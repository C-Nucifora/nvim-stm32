local M = { system = vim.system }

--- Run argv arrays in sequence, stopping at the first failure.
---@param commands string[][]
---@param opts { cwd?: string, env?: table<string, string>, on_output?: fun(chunk: string) }
---@param callback fun(result: { code: integer, signal: integer, output: string, command: string[]|nil })
function M.run(commands, opts, callback)
  opts = opts or {}
  local chunks = {}
  local index = 0

  local function finish(code, signal, command)
    callback({
      code = code,
      signal = signal,
      output = table.concat(chunks),
      command = command,
    })
  end

  local run_next
  run_next = function()
    index = index + 1
    local command = commands[index]
    if not command then
      finish(0, 0, commands[index - 1])
      return
    end

    local function on_stream(_, chunk)
      if not chunk or chunk == "" then
        return
      end
      chunks[#chunks + 1] = chunk
      if opts.on_output then
        if vim.in_fast_event() then
          vim.schedule(function()
            opts.on_output(chunk)
          end)
        else
          opts.on_output(chunk)
        end
      end
    end

    M.system(command, {
      cwd = opts.cwd,
      env = opts.env,
      text = true,
      stdout = on_stream,
      stderr = on_stream,
    }, function(result)
      vim.schedule(function()
        if result.code ~= 0 then
          finish(result.code, result.signal, command)
          return
        end
        run_next()
      end)
    end)
  end

  run_next()
end

return M
