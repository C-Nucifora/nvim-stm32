local detect = require("nvim-stm32.detect")

--- Return the absolute path to a fixture.
---@param rel string
---@return string
local function fixture(rel)
  local here =
    vim.fn.fnamemodify(vim.fn.resolve(debug.getinfo(1, "S").source:sub(2)), ":p:h")
  return here .. "/fixtures/" .. rel
end

describe("nvim-stm32.detect.markers_in", function()
  it("prefers CMakePresets.json over a Makefile in the same directory", function()
    local backend, marker = detect.markers_in(fixture("presets_and_makefile"))
    assert.equals("cmake_presets", backend)
    assert.equals(fixture("presets_and_makefile") .. "/CMakePresets.json", marker)
  end)

  it("falls back to the Makefile when there are no CMake files", function()
    local backend = detect.markers_in(fixture("makefile_only"))
    assert.equals("make", backend)
  end)

  it("marks an .ioc-only directory as a root with nothing to build", function()
    local backend, marker = detect.markers_in(fixture("ioc_only"))
    assert.is_nil(backend)
    assert.equals(fixture("ioc_only") .. "/dt.ioc", marker)
  end)

  it("finds nothing in a directory with no markers", function()
    local backend, marker = detect.markers_in(fixture("nucleo_cmake/Core/Src"))
    assert.is_nil(backend)
    assert.is_nil(marker)
  end)
end)

describe("nvim-stm32.detect.root", function()
  it("walks up from a source file to the firmware folder", function()
    local root, backend = detect.root(fixture("nucleo_cmake/Core/Src"))
    assert.equals(fixture("nucleo_cmake"), root)
    assert.equals("cmake_presets", backend)
  end)

  it("returns the directory itself when it is already a root", function()
    assert.equals(fixture("nucleo_cmake"), (detect.root(fixture("nucleo_cmake"))))
  end)

  it("prefers an outer strong root over generated nested CMake", function()
    local root, backend = detect.root(fixture("nucleo_cmake/cmake/stm32cubemx"))
    assert.equals(fixture("nucleo_cmake"), root)
    assert.equals("cmake_presets", backend)
  end)

  it("returns nil below a git root that holds no markers", function()
    local tmp = vim.fn.tempname()
    vim.fn.mkdir(tmp .. "/.git", "p")
    vim.fn.mkdir(tmp .. "/src/deep", "p")
    assert.is_nil(detect.root(tmp .. "/src/deep"))
    vim.fn.delete(tmp, "rf")
  end)

  it("does not escape the git root to find a marker above it", function()
    local tmp = vim.fn.tempname()
    vim.fn.mkdir(tmp .. "/repo/src", "p")
    vim.fn.mkdir(tmp .. "/repo/.git", "p")
    vim.fn.writefile({ "all:" }, tmp .. "/Makefile")
    assert.is_nil(detect.root(tmp .. "/repo/src"))
    vim.fn.delete(tmp, "rf")
  end)
end)

describe("nvim-stm32.detect.start_dir", function()
  it("uses the current buffer's directory", function()
    vim.cmd("edit " .. vim.fn.fnameescape(fixture("nucleo_cmake/Core/Src/main.c")))
    assert.equals(fixture("nucleo_cmake/Core/Src"), detect.start_dir())
    vim.cmd("bwipeout!")
  end)

  it("falls back to the working directory for an unnamed buffer", function()
    vim.cmd("enew")
    assert.equals(vim.fn.getcwd(), detect.start_dir())
    vim.cmd("bwipeout!")
  end)
end)
