--- Render the :STM32Info report.
local M = {}

local function target_detail_lines(target, include_mcu)
  local lines = {}
  if not target.mcu then
    if include_mcu then
      lines[#lines + 1] = "MCU:     not resolved"
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Build and flash still work; family-specific features are off."
    return lines
  end

  if include_mcu then
    lines[#lines + 1] = ("MCU:     %s (%s, %s)"):format(
      target.mcu,
      target.family,
      target.confidence
    )
  end
  if target.core then
    lines[#lines + 1] = "Core:    "
      .. target.core
      .. (target.fpu and (" with " .. target.fpu) or ", no FPU")
  end
  if target.board then
    lines[#lines + 1] = "Board:   " .. target.board
  end
  if target.flash_kb or target.ram_kb then
    lines[#lines + 1] = ("Memory:  %s flash, %s RAM"):format(
      target.flash_kb and (target.flash_kb .. " KiB") or "unknown",
      target.ram_kb and (target.ram_kb .. " KiB") or "unknown"
    )
  end
  if target.openocd_cfg then
    lines[#lines + 1] = "OpenOCD: " .. target.openocd_cfg
  end

  if target.signals then
    lines[#lines + 1] = ""
    lines[#lines + 1] = ("Signals: %d of %d agree"):format(
      target.agreement or 0,
      #target.signals
    )
    for _, signal in ipairs(target.signals) do
      lines[#lines + 1] = ("  %-8s %-14s %s"):format(
        signal.source,
        signal.mcu,
        vim.fn.fnamemodify(signal.file, ":t")
      )
    end
  end

  return lines
end

--- Render a Target as report lines.
---@param target Stm32Target
---@return string[]
local function target_lines(target)
  local lines = {
    "Project: " .. target.root,
    "Marker:  "
      .. (target.marker and vim.fn.fnamemodify(target.marker, ":t") or "none"),
    "Build:   " .. (target.build_backend or "no build file in this directory"),
  }
  vim.list_extend(lines, target_detail_lines(target, true))
  return lines
end

--- Render a project or compatibility Target as report lines.
---@param value table
---@param state? table
---@return string[]
function M.lines(value, state)
  if not value.images then
    return target_lines(value)
  end

  state = state or require("nvim-stm32.session").get(value)
  local lines = {
    "Project: " .. value.id,
    "Root: " .. value.root,
    "Marker: "
      .. (value.build.marker and vim.fn.fnamemodify(value.build.marker, ":t") or "none"),
    "Build: " .. (value.build.adapter or value.kind or "not configured"),
    "Configuration: " .. (state.configuration or "not selected"),
    "Images:",
  }
  for _, image in ipairs(value.images) do
    local target = image.target or {}
    if target.mcu then
      lines[#lines + 1] = ("  %s: %s (%s, %s)"):format(
        image.id,
        target.mcu,
        target.family or "unknown family",
        target.confidence or "unknown"
      )
    else
      lines[#lines + 1] = ("  %s: not resolved"):format(image.id)
    end
    local details = target_detail_lines(target, false)
    for _, line in ipairs(details) do
      lines[#lines + 1] = line == "" and "" or "    " .. line
    end
  end
  lines[#lines + 1] = "Artifacts:"
  if #state.artifacts == 0 then
    lines[#lines + 1] = "  none"
  else
    for _, artifact in ipairs(state.artifacts) do
      lines[#lines + 1] = ("  %s %s: %s"):format(
        artifact.image_id,
        artifact.kind,
        artifact.path
      )
    end
  end
  return lines
end

--- Resolve the current buffer's Target and show its report.
function M.show()
  local project, err = require("nvim-stm32.discover.project").resolve()
  if not project then
    vim.notify(err.message or tostring(err), vim.log.levels.WARN)
    return
  end
  vim.notify(table.concat(M.lines(project), "\n"), vim.log.levels.INFO)
end

return M
