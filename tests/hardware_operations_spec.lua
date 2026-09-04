local flash = require("nvim-stm32.operations.flash")
local model = require("nvim-stm32.model")
local monitor = require("nvim-stm32.operations.monitor")
local probes = require("nvim-stm32.probes")
local session = require("nvim-stm32.session")

local source = debug.getinfo(1, "S").source:sub(2)
local repo = vim.fn.fnamemodify(vim.fn.resolve(source), ":p:h:h")
local fixtures = repo .. "/tests/integration"

local function write(path, lines)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  vim.fn.writefile(
    type(lines) == "table" and lines
      or vim.split(lines or "firmware", "\n", { plain = true }),
    path
  )
end

local function link(source_path, destination)
  vim.fn.mkdir(vim.fs.dirname(destination), "p")
  assert.is_true(vim.uv.fs_symlink(source_path, destination))
end

local function modified_ns(path)
  local stat = assert(vim.uv.fs_stat(path))
  return stat.mtime.sec * 1000000000 + stat.mtime.nsec
end

local function project(root, address)
  write(
    root .. "/CMakePresets.json",
    vim.json.encode({
      version = 3,
      configurePresets = {
        { name = "Debug", binaryDir = "${sourceDir}/build/Debug" },
      },
      buildPresets = {
        { name = "Debug", configurePreset = "Debug" },
      },
    })
  )
  write(
    root .. "/STM32F429ZITX_FLASH.ld",
    "MEMORY\n{\nFLASH (rx) : ORIGIN = 0x08000000, LENGTH = 2048K\n}"
  )
  return model.project({
    id = root,
    root = root,
    kind = "cmake_presets",
    build = { adapter = "cmake_presets", marker = root .. "/CMakePresets.json" },
    images = {
      {
        id = "application",
        name = "application",
        build_target = "application",
        flash = address and { address = address } or nil,
        target = {
          mcu = "STM32F429ZITx",
          openocd_cfg = "target/stm32f4x.cfg",
          debug_ids = { 0x419 },
          debug_idcode_address = 0xE0042000,
          signals = {
            {
              source = "linker",
              file = root .. "/STM32F429ZITX_FLASH.ld",
              mcu = "STM32F429ZITx",
              confidence = "inferred",
            },
          },
        },
      },
    },
  })
end

local function artifact(root, kind, build_id)
  local path = root .. "/build/Debug/application." .. kind
  write(path, "firmware")
  return model.artifact({
    image_id = "application",
    configuration = "Debug",
    kind = kind,
    path = path,
    build_target = "application",
    modified_ns = modified_ns(path),
    build_id = build_id,
  })
end

local function run_flash(action, project_value, opts, run_opts)
  local plan, plan_err = flash.plan(action, project_value, opts)
  assert.is_nil(plan_err, vim.inspect(plan_err))
  assert.is_not_nil(plan)
  local result
  local handle = flash.execute(plan, run_opts or {}, function(value)
    result = value
  end)
  assert.is_true(
    vim.wait(3000, function()
      return result ~= nil
    end),
    "flash operation did not finish"
  )
  return result, handle, plan
end

local function fake_env(root, fail)
  return {
    NVIM_STM32_FAKE_ROOT = root .. "/fake-log",
    NVIM_STM32_FAKE_FAIL = fail,
  }
end

local function events(root)
  local path = root .. "/fake-log/events"
  return vim.fn.filereadable(path) == 1 and vim.fn.readfile(path) or {}
end

local function argv_logs(root)
  local paths = vim.fn.glob(root .. "/fake-log/*.argv", false, true)
  table.sort(paths)
  return vim.tbl_map(function(path)
    return vim.fn.readfile(path)
  end, paths)
end

