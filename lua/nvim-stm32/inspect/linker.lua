local model = require("nvim-stm32.model")

local M = {}

local ADDRESS_SPACE_END = 0x100000000

local function linker_error(code, message)
  return model.error({
    code = code,
    message = "nvim-stm32: " .. message,
    operation = "analyze",
    hint = "check the linker MEMORY block",
  })
end

local function trim(value)
  return value:match("^%s*(.-)%s*$")
end

local function unsigned(token)
  if token:match("^0[xX][%da-fA-F]+$") or token:match("^%d+$") then
    return tonumber(token)
  end
end

local function length_bytes(token)
  local number, suffix = token:match("^(%d+)([kKmM]?)$")
  if not number then
    if token:match("^0[xX][%da-fA-F]+$") then
      return tonumber(token)
    end
    return nil
  end
  local multiplier = suffix:lower() == "k" and 1024
    or suffix:lower() == "m" and 1024 * 1024
    or 1
  return tonumber(number) * multiplier
end

local function fields(line)
  local name, attributes, origin, length = line:match(
    "^%s*([%a_][%w_%.]*)%s*%(([^)]*)%)%s*:%s*ORIGIN%s*=%s*([^,%s]+)%s*,%s*LENGTH%s*=%s*(%S+)%s*$"
  )
  if name then
    return name, trim(attributes), origin, length
  end
  name, origin, length = line:match(
    "^%s*([%a_][%w_%.]*)%s*:%s*ORIGIN%s*=%s*([^,%s]+)%s*,%s*LENGTH%s*=%s*(%S+)%s*$"
  )
  return name, "", origin, length
end

function M.parse(text)
  if type(text) ~= "string" then
    return nil, linker_error("linker-input-invalid", "linker input must be text")
  end
  local without_comments = text:gsub("/%*.-%*/", "")
  local body = without_comments:match("MEMORY%s*{(.-)}")
  if not body then
    return nil, linker_error("linker-memory-missing", "no MEMORY block found")
  end

  local regions, names = {}, {}
  for line in body:gmatch("[^\r\n]+") do
    if line:match("%S") then
      local name, attributes, origin_token, length_token = fields(line)
      if not name then
        return nil,
          linker_error(
            "linker-region-invalid",
            "malformed MEMORY region: " .. trim(line)
          )
      end
      local origin = unsigned(origin_token)
      if not origin then
        return nil,
          linker_error(
            "linker-origin-invalid",
            "invalid origin for region " .. name .. ": " .. origin_token
          )
      end
      local length = length_bytes(length_token)
      if not length or length <= 0 then
        return nil,
          linker_error(
            "linker-length-invalid",
            "invalid length for region " .. name .. ": " .. length_token
          )
      end
      if origin >= ADDRESS_SPACE_END or origin + length > ADDRESS_SPACE_END then
        return nil,
          linker_error(
            "linker-region-overflow",
            "region exceeds the 32-bit address space: " .. name
          )
      end
      local folded = name:lower()
      if names[folded] then
        return nil,
          linker_error("linker-region-duplicate", "duplicate MEMORY region: " .. name)
      end
      names[folded] = true
      regions[#regions + 1] = {
        name = name,
        attributes = attributes,
        origin = origin,
        length = length,
      }
    end
  end
  if #regions == 0 then
    return nil, linker_error("linker-memory-empty", "MEMORY block has no regions")
  end

  for left_index, left in ipairs(regions) do
    for right_index = left_index + 1, #regions do
      local right = regions[right_index]
      if
        left.origin < right.origin + right.length
        and right.origin < left.origin + left.length
      then
        return nil,
          linker_error(
            "linker-region-overlap",
            "MEMORY regions overlap: " .. left.name .. " and " .. right.name
          )
      end
    end
  end
  return regions
end

function M.flash_region(regions)
  local matches = {}
  for _, region in ipairs(regions or {}) do
    if type(region.name) == "string" and region.name:lower() == "flash" then
      matches[#matches + 1] = region
    end
  end
  if #matches == 1 then
    return vim.deepcopy(matches[1])
  end
  if #matches == 0 then
    return nil, linker_error("linker-flash-missing", "no FLASH region found")
  end
  return nil, linker_error("linker-flash-ambiguous", "more than one FLASH region found")
end

return M
