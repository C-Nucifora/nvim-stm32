local model = require("nvim-stm32.model")
local process = require("nvim-stm32.process")
local session = require("nvim-stm32.session")
local tools = require("nvim-stm32.tools")

local M = {}

local enumerators = {
  {
    driver = require("nvim-stm32.drivers.cubeprogrammer"),
    tool = function(cfg)
      return tools.programmer(cfg)
    end,
  },
  {
    driver = require("nvim-stm32.drivers.stlink"),
    tool = function(cfg)
      return tools.stinfo(cfg)
    end,
  },
}

local function probe_error(code, message, hint)
  return model.error({
    code = code,
    message = "nvim-stm32: " .. message,
    operation = "probe",
    hint = hint,
  })
end

local function passive_enumerator(cfg)
  for _, candidate in ipairs(enumerators) do
    local tool = candidate.tool(cfg)
    if
      tool
      and type(candidate.driver.list_command) == "function"
      and type(candidate.driver.parse_probes) == "function"
    then
      return candidate.driver, tool
    end
  end
end

local function completed_handle()
  return {
    state = function()
      return "completed"
    end,
    cancel = function()
      return false
    end,
    pid = function()
      return nil
    end,
  }
end

--- List connected probes with a backend's passive enumeration command.
---@param cfg Stm32Config|table
---@param callback fun(probes: table[]|nil, err: table|nil)
---@return table handle
function M.enumerate(cfg, callback)
  cfg = cfg or {}
  vim.validate("callback", callback, "function")
  local driver, tool = passive_enumerator(cfg)
  if not driver then
    local err = probe_error(
      "probe-enumerator-unavailable",
      "no passive ST-LINK probe enumerator is available",
      "install STM32CubeProgrammer or st-info"
    )
    callback(nil, err)
    return completed_handle()
  end

  return process.run({ driver.list_command(tool) }, {}, function(result)
    if result.code ~= 0 then
      callback(
        nil,
        probe_error(
          "probe-enumeration-failed",
          "probe enumeration failed",
          "inspect the enumerator output and retry"
        )
      )
      return
    end

    local ok, listed = pcall(driver.parse_probes, result.output)
    if not ok then
      callback(
        nil,
        probe_error(
          "probe-enumeration-invalid",
          "probe enumeration output could not be parsed",
          "inspect the enumerator output and retry"
        )
      )
      return
    end
    callback(listed, nil)
  end)
end

local function find_serial(list, serial)
  for _, candidate in ipairs(list) do
    if candidate.serial == serial then
      return model.probe(candidate)
    end
  end
end

--- Resolve a probe by explicit serial, session serial, or an unambiguous list.
---@param project table|string
---@param list table[]
---@param opts? table
---@return table|nil probe
---@return table|nil err
function M.resolve(project, list, opts)
  vim.validate("list", list, "table")
  opts = opts or {}
  local remembered = session.get(project).probe_serial
  local requested = remembered
  if opts.probe_serial ~= nil then
    requested = opts.probe_serial
  end

  if requested ~= nil then
    local selected = find_serial(list, requested)
    if selected then
      return selected
    end
    return nil,
      probe_error(
        "probe-not-found",
        "probe " .. tostring(requested) .. " was not found",
        "enumerate probes and select a connected serial number"
      )
  end

  if #list == 1 then
    return model.probe(list[1])
  end
  if #list == 0 then
    return nil,
      probe_error(
        "probe-not-found",
        "no ST-LINK probes were found",
        "connect a probe and retry"
      )
  end
  return nil,
    probe_error(
      "probe-selection-required",
      "more than one ST-LINK probe was found",
      "run :STM32SelectProbe and choose a serial number"
    )
end

return M
