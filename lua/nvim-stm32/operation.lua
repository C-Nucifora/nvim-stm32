local locks = require("nvim-stm32.locks")
local model = require("nvim-stm32.model")
local process = require("nvim-stm32.process")

local M = {}

local function operation_error(code, message, plan, process_result)
  return model.error({
    code = code,
    message = "nvim-stm32: " .. message,
    operation = plan and plan.kind or "operation",
    command = process_result and process_result.command or nil,
    output = process_result and process_result.output or nil,
    hint = "inspect the operation output and try again",
  })
end

local function safe_handle(id)
  return {
    id = id,
    state = function()
      return "completed"
    end,
    cancel = function()
      return false
    end,
    pid = function()
      return nil
    end,
  }
end

local function result_for_failure(plan, err, process_result)
  process_result = process_result or {}
  return model.result({
    ok = false,
    code = process_result.code or -1,
    output = process_result.output or "",
    artifacts = {},
    error = err,
    duration_ms = process_result.started_ns
        and process_result.ended_ns
        and (process_result.ended_ns - process_result.started_ns) / 1000000
      or nil,
    started_ns = process_result.started_ns,
    finished_ns = process_result.ended_ns,
    metadata = { operation_id = plan and plan.id or nil },
  })
end

local function unavailable_tool(plan)
  local checked = {}
  for _, command in ipairs(plan.commands) do
    local executable = command.argv[1]
    if not checked[executable] then
      checked[executable] = true
      if vim.fn.executable(executable) ~= 1 then
        return operation_error(
          plan.kind .. "-tool-unavailable",
          "required " .. plan.kind .. " tool not found: " .. executable,
          plan
        )
      end
    end
  end
end

local function structured_hook_error(code, value, plan, process_result)
  if type(value) == "table" then
    local ok, err = pcall(model.error, value)
    if ok then
      return err
    end
  end
  return operation_error(code, tostring(value), plan, process_result)
end

function M.execute(plan, opts, hooks, callback)
  opts = opts or {}
  hooks = hooks or {}
  callback = callback or function() end
  local completed = false
  local release
  local function complete(result)
    if completed then
      return
    end
    completed = true
    local ok, callback_err = pcall(callback, vim.deepcopy(result))
    if release then
      release()
      release = nil
    end
    if not ok then
      error(callback_err)
    end
  end

  local valid, copied_or_err = pcall(model.plan, plan)
  if valid and hooks.validate then
    local hook_ok, hook_result, hook_err = pcall(hooks.validate, copied_or_err)
    if not hook_ok then
      valid = false
      copied_or_err = hook_result
    elseif hook_result == nil and hook_err ~= nil then
      complete(result_for_failure(copied_or_err, hook_err))
      return safe_handle(copied_or_err.id)
    end
  end
  if not valid then
    local err = operation_error("operation-plan-invalid", tostring(copied_or_err))
    complete(result_for_failure(nil, err))
    return safe_handle(nil)
  end
  local copied = copied_or_err

  local tool_err = unavailable_tool(copied)
  if tool_err then
    complete(result_for_failure(copied, tool_err))
    return safe_handle(copied.id)
  end

  local cfg = vim.tbl_deep_extend(
    "force",
    vim.deepcopy(require("nvim-stm32").get_config()),
    vim.deepcopy(opts)
  )

  local lock_err
  release, lock_err = locks.acquire(copied.id, copied.locks)
  if not release then
    complete(result_for_failure(copied, lock_err))
    return safe_handle(copied.id)
  end

  if hooks.preflight then
    local preflight_ok, preflight_result, preflight_err =
      pcall(hooks.preflight, copied, cfg)
    if not preflight_ok then
      preflight_err =
        structured_hook_error("operation-preflight-failed", preflight_result, copied)
    elseif preflight_result == nil and preflight_err ~= nil then
      preflight_err =
        structured_hook_error("operation-preflight-failed", preflight_err, copied)
    else
      preflight_err = nil
    end
    if preflight_err then
      complete(result_for_failure(copied, preflight_err))
      return safe_handle(copied.id)
    end
  end

  local process_opts = {
    cwd = copied.metadata and copied.metadata.project and copied.metadata.project.root
      or opts.cwd,
    env = vim.tbl_extend("force", {}, opts.env or {}),
    toolchain_path = cfg.toolchain_path,
    on_output = opts.on_output,
    max_output_bytes = opts.max_output_bytes,
    timeout_ms = opts.timeout_ms,
    streaming = opts.streaming,
  }
  if hooks.after_command then
    process_opts.after_command = function(command_result)
      local ok, continue, err = pcall(hooks.after_command, copied, command_result, cfg)
      if not ok then
        return nil,
          structured_hook_error(
            "operation-continuation-failed",
            continue,
            copied,
            { command = command_result.argv, output = command_result.output }
          )
      end
      return continue, err
    end
  end

  local started, handle_or_err = pcall(
    process.run,
    copied.commands,
    process_opts,
    function(process_result)
      if completed then
        return
      end
      if process_result.error then
        complete(result_for_failure(copied, process_result.error, process_result))
        return
      end
      local hook_ok, result, result_err =
        pcall(hooks.complete, copied, process_result, cfg)
      if not hook_ok then
        result_err = structured_hook_error(
          "operation-completion-failed",
          result,
          copied,
          process_result
        )
        result = nil
      elseif not result then
        result_err = structured_hook_error(
          "operation-completion-failed",
          result_err or "operation completion failed",
          copied,
          process_result
        )
      end
      complete(result or result_for_failure(copied, result_err, process_result))
    end
  )
  if not started then
    local err = operation_error("process-start-failed", tostring(handle_or_err), copied)
    complete(result_for_failure(copied, err))
    return safe_handle(copied.id)
  end
  return handle_or_err or safe_handle(copied.id)
end

local function analyze_hooks()
  local analyze = require("nvim-stm32.operations.analyze")
  return {
    validate = function(plan)
      if type(plan.metadata) ~= "table" then
        error("plan.metadata: expected table")
      end
      if type(plan.metadata.inputs) ~= "table" then
        error("plan.metadata.inputs: expected table")
      end
    end,
    preflight = analyze.preflight,
    complete = analyze.complete,
  }
end

function M.run(plan, opts, callback)
  local hooks
  if type(plan) == "table" and plan.kind == "build" then
    local build = require("nvim-stm32.operations.build")
    hooks = {
      validate = build.validate,
      preflight = build.preflight,
      complete = build.complete,
    }
  elseif type(plan) == "table" and plan.kind == "analyze" then
    hooks = analyze_hooks()
  elseif type(plan) == "table" and plan.kind == "monitor" then
    local monitor = require("nvim-stm32.operations.monitor")
    hooks = monitor.hooks()
    opts = vim.tbl_extend("force", vim.deepcopy(opts or {}), { streaming = true })
  else
    hooks = {
      validate = function(copied)
        error("unsupported operation kind " .. copied.kind)
      end,
      complete = function() end,
    }
  end
  return M.execute(plan, opts, hooks, callback)
end

return M
