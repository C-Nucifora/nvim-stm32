local model = require("nvim-stm32.model")
local tools = require("nvim-stm32.tools")

local M = { id = "stlink", artifact_kind = "bin" }

local function required_string(name, value)
  vim.validate(name, value, function(candidate)
    return type(candidate) == "string" and candidate ~= ""
  end, "a non-empty string")
end

local function short_command(argv)
  return model.command({ argv = argv, lifecycle = "short" })
end

local function serial_argument(probe)
  vim.validate("probe", probe, "table")
  required_string("probe.serial", probe.serial)
  if probe.serial:match("^0[xX]") then
    return "0x" .. probe.serial:sub(3)
  end
  return "0x" .. probe.serial
end

local function trim(value)
  return value and value:match("^%s*(.-)%s*$") or nil
end

local function driver_error(code, message, hint)
  return model.error({
    code = code,
    message = "nvim-stm32: " .. message,
    operation = "flash",
    hint = hint,
  })
end

---@param cfg Stm32Config
---@return boolean, table|nil
function M.available(cfg)
  cfg = cfg or {}
  local program = tools.stlink(cfg)
  local identify = tools.stinfo(cfg)
  if not program or not identify then
    return false, nil
  end
  return true, { program = program, identify = identify, list = identify }
end

---@param tool string
---@return table
function M.list_command(tool)
  required_string("tool", tool)
  return short_command({ tool, "--probe" })
end

---@param tool string
---@param probe table
---@return table
function M.identify_command(tool, probe)
  serial_argument(probe)
  return M.list_command(tool)
end

---@param tool string
---@param request table
---@return table
function M.program_command(tool, request)
  required_string("tool", tool)
  vim.validate("request", request, "table")
  vim.validate("request.artifact", request.artifact, "table")
  required_string("request.artifact.path", request.artifact.path)
  vim.validate("request.artifact.kind", request.artifact.kind, function(kind)
    return kind == "bin"
  end, '"bin"')
  vim.validate("request.address", request.address, function(address)
    return type(address) == "number"
      and address > 0
      and address <= 0xFFFFFFFF
      and address % 1 == 0
      and address % 4 == 0
  end, "a positive aligned 32-bit integer")
  return short_command({
    tool,
    "--serial",
    serial_argument(request.probe),
    "write",
    request.artifact.path,
    string.format("0x%08X", request.address),
  })
end

---@param tool string
---@param probe table
---@return table
function M.erase_command(tool, probe)
  required_string("tool", tool)
  return short_command({ tool, "--serial", serial_argument(probe), "erase" })
end

---@param tool string
---@param probe table
---@return table
function M.reset_command(tool, probe)
  required_string("tool", tool)
  return short_command({ tool, "--serial", serial_argument(probe), "reset" })
end

---@param output string
---@return table[]
function M.parse_probes(output)
  vim.validate("output", output, "string")
  local probes = {}
  local current = {}

  local function finish()
    if current.serial then
      local target
      if current.device_id or current.device_name then
        target = {
          device_id = current.device_id,
          device_name = current.device_name,
        }
      end
      probes[#probes + 1] = model.probe({
        backend = M.id,
        serial = current.serial,
        transport = "SWD",
        firmware = current.firmware,
        target = target,
        provenance = {},
      })
    end
    current = {}
  end

  for line in (output .. "\n"):gmatch("(.-)\r?\n") do
    local key, value = line:match("^%s*([%w%-]+)%s*:%s*(.-)%s*$")
    if key == "version" and current.serial then
      finish()
    end
    if key == "version" then
      current.firmware = trim(value)
    elseif key == "serial" then
      if current.serial then
        finish()
      end
      current.serial = trim(value)
    elseif key == "chipid" then
      current.device_id = tonumber(value)
    elseif key == "dev-type" then
      current.device_name = trim(value)
    end
  end
  finish()
  return probes
end

---@param output string
---@param probe table
---@return table|nil, table|nil
function M.parse_identity(output, probe)
  vim.validate("probe", probe, "table")
  required_string("probe.serial", probe.serial)
  local wanted = probe.serial:gsub("^0[xX]", "")
  for _, candidate in ipairs(M.parse_probes(output)) do
    if candidate.serial:gsub("^0[xX]", "") == wanted then
      if candidate.target and candidate.target.device_id then
        return candidate.target
      end
      return nil,
        driver_error(
          "target-identity-unavailable",
          "st-info did not report a chip ID for probe " .. probe.serial,
          "check the probe connection and run the identity check again"
        )
    end
  end
  return nil,
    driver_error(
      "probe-not-found",
      "st-info did not report probe " .. probe.serial,
      "enumerate probes and select a connected serial number"
    )
end

---@param output string
---@return table|nil, table|nil
function M.parse_program(output)
  vim.validate("output", output, "string")
  if output:find("Flash written and verified! jolly good!", 1, true) then
    return { verified = true }
  end
  return nil,
    driver_error(
      "flash-verification-missing",
      "st-flash did not report successful verification",
      "inspect the st-flash output and retry after correcting the programming failure"
    )
end

return M
