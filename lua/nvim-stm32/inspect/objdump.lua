local linker = require("nvim-stm32.inspect.linker")
local model = require("nvim-stm32.model")

local M = {}

local function objdump_error(code, message)
  return model.error({
    code = code,
    message = "nvim-stm32: " .. message,
    operation = "analyze",
    hint = "run arm-none-eabi-objdump -h against the selected ELF",
  })
end

local function split_lines(text)
  local lines = {}
  for line in (text .. "\n"):gmatch("(.-)\n") do
    lines[#lines + 1] = line:gsub("\r$", "")
  end
  return lines
end

local function parse_flags(line)
  local flags = {}
  for flag in line:gmatch("[%u_]+") do
    flags[#flags + 1] = flag
  end
  return flags
end

function M.parse_sections(text)
  if type(text) ~= "string" then
    return nil, objdump_error("objdump-output-invalid", "objdump output must be text")
  end
  local lines = split_lines(text)
  local sections = {}
  for index, line in ipairs(lines) do
    local section_index, name, size, vma, lma, file_offset, alignment = line:match(
      "^%s*(%d+)%s+(%S+)%s+([%da-fA-F]+)%s+([%da-fA-F]+)%s+([%da-fA-F]+)%s+([%da-fA-F]+)%s+2%*%*(%d+)%s*$"
    )
    if section_index then
      local flags_line = lines[index + 1] or ""
      local flags = parse_flags(flags_line)
      if #flags == 0 then
        return nil,
          objdump_error(
            "objdump-output-invalid",
            "section " .. name .. " has no flag record"
          )
      end
      sections[#sections + 1] = {
        index = tonumber(section_index),
        name = name,
        size = tonumber(size, 16),
        vma = tonumber(vma, 16),
        lma = tonumber(lma, 16),
        file_offset = tonumber(file_offset, 16),
        alignment = 2 ^ tonumber(alignment),
        flags = flags,
      }
    end
  end
  if #sections == 0 then
    return nil,
      objdump_error("objdump-output-invalid", "could not parse any section records")
  end
  return sections
end

local function flag_set(flags)
  local set = {}
  for _, flag in ipairs(flags or {}) do
    set[flag] = true
  end
  return set
end

local function containing_region(regions, address)
  for index, region in ipairs(regions) do
    if address >= region.origin and address < region.origin + region.length then
      return index, region
    end
  end
end

local function assigned_region(regions, section, address, role)
  local index, region = containing_region(regions, address)
  if region and address + section.size > region.origin + region.length then
    return nil,
      nil,
      objdump_error(
        "objdump-section-overflow",
        section.name .. " " .. role .. " bytes exceed region " .. region.name
      )
  end
  return index, region
end

function M.report(sections, regions)
  if type(sections) ~= "table" or type(regions) ~= "table" then
    return nil,
      objdump_error("objdump-report-invalid", "sections and regions must be lists")
  end
  local flash, flash_err = linker.flash_region(regions)
  if not flash then
    return nil, flash_err
  end
  local report = { totals = { flash = 0, ram = 0 }, regions = {}, sections = {} }
  local flash_index
  for index, region in ipairs(regions) do
    report.regions[index] = vim.tbl_extend("force", vim.deepcopy(region), {
      used = 0,
      percentage = 0,
    })
    if region.name:lower() == flash.name:lower() then
      flash_index = index
    end
  end

  for _, section in ipairs(sections) do
    local item = vim.deepcopy(section)
    local flags = flag_set(item.flags)
    item.debug = flags.DEBUGGING == true or item.name:match("^%.debug") ~= nil
    item.counted = false
    item.unassigned = false
    if item.size > 0 and not item.debug then
      if flags.ALLOC then
        local region_index, region, region_err =
          assigned_region(regions, item, item.vma, "runtime")
        if region_err then
          return nil, region_err
        end
        item.runtime_region = region and region.name or nil
        if not region then
          item.unassigned = true
        elseif region_index ~= flash_index then
          report.regions[region_index].used = report.regions[region_index].used
            + item.size
          report.totals.ram = report.totals.ram + item.size
          item.counted = true
        end
      end
      if flags.ALLOC and flags.LOAD then
        local region_index, region, region_err =
          assigned_region(regions, item, item.lma, "load")
        if region_err then
          return nil, region_err
        end
        item.load_region = region and region.name or nil
        if not region then
          item.unassigned = true
        elseif region_index == flash_index then
          report.regions[region_index].used = report.regions[region_index].used
            + item.size
          report.totals.flash = report.totals.flash + item.size
          item.counted = true
        end
      end
    end
    report.sections[#report.sections + 1] = item
  end

  for _, region in ipairs(report.regions) do
    region.percentage = region.used / region.length * 100
  end
  return report
end

return M
