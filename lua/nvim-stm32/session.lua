local states = {}

local M = {}

local function project_root(project_or_root)
  local value = project_or_root
  if type(project_or_root) == "table" then
    value = project_or_root.root or project_or_root.id
  end
  vim.validate("project_or_root", value, function(root)
    return type(root) == "string" and root ~= ""
  end, "a project or non-empty root string")
  return vim.fs.normalize(value)
end

local function empty_state(root)
  return {
    project_id = root,
    image_id = nil,
    configuration = nil,
    probe_serial = nil,
    monitor_device = nil,
    artifacts = {},
    last_result = nil,
  }
end

local function state_for(project_or_root)
  local root = project_root(project_or_root)
  if not states[root] then
    states[root] = empty_state(root)
  end
  return root, states[root]
end

local function same_artifact_identity(left, right)
  return left.image_id == right.image_id
    and left.configuration == right.configuration
    and left.kind == right.kind
end

local function replace_artifacts(existing, incoming)
  local replacements = {}
  for _, artifact in ipairs(incoming) do
    local group
    for _, candidate in ipairs(replacements) do
      if same_artifact_identity(candidate.identity, artifact) then
        group = candidate
        break
      end
    end
    if not group then
      group = { identity = artifact, artifacts = {} }
      replacements[#replacements + 1] = group
    end
    group.artifacts[#group.artifacts + 1] = artifact
  end

  local result, inserted = {}, {}
  for _, artifact in ipairs(existing) do
    local group
    for _, candidate in ipairs(replacements) do
      if same_artifact_identity(candidate.identity, artifact) then
        group = candidate
        break
      end
    end
    if group then
      if not inserted[group] then
        for _, replacement in ipairs(group.artifacts) do
          result[#result + 1] = replacement
        end
        inserted[group] = true
      end
    else
      result[#result + 1] = artifact
    end
  end
  for _, group in ipairs(replacements) do
    if not inserted[group] then
      for _, replacement in ipairs(group.artifacts) do
        result[#result + 1] = replacement
      end
    end
  end
  return result
end

local function is_dense_record_list(value)
  if type(value) ~= "table" then
    return false
  end
  local count, maximum = 0, 0
  for key, item in pairs(value) do
    if type(key) ~= "number" or key < 1 or key % 1 ~= 0 or type(item) ~= "table" then
      return false
    end
    count = count + 1
    maximum = math.max(maximum, key)
  end
  return maximum == count
end

local function copy_result(result)
  vim.validate("result", result, "table")
  vim.validate(
    "result.artifacts",
    result.artifacts,
    is_dense_record_list,
    "a dense list of tables"
  )
  return vim.deepcopy(result)
end

--- Return a copy of the session for a project, creating an empty one if needed.
---@param project_or_root table|string
---@return table
function M.get(project_or_root)
  local _, state = state_for(project_or_root)
  return vim.deepcopy(state)
end

--- Merge selected session values and return a copy of the updated session.
---@param project_or_root table|string
---@param patch table
---@return table
function M.select(project_or_root, patch)
  local root, state = state_for(project_or_root)
  vim.validate("patch", patch, "table")
  local next_state = vim.deepcopy(state)
  for key, value in pairs(patch) do
    next_state[key] = vim.deepcopy(value)
  end
  next_state.project_id = root
  states[root] = next_state
  return vim.deepcopy(next_state)
end

--- Store an operation result and replace only matching artifact records.
---@param project_or_root table|string
---@param result table
---@return table
function M.record(project_or_root, result)
  local copied_result = copy_result(result)
  local _, state = state_for(project_or_root)
  local next_state = vim.deepcopy(state)
  next_state.artifacts =
    replace_artifacts(next_state.artifacts, copied_result.artifacts)
  next_state.last_result = copied_result
  states[next_state.project_id] = next_state
  return vim.deepcopy(next_state)
end

--- Clear one project session, or all sessions when no project is supplied.
---@param project_or_root? table|string
function M.clear(project_or_root)
  if project_or_root == nil then
    states = {}
    return
  end
  states[project_root(project_or_root)] = nil
end

return M
