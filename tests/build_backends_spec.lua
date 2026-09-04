local presets = require("nvim-stm32.backend.build.cmake_presets")
local plain = require("nvim-stm32.backend.build.cmake_plain")
local make = require("nvim-stm32.backend.build.make")

local function fixture(rel)
  local here =
    vim.fn.fnamemodify(vim.fn.resolve(debug.getinfo(1, "S").source:sub(2)), ":p:h")
  return here .. "/fixtures/" .. rel
end

describe("nvim-stm32 build backends", function()
  it("builds preset CMake argv without a shell", function()
    local target = { root = fixture("nucleo_cmake"), build_backend = "cmake_presets" }
    assert.same(
      { "cmake", "--preset", "Debug" },
      presets.configure_cmd(target, { preset = "Debug" })
    )
    assert.same(
      { "cmake", "--build", "--preset", "Debug" },
      presets.cmd(target, { preset = "Debug" })
    )
  end)

  it("requires a preset for preset CMake commands", function()
    local target = { root = fixture("nucleo_cmake"), build_backend = "cmake_presets" }
    assert.has_error(function()
      presets.configure_cmd(target, {})
    end, "preset is required")
    assert.has_error(function()
      presets.cmd(target, {})
    end, "preset is required")
  end)

  it("builds plain CMake argv", function()
    assert.same({ "cmake", "-S", ".", "-B", "build" }, plain.configure_cmd(target, {}))
    assert.same({ "cmake", "--build", "build" }, plain.cmd(target, {}))
  end)

  it("builds Make argv", function()
    assert.same({ "make" }, make.cmd(target, {}))
  end)

  for name, backend in pairs({
    cmake_presets = presets,
    cmake_plain = plain,
    make = make,
  }) do
    it(name .. " returns a boolean availability result", function()
      assert.equals("boolean", type(backend.available()))
    end)

    it(name .. " returns structured process results", function()
      assert.same({ ok = true, code = 0, output = "done" }, backend.parse("done", 0))
      assert.same({ ok = false, code = 2, output = "bad" }, backend.parse("bad", 2))
    end)
  end
end)

describe("nvim-stm32 CMake preset discovery", function()
  it("returns visible build presets in file order", function()
    assert.same({ "Debug", "Release" }, (presets.presets(fixture("nucleo_cmake"))))
  end)

  it("falls back to visible configure presets", function()
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
    vim.fn.writefile({
      [[{"configurePresets":[{"name":"base","hidden":true},{"name":"Size"}]}]],
    }, root .. "/CMakePresets.json")

    assert.same({ "Size" }, (presets.presets(root)))
    vim.fn.delete(root, "rf")
  end)

  it("returns an error for malformed JSON", function()
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
    vim.fn.writefile({ "not json" }, root .. "/CMakePresets.json")

    local names, err = presets.presets(root)
    assert.is_nil(names)
    assert.equals("string", type(err))
    assert.matches("invalid JSON", err, 1, true)
    vim.fn.delete(root, "rf")
  end)

  it("returns an error when CMakePresets.json is missing", function()
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")

    local names, err = presets.presets(root)
    assert.is_nil(names)
    assert.equals("string", type(err))
    assert.matches("could not read file", err, 1, true)
    vim.fn.delete(root, "rf")
  end)
end)
