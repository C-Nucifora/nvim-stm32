local model = require("nvim-stm32.model")
local tools = require("nvim-stm32.tools")

local M = { id = "cubeprogrammer", artifact_kind = "elf" }

local function required_string(name, value)
  vim.validate(name, value, function(candidate)
    return type(candidate) == "string" and candidate ~= ""
  end, "a non-empty string")
end

local function selected_probe(probe)
  vim.validate("probe", probe, "table")
  required_string("probe.serial", probe.serial)
  return probe
end

local function short_command(argv)
  return model.command({ argv = argv, lifecycle = "short" })
end

local function connection(tool, probe, mode)
  required_string("tool", tool)
  selected_probe(probe)
  return { tool, "-c", "port=SWD", "mode=" .. mode, "sn=" .. probe.serial }
end

local function trim(value)
  return value and value:match("^%s*(.-)%s*$") or nil
end

local function identity_error()
  return model.error({
    code = "target-identity-unavailable",
    message = "nvim-stm32: CubeProgrammer output did not contain a device ID",
    operation = "identify",
    hint = "check the probe connection and run the identity check again",
  })
end

---@param cfg Stm32Config
---@return boolean, table|nil
function M.available(cfg)
  local tool = tools.programmer(cfg or {})
  if not tool then
    return false, nil
  end
  return true, { program = tool, identify = tool, list = tool }
end

---@param tool string
---@return table
function M.list_command(tool)
  required_string("tool", tool)
  return short_command({ tool, "-l", "st-link-only" })
end

---@param tool string
---@param probe table
---@return table
function M.identify_command(tool, probe)
  return short_command(connection(tool, probe, "HOTPLUG"))
end

---@param tool string
---@param request table
---@return table
function M.program_command(tool, request)
  vim.validate("request", request, "table")
  vim.validate("request.artifact", request.artifact, "table")
  required_string("request.artifact.path", request.artifact.path)
  vim.validate("request.artifact.kind", request.artifact.kind, function(kind)
    return kind == "elf"
  end, '"elf"')

  local argv = connection(tool, request.probe, "UR")
  vim.list_extend(argv, { "-w", request.artifact.path, "-v" })
  return short_command(argv)
end

---@param tool string
---@param probe table
---@return table
function M.erase_command(tool, probe)
  local argv = connection(tool, probe, "UR")
  vim.list_extend(argv, { "-e", "all" })
  return short_command(argv)
end

---@param tool string
---@param probe table
---@return table
function M.reset_command(tool, probe)
  local argv = connection(tool, probe, "UR")
  argv[#argv + 1] = "-rst"
  return short_command(argv)
end

---@param output string
---@return table[]
function M.parse_probes(output)
  vim.validate("output", output, "string")
  output = output:gsub("\27%[[%d;]*m", "")
  local probes = {}
  local current = {}

  local function finish()
    if current.serial then
      probes[#probes + 1] = model.probe({
        backend = M.id,
        serial = current.serial,
        transport = "SWD",
        firmware = current.firmware,
        provenance = {},
      })
    end
    current = {}
  end

  for line in (output .. "\n"):gmatch("(.-)\r?\n") do
    if line:match("^%s*Device Index%s*:") then
      finish()
    end
    local serial = line:match("^%s*ST%-LINK SN%s*:%s*(.-)%s*$")
      or line:match("^%s*Device Serial Number%s*:%s*(.-)%s*$")
    if serial and serial ~= "" then
      if current.serial then
        finish()
      end
      current.serial = trim(serial)
    end
    local firmware = line:match("^%s*ST%-LINK FW%s*:%s*(.-)%s*$")
      or line:match("^%s*Firmware Version%s*:%s*(.-)%s*$")
    if firmware and firmware ~= "" then
      current.firmware = trim(firmware)
    end
  end
  finish()
  return probes
end

---@param output string
---@return table|nil, table|nil
function M.parse_identity(output)
  vim.validate("output", output, "string")
  output = output:gsub("\27%[[%d;]*m", "")
  local id_text = output:match("[Dd]evice%s+[Ii][Dd]%s*:%s*(0[xX][%da-fA-F]+)")
  local device_id = id_text and tonumber(id_text)
  if not device_id then
    return nil, identity_error()
  end

  local identity = { device_id = device_id }
  local device_name = output:match("[Dd]evice%s+[Nn]ame%s*:%s*([^\r\n]+)")
  if device_name then
    identity.device_name = trim(device_name)
  end
  local voltage = output:match("[Tt]arget%s+[Vv]oltage%s*:%s*([%d%.]+)")
    or output:match("[Vv]oltage%s*:%s*([%d%.]+)")
  if voltage then
    identity.voltage_mv = math.floor(tonumber(voltage) * 1000 + 0.5)
  end
  return identity
end

return M
