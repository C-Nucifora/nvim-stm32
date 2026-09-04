local health = require("nvim-stm32.health")

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
