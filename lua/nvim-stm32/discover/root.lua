local M = {}

M.markers = {
  { file = "CMakePresets.json", backend = "cmake_presets", strong = true },
  { glob = "*.ioc", backend = nil, strong = true },
  { file = "CMakeLists.txt", backend = "cmake_plain" },
  { file = "Makefile", backend = "make" },
}

local function buffer_name(bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name:match("^health://") then
    local previous = vim.fn.bufnr("#")
    if previous > 0 then
      name = vim.api.nvim_buf_get_name(previous)
    end
  end
  return name
end

function M.start_dir(bufnr)
  local name = buffer_name(bufnr or 0)
  if name ~= "" and vim.uv.fs_stat(name) then
    return vim.fs.dirname(name)
  end
  return vim.fn.getcwd()
end

function M.markers_in(dir)
  for _, candidate in ipairs(M.markers) do
    if candidate.file then
      local path = dir .. "/" .. candidate.file
      if vim.uv.fs_stat(path) then
        return candidate.backend, path, candidate.strong
      end
    else
      local hits = vim.fn.glob(dir .. "/" .. candidate.glob, false, true)
      if #hits > 0 then
        table.sort(hits)
        return candidate.backend, hits[1], candidate.strong
      end
    end
  end
  return nil, nil, nil
end

local function walk_candidates(dir)
  local git = vim.fs.find(".git", { path = dir, upward = true, limit = 1 })[1]
  local stop = git and vim.fs.dirname(git) or nil
  local candidates = {}
  local current = dir

  while current and current ~= "" do
    local backend, marker, strong = M.markers_in(current)
    if marker then
      candidates[#candidates + 1] = {
        root = current,
        adapter = backend,
        marker = marker,
        strong = strong,
      }
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

  return candidates
end

function M.find(dir)
  local candidates = walk_candidates(vim.fs.normalize(dir or M.start_dir()))
  for _, candidate in ipairs(candidates) do
    if candidate.strong then
      return candidate.root, candidate.adapter, candidate.marker
    end
  end
  local candidate = candidates[1]
  if candidate then
    return candidate.root, candidate.adapter, candidate.marker
  end
  return nil, nil, nil
end

return M
