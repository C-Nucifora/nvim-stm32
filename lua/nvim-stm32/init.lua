--- nvim-stm32: build, flash, monitor and debug STM32 projects from Neovim.
---
--- The plugin finds the project and the chip on its own, so there is nothing to
--- configure per firmware folder:
---
---     require("nvim-stm32").setup()
---
--- Options are documented in the README and typed as |Stm32Config|.
local config = require("nvim-stm32.config")

local M = {}

--- The resolved configuration from the last setup() call, or nil.
---@type Stm32Config|nil
M.config = nil

--- Configure the plugin. Idempotent; the last call wins.
---@param opts? table  See |Stm32Config|.
---@return table  this module, so calls can be chained
function M.setup(opts)
  M.config = config.resolve(opts)
  return M
end

--- The resolved configuration, falling back to the defaults when setup() has not
--- run. Commands and health checks go through this so they work in a config that
--- lazy-loads the plugin on its commands.
---@return Stm32Config
function M.get_config()
  return M.config or config.resolve()
end

return M
