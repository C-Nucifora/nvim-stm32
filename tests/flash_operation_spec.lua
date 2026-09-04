local model = require("nvim-stm32.model")
local build = require("nvim-stm32.operations.build")
local nvim_stm32 = require("nvim-stm32")
local flash = require("nvim-stm32.operations.flash")
local operation = require("nvim-stm32.operation")
local process = require("nvim-stm32.process")
local session = require("nvim-stm32.session")

local function write(path, text)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  vim.fn.writefile(vim.split(text or "firmware", "\n", { plain = true }), path)
end

local function executable(root, name)
  local path = root .. "/tools/" .. name
  write(path, "#!/bin/sh")
  vim.uv.fs_chmod(path, 493)
  return path
end

local function write_presets(root)
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
end

local function image(root, id, address, origin)
  origin = origin or address or 0x08000000
  local linker_path = root .. "/" .. id .. ".ld"
  write(
    linker_path,
    string.format("MEMORY\n{\nFLASH (rx) : ORIGIN = 0x%08X, LENGTH = 512K\n}", origin)
  )
  return {
    id = id,
    name = id,
    build_target = id,
    flash = address and { address = address } or nil,
    target = {
      mcu = "STM32F429ZITx",
      openocd_cfg = "target/stm32f4x.cfg",
      debug_ids = { 0x419 },
      debug_idcode_address = 0xE0042000,
      signals = {
        {
          source = "linker",
          file = linker_path,
          mcu = "STM32F429ZITx",
          confidence = "inferred",
        },
      },
    },
  }
end

local function project(root, images, flash_order)
  write_presets(root)
  return model.project({
    id = root,
    root = root,
    kind = "cmake_presets",
    build = { adapter = "cmake_presets", marker = root .. "/CMakePresets.json" },
    images = images,
    flash_order = flash_order or {},
  })
end

local function modified_ns(path)
  local stat = vim.uv.fs_stat(path)
  local mtime = stat and stat.mtime or {}
  return (mtime.sec or 0) * 1000000000 + (mtime.nsec or 0)
end

local function artifact(root, id, kind, build_id, contents)
  local path = root .. "/build/Debug/" .. id .. "." .. kind
  write(path, contents)
  return model.artifact({
    image_id = id,
    configuration = "Debug",
    kind = kind,
    path = path,
    build_target = id,
    modified_ns = modified_ns(path),
    build_id = build_id or "build-1",
  })
end

local function cube_opts(root, artifacts)
  executable(root, "arm-none-eabi-objdump")
  return {
    backend = "cubeprogrammer",
    programmer_path = executable(root, "STM32_Programmer_CLI"),
    configuration = "Debug",
    probe = { backend = "cubeprogrammer", serial = "ABC123" },
    artifacts = artifacts,
    build_id = "build-1",
    toolchain_path = root .. "/tools",
  }
end

