local M = {}

local function copy(value)
  return vim.deepcopy(value)
end

local function required_string(name, value)
  vim.validate(name, value, function(v)
    return type(v) == "string" and v ~= ""
  end, "a non-empty string")
end

local function optional_string(name, value)
  vim.validate(name, value, "string", true)
end

local function list(name, value, predicate, message, non_empty)
  vim.validate(name, value, function(v)
    if type(v) ~= "table" then
      return false
    end
    local count = 0
    local maximum = 0
    for key in pairs(v) do
      if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then
        return false
      end
      count = count + 1
      maximum = math.max(maximum, key)
    end
    if (non_empty and count == 0) or maximum ~= count then
      return false
    end
    for index = 1, count do
      if not predicate(v[index], index) then
        return false
      end
    end
    return true
  end, message or "a list")
end

local function string_list(name, value, non_empty)
  list(name, value, function(item)
    return type(item) == "string" and item ~= ""
  end, "a list of non-empty strings", non_empty)
end

local function unique_ids(images)
  local seen = {}
  for _, image in ipairs(images) do
    if seen[image.id] then
      error("duplicate image id: " .. image.id)
    end
    seen[image.id] = true
  end
end

function M.image(spec)
  vim.validate("image", spec, "table")
  local out = copy(spec)
  required_string("image.id", out.id)
  required_string("image.name", out.name)
  vim.validate("image.target", out.target, "table")
  vim.validate("image.build_target", out.build_target, "string", true)
  vim.validate("image.artifacts", out.artifacts, "table", true)
  vim.validate("image.flash", out.flash, "table", true)
  vim.validate("image.debug", out.debug, "table", true)
  return out
end

function M.configuration(spec)
  vim.validate("configuration", spec, "table")
  local out = copy(spec)
  required_string("configuration.name", out.name)
  required_string("configuration.configure_preset", out.configure_preset)
  optional_string("configuration.build_preset", out.build_preset)
  required_string("configuration.binary_dir", out.binary_dir)
  out.binary_dir = vim.fs.normalize(out.binary_dir)
  return out
end

function M.project(spec)
  vim.validate("project", spec, "table")
  local out = copy(spec)
  required_string("project.id", out.id)
  required_string("project.root", out.root)
  required_string("project.kind", out.kind)
  vim.validate("project.build", out.build, "table")
  list("project.images", out.images, function(item)
    return type(item) == "table" and type(item.id) == "string" and item.id ~= ""
  end, "a list of images", true)
  unique_ids(out.images)
  for index, image in ipairs(out.images) do
    out.images[index] = M.image(image)
  end
  out.root = vim.fs.normalize(out.root)
  out.id = vim.fs.normalize(out.id)
  out.flash_order = out.flash_order or {}
  string_list("project.flash_order", out.flash_order)
  local ids = {}
  for _, image in ipairs(out.images) do
    ids[image.id] = true
  end
  for _, id in ipairs(out.flash_order) do
    if not ids[id] then
      error("project.flash_order contains unknown image id: " .. id)
    end
  end
  out.provenance = out.provenance or {}
  vim.validate("project.provenance", out.provenance, "table")
  return out
end

function M.artifact(spec)
  vim.validate("artifact", spec, "table")
  local out = copy(spec)
  required_string("artifact.image_id", out.image_id)
  required_string("artifact.kind", out.kind)
  required_string("artifact.path", out.path)
  required_string("artifact.configuration", out.configuration)
  required_string("artifact.build_target", out.build_target)
  vim.validate("artifact.modified_ns", out.modified_ns, "number")
  out.path = vim.fs.normalize(out.path)
  out.provenance = out.provenance or {}
  vim.validate("artifact.provenance", out.provenance, "table")
  return out
end

function M.command(spec)
  vim.validate("command", spec, "table")
  local out = copy(spec)
  string_list("command.argv", out.argv, true)
  optional_string("command.cwd", out.cwd)
  vim.validate("command.env", out.env, "table", true)
  optional_string("command.image_id", out.image_id)
  optional_string("command.lifecycle", out.lifecycle)
  optional_string("command.ready_pattern", out.ready_pattern)
  vim.validate("command.timeout_ms", out.timeout_ms, "number", true)
  return out
end

function M.plan(spec)
  vim.validate("plan", spec, "table")
  local out = copy(spec)
  required_string("plan.id", out.id)
  required_string("plan.kind", out.kind)
  required_string("plan.project_id", out.project_id)
  string_list("plan.images", out.images, true)
  list("plan.commands", out.commands, function(item)
    return type(item) == "table" and type(item.argv) == "table"
  end, "a list of commands")
  for index, command in ipairs(out.commands) do
    out.commands[index] = M.command(command)
  end
  vim.validate("plan.locks", out.locks, "table")
  required_string("plan.reset_policy", out.reset_policy)
  return out
end

function M.result(spec)
  vim.validate("result", spec, "table")
  local out = copy(spec)
  vim.validate("result.ok", out.ok, "boolean")
  vim.validate("result.code", out.code, function(v)
    return (type(v) == "string" and v ~= "") or type(v) == "number"
  end, "a string or number")
  vim.validate("result.output", out.output, "string")
  vim.validate("result.artifacts", out.artifacts, "table")
  vim.validate("result.error", out.error, "table", true)
  list("result.artifacts", out.artifacts, function(item)
    return type(item) == "table"
  end, "a list of artifacts")
  for index, artifact in ipairs(out.artifacts) do
    out.artifacts[index] = M.artifact(artifact)
  end
  if out.error then
    out.error = M.error(out.error)
  end
  vim.validate("result.duration_ms", out.duration_ms, "number", true)
  vim.validate("result.started_ns", out.started_ns, "number", true)
  vim.validate("result.finished_ns", out.finished_ns, "number", true)
  return out
end

function M.error(spec)
  vim.validate("error", spec, "table")
  local out = copy(spec)
  required_string("error.code", out.code)
  required_string("error.message", out.message)
  optional_string("error.operation", out.operation)
  optional_string("error.image_id", out.image_id)
  vim.validate("error.command", out.command, "table", true)
  vim.validate("error.output", out.output, "string", true)
  required_string("error.hint", out.hint)
  return out
end

return M
