--- nvim-stm32: what a part number tells you about the chip.
---
--- Everything here is a table lookup on ST's part-number scheme:
---
---     STM32 F4 29 Z I T x
---           |  |  | | | temperature range
---           |  |  | | package
---           |  |  | flash size
---           |  |  pin count
---           |  device
---           series
---
--- Supporting another family is a new entry in M.families. It must never become
--- a branch in code.
local M = {}

---@class Stm32FamilyInfo
---@field family string
---@field core string
---@field fpu string|nil
---@field openocd_cfg string

--- Series code to family facts.
---@type table<string, Stm32FamilyInfo>
M.families = {
  C0 = {
    family = "STM32C0",
    core = "cortex-m0plus",
    fpu = nil,
    openocd_cfg = "target/stm32c0x.cfg",
  },
  F0 = {
    family = "STM32F0",
    core = "cortex-m0",
    fpu = nil,
    openocd_cfg = "target/stm32f0x.cfg",
  },
  F1 = {
    family = "STM32F1",
    core = "cortex-m3",
    fpu = nil,
    openocd_cfg = "target/stm32f1x.cfg",
  },
  F2 = {
    family = "STM32F2",
    core = "cortex-m3",
    fpu = nil,
    openocd_cfg = "target/stm32f2x.cfg",
  },
  F3 = {
    family = "STM32F3",
    core = "cortex-m4",
    fpu = "fpv4-sp-d16",
    openocd_cfg = "target/stm32f3x.cfg",
  },
  F4 = {
    family = "STM32F4",
    core = "cortex-m4",
    fpu = "fpv4-sp-d16",
    openocd_cfg = "target/stm32f4x.cfg",
  },
  F7 = {
    family = "STM32F7",
    core = "cortex-m7",
    fpu = "fpv5-d16",
    openocd_cfg = "target/stm32f7x.cfg",
  },
  G0 = {
    family = "STM32G0",
    core = "cortex-m0plus",
    fpu = nil,
    openocd_cfg = "target/stm32g0x.cfg",
  },
  G4 = {
    family = "STM32G4",
    core = "cortex-m4",
    fpu = "fpv4-sp-d16",
    openocd_cfg = "target/stm32g4x.cfg",
  },
  H5 = {
    family = "STM32H5",
    core = "cortex-m33",
    fpu = "fpv5-sp-d16",
    openocd_cfg = "target/stm32h5x.cfg",
  },
  H7 = {
    family = "STM32H7",
    core = "cortex-m7",
    fpu = "fpv5-d16",
    openocd_cfg = "target/stm32h7x.cfg",
  },
  L0 = {
    family = "STM32L0",
    core = "cortex-m0plus",
    fpu = nil,
    openocd_cfg = "target/stm32l0.cfg",
  },
  L1 = {
    family = "STM32L1",
    core = "cortex-m3",
    fpu = nil,
    openocd_cfg = "target/stm32l1.cfg",
  },
  L4 = {
    family = "STM32L4",
    core = "cortex-m4",
    fpu = "fpv4-sp-d16",
    openocd_cfg = "target/stm32l4x.cfg",
  },
  L5 = {
    family = "STM32L5",
    core = "cortex-m33",
    fpu = "fpv5-sp-d16",
    openocd_cfg = "target/stm32l5x.cfg",
  },
  U5 = {
    family = "STM32U5",
    core = "cortex-m33",
    fpu = "fpv5-sp-d16",
    openocd_cfg = "target/stm32u5x.cfg",
  },
  WB = {
    family = "STM32WB",
    core = "cortex-m4",
    fpu = "fpv4-sp-d16",
    openocd_cfg = "target/stm32wbx.cfg",
  },
  WL = {
    family = "STM32WL",
    core = "cortex-m4",
    fpu = nil,
    openocd_cfg = "target/stm32wlx.cfg",
  },
}

--- Flash-size code to size in KiB.
---@type table<string, integer>
M.flash_sizes = {
  ["3"] = 8,
  ["4"] = 16,
  ["6"] = 32,
  ["8"] = 64,
  B = 128,
  Z = 192,
  C = 256,
  D = 384,
  E = 512,
  F = 768,
  G = 1024,
  H = 1536,
  I = 2048,
  J = 4096,
}

--- SRAM in KiB by device code. The part number does not encode RAM.
---@type table<string, integer>
M.ram_kb = {
  STM32F429 = 256,
}

---@class Stm32Parts
---@field mcu string
---@field series string
---@field device string
---@field pins string|nil
---@field flash string|nil
---@field package string|nil
---@field temp string|nil

--- Split a part number into its coded fields.
---@param mcu string|nil
---@return Stm32Parts|nil
function M.parse(mcu)
  if type(mcu) ~= "string" then
    return nil
  end
  local rest = mcu:upper():match("^STM32([%u%d]+)$")
  if not rest or #rest < 4 then
    return nil
  end
  local series = rest:sub(1, 2)
  if not M.families[series] then
    return nil
  end

  local function code(i)
    local c = rest:sub(i, i)
    if c == "" or c == "X" then
      return nil
    end
    return c
  end

  return {
    mcu = mcu:upper(),
    series = series,
    device = "STM32" .. rest:sub(1, 4),
    pins = code(5),
    flash = code(6),
    package = code(7),
    temp = code(8),
  }
end

--- Resolve family and memory facts from a part number.
---@param mcu string|nil
---@return table|nil
function M.resolve(mcu)
  local parts = M.parse(mcu)
  if not parts then
    return nil
  end
  local family = M.families[parts.series]
  return {
    device = parts.device,
    family = family.family,
    core = family.core,
    fpu = family.fpu,
    openocd_cfg = family.openocd_cfg,
    flash_kb = parts.flash and M.flash_sizes[parts.flash] or nil,
    ram_kb = M.ram_kb[parts.device],
  }
end

--- Return the device name used by ST tools.
---@param mcu string|nil
---@return string|nil
function M.device_name(mcu)
  local parts = M.parse(mcu)
  if not parts then
    return nil
  end
  if parts.pins and parts.flash then
    return parts.device .. parts.pins .. parts.flash
  end
  return parts.device
end

return M
