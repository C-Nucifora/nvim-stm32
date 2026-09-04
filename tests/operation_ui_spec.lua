local commands = { "STM32Flash", "STM32Erase", "STM32Reset", "STM32Plan" }

describe("nvim-stm32 hardware operation commands", function()
  before_each(function()
    for _, command in ipairs(commands) do
      pcall(vim.api.nvim_del_user_command, command)
    end
    vim.g.loaded_nvim_stm32 = nil

    -- PlenaryBustedFile starts Neovim with --noplugin. Load the command shim
    -- explicitly to exercise the same registration path as normal startup.
    vim.cmd("runtime plugin/nvim-stm32.lua")
  end)

  it("registers flash, erase, and reset without a setup call", function()
    assert.equals(2, vim.fn.exists(":STM32Flash"))
    assert.equals(2, vim.fn.exists(":STM32Erase"))
    assert.equals(2, vim.fn.exists(":STM32Reset"))
    assert.equals(0, vim.fn.exists(":STM32Verify"))

    local completion = vim.api.nvim_get_commands({ builtin = false }).STM32Plan.complete
    assert.same(
      { "build", "clean", "rebuild", "analyze", "flash", "erase", "reset" },
      completion()
    )
  end)
end)

describe("nvim-stm32 erase confirmation", function()
  local nvim_stm32 = require("nvim-stm32")
  local process = require("nvim-stm32.process")
  local project_discovery = require("nvim-stm32.discover.project")
  local float = require("nvim-stm32.ui.float")
  local original_confirm
  local original_float_open
  local original_plan
  local original_process_run
  local original_resolve
  local original_run

  local project = {
    id = "/firmware/blinky",
    root = "/firmware/blinky",
    kind = "cmake_presets",
    build = { marker = "/firmware/blinky/CMakePresets.json" },
    images = {
      {
        id = "application",
        target = { mcu = "STM32F429ZITx", family = "STM32F4" },
      },
    },
  }

  before_each(function()
    package.loaded["nvim-stm32.ui.operation"] = nil
    original_confirm = vim.fn.confirm
    original_float_open = float.open
    original_plan = nvim_stm32.plan
    original_process_run = process.run
    original_resolve = project_discovery.resolve
    original_run = nvim_stm32.run
  end)

  after_each(function()
    vim.fn.confirm = original_confirm
    float.open = original_float_open
    nvim_stm32.plan = original_plan
    process.run = original_process_run
    project_discovery.resolve = original_resolve
    nvim_stm32.run = original_run
    package.loaded["nvim-stm32.ui.operation"] = nil
  end)

  it("constructs no plan and spawns nothing when erase is declined", function()
    local calls = { plan = 0, run = 0, process = 0, float = 0 }
    project_discovery.resolve = function()
      return vim.deepcopy(project)
    end
    vim.fn.confirm = function()
      return 2
    end
    nvim_stm32.plan = function()
      calls.plan = calls.plan + 1
    end
    nvim_stm32.run = function()
      calls.run = calls.run + 1
    end
    process.run = function()
      calls.process = calls.process + 1
    end
    float.open = function()
      calls.float = calls.float + 1
    end

    local handle = require("nvim-stm32.ui.operation").current("erase")

    assert.is_nil(handle)
    assert.same({ plan = 0, run = 0, process = 0, float = 0 }, calls)
  end)

  it("runs a confirmed erase only for the literal affirmative result", function()
    local prompt
    local received
    local expected_handle = { id = 23 }
    local float_options
    project_discovery.resolve = function()
      return vim.deepcopy(project)
    end
    vim.fn.confirm = function(message, choices, default)
      prompt = { message = message, choices = choices, default = default }
      return 1
    end
    float.open = function(_, _, options)
      float_options = options
      return {
        append = function() end,
        finish = function() end,
      }
    end
    nvim_stm32.run = function(action, opts)
      received = { action = action, opts = opts }
      return expected_handle
    end

    local handle = require("nvim-stm32.ui.operation").current("erase")

    assert.equals(expected_handle, handle)
    assert.matches("/firmware/blinky", prompt.message, 1, true)
    assert.matches("STM32F429ZITx", prompt.message, 1, true)
    assert.equals("&Erase\n&Cancel", prompt.choices)
    assert.equals(2, prompt.default)
    assert.equals("erase", received.action)
    assert.is_true(received.opts.confirmed)
    assert.same(project, received.opts.project)
    assert.matches("erase", float_options.title, 1, true)
  end)

  it("rejects truthy values other than numeric one", function()
    local run_calls = 0
    project_discovery.resolve = function()
      return vim.deepcopy(project)
    end
    nvim_stm32.run = function()
      run_calls = run_calls + 1
    end

    for _, answer in ipairs({ true, "1", 2 }) do
      vim.fn.confirm = function()
        return answer
      end
      assert.is_nil(require("nvim-stm32.ui.operation").current("erase"))
    end

    assert.equals(0, run_calls)
  end)
end)

describe("nvim-stm32 hardware operation output", function()
  local nvim_stm32 = require("nvim-stm32")
  local project_discovery = require("nvim-stm32.discover.project")
  local float = require("nvim-stm32.ui.float")
  local original_float_open
  local original_resolve
  local original_run
  local presenter
  local opened

  local project = {
    id = "/firmware/blinky",
    root = "/firmware/blinky",
    kind = "cmake_presets",
    build = { marker = "/firmware/blinky/CMakePresets.json" },
    images = {
      {
        id = "application",
        target = { mcu = "STM32F429ZITx", family = "STM32F4" },
      },
    },
  }

  before_each(function()
    package.loaded["nvim-stm32.ui.operation"] = nil
    original_float_open = float.open
    original_resolve = project_discovery.resolve
    original_run = nvim_stm32.run
    presenter = { chunks = {} }
    function presenter:append(chunk)
      self.chunks[#self.chunks + 1] = chunk
    end
    function presenter:finish(ok)
      self.finished = ok
    end
    project_discovery.resolve = function()
      return vim.deepcopy(project)
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
  end)

  after_each(function()
    float.open = original_float_open
    project_discovery.resolve = original_resolve
    nvim_stm32.run = original_run
    package.loaded["nvim-stm32.ui.operation"] = nil
  end)

  it("streams bounded output into a titled float and keeps failures visible", function()
    local received
    local expected_handle = { id = 44 }
    nvim_stm32.run = function(action, opts, callback)
      received = { action = action, opts = opts }
      opts.on_output("probe output\n")
      callback({
        ok = false,
        code = 1,
        output = "probe output\n",
        artifacts = {},
        error = { message = "nvim-stm32: reset failed" },
        metadata = {},
      })
      return expected_handle
    end

    local handle = require("nvim-stm32.ui.operation").current("reset")

    assert.equals(expected_handle, handle)
    assert.equals("reset", received.action)
    assert.same({ "probe output\n", "\nnvim-stm32: reset failed\n" }, presenter.chunks)
    assert.is_false(presenter.finished)
    assert.matches("reset", opened.options.title, 1, true)
    assert.matches("STM32F429ZITx", opened.options.title, 1, true)
    assert.is_true(opened.options.close_on_success)
  end)

  it("cancels only the operation handle when its window closes", function()
    local cancelled
    local handle = {
      cancel = function(reason)
        cancelled = reason
        return true
      end,
    }
    nvim_stm32.run = function()
      return handle
    end

    assert.equals(handle, require("nvim-stm32.ui.operation").current("flash"))
    opened.on_close()

    assert.equals("window-closed", cancelled)
  end)
end)
