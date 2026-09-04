local model = require("nvim-stm32.model")
local root = require("nvim-stm32.discover.root")
local signals = require("nvim-stm32.discover.signals")
local targets = require("nvim-stm32.targets")

local M = {}

local function enclosing_multi_image_preset(dir)
  local git = vim.fs.find(".git", { path = dir, upward = true, limit = 1 })[1]
  local stop = git and vim.fs.dirname(git) or nil
  local current = vim.fs.dirname(dir)
  while current and current ~= "" do
    local marker = current .. "/CMakePresets.json"
    if vim.uv.fs_stat(marker) then
      local hints = {}
      for _, signal in ipairs(signals.collect(current)) do
        if signal.confidence == "exact" and signal.image_hint then
          hints[signal.image_hint] = true
        end
      end
      if vim.tbl_count(hints) > 1 then
        return current, "cmake_presets", marker
      end
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

local function target_from(group, all_signals)
  local found = group[1]
  local info = found.mcu and targets.resolve(found.mcu) or {}
  local device = found.mcu and targets.parse(found.mcu).device or nil
  local agreement, board, core, fpu = 0, nil, nil, nil
  for _, signal in ipairs(all_signals) do
    if device and targets.parse(signal.mcu).device == device then
      agreement = agreement + 1
    end
    board = board or signal.board
    core = core or signal.core
    fpu = fpu or signal.fpu
  end
  return {
    root = nil,
    marker = nil,
    build_backend = nil,
    mcu = found.mcu,
    family = info.family,
    core = core or info.core,
    fpu = fpu or info.fpu,
    flash_kb = info.flash_kb,
    ram_kb = info.ram_kb,
    board = board,
    openocd_cfg = info.openocd_cfg,
    elf = nil,
    confidence = found.confidence,
    signals = all_signals,
    agreement = agreement,
    identity = { cpn = found.mcu },
    cores = core
        and { { id = found.image_hint or "application", architecture = core } }
      or {},
  }
end

local function group_key(signal)
  local device = targets.parse(signal.mcu).device
  return table.concat({ signal.image_hint or "", device, signal.core or "" }, "\0")
end

local function collect_groups(found)
  local candidates = {}
  for _, signal in ipairs(found) do
    if signal.confidence == "exact" then
      candidates[#candidates + 1] = signal
    end
  end
  if #candidates == 0 then
    candidates = found
  end

  local groups, order = {}, {}
  for _, signal in ipairs(candidates) do
    local key = group_key(signal)
    if not groups[key] then
      groups[key] = {}
      order[#order + 1] = groups[key]
    end
    groups[key][#groups[key] + 1] = signal
  end
  return order, candidates
end

local function group_id(group, count, index)
  local hint = group[1].image_hint
  if hint == "CM4" or hint == "CM7" then
    return hint
  end
  if count == 1 then
    return "application"
  end
  return "image_" .. index
end

function M.resolve(dir)
  local project_root, adapter, marker = root.find(dir)
  if not project_root then
    local from = dir or root.start_dir()
    return nil,
      model.error({
        code = "project-not-found",
        message = "nvim-stm32: no STM32 project found at or above " .. from,
        operation = "discover",
        hint = "open a file under an STM32 project",
      })
  end

  if marker:match("%.ioc$") then
    local multi_root, multi_adapter, multi_marker =
      enclosing_multi_image_preset(project_root)
    if multi_root then
      project_root, adapter, marker = multi_root, multi_adapter, multi_marker
    end
  end

  local found = signals.collect(project_root)
  local groups, candidates = collect_groups(found)
  if #groups == 0 then
    groups = { { { mcu = nil, confidence = "unknown", image_hint = nil } } }
    candidates = {}
  end

  table.sort(groups, function(a, b)
    return group_id(a, #groups, 1) < group_id(b, #groups, 2)
  end)

  local images = {}
  for index, group in ipairs(groups) do
    local id = group_id(group, #groups, index)
    local image_signals = {}
    for _, signal in ipairs(found) do
      if signal.image_hint == group[1].image_hint or #groups == 1 then
        image_signals[#image_signals + 1] = signal
      end
    end
    local target = target_from(group, image_signals)
    target.root = project_root
    target.marker = marker
    target.build_backend = adapter
    images[#images + 1] = model.image({
      id = id,
      name = id,
      target = target,
    })
  end

  local provenance = { signals = found }
  local unhinted, hinted = 0, 0
  for _, signal in ipairs(candidates) do
    if signal.image_hint then
      hinted = hinted + 1
    else
      unhinted = unhinted + 1
    end
  end
  if unhinted > 1 or (unhinted > 0 and hinted > 0) then
    provenance.warnings = {
      model.error({
        code = "ambiguous-images",
        message = "multiple exact images have no image hint",
        operation = "discover",
        hint = "add CM4 or CM7 image hints to the project files",
      }),
    }
  end

  return model.project({
    id = project_root,
    root = project_root,
    kind = adapter or "unconfigured",
    build = { adapter = adapter, marker = marker },
    images = images,
    provenance = provenance,
  })
end

return M
