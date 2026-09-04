local presets = require("nvim-stm32.build.presets")

local function fixture(rel)
  local here =
    vim.fn.fnamemodify(vim.fn.resolve(debug.getinfo(1, "S").source:sub(2)), ":p:h")
  return here .. "/fixtures/" .. rel
end

describe("nvim-stm32 CMake preset resolution", function()
  it("maps a build preset to its configure preset", function()
    local configs = assert(presets.configurations(fixture("preset_inheritance")))
    assert.same({
      {
        name = "Debug",
        configure_preset = "gcc-debug",
        build_preset = "Debug",
        binary_dir = fixture("preset_inheritance/build/gcc-debug"),
      },
    }, configs)
  end)

  it("uses CMake build presets instead of assuming a build slash preset", function()
    local command = presets.build_command({ root = "/fw" }, {
      name = "Debug",
      configure_preset = "gcc-debug",
      build_preset = "Debug",
      binary_dir = "/fw/out/debug",
    })
    assert.same({ "cmake", "--build", "--preset", "Debug" }, command.argv)
    assert.equals("/fw", command.cwd)
    assert.equals("short", command.lifecycle)
  end)

  it("falls back to the resolved binary directory without a build preset", function()
    local command = presets.build_command({ root = "/fw" }, {
      name = "Size",
      configure_preset = "size",
      binary_dir = "/fw/out/size",
    })
    assert.same({ "cmake", "--build", "/fw/out/size" }, command.argv)
  end)

  it("passes every requested target after one target flag", function()
    local command = presets.build_command({ root = "/fw" }, {
      name = "Debug",
      configure_preset = "gcc-debug",
      build_preset = "Debug",
      binary_dir = "/fw/out/debug",
    }, { "firmware", "flash" })
    assert.same(
      { "cmake", "--build", "--preset", "Debug", "--target", "firmware", "flash" },
      command.argv
    )
  end)

  it("includes visible configure presets that have no build preset", function()
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
    vim.fn.writefile({
      [[{"configurePresets":[{"name":"base","hidden":true,"binaryDir":"${sourceDir}/out/${presetName}"},{"name":"Size","inherits":"base"}]}]],
    }, root .. "/CMakePresets.json")

    local configs = assert(presets.configurations(root))
    assert.same({
      {
        name = "Size",
        configure_preset = "Size",
        binary_dir = root .. "/out/Size",
      },
    }, configs)
    vim.fn.delete(root, "rf")
  end)

  it("reports cycles and missing inherited presets as structured errors", function()
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
    vim.fn.writefile({
      [[{"configurePresets":[{"name":"one","inherits":"two"},{"name":"two","inherits":"one"}]}]],
    }, root .. "/CMakePresets.json")
    local _, cycle = presets.configurations(root)
    assert.equals("cmake-presets-cycle", cycle.code)
    assert.matches("CMakePresets.json", cycle.message, 1, true)
    assert.matches("one", cycle.message, 1, true)

    vim.fn.writefile({
      [[{"configurePresets":[{"name":"one","inherits":"missing"}]}]],
    }, root .. "/CMakePresets.json")
    local _, reference = presets.configurations(root)
    assert.equals("cmake-presets-reference", reference.code)
    assert.matches("missing", reference.message, 1, true)
    vim.fn.delete(root, "rf")
  end)
end)
