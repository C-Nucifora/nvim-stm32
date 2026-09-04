local M = {}

local function check(value, message)
  if not value then
    error(message, 2)
  end
  return value
end

local function wait_for(predicate, message)
  check(vim.wait(5000, predicate, 10), message)
end

local function read_lines(path)
  if vim.fn.filereadable(path) ~= 1 then
    return {}
  end
  return vim.fn.readfile(path)
end

local function window_for_filetype(filetype)
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local buf = vim.api.nvim_win_get_buf(win)
    if vim.bo[buf].filetype == filetype then
      return win, buf
    end
  end
end

local function buffer_text(buf)
  return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
end

local function edit_source(root)
  vim.cmd.edit(vim.fn.fnameescape(root .. "/Core/Src/main.c"))
end

local function run_gate()
  local root = check(vim.env.NVIM_STM32_RPC_PROJECT, "missing RPC project root")
  local fake_root = check(vim.env.NVIM_STM32_FAKE_ROOT, "missing fake log root")
  local uart_one = check(vim.env.NVIM_STM32_RPC_UART_ONE, "missing first fake UART")
  local uart_two = check(vim.env.NVIM_STM32_RPC_UART_TWO, "missing second fake UART")
  local tools = root .. "/tools"
  local programmer = tools .. "/STM32_Programmer_CLI"
  local elf = root .. "/build/Debug/app.elf"
  local notifications = {}
  local selections = {}

  vim.notify = function(message)
    notifications[#notifications + 1] = tostring(message)
  end
  vim.ui.select = function(items, options, callback)
    selections[#selections + 1] = options and options.prompt or ""
    callback(items[1], 1)
  end
  vim.fn.confirm = function()
    return 2
  end

  local runtime_ok, runtime = pcall(require, "nvim-stm32")
  check(
    runtime_ok,
    tostring(runtime)
      .. "\nruntimepath="
      .. vim.o.runtimepath
      .. "\nrepo="
      .. tostring(vim.env.NVIM_STM32_RPC_REPO)
  )
  runtime.setup({
    preset = "Debug",
    flash_backend = "cubeprogrammer",
    programmer_path = programmer,
    toolchain_path = tools,
    float = { close_on_success_ms = 20 },
  })
  require("nvim-stm32.session").clear()
  vim.cmd.cd(vim.fn.fnameescape(root))
  edit_source(root)

  check(#vim.api.nvim_list_uis() > 0, "Neovim has no attached UI")

  vim.cmd("STM32Info")
  local info = table.concat(notifications, "\n")
  check(info:find("STM32F429ZITx", 1, true), "info omitted the F429 target")
  check(info:find("NUCLEO-F429ZI", 1, true), "info omitted the Nucleo board")

  vim.cmd("STM32SelectProbe")
  wait_for(function()
    return require("nvim-stm32").get_session(root).probe_serial == "FAKE-F429-001"
  end, "probe selection did not finish: " .. table.concat(notifications, " | "))
  check(selections[1] == "STM32 probe", "probe selection did not use vim.ui.select")

  edit_source(root)
  vim.cmd("STM32Build")
  local build_win = window_for_filetype("nvim-stm32-output")
  check(build_win, "build did not open an output window")
  wait_for(function()
    local state = require("nvim-stm32").get_session(root)
    return state.last_result and state.last_result.ok
  end, "build did not record a successful result")
  wait_for(function()
    return not vim.api.nvim_win_is_valid(build_win)
  end, "successful build output window did not close")

  edit_source(root)
  vim.cmd("STM32Analyze")
  local analysis_buf
  wait_for(function()
    local _, candidate = window_for_filetype("nvim-stm32-analysis")
    analysis_buf = candidate
    return candidate ~= nil
  end, "analysis did not open its report buffer")
  local analysis_text = buffer_text(analysis_buf)
  check(analysis_text:find("FLASH: 8 /", 1, true), "analysis FLASH total is wrong")
  check(analysis_text:find("RAM: 4 /", 1, true), "analysis RAM total is wrong")

  local size_result = vim
    .system({ tools .. "/arm-none-eabi-size", "-B", "-x", elf }, {
      cwd = root,
      text = true,
    })
    :wait(5000)
  check(
    require("nvim-stm32.process").succeeded(size_result),
    "direct size command failed"
  )
  local direct_size, size_err =
    require("nvim-stm32.inspect.size").parse(size_result.stdout)
  check(
    direct_size,
    size_err and size_err.message or "direct size output did not parse"
  )
  check(
    direct_size.text == 8 and direct_size.data == 0 and direct_size.bss == 4,
    "analysis does not match direct size output"
  )

  vim.fn.writefile({}, fake_root .. "/events")
  edit_source(root)
  vim.cmd("STM32Plan flash")
  local _, plan_buf = window_for_filetype("nvim-stm32-plan")
  check(plan_buf, "flash plan did not open its report buffer")
  local plan_text = buffer_text(plan_buf)
  check(plan_text:find("Configuration: Debug", 1, true), "plan omitted Debug")
  check(plan_text:find("Backend: cubeprogrammer", 1, true), "plan omitted backend")
  check(plan_text:find(elf, 1, true), "plan omitted the selected ELF")
  check(plan_text:find(programmer, 1, true), "plan omitted the fake programmer")
  check(
    plan_text:find("Address: embedded in ELF", 1, true),
    "plan invented an ELF address"
  )
  check(#read_lines(fake_root .. "/events") == 0, "plan spawned an external process")

  edit_source(root)
  vim.cmd("STM32Flash")
  local flash_win = window_for_filetype("nvim-stm32-output")
  check(flash_win, "flash did not open an output window")
  wait_for(function()
    local seen = read_lines(fake_root .. "/events")
    return seen[#seen] == "cubeprogrammer:reset"
  end, "flash did not reach its final reset")
  wait_for(function()
    return not vim.api.nvim_win_is_valid(flash_win)
  end, "successful flash output window did not close")
  check(
    vim.deep_equal(read_lines(fake_root .. "/events"), {
      "cmake:configure",
      "cmake:build",
      "cubeprogrammer:identify",
      "cubeprogrammer:program-verify",
      "cubeprogrammer:reset",
    }),
    "flash command order or reset count is wrong"
  )

  local before_erase = #read_lines(fake_root .. "/events")
  edit_source(root)
  vim.cmd("STM32Erase")
  check(
    #read_lines(fake_root .. "/events") == before_erase,
    "declined erase spawned an external process"
  )

  vim.fn.writefile({}, fake_root .. "/events")
  local monitor_result
  edit_source(root)
  require("nvim-stm32.ui.monitor").current({
    dir = root .. "/Core/Src",
    platform = "Linux",
    glob = function()
      return { uart_two, uart_one }
    end,
  }, function(result)
    monitor_result = result
  end)
  check(
    selections[#selections] == "Select UART serial device:",
    "UART selection did not use vim.ui.select"
  )
  local monitor_win, monitor_buf
  wait_for(function()
    monitor_win, monitor_buf = window_for_filetype("nvim-stm32-output")
    return monitor_win ~= nil
  end, "monitor did not open an output window")
  wait_for(function()
    return buffer_text(monitor_buf):find("first second", 1, true) ~= nil
  end, "monitor did not stream split UART output")
  vim.api.nvim_win_close(monitor_win, true)
  wait_for(function()
    return monitor_result ~= nil
  end, "window close did not finish monitor cancellation")
  check(not monitor_result.ok, "cancelled monitor reported success")
  check(
    monitor_result.error.code == "monitor-stopped",
    "monitor cancellation error is wrong"
  )
  check(
    vim.deep_equal(read_lines(fake_root .. "/events"), {
      "uart:setup",
      "uart:stream",
    }),
    "monitor spawned an unexpected process"
  )

  return {
    ui_attached = true,
    info = true,
    probe_selection = true,
    build_window = true,
    analysis_matches_size = true,
    plan_zero_spawn = true,
    flash_order = true,
    erase_decline_zero_spawn = true,
    uart_selection_stream_cancel = true,
  }
end

function M.run()
  local ok, result = xpcall(run_gate, debug.traceback)
  if ok then
    result.ok = true
    return vim.json.encode(result)
  end
  return vim.json.encode({ ok = false, error = result })
end

return M
