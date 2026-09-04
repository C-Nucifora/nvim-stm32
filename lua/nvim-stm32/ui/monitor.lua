local M = {}

local function target(project)
  local image = project.images and project.images[1] or {}
  return image.target or {}
end

local function notify_error(err)
  vim.notify(err and err.message or tostring(err), vim.log.levels.WARN)
end

function M.current(opts, callback)
  opts = vim.deepcopy(opts or {})
  local runtime = require("nvim-stm32")
  local operations = require("nvim-stm32.operations.monitor")
  local project = opts.project
  if not project then
    local project_err
    project, project_err = require("nvim-stm32.discover.project").resolve(opts.dir)
    if not project then
      notify_error(project_err)
      return nil
    end
  end

  local resolved =
    vim.tbl_deep_extend("force", vim.deepcopy(runtime.get_config()), opts)
  resolved.project = nil
  local function start(run_opts)
    local plan, plan_err = operations.plan(project, run_opts)
    if not plan then
      notify_error(plan_err)
      return nil
    end

    require("nvim-stm32.session").select(project, {
      monitor_device = plan.metadata.device,
    })
    local presenter
    local handle
    local saw_output = false
    local last_byte
    presenter = require("nvim-stm32.ui.float").open(target(project), resolved, {
      title = " nvim-stm32 monitor: " .. plan.metadata.device .. " ",
      close_on_success = false,
    }, function()
      if handle then
        handle.cancel("window-closed")
      end
    end)

    local caller_output = run_opts.on_output
    run_opts.on_output = function(chunk)
      if chunk and chunk ~= "" then
        saw_output = true
        last_byte = chunk:sub(-1)
      end
      presenter:append(chunk)
      if caller_output then
        caller_output(chunk)
      end
    end
    handle = operations.execute(plan, run_opts, function(result)
      if not saw_output and result.error and result.error.output ~= "" then
        local output = result.error.output
        if output then
          run_opts.on_output(output)
        end
      end

      local ending
      if result.metadata and result.metadata.status == "stopped" then
        ending = "monitor stopped"
      elseif result.ok then
        ending = "monitor ended"
      elseif result.error and result.error.message then
        ending = result.error.message
      else
        ending = "nvim-stm32: monitor failed"
      end
      local separator = saw_output and last_byte ~= "\n" and "\n" or ""
      presenter:append(separator .. ending .. "\n")
      presenter:finish(false)
      if callback then
        callback(result)
      end
    end)
    return handle
  end

  local plan, plan_err = operations.plan(project, resolved)
  if plan then
    resolved.device = plan.metadata.device
    return start(resolved)
  end
  if plan_err.code ~= "monitor-device-required" or #plan_err.candidates < 2 then
    notify_error(plan_err)
    return nil
  end

  vim.ui.select(
    plan_err.candidates,
    { prompt = "Select UART serial device:" },
    function(choice)
      if not choice then
        return
      end
      local selected_opts = vim.deepcopy(resolved)
      selected_opts.device = choice
      start(selected_opts)
    end
  )
  return nil
end

return M
