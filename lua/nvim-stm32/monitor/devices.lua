local model = require("nvim-stm32.model")

local M = {}

local PATTERNS = {
  Darwin = "/dev/cu.usbmodem*",
  Linux = "/dev/ttyACM*",
}

local function monitor_error(code, message)
  return model.error({
    code = code,
    message = "nvim-stm32: " .. message,
    operation = "monitor",
    hint = "connect a supported serial device or set opts.monitor.device",
  })
end

function M.platform(opts)
  opts = opts or {}
  return opts.platform or vim.uv.os_uname().sysname
end

function M.pattern(platform)
  return PATTERNS[platform]
end

function M.validate(path, opts)
  opts = opts or {}
  if type(path) ~= "string" or path == "" then
    return nil, monitor_error("monitor-device-not-found", "serial device not found")
  end

  local stat = (opts.stat or vim.uv.fs_stat)(path)
  if not stat or opts.require_character_device ~= false and stat.type ~= "char" then
    return nil,
      monitor_error("monitor-device-not-found", "serial device not found: " .. path)
  end
  return path
end

function M.list(opts)
  opts = opts or {}
  local platform = M.platform(opts)
  local pattern = M.pattern(platform)
  if not pattern then
    return nil,
      monitor_error(
        "monitor-platform-unsupported",
        "UART monitoring is unsupported on " .. tostring(platform)
      )
  end

  local glob = opts.glob
    or function(value)
      return vim.fn.glob(value, false, true)
    end
  local unique = {}
  for _, path in ipairs(glob(pattern) or {}) do
    if type(path) == "string" and path ~= "" then
      unique[path] = true
    end
  end

  local paths = vim.tbl_keys(unique)
  table.sort(paths)
  local found = {}
  for _, path in ipairs(paths) do
    if M.validate(path, opts) then
      found[#found + 1] = path
    end
  end
  return found
end

return M
