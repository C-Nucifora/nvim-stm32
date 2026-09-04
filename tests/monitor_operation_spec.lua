local locks = require("nvim-stm32.locks")
local model = require("nvim-stm32.model")
local process = require("nvim-stm32.process")
local session = require("nvim-stm32.session")

local function project(root)
  return model.project({
    id = root,
    root = root,
    kind = "cmake_presets",
    build = { adapter = "cmake_presets", marker = root .. "/CMakePresets.json" },
    images = {
      {
        id = "application",
        name = "application",
        target = { mcu = "STM32F429ZITx" },
      },
    },
  })
end

local function device_opts(paths)
  paths = paths or { "/dev/ttyACM0" }
  local present = {}
  for _, path in ipairs(paths) do
    present[path] = true
  end
  return {
    platform = "Linux",
    glob = function()
      return vim.deepcopy(paths)
    end,
    stat = function(path)
      return present[path] and { type = "char" } or nil
    end,
  }
end

describe("nvim-stm32 monitor operation plans", function()
  local monitor = require("nvim-stm32.operations.monitor")
  local root

  before_each(function()
    root = vim.fn.tempname()
    session.clear()
  end)

  after_each(function()
    session.clear()
  end)

  it(
    "uses explicit, configured, session, and sole-discovered devices in order",
    function()
      session.select(root, { monitor_device = "/dev/ttyACM2" })
      local opts = device_opts({
        "/dev/ttyACM0",
        "/dev/ttyACM1",
        "/dev/ttyACM2",
        "/dev/ttyACM3",
      })
      opts.device = "/dev/ttyACM3"
      opts.monitor = { device = "/dev/ttyACM1", baud = 57600 }
      local explicit = assert(monitor.plan(project(root), opts))
      assert.equals("/dev/ttyACM3", explicit.metadata.device)
      assert.equals(57600, explicit.metadata.baud)

      opts.device = nil
      local configured = assert(monitor.plan(project(root), opts))
      assert.equals("/dev/ttyACM1", configured.metadata.device)

      opts.monitor.device = nil
      local remembered = assert(monitor.plan(project(root), opts))
      assert.equals("/dev/ttyACM2", remembered.metadata.device)

      session.clear(root)
      opts = device_opts({ "/dev/ttyACM0" })
      opts.monitor = { baud = 115200 }
      local discovered = assert(monitor.plan(project(root), opts))
      assert.equals("/dev/ttyACM0", discovered.metadata.device)
    end
  )

  it(
    "fails stale explicit or configured paths without selecting another device",
    function()
      local opts = device_opts({ "/dev/ttyACM0" })
      opts.device = "/dev/ttyACM-missing"
      opts.monitor = { device = "/dev/ttyACM0", baud = 115200 }
      local explicit, explicit_err = monitor.plan(project(root), opts)
      assert.is_nil(explicit)
      assert.equals("monitor-device-not-found", explicit_err.code)

      opts.device = nil
      opts.monitor.device = "/dev/ttyACM-missing"
      local configured, configured_err = monitor.plan(project(root), opts)
      assert.is_nil(configured)
      assert.equals("monitor-device-not-found", configured_err.code)
    end
  )

  it(
    "ignores a stale session path and requires a picker for several candidates",
    function()
      session.select(root, { monitor_device = "/dev/ttyACM-stale" })
      local opts = device_opts({ "/dev/ttyACM0", "/dev/ttyACM1" })
      opts.monitor = { baud = 115200 }

      local plan, err = monitor.plan(project(root), opts)

      assert.is_nil(plan)
      assert.equals("monitor-device-required", err.code)
      assert.same({ "/dev/ttyACM0", "/dev/ttyACM1" }, err.candidates)
    end
  )

  it("owns the exact device and records an unbounded stream with no reset", function()
    local opts = device_opts({ "/dev/ttyACM0" })
    opts.monitor = { baud = 9600 }

    local plan = assert(monitor.plan(project(root), opts))

    assert.equals("monitor", plan.kind)
    assert.same({ "application" }, plan.images)
    assert.same({ { kind = "serial-device", id = "/dev/ttyACM0" } }, plan.locks)
    assert.equals("none", plan.reset_policy)
    assert.equals("/dev/ttyACM0", plan.metadata.device)
    assert.equals(9600, plan.metadata.baud)
    assert.equals("stream", plan.commands[2].lifecycle)
    assert.is_nil(plan.commands[2].timeout_ms)
  end)
end)

