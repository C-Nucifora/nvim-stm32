local uart = require("nvim-stm32.drivers.uart")

describe("nvim-stm32 UART driver commands", function()
  it("builds exact Darwin setup and stream argv without shell syntax", function()
    local commands = assert(uart.commands("/dev/cu.usb modem", 115200, "Darwin"))

    assert.same({
      {
        argv = {
          "stty",
          "-f",
          "/dev/cu.usb modem",
          "115200",
          "raw",
          "-echo",
          "cs8",
          "-parenb",
          "-cstopb",
          "clocal",
        },
        timeout_ms = 5000,
      },
      {
        argv = { "cat", "/dev/cu.usb modem" },
        lifecycle = "stream",
      },
    }, commands)
  end)

  it("uses Linux stty -F and keeps the stream unbounded", function()
    local commands = assert(uart.commands("/dev/ttyACM0", 9600, "Linux"))

    assert.same({
      "stty",
      "-F",
      "/dev/ttyACM0",
      "9600",
      "raw",
      "-echo",
      "cs8",
      "-parenb",
      "-cstopb",
      "clocal",
    }, commands[1].argv)
    assert.equals(5000, commands[1].timeout_ms)
    assert.same({ "cat", "/dev/ttyACM0" }, commands[2].argv)
    assert.equals("stream", commands[2].lifecycle)
    assert.is_nil(commands[2].timeout_ms)
  end)

  it("rejects unsupported platforms before returning commands", function()
    local commands, err = uart.commands("COM3", 115200, "Windows_NT")

    assert.is_nil(commands)
    assert.equals("monitor-platform-unsupported", err.code)
  end)
end)
