local model = require("nvim-stm32.model")
local nvim_stm32 = require("nvim-stm32")
local analyze = require("nvim-stm32.operations.analyze")
local operation = require("nvim-stm32.operation")
local process = require("nvim-stm32.process")
local session = require("nvim-stm32.session")
local tools = require("nvim-stm32.tools")

local function fixture(rel)
  local here =
    vim.fn.fnamemodify(vim.fn.resolve(debug.getinfo(1, "S").source:sub(2)), ":p:h")
  return here .. "/fixtures/" .. rel
end

local function contents(rel)
  return table.concat(vim.fn.readfile(fixture(rel)), "\n")
end

local function project(root, with_linker)
  return model.project({
    id = root,
    root = root,
    kind = "cmake_presets",
    build = { adapter = "cmake_presets", marker = root .. "/CMakePresets.json" },
    images = {
      {
        id = "application",
        name = "application",
        build_target = "dt",
        target = {
          mcu = "STM32F429ZITx",
          signals = with_linker == false and {} or {
            {
              source = "linker",
              file = fixture("nucleo_cmake/STM32F429xx_FLASH.ld"),
              mcu = "STM32F429ZITx",
              confidence = "inferred",
            },
          },
        },
      },
    },
  })
end

local function artifact(root, kind, configuration, path, build_id)
  if build_id == nil then
    build_id = "build-1"
  elseif build_id == false then
    build_id = nil
  end
  local artifact_path = path or root .. "/build/Debug/dt." .. kind
  local stat = assert(vim.uv.fs_stat(artifact_path))
  return model.artifact({
    image_id = "application",
    configuration = configuration or "Debug",
    kind = kind,
    path = artifact_path,
    build_target = "dt",
    modified_ns = stat.mtime.sec * 1000000000 + stat.mtime.nsec,
    size = stat.size,
    build_id = build_id,
  })
end

local function record_artifacts(root, artifacts)
  session.select(root, { configuration = "Debug" })
  session.record(root, {
    ok = true,
    code = 0,
    output = "built",
    artifacts = artifacts,
    metadata = { operation_id = "build-1" },
  })
end

