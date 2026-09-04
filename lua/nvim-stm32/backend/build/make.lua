local M = {}

function M.available()
  return vim.fn.executable("make") == 1
end

function M.cmd()
  return { "make" }
end

function M.parse(output, code)
  return { ok = code == 0, code = code, output = output }
end

return M
