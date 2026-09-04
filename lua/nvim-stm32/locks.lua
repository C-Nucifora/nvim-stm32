local model = require("nvim-stm32.model")

local M = {}

local held = {}
local next_acquisition_id = 0

function M.probe_id(serial)
  vim.validate("serial", serial, function(value)
    return type(value) == "string" and value:match("%S") ~= nil
  end, "a non-empty string")
  local normalized = serial:match("^%s*(.-)%s*$")
  local hexadecimal = normalized:match("^0[xX]([%da-fA-F]+)$")
    or normalized:match("^([%da-fA-F]+)$")
  return hexadecimal and hexadecimal:upper() or normalized
end

local function same_lock(a, b)
  return a.kind == b.kind and a.id == b.id
end

local function find(lock)
  for _, entry in ipairs(held) do
    if same_lock(entry.lock, lock) then
      return entry
    end
  end
end

local function contention_error(entry)
  return model.error({
    code = "operation-lock-contended",
    message = string.format(
      "nvim-stm32: %s lock %s is held by operation %s",
      entry.lock.kind,
      entry.lock.id,
      entry.owner_id
    ),
    operation = "operation",
    hint = "wait for the active operation to finish, then try again",
  })
end

function M.acquire(owner_id, requested)
  vim.validate("owner_id", owner_id, function(value)
    return type(value) == "string" and value ~= ""
  end, "a non-empty string")
  vim.validate("requested", requested, "table")

  local normalized = {}
  for index, lock in ipairs(requested) do
    normalized[index] = model.lock(lock)
    local entry = find(normalized[index])
    if entry then
      return nil, contention_error(entry)
    end
  end

  next_acquisition_id = next_acquisition_id + 1
  local acquisition_id = next_acquisition_id
  for _, lock in ipairs(normalized) do
    held[#held + 1] = {
      acquisition_id = acquisition_id,
      lock = lock,
      owner_id = owner_id,
    }
  end

  local released = false
  return function()
    if released then
      return false
    end
    released = true
    held = vim.tbl_filter(function(entry)
      return not (entry.owner_id == owner_id and entry.acquisition_id == acquisition_id)
    end, held)
    return true
  end
end

return M
