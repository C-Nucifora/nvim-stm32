local args = {}
local after_separator = false
for _, value in ipairs(arg or {}) do
  if after_separator then
    args[#args + 1] = value
  elseif value == "--" then
    after_separator = true
  end
end

local code = require("nvim-stm32.corpus").main(args)
if code ~= 0 then
  vim.cmd("cquit " .. code)
else
  vim.cmd("quitall")
end
