--- nvim-stm32: `:checkhealth nvim-stm32`.
---
--- Answers the two questions a broken setup raises: which external programs did
--- the plugin find, and which optional Neovim plugins is it able to use.
local M = {}

local h = vim.health

--- Classify a resolved tool path.
---
--- Pure, so the specs pin the wording without a real toolchain on the runner,
--- and so a missing tool always reports the config key that overrides its path
--- instead of a bare "not found".
--- `path == ""` counts as not found: vim.fn.exepath() returns "" rather than
--- nil for a missing program, and an unguarded `if path then` would treat that
--- as truthy and print an ok line with nothing after the colon.
---@param label string        the program's name, as the user would type it
---@param path string|nil     the resolved path, "", or nil
---@param opt_key string|nil  config key that overrides this path
---@return "ok"|"warn" level, string msg, string[]|nil advice
function M.tool_status(label, path, opt_key)
  if path and path ~= "" then
    return "ok", label .. ": " .. path
  end
  local advice = opt_key
      and { ("Install %s, or set opts.%s to its path."):format(label, opt_key) }
    or { ("Install %s and put it on $PATH."):format(label) }
  return "warn", label .. " not found", advice
end

--- Render one tool_status verdict.
---@param label string
---@param path string|nil
---@param opt_key string|nil
local function report_tool(label, path, opt_key)
  local level, msg, advice = M.tool_status(label, path, opt_key)
  if level == "ok" then
    h.ok(msg)
  else
    h.warn(msg, advice)
  end
end

function M.check()
  local cfg = require("nvim-stm32").get_config()
  local tools = require("nvim-stm32.tools")

  h.start("nvim-stm32: Neovim")
  if vim.fn.has("nvim-0.11") == 1 then
    h.ok("Neovim " .. tostring(vim.version()))
  else
    h.error("Neovim >= 0.11 required")
  end
  if vim.fn.has("win32") == 1 then
    h.error("Windows is not supported; nvim-stm32 targets macOS and Linux")
  end

  h.start("nvim-stm32: build tools")
  if cfg.toolchain_path then
    h.info("toolchain_path: " .. cfg.toolchain_path)
  else
    h.info("toolchain_path unset; children inherit $PATH")
  end
  report_tool("arm-none-eabi-gcc", tools.gcc(cfg), "toolchain_path")
  report_tool("cmake", vim.fn.exepath("cmake"), nil)
  for _, gen in ipairs({ "ninja", "make" }) do
    local path = vim.fn.exepath(gen)
    if path ~= "" then
      h.ok(gen .. ": " .. path)
    else
      h.info(gen .. " not found")
    end
  end

  h.start("nvim-stm32: programmers")
  report_tool("STM32_Programmer_CLI", tools.programmer(cfg), "programmer_path")
  report_tool("st-flash", tools.stlink(cfg), "stlink_path")
  report_tool("openocd", tools.openocd(cfg), "openocd_path")
  if cfg.flash_backend then
    h.info("flash_backend pinned to " .. cfg.flash_backend)
  else
    h.info("flash probe order: " .. table.concat(cfg.flash_order, ", "))
  end

  h.start("nvim-stm32: debug")
  report_tool("arm-none-eabi-gdb", tools.gdb(cfg), "gdb_path")

  h.start("nvim-stm32: optional integrations")
  for _, mod in ipairs({
    {
      "snacks",
      "floats and notifications; a plain nvim_open_win float is used without it",
    },
    { "dap", "debugging" },
    { "dap-cortex-debug", "richer debugging, RTT and SVD support" },
    { "compiler", "STM32 entries in the compiler.nvim picker" },
  }) do
    if pcall(require, mod[1]) then
      h.ok(mod[1] .. ": " .. mod[2])
    else
      h.info(mod[1] .. " not installed, so no " .. mod[2])
    end
  end
end

return M
