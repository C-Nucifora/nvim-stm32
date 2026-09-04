local process = require("nvim-stm32.process")

describe("nvim-stm32.process.run", function()
  local original_system
  local calls
  local exit_codes

  before_each(function()
    original_system = process.system
    calls = {}
    exit_codes = { 0, 0 }

    process.system = function(cmd, opts, callback)
      calls[#calls + 1] = { cmd = cmd, opts = opts }
      local index = #calls
      opts.stdout(nil, "stdout " .. index .. "\n")
      opts.stderr(nil, "stderr " .. index .. "\n")
      callback({ code = exit_codes[index], signal = 0 })
      return { kill = function() end }
    end
  end)

  after_each(function()
    process.system = original_system
  end)

  it("runs commands in order with the requested cwd and environment", function()
    local output = {}
    local done
    local commands = {
      { "cmake", "--preset", "Debug" },
      { "cmake", "--build", "build/Debug" },
    }

    process.run(commands, {
      cwd = "/work/fw",
      env = { PATH = "/toolchain:/usr/bin" },
      on_output = function(chunk)
        output[#output + 1] = chunk
      end,
    }, function(result)
      done = result
    end)

    assert.is_true(vim.wait(100, function()
      return done ~= nil
    end))
    assert.same(commands[1], calls[1].cmd)
    assert.same(commands[2], calls[2].cmd)
    assert.equals("/work/fw", calls[1].opts.cwd)
    assert.equals("/toolchain:/usr/bin", calls[1].opts.env.PATH)
    assert.same({ "stdout 1\n", "stderr 1\n", "stdout 2\n", "stderr 2\n" }, output)
    assert.equals(0, done.code)
    assert.equals(0, done.signal)
    assert.equals("stdout 1\nstderr 1\nstdout 2\nstderr 2\n", done.output)
    assert.same(commands[2], done.command)
    assert.is_false(done.cancelled)
    assert.is_false(done.timed_out)
    assert.is_false(done.truncated)
    assert.is_true(done.ended_ns >= done.started_ns)
  end)

  it("stops after the first failed command", function()
    exit_codes[1] = 1
    local done
    local commands = {
      { "cmake", "--preset", "Debug" },
      { "cmake", "--build", "build/Debug" },
    }

    process.run(commands, { cwd = "/work/fw", env = {} }, function(result)
      done = result
    end)

    assert.is_true(vim.wait(100, function()
      return done ~= nil
    end))
    assert.equals(1, #calls)
    assert.same(commands[1], done.command)
    assert.equals(1, done.code)
    assert.equals("stdout 1\nstderr 1\n", done.output)
  end)

  it("forwards stream chunks outside fast-event context", function()
    local done
    local output_was_fast
    process.system = function(_, opts, callback)
      local timer = vim.uv.new_timer()
      timer:start(0, 0, function()
        opts.stdout(nil, "streamed\n")
        timer:stop()
        timer:close()
        callback({ code = 0, signal = 0 })
      end)
      return timer
    end

    process.run({ { "make" } }, {
      on_output = function()
        output_was_fast = vim.in_fast_event()
      end,
    }, function(result)
      done = result
    end)

    assert.is_true(vim.wait(100, function()
      return done ~= nil
    end))
    assert.is_false(output_was_fast)
  end)

  it("returns a handle that cancels only the active child", function()
    local killed
    local child
    local on_exit
    process.system = function(_, _, callback)
      on_exit = callback
      child = {
        pid = 41,
        kill = function(_, signal)
          killed = signal
        end,
      }
      return child
    end

    local handle = process.run({ { "long-job" } }, {}, function() end)

    assert.equals(41, handle.pid())
    assert.equals("running", handle.state())
    assert.is_true(handle.cancel("user"))
    assert.equals(15, killed)
    assert.equals("cancelling", handle.state())
    on_exit({ code = 143, signal = 15 })
    assert.is_true(vim.wait(100, function()
      return handle.state() == "cancelled"
    end))
  end)

  it("bounds captured output but keeps every streamed chunk", function()
    local streamed = {}
    local done
    process.system = function(_, opts, callback)
      opts.stdout(nil, "12345")
      opts.stderr(nil, "67890")
      callback({ code = 0, signal = 0 })
      return { pid = 42, kill = function() end }
    end

    process.run({ { "job" } }, {
      max_output_bytes = 6,
      on_output = function(chunk)
        streamed[#streamed + 1] = chunk
      end,
    }, function(result)
      done = result
    end)

    assert.is_true(vim.wait(100, function()
      return done ~= nil
    end))
    assert.same({ "12345", "67890" }, streamed)
    assert.equals("567890", done.output)
    assert.is_true(done.truncated)
  end)

  it("uses CommandSpec fields and prepends an option toolchain to PATH", function()
    local call
    local done
    process.system = function(cmd, opts, callback)
      call = { cmd = cmd, opts = opts }
      callback({ code = 0, signal = 0 })
      return { pid = 43, kill = function() end }
    end

    process.run({
      {
        argv = { "cmake", "--build", "build" },
        cwd = "/firmware",
        env = { PATH = "/usr/bin", LANG = "C" },
      },
    }, { toolchain_path = "/opt/arm/bin" }, function(result)
      done = result
    end)

    assert.is_true(vim.wait(100, function()
      return done ~= nil
    end))
    assert.same({ "cmake", "--build", "build" }, call.cmd)
    assert.equals("/firmware", call.opts.cwd)
    assert.equals("/opt/arm/bin:/usr/bin", call.opts.env.PATH)
    assert.equals("C", call.opts.env.LANG)
  end)

  it("marks a timed out active child cancelled and calls back once", function()
    local callback
    local killed
    local done_count = 0
    local done
    process.system = function(_, _, on_exit)
      callback = on_exit
      return {
        pid = 44,
        kill = function(_, signal)
          killed = signal
        end,
      }
    end

    local handle = process.run({ { "long-job" } }, { timeout_ms = 1 }, function(result)
      done_count = done_count + 1
      done = result
    end)

    assert.is_true(vim.wait(100, function()
      return killed == 15
    end))
    callback({ code = 143, signal = 15 })
    assert.is_true(vim.wait(100, function()
      return done ~= nil
    end))
    assert.equals(1, done_count)
    assert.is_true(done.cancelled)
    assert.is_true(done.timed_out)
    assert.equals("cancelled", handle.state())
  end)

  it("completes a zero-exit stream exactly once", function()
    local done_count = 0
    local done
    process.system = function(_, opts, callback)
      opts.stdout(nil, "attached\n")
      callback({ code = 0, signal = 0 })
      return { pid = 45, kill = function() end }
    end

    local handle = process.run({ { "monitor" } }, { streaming = true }, function(result)
      done_count = done_count + 1
      done = result
    end)

    assert.is_true(vim.wait(100, function()
      return done ~= nil
    end))
    assert.equals(1, done_count)
    assert.equals("completed", handle.state())
    assert.equals("attached\n", done.output)
  end)
end)
