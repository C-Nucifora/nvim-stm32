--- Render the :STM32Info report.
local M = {}

--- Render a Target as report lines.
---@param target Stm32Target
---@return string[]
function M.lines(target)
  local lines = {
    "Project: " .. target.root,
    "Marker:  " .. vim.fn.fnamemodify(target.marker, ":t"),
    "Build:   " .. (target.build_backend or "no build file in this directory"),
  }

  if not target.mcu then
    lines[#lines + 1] = "MCU:     not resolved"
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Build and flash still work; family-specific features are off."
    return lines
  end

  lines[#lines + 1] = ("MCU:     %s (%s, %s)"):format(
    target.mcu,
    target.family,
    target.confidence
  )
  lines[#lines + 1] = "Core:    "
    .. target.core
    .. (target.fpu and (" with " .. target.fpu) or ", no FPU")
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

  lines[#lines + 1] = ""
  lines[#lines + 1] = ("Signals: %d of %d agree"):format(
    target.agreement,
    #target.signals
  )
  for _, signal in ipairs(target.signals) do
    lines[#lines + 1] = ("  %-8s %-14s %s"):format(
      signal.source,
      signal.mcu,
      vim.fn.fnamemodify(signal.file, ":t")
    )
  end

  return lines
end

--- Resolve the current buffer's Target and show its report.
function M.show()
  local target, err = require("nvim-stm32.detect").target()
  if not target then
    vim.notify(err, vim.log.levels.WARN)
    return
  end
  vim.notify(table.concat(M.lines(target), "\n"), vim.log.levels.INFO)
end

return M
