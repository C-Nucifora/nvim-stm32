local M = {}

local function escaped_argv(argv)
  return table.concat(vim.tbl_map(vim.fn.shellescape, argv), " ")
end

function M.lines(plan)
  local configuration = plan.metadata
      and plan.metadata.configuration
      and plan.metadata.configuration.name
    or "not selected"
  local lines = {
    "Operation: " .. plan.kind,
    "Project: " .. plan.project_id,
    "Configuration: " .. configuration,
    "Images: " .. table.concat(plan.images, ", "),
  }
  for index, command in ipairs(plan.commands) do
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Command " .. index
    lines[#lines + 1] = "Cwd: " .. (command.cwd or "")
    lines[#lines + 1] = "Argv: " .. escaped_argv(command.argv)
  end
  return lines
end

function M.show(plan)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "nvim-stm32-plan"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, M.lines(plan))
  vim.bo[buf].modifiable = false
  vim.api.nvim_set_current_buf(buf)
  return buf
end

function M.current(kind, opts)
  local plan, err = require("nvim-stm32").plan(kind or "build", opts)
  if not plan then
    vim.notify(err.message or tostring(err), vim.log.levels.WARN)
    return nil
  end
  return M.show(plan)
end

return M
