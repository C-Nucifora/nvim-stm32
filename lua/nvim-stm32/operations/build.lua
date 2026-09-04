local artifacts = require("nvim-stm32.discover.artifacts")
local file_api = require("nvim-stm32.build.file_api")
local model = require("nvim-stm32.model")
local presets = require("nvim-stm32.build.presets")
local process = require("nvim-stm32.process")
local session = require("nvim-stm32.session")
local context = require("nvim-stm32.operations.context")

local M = {}

local next_plan_id = 0

local function operation_error(code, message, plan, process_result)
  return model.error({
    code = code,
    message = "nvim-stm32: " .. message,
    operation = plan.kind,
    command = process_result and process_result.command or nil,
    output = process_result and process_result.output or nil,
    hint = "inspect the operation output and try again",
  })
end

local function failure(plan, err, process_result)
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
    metadata = { operation_id = plan.id },
  })
end

local function selected_project(plan)
  local wanted = {}
  for _, image_id in ipairs(plan.images) do
    wanted[image_id] = true
  end
  local selected = vim.deepcopy(plan.metadata.project)
  selected.images = vim.tbl_filter(function(image)
    return wanted[image.id]
  end, selected.images)
  return selected
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
    local configuration_name = plan.metadata.configuration.file_api_configuration
      or plan.metadata.configuration.name
    if #reply.configurations == 1 then
      targets = reply.configurations[1].targets or {}
    else
      targets = {}
      for _, configuration in ipairs(reply.configurations) do
        if configuration.name == configuration_name then
          targets = configuration.targets or {}
          break
        end
      end
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
  local selected = selected_project(plan)
  local configuration = metadata.configuration
  if metadata.file_api then
    local reply, reply_err = file_api.reply(configuration.binary_dir)
    if not reply then
      return nil, reply_err
    end
    return artifacts.from_cmake(
      selected,
      configuration,
      selected_reply(plan, reply),
      plan.id
    )
  end
  return artifacts.from_tree(selected, configuration, plan.id)
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

local function successful_clean_result(plan, process_result)
  local selected = {}
  for _, image_id in ipairs(plan.images) do
    selected[image_id] = true
  end
  local configuration = plan.metadata.configuration.name
  local state = session.get(plan.project_id)
  state.artifacts = vim.tbl_filter(function(artifact)
    return not (selected[artifact.image_id] and artifact.configuration == configuration)
  end, state.artifacts)
  session.select(plan.project_id, {
    artifacts = state.artifacts,
    configuration = configuration,
  })
  return model.result({
    ok = true,
    code = process_result.code,
    output = process_result.output or "",
    artifacts = {},
    duration_ms = process_result.started_ns
        and process_result.ended_ns
        and (process_result.ended_ns - process_result.started_ns) / 1000000
      or nil,
    started_ns = process_result.started_ns,
    finished_ns = process_result.ended_ns,
    metadata = { operation_id = plan.id, mode = "clean" },
  })
end

local function adapter_for(project)
  return project.build.adapter
    or project.kind
    or (project.images[1].target and project.images[1].target.build_backend)
end

