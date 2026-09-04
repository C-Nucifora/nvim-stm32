local model = require("nvim-stm32.model")
local layout = require("nvim-stm32.flash.layout")

local function write(path, contents)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  vim.fn.writefile(vim.split(contents or "firmware", "\n", { plain = true }), path)
end

local function image(root, id, address, linker_text)
  local linker_path = root .. "/" .. id .. ".ld"
  write(
    linker_path,
    linker_text or "MEMORY\n{\nFLASH (rx) : ORIGIN = 0x08000000, LENGTH = 2M\n}"
  )
  return {
    id = id,
    name = id,
    build_target = id,
    flash = address and { address = address } or nil,
    target = {
      mcu = "STM32F429ZITx",
      signals = {
        {
          source = "linker",
          file = linker_path,
          mcu = "STM32F429ZITx",
          confidence = "inferred",
        },
      },
    },
  }
end

local function modified_ns(path)
  local stat = vim.uv.fs_stat(path)
  local mtime = stat and stat.mtime or {}
  return (mtime.sec or 0) * 1000000000 + (mtime.nsec or 0)
end

local function project(root, images, flash_order)
  return model.project({
    id = root,
    root = root,
    kind = "cmake_presets",
    build = { adapter = "cmake_presets", marker = root .. "/CMakePresets.json" },
    images = images,
    flash_order = flash_order or {},
  })
end

local function artifact(root, id, kind, overrides)
  overrides = overrides or {}
  local path = overrides.path or root .. "/build/Debug/" .. id .. "." .. kind
  if overrides.write ~= false then
    write(path, overrides.contents)
  end
  local spec = {
    image_id = id,
    configuration = overrides.configuration or "Debug",
    kind = kind,
    path = path,
    build_target = overrides.build_target or id,
    modified_ns = modified_ns(path),
    build_id = overrides.build_id or "build-7",
  }
  if overrides.build_id == false then
    spec.build_id = nil
  end
  return model.artifact(spec)
end

local function context(root, images, flash_order, overrides)
  overrides = overrides or {}
  return {
    project = project(root, images, flash_order),
    images = vim.deepcopy(overrides.images or images),
    configuration = {
      name = overrides.configuration or "Debug",
      configure_preset = "Debug",
      build_preset = "Debug",
      binary_dir = root .. "/build/Debug",
    },
    build_id = overrides.build_id or "build-7",
  }
end

