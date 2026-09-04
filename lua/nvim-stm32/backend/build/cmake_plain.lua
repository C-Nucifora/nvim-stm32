local M = {}

function M.available()
  return vim.fn.executable("cmake") == 1
end

function M.configure_cmd()
  return { "cmake", "-S", ".", "-B", "build" }
end

function M.cmd()
  return { "cmake", "--build", "build" }
end

function M.parse(output, code)
  return { ok = code == 0, code = code, output = output }
end

return M
