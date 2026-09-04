local model = require("nvim-stm32.model")

local M = {}

M.backends = {
  cubeprogrammer = require("nvim-stm32.drivers.cubeprogrammer"),
  stlink = require("nvim-stm32.drivers.stlink"),
  openocd = require("nvim-stm32.drivers.openocd"),
}

local function resolution_error(code, message, hint)
  return model.error({
    code = code,
    message = "nvim-stm32: " .. message,
    operation = "flash",
    hint = hint,
  })
end

local function resolve_named(cfg, name)
  local driver = M.backends[name]
  if not driver then
    return nil,
      resolution_error(
        "flash-backend-unknown",
        "unknown flash backend " .. tostring(name),
        "choose cubeprogrammer, stlink, or openocd"
      )
  end
  local available, tool = driver.available(cfg)
  if available and tool then
    return driver, tool
  end
  return nil,
    resolution_error(
      "flash-backend-unavailable",
      "flash backend " .. name .. " is unavailable",
      "install its command-line tool or configure the matching executable path"
    )
end

--- Resolve a programming backend without ever falling through from a pin.
---
--- An operation-local `backend` option is the strongest choice. The configured
--- pin comes next. Only the unpinned path walks `flash_order`.
---@param cfg Stm32Config|table
---@param opts? table
---@return table|nil, string|table
function M.resolve(cfg, opts)
  cfg = cfg or {}
  opts = opts or {}
  local explicit = opts.backend or opts.flash_backend
  local pinned = explicit or cfg.flash_backend
  if pinned then
    return resolve_named(cfg, pinned)
  end

  local order = cfg.flash_order or require("nvim-stm32.config").defaults.flash_order
  for _, name in ipairs(order) do
    local driver = M.backends[name]
    if not driver then
      return nil,
        resolution_error(
          "flash-backend-unknown",
          "unknown flash backend " .. tostring(name),
          "fix flash_order so every entry names a supported backend"
        )
    end
    local available, tool = driver.available(cfg)
    if available and tool then
      return driver, tool
    end
  end

  return nil,
    resolution_error(
      "flash-backend-unavailable",
      "no flash backend in flash_order is available",
      "install CubeProgrammer, stlink, or OpenOCD, or configure an executable path"
    )
end

return M
