local model = require("nvim-stm32.model")
local root = require("nvim-stm32.discover.root")
local signals = require("nvim-stm32.discover.signals")
local targets = require("nvim-stm32.targets")

local M = {}

local function multi_image_preset(dir)
  local image_id = vim.fs.basename(dir):upper()
  if image_id ~= "CM4" and image_id ~= "CM7" then
    return nil, nil, nil
  end
  local parent = vim.fs.dirname(dir)
  local preset = parent .. "/CMakePresets.json"
  if not vim.uv.fs_stat(preset) then
    return nil, nil, nil
  end
  local sibling = parent .. "/" .. (image_id == "CM4" and "CM7" or "CM4")
  if #vim.fn.glob(sibling .. "/*.ioc", false, true) > 0 then
    return parent, "cmake_presets", preset
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

local function same_device(left, right)
  return targets.parse(left[1].mcu).device == targets.parse(right[1].mcu).device
end

local function compatible_core(left, right)
  return not left[1].core or not right[1].core or left[1].core == right[1].core
end

local function merge_compatible_unhinted_groups(groups)
  local merged = {}
  for _, group in ipairs(groups) do
    if group[1].image_hint then
      merged[#merged + 1] = group
    else
      local matches = {}
      for _, hinted in ipairs(groups) do
        if
          hinted[1].image_hint
          and same_device(group, hinted)
          and compatible_core(group, hinted)
        then
          matches[#matches + 1] = hinted
        end
      end
      if #matches == 1 then
        vim.list_extend(matches[1], group)
      else
        merged[#merged + 1] = group
      end
    end
  end
  return merged
end

local function ambiguous_groups(groups)
  local unhinted, hinted = 0, 0
  for _, group in ipairs(groups) do
    if group[1].image_hint then
      hinted = hinted + 1
    else
      unhinted = unhinted + 1
      if #group > 1 then
        return true
      end
    end
  end
  return unhinted > 1 or (unhinted > 0 and hinted > 0)
end

local function group_id(group, count, index)
  if count == 1 then
    return "application"
  end
  local hint = group[1].image_hint
  if hint == "CM4" or hint == "CM7" then
    return hint
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
    local multi_root, multi_adapter, multi_marker = multi_image_preset(project_root)
    if multi_root then
      project_root, adapter, marker = multi_root, multi_adapter, multi_marker
    end
  end

  local found = signals.collect(project_root)
  local groups, candidates = collect_groups(found)
  groups = merge_compatible_unhinted_groups(groups)
  if #groups == 0 then
    groups = { { { mcu = nil, confidence = "unknown", image_hint = nil } } }
    candidates = {}
  end

  local ambiguous = ambiguous_groups(groups)
  local _, measured_core, measured_fpu = nil, nil, nil
  if #groups == 1 and not ambiguous then
    _, measured_core, measured_fpu = signals.scan_cmake(project_root)
  end

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
    local local_core, local_fpu = nil, nil
    for _, signal in ipairs(image_signals) do
      local_core = local_core or signal.core
      local_fpu = local_fpu or signal.fpu
    end
    target.core = local_core or measured_core or target.core
    target.fpu = local_fpu or measured_fpu or target.fpu
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
  if ambiguous then
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
