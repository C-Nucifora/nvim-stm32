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
end)

describe("nvim-stm32.health.check", function()
  it("runs without error", function()
    -- :checkhealth loads the module and calls check(); a nil index in there
    -- is a traceback in the user's face, so at least prove it survives a
    -- real run.
    vim.cmd("checkhealth nvim-stm32")
    local out = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
    assert.is_truthy(out:find("nvim-stm32", 1, true))
    vim.cmd("bwipeout!")
  end)
end)
