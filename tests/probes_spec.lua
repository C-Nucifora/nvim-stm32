local model = require("nvim-stm32.model")
local session = require("nvim-stm32.session")

local function probe(serial, firmware)
  return model.probe({
    backend = "cubeprogrammer",
    serial = serial,
    firmware = firmware,
  })
end

describe("nvim-stm32 passive probe enumeration", function()
  local probes
  local directory
  local argv_path
  local old_argv_path
  local old_output
  local old_path

  local function fake_executable(name)
    local path = directory .. "/" .. name
    vim.fn.writefile({
      "#!/bin/sh",
      [[printf '%s\n' "$0" "$@" > "$NVIM_STM32_TEST_ARGV"]],
      [[printf '%s' "$NVIM_STM32_TEST_OUTPUT"]],
    }, path)
    vim.uv.fs_chmod(path, 493)
    return path
  end

  local function enumerate(cfg)
    local listed
    local enumeration_err
    local handle, immediate_err = probes.enumerate(cfg, function(value, err)
      listed = value
      enumeration_err = err
    end)
    assert.is_true(vim.wait(1000, function()
      return listed ~= nil or enumeration_err ~= nil
    end))
    return listed, enumeration_err, handle, immediate_err
  end

  before_each(function()
    package.loaded["nvim-stm32.probes"] = nil
    probes = require("nvim-stm32.probes")
    directory = vim.fn.tempname()
    vim.fn.mkdir(directory, "p")
    argv_path = directory .. "/argv"
    old_argv_path = vim.env.NVIM_STM32_TEST_ARGV
    old_output = vim.env.NVIM_STM32_TEST_OUTPUT
    old_path = vim.env.PATH
    vim.env.NVIM_STM32_TEST_ARGV = argv_path
  end)

  after_each(function()
    vim.env.NVIM_STM32_TEST_ARGV = old_argv_path
    vim.env.NVIM_STM32_TEST_OUTPUT = old_output
    vim.env.PATH = old_path
    vim.fn.delete(directory, "rf")
    package.loaded["nvim-stm32.probes"] = nil
  end)

  it("runs only CubeProgrammer's passive ST-LINK listing argv", function()
    local tool = fake_executable("STM32_Programmer_CLI")
    vim.env.NVIM_STM32_TEST_OUTPUT = [[
  Device Index           : 1
  ST-LINK SN             : 003F002A3138510E34383839
  ST-LINK FW             : V3J15M7

  Device Index           : 2
  Device Serial Number   : 066DFF515450657867190941
  Firmware Version       : V2J45S7
]]

    local listed, err, handle = enumerate({
      programmer_path = tool,
      flash_backend = "openocd",
    })

    assert.is_nil(err)
    assert.is_not_nil(handle)
    assert.same({ tool, "-l", "st-link-only" }, vim.fn.readfile(argv_path))
    assert.equals(2, #listed)
    assert.equals("003F002A3138510E34383839", listed[1].serial)
    assert.equals("V3J15M7", listed[1].firmware)
    assert.equals("066DFF515450657867190941", listed[2].serial)
    assert.equals("V2J45S7", listed[2].firmware)
  end)

  it("falls back to the passive st-info probe argv", function()
    local tool = fake_executable("st-info")
    vim.env.NVIM_STM32_TEST_OUTPUT = [[
Found 1 stlink programmers
  version:    V3J15M7
  serial:     003F002A3138510E34383839
  chipid:     0x419
  dev-type:   STM32F42x_F43x
]]

    local listed, err = enumerate({
      programmer_path = directory .. "/missing-programmer",
      stlink_path = directory .. "/st-flash",
    })

    assert.is_nil(err)
    assert.same({ tool, "--probe" }, vim.fn.readfile(argv_path))
    assert.equals(1, #listed)
    assert.equals("003F002A3138510E34383839", listed[1].serial)
    assert.equals("V3J15M7", listed[1].firmware)
  end)

  it("does not use OpenOCD to guess a connected probe", function()
    local openocd = fake_executable("openocd")
    vim.env.PATH = directory
    vim.env.NVIM_STM32_TEST_OUTPUT = "Open On-Chip Debugger"

    local listed, err, handle, immediate_err = enumerate({
      programmer_path = directory .. "/missing-programmer",
      stlink_path = directory .. "/missing-st-flash",
      openocd_path = openocd,
    })

    assert.is_nil(listed)
    assert.is_not_nil(handle)
    assert.equals("completed", handle.state())
    assert.is_false(handle.cancel())
    assert.is_nil(handle.pid())
    assert.equals("probe-enumerator-unavailable", err.code)
    assert.is_nil(immediate_err)
    assert.equals(0, vim.fn.filereadable(argv_path))
  end)
end)

describe("nvim-stm32 probe selection", function()
  local probes
  local project = { root = "/firmware", id = "/firmware" }
  local available

  before_each(function()
    package.loaded["nvim-stm32.probes"] = nil
    probes = require("nvim-stm32.probes")
    session.clear()
    available = {
      probe("FIRST", "V3J15M7"),
      probe("SECOND", "V2J45S7"),
    }
  end)

  after_each(function()
    session.clear()
    package.loaded["nvim-stm32.probes"] = nil
  end)

  it("prefers an explicit serial over the remembered serial", function()
    session.select(project, { probe_serial = "FIRST" })

    local selected = assert(probes.resolve(project, available, {
      probe_serial = "SECOND",
    }))

    assert.equals("SECOND", selected.serial)
  end)

  it("uses the remembered serial when no explicit serial is given", function()
    session.select(project, { probe_serial = "SECOND" })

    local selected = assert(probes.resolve(project, available))

    assert.equals("SECOND", selected.serial)
  end)

  it("selects the sole detected probe without storing a selection", function()
    local selected = assert(probes.resolve(project, { available[1] }))

    assert.equals("FIRST", selected.serial)
    assert.is_nil(session.get(project).probe_serial)
  end)

  it("reports no probes and ambiguous probe lists", function()
    local missing, missing_err = probes.resolve(project, {})
    assert.is_nil(missing)
    assert.equals("probe-not-found", missing_err.code)

    local ambiguous, ambiguous_err = probes.resolve(project, available)
    assert.is_nil(ambiguous)
    assert.equals("probe-selection-required", ambiguous_err.code)
  end)

  it("never replaces a stale requested serial with another probe", function()
    local selected, err = probes.resolve(project, { available[1] }, {
      probe_serial = "DISCONNECTED",
    })

    assert.is_nil(selected)
    assert.equals("probe-not-found", err.code)
  end)

  it(
    "does not replace an explicit false selection with the remembered probe",
    function()
      session.select(project, { probe_serial = "FIRST" })

      local selected, err = probes.resolve(project, available, {
        probe_serial = false,
      })

      assert.is_nil(selected)
      assert.equals("probe-not-found", err.code)
    end
  )
end)
