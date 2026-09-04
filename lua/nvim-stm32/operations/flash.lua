local context = require("nvim-stm32.operations.context")
local driver_registry = require("nvim-stm32.drivers.flash")
local layout = require("nvim-stm32.flash.layout")
local model = require("nvim-stm32.model")
local session = require("nvim-stm32.session")

local M = {}

local next_plan_id = 0

local function flash_error(code, message, action, image_id)
  return model.error({
    code = code,
    message = "nvim-stm32: " .. message,
    operation = action or "flash",
    image_id = image_id,
    hint = "check the selected backend, probe, target, and build inputs",
  })
end

local function project_images(project, opts)
  local ok, copied = pcall(model.project, project)
  if not ok then
    return nil, flash_error("project-invalid", tostring(copied))
  end
  local images, images_err = context.resolve_images(copied, opts)
  if not images then
    return nil, images_err
  end
  return { project = copied, images = images }
end

local function same_ids(left, right)
  if #left ~= #right then
    return false
  end
  local found = {}
  for _, id in ipairs(left) do
    found[id] = true
  end
  for _, id in ipairs(right) do
    if not found[id] then
      return false
    end
  end
  return true
end

local function expected_target(images, action)
  local expected
  for _, image in ipairs(images) do
    local target = vim.deepcopy(image.target or {})
    local target_facts = require("nvim-stm32.targets").resolve(target.mcu) or {}
    target.debug_ids = target.debug_ids or target_facts.debug_ids
    target.debug_idcode_address = target.debug_idcode_address
      or target_facts.debug_idcode_address
    if type(target.debug_ids) ~= "table" or #target.debug_ids == 0 then
      return nil,
        flash_error(
          "target-identity-unsupported",
          "target " .. tostring(target.mcu or image.id) .. " has no observed device IDs",
          action,
          image.id
        )
    end
    local ids = {}
    for _, id in ipairs(target.debug_ids) do
      if type(id) ~= "number" or id <= 0 or id > 0xFFF or id % 1 ~= 0 then
        return nil,
          flash_error(
            "target-identity-invalid",
            "target " .. image.id .. " has an invalid observed device ID",
            action,
            image.id
          )
      end
      ids[#ids + 1] = id
    end
    if expected and not same_ids(expected.debug_ids, ids) then
      return nil,
        flash_error(
          "target-identity-ambiguous",
          "selected images do not share one expected target identity",
          action
        )
    end
    expected = expected or vim.deepcopy(target)
    expected.debug_ids = vim.deepcopy(ids)
  end
  return expected
end

local function selected_probe(project, driver, target, opts, action)
  local probe
  if opts.probe ~= nil then
    local ok, copied = pcall(model.probe, opts.probe)
    if not ok then
      return nil, flash_error("probe-invalid", tostring(copied), action)
    end
    probe = copied
  else
    local serial = opts.probe_serial
    if serial == nil then
      serial = session.get(project).probe_serial
    end
    if type(serial) ~= "string" or serial == "" then
      return nil,
        flash_error(
          "probe-selection-required",
          "a probe serial must be selected before planning " .. action,
          action
        )
    end
    probe = model.probe({ backend = driver.id, serial = serial })
  end
  probe.target = vim.deepcopy(target)
  return probe
end

local function command(driver, method, tool, request, action)
  local ok, value = pcall(driver[method], tool, request)
  if not ok then
    return nil,
      flash_error(
        "flash-command-invalid",
        "could not construct " .. action .. " command: " .. tostring(value),
        action
      )
  end
  return value
end

local function append(commands, steps, value, step)
  commands[#commands + 1] = value
  steps[#steps + 1] = step
end

function M.plan(action, project, opts)
  opts = vim.deepcopy(opts or {})
  if action ~= "flash" and action ~= "erase" and action ~= "reset" then
    return nil,
      flash_error(
        "flash-action-invalid",
        "unknown hardware action " .. tostring(action),
        tostring(action)
      )
  end
  if action == "erase" and opts.confirmed ~= true and opts.preview ~= true then
    return nil,
      flash_error(
        "erase-confirmation-required",
        "mass erase requires explicit confirmation",
        action
      )
  end

  local resolved, resolved_err
  if action == "flash" then
    resolved, resolved_err = context.resolve(project, opts)
  else
    resolved, resolved_err = project_images(project, opts)
  end
  if not resolved then
    return nil, resolved_err
  end

  local driver, tools_or_err = driver_registry.resolve(opts, opts)
  if not driver then
    return nil, tools_or_err
  end
  local tools = tools_or_err
  if
    type(driver.identify_command) ~= "function"
    or type(driver.parse_identity) ~= "function"
    or type(driver.reset_command) ~= "function"
    or type(driver.erase_command) ~= "function"
    or type(driver.program_command) ~= "function"
  then
    return nil,
      flash_error(
        "flash-backend-invalid",
        "flash backend " .. tostring(driver.id) .. " has an incomplete driver contract",
        action
      )
  end

  local target, target_err = expected_target(resolved.images, action)
  if not target then
    return nil, target_err
  end
  local probe, probe_err =
    selected_probe(resolved.project, driver, target, opts, action)
  if not probe then
    return nil, probe_err
  end

  local artifacts = opts.artifacts
  local build_id = opts.build_id
  if action == "flash" and artifacts == nil then
    local state = session.get(resolved.project)
    artifacts = state.artifacts
    build_id = build_id
      or state.last_result
        and state.last_result.metadata
        and state.last_result.metadata.operation_id
  end
  if action == "flash" and (type(artifacts) ~= "table" or #artifacts == 0) then
    return nil,
      flash_error(
        "flash-artifact-missing",
        "the selected successful build has no flash artifacts",
        action
      )
  end
  if action == "flash" and (type(build_id) ~= "string" or build_id == "") then
    return nil,
      flash_error(
        "flash-build-stale",
        "flash artifacts are not tied to the selected successful build",
        action
      )
  end
  local resolved_layout = {}
  if action == "flash" then
    local layout_context = vim.deepcopy(resolved)
    layout_context.build_id = build_id
    resolved_layout, resolved_err =
      layout.resolve(layout_context, artifacts or {}, driver)
    if not resolved_layout then
      return nil, resolved_err
    end
  end

  local commands, steps = {}, {}
  local identify, identify_err =
    command(driver, "identify_command", tools.identify, probe, action)
  if not identify then
    return nil, identify_err
  end
  append(commands, steps, identify, { phase = "identify", image_id = nil })

  if action == "flash" then
    for _, item in ipairs(resolved_layout) do
      local program, program_err = command(driver, "program_command", tools.program, {
        probe = probe,
        artifact = item.artifact,
        address = item.address,
      }, action)
      if not program then
        return nil, program_err
      end
      program.image_id = item.image_id
      append(commands, steps, program, {
        phase = "program-verify",
        image_id = item.image_id,
        artifact = vim.deepcopy(item.artifact),
      })
    end
    local reset, reset_err =
      command(driver, "reset_command", tools.program, probe, action)
    if not reset then
      return nil, reset_err
    end
    append(commands, steps, reset, { phase = "reset", image_id = nil })
  elseif action == "erase" then
    local erase, erase_err =
      command(driver, "erase_command", tools.program, probe, action)
    if not erase then
      return nil, erase_err
    end
    append(commands, steps, erase, { phase = "erase", image_id = nil })
  else
    local reset, reset_err =
      command(driver, "reset_command", tools.program, probe, action)
    if not reset then
      return nil, reset_err
    end
    append(commands, steps, reset, { phase = "reset", image_id = nil })
  end

  next_plan_id = next_plan_id + 1
  local image_ids = action == "flash"
      and vim.tbl_map(function(item)
        return item.image_id
      end, resolved_layout)
    or vim.tbl_map(function(image)
      return image.id
    end, resolved.images)
  return model.plan({
    id = action .. "-" .. next_plan_id,
    kind = action,
    project_id = resolved.project.id,
    images = image_ids,
    commands = commands,
    locks = { { kind = "probe", id = driver.id .. ":" .. probe.serial } },
    reset_policy = action == "flash" and "once-after-verify"
      or action == "reset" and "once"
      or "none",
    metadata = {
      backend = driver.id,
      tools = vim.deepcopy(tools),
      probe = vim.deepcopy(probe),
      target = vim.deepcopy(target),
      project = vim.deepcopy(resolved.project),
      configuration = resolved.configuration and vim.deepcopy(resolved.configuration)
        or nil,
      build_id = build_id,
      layout = vim.deepcopy(resolved_layout),
      steps = steps,
      confirmed = opts.confirmed == true,
      preview = opts.preview == true,
      allow_target_mismatch = opts.allow_target_mismatch == true,
    },
  })
end

local function decorated_error(err, plan, step, command_result)
  local value = vim.deepcopy(err)
  value.operation = plan.kind
  value.backend = plan.metadata.backend
  value.phase = step and step.phase or nil
  value.image_id = step and step.image_id or value.image_id
  value.command = command_result and vim.deepcopy(command_result.argv) or value.command
  value.output = command_result and command_result.output or value.output
  return model.error(value)
end

local function command_error(plan, process_result)
  local index = process_result.command_index
  local step = index and plan.metadata.steps[index] or nil
  local record = index and process_result.commands and process_result.commands[index]
    or nil
  return model.error({
    code = "flash-command-failed",
    message = "nvim-stm32: "
      .. tostring(step and step.phase or plan.kind)
      .. " command failed with exit code "
      .. tostring(process_result.code),
    operation = plan.kind,
    backend = plan.metadata.backend,
    phase = step and step.phase or nil,
    image_id = step and step.image_id or nil,
    command = process_result.command,
    output = record and record.output or process_result.output,
    hint = "inspect the captured command output and correct the hardware failure",
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
    metadata = {
      operation_id = plan and plan.id or nil,
      backend = plan and plan.metadata and plan.metadata.backend or nil,
    },
  })
end

local function selected_images(project, image_ids)
  local wanted = {}
  for _, image_id in ipairs(image_ids) do
    wanted[image_id] = true
  end
  return vim.tbl_filter(function(image)
    return wanted[image.id]
  end, project.images)
end

local function expected_commands(plan, driver)
  local commands = {}
  commands[#commands + 1] =
    driver.identify_command(plan.metadata.tools.identify, plan.metadata.probe)
  if plan.kind == "flash" then
    for _, item in ipairs(plan.metadata.layout) do
      local value = driver.program_command(plan.metadata.tools.program, {
        probe = plan.metadata.probe,
        artifact = item.artifact,
        address = item.address,
      })
      value.image_id = item.image_id
      commands[#commands + 1] = value
    end
    commands[#commands + 1] =
      driver.reset_command(plan.metadata.tools.program, plan.metadata.probe)
  elseif plan.kind == "erase" then
    commands[#commands + 1] =
      driver.erase_command(plan.metadata.tools.program, plan.metadata.probe)
  else
    commands[#commands + 1] =
      driver.reset_command(plan.metadata.tools.program, plan.metadata.probe)
  end
  return commands
end

local function expected_steps(plan)
  local steps = { { phase = "identify", image_id = nil } }
  if plan.kind == "flash" then
    for _, item in ipairs(plan.metadata.layout) do
      steps[#steps + 1] = {
        phase = "program-verify",
        image_id = item.image_id,
        artifact = vim.deepcopy(item.artifact),
      }
    end
    steps[#steps + 1] = { phase = "reset", image_id = nil }
  elseif plan.kind == "erase" then
    steps[#steps + 1] = { phase = "erase", image_id = nil }
  else
    steps[#steps + 1] = { phase = "reset", image_id = nil }
  end
  return steps
end

function M.validate(plan)
  if type(plan.metadata) ~= "table" then
    error("plan.metadata: expected table")
  end
  if type(plan.metadata.backend) ~= "string" then
    error("plan.metadata.backend: expected string")
  end
  if type(plan.metadata.tools) ~= "table" then
    error("plan.metadata.tools: expected table")
  end
  if type(plan.metadata.steps) ~= "table" or #plan.metadata.steps ~= #plan.commands then
    error("plan.metadata.steps: expected one step per command")
  end
  if type(plan.metadata.layout) ~= "table" then
    error("plan.metadata.layout: expected table")
  end
  plan.metadata.project = model.project(plan.metadata.project)
  plan.metadata.probe = model.probe(plan.metadata.probe)
  if plan.metadata.configuration then
    plan.metadata.configuration = model.configuration(plan.metadata.configuration)
  end
end

function M.preflight(plan)
  if
    plan.kind == "erase" and (plan.metadata.preview or not plan.metadata.confirmed)
  then
    return nil,
      flash_error(
        "erase-confirmation-required",
        "mass erase requires explicit confirmation immediately before execution",
        "erase"
      )
  end
  local driver = driver_registry.backends[plan.metadata.backend]
  if not driver then
    return nil,
      flash_error(
        "flash-backend-unknown",
        "planned backend is no longer registered: " .. plan.metadata.backend,
        plan.kind
      )
  end

  local images = selected_images(plan.metadata.project, plan.images)
  if #images ~= #plan.images then
    return nil,
      flash_error(
        "flash-plan-tampered",
        "planned images do not match the selected project",
        plan.kind
      )
  end
  local target, target_err = expected_target(images, plan.kind)
  if not target then
    return nil, target_err
  end
  if
    not vim.deep_equal(target, plan.metadata.target)
    or not vim.deep_equal(target, plan.metadata.probe.target)
  then
    return nil,
      flash_error(
        "flash-plan-tampered",
        "planned target identity no longer matches the selected project",
        plan.kind
      )
  end
  if
    #plan.locks ~= 1
    or plan.locks[1].kind ~= "probe"
    or plan.locks[1].id ~= plan.metadata.backend .. ":" .. plan.metadata.probe.serial
  then
    return nil,
      flash_error(
        "flash-plan-tampered",
        "planned probe lock does not match the pinned backend and serial",
        plan.kind
      )
  end

  local ok, rebuilt = pcall(expected_commands, plan, driver)
  if
    not ok
    or not vim.deep_equal(rebuilt, plan.commands)
    or not vim.deep_equal(expected_steps(plan), plan.metadata.steps)
  then
    return nil,
      flash_error(
        "flash-plan-tampered",
        "planned commands do not match the pinned backend inputs",
        plan.kind
      )
  end

  if plan.kind == "flash" then
    local fresh_context, context_err = context.resolve(plan.metadata.project, {
      configuration = plan.metadata.configuration.name,
      images = plan.images,
    })
    if not fresh_context then
      return nil, context_err
    end
    if not vim.deep_equal(fresh_context.configuration, plan.metadata.configuration) then
      return nil,
        flash_error(
          "flash-plan-tampered",
          "planned configuration no longer matches the selected project",
          plan.kind
        )
    end
    local checked, checked_err = layout.resolve(
      {
        project = plan.metadata.project,
        images = fresh_context.images,
        configuration = plan.metadata.configuration,
        build_id = plan.metadata.build_id,
      },
      vim.tbl_map(function(item)
        return item.artifact
      end, plan.metadata.layout),
      driver
    )
    if not checked then
      return nil, checked_err
    end
    if not vim.deep_equal(checked, plan.metadata.layout) then
      return nil,
        flash_error(
          "flash-layout-changed",
          "flash artifacts or memory layout changed after planning",
          plan.kind
        )
    end
  end
  return true
end

local function parse_identity(driver, plan, output)
  if plan.metadata.backend == "stlink" then
    return driver.parse_identity(output, plan.metadata.probe)
  end
  return driver.parse_identity(output, plan.metadata.target)
end

local function accepted_identity(target, observed)
  for _, expected in ipairs(target.debug_ids) do
    if observed.device_id == expected then
      return true
    end
  end
  return false
end

function M.after_command(plan, command_result, command_index)
  local step = plan.metadata.steps[command_index]
  if not step then
    return nil,
      flash_error(
        "flash-step-missing",
        "no phase metadata exists for command " .. tostring(command_index),
        plan.kind
      )
  end
  local driver = driver_registry.backends[plan.metadata.backend]
  if step.phase == "identify" then
    local ok, identity, identity_err =
      pcall(parse_identity, driver, plan, command_result.output)
    if not ok then
      identity_err =
        flash_error("target-identity-invalid", tostring(identity), plan.kind)
      identity = nil
    end
    if not identity then
      return nil, decorated_error(identity_err, plan, step, command_result)
    end
    if
      not accepted_identity(plan.metadata.target, identity)
      and not plan.metadata.allow_target_mismatch
    then
      return nil,
        decorated_error(
          flash_error(
            "target-mismatch",
            string.format(
              "connected target device ID 0x%03X does not match the selected project",
              identity.device_id
            ),
            plan.kind
          ),
          plan,
          step,
          command_result
        )
    end
  elseif
    step.phase == "program-verify" and type(driver.parse_program) == "function"
  then
    local verified, verify_err = driver.parse_program(command_result.output)
    if not verified then
      return nil, decorated_error(verify_err, plan, step, command_result)
    end
  end
  return true
end

function M.complete(plan, process_result)
  if process_result.code ~= 0 then
    return failure(plan, command_error(plan, process_result), process_result)
  end
  local result_artifacts = {}
  for _, item in ipairs(plan.metadata.layout) do
    result_artifacts[#result_artifacts + 1] = item.artifact
  end
  return model.result({
    ok = true,
    code = process_result.code,
    output = process_result.output or "",
    artifacts = result_artifacts,
    duration_ms = process_result.started_ns
        and process_result.ended_ns
        and (process_result.ended_ns - process_result.started_ns) / 1000000
      or nil,
    started_ns = process_result.started_ns,
    finished_ns = process_result.ended_ns,
    metadata = { operation_id = plan.id, backend = plan.metadata.backend },
  })
end

local function hooks()
  local command_index = 0
  return {
    validate = M.validate,
    preflight = M.preflight,
    after_command = function(plan, command_result)
      command_index = command_index + 1
      return M.after_command(plan, command_result, command_index)
    end,
    complete = M.complete,
  }
end

function M.execute(plan, opts, callback)
  return require("nvim-stm32.operation").execute(plan, opts, hooks(), callback)
end

local function immediate_failure(action, err)
  return model.result({
    ok = false,
    code = -1,
    output = "",
    artifacts = {},
    error = err,
    metadata = { operation_id = action },
  })
end

local function done_handle(state)
  return {
    state = function()
      return state or "completed"
    end,
    cancel = function()
      return false
    end,
    pid = function()
      return nil
    end,
  }
end

function M.current(action, opts, callback)
  local invocation_opts = vim.deepcopy(opts or {})
  local allow_target_mismatch = invocation_opts.allow_target_mismatch == true
  opts = vim.tbl_deep_extend(
    "force",
    vim.deepcopy(require("nvim-stm32").get_config()),
    invocation_opts
  )
  opts.allow_target_mismatch = allow_target_mismatch
  callback = callback or function() end
  local project = opts.project
  if not project then
    local project_err
    project, project_err = require("nvim-stm32.discover.project").resolve(opts.dir)
    if not project then
      callback(immediate_failure(action, project_err))
      return done_handle()
    end
  end

  local active
  local stage = "pending"
  local cancelled = false
  local finished = false
  local composite = {}

  local function finish(result)
    if finished or cancelled then
      return
    end
    finished = true
    stage = "completed"
    active = nil
    callback(result)
  end

  local function run_hardware(artifacts, build_id)
    if cancelled then
      return
    end
    local plan_opts = vim.deepcopy(opts)
    plan_opts.project = nil
    if artifacts then
      plan_opts.artifacts = artifacts
      plan_opts.build_id = build_id
    end
    local plan, plan_err = M.plan(action, project, plan_opts)
    if not plan then
      finish(immediate_failure(action, plan_err))
      return
    end
    stage = "hardware"
    local child = require("nvim-stm32.operation").execute(plan, opts, hooks(), finish)
    if stage == "hardware" and not finished and not cancelled then
      active = child
    end
  end

  if action == "flash" and opts.build ~= false then
    stage = "build"
    local build_opts = vim.deepcopy(opts)
    build_opts.project = project
    build_opts.build = nil
    build_opts.artifacts = nil
    build_opts.build_id = nil
    local child = require("nvim-stm32.operations.build").run(
      build_opts,
      function(result, err)
        if cancelled then
          return
        end
        if not result or not result.ok then
          finish(result or immediate_failure("build", err))
          return
        end
        local build_id = result.metadata and result.metadata.operation_id
        run_hardware(result.artifacts, build_id)
      end
    )
    if stage == "build" and not finished and not cancelled then
      active = child
    end
  else
    run_hardware()
  end

  function composite.state()
    if cancelled then
      return "cancelled"
    end
    if finished then
      return "completed"
    end
    return active and active.state and active.state() or stage
  end

  function composite.cancel(reason)
    if cancelled or finished then
      return false
    end
    cancelled = true
    stage = "cancelled"
    if active and active.cancel then
      active.cancel(reason)
    end
    return true
  end

  function composite.pid()
    return active and active.pid and active.pid() or nil
  end

  return composite
end

return M