describe("nvim-stm32 flash layout", function()
  local root

  before_each(function()
    root = vim.fn.tempname()
    vim.fn.mkdir(root .. "/build/Debug", "p")
  end)

  after_each(function()
    vim.fn.delete(root, "rf")
  end)

  for _, backend in ipairs({ "cubeprogrammer", "openocd" }) do
    it("accepts one fresh ELF for " .. backend, function()
      local app = image(root, "application")
      local elf = artifact(root, "application", "elf")

      local resolved = assert(layout.resolve(context(root, { app }), { elf }, backend))

      assert.equals(1, #resolved)
      assert.equals("application", resolved[1].image_id)
      assert.equals(vim.uv.fs_realpath(elf.path), resolved[1].artifact.path)
      assert.equals(0x08000000, resolved[1].address)
      assert.equals(vim.uv.fs_stat(elf.path).size, resolved[1].size)
      assert.same({
        name = "FLASH",
        attributes = "rx",
        origin = 0x08000000,
        length = 2 * 1024 * 1024,
      }, resolved[1].region)
    end)
  end

  it("accepts one fresh BIN with an explicit aligned address", function()
    local app = image(root, "application", 0x08004000)
    local bin = artifact(root, "application", "bin")

    local resolved = assert(layout.resolve(context(root, { app }), { bin }, "stlink"))

    assert.equals(0x08004000, resolved[1].address)
    assert.equals("bin", resolved[1].artifact.kind)
  end)

  it(
    "uses the sole parsed FLASH origin for a BIN without an explicit address",
    function()
      local app = image(
        root,
        "application",
        nil,
        "MEMORY\n{\nRAM (rw) : ORIGIN = 0x20000000, LENGTH = 192K\nFLASH (rx) : ORIGIN = 0x08008000, LENGTH = 512K\n}"
      )
      local bin = artifact(root, "application", "bin")

      local resolved = assert(layout.resolve(context(root, { app }), { bin }, "stlink"))

      assert.equals(0x08008000, resolved[1].address)
    end
  )

  it("orders selected images by flash_order then project order", function()
    local boot = image(
      root,
      "boot",
      0x08000000,
      "MEMORY\n{\nFLASH (rx) : ORIGIN = 0x08000000, LENGTH = 16K\n}"
    )
    local app = image(
      root,
      "app",
      0x08010000,
      "MEMORY\n{\nFLASH (rx) : ORIGIN = 0x08010000, LENGTH = 1M\n}"
    )
    local settings = image(
      root,
      "settings",
      0x08180000,
      "MEMORY\n{\nFLASH (rx) : ORIGIN = 0x08180000, LENGTH = 64K\n}"
    )
    local artifacts = {
      artifact(root, "settings", "elf"),
      artifact(root, "boot", "elf"),
      artifact(root, "app", "elf"),
    }

    local resolved = assert(
      layout.resolve(
        context(root, { boot, app, settings }, { "app" }),
        artifacts,
        "openocd"
      )
    )

    assert.same(
      { "app", "boot", "settings" },
      vim.tbl_map(function(item)
        return item.image_id
      end, resolved)
    )
  end)

  it("rejects an artifact from another configuration", function()
    local app = image(root, "application")
    local elf = artifact(root, "application", "elf", { configuration = "Release" })

    local resolved, err = layout.resolve(context(root, { app }), { elf }, "openocd")

    assert.is_nil(resolved)
    assert.equals("flash-configuration-mismatch", err.code)
  end)

  it("rejects an artifact without the selected build id", function()
    local app = image(root, "application")
    local elf = artifact(root, "application", "elf", { build_id = "build-older" })

    local resolved, err = layout.resolve(context(root, { app }), { elf }, "openocd")

    assert.is_nil(resolved)
    assert.equals("flash-build-stale", err.code)
  end)

  it("rejects an artifact with no build id", function()
    local app = image(root, "application")
    local elf = artifact(root, "application", "elf", { build_id = false })

    local resolved, err = layout.resolve(context(root, { app }), { elf }, "openocd")

    assert.is_nil(resolved)
    assert.equals("flash-build-stale", err.code)
  end)

  it("rejects several matching artifacts", function()
    local app = image(root, "application")
    local first = artifact(root, "application", "elf")
    local second = artifact(root, "application", "elf", {
      path = root .. "/build/Debug/application-copy.elf",
    })

    local resolved, err =
      layout.resolve(context(root, { app }), { first, second }, "cubeprogrammer")

    assert.is_nil(resolved)
    assert.equals("flash-artifact-ambiguous", err.code)
  end)

  it("rejects the wrong artifact kind for the backend", function()
    local app = image(root, "application")
    local bin = artifact(root, "application", "bin")

    local resolved, err = layout.resolve(context(root, { app }), { bin }, "openocd")

    assert.is_nil(resolved)
    assert.equals("flash-artifact-missing", err.code)
  end)

  it("rejects a missing artifact file", function()
    local app = image(root, "application")
    local elf = artifact(root, "application", "elf", { write = false })

    local resolved, err = layout.resolve(context(root, { app }), { elf }, "openocd")

    assert.is_nil(resolved)
    assert.equals("flash-artifact-missing", err.code)
  end)

  it("rejects an artifact modified after its successful build", function()
    local app = image(root, "application")
    local elf = artifact(root, "application", "elf")
    local stat = assert(vim.uv.fs_stat(elf.path))
    assert(vim.uv.fs_utime(elf.path, stat.atime.sec, stat.mtime.sec + 10))

    local resolved, err = layout.resolve(context(root, { app }), { elf }, "openocd")

    assert.is_nil(resolved)
    assert.equals("flash-artifact-changed", err.code)
  end)

  it("rejects an artifact whose build target differs from the image", function()
    local app = image(root, "application")
    local elf = artifact(root, "application", "elf", { build_target = "other" })

    local resolved, err = layout.resolve(context(root, { app }), { elf }, "openocd")

    assert.is_nil(resolved)
    assert.equals("flash-build-target-mismatch", err.code)
  end)

  it("rejects a symlink that resolves outside the selected binary directory", function()
    local app = image(root, "application")
    local outside = root .. "/outside.elf"
    local symlink = root .. "/build/Debug/application.elf"
    write(outside)
    assert(vim.uv.fs_symlink(outside, symlink))
    local elf = artifact(root, "application", "elf", { path = symlink, write = false })

    local resolved, err = layout.resolve(context(root, { app }), { elf }, "openocd")

    assert.is_nil(resolved)
    assert.equals("flash-artifact-outside-build", err.code)
  end)

  for _, address in ipairs({ 0, 0x08000001 }) do
    it(string.format("rejects invalid BIN address 0x%X", address), function()
      local app = image(root, "application", address)
      local bin = artifact(root, "application", "bin")

      local resolved, err = layout.resolve(context(root, { app }), { bin }, "stlink")

      assert.is_nil(resolved)
      assert.equals("flash-address-invalid", err.code)
    end)
  end

  it("rejects a binary that exceeds its FLASH region", function()
    local app = image(
      root,
      "application",
      0x08000000,
      "MEMORY\n{\nFLASH (rx) : ORIGIN = 0x08000000, LENGTH = 4\n}"
    )
    local bin = artifact(root, "application", "bin", { contents = "12345" })

    local resolved, err = layout.resolve(context(root, { app }), { bin }, "stlink")

    assert.is_nil(resolved)
    assert.equals("flash-range-outside-region", err.code)
  end)

  it("rejects overlapping selected image ranges", function()
    local first = image(
      root,
      "first",
      0x08000000,
      "MEMORY\n{\nFLASH (rx) : ORIGIN = 0x08000000, LENGTH = 64K\n}"
    )
    local second = image(
      root,
      "second",
      0x08000004,
      "MEMORY\n{\nFLASH (rx) : ORIGIN = 0x08000000, LENGTH = 64K\n}"
    )
    local artifacts = {
      artifact(root, "first", "bin", { contents = "12345678" }),
      artifact(root, "second", "bin", { contents = "12345678" }),
    }

    local resolved, err =
      layout.resolve(context(root, { first, second }), artifacts, "stlink")

    assert.is_nil(resolved)
    assert.equals("flash-range-overlap", err.code)
  end)

  it("rejects an unsupported backend before examining artifacts", function()
    local app = image(root, "application")

    local resolved, err = layout.resolve(context(root, { app }), {}, "jlink")

    assert.is_nil(resolved)
    assert.equals("flash-backend-unknown", err.code)
  end)
end)
