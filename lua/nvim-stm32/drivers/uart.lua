local model = require("nvim-stm32.model")

local M = {}

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

  local device_flag
  if platform == "Darwin" then
    device_flag = "-f"
  elseif platform == "Linux" then
    device_flag = "-F"
  else
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
        device_flag,
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
