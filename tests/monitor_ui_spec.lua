local model = require("nvim-stm32.model")
local monitor = require("nvim-stm32.operations.monitor")
local project_discovery = require("nvim-stm32.discover.project")
local session = require("nvim-stm32.session")
local float = require("nvim-stm32.ui.float")

local project = model.project({
  id = "/firmware/blinky",
  root = "/firmware/blinky",
  kind = "cmake_presets",
  build = {
    adapter = "cmake_presets",
    marker = "/firmware/blinky/CMakePresets.json",
  },
  images = {
    {
      id = "application",
      name = "application",
      target = { mcu = "STM32F429ZITx", family = "STM32F4" },
    },
  },
})

local function opts(paths)
  local present = {}
  for _, path in ipairs(paths) do
    present[path] = true
  end
  return {
    platform = "Linux",
    monitor = { baud = 115200 },
    glob = function()
      return vim.deepcopy(paths)
    end,
    stat = function(path)
      return present[path] and { type = "char" } or nil
    end,
  }
end

describe("nvim-stm32 UART monitor UI", function()
  local original_execute
  local original_float_open
  local original_resolve
  local original_select
  local opened
  local presenter

  before_each(function()
    package.loaded["nvim-stm32.ui.monitor"] = nil
    original_execute = monitor.execute
    original_float_open = float.open
    original_resolve = project_discovery.resolve
    original_select = vim.ui.select
    session.clear()
    opened = nil
    presenter = { chunks = {} }
    function presenter:append(chunk)
      self.chunks[#self.chunks + 1] = chunk
    end
    function presenter:finish(ok)
      self.finished = ok
    end
    float.open = function(target, config, options, on_close)
      opened = {
        target = target,
        config = config,
        options = options,
        on_close = on_close,
      }
      return presenter
    end
    project_discovery.resolve = function()
      return vim.deepcopy(project)
    end
  end)

  after_each(function()
    monitor.execute = original_execute
    float.open = original_float_open
    project_discovery.resolve = original_resolve
    vim.ui.select = original_select
    session.clear()
    package.loaded["nvim-stm32.ui.monitor"] = nil
  end)

  it(
    "picks among several devices, remembers the choice, and streams raw chunks",
    function()
      local picker
      vim.ui.select = function(items, options, callback)
        picker = { items = items, options = options, callback = callback }
      end
      local received
      local expected_handle = { id = 101, cancel = function() end }
      monitor.execute = function(plan, run_opts, callback)
        received = { plan = plan, opts = run_opts }
        run_opts.on_output("A\0B\r\n")
        callback({
          ok = true,
          code = 0,
          output = "A\0B\r\n",
          artifacts = {},
          metadata = { status = "ended" },
        })
        return expected_handle
      end

      local result_handle = require("nvim-stm32.ui.monitor").current(opts({
        "/dev/ttyACM1",
        "/dev/ttyACM0",
      }))
      assert.is_nil(result_handle)
      assert.same({ "/dev/ttyACM0", "/dev/ttyACM1" }, picker.items)
      assert.matches("serial device", picker.options.prompt, 1, true)

      picker.callback("/dev/ttyACM1")

      assert.equals("/dev/ttyACM1", received.plan.metadata.device)
      assert.equals("/dev/ttyACM1", session.get(project).monitor_device)
      assert.same({ "A\0B\r\n", "monitor ended\n" }, presenter.chunks)
      assert.is_false(opened.options.close_on_success)
      assert.matches("/dev/ttyACM1", opened.options.title, 1, true)
      assert.is_false(presenter.finished)
    end
  )

  it("does nothing when device selection is cancelled", function()
    local execute_calls = 0
    vim.ui.select = function(_, _, callback)
      callback(nil)
    end
    monitor.execute = function()
      execute_calls = execute_calls + 1
    end

    require("nvim-stm32.ui.monitor").current(opts({
      "/dev/ttyACM0",
      "/dev/ttyACM1",
    }))

    assert.equals(0, execute_calls)
    assert.is_nil(opened)
    assert.is_nil(session.get(project).monitor_device)
  end)

  it("keeps clean EOF visible and separates its ending from a partial line", function()
    monitor.execute = function(_, run_opts, callback)
      run_opts.on_output("partial")
      callback({
        ok = true,
        code = 0,
        output = "partial",
        artifacts = {},
        metadata = { status = "ended" },
      })
      return { cancel = function() end }
    end

    require("nvim-stm32.ui.monitor").current(opts({ "/dev/ttyACM0" }))

    assert.same({ "partial", "\nmonitor ended\n" }, presenter.chunks)
    assert.is_false(presenter.finished)
  end)

  it("shows stopped status after cancellation completes", function()
    monitor.execute = function(_, _, callback)
      callback({
        ok = false,
        code = 143,
        output = "",
        artifacts = {},
        error = { code = "monitor-stopped", message = "nvim-stm32: monitor stopped" },
        metadata = { status = "stopped" },
      })
      return { cancel = function() end }
    end

    require("nvim-stm32.ui.monitor").current(opts({ "/dev/ttyACM0" }))

    assert.same({ "monitor stopped\n" }, presenter.chunks)
    assert.is_false(presenter.finished)
  end)

  it("keeps nonzero exit diagnostics visible", function()
    monitor.execute = function(_, run_opts, callback)
      run_opts.on_output("cat: disconnected\n")
      callback({
        ok = false,
        code = 5,
        output = "cat: disconnected\n",
        artifacts = {},
        error = {
          code = "monitor-disconnected",
          message = "nvim-stm32: serial device disconnected",
        },
        metadata = { status = "disconnected" },
      })
      return { cancel = function() end }
    end

    require("nvim-stm32.ui.monitor").current(opts({ "/dev/ttyACM0" }))

    assert.same({
      "cat: disconnected\n",
      "nvim-stm32: serial device disconnected\n",
    }, presenter.chunks)
    assert.is_false(presenter.finished)
  end)

  it("cancels only its returned handle when the window closes", function()
    local cancellation
    local handle = {
      cancel = function(reason)
        cancellation = reason
        return true
      end,
    }
    monitor.execute = function()
      return handle
    end

    local returned = require("nvim-stm32.ui.monitor").current(opts({ "/dev/ttyACM0" }))
    opened.on_close()

    assert.equals(handle, returned)
    assert.equals("window-closed", cancellation)
  end)

  it("registers monitor planning and the lazy command", function()
    pcall(vim.api.nvim_del_user_command, "STM32Monitor")
    pcall(vim.api.nvim_del_user_command, "STM32Plan")
    vim.g.loaded_nvim_stm32 = nil
    vim.cmd("runtime plugin/nvim-stm32.lua")

    assert.equals(2, vim.fn.exists(":STM32Monitor"))
    local completion = vim.api.nvim_get_commands({ builtin = false }).STM32Plan.complete
    assert.is_true(vim.tbl_contains(completion(), "monitor"))

    local plan = assert(
      require("nvim-stm32").plan(
        "monitor",
        vim.tbl_extend("force", opts({ "/dev/ttyACM0" }), { project = project })
      )
    )
    assert.equals("monitor", plan.kind)
  end)
end)
