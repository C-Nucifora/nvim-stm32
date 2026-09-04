--- Find an STM32 project from the current buffer.
---
--- The walk starts at the buffer because one repository can hold several
--- firmware projects. It stops at the Git root to avoid adopting a build file
--- from an unrelated parent directory.
local targets = require("nvim-stm32.targets")

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

---@class Stm32Signal
---@field source "ioc"|"startup"|"linker"|"cmake"
---@field mcu string
---@field confidence "exact"|"inferred"
---@field file string
---@field board string|nil
---@field core string|nil
---@field fpu string|nil

--- Read the part number and board from a CubeMX .ioc file.
---@param path string
---@return string|nil mcu
---@return string|nil board
function M.read_ioc(path)
  local file = io.open(path, "r")
  if not file then
    return nil, nil
  end

  local mcu, device_id, board
  for line in file:lines() do
    line = line:gsub("\r$", "")
    mcu = mcu or line:match("^Mcu%.Name=(.+)$")
    device_id = device_id or line:match("^ProjectManager%.DeviceId=(.+)$")
    board = board or line:match("^board=(.+)$")
  end
  file:close()
  return mcu or device_id, board
end

--- Read a part number from a CubeMX startup filename.
---@param name string
---@return string|nil
function M.mcu_from_startup(name)
  local stem = name:match("^startup_(.+)%.s$")
  if not stem or not targets.parse(stem) then
    return nil
  end
  return stem:upper()
end

--- Read a part number from a CubeMX or CubeIDE linker-script filename.
---@param name string
---@return string|nil
function M.mcu_from_linker(name)
  local stem = name:match("^(.+)%.ld$")
  if not stem then
    return nil
  end
  stem = stem:upper():gsub("_FLASH$", ""):gsub("_RAM$", "")
  if not targets.parse(stem) then
    return nil
  end
  return stem
end

--- Scan generated CMake files for the device macro, CPU, and FPU.
---@param root string
---@return string|nil mcu
---@return string|nil core
---@return string|nil fpu
---@return string|nil file
function M.scan_cmake(root)
  local files = {
    root .. "/CMakeLists.txt",
    root .. "/cmake/stm32cubemx/CMakeLists.txt",
  }
  vim.list_extend(files, vim.fn.glob(root .. "/cmake/*.cmake", false, true))

  local mcu, core, fpu, source
  for _, path in ipairs(files) do
    local file = io.open(path, "r")
    if file then
      local contents = file:read("*a")
      file:close()
      if not mcu then
        local hit = contents:match("(STM32%u%d[%u%d]+[Xx][Xx])")
        if hit and targets.parse(hit) then
          mcu, source = hit, path
        end
      end
      core = core or contents:match("%-mcpu=([%w%-%.]+)")
      fpu = fpu or contents:match("%-mfpu=([%w%-%.]+)")
    end
  end
  return mcu, core, fpu, source
end

--- Return the first valid .ioc signal in the project root.
---@param root string
---@return Stm32Signal|nil
function M.signal_ioc(root)
  for _, path in ipairs(vim.fn.glob(root .. "/*.ioc", false, true)) do
    local mcu, board = M.read_ioc(path)
    if mcu and targets.parse(mcu) then
      return {
        source = "ioc",
        mcu = mcu,
        board = board,
        file = path,
        confidence = "exact",
      }
    end
  end
  return nil
end

--- Return the first valid startup-file signal.
---@param root string
---@return Stm32Signal|nil
function M.signal_startup(root)
  for _, dir in ipairs({ root, root .. "/Core/Startup" }) do
    for _, path in ipairs(vim.fn.glob(dir .. "/startup_*.s", false, true)) do
      local mcu = M.mcu_from_startup(vim.fs.basename(path))
      if mcu then
        return { source = "startup", mcu = mcu, file = path, confidence = "inferred" }
      end
    end
  end
  return nil
end

--- Return the first valid linker-script signal.
---@param root string
---@return Stm32Signal|nil
function M.signal_linker(root)
  for _, path in ipairs(vim.fn.glob(root .. "/*.ld", false, true)) do
    local mcu = M.mcu_from_linker(vim.fs.basename(path))
    if mcu then
      return { source = "linker", mcu = mcu, file = path, confidence = "inferred" }
    end
  end
  return nil
end

--- Return the CMake signal and its measured compiler flags.
---@param root string
---@return Stm32Signal|nil
function M.signal_cmake(root)
  local mcu, core, fpu, file = M.scan_cmake(root)
  if not mcu then
    return nil
  end
  return {
    source = "cmake",
    mcu = mcu,
    core = core,
    fpu = fpu,
    file = file,
    confidence = "inferred",
  }
end

--- Resolve an MCU from the available project signals in precedence order.
---@param root string
---@return table
function M.mcu(root)
  local signals = {}
  for _, find in ipairs({
    M.signal_ioc,
    M.signal_startup,
    M.signal_linker,
    M.signal_cmake,
  }) do
    local signal = find(root)
    if signal then
      signals[#signals + 1] = signal
    end
  end

  local best = signals[1]
  if not best then
    return { confidence = "unknown", signals = signals, agreement = 0 }
  end

  local device = targets.parse(best.mcu).device
  local agreement, board, core, fpu = 0, nil, nil, nil
  for _, signal in ipairs(signals) do
    if targets.parse(signal.mcu).device == device then
      agreement = agreement + 1
    end
    board = board or signal.board
    core = core or signal.core
    fpu = fpu or signal.fpu
  end

  return {
    mcu = best.mcu,
    board = board,
    core = core,
    fpu = fpu,
    confidence = best.confidence,
    signals = signals,
    agreement = agreement,
  }
end

---@class Stm32Target
---@field root string
---@field marker string
---@field build_backend string|nil
---@field mcu string|nil
---@field family string|nil
---@field core string|nil
---@field fpu string|nil
---@field flash_kb integer|nil
---@field ram_kb integer|nil
---@field board string|nil
---@field openocd_cfg string|nil
---@field elf string|nil
---@field confidence "exact"|"inferred"|"unknown"
---@field signals Stm32Signal[]
---@field agreement integer

--- Return the Target for a directory or the current buffer.
---@param dir? string
---@return Stm32Target|nil target
---@return string|nil err
function M.target(dir)
  local from = dir or M.start_dir()
  local root, backend, marker = M.root(from)
  if not root then
    return nil, "nvim-stm32: no STM32 project found at or above " .. from
  end

  local found = M.mcu(root)
  local info = found.mcu and targets.resolve(found.mcu) or {}

  return {
    root = root,
    marker = marker,
    build_backend = backend,
    mcu = found.mcu,
    family = info.family,
    core = found.core or info.core,
    fpu = found.fpu or info.fpu,
    flash_kb = info.flash_kb,
    ram_kb = info.ram_kb,
    board = found.board,
    openocd_cfg = info.openocd_cfg,
    elf = nil,
    confidence = found.confidence,
    signals = found.signals,
    agreement = found.agreement,
  }
end

return M