describe("nvim-stm32 flash operation plans", function()
  local root

  before_each(function()
    root = vim.fn.tempname()
    vim.fn.mkdir(root .. "/build/Debug", "p")
    session.clear()
  end)

  after_each(function()
    session.clear()
    vim.fn.delete(root, "rf")
  end)

  it("plans identify, mandatory program verification, then one reset", function()
    local app = image(root, "application")
    local source = project(root, { app })
    local elf = artifact(root, "application", "elf")
    local opts = cube_opts(root, { elf })

    local plan = assert(flash.plan("flash", source, opts))

    assert.equals("flash", plan.kind)
    assert.same({ "application" }, plan.images)
    assert.same({ kind = "project-artifacts", id = root }, plan.locks[1])
    assert.same({ kind = "probe", id = "ABC123" }, plan.locks[2])
    assert.equals("once-after-verify", plan.reset_policy)
    assert.same({
      opts.programmer_path,
      "-c",
      "port=SWD",
      "mode=HOTPLUG",
      "sn=ABC123",
    }, plan.commands[1].argv)
    assert.same({
      opts.programmer_path,
      "-c",
      "port=SWD",
      "mode=UR",
      "sn=ABC123",
      "-w",
      vim.uv.fs_realpath(elf.path),
      "-v",
    }, plan.commands[2].argv)
    assert.same({
      opts.programmer_path,
      "-c",
      "port=SWD",
      "mode=UR",
      "sn=ABC123",
      "-rst",
    }, plan.commands[3].argv)
    assert.same({
      { phase = "identify", image_id = nil },
      {
        phase = "program-verify",
        image_id = "application",
        artifact = plan.metadata.layout[1].artifact,
      },
      { phase = "reset", image_id = nil },
    }, plan.metadata.steps)
    assert.equals("cubeprogrammer", plan.metadata.backend)
    assert.equals("ABC123", plan.metadata.probe.serial)
  end)

  it("keeps multi-image program commands in resolved flash order", function()
    local boot = image(root, "boot", 0x08000000)
    local app = image(root, "app", 0x08100000)
    local source = project(root, { boot, app }, { "app" })
    local opts = cube_opts(root, {
      artifact(root, "boot", "elf"),
      artifact(root, "app", "elf"),
    })

    local plan = assert(flash.plan("flash", source, opts))

    assert.same({ "app", "boot" }, plan.images)
    assert.equals("app", plan.metadata.steps[2].image_id)
    assert.equals("boot", plan.metadata.steps[3].image_id)
    assert.equals("reset", plan.metadata.steps[4].phase)
    assert.equals(4, #plan.commands)
  end)

  it("plans reset with identity first and without artifacts or a build", function()
    local source = project(root, { image(root, "application") })
    local opts = cube_opts(root)
    opts.artifacts = nil
    opts.build_id = nil

    local plan = assert(flash.plan("reset", source, opts))

    assert.equals("reset", plan.kind)
    assert.equals(2, #plan.commands)
    assert.same(
      { "identify", "reset" },
      vim.tbl_map(function(step)
        return step.phase
      end, plan.metadata.steps)
    )
    assert.same({}, plan.metadata.layout)
    assert.equals("once", plan.reset_policy)
  end)

  it("uses one normalized physical probe lock across programmer backends", function()
    local source = project(root, { image(root, "application") })
    local cube = cube_opts(root)
    cube.probe = { backend = "cubeprogrammer", serial = "0xabc123" }
    local openocd_path = executable(root, "openocd")

    local cube_plan = assert(flash.plan("reset", source, cube))
    local openocd_plan = assert(flash.plan("reset", source, {
      backend = "openocd",
      openocd_path = openocd_path,
      probe = { backend = "openocd", serial = "ABC123" },
    }))

    assert.same({ kind = "probe", id = "ABC123" }, cube_plan.locks[1])
    assert.same(cube_plan.locks, openocd_plan.locks)
    local release = assert(require("nvim-stm32.locks").acquire("cube", cube_plan.locks))
    local competing, err =
      require("nvim-stm32.locks").acquire("openocd", openocd_plan.locks)
    assert.is_nil(competing)
    assert.equals("operation-lock-contended", err.code)
    release()
  end)

  it("does not conflate different normalized probe serials", function()
    local source = project(root, { image(root, "application") })
    local first_opts = cube_opts(root)
    first_opts.probe = { backend = "cubeprogrammer", serial = "ABC123" }
    local second_opts = cube_opts(root)
    second_opts.probe = { backend = "cubeprogrammer", serial = "ABC124" }

    local first = assert(flash.plan("reset", source, first_opts))
    local second = assert(flash.plan("reset", source, second_opts))

    assert.not_equals(first.locks[1].id, second.locks[1].id)
  end)

  it("requires confirmation for erase execution plans", function()
    local source = project(root, { image(root, "application") })
    local opts = cube_opts(root)
    opts.artifacts = nil

    local plan, err = flash.plan("erase", source, opts)

    assert.is_nil(plan)
    assert.equals("erase-confirmation-required", err.code)
  end)

  it("allows a non-executing erase preview without confirmation", function()
    local source = project(root, { image(root, "application") })
    local opts = cube_opts(root)
    opts.artifacts = nil
    opts.preview = true

    local plan = assert(flash.plan("erase", source, opts))

    assert.same(
      { "identify", "erase" },
      vim.tbl_map(function(step)
        return step.phase
      end, plan.metadata.steps)
    )
    assert.is_false(plan.metadata.confirmed)
    assert.is_true(plan.metadata.preview)
    assert.equals("none", plan.reset_policy)
  end)

  it("plans one confirmed mass erase after identity", function()
    local source = project(root, { image(root, "application") })
    local opts = cube_opts(root)
    opts.artifacts = nil
    opts.confirmed = true

    local plan = assert(flash.plan("erase", source, opts))

    assert.equals(2, #plan.commands)
    assert.same({
      opts.programmer_path,
      "-c",
      "port=SWD",
      "mode=UR",
      "sn=ABC123",
      "-e",
      "all",
    }, plan.commands[2].argv)
  end)

  it("uses a remembered probe serial without enumerating", function()
    local source = project(root, { image(root, "application") })
    session.select(root, { probe_serial = "REMEMBERED" })
    local opts = cube_opts(root)
    opts.probe = nil

    local plan = assert(flash.plan("reset", source, opts))

    assert.equals("REMEMBERED", plan.metadata.probe.serial)
  end)

  it("rejects plans without a selected probe", function()
    local source = project(root, { image(root, "application") })
    local opts = cube_opts(root)
    opts.probe = nil

    local plan, err = flash.plan("reset", source, opts)

    assert.is_nil(plan)
    assert.equals("probe-selection-required", err.code)
  end)

  it("rejects a target without an expected observed identity", function()
    local app = image(root, "application")
    app.target.mcu = "STM32F401RETx"
    app.target.debug_ids = nil
    app.target.debug_idcode_address = nil
    local source = project(root, { app })

    local plan, err = flash.plan("reset", source, cube_opts(root))

    assert.is_nil(plan)
    assert.equals("target-identity-unsupported", err.code)
  end)

  it("derives F429 identity policy from the target table", function()
    local app = image(root, "application")
    app.target.debug_ids = nil
    app.target.debug_idcode_address = nil
    local source = project(root, { app })

    local plan = assert(flash.plan("reset", source, cube_opts(root)))

    assert.same({ 0x419 }, plan.metadata.target.debug_ids)
    assert.equals(0xE0042000, plan.metadata.target.debug_idcode_address)
  end)

  it(
    "renders pinned backend, probe, artifacts, addresses, phases, and reset policy",
    function()
      local app = image(root, "application")
      local source = project(root, { app })
      local elf = artifact(root, "application", "elf")
      local plan = assert(flash.plan("flash", source, cube_opts(root, { elf })))

      local text = table.concat(require("nvim-stm32.ui.plan").lines(plan), "\n")

      assert.matches("Backend: cubeprogrammer", text, 1, true)
      assert.matches("Probe: ABC123", text, 1, true)
      assert.matches("Artifact: " .. vim.uv.fs_realpath(elf.path), text, 1, true)
      assert.matches("Address: embedded in ELF", text, 1, true)
      assert.matches("Phase: program-verify", text, 1, true)
      assert.matches("Reset policy: once-after-verify", text, 1, true)
    end
  )

  it("marks erase plans opened through the plan UI as previews", function()
    local ui_plan = require("nvim-stm32.ui.plan")
    local original_plan = nvim_stm32.plan
    local received
    nvim_stm32.plan = function(kind, opts)
      received = { kind = kind, opts = opts }
      return model.plan({
        id = "erase-preview",
        kind = "erase",
        project_id = root,
        images = { "application" },
        commands = {},
        locks = {},
        reset_policy = "none",
        metadata = {},
      })
    end

    local buffer = ui_plan.current("erase", {})
    nvim_stm32.plan = original_plan

    assert.equals("erase", received.kind)
    assert.is_true(received.opts.preview)
    vim.api.nvim_buf_delete(buffer, { force = true })
  end)
end)

describe("nvim-stm32 flash operation execution", function()
  local root
  local original_process_run
  local original_build_run
  local original_execute
  local original_executable
  local original_config
  local original_inspect_elf_command
  local original_schedule

  local function completed_handle(id)
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

  local function fake_sequence(outputs, calls)
    process.run = function(commands, opts, callback)
      local records = {}
      local combined = ""
      for index, command in ipairs(commands) do
        calls[#calls + 1] = vim.deepcopy(command.argv)
        local item = outputs[index] or { code = 0, output = "" }
        combined = combined .. (item.output or "")
        records[#records + 1] = {
          argv = vim.deepcopy(command.argv),
          code = item.code or 0,
          signal = 0,
          output = item.output or "",
        }
        if item.code and item.code ~= 0 then
          callback({
            code = item.code,
            signal = 0,
            output = combined,
            command = command.argv,
            command_index = index,
            commands = records,
          })
          return completed_handle(90)
        end
        if opts.after_command then
          local continue, err = opts.after_command(records[#records])
          if continue == nil and err then
            callback({
              code = 0,
              signal = 0,
              output = combined,
              command = command.argv,
              command_index = index,
              commands = records,
              error = err,
            })
            return completed_handle(90)
          end
        end
      end
      callback({
        code = 0,
        signal = 0,
        output = combined,
        command = commands[#commands].argv,
        command_index = #commands,
        commands = records,
      })
      return completed_handle(90)
    end
  end

  local function build_result(artifacts, build_id)
    return model.result({
      ok = true,
      code = 0,
      output = "built",
      artifacts = artifacts,
      metadata = { operation_id = build_id or "build-immediate" },
    })
  end

  before_each(function()
    root = vim.fn.tempname()
    vim.fn.mkdir(root .. "/build/Debug", "p")
    session.clear()
    original_process_run = process.run
    original_build_run = build.run
    original_execute = operation.execute
    original_executable = vim.fn.executable
    original_config = nvim_stm32.config
    original_inspect_elf_command = flash.inspect_elf_command
    original_schedule = vim.schedule
    flash.inspect_elf_command = function(_, item)
      return {
        {
          index = 0,
          name = ".text",
          size = 8,
          vma = item.region.origin,
          lma = item.region.origin,
          file_offset = 0x1000,
          alignment = 4,
          flags = { "CONTENTS", "ALLOC", "LOAD", "READONLY", "CODE" },
        },
      }
    end
    vim.fn.executable = function()
      return 1
    end
  end)

  after_each(function()
    process.run = original_process_run
    build.run = original_build_run
    operation.execute = original_execute
    vim.fn.executable = original_executable
    nvim_stm32.config = original_config
    flash.inspect_elf_command = original_inspect_elf_command
    vim.schedule = original_schedule
    session.clear()
    vim.fn.delete(root, "rf")
  end)

  it("blocks a target mismatch before the first state-changing command", function()
    local source = project(root, { image(root, "application") })
    local elf = artifact(root, "application", "elf")
    local plan = assert(flash.plan("flash", source, cube_opts(root, { elf })))
    local calls = {}
    fake_sequence({ { output = "Device ID : 0x413\n" } }, calls)
    local result

    flash.execute(plan, {}, function(value)
      result = value
    end)

    assert.equals(1, #calls)
    assert.is_false(result.ok)
    assert.equals("target-mismatch", result.error.code)
    assert.equals("cubeprogrammer", result.error.backend)
    assert.equals("identify", result.error.phase)
    assert.same(plan.commands[1].argv, result.error.command)
    assert.matches("0x413", result.error.output, 1, true)
  end)

  it("honors a one-plan target mismatch override", function()
    local source = project(root, { image(root, "application") })
    local elf = artifact(root, "application", "elf")
    local opts = cube_opts(root, { elf })
    opts.allow_target_mismatch = true
    local plan = assert(flash.plan("flash", source, opts))
    local calls = {}
    fake_sequence({
      { output = "Device ID : 0x413\n" },
      { output = "Download verified successfully\n" },
      { output = "reset\n" },
    }, calls)
    local result

    flash.execute(plan, {}, function(value)
      result = value
    end)

    assert.is_true(result.ok, vim.inspect(result))
    assert.equals(3, #calls)
  end)

  it("does not accept a target mismatch override from setup config", function()
    local source = project(root, { image(root, "application") })
    local programmer = executable(root, "configured-programmer")
    nvim_stm32.setup({
      flash_backend = "cubeprogrammer",
      programmer_path = programmer,
      allow_target_mismatch = true,
    })
    local calls = {}
    fake_sequence({
      { output = "Device ID : 0x413\n" },
      { output = "reset\n" },
    }, calls)
    local result

    nvim_stm32.run("reset", {
      project = source,
      probe = { backend = "cubeprogrammer", serial = "ABC123" },
    }, function(value)
      result = value
    end)

    assert.equals(1, #calls)
    assert.is_false(result.ok)
    assert.equals("target-mismatch", result.error.code)
  end)

  it("accepts a target mismatch override from the direct invocation", function()
    local source = project(root, { image(root, "application") })
    local programmer = executable(root, "configured-programmer")
    nvim_stm32.setup({
      flash_backend = "cubeprogrammer",
      programmer_path = programmer,
    })
    local calls = {}
    fake_sequence({
      { output = "Device ID : 0x413\n" },
      { output = "reset\n" },
    }, calls)
    local result

    nvim_stm32.run("reset", {
      project = source,
      probe = { backend = "cubeprogrammer", serial = "ABC123" },
      allow_target_mismatch = true,
    }, function(value)
      result = value
    end)

    assert.equals(2, #calls)
    assert.is_true(result.ok, vim.inspect(result))
  end)

  it(
    "copies a target mismatch override only from direct public plan options",
    function()
      local source = project(root, { image(root, "application") })
      local programmer = executable(root, "configured-programmer")
      nvim_stm32.setup({
        flash_backend = "cubeprogrammer",
        programmer_path = programmer,
        allow_target_mismatch = true,
      })
      local opts = {
        project = source,
        probe = { backend = "cubeprogrammer", serial = "ABC123" },
      }

      local guarded = assert(nvim_stm32.plan("reset", opts))
      opts.allow_target_mismatch = true
      local allowed = assert(nvim_stm32.plan("reset", opts))

      assert.is_false(guarded.metadata.allow_target_mismatch)
      assert.is_true(allowed.metadata.allow_target_mismatch)
    end
  )

  it("requires stlink verification output before reset", function()
    local app = image(root, "application", 0x08000000)
    local source = project(root, { app })
    local bin = artifact(root, "application", "bin")
    local opts = {
      backend = "stlink",
      stlink_path = executable(root, "st-flash"),
      configuration = "Debug",
      probe = { backend = "stlink", serial = "ABC123" },
      artifacts = { bin },
      build_id = "build-1",
    }
    executable(root, "st-info")
    local plan = assert(flash.plan("flash", source, opts))
    local calls = {}
    fake_sequence({
      {
        output = "serial: ABC123\nchipid: 0x419\ndev-type: STM32F42x_F43x\n",
      },
      { output = "write complete without verification marker\n" },
    }, calls)
    local result

    flash.execute(plan, opts, function(value)
      result = value
    end)

    assert.equals(2, #calls)
    assert.is_false(result.ok)
    assert.equals("flash-verification-missing", result.error.code)
    assert.equals("program-verify", result.error.phase)
    assert.equals("application", result.error.image_id)
  end)

  it("stops later images and reset after a program failure", function()
    local boot = image(root, "boot", 0x08000000)
    local app = image(root, "app", 0x08100000)
    local source = project(root, { boot, app })
    local opts = cube_opts(root, {
      artifact(root, "boot", "elf"),
      artifact(root, "app", "elf"),
    })
    local plan = assert(flash.plan("flash", source, opts))
    local calls = {}
    fake_sequence({
      { output = "Device ID : 0x419\n" },
      { code = 7, output = "verify failed\n" },
    }, calls)
    local result

    flash.execute(plan, opts, function(value)
      result = value
    end)

    assert.equals(2, #calls)
    assert.is_false(result.ok)
    assert.equals("cubeprogrammer", result.error.backend)
    assert.equals("program-verify", result.error.phase)
    assert.equals("boot", result.error.image_id)
    assert.same(plan.commands[2].argv, result.error.command)
    assert.matches("verify failed", result.error.output, 1, true)
  end)

  it("rejects zero-exit flash completion terminated by a signal", function()
    local source = project(root, { image(root, "application") })
    local elf = artifact(root, "application", "elf")
    local plan = assert(flash.plan("flash", source, cube_opts(root, { elf })))

    local result = flash.complete(plan, {
      code = 0,
      signal = 15,
      output = "terminated",
      command = plan.commands[2].argv,
      command_index = 2,
      commands = {
        {
          argv = plan.commands[1].argv,
          output = "Device ID : 0x419",
          code = 0,
          signal = 0,
        },
        { argv = plan.commands[2].argv, output = "terminated", code = 0, signal = 15 },
      },
    })

    assert.is_false(result.ok)
    assert.equals("flash-command-failed", result.error.code)
  end)

  it("resets exactly once after every image verifies", function()
    local boot = image(root, "boot", 0x08000000)
    local app = image(root, "app", 0x08100000)
    local source = project(root, { boot, app })
    local opts = cube_opts(root, {
      artifact(root, "boot", "elf"),
      artifact(root, "app", "elf"),
    })
    local plan = assert(flash.plan("flash", source, opts))
    local calls = {}
    fake_sequence({
      { output = "Device ID : 0x419\n" },
      { output = "verified boot\n" },
      { output = "verified app\n" },
      { output = "reset\n" },
    }, calls)
    local result

    flash.execute(plan, opts, function(value)
      result = value
    end)

    assert.is_true(result.ok, vim.inspect(result))
    assert.equals(4, #calls)
    local resets = vim.tbl_filter(function(argv)
      return vim.tbl_contains(argv, "-rst")
    end, calls)
    assert.equals(1, #resets)
  end)

  it("revalidates changed artifacts before identity connects", function()
    local app = image(root, "application", nil, 0x08000000)
    write(
      root .. "/application.ld",
      "MEMORY\n{\nFLASH (rx) : ORIGIN = 0x08000000, LENGTH = 8\n}"
    )
    local source = project(root, { app })
    local elf = artifact(root, "application", "elf", nil, "tiny")
    local opts = cube_opts(root, { elf })
    local plan = assert(flash.plan("flash", source, opts))
    write(elf.path, "this artifact is now too large")
    local calls = 0
    process.run = function()
      calls = calls + 1
    end
    local result

    flash.execute(plan, opts, function(value)
      result = value
    end)

    assert.equals(0, calls)
    assert.is_false(result.ok)
    assert.equals("flash-artifact-changed", result.error.code)
  end)

  it("rejects invalid fake objdump load ranges before identity starts", function()
    local source = project(root, { image(root, "application") })
    local elf = artifact(root, "application", "elf")
    local opts = cube_opts(root, { elf })
    local objdump_path = root .. "/tools/arm-none-eabi-objdump"
    write(
      objdump_path,
      [[#!/bin/sh
printf '%s\n' 'fake.elf: file format elf32-littlearm'
printf '%s\n' 'Sections:'
printf '%s\n' 'Idx Name          Size      VMA       LMA       File off  Algn'
printf '%s\n' '  0 .text         00000008  08200000  08200000  00001000  2**2'
printf '%s\n' '                  CONTENTS, ALLOC, LOAD, READONLY, CODE'
]]
    )
    vim.uv.fs_chmod(objdump_path, 493)
    local plan = assert(flash.plan("flash", source, opts))
    flash.inspect_elf_command = original_inspect_elf_command
    local starts = 0
    process.run = function()
      starts = starts + 1
    end
    local result

    flash.execute(plan, opts, function(value)
      result = value
    end)

    assert.equals(0, starts)
    assert.is_false(result.ok)
    assert.equals("flash-range-outside-region", result.error.code)
  end)

  it("rejects altered phase metadata before identity connects", function()
    local source = project(root, { image(root, "application") })
    local elf = artifact(root, "application", "elf")
    local opts = cube_opts(root, { elf })
    local plan = assert(flash.plan("flash", source, opts))
    plan.metadata.steps[1].phase = "reset"
    local calls = 0
    process.run = function()
      calls = calls + 1
    end
    local result

    flash.execute(plan, opts, function(value)
      result = value
    end)

    assert.equals(0, calls)
    assert.is_false(result.ok)
    assert.equals("flash-plan-tampered", result.error.code)
  end)

  it("refuses to execute an unconfirmed erase preview", function()
    local source = project(root, { image(root, "application") })
    local opts = cube_opts(root)
    opts.preview = true
    local plan = assert(flash.plan("erase", source, opts))
    local calls = 0
    process.run = function()
      calls = calls + 1
    end
    local result

    flash.execute(plan, opts, function(value)
      result = value
    end)

    assert.equals(0, calls)
    assert.is_false(result.ok)
    assert.equals("erase-confirmation-required", result.error.code)
  end)

  it("feeds an immediately returned successful build into the flash plan", function()
    local source = project(root, { image(root, "application") })
    local elf = artifact(root, "application", "elf", "build-immediate")
    local opts = cube_opts(root)
    opts.project = source
    opts.artifacts = nil
    opts.build_id = nil
    local hardware_plan
    build.run = function(build_opts, callback)
      assert.same(source, build_opts.project)
      callback(build_result({ elf }))
      return completed_handle(31)
    end
    operation.execute = function(plan, _, _, callback)
      hardware_plan = plan
      callback(model.result({
        ok = true,
        code = 0,
        output = "flashed",
        artifacts = plan.metadata.layout[1] and { plan.metadata.layout[1].artifact }
          or {},
        metadata = { operation_id = plan.id },
      }))
      return completed_handle(32)
    end
    local result

    local handle = flash.current("flash", opts, function(value)
      result = value
    end)

    assert.is_true(vim.wait(100, function()
      return hardware_plan ~= nil
    end))
    assert.equals("build-immediate", hardware_plan.metadata.build_id)
    assert.equals(
      vim.uv.fs_realpath(elf.path),
      hardware_plan.metadata.layout[1].artifact.path
    )
    assert.is_true(result.ok)
    assert.equals("completed", handle.state())
  end)

  it("uses a matching fresh session artifact when build is false", function()
    local source = project(root, { image(root, "application") })
    local elf = artifact(root, "application", "elf", "build-session")
    session.record(root, build_result({ elf }, "build-session"))
    local opts = cube_opts(root)
    opts.project = source
    opts.artifacts = nil
    opts.build_id = nil
    opts.build = false
    local build_calls = 0
    local hardware_plan
    build.run = function()
      build_calls = build_calls + 1
    end
    operation.execute = function(plan, _, _, callback)
      hardware_plan = plan
      callback(build_result({}))
      return completed_handle(33)
    end

    flash.current("flash", opts, function() end)

    assert.equals(0, build_calls)
    assert.equals("build-session", hardware_plan.metadata.build_id)
  end)

  it("rejects build-free flash when the session has no fresh artifact", function()
    local source = project(root, { image(root, "application") })
    local opts = cube_opts(root)
    opts.project = source
    opts.artifacts = nil
    opts.build_id = nil
    opts.build = false
    local process_calls = 0
    operation.execute = function()
      process_calls = process_calls + 1
    end
    local result

    flash.current("flash", opts, function(value)
      result = value
    end)

    assert.equals(0, process_calls)
    assert.is_false(result.ok)
    assert.equals("flash-artifact-missing", result.error.code)
  end)

  it(
    "rejects session artifacts that are not tied to the last successful build",
    function()
      local source = project(root, { image(root, "application") })
      local elf = artifact(root, "application", "elf", "build-untracked")
      session.select(root, { artifacts = { elf } })
      local opts = cube_opts(root)
      opts.project = source
      opts.artifacts = nil
      opts.build_id = nil
      opts.build = false
      local hardware_calls = 0
      operation.execute = function()
        hardware_calls = hardware_calls + 1
      end
      local result

      flash.current("flash", opts, function(value)
        result = value
      end)

      assert.equals(0, hardware_calls)
      assert.is_false(result.ok)
      assert.equals("flash-build-stale", result.error.code)
    end
  )

  it("uses setup backend paths when current options do not repeat them", function()
    local source = project(root, { image(root, "application") })
    local elf = artifact(root, "application", "elf", "build-configured")
    session.record(root, build_result({ elf }, "build-configured"))
    local setup_root = root .. "/configured"
    local programmer = executable(setup_root, "configured-programmer")
    local objdump_path = executable(setup_root, "arm-none-eabi-objdump")
    nvim_stm32.setup({
      flash_backend = "cubeprogrammer",
      programmer_path = programmer,
      toolchain_path = setup_root .. "/tools",
    })
    local hardware_plan
    operation.execute = function(plan, _, _, callback)
      hardware_plan = plan
      callback(build_result({}))
      return completed_handle(72)
    end

    flash.current("flash", {
      project = source,
      configuration = "Debug",
      probe = { backend = "cubeprogrammer", serial = "ABC123" },
      build = false,
    }, function() end)

    assert.equals("cubeprogrammer", hardware_plan.metadata.backend)
    assert.same({
      program = programmer,
      identify = programmer,
      list = programmer,
    }, hardware_plan.metadata.tools)
    assert.equals(objdump_path, hardware_plan.metadata.elf_commands[1].argv[1])
  end)

  it(
    "waits for an accepted build cancellation and delivers its callback once",
    function()
      local source = project(root, { image(root, "application") })
      local elf = artifact(root, "application", "elf", "build-race")
      local opts = cube_opts(root)
      opts.project = source
      opts.artifacts = nil
      local build_callback
      local build_cancelled = 0
      local hardware_calls = 0
      build.run = function(_, callback)
        build_callback = callback
        return {
          state = function()
            return "running"
          end,
          cancel = function()
            build_cancelled = build_cancelled + 1
            return true
          end,
          pid = function()
            return 44
          end,
        }
      end
      operation.execute = function()
        hardware_calls = hardware_calls + 1
      end
      local callback_calls = 0
      local result
      local handle = flash.current("flash", opts, function(value)
        callback_calls = callback_calls + 1
        result = value
      end)

      assert.equals(44, handle.pid())
      assert.is_true(handle.cancel("test"))
      assert.equals(1, build_cancelled)
      assert.equals("cancelling", handle.state())
      assert.equals(0, hardware_calls)
      assert.equals(0, callback_calls)

      build_callback(model.result({
        ok = false,
        code = 0,
        output = "terminated",
        artifacts = {},
        error = model.error({
          code = "process-failed",
          message = "nvim-stm32: build command did not complete successfully",
          operation = "build",
          hint = "inspect output",
        }),
        metadata = { operation_id = "build-race" },
      }))

      assert.equals(1, callback_calls)
      assert.is_false(result.ok)
      assert.equals("cancelled", handle.state())
    end
  )

  it("preserves a queued build result when child cancellation is rejected", function()
    local source = project(root, { image(root, "application") })
    local elf = artifact(root, "application", "elf", "build-queued")
    local opts = cube_opts(root)
    opts.project = source
    opts.artifacts = nil
    local build_callback
    build.run = function(_, callback)
      build_callback = callback
      return {
        state = function()
          return "completing"
        end,
        cancel = function()
          return false
        end,
        pid = function()
          return nil
        end,
      }
    end
    local hardware_callback
    operation.execute = function(_, _, _, callback)
      hardware_callback = callback
      return completed_handle(91)
    end
    local callback_calls = 0
    local result
    local handle = flash.current("flash", opts, function(value)
      callback_calls = callback_calls + 1
      result = value
    end)

    assert.is_false(handle.cancel("late"))
    build_callback(build_result({ elf }, "build-queued"))
    assert.is_true(vim.wait(100, function()
      return hardware_callback ~= nil
    end))
    hardware_callback(build_result({}))

    assert.equals(1, callback_calls)
    assert.is_true(result.ok)
    assert.equals("completed", handle.state())
  end)

  it("cancels the scheduled gap without starting hardware", function()
    local source = project(root, { image(root, "application") })
    local elf = artifact(root, "application", "elf", "build-gap")
    local opts = cube_opts(root)
    opts.project = source
    opts.artifacts = nil
    local scheduled
    vim.schedule = function(callback)
      scheduled = callback
    end
    build.run = function(_, callback)
      callback(build_result({ elf }, "build-gap"))
      return completed_handle(93)
    end
    local hardware_calls = 0
    operation.execute = function()
      hardware_calls = hardware_calls + 1
    end
    local callback_calls = 0
    local result

    local handle = flash.current("flash", opts, function(value)
      callback_calls = callback_calls + 1
      result = value
    end)

    assert.equals("between-stages", handle.state())
    assert.is_nil(handle.pid())
    assert.is_true(handle.cancel("between-stages"))
    assert.equals("cancelled", handle.state())
    assert.is_nil(handle.pid())
    assert.equals(1, callback_calls)
    assert.is_false(result.ok)
    assert.equals("flash-cancelled", result.error.code)
    scheduled()
    assert.equals(0, hardware_calls)
    assert.equals(1, callback_calls)
  end)

  it("keeps accepted hardware cancellation nonterminal until child exit", function()
    local source = project(root, { image(root, "application") })
    local opts = cube_opts(root)
    opts.project = source
    opts.build = false
    opts.artifacts = { artifact(root, "application", "elf", "build-running") }
    opts.build_id = "build-running"
    local hardware_callback
    operation.execute = function(_, _, _, callback)
      hardware_callback = callback
      return {
        state = function()
          return "cancelling"
        end,
        cancel = function()
          return true
        end,
        pid = function()
          return 92
        end,
      }
    end
    local callback_calls = 0
    local handle = flash.current("flash", opts, function()
      callback_calls = callback_calls + 1
    end)

    assert.is_true(handle.cancel("test"))
    assert.equals("cancelling", handle.state())
    assert.equals(0, callback_calls)

    hardware_callback(model.result({
      ok = false,
      code = 0,
      output = "terminated",
      artifacts = {},
      error = model.error({
        code = "flash-command-failed",
        message = "nvim-stm32: flash command did not complete successfully",
        operation = "flash",
        hint = "inspect output",
      }),
      metadata = { operation_id = "flash-running" },
    }))

    assert.equals(1, callback_calls)
    assert.equals("cancelled", handle.state())
  end)

  it("delegates cancellation to hardware after a synchronous build callback", function()
    local source = project(root, { image(root, "application") })
    local elf = artifact(root, "application", "elf", "build-sync")
    local opts = cube_opts(root)
    opts.project = source
    opts.artifacts = nil
    local hardware_cancelled = 0
    build.run = function(_, callback)
      callback(build_result({ elf }, "build-sync"))
      return completed_handle(45)
    end
    operation.execute = function()
      return {
        state = function()
          return "running"
        end,
        cancel = function()
          hardware_cancelled = hardware_cancelled + 1
          return true
        end,
        pid = function()
          return 46
        end,
      }
    end

    local handle = flash.current("flash", opts, function() end)

    assert.is_true(vim.wait(100, function()
      return handle.pid() == 46
    end))
    assert.equals(46, handle.pid())
    assert.is_true(handle.cancel("test"))
    assert.equals(1, hardware_cancelled)
  end)

  it("keeps successful build artifacts after hardware failure", function()
    local source = project(root, { image(root, "application") })
    local elf = artifact(root, "application", "elf", "build-kept")
    local built = build_result({ elf }, "build-kept")
    local opts = cube_opts(root)
    opts.project = source
    opts.artifacts = nil
    build.run = function(_, callback)
      session.record(root, built)
      callback(built)
      return completed_handle(47)
    end
    operation.execute = function(plan, _, _, callback)
      callback(model.result({
        ok = false,
        code = 2,
        output = "program failed",
        artifacts = {},
        error = model.error({
          code = "flash-command-failed",
          message = "nvim-stm32: program failed",
          operation = "flash",
          hint = "inspect output",
        }),
        metadata = { operation_id = plan.id },
      }))
      return completed_handle(48)
    end

    flash.current("flash", opts, function() end)

    assert.same({ elf }, session.get(root).artifacts)
    assert.equals("build-kept", session.get(root).last_result.metadata.operation_id)
  end)

  it("exposes hardware planning and build-chained running in the public API", function()
    local source = project(root, { image(root, "application") })
    local opts = cube_opts(root)
    opts.project = source
    local planned = assert(nvim_stm32.plan("reset", opts))
    assert.equals("reset", planned.kind)

    local current_calls = 0
    local original_current = flash.current
    flash.current = function(action, received, callback)
      current_calls = current_calls + 1
      assert.equals("flash", action)
      assert.same(opts, received)
      callback(build_result({}))
      return completed_handle(71)
    end
    local result
    local handle = nvim_stm32.run("flash", opts, function(value)
      result = value
    end)
    flash.current = original_current

    assert.equals(1, current_calls)
    assert.equals(71, handle.id)
    assert.is_true(result.ok)
  end)
end)
