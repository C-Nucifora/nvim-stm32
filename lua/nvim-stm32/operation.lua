local artifacts = require("nvim-stm32.discover.artifacts")
local file_api = require("nvim-stm32.build.file_api")
local model = require("nvim-stm32.model")
local process = require("nvim-stm32.process")
local session = require("nvim-stm32.session")

local M = {}

local function operation_error(code, message, plan, process_result)
  return model.error({
    code = code,
    message = "nvim-stm32: " .. message,
    operation = plan and plan.kind or "operation",
    command = process_result and process_result.command or nil,
    output = process_result and process_result.output or nil,
    hint = "inspect the operation output and try again",
  })
end

local function safe_handle(id)
  return {
    id = id,
    state = function()
      return "completed"
    end,
    cancel = function()
      return false
    end,
    pid = function()
      return nil
    end,
  }
end

local function result_for_failure(plan, err, process_result)
  process_result = process_result or {}
  return model.result({
    ok = false,
    code = process_result.code or -1,
    output = process_result.output or "",
    artifacts = {},
    error = err,
    duration_ms = process_result.started_ns
        and process_result.ended_ns
        and (process_result.ended_ns - process_result.started_ns) / 1000000
      or nil,
    started_ns = process_result.started_ns,
    finished_ns = process_result.ended_ns,
    metadata = { operation_id = plan and plan.id or nil },
  })
end

local function selected_project(plan)
  local wanted = {}
  for _, image_id in ipairs(plan.images) do
    wanted[image_id] = true
  end
  local project = vim.deepcopy(plan.metadata.project)
  project.images = vim.tbl_filter(function(image)
    return wanted[image.id]
  end, project.images)
  return project
end

local function selected_reply(plan, reply)
  local target_names = {}
  for _, image in ipairs(selected_project(plan).images) do
    if image.build_target then
      target_names[image.build_target] = true
    end
  end
  local targets = reply.targets or {}
  if type(reply.configurations) == "table" then
    for _, configuration in ipairs(reply.configurations) do
      if configuration.name == plan.metadata.configuration.name then
        targets = configuration.targets or {}
        break
      end
    end
    if #reply.configurations == 1 and targets == reply.targets then
      targets = reply.configurations[1].targets or {}
    end
  end
  return {
    targets = vim.tbl_filter(function(target)
      return vim.tbl_isempty(target_names) or target_names[target.name]
    end, targets),
  }
end

local function build_artifacts(plan)
  local metadata = plan.metadata
  local project = selected_project(plan)
  local configuration = metadata.configuration
  if metadata.file_api then
    local reply, reply_err = file_api.reply(configuration.binary_dir)
    if not reply then
      return nil, reply_err
    end
    return artifacts.from_cmake(
      project,
      configuration,
      selected_reply(plan, reply),
      plan.id
    )
  end
  return artifacts.from_tree(project, configuration, plan.id)
end

local function successful_result(plan, process_result)
  local found, artifact_err = build_artifacts(plan)
  if not found then
    return nil, artifact_err
  end
  local result = model.result({
    ok = true,
    code = process_result.code,
    output = process_result.output or "",
    artifacts = found,
    duration_ms = process_result.started_ns
        and process_result.ended_ns
        and (process_result.ended_ns - process_result.started_ns) / 1000000
      or nil,
    started_ns = process_result.started_ns,
    finished_ns = process_result.ended_ns,
    metadata = { operation_id = plan.id },
  })
  local elves = artifacts.for_image(result.artifacts, plan.images[1], "elf")
  if #plan.images == 1 and #elves == 1 then
    result.elf = elves[1].path
  end
  return model.result(result)
end

local function validate_build_plan(plan)
  if type(plan.metadata) ~= "table" then
    error("plan.metadata: expected table")
  end
  if type(plan.metadata.project) ~= "table" then
    error("plan.metadata.project: expected table")
  end
  plan.metadata.project = model.project(plan.metadata.project)
  if type(plan.metadata.configuration) ~= "table" then
    error("plan.metadata.configuration: expected table")
  end
  plan.metadata.configuration = model.configuration(plan.metadata.configuration)
  if plan.metadata.file_api ~= nil then
    vim.validate("plan.metadata.file_api", plan.metadata.file_api, "table")
    vim.validate(
      "plan.metadata.file_api.query_path",
      plan.metadata.file_api.query_path,
      "string"
    )
    vim.validate(
      "plan.metadata.file_api.reply_dir",
      plan.metadata.file_api.reply_dir,
      "string"
    )
  end
end

local function unavailable_tool(plan)
  local checked = {}
  for _, command in ipairs(plan.commands) do
    local executable = command.argv[1]
    if not checked[executable] then
      checked[executable] = true
      if vim.fn.executable(executable) ~= 1 then
        return operation_error(
          "build-tool-unavailable",
          "required build tool not found: " .. executable,
          plan
        )
      end
    end
  end
end

function M.run(plan, opts, callback)
  opts = opts or {}
  callback = callback or function() end
  local completed = false
  local function complete(result)
    if completed then
      return
    end
    completed = true
    callback(vim.deepcopy(result))
  end

  local valid, copied_or_err = pcall(model.plan, plan)
  if valid and copied_or_err.kind == "build" then
    valid, copied_or_err = pcall(function()
      validate_build_plan(copied_or_err)
      return copied_or_err
    end)
  elseif valid then
    valid = false
    copied_or_err = "unsupported operation kind " .. copied_or_err.kind
  end
  if not valid then
    local err = operation_error("operation-plan-invalid", tostring(copied_or_err))
    complete(result_for_failure(nil, err))
    return safe_handle(nil)
  end
  local copied = copied_or_err

  local tool_err = unavailable_tool(copied)
  if tool_err then
    complete(result_for_failure(copied, tool_err))
    return safe_handle(copied.id)
  end

  if copied.metadata.file_api then
    local query, query_err =
      file_api.write_query(copied.metadata.configuration.binary_dir)
    if not query then
      complete(result_for_failure(copied, query_err))
      return safe_handle(copied.id)
    end
  end

  local cfg = vim.tbl_deep_extend(
    "force",
    vim.deepcopy(require("nvim-stm32").get_config()),
    vim.deepcopy(opts)
  )
  local process_opts = {
    cwd = copied.metadata.project.root,
    env = vim.tbl_extend("force", {}, opts.env or {}),
    toolchain_path = cfg.toolchain_path,
    on_output = opts.on_output,
    max_output_bytes = opts.max_output_bytes,
    timeout_ms = opts.timeout_ms,
  }
  local started, handle_or_err = pcall(
    process.run,
    copied.commands,
    process_opts,
    function(process_result)
      if completed then
        return
      end
      if process_result.code ~= 0 then
        local err = operation_error(
          "process-failed",
          "build command failed with exit code " .. tostring(process_result.code),
          copied,
          process_result
        )
        complete(result_for_failure(copied, err, process_result))
        return
      end

      local result, result_err = successful_result(copied, process_result)
      if not result then
        complete(result_for_failure(copied, result_err, process_result))
        return
      end
      session.select(copied.project_id, {
        configuration = copied.metadata.configuration.name,
      })
      session.record(copied.project_id, result)
      complete(result)
    end
  )
  if not started then
    local err = operation_error("process-start-failed", tostring(handle_or_err), copied)
    complete(result_for_failure(copied, err))
    return safe_handle(copied.id)
  end
  return handle_or_err or safe_handle(copied.id)
end

return M
