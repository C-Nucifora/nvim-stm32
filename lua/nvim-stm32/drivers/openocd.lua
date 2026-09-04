local model = require("nvim-stm32.model")
local tools = require("nvim-stm32.tools")

local M = { id = "openocd", artifact_kind = "elf" }

local function required_string(name, value)
  vim.validate(name, value, function(candidate)
    return type(candidate) == "string" and candidate ~= ""
  end, "a non-empty string")
end

local function driver_error()
  return model.error({
    code = "target-identity-unavailable",
    message = "nvim-stm32: OpenOCD output did not contain the requested DBGMCU IDCODE",
    operation = "identify",
    hint = "check the target profile and probe connection, then retry",
  })
end

local function target_for(probe)
  vim.validate("probe", probe, "table")
  required_string("probe.serial", probe.serial)
  vim.validate("probe.target", probe.target, "table")
  required_string("probe.target.openocd_cfg", probe.target.openocd_cfg)
  return probe.target
end

local function tcl_word(name, value)
  required_string(name, value)
  if value:match("^[%w%._/%-]+$") then
    return value
  end
  vim.validate(name, value, function(candidate)
    return not candidate:find("[{}]", 1)
  end, "a path without braces")
  return "{" .. value .. "}"
end

local function command(tool, probe, action)
  required_string("tool", tool)
  local target = target_for(probe)
  vim.validate("probe.serial", probe.serial, function(serial)
    return not serial:find("[%s;]", 1)
  end, "a serial without whitespace or semicolons")
  return model.command({
    argv = {
      tool,
      "-f",
      "interface/stlink.cfg",
      "-c",
      "adapter serial " .. probe.serial,
      "-f",
      target.openocd_cfg,
      "-c",
      action,
    },
    lifecycle = "short",
  })
end

---@param cfg Stm32Config
---@return boolean, string|nil
function M.available(cfg)
  local tool = tools.openocd(cfg or {})
  return tool ~= nil, tool
end

---@param tool string
---@param probe table
---@return table
function M.identify_command(tool, probe)
  local target = target_for(probe)
  vim.validate(
    "probe.target.debug_idcode_address",
    target.debug_idcode_address,
    function(address)
      return type(address) == "number"
        and address > 0
        and address <= 0xFFFFFFFF
        and address % 1 == 0
        and address % 4 == 0
    end,
    "an aligned 32-bit integer"
  )
  return command(
    tool,
    probe,
    string.format("init; mdw 0x%08X 1; shutdown", target.debug_idcode_address)
  )
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
  return command(
    tool,
    request.probe,
    "program "
      .. tcl_word("request.artifact.path", request.artifact.path)
      .. " verify; shutdown"
  )
end

---@param tool string
---@param probe table
---@return table
function M.erase_command(tool, probe)
  return command(tool, probe, "init; reset halt; flash erase_sector 0 0 last; shutdown")
end

---@param tool string
---@param probe table
---@return table
function M.reset_command(tool, probe)
  return command(tool, probe, "init; reset run; shutdown")
end

---@param output string
---@param target? table
---@return table|nil, table|nil
function M.parse_identity(output, target)
  vim.validate("output", output, "string")
  vim.validate("target", target, "table", true)
  local expected_address = target and target.debug_idcode_address or nil
  for address_text, idcode_text in
    output:gmatch("(0[xX][%da-fA-F]+)%s*:%s*(0?[xX]?[%da-fA-F]+)")
  do
    local address = tonumber(address_text)
    local idcode = tonumber(idcode_text:gsub("^0[xX]", ""), 16)
    if idcode and (not expected_address or address == expected_address) then
      return { device_id = bit.band(idcode, 0xFFF), idcode = idcode }
    end
  end
  return nil, driver_error()
end

return M
