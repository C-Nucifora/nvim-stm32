local uart = require("nvim-stm32.drivers.uart")

describe("nvim-stm32 UART driver commands", function()
  it("opens, configures, and streams Darwin UARTs through one descriptor", function()
    local commands = assert(uart.commands("/dev/cu.usb modem", 115200, "Darwin"))

    assert.same({
      {
        argv = {
          "sh",
          "-c",
          'exec 3<>"$1" || exit 125; stty "$2" raw -echo cs8 -parenb -cstopb clocal <&3 || exit 125; exec cat <&3',
          "nvim-stm32-uart",
          "/dev/cu.usb modem",
          "115200",
        },
        lifecycle = "stream",
      },
    }, commands)
  end)

  it("reserves a distinct Darwin setup failure status", function()
    assert.equals(125, uart.SETUP_FAILURE_CODE)
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
