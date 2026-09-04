local model = require("nvim-stm32.model")
local session = require("nvim-stm32.session")
local context = require("nvim-stm32.operations.context")

local function write_json(path, value)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  vim.fn.writefile({ vim.json.encode(value) }, path)
end

local function preset_document(root, names)
  local configure, builds = {}, {}
  for _, name in ipairs(names) do
    configure[#configure + 1] = {
      name = name,
      binaryDir = "${sourceDir}/build/${presetName}",
    }
    builds[#builds + 1] = { name = name, configurePreset = name }
  end
  write_json(root .. "/CMakePresets.json", {
    version = 3,
    configurePresets = configure,
    buildPresets = builds,
  })
end

local function project(root, images)
  return model.project({
    id = root,
    root = root,
    kind = "cmake_presets",
    build = { adapter = "cmake_presets", marker = root .. "/CMakePresets.json" },
    images = images or {
      {
        id = "application",
        name = "application",
        build_target = "app",
        target = { mcu = "STM32F429ZITx" },
      },
    },
  })
end

local function image_ids(images)
  return vim.tbl_map(function(image)
    return image.id
  end, images)
end

describe("nvim-stm32 operation context", function()
  local root

  before_each(function()
    root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
    preset_document(root, { "Debug", "Release" })
    session.clear()
  end)

  after_each(function()
    session.clear()
    vim.fn.delete(root, "rf")
  end)

  it("resolves the explicit F429 configuration and image", function()
    local resolved = assert(context.resolve(project(root), {
      configuration = "Debug",
      images = { "application" },
    }))
    assert.equals("Debug", resolved.configuration.name)
    assert.same(
      { "application" },
      vim.tbl_map(function(image)
        return image.id
      end, resolved.images)
    )
  end)

  it("uses remembered selections when options do not provide them", function()
    local multi = project(root, {
      { id = "CM4", name = "CM4", target = {} },
      { id = "CM7", name = "CM7", target = {} },
    })
    session.select(root, { configuration = "Release", image_id = "CM7" })

    local resolved = assert(context.resolve(multi))

    assert.equals("Release", resolved.configuration.name)
    assert.same({ "CM7" }, image_ids(resolved.images))
  end)

  it("uses the sole configuration when no selection exists", function()
    preset_document(root, { "Debug" })

    local resolved = assert(context.resolve(project(root)))

    assert.equals("Debug", resolved.configuration.name)
  end)

  it("rejects an explicit false configuration instead of using the session", function()
    session.select(root, { configuration = "Release" })

    local resolved, err = context.resolve(project(root), { configuration = false })

    assert.is_nil(resolved)
    assert.equals("configuration-not-found", err.code)
  end)

  it("selects all images in project order without a selection", function()
    local multi = project(root, {
      { id = "CM4", name = "CM4", target = {} },
      { id = "CM7", name = "CM7", target = {} },
    })

    local resolved = assert(context.resolve(multi, { configuration = "Debug" }))

    assert.same({ "CM4", "CM7" }, image_ids(resolved.images))
  end)

  it("deduplicates explicit images while preserving requested order", function()
    local multi = project(root, {
      { id = "CM4", name = "CM4", target = {} },
      { id = "CM7", name = "CM7", target = {} },
    })

    local resolved = assert(context.resolve(multi, {
      configuration = "Debug",
      images = { "CM7", "CM7", "CM4" },
    }))

    assert.same({ "CM7", "CM4" }, image_ids(resolved.images))
  end)

  it("rejects unknown configuration and image selections", function()
    local multi = project(root, {
      { id = "CM4", name = "CM4", target = {} },
      { id = "CM7", name = "CM7", target = {} },
    })

    local missing_configuration, configuration_err = context.resolve(multi, {
      configuration = "missing",
    })
    assert.is_nil(missing_configuration)
    assert.equals("configuration-not-found", configuration_err.code)

    local missing_image, image_err = context.resolve(multi, {
      configuration = "Debug",
      images = { "missing" },
    })
    assert.is_nil(missing_image)
    assert.equals("image-not-found", image_err.code)
  end)
end)
