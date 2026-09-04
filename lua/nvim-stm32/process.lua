local M = { system = vim.system }

local DEFAULT_MAX_OUTPUT_BYTES = 1024 * 1024
local next_operation_id = 0

local function close_timer(timer)
  if not timer or timer:is_closing() then
    return
  end
  timer:stop()
  timer:close()
end

local function schedule(callback)
  if vim.in_fast_event() then
    vim.schedule(callback)
  else
    callback()
  end
end

local function normalize(command)
  if command.argv then
    return command
  end
  return { argv = command }
end

local function command_options(command, opts)
  local env = vim.tbl_extend("force", {}, opts.env or {}, command.env or {})
  local toolchain_path = command.toolchain_path or opts.toolchain_path
  if toolchain_path and toolchain_path ~= "" then
    local path = env.PATH or vim.env.PATH or ""
    env.PATH = toolchain_path .. ":" .. path
  end

  return {
    cwd = command.cwd or opts.cwd,
    env = env,
    text = true,
  }
end

--- Run CommandSpec records or argv arrays in sequence, stopping at the first failure.
---@param commands (table|string[])[]
---@param opts { cwd?: string, env?: table<string, string>, on_output?: fun(chunk: string), max_output_bytes?: integer, timeout_ms?: integer, streaming?: boolean, toolchain_path?: string }
---@param callback fun(result: { code: integer, signal: integer, output: string, command: string[]|nil, cancelled: boolean, timed_out: boolean, truncated: boolean, started_ns: integer, ended_ns: integer })
---@return { id: integer, state: fun(): string, cancel: fun(reason?: string): boolean, pid: fun(): integer|nil }
function M.run(commands, opts, callback)
  opts = opts or {}
  next_operation_id = next_operation_id + 1

  local handle = { id = next_operation_id }
  local state = "pending"
  local active_child
  local kill_timer
  local timeout_timer
  local index = 0
  local output = ""
  local truncated = false
  local cancelled = false
  local timed_out = false
  local finished = false
  local last_command
  local command_output = ""
  local command_results = {}
  local started_ns = vim.uv.hrtime()
  local max_output_bytes = opts.max_output_bytes or DEFAULT_MAX_OUTPUT_BYTES

  local function clear_child_timers()
    close_timer(kill_timer)
    kill_timer = nil
    close_timer(timeout_timer)
    timeout_timer = nil
  end

  local function finish(code, signal, command)
    if finished then
      return
    end
    finished = true
    clear_child_timers()
    active_child = nil
    state = cancelled and "cancelled" or "completed"
    callback({
      code = code or 0,
      signal = signal or 0,
      output = output,
      command = command or last_command,
      commands = vim.deepcopy(command_results),
      cancelled = cancelled,
      timed_out = timed_out,
      truncated = truncated,
      started_ns = started_ns,
      ended_ns = vim.uv.hrtime(),
    })
  end

  local function append_output(chunk)
    if not chunk or chunk == "" then
      return
    end

    output = output .. chunk
    if #output > max_output_bytes then
      output = output:sub(#output - max_output_bytes + 1)
      truncated = true
    end
    command_output = command_output .. chunk
    if #command_output > max_output_bytes then
      command_output = command_output:sub(#command_output - max_output_bytes + 1)
    end

    if opts.on_output then
      schedule(function()
        opts.on_output(chunk)
      end)
    end
  end

  local function cancel_active(reason, expected_child)
    if finished or not active_child or state == "cancelling" then
      return false
    end
    if expected_child and active_child ~= expected_child then
      return false
    end

    if reason == "timeout" then
      timed_out = true
    end
    cancelled = true
    state = "cancelling"
    local child = active_child
    child:kill(15)

    close_timer(kill_timer)
    local timer = vim.uv.new_timer()
    kill_timer = timer
    timer:unref()
    timer:start(1000, 0, function()
      if not timer:is_closing() then
        timer:close()
      end
      if kill_timer == timer then
        kill_timer = nil
      end
      if not finished and active_child == child then
        child:kill(9)
      end
    end)
    return true
  end

  function handle.state()
    return state
  end

  function handle.cancel(reason)
    return cancel_active(reason)
  end

  function handle.pid()
    return active_child and active_child.pid or nil
  end

  local run_next
  run_next = function()
    if finished then
      return
    end

    index = index + 1
    local command = commands[index]
    if not command then
      finish(0, 0, last_command)
      return
    end

    command = normalize(command)
    last_command = command.argv
    command_output = ""
    state = "running"
    local child
    local early_exit
    local function on_stream(_, chunk)
      append_output(chunk)
    end
    local function retire_child(result)
      if finished or active_child ~= child then
        return
      end
      active_child = nil
      clear_child_timers()
      command_results[#command_results + 1] = {
        argv = vim.deepcopy(command.argv),
        output = command_output,
        code = result.code or 0,
        signal = result.signal or 0,
      }
      vim.schedule(function()
        if finished then
          return
        end
        if cancelled or result.code ~= 0 then
          finish(result.code, result.signal, command.argv)
        else
          run_next()
        end
      end)
    end
    local function on_exit(result)
      if not child then
        early_exit = result
        return
      end
      retire_child(result)
    end

    local ok, system_or_err = pcall(
      M.system,
      command.argv,
      vim.tbl_extend("force", command_options(command, opts), {
        stdout = on_stream,
        stderr = on_stream,
      }),
      on_exit
    )
    if not ok then
      finish(-1, 0, command.argv)
      return
    end

    child = system_or_err
    active_child = child
    if early_exit then
      retire_child(early_exit)
      return
    end
    local timeout_ms = command.timeout_ms or opts.timeout_ms
    if timeout_ms and timeout_ms > 0 then
      local timer = vim.uv.new_timer()
      timeout_timer = timer
      timer:unref()
      timer:start(timeout_ms, 0, function()
        if timeout_timer == timer then
          timeout_timer = nil
        end
        if not timer:is_closing() then
          timer:close()
        end
        cancel_active("timeout", child)
      end)
    end
  end

  run_next()
  return handle
end

return M
