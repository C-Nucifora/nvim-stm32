local targets = require("nvim-stm32.targets")

local M = {}

local precedence = { ioc = 1, startup = 2, linker = 3, cmake = 4 }

local function paths(pattern)
  local found = vim.fn.glob(pattern, false, true)
  table.sort(found)
  return found
end

local function image_hint(root, path, core, build_target)
  if build_target then
    local named = build_target:upper():match("CM([47])")
    if named then
      return "CM" .. named
    end
  end
  if core then
    local named = core:upper():match("CORTEX%-M([47])")
      or core:upper():match("CM([47])")
    if named then
      return "CM" .. named
    end
  end
  local relative = path:sub(#root + 2)
  local upper = relative:upper()
  local hinted = upper:match("^CM([47])/")
    or upper:match("/CM([47])/")
    or upper:match("^CM([47])$")
  if hinted then
    return "CM" .. hinted
  end
  return nil
end

local function cmake_files(root)
  local seen, out = {}, {}
  for _, pattern in ipairs({ root .. "/**/CMakeLists.txt", root .. "/**/*.cmake" }) do
    for _, path in ipairs(paths(pattern)) do
      if not seen[path] then
        seen[path] = true
        out[#out + 1] = path
      end
    end
  end
  table.sort(out)
  return out
end

local function read_cmake(path)
  local file = io.open(path, "r")
  if not file then
    return nil, nil, nil, nil
  end
  local contents = file:read("*a")
  file:close()
  return contents:match("(STM32%u%d[%u%d]+[Xx][Xx])%f[^%w_]"),
    contents:match("%-mcpu=([%w%-%.]+)"),
    contents:match("%-mfpu=([%w%-%.]+)"),
    contents:match("add_executable%s*%(%s*([%w_%-]+)") or contents:match(
      "add_custom_target%s*%(%s*([%w_%-]+)"
    )
end

function M.read_ioc(path)
  local file = io.open(path, "r")
  if not file then
    return nil, nil
  end

  local mcu, device_id, board, user_name
  for line in file:lines() do
    line = line:gsub("\r$", "")
    mcu = mcu or line:match("^Mcu%.Name=(.+)$")
    device_id = device_id or line:match("^ProjectManager%.DeviceId=(.+)$")
    board = board or line:match("^board=(.+)$")
    user_name = user_name or line:match("^Mcu%.UserName=(.+)$")
  end
  file:close()
  return mcu or device_id, board, user_name
end

function M.mcu_from_startup(name)
  local stem = name:match("^startup_(.+)%.s$")
  if not stem or not targets.parse(stem) then
    return nil
  end
  return stem:upper()
end

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

function M.scan_cmake(root)
  local mcu, core, fpu, source
  for _, path in ipairs(cmake_files(root)) do
    local hit, found_core, found_fpu = read_cmake(path)
    if not mcu and hit and targets.parse(hit) then
      mcu, source = hit, path
    end
    core = core or found_core
    fpu = fpu or found_fpu
  end
  return mcu, core, fpu, source
end

local function append_ioc_signals(out, root)
  for _, path in ipairs(paths(root .. "/**/*.ioc")) do
    local mcu, board, user_name = M.read_ioc(path)
    if mcu and targets.parse(mcu) then
      out[#out + 1] = {
        source = "ioc",
        file = path,
        mcu = mcu,
        confidence = "exact",
        board = board,
        core = nil,
        fpu = nil,
        image_hint = image_hint(root, path, user_name),
      }
    end
  end
end

local function append_startup_signals(out, root)
  for _, path in ipairs(paths(root .. "/**/startup_*.s")) do
    local mcu = M.mcu_from_startup(vim.fs.basename(path))
    if mcu then
      local file = io.open(path, "r")
      local contents = file and file:read("*a") or ""
      if file then
        file:close()
      end
      local core = contents:match("%.cpu%s+([%w%-%.]+)")
      out[#out + 1] = {
        source = "startup",
        file = path,
        mcu = mcu,
        confidence = "inferred",
        board = nil,
        core = core,
        fpu = nil,
        image_hint = image_hint(root, path, core),
      }
    end
  end
end

local function append_linker_signals(out, root)
  for _, path in ipairs(paths(root .. "/**/*.ld")) do
    local mcu = M.mcu_from_linker(vim.fs.basename(path))
    if mcu then
      out[#out + 1] = {
        source = "linker",
        file = path,
        mcu = mcu,
        confidence = "inferred",
        board = nil,
        core = nil,
        fpu = nil,
        image_hint = image_hint(root, path),
      }
    end
  end
end

local function append_cmake_signals(out, root)
  local _, aggregate_core, aggregate_fpu = M.scan_cmake(root)
  local matches = {}
  for _, path in ipairs(cmake_files(root)) do
    local mcu, core, fpu, build_target = read_cmake(path)
    if mcu and targets.parse(mcu) then
      matches[#matches + 1] = {
        mcu = mcu,
        core = core,
        fpu = fpu,
        file = path,
        build_target = build_target,
      }
    end
  end
  for _, match in ipairs(matches) do
    out[#out + 1] = {
      source = "cmake",
      file = match.file,
      mcu = match.mcu,
      confidence = "inferred",
      board = nil,
      core = match.core or aggregate_core,
      fpu = match.fpu or aggregate_fpu,
      build_target = match.build_target,
      image_hint = image_hint(
        root,
        match.file,
        match.core or aggregate_core,
        match.build_target
      ),
    }
  end
end

function M.collect(project_root)
  local out = {}
  append_ioc_signals(out, project_root)
  append_startup_signals(out, project_root)
  append_linker_signals(out, project_root)
  append_cmake_signals(out, project_root)
  table.sort(out, function(a, b)
    local a_precedence = precedence[a.source]
    local b_precedence = precedence[b.source]
    return a_precedence == b_precedence and a.file < b.file
      or a_precedence < b_precedence
  end)
  return out
end

function M.signal_ioc(root)
  for _, signal in ipairs(M.collect(root)) do
    if signal.source == "ioc" then
      return signal
    end
  end
  return nil
end

function M.signal_startup(root)
  for _, signal in ipairs(M.collect(root)) do
    if signal.source == "startup" then
      return signal
    end
  end
  return nil
end

function M.signal_linker(root)
  for _, signal in ipairs(M.collect(root)) do
    if signal.source == "linker" then
      return signal
    end
  end
  return nil
end

function M.signal_cmake(root)
  for _, signal in ipairs(M.collect(root)) do
    if signal.source == "cmake" then
      return signal
    end
  end
  return nil
end

function M.mcu(root)
  local found = M.collect(root)
  local best = found[1]
  if not best then
    return { confidence = "unknown", signals = found, agreement = 0 }
  end

  local device = targets.parse(best.mcu).device
  local agreement, board, core, fpu = 0, nil, nil, nil
  for _, signal in ipairs(found) do
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
    signals = found,
    agreement = agreement,
  }
end

return M
