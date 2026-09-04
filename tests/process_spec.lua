local process = require("nvim-stm32.process")

describe("nvim-stm32.process.run", function()
  local original_system
  local original_schedule
  local original_new_timer
  local calls
  local exit_codes

  before_each(function()
    original_system = process.system
    original_schedule = vim.schedule
    original_new_timer = vim.uv.new_timer
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
    vim.schedule = original_schedule
    vim.uv.new_timer = original_new_timer
  end)

  local function fake_scheduler()
    local scheduled = {}
    vim.schedule = function(callback)
      scheduled[#scheduled + 1] = callback
    end
    return function()
      local pending = scheduled
      scheduled = {}
      for _, callback in ipairs(pending) do
        callback()
      end
    end
  end

  local function fake_timers()
    local timers = {}
    vim.uv.new_timer = function()
      local timer = { closed = false, stopped = false }
      function timer:is_closing()
        return self.closed
      end
      function timer:stop()
        self.stopped = true
      end
      function timer:close()
        self.closed = true
      end
      function timer:unref() end
      function timer:start(_, _, callback)
        self.callback = callback
      end
      timers[#timers + 1] = timer
      return timer
    end
    return timers
  end

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
    assert.equals(2, done.command_index)
    assert.same({
      {
        argv = commands[1],
        output = "stdout 1\nstderr 1\n",
        code = 0,
        signal = 0,
      },
      {
        argv = commands[2],
        output = "stdout 2\nstderr 2\n",
        code = 0,
        signal = 0,
      },
    }, done.commands)
    assert.is_false(done.cancelled)
    assert.is_false(done.timed_out)
    assert.is_false(done.truncated)
    assert.is_true(done.ended_ns >= done.started_ns)
  end)

  it("reports the middle command when it stops on failure", function()
    exit_codes[2] = 1
    local done
    local commands = {
      { "cmake", "--preset", "Debug" },
      { "cmake", "--build", "build/Debug" },
      { "cmake", "--install", "build/Debug" },
    }

    process.run(commands, { cwd = "/work/fw", env = {} }, function(result)
      done = result
    end)

    assert.is_true(vim.wait(100, function()
      return done ~= nil
    end))
    assert.equals(2, #calls)
    assert.same(commands[2], done.command)
    assert.equals(2, done.command_index)
    assert.equals(1, done.code)
    assert.equals("stdout 1\nstderr 1\nstdout 2\nstderr 2\n", done.output)
    assert.same({
      {
        argv = commands[1],
        output = "stdout 1\nstderr 1\n",
        code = 0,
        signal = 0,
      },
      {
        argv = commands[2],
        output = "stdout 2\nstderr 2\n",
        code = 1,
        signal = 0,
      },
    }, done.commands)
  end)

  it("stops a pipeline when a zero-exit child was terminated by a signal", function()
    local done
    process.system = function(cmd, opts, callback)
      calls[#calls + 1] = { cmd = cmd, opts = opts }
      callback({ code = 0, signal = 15 })
      return { pid = 39, kill = function() end }
    end

    process.run({ { "first" }, { "must-not-run" } }, {}, function(result)
      done = result
    end)

    assert.is_true(vim.wait(100, function()
      return done ~= nil
    end))
    assert.equals(1, #calls)
    assert.equals(0, done.code)
    assert.equals(15, done.signal)
    assert.same({ "first" }, done.command)
  end)

  it("stops before the next child when after_command rejects continuation", function()
    local done
    local gate_error = {
      code = "target-mismatch",
      message = "nvim-stm32: target identity does not match",
      operation = "flash",
      hint = "select the connected target",
    }
    local seen

    process.run({ { "identify" }, { "program" } }, {
      after_command = function(command_result)
        seen = vim.deepcopy(command_result)
        return nil, gate_error
      end,
    }, function(result)
      done = result
    end)

    assert.is_true(vim.wait(100, function()
      return done ~= nil
    end))
    assert.equals(1, #calls)
    assert.same({ "identify" }, done.command)
    assert.equals(1, done.command_index)
    assert.same(gate_error, done.error)
    assert.same(done.commands[1], seen)
    assert.equals(1, #done.commands)
  end)

  it(
    "reports the command whose spawn failed without adding a command result",
    function()
      local done
      local count = 0
      process.system = function(_, _, callback)
        count = count + 1
        if count == 1 then
          callback({ code = 0, signal = 0 })
          return { pid = 40, kill = function() end }
        end
        error("spawn denied")
      end

      process.run({ { "first" }, { "second" }, { "third" } }, {}, function(result)
        done = result
      end)

      assert.is_true(vim.wait(100, function()
        return done ~= nil
      end))
      assert.equals(-1, done.code)
      assert.same({ "second" }, done.command)
      assert.equals(2, done.command_index)
      assert.equals(1, #done.commands)
    end
  )

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

    local done
    local handle = process.run({ { "long-job" } }, {}, function(result)
      done = result
    end)

    assert.equals(41, handle.pid())
    assert.equals("running", handle.state())
    assert.is_true(handle.cancel("user"))
    assert.equals(15, killed)
    assert.equals("cancelling", handle.state())
    on_exit({ code = 143, signal = 15 })
    assert.is_true(vim.wait(100, function()
      return handle.state() == "cancelled"
    end))
    assert.equals(1, done.command_index)
    assert.equals(1, #done.commands)
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
    assert.equals(1, done.command_index)
    assert.equals(1, #done.commands)
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

  it("ignores a timeout after its child has exited before continuation runs", function()
    local flush = fake_scheduler()
    local timers = fake_timers()
    local on_exit
    local signals = {}
    local done
    process.system = function(_, _, callback)
      on_exit = callback
      return {
        pid = 46,
        kill = function(_, signal)
          signals[#signals + 1] = signal
        end,
      }
    end

    local handle = process.run(
      { { "short-job" } },
      { timeout_ms = 10 },
      function(result)
        done = result
      end
    )
    on_exit({ code = 0, signal = 0 })
    timers[1].callback()
    flush()

    assert.same({}, signals)
    assert.is_false(done.cancelled)
    assert.is_false(done.timed_out)
    assert.equals("completed", handle.state())
    assert.is_true(timers[1].closed)
  end)

  it("does not cancel a child after observing its successful exit", function()
    local flush = fake_scheduler()
    local timers = fake_timers()
    local on_exit
    local signals = {}
    local done
    process.system = function(_, _, callback)
      on_exit = callback
      return {
        pid = 47,
        kill = function(_, signal)
          signals[#signals + 1] = signal
        end,
      }
    end

    local handle = process.run({ { "short-job" } }, {}, function(result)
      done = result
    end)
    on_exit({ code = 0, signal = 0 })

    assert.is_false(handle.cancel("user"))
    flush()
    assert.same({}, signals)
    assert.is_false(done.cancelled)
    assert.equals(0, #timers)
  end)

  it("does not let an exited command timeout cancel its replacement", function()
    local flush = fake_scheduler()
    local timers = fake_timers()
    local exits = {}
    local signals = { {}, {} }
    local done_count = 0
    process.system = function(_, _, callback)
      local index = #exits + 1
      exits[index] = callback
      return {
        pid = 47 + index,
        kill = function(_, signal)
          signals[index][#signals[index] + 1] = signal
        end,
      }
    end

    process.run({ { "first" }, { "second" } }, { timeout_ms = 10 }, function()
      done_count = done_count + 1
    end)
    exits[1]({ code = 0, signal = 0 })
    flush()
    timers[1].callback()

    assert.same({}, signals[1])
    assert.same({}, signals[2])
    assert.equals(2, #exits)
    exits[2]({ code = 0, signal = 0 })
    flush()
    assert.equals(1, done_count)
    assert.is_true(timers[1].closed)
    assert.is_true(timers[2].closed)
  end)

  it("does not SIGKILL a child after its exit is observed", function()
    local flush = fake_scheduler()
    local timers = fake_timers()
    local on_exit
    local signals = {}
    local done
    process.system = function(_, _, callback)
      on_exit = callback
      return {
        pid = 50,
        kill = function(_, signal)
          signals[#signals + 1] = signal
        end,
      }
    end

    local handle = process.run({ { "long-job" } }, {}, function(result)
      done = result
    end)
    assert.is_true(handle.cancel("user"))
    on_exit({ code = 143, signal = 15 })
    timers[1].callback()
    flush()

    assert.same({ 15 }, signals)
    assert.is_true(done.cancelled)
    assert.is_true(timers[1].closed)
  end)

  it("sends SIGKILL through the active child after its grace timer", function()
    local flush = fake_scheduler()
    local timers = fake_timers()
    local on_exit
    local signals = {}
    process.system = function(_, _, callback)
      on_exit = callback
      return {
        pid = 51,
        kill = function(_, signal)
          signals[#signals + 1] = signal
        end,
      }
    end

    local handle = process.run({ { "long-job" } }, {}, function() end)
    assert.is_true(handle.cancel("user"))
    timers[1].callback()
    on_exit({ code = 137, signal = 9 })
    flush()

    assert.same({ 15, 9 }, signals)
    assert.equals("cancelled", handle.state())
    assert.is_true(timers[1].closed)
  end)

  it("keeps a timeout cancellation when a user cancel follows it", function()
    local flush = fake_scheduler()
    local timers = fake_timers()
    local on_exit
    local signals = {}
    local done_count = 0
    local done
    process.system = function(_, _, callback)
      on_exit = callback
      return {
        pid = 52,
        kill = function(_, signal)
          signals[#signals + 1] = signal
        end,
      }
    end

    local handle = process.run({ { "long-job" } }, { timeout_ms = 10 }, function(result)
      done_count = done_count + 1
      done = result
    end)
    timers[1].callback()

    assert.is_false(handle.cancel("user"))
    assert.same({ 15 }, signals)
    on_exit({ code = 143, signal = 15 })
    flush()
    assert.equals(1, done_count)
    assert.is_true(done.cancelled)
    assert.is_true(done.timed_out)
    assert.is_true(timers[1].closed)
    assert.is_true(timers[2].closed)
  end)
end)