describe("nvim-stm32 fake programmer integration", function()
  local root
  local programmer = fixtures .. "/fake_programmer.sh"
  local old_fake_root

  before_each(function()
    root = vim.fn.tempname()
    vim.fn.mkdir(root .. "/fake-log", "p")
    old_fake_root = vim.env.NVIM_STM32_FAKE_ROOT
    vim.env.NVIM_STM32_FAKE_ROOT = root .. "/fake-log"
    session.clear()
  end)

  after_each(function()
    session.clear()
    vim.env.NVIM_STM32_FAKE_ROOT = old_fake_root
    vim.fn.delete(root, "rf")
  end)

  it("enumerates CubeProgrammer probes with the passive real process path", function()
    local listed
    local listed_err
    probes.enumerate({ programmer_path = programmer }, function(value, err)
      listed = value
      listed_err = err
    end)

    assert.is_true(
      vim.wait(3000, function()
        return listed ~= nil or listed_err ~= nil
      end),
      "probe enumeration did not finish"
    )
    assert.is_nil(listed_err)
    assert.equals("FAKE-F429-001", listed[1].serial)
    assert.equals("V3J15M7", listed[1].firmware)
    assert.same({ "cubeprogrammer:list" }, events(root))
    assert.same({ { programmer, "-l", "st-link-only" } }, argv_logs(root))
  end)

  it("accepts F429 identity output and runs a requested reset", function()
    local source_project = project(root)
    local result = run_flash("reset", source_project, {
      backend = "cubeprogrammer",
      programmer_path = programmer,
      probe = { backend = "cubeprogrammer", serial = "FAKE-F429-001" },
    }, { env = fake_env(root) })

    assert.is_true(result.ok, vim.inspect(result))
    assert.same({ "cubeprogrammer:identify", "cubeprogrammer:reset" }, events(root))
  end)

  it("programs, verifies, then resets through real vim.system children", function()
    local source_project = project(root)
    local elf = artifact(root, "elf", "fake-build-1")
    local result, _, plan = run_flash("flash", source_project, {
      backend = "cubeprogrammer",
      programmer_path = programmer,
      configuration = "Debug",
      probe = { backend = "cubeprogrammer", serial = "FAKE-F429-001" },
      artifacts = { elf },
      build_id = "fake-build-1",
    }, { env = fake_env(root) })

    assert.is_true(result.ok, vim.inspect(result))
    assert.same({
      "cubeprogrammer:identify",
      "cubeprogrammer:program-verify",
      "cubeprogrammer:reset",
    }, events(root))
    assert.same(plan.commands[2].argv, argv_logs(root)[2])
  end)

  for _, failure in ipairs({
    { name = "write", code = 10, marker = "write failed" },
    {
      name = "verification",
      fail = "verify",
      code = 11,
      marker = "verification failed",
    },
  }) do
    it("stops before reset when " .. failure.name .. " fails", function()
      local source_project = project(root)
      local elf = artifact(root, "elf", "fake-build-1")
      local result = run_flash("flash", source_project, {
        backend = "cubeprogrammer",
        programmer_path = programmer,
        configuration = "Debug",
        probe = { backend = "cubeprogrammer", serial = "FAKE-F429-001" },
        artifacts = { elf },
        build_id = "fake-build-1",
      }, { env = fake_env(root, failure.fail or failure.name) })

      assert.is_false(result.ok)
      assert.equals(failure.code, result.code)
      assert.equals("program-verify", result.error.phase)
      assert.matches(failure.marker, result.error.output, 1, true)
      assert.same({
        "cubeprogrammer:identify",
        "cubeprogrammer:program-verify",
      }, events(root))
    end)
  end

  it("mass erases only after a confirmed plan", function()
    local source_project = project(root)
    local result = run_flash("erase", source_project, {
      backend = "cubeprogrammer",
      programmer_path = programmer,
      probe = { backend = "cubeprogrammer", serial = "FAKE-F429-001" },
      confirmed = true,
    }, { env = fake_env(root) })

    assert.is_true(result.ok, vim.inspect(result))
    assert.same({ "cubeprogrammer:identify", "cubeprogrammer:erase" }, events(root))
  end)
end)