describe("nvim-stm32 monitor operation lifecycle", function()
  local monitor = require("nvim-stm32.operations.monitor")
  local original_executable
  local original_new_timer
  local original_schedule
  local original_system
  local root
  local planned

  before_each(function()
    root = vim.fn.tempname()
    session.clear()
    original_executable = vim.fn.executable
    original_new_timer = vim.uv.new_timer
    original_schedule = vim.schedule
    original_system = process.system
    vim.fn.executable = function()
      return 1
    end
    local opts = device_opts({ "/dev/ttyACM0" })
    opts.monitor = { baud = 115200 }
    planned = assert(monitor.plan(project(root), opts))
  end)

  after_each(function()
    vim.fn.executable = original_executable
    vim.uv.new_timer = original_new_timer
    vim.schedule = original_schedule
    process.system = original_system
    session.clear()
  end)

  it("stops before streaming when line setup fails", function()
    local calls = {}
    process.system = function(argv, _, callback)
      calls[#calls + 1] = vim.deepcopy(argv)
      callback({ code = 2, signal = 0 })
      return { pid = 90, kill = function() end }
    end
    local result

    monitor.execute(planned, device_opts({ "/dev/ttyACM0" }), function(value)
      result = value
    end)

    assert.is_true(vim.wait(100, function()
      return result ~= nil
    end))
    assert.equals(1, #calls)
    assert.equals("stty", calls[1][1])
    assert.equals("monitor-setup-failed", result.error.code)
  end)

  it("streams byte chunks unchanged and reports clean EOF", function()
    local chunks = {}
    local text_modes = {}
    local result
    local calls = 0
    process.system = function(_, opts, callback)
      calls = calls + 1
      text_modes[calls] = opts.text
      if calls == 2 then
        opts.stdout(nil, "A\0B\r\n")
        opts.stderr(nil, "\255")
      end
      callback({ code = 0, signal = 0 })
      return { pid = 90 + calls, kill = function() end }
    end

    monitor.execute(
      planned,
      vim.tbl_extend("force", device_opts({ "/dev/ttyACM0" }), {
        on_output = function(chunk)
          chunks[#chunks + 1] = chunk
        end,
      }),
      function(value)
        result = value
      end
    )

    assert.is_true(vim.wait(100, function()
      return result ~= nil
    end))
    assert.same({ true, false }, text_modes)
    assert.same({ "A\0B\r\n", "\255" }, chunks)
    assert.is_true(result.ok)
    assert.equals("ended", result.metadata.status)
  end)

  it("keeps disconnection output and returns a structured failure", function()
    local calls = 0
    local result
    process.system = function(_, opts, callback)
      calls = calls + 1
      if calls == 2 then
        opts.stderr(nil, "cat: device disconnected\n")
        callback({ code = 5, signal = 0 })
      else
        callback({ code = 0, signal = 0 })
      end
      return { pid = 92 + calls, kill = function() end }
    end

    monitor.execute(planned, device_opts({ "/dev/ttyACM0" }), function(value)
      result = value
    end)

    assert.is_true(vim.wait(100, function()
      return result ~= nil
    end))
    assert.is_false(result.ok)
    assert.equals("monitor-disconnected", result.error.code)
    assert.equals("cat: device disconnected\n", result.error.output)
  end)

  it("revalidates the selected device before starting setup", function()
    local starts = 0
    process.system = function()
      starts = starts + 1
    end
    local result
    local opts = device_opts({})

    monitor.execute(planned, opts, function(value)
      result = value
    end)

    assert.equals(0, starts)
    assert.equals("monitor-device-not-found", result.error.code)
  end)

  it("reports lock contention without starting another monitor", function()
    local release = assert(locks.acquire("other-monitor", planned.locks))
    local starts = 0
    process.system = function()
      starts = starts + 1
    end
    local result

    monitor.execute(planned, device_opts({ "/dev/ttyACM0" }), function(value)
      result = value
    end)

    assert.equals(0, starts)
    assert.equals("operation-lock-contended", result.error.code)
    release()
  end)

  it("cancels owned setup and releases its lock only after child exit", function()
    local on_exit
    local signals = {}
    process.system = function(_, _, callback)
      on_exit = callback
      return {
        pid = 96,
        kill = function(_, signal)
          signals[#signals + 1] = signal
        end,
      }
    end
    local result
    local handle = monitor.execute(
      planned,
      device_opts({ "/dev/ttyACM0" }),
      function(value)
        result = value
      end
    )

    assert.is_true(handle.cancel("user"))
    assert.same({ 15 }, signals)
    local competing, lock_err = locks.acquire("before-exit", planned.locks)
    assert.is_nil(competing)
    assert.equals("operation-lock-contended", lock_err.code)
    assert.is_nil(result)

    on_exit({ code = 143, signal = 15 })
    assert.is_true(vim.wait(100, function()
      return result ~= nil
    end))
    assert.equals("monitor-stopped", result.error.code)
    assert.equals("stopped", result.metadata.status)
    local reacquired = assert(locks.acquire("after-exit", planned.locks))
    reacquired()
  end)

  it("cancels only the active stream child after setup", function()
    local calls = 0
    local stream_exit
    local signals = {}
    process.system = function(_, _, callback)
      calls = calls + 1
      if calls == 1 then
        callback({ code = 0, signal = 0 })
      else
        stream_exit = callback
      end
      local child_id = calls
      return {
        pid = 96 + child_id,
        kill = function(_, signal)
          signals[#signals + 1] = { child = child_id, signal = signal }
        end,
      }
    end
    local result
    local handle = monitor.execute(
      planned,
      device_opts({ "/dev/ttyACM0" }),
      function(value)
        result = value
      end
    )
    assert.is_true(vim.wait(100, function()
      return stream_exit ~= nil
    end))

    assert.is_true(handle.cancel("user"))
    assert.same({ { child = 2, signal = 15 } }, signals)
    stream_exit({ code = 143, signal = 15 })
    assert.is_true(vim.wait(100, function()
      return result ~= nil
    end))
    assert.equals("monitor-stopped", result.error.code)
  end)

  it("cancels between setup exit and stream startup without launching cat", function()
    local scheduled = {}
    vim.schedule = function(callback)
      scheduled[#scheduled + 1] = callback
    end
    local setup_exit
    local starts = 0
    process.system = function(_, _, callback)
      starts = starts + 1
      setup_exit = callback
      return { pid = 99, kill = function() end }
    end
    local result
    local handle = monitor.execute(
      planned,
      device_opts({ "/dev/ttyACM0" }),
      function(value)
        result = value
      end
    )

    setup_exit({ code = 0, signal = 0 })
    assert.equals(1, starts)
    local cancelled = handle.cancel("window-closed")
    if not cancelled then
      scheduled[1]()
      handle.cancel("test-cleanup")
      setup_exit({ code = 143, signal = 15 })
      for index = 2, #scheduled do
        scheduled[index]()
      end
    end
    assert.is_true(cancelled)
    assert.equals("monitor-stopped", result.error.code)
    assert.equals("stopped", result.metadata.status)
    local reacquired =
      assert(locks.acquire("after-between-command-cancel", planned.locks))
    reacquired()

    for _, callback in ipairs(scheduled) do
      callback()
    end
    assert.equals(1, starts)
  end)

  it(
    "reports a setup timeout as setup failure rather than user cancellation",
    function()
      local timers = {}
      vim.uv.new_timer = function()
        local timer = { closed = false }
        function timer:is_closing()
          return self.closed
        end
        function timer:stop() end
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
      local setup_exit
      local signals = {}
      process.system = function(_, _, callback)
        setup_exit = callback
        return {
          pid = 100,
          kill = function(_, signal)
            signals[#signals + 1] = signal
          end,
        }
      end
      local result
      monitor.execute(planned, device_opts({ "/dev/ttyACM0" }), function(value)
        result = value
      end)

      timers[1].callback()
      assert.same({ 15 }, signals)
      setup_exit({ code = 143, signal = 15 })
      assert.is_true(vim.wait(100, function()
        return result ~= nil
      end))
      assert.equals("monitor-setup-failed", result.error.code)
      assert.equals("setup-failed", result.metadata.status)
      assert.matches("timed out", result.error.message, 1, true)
    end
  )
end)
