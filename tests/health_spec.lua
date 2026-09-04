local health = require("nvim-stm32.health")
local probes = require("nvim-stm32.probes")
local tools = require("nvim-stm32.tools")

describe("nvim-stm32.health.tool_status", function()
  it("reports a found tool with its path", function()
    local level, msg =
      health.tool_status("openocd", "/opt/homebrew/bin/openocd", "openocd_path")
    assert.equals("ok", level)
    assert.equals("openocd: /opt/homebrew/bin/openocd", msg)
  end)

  it("names the config key that overrides a missing tool", function()
    local level, msg, advice =
      health.tool_status("STM32_Programmer_CLI", nil, "programmer_path")
    assert.equals("warn", level)
    assert.is_truthy(msg:find("STM32_Programmer_CLI", 1, true))
    assert.is_truthy(table.concat(advice, " "):find("opts.programmer_path", 1, true))
  end)

  it("falls back to a PATH hint when no key overrides the tool", function()
    local level, _, advice = health.tool_status("cmake", nil, nil)
    assert.equals("warn", level)
    assert.is_truthy(table.concat(advice, " "):find("$PATH", 1, true))
  end)

  it("treats an empty exepath result as not found", function()
    -- vim.fn.exepath returns "" rather than nil for a missing program, and ""
    -- is truthy in Lua, so this is the case that would otherwise report ok
    -- with a blank path.
    local level, msg = health.tool_status("cmake", "", nil)
    assert.equals("warn", level)
    assert.is_truthy(msg:find("not found", 1, true))
  end)
end)

describe("nvim-stm32.health.cmake_project_status", function()
  it("distinguishes missing CMake", function()
    local level, message = health.cmake_project_status({
      root = "/fw",
      kind = "cmake_presets",
    }, { cmake_path = "" })
    assert.equals("warn", level)
    assert.matches("cmake not found", message, 1, true)
  end)

  it("distinguishes an absent pre-configure File API reply", function()
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
    local level, message = health.cmake_project_status({
      root = root,
      kind = "cmake_presets",
    }, { cmake_path = "/usr/bin/cmake", binary_dir = root .. "/build/Debug" })
    assert.equals("info", level)
    assert.matches("not configured yet", message, 1, true)
    vim.fn.delete(root, "rf")
  end)

  it("distinguishes malformed and usable File API replies", function()
    local root = vim.fn.tempname()
    local binary = root .. "/build/Debug"
    local replies = binary .. "/.cmake/api/v1/reply"
    vim.fn.mkdir(replies, "p")
    vim.fn.writefile({ "bad json" }, replies .. "/index-test.json")

    local malformed_level, malformed_message = health.cmake_project_status({
      root = root,
      kind = "cmake_presets",
    }, { cmake_path = "/usr/bin/cmake", binary_dir = binary })
    assert.equals("warn", malformed_level)
    assert.matches("malformed", malformed_message, 1, true)

    vim.fn.delete(replies, "rf")
    vim.fn.mkdir(replies, "p")
    vim.fn.writefile({
      vim.json.encode({
        objects = {
          {
            kind = "codemodel",
            version = { major = 2 },
            jsonFile = "codemodel-test.json",
          },
        },
      }),
    }, replies .. "/index-test.json")
    vim.fn.writefile({
      vim.json.encode({
        kind = "codemodel",
        version = { major = 2 },
        paths = { source = root, build = binary },
        configurations = { { name = "Debug", targets = {} } },
      }),
    }, replies .. "/codemodel-test.json")

    local ok_level, ok_message = health.cmake_project_status({
      root = root,
      kind = "cmake_presets",
    }, { cmake_path = "/usr/bin/cmake", binary_dir = binary })
    assert.equals("ok", ok_level)
    assert.matches("File API reply", ok_message, 1, true)
    vim.fn.delete(root, "rf")
  end)
end)

describe("nvim-stm32.health.check", function()
  it("runs without error", function()
    -- :checkhealth loads the module and calls check(); a nil index in there
    -- is a traceback in the user's face. The engine prints the "nvim-stm32:"
    -- heading itself before calling check(), so that string alone survives
    -- even a check() that errors immediately; assert on a section title only
    -- our own code emits, and on the absence of a traceback, so this case
    -- actually fails when check() throws.
    vim.cmd("checkhealth nvim-stm32")
    local out = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
    assert.is_truthy(out:find("nvim-stm32: programmers", 1, true))
    assert.is_falsy(out:find("stack traceback", 1, true))
    vim.cmd("bwipeout!")
  end)

  it("resolves programmer tools without enumerating probes", function()
    local original_programmer = tools.programmer
    local original_enumerate = probes.enumerate
    local programmer_resolutions = 0
    local enumerations = 0
    tools.programmer = function()
      programmer_resolutions = programmer_resolutions + 1
      return nil
    end
    probes.enumerate = function()
      enumerations = enumerations + 1
      error("health must not enumerate probes")
    end

    local ok, err = pcall(function()
      vim.cmd("checkhealth nvim-stm32")
    end)
    tools.programmer = original_programmer
    probes.enumerate = original_enumerate

    assert.is_true(ok, err)
    assert.is_true(programmer_resolutions > 0)
    assert.equals(0, enumerations)
    vim.cmd("bwipeout!")
  end)
end)

describe("nvim-stm32.health project section", function()
  it("names the detected project in the report", function()
    local here =
      vim.fn.fnamemodify(vim.fn.resolve(debug.getinfo(1, "S").source:sub(2)), ":p:h")
    vim.cmd(
      "edit " .. vim.fn.fnameescape(here .. "/fixtures/nucleo_cmake/Core/Src/main.c")
    )
    local source_buf = vim.api.nvim_get_current_buf()
    vim.cmd("checkhealth nvim-stm32")
    local out = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
    assert.is_truthy(out:find("STM32F429ZITx", 1, true))
    vim.cmd("bwipeout!")
    vim.api.nvim_buf_delete(source_buf, { force = true })
  end)
end)