describe("nvim-stm32 alternative fake backend integration", function()
  local root

  before_each(function()
    root = vim.fn.tempname()
    vim.fn.mkdir(root .. "/fake-log", "p")
    session.clear()
  end)

  after_each(function()
    session.clear()
    vim.fn.delete(root, "rf")
  end)

  it("programs and verifies a BIN with the pinned stlink tools", function()
    local stlink = root .. "/tools/st-flash"
    link(fixtures .. "/fake_st_flash.sh", stlink)
    link(fixtures .. "/fake_st_flash.sh", root .. "/tools/st-info")
    local source_project = project(root, 0x08000000)
    local bin = artifact(root, "bin", "fake-build-1")

    local result = run_flash("flash", source_project, {
      backend = "stlink",
      stlink_path = stlink,
      configuration = "Debug",
      probe = { backend = "stlink", serial = "FAKEF429001" },
      artifacts = { bin },
      build_id = "fake-build-1",
    }, { env = fake_env(root) })

    assert.is_true(result.ok, vim.inspect(result))
    assert.same(
      { "stlink:identify", "stlink:program-verify", "stlink:reset" },
      events(root)
    )
    assert.same({
      stlink,
      "--serial",
      "0xFAKEF429001",
      "write",
      vim.fn.resolve(bin.path),
      "0x08000000",
    }, argv_logs(root)[2])
  end)

  it("programs and verifies an ELF with the pinned OpenOCD tool", function()
    local openocd = fixtures .. "/fake_openocd.sh"
    local source_project = project(root)
    local elf = artifact(root, "elf", "fake-build-1")

    local result = run_flash("flash", source_project, {
      backend = "openocd",
      openocd_path = openocd,
      configuration = "Debug",
      probe = { backend = "openocd", serial = "[FAKE-F429-001]" },
      artifacts = { elf },
      build_id = "fake-build-1",
    }, { env = fake_env(root) })

    assert.is_true(result.ok, vim.inspect(result))
    assert.same(
      { "openocd:identify", "openocd:program-verify", "openocd:reset" },
      events(root)
    )
    assert.same({
      openocd,
      "-f",
      "interface/stlink.cfg",
      "-c",
      "adapter serial {[FAKE-F429-001]}",
      "-f",
      "target/stm32f4x.cfg",
      "-c",
      "program " .. vim.fn.resolve(elf.path) .. " verify; shutdown",
    }, argv_logs(root)[2])
  end)
end)

