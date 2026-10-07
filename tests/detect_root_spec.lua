local detect = require("nvim-stm32.detect")
local float = require("nvim-stm32.ui.float")
local config = require("nvim-stm32.config")
local runtime = require("nvim-stm32")

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

describe("nvim-stm32 focused output context", function()
  local original_cwd
  local original_win
  local source_buf
  local presenters
  local temporary

  before_each(function()
    original_cwd = vim.fn.getcwd()
    original_win = vim.api.nvim_get_current_win()
    presenters = {}
    temporary = vim.fn.tempname()
    vim.fn.mkdir(temporary, "p")
  end)

  after_each(function()
    for index = #presenters, 1, -1 do
      presenters[index]:close()
      if vim.api.nvim_buf_is_valid(presenters[index].buf) then
        vim.api.nvim_buf_delete(presenters[index].buf, { force = true })
      end
    end
    if vim.api.nvim_win_is_valid(original_win) then
      vim.api.nvim_set_current_win(original_win)
    end
    if source_buf and vim.api.nvim_buf_is_valid(source_buf) then
      vim.api.nvim_buf_delete(source_buf, { force = true })
    end
    source_buf = nil
    vim.cmd.cd(vim.fn.fnameescape(original_cwd))
    vim.fn.delete(temporary, "rf")
  end)

  local function output()
    local presenter = float.open({}, config.resolve())
    presenters[#presenters + 1] = presenter
    return presenter
  end

  it(
    "keeps the source project through focused and nested output despite another cwd",
    function()
      vim.cmd.cd(vim.fn.fnameescape(fixture("makefile_only")))
      vim.cmd.edit(vim.fn.fnameescape(fixture("nucleo_cmake/Core/Src/main.c")))
      source_buf = vim.api.nvim_get_current_buf()
      output()
      local project = assert(runtime.resolve_project())
      assert.equals(fixture("nucleo_cmake"), project.root)
      output()
      assert.equals(fixture("nucleo_cmake/Core/Src"), detect.start_dir())
      assert.equals(fixture("nucleo_cmake"), assert(runtime.resolve_project()).root)
      vim.api.nvim_buf_delete(source_buf, { force = true })
      assert.equals(fixture("nucleo_cmake"), assert(runtime.resolve_project()).root)
    end
  )

  it(
    "does not select an outer or cwd project after the source project is deleted",
    function()
      vim.fn.mkdir(temporary .. "/firmware", "p")
      vim.fn.writefile({ "all:" }, temporary .. "/Makefile")
      vim.fn.writefile({ "Mcu.CPN=STM32F429ZITx" }, temporary .. "/firmware/board.ioc")
      vim.fn.writefile({ "int main(void) {}" }, temporary .. "/firmware/main.c")
      vim.cmd.cd(vim.fn.fnameescape(fixture("makefile_only")))
      vim.cmd.edit(vim.fn.fnameescape(temporary .. "/firmware/main.c"))
      source_buf = vim.api.nvim_get_current_buf()
      output()
      vim.fn.delete(temporary .. "/firmware", "rf")
      local project, err = runtime.resolve_project()
      assert.is_nil(project)
      assert.equals("project-not-found", err.code)
    end
  )
end)
