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

--- Return the in-memory session for a project root or resolved project.
---@param root table|string
---@return table
function M.get_session(root)
  return require("nvim-stm32.session").get(root)
end

--- Resolve the STM32 project containing a directory.
---@param dir? string
---@return table|nil, table|nil
function M.resolve_project(dir)
  return require("nvim-stm32.discover.project").resolve(dir)
end

local function operation_module(kind)
  if kind ~= "build" then
    return nil,
      require("nvim-stm32.model").error({
        code = "operation-kind-unsupported",
        message = "nvim-stm32: unsupported operation kind " .. tostring(kind),
        operation = tostring(kind),
        hint = "use the build operation",
      })
  end
  return require("nvim-stm32.operations.build")
end

--- Plan an operation without running it.
---@param kind string
---@param opts? table
---@return table|nil, table|nil
function M.plan(kind, opts)
  opts = vim.deepcopy(opts or {})
  local operations, kind_err = operation_module(kind)
  if not operations then
    return nil, kind_err
  end
  local project = opts.project
  if not project then
    local project_err
    project, project_err = M.resolve_project(opts.dir)
    if not project then
      return nil, project_err
    end
  end
  opts.project = nil
  local resolved = vim.tbl_deep_extend("force", M.get_config(), opts)
  resolved.configuration = opts.configuration or opts.preset or resolved.preset
  return operations.plan(project, resolved)
end

--- Plan and run an operation.
---@param kind string
---@param opts? table
---@param callback? function
---@return table|nil, table|nil
function M.run(kind, opts, callback)
  local plan, plan_err = M.plan(kind, opts)
  if not plan then
    return nil, plan_err
  end
  return require("nvim-stm32.operation").run(plan, opts, callback)
end

return M
