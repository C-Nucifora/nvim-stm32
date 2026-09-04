local driver = require("nvim-stm32.drivers.cubeprogrammer")

local programmer = "/opt/st/STM32 Programmer/bin/STM32_Programmer_CLI"
local probe = { backend = "cubeprogrammer", serial = "ABC123" }

describe("nvim-stm32 CubeProgrammer driver commands", function()
  it("lists ST-LINK probes without connecting to a target", function()
    assert.same(
      { programmer, "-l", "st-link-only" },
      driver.list_command(programmer).argv
    )
  end)

  it("identifies a selected probe with a non-resetting HOTPLUG connection", function()
    assert.same({
      programmer,
      "-c",
      "port=SWD",
      "mode=HOTPLUG",
      "sn=ABC123",
    }, driver.identify_command(programmer, probe).argv)
  end)

  it("programs and verifies an ELF without resetting", function()
    local command = driver.program_command(programmer, {
      probe = probe,
      artifact = { kind = "elf", path = "/tmp/app.elf" },
    })

    assert.same({
      programmer,
      "-c",
      "port=SWD",
      "mode=UR",
      "sn=ABC123",
      "-w",
      "/tmp/app.elf",
      "-v",
    }, command.argv)
    assert.is_nil(vim.tbl_contains(command.argv, "-rst") and "-rst" or nil)
  end)

  it("mass erases the selected probe without resetting", function()
    assert.same({
      programmer,
      "-c",
      "port=SWD",
      "mode=UR",
      "sn=ABC123",
      "-e",
      "all",
    }, driver.erase_command(programmer, probe).argv)
  end)

  it("keeps reset in its own command", function()
    assert.same({
      programmer,
      "-c",
      "port=SWD",
      "mode=UR",
      "sn=ABC123",
      "-rst",
    }, driver.reset_command(programmer, probe).argv)
  end)
end)

describe("nvim-stm32 CubeProgrammer output parsing", function()
  it("parses stable serial and firmware fields from every probe block", function()
    local output = [[
=====  STLink Interface   =====

Total number of available STM32 device in ST-Link mode: 2

  Device Index           : 1
  ST-LINK SN             : 003F002A3138510E34383839
  ST-LINK FW             : V3J15M7
  Board                  : NUCLEO-F429ZI

  Device Index           : 2
  Device Serial Number   : 066DFF515450657867190941
  Firmware Version       : V2J45S7
]]

    local probes = driver.parse_probes(output)
    assert.equals(2, #probes)
    assert.equals("003F002A3138510E34383839", probes[1].serial)
    assert.equals("V3J15M7", probes[1].firmware)
    assert.equals("066DFF515450657867190941", probes[2].serial)
    assert.equals("V2J45S7", probes[2].firmware)
  end)

  it("does not return incomplete probe blocks", function()
    local probes = driver.parse_probes([[
  Device Index           : 1
  ST-LINK FW             : V3J15M7
]])
    assert.same({}, probes)
  end)

  it("parses the connected device id, name, and target voltage", function()
    local identity = assert(driver.parse_identity([[
  ST-LINK SN              : ABC123
  Voltage                 : 3.29V
  Device ID               : 0x419
  Device name             : STM32F42xxx/F43xxx
]]))

    assert.same({
      device_id = 0x419,
      device_name = "STM32F42xxx/F43xxx",
      voltage_mv = 3290,
    }, identity)
  end)

  it("requires a device id as identity evidence", function()
    local identity, err = driver.parse_identity([[
  Voltage                 : 3.30V
  Device name             : STM32F42xxx/F43xxx
]])

    assert.is_nil(identity)
    assert.equals("target-identity-unavailable", err.code)
  end)

  it("leaves absent optional identity fields unset", function()
    local identity = assert(driver.parse_identity("Device ID : 0x419"))
    assert.same({ device_id = 0x419 }, identity)
  end)
end)
