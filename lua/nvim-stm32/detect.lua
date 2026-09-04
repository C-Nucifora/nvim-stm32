--- Find an STM32 project from the current buffer.
---
--- The walk starts at the buffer because one repository can hold several
--- firmware projects. It stops at the Git root to avoid adopting a build file
--- from an unrelated parent directory.
local M = {}

--- Build markers in precedence order.
---@type { file?: string, glob?: string, backend?: string }[]
M.markers = {
  { file = "CMakePresets.json", backend = "cmake_presets" },
  { file = "CMakeLists.txt", backend = "cmake_plain" },
  { file = "Makefile", backend = "make" },
  { glob = "*.ioc", backend = nil },
}

--- Return the current buffer's directory, or cwd for an unnamed buffer.
---@return string
function M.start_dir()
  local name = vim.api.nvim_buf_get_name(0)
  if name ~= "" and vim.uv.fs_stat(name) then
    return vim.fs.dirname(name)
  end
  return vim.fn.getcwd()
end

--- Find the highest-priority project marker directly inside a directory.
---@param dir string
---@return string|nil backend
---@return string|nil marker
function M.markers_in(dir)
  for _, candidate in ipairs(M.markers) do
    if candidate.file then
      local path = dir .. "/" .. candidate.file
      if vim.uv.fs_stat(path) then
        return candidate.backend, path
      end
    else
      local hits = vim.fn.glob(dir .. "/" .. candidate.glob, false, true)
      if #hits > 0 then
        table.sort(hits)
        return candidate.backend, hits[1]
      end
    end
  end
  return nil, nil
end

--- Find the nearest project root at or above a directory.
---@param dir? string
---@return string|nil root
---@return string|nil backend
---@return string|nil marker
function M.root(dir)
  dir = vim.fs.normalize(dir or M.start_dir())

  local git = vim.fs.find(".git", { path = dir, upward = true, limit = 1 })[1]
  local stop = git and vim.fs.dirname(git) or nil

  local current = dir
  while current and current ~= "" do
    local backend, marker = M.markers_in(current)
    if marker then
      return current, backend, marker
    end
    if current == stop then
      break
    end
    local parent = vim.fs.dirname(current)
    if parent == current then
      break
    end
    current = parent
  end

  return nil, nil, nil
end

return M
