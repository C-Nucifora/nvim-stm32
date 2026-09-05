local model = require("nvim-stm32.model")

local M = {}

M.SETUP_FAILURE_CODE = 125

local DARWIN_STREAM_SCRIPT =
  'exec 3<>"$1" || exit 125; stty "$2" raw -echo cs8 -parenb -cstopb clocal <&3 || exit 125; exec cat <&3'

local function monitor_error(code, message)
  return model.error({
    code = code,
    message = "nvim-stm32: " .. message,
    operation = "monitor",
    hint = "use a supported serial device and positive integer baud rate",
  })
end

function M.commands(device, baud, platform)
  if type(device) ~= "string" or device == "" then
    return nil, monitor_error("monitor-device-not-found", "serial device not found")
  end
  if type(baud) ~= "number" or baud <= 0 or baud % 1 ~= 0 then
    return nil, monitor_error("monitor-baud-invalid", "baud must be a positive integer")
  end

  if platform == "Darwin" then
    return {
      model.command({
        argv = {
          "sh",
          "-c",
          DARWIN_STREAM_SCRIPT,
          "nvim-stm32-uart",
          device,
          tostring(baud),
        },
        lifecycle = "stream",
      }),
    }
  end

  if platform ~= "Linux" then
    return nil,
      monitor_error(
        "monitor-platform-unsupported",
        "UART monitoring is unsupported on " .. tostring(platform)
      )
  end

  return {
    model.command({
      argv = {
        "stty",
        "-F",
        device,
        tostring(baud),
        "raw",
        "-echo",
        "cs8",
        "-parenb",
        "-cstopb",
        "clocal",
      },
      timeout_ms = 5000,
    }),
    model.command({
      argv = { "cat", device },
      lifecycle = "stream",
    }),
  }
end

return M
