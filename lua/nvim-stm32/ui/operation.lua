local M = {}

local function target_label(project)
  local image = project.images and project.images[1] or {}
  local target = image.target or {}
  return target.mcu or target.family or image.id or "unknown target"
end

local function captured_failure_output(result)
  if result.output and result.output ~= "" then
    return result.output
  end
  if result.error and result.error.output and result.error.output ~= "" then
    return result.error.output
  end
end

function M.current(action, opts, callback)
  opts = vim.deepcopy(opts or {})
  local runtime = require("nvim-stm32")
  local project = opts.project
  if not project then
    local project_err
    project, project_err = require("nvim-stm32.discover.project").resolve(opts.dir)
    if not project then
      vim.notify(project_err.message or tostring(project_err), vim.log.levels.WARN)
      return nil
    end
  end

  if action == "erase" then
    local message = "Mass erase project "
      .. tostring(project.id or project.root)
      .. " on target "
      .. target_label(project)
      .. "?\nThis cannot be undone."
    if vim.fn.confirm(message, "&Erase\n&Cancel", 2) ~= 1 then
      return nil
    end
    opts.confirmed = true
  end

  opts.project = project
  local target = project.images and project.images[1] and project.images[1].target or {}
  local config = vim.tbl_deep_extend("force", vim.deepcopy(runtime.get_config()), opts)
  local presenter
  local handle
  local saw_output = false
  presenter = require("nvim-stm32.ui.float").open(target, config, {
    title = " nvim-stm32 " .. action .. ": " .. target_label(project) .. " ",
    close_on_success = true,
  }, function()
    if handle then
      handle.cancel("window-closed")
    end
  end)

  local caller_output = opts.on_output
  opts.on_output = function(chunk)
    saw_output = saw_output or chunk ~= nil and chunk ~= ""
    presenter:append(chunk)
    if caller_output then
      caller_output(chunk)
    end
  end
  handle = runtime.run(action, opts, function(result)
    if not result.ok then
      local had_output = saw_output
      if not saw_output then
        local output = captured_failure_output(result)
        if output then
          presenter:append(output)
          had_output = true
        end
      end
      if result.error and result.error.message then
        presenter:append((had_output and "\n" or "") .. result.error.message .. "\n")
      end
    end
    presenter:finish(result.ok)
    if callback then
      callback(result)
    end
  end)
  return handle
end

return M
