local artifacts = require("nvim-stm32.discover.artifacts")
local model = require("nvim-stm32.model")

local function project(root, images)
  return model.project({
    id = root,
    root = root,
    kind = "cmake",
    build = {},
    images = images,
  })
end

local function image(id, build_target)
  return {
    id = id,
    name = id,
    target = {},
    build_target = build_target,
  }
end

local function configuration(root)
  return model.configuration({
    name = "Debug",
    configure_preset = "Debug",
    binary_dir = root .. "/build/Debug",
  })
end

local function write(path)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  vim.fn.writefile({ "artifact" }, path)
end

local function reply(root, targets)
  local records = {}
  for _, target in ipairs(targets) do
    records[#records + 1] = {
      name = target,
      type = "EXECUTABLE",
      artifacts = { root .. "/build/Debug/" .. target .. ".elf" },
    }
  end
  return { targets = records }
end

describe("nvim-stm32 artifact discovery", function()
  local root
  local config
  local single_image_project
  local single_target_reply
  local original_stat = vim.uv.fs_stat

  before_each(function()
    root = vim.fn.tempname()
    config = configuration(root)
    single_image_project = project(root, { image("application", "app") })
    single_target_reply = reply(root, { "app" })
    write(root .. "/build/Debug/app.elf")
    write(root .. "/build/Debug/app.hex")
    write(root .. "/build/Debug/app.bin")
    write(root .. "/build/Debug/app.map")
  end)

  after_each(function()
    vim.uv.fs_stat = original_stat
    vim.fn.delete(root, "rf")
  end)

  for _, adapter in ipairs({ "cmake", "tree" }) do
    local function discover()
      if adapter == "cmake" then
        return assert(
          artifacts.from_cmake(
            single_image_project,
            config,
            single_target_reply,
            "build-new"
          )
        )
      end
      return assert(artifacts.from_tree(single_image_project, config, "build-new"))
    end

    it(
      adapter .. " omits stale flash companions while retaining older linker maps",
      function()
        local timestamp = os.time() - 120
        for _, extension in ipairs({ "bin", "hex", "map" }) do
          local path = config.binary_dir .. "/app." .. extension
          assert(vim.uv.fs_utime(path, timestamp, timestamp))
        end
        local elf = config.binary_dir .. "/app.elf"
        assert(vim.uv.fs_utime(elf, timestamp + 60, timestamp + 60))

        local found = discover()
        assert.equals(2, #found)
        assert.equals(1, #artifacts.for_image(found, "application", "elf"))
        assert.equals(1, #artifacts.for_image(found, "application", "map"))
        for _, artifact in ipairs(found) do
          assert.equals("build-new", artifact.build_id)
        end
      end
    )

    it(adapter .. " retains equal and newer companions after no-op builds", function()
      local timestamp = os.time() - 120
      for _, extension in ipairs({ "elf", "bin", "hex", "map" }) do
        local path = config.binary_dir .. "/app." .. extension
        assert(vim.uv.fs_utime(path, timestamp, timestamp))
      end
      for _, offset in ipairs({ 0, 60 }) do
        for _, extension in ipairs({ "bin", "hex" }) do
          local path = config.binary_dir .. "/app." .. extension
          assert(vim.uv.fs_utime(path, timestamp + offset, timestamp + offset))
        end
        local found = discover()
        assert.equals(4, #found)
        for _, artifact in ipairs(found) do
          assert.equals("build-new", artifact.build_id)
        end
      end
    end)

    it(adapter .. " compares companion freshness at nanosecond precision", function()
      local timestamp = os.time()
      vim.uv.fs_stat = function(path, ...)
        local stat = original_stat(path, ...)
        if stat and vim.fs.dirname(path) == config.binary_dir then
          stat.mtime = {
            sec = timestamp,
            nsec = path:match("%.elf$") and 101 or 100,
          }
        end
        return stat
      end

      local found = discover()
      assert.equals(2, #found)
      assert.equals(0, #artifacts.for_image(found, "application", "bin"))
      assert.equals(0, #artifacts.for_image(found, "application", "hex"))
    end)
  end

  it("maps an executable target to its image", function()
    local found = assert(
      artifacts.from_cmake(single_image_project, config, single_target_reply, 40)
    )

    assert.equals("application", found[1].image_id)
    assert.equals("app", found[1].build_target)
    assert.equals("elf", found[1].kind)
    assert.equals("cmake-file-api", found[1].provenance.source)
    assert.equals(4, #found)
  end)

  it("rejects an artifact path that does not exist", function()
    local missing_reply = reply(root, { "missing" })
    local found, err =
      artifacts.from_cmake(single_image_project, config, missing_reply, "op-1")

    assert.is_nil(found)
    assert.equals("artifact-missing", err.code)
  end)

  it("accepts an unchanged artifact after a successful no-op build", function()
    local found = assert(
      artifacts.from_cmake(single_image_project, config, single_target_reply, "op-2")
    )

    assert.equals("op-2", found[1].build_id)
  end)

  it("uses the executable name as an implicit CMake build target", function()
    local implicit_project = project(root, { image("application") })
    local found = assert(
      artifacts.from_cmake(implicit_project, config, single_target_reply, "op-implicit")
    )

    assert.equals("app", found[1].build_target)
  end)

  it("finds uppercase sibling artifact extensions", function()
    local uppercase_project = project(root, { image("application", "caps") })
    write(root .. "/build/Debug/caps.elf")
    write(root .. "/build/Debug/caps.HEX")
    write(root .. "/build/Debug/caps.BIN")
    write(root .. "/build/Debug/caps.MAP")
    local found = assert(
      artifacts.from_cmake(
        uppercase_project,
        config,
        reply(root, { "caps" }),
        "op-uppercase"
      )
    )

    assert.equals(4, #found)
    local kinds = vim.tbl_map(function(artifact)
      return artifact.kind
    end, found)
    table.sort(kinds)
    assert.same({ "bin", "elf", "hex", "map" }, kinds)
  end)

  it("does not guess between unmapped executable targets", function()
    local two_image_project = project(root, {
      image("core-0", "firmware-0"),
      image("core-1", "firmware-1"),
    })
    write(root .. "/build/Debug/a.elf")
    write(root .. "/build/Debug/b.elf")
    local found, err =
      artifacts.from_cmake(two_image_project, config, reply(root, { "a", "b" }), "op-3")

    assert.is_nil(found)
    assert.equals("artifact-ambiguous", err.code)
  end)

  it("rejects a CMake artifact outside the selected binary directory", function()
    local outside = root .. "/outside.elf"
    local linked = root .. "/build/Debug/linked.elf"
    write(outside)
    assert(vim.uv.fs_symlink(outside, linked))
    local found, err = artifacts.from_cmake(single_image_project, config, {
      targets = {
        { name = "app", type = "EXECUTABLE", artifacts = { linked } },
      },
    }, "op-4")

    assert.is_nil(found)
    assert.equals("artifact-outside-binary-dir", err.code)
  end)

  it("does not assign unrelated tree executables to the sole image", function()
    write(root .. "/build/Debug/nested/boot.elf")
    local found, err = artifacts.from_tree(single_image_project, config, "op-5")

    assert.is_nil(found)
    assert.equals("artifact-ambiguous", err.code)
  end)
end)
