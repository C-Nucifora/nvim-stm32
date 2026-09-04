local devices = require("nvim-stm32.monitor.devices")
local model = require("nvim-stm32.model")
local session = require("nvim-stm32.session")
local uart = require("nvim-stm32.drivers.uart")

local M = {}

local next_plan_id = 0

local function monitor_error(code, message, command, output)
  return model.error({
    code = code,
    message = "nvim-stm32: " .. message,
    operation = "monitor",
    command = command,
    output = output,
    hint = "check the selected serial device, baud rate, and monitor output",
  })
end

local function selected_device(project, opts)
  local monitor_config = type(opts.monitor) == "table" and opts.monitor or {}
  if opts.device ~= nil then
    local device, err = devices.validate(opts.device, opts)
    return device, err, "explicit"
  end
  if monitor_config.device ~= nil then
    local device, err = devices.validate(monitor_config.device, opts)
    return device, err, "configured"
  end

  local remembered = session.get(project).monitor_device
  if remembered ~= nil then
    local device = devices.validate(remembered, opts)
    if device then
      return device, nil, "session"
    end
  end

  local candidates, candidates_err = devices.list(opts)
  if not candidates then
    return nil, candidates_err
  end
  if #candidates == 1 then
    return candidates[1], nil, "discovered"
  end
  local err = monitor_error(
    "monitor-device-required",
    #candidates == 0 and "no serial device was found"
      or "select one of the discovered serial devices"
  )
  err.candidates = vim.deepcopy(candidates)
  return nil, err
end

function M.plan(project, opts)
  opts = vim.deepcopy(opts or {})
  local ok, copied = pcall(model.project, project)
  if not ok then
    return nil, monitor_error("project-invalid", tostring(copied))
  end

  local platform = devices.platform(opts)
  if not devices.pattern(platform) then
    return nil,
      monitor_error(
        "monitor-platform-unsupported",
        "UART monitoring is unsupported on " .. tostring(platform)
      )
  end
  local device, device_err, source = selected_device(copied, opts)
  if not device then
    return nil, device_err
  end
  local monitor_config = type(opts.monitor) == "table" and opts.monitor or {}
  local baud = opts.baud or monitor_config.baud or 115200
  local commands, command_err = uart.commands(device, baud, platform)
  if not commands then
    return nil, command_err
  end

  next_plan_id = next_plan_id + 1
  return model.plan({
    id = "monitor-" .. next_plan_id,
    kind = "monitor",
    project_id = copied.id,
    images = vim.tbl_map(function(image)
      return image.id
    end, copied.images),
    commands = commands,
    locks = { { kind = "serial-device", id = device } },
    reset_policy = "none",
    metadata = {
      project = copied,
      platform = platform,
      device = device,
      baud = baud,
      selection_source = source,
    },
  })
end

function M.validate(plan)
  if type(plan.metadata) ~= "table" then
    error("plan.metadata: expected table")
  end
  plan.metadata.project = model.project(plan.metadata.project)
  if type(plan.metadata.platform) ~= "string" then
    error("plan.metadata.platform: expected string")
  end
  if type(plan.metadata.device) ~= "string" or plan.metadata.device == "" then
    error("plan.metadata.device: expected non-empty string")
  end
  if
    type(plan.metadata.baud) ~= "number"
    or plan.metadata.baud <= 0
    or plan.metadata.baud % 1 ~= 0
  then
    error("plan.metadata.baud: expected positive integer")
  end
end

function M.preflight(plan, opts)
  local device, device_err = devices.validate(plan.metadata.device, opts)
  if not device then
    return nil, device_err
  end
  local expected_commands, command_err =
    uart.commands(device, plan.metadata.baud, plan.metadata.platform)
  if not expected_commands then
    return nil, command_err
  end
  if
    plan.kind ~= "monitor"
    or plan.project_id ~= plan.metadata.project.id
    or plan.reset_policy ~= "none"
    or #plan.locks ~= 1
    or plan.locks[1].kind ~= "serial-device"
    or plan.locks[1].id ~= device
    or not vim.deep_equal(plan.commands, expected_commands)
  then
    return nil,
      monitor_error(
        "monitor-plan-tampered",
        "planned UART commands or device ownership changed before execution"
      )
  end
  return true
end

local function result(plan, process_result, ok, status, err)
  return model.result({
    ok = ok,
    code = process_result.code or 0,
    output = process_result.output or "",
    artifacts = {},
    error = err,
    duration_ms = process_result.started_ns
        and process_result.ended_ns
        and (process_result.ended_ns - process_result.started_ns) / 1000000
      or nil,
    started_ns = process_result.started_ns,
    finished_ns = process_result.ended_ns,
    metadata = {
      operation_id = plan.id,
      device = plan.metadata.device,
      baud = plan.metadata.baud,
      status = status,
    },
  })
end

function M.complete(plan, process_result)
  if process_result.timed_out then
    local setup = process_result.command_index == 1
    return result(
      plan,
      process_result,
      false,
      setup and "setup-failed" or "disconnected",
      monitor_error(
        setup and "monitor-setup-failed" or "monitor-disconnected",
        setup and "serial device setup timed out" or "serial monitor timed out",
        process_result.command,
        process_result.output
      )
    )
  end
  if process_result.cancelled then
    return result(
      plan,
      process_result,
      false,
      "stopped",
      monitor_error(
        "monitor-stopped",
        "monitor stopped",
        process_result.command,
        process_result.output
      )
    )
  end
  if process_result.code ~= 0 then
    local setup = process_result.command_index == 1
    return result(
      plan,
      process_result,
      false,
      setup and "setup-failed" or "disconnected",
      monitor_error(
        setup and "monitor-setup-failed" or "monitor-disconnected",
        setup and "could not configure the serial device"
          or "serial device disconnected",
        process_result.command,
        process_result.output
      )
    )
  end
  return result(plan, process_result, true, "ended")
end

function M.hooks()
  return {
    validate = M.validate,
    preflight = M.preflight,
    complete = M.complete,
  }
end

function M.execute(plan, opts, callback)
  opts = vim.tbl_extend("force", vim.deepcopy(opts or {}), { streaming = true })
  return require("nvim-stm32.operation").execute(plan, opts, M.hooks(), callback)
end

return M
