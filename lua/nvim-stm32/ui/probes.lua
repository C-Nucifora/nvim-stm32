local probes = require("nvim-stm32.probes")
local session = require("nvim-stm32.session")

local M = {}

local function current_project(opts)
  if opts.project then
    return opts.project
  end
  return require("nvim-stm32.discover.project").resolve(opts.dir)
end

local function label(probe)
  if probe.firmware then
    return ("%s (%s)"):format(probe.serial, probe.firmware)
  end
  return probe.serial
end

local function notify_error(err)
  vim.notify(err.message or tostring(err), vim.log.levels.ERROR)
end

--- Enumerate probes and save a selection for the current project.
---@param opts? table
---@param callback? fun(probe: table, project: table)
---@return table|nil handle
function M.select(opts, callback)
  if type(opts) == "function" then
    callback, opts = opts, nil
  end
  opts = opts or {}
  local project, project_err = current_project(opts)
  if not project then
    vim.notify(project_err.message or tostring(project_err), vim.log.levels.WARN)
    return nil
  end

  local cfg =
    vim.tbl_deep_extend("force", require("nvim-stm32").get_config(), opts.config or {})
  return probes.enumerate(cfg, function(list, enumeration_err)
    if not list then
      notify_error(enumeration_err)
      return
    end
    if #list == 0 then
      local _, missing_err = probes.resolve(project, list)
      notify_error(missing_err)
      return
    end

    local labels = vim.tbl_map(label, list)
    vim.ui.select(labels, { prompt = "STM32 probe" }, function(choice, index)
      if not choice then
        return
      end
      local selected = index and list[index] or nil
      if not selected then
        for candidate_index, candidate_label in ipairs(labels) do
          if candidate_label == choice then
            selected = list[candidate_index]
            break
          end
        end
      end
      if not selected then
        return
      end
      session.select(project, { probe_serial = selected.serial })
      if callback then
        callback(selected, project)
      end
    end)
  end)
end

return M