describe("nvim-stm32 fake UART integration", function()
  local root
  local old_path
  local active

  local function device_opts(device)
    return {
      platform = "Linux",
      device = device,
      monitor = { baud = 115200 },
      stat = function(path)
        return path == device and { type = "char" } or nil
      end,
    }
  end

  before_each(function()
    root = vim.fn.tempname()
    vim.fn.mkdir(root .. "/fake-log", "p")
    link(fixtures .. "/fake_stty.sh", root .. "/tools/stty")
    link(fixtures .. "/fake_cat.sh", root .. "/tools/cat")
    old_path = vim.env.PATH
    vim.env.PATH = root .. "/tools:" .. old_path
    session.clear()
  end)

  after_each(function()
    if active and active.state() ~= "completed" and active.state() ~= "cancelled" then
      active.cancel("test-cleanup")
      vim.wait(3000, function()
        return active.state() == "cancelled" or active.state() == "completed"
      end)
    end
    active = nil
    session.clear()
    vim.env.PATH = old_path
    vim.fn.delete(root, "rf")
  end)

  it("configures, streams split chunks, and cancels only its owned process", function()
    local device = root .. "/fake-uart"
    write(device, "")
    local opts = device_opts(device)
    local plan = assert(monitor.plan(project(root), opts))
    local chunks = {}
    local result
    local env = fake_env(root)
    env.NVIM_STM32_FAKE_UART_CHUNK_1 = "first "
    env.NVIM_STM32_FAKE_UART_CHUNK_2 = "second\n"

    active = monitor.execute(
      plan,
      vim.tbl_extend("force", opts, {
        env = env,
        on_output = function(chunk)
          chunks[#chunks + 1] = chunk
        end,
      }),
      function(value)
        result = value
      end
    )

    assert.is_true(
      vim.wait(3000, function()
        return table.concat(chunks):find("first second\n", 1, true) ~= nil
      end),
      vim.inspect(chunks)
    )
    assert.is_true(active.cancel("integration-test"))
    assert.is_true(
      vim.wait(3000, function()
        return result ~= nil
      end),
      "monitor cancellation did not finish"
    )
    assert.is_false(result.ok)
    assert.equals("monitor-stopped", result.error.code)
    assert.same({ "uart:setup", "uart:stream" }, events(root))
    assert.same({
      root .. "/tools/stty",
      "-F",
      device,
      "115200",
      "raw",
      "-echo",
      "cs8",
      "-parenb",
      "-cstopb",
      "clocal",
    }, argv_logs(root)[1])
    assert.same({ root .. "/tools/cat", device }, argv_logs(root)[2])
  end)
end)

local function real_pty_prerequisites()
  local commands = {}
  for _, name in ipairs({ "python3", "stty", "cat" }) do
    local path = vim.fn.exepath(name)
    if path == "" then
      return nil,
        "nvim-stm32 real PTY UART integration skipped: " .. name .. " is unavailable"
    end
    commands[name] = path
  end

  local result = vim
    .system({
      commands.python3,
      "-c",
      "import os, pty; master, slave = pty.openpty(); os.close(slave); os.close(master)",
    }, { text = true })
    :wait()
  if result.code ~= 0 then
    local detail = vim.trim((result.stderr or "") .. (result.stdout or ""))
    return nil,
      "nvim-stm32 real PTY UART integration skipped: Python stdlib pty.openpty() is unavailable"
        .. (detail ~= "" and ": " .. detail or "")
  end
  return commands
end

local pty_commands
local pty_skip_reason
if vim.env.NVIM_STM32_REAL_PTY == "1" then
  pty_commands, pty_skip_reason = real_pty_prerequisites()
end

if pty_commands then
  describe("nvim-stm32 real PTY UART integration", function()
    it("streams through real stty and cat, cancels, and reopens the device", function()
      local root = vim.fn.tempname()
      vim.fn.mkdir(root, "p")
      local slave_file = root .. "/slave"
      local trigger_file = root .. "/write"
      local stop_file = root .. "/stop"
      local helper_result
      local helper = vim.system({
        pty_commands.python3,
        "-c",
        [[
import os
import pty
import sys
import time

root = sys.argv[1]
master, slave = pty.openpty()
with open(os.path.join(root, "slave"), "w", encoding="utf-8") as output:
    output.write(os.ttyname(slave))
while not os.path.exists(os.path.join(root, "write")):
    time.sleep(0.01)
os.write(master, b"split ")
time.sleep(0.05)
os.write(master, b"chunks\n")
while not os.path.exists(os.path.join(root, "stop")):
    time.sleep(0.01)
os.close(slave)
os.close(master)
]],
        root,
      }, { text = true }, function(value)
        helper_result = value
      end)

      local first_handle
      local second_handle
      local first_result
      local second_result
      local function terminal(handle)
        return not handle
          or handle.state() == "completed"
          or handle.state() == "cancelled"
      end

      local function cancel_and_wait(handle)
        if handle and not terminal(handle) then
          pcall(handle.cancel, "test-cleanup")
        end
        return vim.wait(3000, function()
          return terminal(handle)
        end)
      end

      local ok, err = pcall(function()
        assert.is_true(
          vim.wait(3000, function()
            return vim.fn.filereadable(slave_file) == 1
          end),
          "Python did not create a PTY"
        )
        local device = vim.fn.readfile(slave_file)[1]
        local opts = {
          platform = vim.uv.os_uname().sysname,
          device = device,
          monitor = { baud = 115200 },
        }

        local first_plan = assert(monitor.plan(project(root), opts))
        local chunks = {}
        first_handle = monitor.execute(
          first_plan,
          vim.tbl_extend("force", opts, {
            on_output = function(chunk)
              chunks[#chunks + 1] = chunk
            end,
          }),
          function(value)
            first_result = value
          end
        )
        write(trigger_file, "go")
        assert.is_true(
          vim.wait(3000, function()
            return table.concat(chunks):find("split chunks\n", 1, true) ~= nil
          end),
          vim.inspect(chunks)
        )
        assert.is_true(first_handle.cancel("pty-smoke"))
        assert.is_true(
          vim.wait(3000, function()
            return first_result ~= nil
          end),
          "first PTY monitor did not stop"
        )
        assert.equals("monitor-stopped", first_result.error.code)

        local second_plan = assert(monitor.plan(project(root), opts))
        second_handle = monitor.execute(second_plan, opts, function(value)
          second_result = value
        end)
        assert.is_true(
          vim.wait(3000, function()
            return second_handle.pid() ~= nil
          end),
          "second PTY monitor did not open"
        )
        assert.is_true(second_handle.cancel("pty-reopen"))
        assert.is_true(
          vim.wait(3000, function()
            return second_result ~= nil
          end),
          "second PTY monitor did not stop"
        )
        assert.equals("monitor-stopped", second_result.error.code)
      end)

      local first_stopped = cancel_and_wait(first_handle)
      local second_stopped = cancel_and_wait(second_handle)
      write(stop_file, "stop")
      local helper_stopped = vim.wait(3000, function()
        return helper_result ~= nil
      end)
      if not helper_stopped then
        helper:kill(15)
        helper_stopped = vim.wait(3000, function()
          return helper_result ~= nil
        end)
      end
      if first_stopped and second_stopped and helper_stopped then
        vim.fn.delete(root, "rf")
      end
      assert.is_true(first_stopped, "first PTY monitor did not reach a terminal state")
      assert.is_true(
        second_stopped,
        "second PTY monitor did not reach a terminal state"
      )
      assert.is_true(helper_stopped, "Python PTY helper did not reach a terminal state")
      assert.is_true(ok, err)
      assert.equals(0, helper_result.code, helper_result.stderr)
    end)
  end)
else
  pending(
    pty_skip_reason
      or "nvim-stm32 real PTY UART integration: set NVIM_STM32_REAL_PTY=1 to run the Python stdlib PTY smoke test"
  )
end

describe("nvim-stm32 F429 software acceptance entry point", function()
  local root
  local corpus
  local wrapper
  local fixture_path

  local function executable(path, lines)
    write(path, lines)
    assert.is_true(vim.uv.fs_chmod(path, 493))
  end

  before_each(function()
    root = vim.fn.tempname()
    corpus = root .. "/corpus"
    wrapper = root .. "/scripts/validate-f429-software.sh"
    fixture_path = root .. "/bin:" .. vim.env.PATH
    vim.fn.mkdir(corpus, "p")
    vim.fn.mkdir(root .. "/scripts", "p")
    vim.fn.mkdir(root .. "/bin", "p")
    assert.is_true(
      vim.uv.fs_copyfile(repo .. "/scripts/validate-f429-software.sh", wrapper)
    )
    assert.is_true(vim.uv.fs_chmod(wrapper, 493))
    executable(root .. "/scripts/test.sh", {
      "#!/bin/sh",
      "set -eu",
      'if [ "${NVIM_STM32_TEST_SIGNAL_TERM:-}" = 1 ]; then',
      '  kill -TERM "$PPID"',
      "fi",
    })
    executable(root .. "/bin/stylua", { "#!/bin/sh", "exit 0" })
    executable(root .. "/scripts/validate-corpus.sh", {
      "#!/bin/sh",
      "set -eu",
      'if [ "${2:-}" = --build ]; then',
      "  echo '13/13 projects passed'",
      "  exit 0",
      "fi",
      "printf '%s\\n' \"${NVIM_STM32_TEST_DISCOVERY_OUTPUT:-13/13 projects passed}\"",
      'exit "${NVIM_STM32_TEST_DISCOVERY_STATUS:-0}"',
    })
  end)

  after_each(function()
    vim.fn.delete(root, "rf")
  end)

  it("is valid POSIX shell", function()
    local result = vim
      .system({
        "sh",
        "-n",
        repo .. "/scripts/validate-f429-software.sh",
      }, { text = true })
      :wait()

    assert.equals(0, result.code, result.stderr)
  end)

  it("requires an explicit corpus root before running any gate", function()
    local result = vim
      .system({ repo .. "/scripts/validate-f429-software.sh" }, {
        text = true,
      })
      :wait()

    assert.equals(2, result.code)
    assert.matches(
      "usage: scripts/validate%-f429%-software.sh CORPUS_ROOT",
      result.stderr
    )
  end)

  it("rejects a missing corpus directory before running any gate", function()
    local result = vim
      .system({
        repo .. "/scripts/validate-f429-software.sh",
        repo .. "/tests/fixtures/not-a-corpus",
      }, { text = true })
      :wait()

    assert.equals(2, result.code)
    assert.matches("corpus root is not a directory", result.stderr, 1, true)
  end)

  it("prints discovery diagnostics before its custom nonzero-status failure", function()
    local result = vim
      .system({ wrapper, corpus }, {
        text = true,
        env = {
          PATH = fixture_path,
          NVIM_STM32_TEST_DISCOVERY_OUTPUT = "controlled discovery failure",
          NVIM_STM32_TEST_DISCOVERY_STATUS = "7",
        },
      })
      :wait()

    assert.equals(1, result.code)
    assert.matches("controlled discovery failure", result.stdout, 1, true)
    assert.matches("F429 discovery gate failed with status 7", result.stderr, 1, true)
  end)

  it("prints discovery diagnostics before its wrong-summary failure", function()
    local result = vim
      .system({ wrapper, corpus }, {
        text = true,
        env = {
          PATH = fixture_path,
          NVIM_STM32_TEST_DISCOVERY_OUTPUT = "12/13 projects passed",
        },
      })
      :wait()

    assert.equals(1, result.code)
    assert.matches("12/13 projects passed", result.stdout, 1, true)
    assert.matches("expected exactly 13/13 projects", result.stderr, 1, true)
  end)

  it("returns the conventional nonzero status when TERM interrupts it", function()
    local result = vim
      .system({ wrapper, corpus }, {
        text = true,
        env = {
          PATH = fixture_path,
          NVIM_STM32_TEST_SIGNAL_TERM = "1",
        },
      })
      :wait()

    assert.equals(143, result.code, vim.inspect(result))
  end)
end)
