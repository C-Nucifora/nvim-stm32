local tools = require("nvim-stm32.tools")
local driver = require("nvim-stm32.drivers.stlink")

local st_flash = "/opt/homebrew/bin/st-flash"
local st_info = "/opt/homebrew/bin/st-info"
local probe = { backend = "stlink", serial = "ABC123" }

describe("nvim-stm32 stlink driver commands", function()
  it("enumerates and identifies through the passive st-info probe command", function()
    assert.same({ st_info, "--probe" }, driver.list_command(st_info).argv)
    assert.same({ st_info, "--probe" }, driver.identify_command(st_info, probe).argv)
  end)

  it("programs and verifies a BIN at its validated address", function()
    local command = driver.program_command(st_flash, {
      probe = probe,
      artifact = { kind = "bin", path = "/tmp/app.bin" },
      address = 0x08000000,
    })

    assert.same({
      st_flash,
      "--serial",
      "0xABC123",
      "write",
      "/tmp/app.bin",
      "0x08000000",
    }, command.argv)
  end)

  it("mass erases and resets only the selected probe", function()
    assert.same(
      { st_flash, "--serial", "0xABC123", "erase" },
      driver.erase_command(st_flash, probe).argv
    )
    assert.same(
      { st_flash, "--serial", "0xABC123", "reset" },
      driver.reset_command(st_flash, probe).argv
    )
  end)

  it("rejects artifacts other than BIN and invalid addresses", function()
    assert.has_error(function()
      driver.program_command(st_flash, {
        probe = probe,
        artifact = { kind = "elf", path = "/tmp/app.elf" },
        address = 0x08000000,
      })
    end)
    assert.has_error(function()
      driver.program_command(st_flash, {
        probe = probe,
        artifact = { kind = "bin", path = "/tmp/app.bin" },
        address = 0,
      })
    end)
  end)
end)

describe("nvim-stm32 stlink output parsing", function()
  local output = [[
Found 2 stlink programmers
  version:    V3J15M7
  serial:     003F002A3138510E34383839
  flash:      2097152 (pagesize: 16384)
  sram:       262144
  chipid:     0x419
  dev-type:   STM32F42x_F43x

  version:    V2J45S7
  serial:     066DFF515450657867190941
  flash:      1048576 (pagesize: 16384)
  sram:       196608
  chipid:     0x413
  dev-type:   STM32F40x_F41x
]]

  it("parses stable probe fields and the observed target", function()
    local probes = driver.parse_probes(output)
    assert.equals(2, #probes)
    assert.equals("003F002A3138510E34383839", probes[1].serial)
    assert.equals("V3J15M7", probes[1].firmware)
    assert.equals(0x419, probes[1].target.device_id)
    assert.equals("STM32F42x_F43x", probes[1].target.device_name)
    assert.equals("066DFF515450657867190941", probes[2].serial)
    assert.equals(0x413, probes[2].target.device_id)
  end)

  it("selects identity by serial instead of taking the first probe", function()
    local identity = assert(driver.parse_identity(output, {
      serial = "066DFF515450657867190941",
    }))
    assert.equals(0x413, identity.device_id)
    assert.equals("STM32F40x_F41x", identity.device_name)
  end)

  it("requires st-flash's verification-success marker", function()
    assert.same(
      { verified = true },
      assert(driver.parse_program("Flash written and verified! jolly good!"))
    )
    local result, err = driver.parse_program("st-flash exited without an error")
    assert.is_nil(result)
    assert.equals("flash-verification-missing", err.code)
  end)
end)

describe("nvim-stm32.tools.stinfo", function()
  local dir
  local old_path

  before_each(function()
    dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    old_path = vim.env.PATH
  end)

  after_each(function()
    vim.env.PATH = old_path
    vim.fn.delete(dir, "rf")
  end)

  local function executable(name)
    local path = dir .. "/" .. name
    vim.fn.writefile({ "#!/bin/sh" }, path)
    vim.uv.fs_chmod(path, 493)
    return path
  end

  it("uses st-info beside an explicit st-flash", function()
    local flash = executable("st-flash")
    local info = executable("st-info")
    assert.equals(info, tools.stinfo({ stlink_path = flash }))
  end)

  it("falls back to PATH when the explicit st-flash has no sibling", function()
    local flash = executable("st-flash")
    local path_dir = vim.fn.tempname()
    vim.fn.mkdir(path_dir, "p")
    local info = path_dir .. "/st-info"
    vim.fn.writefile({ "#!/bin/sh" }, info)
    vim.uv.fs_chmod(info, 493)
    vim.env.PATH = path_dir

    assert.equals(info, tools.stinfo({ stlink_path = flash }))
    vim.fn.delete(path_dir, "rf")
  end)
end)