describe("nvim-stm32 analysis operation", function()
  local root
  local toolchain
  local original_size
  local original_objdump
  local original_process_run

  before_each(function()
    root = vim.fn.tempname()
    toolchain = vim.fn.tempname()
    vim.fn.mkdir(root .. "/build/Debug", "p")
    vim.fn.mkdir(toolchain, "p")
    vim.fn.writefile({
      vim.json.encode({
        version = 3,
        configurePresets = {
          { name = "Debug", binaryDir = "${sourceDir}/build/Debug" },
        },
        buildPresets = {
          { name = "Debug", configurePreset = "Debug" },
        },
      }),
    }, root .. "/CMakePresets.json")
    for _, name in ipairs({ "arm-none-eabi-size", "arm-none-eabi-objdump" }) do
      vim.fn.writefile({ "#!/bin/sh" }, toolchain .. "/" .. name)
      vim.uv.fs_chmod(toolchain .. "/" .. name, 493)
    end
    vim.fn.writefile({ "elf" }, root .. "/build/Debug/dt.elf")
    vim.fn.writefile({ "map" }, root .. "/build/Debug/dt.map")
    session.clear()
    original_size = tools.size
    original_objdump = tools.objdump
    original_process_run = process.run
  end)

  after_each(function()
    tools.size = original_size
    tools.objdump = original_objdump
    process.run = original_process_run
    session.clear()
    vim.fn.delete(root, "rf")
    vim.fn.delete(toolchain, "rf")
  end)

  local function opts()
    return {
      configuration = {
        name = "Debug",
        configure_preset = "Debug",
        build_preset = "Debug",
        binary_dir = root .. "/build/Debug",
      },
      toolchain_path = toolchain,
    }
  end

  it("plans size then objdump with resolved absolute tools", function()
    record_artifacts(root, {
      artifact(root, "elf"),
      artifact(root, "map"),
    })

    local plan = assert(analyze.plan(project(root), opts()))

    assert.equals("analyze", plan.kind)
    assert.same({
      toolchain .. "/arm-none-eabi-size",
      "-B",
      "-x",
      root .. "/build/Debug/dt.elf",
    }, plan.commands[1].argv)
    assert.same({
      toolchain .. "/arm-none-eabi-objdump",
      "-h",
      root .. "/build/Debug/dt.elf",
    }, plan.commands[2].argv)
    assert.equals(root, plan.commands[1].cwd)
    assert.equals("application", plan.commands[1].image_id)
    assert.equals("short", plan.commands[1].lifecycle)
    assert.equals(root .. "/build/Debug/dt.map", plan.metadata.inputs[1].map.path)
    assert.same({ { kind = "project-artifacts", id = root } }, plan.locks)
  end)

  it("rejects an ELF from the wrong configuration", function()
    record_artifacts(root, { artifact(root, "elf", "Release") })

    local plan, err = analyze.plan(project(root), opts())

    assert.is_nil(plan)
    assert.equals("analysis-elf-missing", err.code)
  end)

  local function expect_preflight_failure(plan, expected_code)
    local starts = 0
    local result
    process.run = function()
      starts = starts + 1
    end
    operation.run(plan, {}, function(value)
      result = value
    end)
    assert.equals(0, starts)
    assert.is_false(result.ok)
    assert.equals(expected_code, result.error.code)
  end

  it("rejects an ELF modified after analysis planning before size starts", function()
    local elf = artifact(root, "elf")
    record_artifacts(root, { elf })
    local plan = assert(analyze.plan(project(root), opts()))
    local stat = assert(vim.uv.fs_stat(elf.path))
    vim.fn.writefile({ "ELF" }, elf.path)
    assert(vim.uv.fs_utime(elf.path, stat.atime.sec, stat.mtime.sec + 10))

    expect_preflight_failure(plan, "analysis-artifact-changed")
  end)

  it("rejects an ELF whose real path changes after analysis planning", function()
    local elf = artifact(root, "elf")
    record_artifacts(root, { elf })
    local plan = assert(analyze.plan(project(root), opts()))
    local outside = root .. "/outside.elf"
    vim.fn.writefile({ "elf" }, outside)
    assert.equals(0, vim.fn.delete(elf.path))
    assert(vim.uv.fs_symlink(outside, elf.path))

    expect_preflight_failure(plan, "analysis-artifact-outside-build")
  end)

  it("rejects a changed selected configuration before analysis starts", function()
    local elf = artifact(root, "elf")
    record_artifacts(root, { elf })
    local plan = assert(analyze.plan(project(root), opts()))
    session.select(root, { configuration = "Release" })

    expect_preflight_failure(plan, "analysis-configuration-changed")
  end)

  it("rejects a changed successful build id before analysis starts", function()
    local elf = artifact(root, "elf")
    record_artifacts(root, { elf })
    local plan = assert(analyze.plan(project(root), opts()))
    session.select(root, {
      last_result = {
        ok = true,
        code = 0,
        output = "rebuilt",
        artifacts = {},
        metadata = { operation_id = "build-2" },
      },
    })

    expect_preflight_failure(plan, "analysis-build-changed")
  end)

  it("rejects a missing ELF", function()
    record_artifacts(root, { artifact(root, "map") })

    local plan, err = analyze.plan(project(root), opts())

    assert.is_nil(plan)
    assert.equals("analysis-elf-missing", err.code)
  end)

  it("rejects several matching ELF artifacts", function()
    local second_path = root .. "/build/Debug/other.elf"
    vim.fn.writefile({ "elf" }, second_path)
    local second = artifact(root, "elf", "Debug", second_path)
    record_artifacts(root, { artifact(root, "elf"), second })

    local plan, err = analyze.plan(project(root), opts())

    assert.is_nil(plan)
    assert.equals("analysis-elf-ambiguous", err.code)
  end)

  it("rejects an artifact without a build id", function()
    record_artifacts(root, { artifact(root, "elf", "Debug", nil, false) })

    local plan, err = analyze.plan(project(root), opts())

    assert.is_nil(plan)
    assert.equals("analysis-build-stale", err.code)
  end)

  it("rejects an image without a linker signal", function()
    record_artifacts(root, { artifact(root, "elf") })

    local plan, err = analyze.plan(project(root, false), opts())

    assert.is_nil(plan)
    assert.equals("analysis-linker-missing", err.code)
  end)

  it("rejects a missing size tool before constructing commands", function()
    record_artifacts(root, { artifact(root, "elf") })
    tools.size = function()
      return nil
    end

    local plan, err = analyze.plan(project(root), opts())

    assert.is_nil(plan)
    assert.equals("analysis-tool-unavailable", err.code)
    assert.matches("arm%-none%-eabi%-size", err.message)
  end)

  it("returns a structured result when a process command fails", function()
    record_artifacts(root, { artifact(root, "elf") })
    local plan = assert(analyze.plan(project(root), opts()))

    local result = analyze.complete(plan, {
      code = 2,
      signal = 0,
      output = "size failed",
      commands = {
        { argv = plan.commands[1].argv, output = "size failed", code = 2, signal = 0 },
      },
    })

    assert.is_false(result.ok)
    assert.equals("process-failed", result.error.code)
    assert.same({}, result.artifacts)
  end)

  it("rejects zero-exit analysis terminated by a signal", function()
    record_artifacts(root, { artifact(root, "elf") })
    local plan = assert(analyze.plan(project(root), opts()))

    local result = analyze.complete(plan, {
      code = 0,
      signal = 15,
      output = "terminated",
      commands = {},
    })

    assert.is_false(result.ok)
    assert.equals("process-failed", result.error.code)
  end)

  it("parses separate command outputs into successful metadata", function()
    local elf = artifact(root, "elf")
    record_artifacts(root, { elf, artifact(root, "map") })
    local plan = assert(analyze.plan(project(root), opts()))

    local result = analyze.complete(plan, {
      code = 0,
      signal = 0,
      output = "combined output is not parsed",
      started_ns = 10,
      ended_ns = 30,
      commands = {
        {
          argv = plan.commands[1].argv,
          output = contents("f429_size.txt"),
          code = 0,
          signal = 0,
        },
        {
          argv = plan.commands[2].argv,
          output = contents("f429_objdump_sections.txt"),
          code = 0,
          signal = 0,
        },
      },
    })

    assert.is_true(result.ok, vim.inspect(result))
    assert.same(
      { text = 0x4cbc, data = 0x68, bss = 0xed8 },
      result.metadata.analysis[1].size
    )
    assert.equals(0x4d24, result.metadata.analysis[1].report.totals.flash)
    assert.equals(0xf40, result.metadata.analysis[1].report.totals.ram)
    assert.same({ elf }, result.artifacts)
    assert.equals(0.00002, result.duration_ms)
  end)

  it("renders region and section rows", function()
    record_artifacts(root, { artifact(root, "elf") })
    local plan = assert(analyze.plan(project(root), opts()))
    local result = analyze.complete(plan, {
      code = 0,
      signal = 0,
      output = "",
      commands = {
        {
          argv = plan.commands[1].argv,
          output = contents("f429_size.txt"),
          code = 0,
          signal = 0,
        },
        {
          argv = plan.commands[2].argv,
          output = contents("f429_objdump_sections.txt"),
          code = 0,
          signal = 0,
        },
      },
    })
    local text = table.concat(require("nvim-stm32.ui.analysis").lines(result), "\n")

    assert.matches("RAM: 3904 / 196608 bytes %(1%.99%%%)", text)
    assert.matches("FLASH: 19748 / 2097152 bytes %(0%.94%%%)", text)
    assert.matches("%.data", text)
    assert.matches("runtime=RAM", text, 1, true)
    assert.matches("load=FLASH", text, 1, true)
  end)

  it("registers analyze in the public planner without running a tool", function()
    record_artifacts(root, { artifact(root, "elf") })
    local plan = assert(nvim_stm32.plan(
      "analyze",
      vim.tbl_extend("force", opts(), {
        project = project(root),
      })
    ))

    assert.equals("analyze", plan.kind)
    assert.equals(2, #plan.commands)

    pcall(vim.api.nvim_del_user_command, "STM32Analyze")
    vim.g.loaded_nvim_stm32 = nil
    vim.cmd("runtime plugin/nvim-stm32.lua")
    assert.equals(2, vim.fn.exists(":STM32Analyze"))
  end)
end)
