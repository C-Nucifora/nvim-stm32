local model = require("nvim-stm32.model")
local presets = require("nvim-stm32.build.presets")
local session = require("nvim-stm32.session")
local context = require("nvim-stm32.operations.context")

local M = {}

local next_plan_id = 0

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
    locks = {},
    reset_policy = "none",
    metadata = metadata,
  })
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
