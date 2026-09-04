local M = {}

function M.lines(result)
  local lines = {}
  local analyses = result.metadata and result.metadata.analysis or {}
  for analysis_index, analysis in ipairs(analyses) do
    if analysis_index > 1 then
      lines[#lines + 1] = ""
    end
    lines[#lines + 1] = "Image: " .. analysis.image_id
    for _, region in ipairs(analysis.report.regions) do
      lines[#lines + 1] = string.format(
        "%s: %d / %d bytes (%.2f%%)",
        region.name,
        region.used,
        region.length,
        region.percentage
      )
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Sections"
    for _, section in ipairs(analysis.report.sections) do
      local locations = {}
      if section.runtime_region then
        locations[#locations + 1] = "runtime=" .. section.runtime_region
      end
      if section.load_region then
        locations[#locations + 1] = "load=" .. section.load_region
      end
      if section.debug then
        locations[#locations + 1] = "debug"
      elseif section.unassigned then
        locations[#locations + 1] = "unassigned"
      end
      lines[#lines + 1] = string.format(
        "%s: %d bytes%s",
        section.name,
        section.size,
        #locations > 0 and " " .. table.concat(locations, " ") or ""
      )
    end
  end
  return lines
end

function M.show(result)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "nvim-stm32-analysis"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, M.lines(result))
  vim.bo[buf].modifiable = false
  vim.api.nvim_set_current_buf(buf)
  return buf
end

return M
