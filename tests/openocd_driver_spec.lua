local driver = require("nvim-stm32.drivers.openocd")

local openocd = "/opt/homebrew/bin/openocd"
local probe = {
  backend = "openocd",
  serial = "ABC123",
  target = {
    openocd_cfg = "target/stm32f4x.cfg",
    debug_idcode_address = 0xE0042000,
  },
}

describe("nvim-stm32 OpenOCD driver commands", function()
  it("identifies the device through the configured DBGMCU IDCODE address", function()
    assert.same({
      openocd,
      "-f",
      "interface/stlink.cfg",
      "-c",
      "adapter serial ABC123",
      "-f",
      "target/stm32f4x.cfg",
      "-c",
      "init; mdw 0xE0042000 1; shutdown",
    }, driver.identify_command(openocd, probe).argv)
  end)

  it("programs and verifies an ELF before shutdown", function()
    assert.same(
      {
        openocd,
        "-f",
        "interface/stlink.cfg",
        "-c",
        "adapter serial ABC123",
        "-f",
        "target/stm32f4x.cfg",
        "-c",
        "program /tmp/app.elf verify; shutdown",
      },
      driver.program_command(openocd, {
        probe = probe,
        artifact = { kind = "elf", path = "/tmp/app.elf" },
      }).argv
    )
  end)

  it("mass erases without resetting and always shuts down", function()
    assert.same({
      openocd,
      "-f",
      "interface/stlink.cfg",
      "-c",
      "adapter serial ABC123",
      "-f",
      "target/stm32f4x.cfg",
      "-c",
      "init; reset halt; flash erase_sector 0 0 last; shutdown",
    }, driver.erase_command(openocd, probe).argv)
  end)

  it("resets in a separate short-lived invocation", function()
    assert.same({
      openocd,
      "-f",
      "interface/stlink.cfg",
      "-c",
      "adapter serial ABC123",
      "-f",
      "target/stm32f4x.cfg",
      "-c",
      "init; reset run; shutdown",
    }, driver.reset_command(openocd, probe).argv)
  end)

  it("does not claim a passive USB probe enumerator", function()
    assert.is_nil(driver.list_command)
    assert.is_nil(driver.parse_probes)
  end)
end)

describe("nvim-stm32 OpenOCD identity parsing", function()
  it("extracts the low 12-bit device id from the DBGMCU IDCODE word", function()
    local identity = assert(driver.parse_identity([[
Info : clock speed 1800 kHz
0xe0042000: 0x10016419
shutdown command invoked
]]))
    assert.same({ device_id = 0x419, idcode = 0x10016419 }, identity)
  end)

  it("treats OpenOCD's unprefixed memory word as hexadecimal", function()
    local identity = assert(driver.parse_identity("0xe0042000: 10016419"))
    assert.same({ device_id = 0x419, idcode = 0x10016419 }, identity)
  end)

  it("requires a read from the requested IDCODE address", function()
    local identity, err = driver.parse_identity("0x20000000: 0x10016419", {
      debug_idcode_address = 0xE0042000,
    })
    assert.is_nil(identity)
    assert.equals("target-identity-unavailable", err.code)
  end)
end)