local function image_targets(project, selected)
  local by_id = {}
  for _, image in ipairs(project.images) do
    by_id[image.id] = image
  end
  local targets = {}
  for _, id in ipairs(selected) do
    local image = by_id[id]
    if not image.build_target then
      return nil
    end
    targets[#targets + 1] = image.build_target
  end
  return targets
end

local function clean_command(project, adapter, configuration)
  if adapter == "cmake_presets" then
    return presets.build_command(project, configuration, { "clean" })
  end
  if adapter == "cmake_plain" then
    return model.command({
      argv = { "cmake", "--build", "build", "--target", "clean" },
      cwd = project.root,
      lifecycle = "short",
    })
  end
  return model.command({
    argv = { "make", "clean" },
    cwd = project.root,
    lifecycle = "short",
  })
end

local function build_commands(project, adapter, configuration, targets)
  if adapter == "cmake_presets" then
    return {
      presets.configure_command(project, configuration),
      presets.build_command(project, configuration, targets),
    }
  end
  if adapter == "cmake_plain" then
    local build_argv = { "cmake", "--build", "build" }
    if targets and #targets > 0 then
      build_argv[#build_argv + 1] = "--target"
      vim.list_extend(build_argv, targets)
    end
    return {
      model.command({
        argv = { "cmake", "-S", ".", "-B", "build" },
        cwd = project.root,
        lifecycle = "short",
      }),
      model.command({ argv = build_argv, cwd = project.root, lifecycle = "short" }),
    }
  end
  return {
    model.command({ argv = { "make" }, cwd = project.root, lifecycle = "short" }),
  }
end

local function commands_for(project, adapter, configuration, targets, mode)
  if mode == "clean" then
    return { clean_command(project, adapter, configuration) }
  end
  local commands = build_commands(project, adapter, configuration, targets)
  if mode == "rebuild" then
    table.insert(commands, 1, clean_command(project, adapter, configuration))
  end
  return commands
end

function M.plan(project, opts)
  opts = vim.deepcopy(opts or {})
  local mode = opts.mode or "build"
  if mode ~= "build" and mode ~= "clean" and mode ~= "rebuild" then
    return nil,
      model.error({
        code = "build-mode-invalid",
        message = "nvim-stm32: unknown build lifecycle mode " .. tostring(mode),
        operation = "build",
        hint = "use build, clean, or rebuild",
      })
  end
  local resolved, resolved_err = context.resolve(project, opts)
  if not resolved then
    return nil, resolved_err
  end
  project = resolved.project
  local configuration = resolved.configuration
  local selected = vim.tbl_map(function(image)
    return image.id
  end, resolved.images)
  local adapter = adapter_for(project)

  next_plan_id = next_plan_id + 1
  local binary_dir = vim.fs.normalize(configuration.binary_dir)
  local metadata = {
    adapter = adapter,
    configuration = vim.deepcopy(configuration),
    mode = mode,
    project = project,
  }
  if mode ~= "clean" and (adapter == "cmake_presets" or adapter == "cmake_plain") then
    metadata.query_path = binary_dir
      .. "/.cmake/api/v1/query/client-nvim-stm32/query.json"
    metadata.reply_dir = binary_dir .. "/.cmake/api/v1/reply"
    metadata.file_api = {
      query_path = metadata.query_path,
      reply_dir = metadata.reply_dir,
    }
  end

  return model.plan({
    id = "build-" .. next_plan_id,
    kind = "build",
    project_id = project.id,
    images = selected,
    commands = commands_for(
      project,
      adapter,
      configuration,
      image_targets(project, selected),
      mode
    ),
    locks = { context.artifact_lock(project) },
    reset_policy = "none",
    metadata = metadata,
  })
end

function M.validate(plan)
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

function M.preflight(plan)
  if not plan.metadata.file_api then
    return true
  end
  return file_api.write_query(plan.metadata.configuration.binary_dir)
end

function M.complete(plan, process_result)
  if not process.succeeded(process_result) then
    return failure(
      plan,
      operation_error(
        "process-failed",
        "build command did not complete successfully",
        plan,
        process_result
      ),
      process_result
    )
  end

  local result, result_err
  if plan.metadata.mode == "clean" then
    result = successful_clean_result(plan, process_result)
  else
    result, result_err = successful_result(plan, process_result)
  end
  if not result then
    return failure(plan, result_err, process_result)
  end
  session.select(plan.project_id, {
    configuration = plan.metadata.configuration.name,
  })
  if plan.metadata.mode ~= "clean" then
    session.record(plan.project_id, result)
  end
  return result
end

local function notify_error(err)
  vim.notify(err.message or tostring(err), vim.log.levels.ERROR)
end

local function current_project(opts)
  if opts.project then
    return opts.project
  end
  return require("nvim-stm32.discover.project").resolve(opts.dir)
end

function M.select_configuration(opts, callback)
  if type(opts) == "function" then
    callback, opts = opts, nil
  end
  opts = opts or {}
  local project, project_err = current_project(opts)
  if not project then
    vim.notify(project_err.message or tostring(project_err), vim.log.levels.WARN)
    return nil
  end
  local available, available_err = context.configurations(project)
  if not available then
    notify_error(available_err)
    return nil
  end
  local names = vim.tbl_map(function(configuration)
    return configuration.name
  end, available)
  if #names == 0 then
    vim.notify("nvim-stm32: no visible build configurations found", vim.log.levels.WARN)
    return nil
  end
  vim.ui.select(names, { prompt = "STM32 build configuration" }, function(choice)
    if not choice then
      return
    end
    session.select(project, { configuration = choice })
    if callback then
      callback(choice, project)
    end
  end)
end

local function run_planned(project, plan, opts, callback)
  local float = require("nvim-stm32.ui.float")
  local target = project.images[1].target or {}
  local presenter
  local handle
  presenter = float.open(target, opts, function()
    if handle then
      handle.cancel("window-closed")
    end
  end)
  local run_opts = vim.tbl_deep_extend("force", {}, opts, {
    on_output = function(chunk)
      presenter:append(chunk)
      if opts.on_output then
        opts.on_output(chunk)
      end
    end,
  })
  handle = require("nvim-stm32.operation").run(plan, run_opts, function(result)
    presenter:finish(result.ok)
    if callback then
      callback(result)
    end
  end)
  return handle
end

function M.current(opts, callback)
  if type(opts) == "function" then
    callback, opts = opts, nil
  end
  opts = vim.deepcopy(opts or {})
  local project, project_err = current_project(opts)
  if not project then
    vim.notify(project_err.message or tostring(project_err), vim.log.levels.WARN)
    return nil
  end

  local config = vim.tbl_deep_extend("force", require("nvim-stm32").get_config(), opts)
  config.configuration = opts.configuration or opts.preset or config.preset
  local plan, plan_err = M.plan(project, config)
  if not plan and plan_err.code == "configuration-required" then
    return M.select_configuration({ project = project }, function(choice)
      config.configuration = choice
      local selected_plan, selected_err = M.plan(project, config)
      if not selected_plan then
        notify_error(selected_err)
        return
      end
      run_planned(project, selected_plan, config, callback)
    end)
  end
  if not plan then
    notify_error(plan_err)
    return nil
  end
  return run_planned(project, plan, config, callback)
end

function M.run(opts, callback)
  opts = vim.deepcopy(opts or {})
  local project, project_err = current_project(opts)
  if not project then
    if callback then
      callback(nil, project_err)
    end
    return nil, project_err
  end
  local plan, plan_err = M.plan(project, opts)
  if not plan then
    if callback then
      callback(nil, plan_err)
    end
    return nil, plan_err
  end
  return require("nvim-stm32.operation").run(plan, opts, callback)
end

return M
