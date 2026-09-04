local M = {}

local Presenter = {}
Presenter.__index = Presenter

local function callable(value)
  if type(value) == "function" then
    return true
  end
  local metatable = type(value) == "table" and getmetatable(value) or nil
  return metatable and type(metatable.__call) == "function" or false
end

function Presenter:_write(lines)
  if #lines == 0 or not vim.api.nvim_buf_is_valid(self.buf) then
    return
  end

  if self.empty then
    vim.api.nvim_buf_set_lines(self.buf, 0, -1, false, lines)
    self.empty = false
  else
    vim.api.nvim_buf_set_lines(self.buf, -1, -1, false, lines)
  end

  if self.win and vim.api.nvim_win_is_valid(self.win) then
    vim.api.nvim_win_set_cursor(self.win, { vim.api.nvim_buf_line_count(self.buf), 0 })
  end
end

function Presenter:append(chunk)
  if not chunk or chunk == "" then
    return
  end

  local parts = vim.split(self.partial .. chunk, "\n", { plain = true })
  self.partial = table.remove(parts) or ""
  self:_write(parts)
end

function Presenter:close()
  self.programmatic_close = true
  if self.snacks then
    pcall(self.snacks.close, self.snacks)
    return
  end
  if self.win and vim.api.nvim_win_is_valid(self.win) then
    vim.api.nvim_win_close(self.win, true)
  end
end

local function watch_close(presenter, on_close)
  if not on_close or not presenter.win then
    return
  end

  vim.api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(presenter.win),
    once = true,
    callback = function()
      if presenter.programmatic_close or presenter.close_called then
        return
      end
      presenter.close_called = true
      on_close()
    end,
  })
end

function Presenter:finish(ok)
  if self.partial ~= "" then
    local partial = self.partial
    self.partial = ""
    self:_write({ partial })
  end

  if ok then
    vim.defer_fn(function()
      self:close()
    end, self.close_on_success_ms)
  end
end

local function native_window(buf, title, config)
  local width = math.max(1, math.floor(vim.o.columns * 0.8))
  local height = math.max(1, math.floor((vim.o.lines - 2) * 0.7))
  return vim.api.nvim_open_win(buf, false, {
    relative = "editor",
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    width = width,
    height = height,
    style = "minimal",
    border = config.float.border,
    title = title,
    title_pos = "center",
  })
end

function M.open(target, config, on_close)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "nvim-stm32-output"

  local label = target.mcu or target.family or "unknown target"
  local title = " nvim-stm32 build: " .. label .. " "
  local presenter = setmetatable({
    buf = buf,
    partial = "",
    empty = true,
    close_on_success_ms = config.float.close_on_success_ms,
  }, Presenter)

  local snacks_ok, snacks = pcall(require, "snacks")
  if snacks_ok and callable(snacks.win) then
    local opened, snack_window = pcall(snacks.win, {
      buf = buf,
      border = config.float.border,
      title = title,
      title_pos = "center",
      width = 0.8,
      height = 0.7,
      enter = false,
      show = false,
    })
    if opened and snack_window and type(snack_window.show) == "function" then
      snack_window:show()
      presenter.snacks = snack_window
      presenter.win = snack_window.win
      watch_close(presenter, on_close)
      return presenter
    end
  end

  presenter.win = native_window(buf, title, config)
  watch_close(presenter, on_close)
  return presenter
end

return M
