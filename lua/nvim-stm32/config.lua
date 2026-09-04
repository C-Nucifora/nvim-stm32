--- nvim-stm32 configuration: defaults, merge, and normalisation.
---
--- The option surface is flat and matches the keys documented in the README.
--- Path options accept `~`; resolve() expands them once so no consumer has to.
local M = {}

--- Flash backends, in the order they are probed when `flash_backend` is unset.
M.flash_backends = { "cubeprogrammer", "stlink", "openocd" }

---@class Stm32Config
---@field toolchain_path? string   Directory prepended to $PATH for build, flash and
---                                 debug children (the arm-none-eabi bin dir). nil
---                                 relies on the inherited $PATH.
---@field programmer_path? string  STM32_Programmer_CLI. nil searches $PATH, then the
---                                 known CubeProgrammer install locations.
---@field openocd_path? string     openocd. nil searches $PATH.
---@field stlink_path? string      st-flash. nil searches $PATH.
---@field gdb_path? string         arm-none-eabi-gdb. nil searches toolchain_path, then $PATH.
---@field flash_backend? string    Force one backend. nil probes `flash_order`.
---@field flash_order string[]     Probe order, first available wins.
---@field preset? string           CMake preset to build. nil asks, listing the real
---                                 preset names out of CMakePresets.json.
---@field monitor Stm32MonitorConfig
---@field compiler_nvim boolean    Patch compiler.nvim's option list when it is loaded.
---@field float Stm32FloatConfig

---@class Stm32MonitorConfig
---@field baud integer             Line speed for the UART monitor.
---@field device? string           Serial device. nil globs and asks when several match.

---@class Stm32FloatConfig
---@field border string            Border style for the output float.
---@field close_on_success_ms integer  Delay before closing after a clean exit.

---@type Stm32Config
M.defaults = {
  toolchain_path = nil,
  programmer_path = nil,
  openocd_path = nil,
  stlink_path = nil,
  gdb_path = nil,

  flash_backend = nil,
  flash_order = { "cubeprogrammer", "stlink", "openocd" },

  preset = nil,

  monitor = {
    baud = 115200,
    device = nil,
  },

  compiler_nvim = true,

  float = {
    border = "rounded",
    close_on_success_ms = 1500,
  },
}

--- Path options that accept `~` and are expanded to absolute paths by resolve().
local PATH_KEYS = {
  "toolchain_path",
  "programmer_path",
  "openocd_path",
  "stlink_path",
  "gdb_path",
}

--- Whether every entry of `order` names a real flash backend.
---@param order any
---@return boolean
local function valid_order(order)
  if type(order) ~= "table" then
    return false
  end
  for _, name in ipairs(order) do
    if not vim.tbl_contains(M.flash_backends, name) then
      return false
    end
  end
  return true
end

--- Merge user opts over the defaults, validate, and expand path options.
---@param opts? table
---@return Stm32Config
function M.resolve(opts)
  local cfg = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})

  for _, key in ipairs(PATH_KEYS) do
    vim.validate(key, cfg[key], "string", true)
  end
  vim.validate("flash_backend", cfg.flash_backend, function(v)
    return v == nil or vim.tbl_contains(M.flash_backends, v)
  end, "nil or one of: " .. table.concat(M.flash_backends, ", "))
  vim.validate(
    "flash_order",
    cfg.flash_order,
    valid_order,
    "a list of: " .. table.concat(M.flash_backends, ", ")
  )
  vim.validate("preset", cfg.preset, "string", true)
  vim.validate("monitor", cfg.monitor, "table")
  vim.validate("monitor.baud", cfg.monitor.baud, function(value)
    return type(value) == "number" and value > 0 and value % 1 == 0
  end, "a positive integer")
  vim.validate("monitor.device", cfg.monitor.device, "string", true)
  vim.validate("compiler_nvim", cfg.compiler_nvim, "boolean")
  vim.validate("float", cfg.float, "table")
  vim.validate("float.border", cfg.float.border, "string")
  vim.validate("float.close_on_success_ms", cfg.float.close_on_success_ms, "number")

  for _, key in ipairs(PATH_KEYS) do
    if cfg[key] then
      cfg[key] = vim.fs.normalize(cfg[key])
    end
  end

  return cfg
end

return M
