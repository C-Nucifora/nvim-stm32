local model = require("nvim-stm32.model")
local presets = require("nvim-stm32.build.presets")
local session = require("nvim-stm32.session")

local M = {}

local next_plan_id = 0

local function build_error(code, message, hint)
  return model.error({
    code = code,
    message = "nvim-stm32: " .. message,
    operation = "build",
    hint = hint or "check the project build configuration and try again",
  })
end

local function adapter_for(project)
  return project.build.adapter
    or project.kind
    or (project.images[1].target and project.images[1].target.build_backend)
end

local function configurations(project, adapter)
  if adapter == "cmake_presets" then
    return presets.configurations(project.root)
  end
  if adapter == "cmake_plain" then
    return {
      {
        name = "default",
        configure_preset = "default",
        binary_dir = project.root .. "/build",
      },
    }
  end
  if adapter == "make" then
    return {
      {
        name = "default",
        configure_preset = "default",
        binary_dir = project.root .. "/build",
      },
    }
  end
  return nil,
    build_error("build-backend-unknown", "unknown build backend " .. tostring(adapter))
end

local function named_configuration(available, requested)
  if type(requested) == "table" then
    requested = requested.name
  end
  if requested == nil then
    return nil
  end
  for _, configuration in ipairs(available) do
    if configuration.name == requested then
      return configuration
    end
  end
  return false
end

local function resolve_configuration(project, opts, available)
  local state = session.get(project)
  local requested = opts.configuration
  if requested == nil then
    requested = opts.preset
  end
  if requested == nil then
    requested = state.configuration
  end
  local selected = named_configuration(available, requested)
  if selected == false then
    return nil,
      build_error(
        "configuration-not-found",
        "unknown build configuration "
          .. tostring(type(requested) == "table" and requested.name or requested),
        "run :STM32SelectConfig and choose a visible configuration"
      )
  end
  if selected then
    return selected
  end
  if #available == 1 then
    return available[1]
  end
  return nil,
    build_error(
      "configuration-required",
      #available == 0 and "no visible build configurations found"
        or "a build configuration must be selected",
      "run :STM32SelectConfig and choose a visible configuration"
    )
end

local function select_images(project, opts)
  local requested = opts.images
  if not requested and opts.image_id then
    requested = { opts.image_id }
  end
  if not requested then
    local selected = session.get(project).image_id
    if selected then
      requested = { selected }
    end
  end
  if not requested then
    local all = {}
    for _, image in ipairs(project.images) do
      all[#all + 1] = image.id
    end
    return all
  end
  if type(requested) ~= "table" then
    return nil, build_error("image-selection-invalid", "images must be a list")
  end
  local known = {}
  for _, image in ipairs(project.images) do
    known[image.id] = true
  end
  local selected, seen = {}, {}
  for _, image_id in ipairs(requested) do
    if type(image_id) ~= "string" or image_id == "" or not known[image_id] then
      return nil,
        build_error("image-not-found", "unknown project image " .. tostring(image_id))
    end
    if not seen[image_id] then
      selected[#selected + 1] = image_id
      seen[image_id] = true
    end
  end
  if #selected == 0 then
    return nil, build_error("image-selection-invalid", "at least one image is required")
  end
  return selected
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

local function commands_for(project, adapter, configuration, targets)
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

function M.plan(project, opts)
  opts = vim.deepcopy(opts or {})
  local project_ok, copied_project = pcall(model.project, project)
  if not project_ok then
    return nil, build_error("project-invalid", tostring(copied_project))
  end
  project = copied_project

  local adapter = adapter_for(project)
  local available, configuration_err = configurations(project, adapter)
  if not available then
    return nil, configuration_err
  end
  local configuration, selected_err = resolve_configuration(project, opts, available)
  if not configuration then
    return nil, selected_err
  end
  local selected, image_err = select_images(project, opts)
  if not selected then
    return nil, image_err
  end

  next_plan_id = next_plan_id + 1
  local binary_dir = vim.fs.normalize(configuration.binary_dir)
  local metadata = {
    adapter = adapter,
    configuration = vim.deepcopy(configuration),
    project = project,
  }
  if adapter == "cmake_presets" or adapter == "cmake_plain" then
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
      image_targets(project, selected)
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
  local available, available_err = configurations(project, adapter_for(project))
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
