local model = require("nvim-stm32.model")

local M = {}

local function output_error(message)
  return model.error({
    code = "size-output-invalid",
    message = "nvim-stm32: " .. message,
    operation = "analyze",
    hint = "run arm-none-eabi-size -B -x against the selected ELF",
  })
end

local function number(token)
  if token:match("^0[xX][%da-fA-F]+$") then
    return tonumber(token)
  end
  if token:match("^%d+$") then
    return tonumber(token, 10)
  end
end

local function hexadecimal(token)
  if token:match("^0[xX][%da-fA-F]+$") then
    return tonumber(token)
  end
  if token:match("^[%da-fA-F]+$") then
    return tonumber(token, 16)
  end
end

function M.parse(text)
  if type(text) ~= "string" then
    return nil, output_error("GNU size output must be text")
  end
  local saw_header = false
  for line in text:gmatch("[^\r\n]+") do
    if line:match("^%s*text%s+data%s+bss%s+dec%s+hex%s+filename%s*$") then
      saw_header = true
    elseif saw_header and line:match("%S") then
      local text_token, data_token, bss_token, dec_token, hex_token, filename =
        line:match("^%s*(%S+)%s+(%S+)%s+(%S+)%s+(%S+)%s+(%S+)%s+(.+%S)%s*$")
      local text_bytes = text_token and number(text_token)
      local data_bytes = data_token and number(data_token)
      local bss_bytes = bss_token and number(bss_token)
      local dec_bytes = dec_token and number(dec_token)
      local hex_bytes = hex_token and hexadecimal(hex_token)
      if
        text_bytes
        and data_bytes
        and bss_bytes
        and dec_bytes
        and hex_bytes
        and filename
      then
        return { text = text_bytes, data = data_bytes, bss = bss_bytes }
      end
      break
    end
  end
  return nil, output_error("could not parse the Berkeley size row")
end

return M
