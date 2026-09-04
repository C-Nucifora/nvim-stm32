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
    vim.fn.delete(root, "rf")
  end)

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

  it("finds every tree artifact inside the selected binary directory", function()
    write(root .. "/build/Debug/nested/boot.elf")
    local found = assert(artifacts.from_tree(single_image_project, config, "op-5"))

    assert.equals(5, #found)
    assert.equals("tree", found[1].provenance.source)
  end)
end)
