local model = require("nvim-stm32.model")
local context = require("nvim-stm32.operations.context")
local objdump = require("nvim-stm32.inspect.objdump")
local process = require("nvim-stm32.process")
local session = require("nvim-stm32.session")
local size = require("nvim-stm32.inspect.size")
local tools = require("nvim-stm32.tools")

local M = {}

local next_plan_id = 0

local function modified_ns(stat)
  local mtime = stat.mtime or {}
  return (mtime.sec or 0) * 1000000000 + (mtime.nsec or 0)
end

local function within(root, path)
  return path == root or path:sub(1, #root + 1) == root .. "/"
end

local function analysis_error(code, message, image_id, output)
  return model.error({
    code = code,
    message = "nvim-stm32: " .. message,
    operation = "analyze",
    image_id = image_id,
    output = output,
    hint = "build the selected configuration, then run analysis again",
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
    metadata = { operation_id = plan and plan.id or nil },
  })
end

local function stem(path)
  return vim.fn.fnamemodify(vim.fn.fnamemodify(path, ":t"), ":r")
end

local function checked_artifact(state, image, configuration, artifact)
  local build_id = state.last_result
    and state.last_result.metadata
    and state.last_result.metadata.operation_id
  if state.configuration ~= configuration.name then
    return nil,
      analysis_error(
        "analysis-configuration-changed",
        "selected configuration is not the recorded artifact configuration",
        image.id
      )
  end
  if artifact.build_id ~= build_id then
    return nil,
      analysis_error(
        "analysis-build-changed",
        "ELF artifact is not tied to the last successful build",
        image.id
      )
  end
  local binary_real = vim.uv.fs_realpath(configuration.binary_dir)
  local real = vim.uv.fs_realpath(artifact.path)
  if
    not binary_real
    or not real
    or not within(vim.fs.normalize(binary_real), vim.fs.normalize(real))
  then
    return nil,
      analysis_error(
        "analysis-artifact-outside-build",
        "ELF artifact is outside the selected binary directory: " .. artifact.path,
        image.id
      )
  end
  local stat = vim.uv.fs_stat(real)
  if not stat or stat.type ~= "file" then
    return nil,
      analysis_error(
        "analysis-elf-missing",
        "ELF artifact no longer exists: " .. artifact.path,
        image.id
      )
  end
  if
    type(artifact.size) ~= "number"
    or artifact.size ~= stat.size
    or artifact.modified_ns ~= modified_ns(stat)
  then
    return nil,
      analysis_error(
        "analysis-artifact-changed",
        "ELF artifact changed after its successful build: " .. artifact.path,
        image.id
      )
  end
  return {
    artifact = vim.deepcopy(artifact),
    binary_real = vim.fs.normalize(binary_real),
    real_path = vim.fs.normalize(real),
    size = stat.size,
    modified_ns = modified_ns(stat),
    build_id = build_id,
  }
end

local function artifacts_for(state, image, configuration)
  local elves = {}
  for _, artifact in ipairs(state.artifacts or {}) do
    if
      artifact.image_id == image.id
      and artifact.configuration == configuration.name
      and artifact.kind == "elf"
    then
      elves[#elves + 1] = artifact
    end
  end
  if #elves == 0 then
    return nil,
      analysis_error(
        "analysis-elf-missing",
        "no ELF artifact for " .. image.id .. " in " .. configuration.name,
        image.id
      )
  end
  if #elves > 1 then
    return nil,
      analysis_error(
        "analysis-elf-ambiguous",
        "more than one ELF artifact for " .. image.id .. " in " .. configuration.name,
        image.id
      )
  end
  local elf = elves[1]
  if type(elf.build_id) ~= "string" or elf.build_id == "" then
    return nil,
      analysis_error(
        "analysis-build-stale",
        "ELF artifact has no successful build id: " .. elf.path,
        image.id
      )
  end
  local snapshot, snapshot_err = checked_artifact(state, image, configuration, elf)
  if not snapshot then
    return nil, snapshot_err
  end

  local matching_maps = {}
  for _, artifact in ipairs(state.artifacts or {}) do
    if
      artifact.image_id == image.id
      and artifact.configuration == configuration.name
      and artifact.kind == "map"
      and artifact.build_id == elf.build_id
      and stem(artifact.path) == stem(elf.path)
    then
      matching_maps[#matching_maps + 1] = artifact
    end
  end
  return snapshot, #matching_maps == 1 and matching_maps[1] or nil
end

local function linker_path(image)
  local matches = {}
  for _, signal in ipairs(image.target.signals or {}) do
    if signal.source == "linker" and type(signal.file) == "string" then
      matches[#matches + 1] = signal.file
    end
  end
  if #matches == 1 then
    return matches[1]
  end
  if #matches == 0 then
    return nil,
      analysis_error(
        "analysis-linker-missing",
        "no linker signal for image " .. image.id,
        image.id
      )
  end
  return nil,
    analysis_error(
      "analysis-linker-ambiguous",
      "more than one linker signal for image " .. image.id,
      image.id
    )
end

function M.plan(project, opts)
  opts = vim.deepcopy(opts or {})
  local resolved, resolved_err = context.resolve(project, opts)
  if not resolved then
    return nil, resolved_err
  end
  local state = session.get(resolved.project)
  local inputs = {}
  for _, image in ipairs(resolved.images) do
    local snapshot, map_or_err = artifacts_for(state, image, resolved.configuration)
    if not snapshot then
      return nil, map_or_err
    end
    local path, path_err = linker_path(image)
    if not path then
      return nil, path_err
    end
    inputs[#inputs + 1] = {
      image_id = image.id,
      elf = vim.deepcopy(snapshot.artifact),
      map = vim.deepcopy(map_or_err),
      linker_path = vim.fs.normalize(path),
      binary_real = snapshot.binary_real,
      real_path = snapshot.real_path,
      size = snapshot.size,
      modified_ns = snapshot.modified_ns,
      build_id = snapshot.build_id,
    }
  end

  local size_path = tools.size(opts)
  if not size_path then
    return nil,
      analysis_error(
        "analysis-tool-unavailable",
        "required analysis tool not found: arm-none-eabi-size"
      )
  end
  local objdump_path = tools.objdump(opts)
  if not objdump_path then
    return nil,
      analysis_error(
        "analysis-tool-unavailable",
        "required analysis tool not found: arm-none-eabi-objdump"
      )
  end

  local commands = {}
  for _, input in ipairs(inputs) do
    commands[#commands + 1] = model.command({
      argv = { size_path, "-B", "-x", input.elf.path },
      cwd = resolved.project.root,
      image_id = input.image_id,
      lifecycle = "short",
    })
    commands[#commands + 1] = model.command({
      argv = { objdump_path, "-h", input.elf.path },
      cwd = resolved.project.root,
      image_id = input.image_id,
      lifecycle = "short",
    })
  end

  next_plan_id = next_plan_id + 1
  return model.plan({
    id = "analyze-" .. next_plan_id,
    kind = "analyze",
    project_id = resolved.project.id,
    images = vim.tbl_map(function(image)
      return image.id
    end, resolved.images),
    commands = commands,
    locks = { context.artifact_lock(resolved.project) },
    reset_policy = "none",
    metadata = {
      configuration = resolved.configuration,
      inputs = inputs,
      project = resolved.project,
    },
  })
end

function M.preflight(plan)
  local fresh_context, context_err = context.resolve(plan.metadata.project, {
    configuration = plan.metadata.configuration.name,
    images = plan.images,
  })
  if not fresh_context then
    return nil, context_err
  end
  if not vim.deep_equal(fresh_context.configuration, plan.metadata.configuration) then
    return nil,
      analysis_error(
        "analysis-configuration-changed",
        "selected configuration changed after analysis planning"
      )
  end

  local state = session.get(plan.project_id)
  if state.configuration ~= plan.metadata.configuration.name then
    return nil,
      analysis_error(
        "analysis-configuration-changed",
        "selected configuration changed after analysis planning"
      )
  end
  local build_id = state.last_result
    and state.last_result.metadata
    and state.last_result.metadata.operation_id
  for _, input in ipairs(plan.metadata.inputs) do
    if build_id ~= input.build_id then
      return nil,
        analysis_error(
          "analysis-build-changed",
          "successful build changed after analysis planning",
          input.image_id
        )
    end
    local recorded
    for _, artifact in ipairs(state.artifacts or {}) do
      if
        artifact.image_id == input.image_id
        and artifact.kind == "elf"
        and artifact.configuration == plan.metadata.configuration.name
        and artifact.build_id == input.build_id
        and artifact.path == input.elf.path
      then
        recorded = artifact
        break
      end
    end
    if not recorded then
      return nil,
        analysis_error(
          "analysis-build-changed",
          "recorded ELF changed after analysis planning",
          input.image_id
        )
    end
    local checked, checked_err = checked_artifact(
      state,
      { id = input.image_id },
      plan.metadata.configuration,
      recorded
    )
    if not checked then
      return nil, checked_err
    end
    if
      checked.binary_real ~= input.binary_real
      or checked.real_path ~= input.real_path
      or checked.size ~= input.size
      or checked.modified_ns ~= input.modified_ns
      or not vim.deep_equal(checked.artifact, input.elf)
    then
      return nil,
        analysis_error(
          "analysis-artifact-changed",
          "ELF artifact identity changed after analysis planning: " .. input.elf.path,
          input.image_id
        )
    end
  end
  return true
end

local function read(path)
  local file = io.open(path, "r")
  if not file then
    return nil
  end
  local text = file:read("*a")
  file:close()
  return text
end

function M.complete(plan, process_result)
  if not process.succeeded(process_result) then
    return failure(
      plan,
      analysis_error(
        "process-failed",
        "analysis command did not complete successfully",
        nil,
        process_result.output
      ),
      process_result
    )
  end
  local command_results = process_result.commands or {}
  if #command_results ~= #plan.commands then
    return failure(
      plan,
      analysis_error("analysis-output-missing", "analysis command output is incomplete"),
      process_result
    )
  end

  local analyses, result_artifacts = {}, {}
  for index, input in ipairs(plan.metadata.inputs) do
    local linker_text = read(input.linker_path)
    if not linker_text then
      return failure(
        plan,
        analysis_error(
          "analysis-linker-read",
          "could not read linker script: " .. input.linker_path,
          input.image_id
        ),
        process_result
      )
    end
    local regions, regions_err = require("nvim-stm32.inspect.linker").parse(linker_text)
    if not regions then
      return failure(plan, regions_err, process_result)
    end
    local summary, summary_err = size.parse(command_results[index * 2 - 1].output)
    if not summary then
      return failure(plan, summary_err, process_result)
    end
    local sections, sections_err =
      objdump.parse_sections(command_results[index * 2].output)
    if not sections then
      return failure(plan, sections_err, process_result)
    end
    local report, report_err = objdump.report(sections, regions)
    if not report then
      return failure(plan, report_err, process_result)
    end
    analyses[#analyses + 1] = {
      image_id = input.image_id,
      elf = vim.deepcopy(input.elf),
      map = vim.deepcopy(input.map),
      linker_path = input.linker_path,
      size = summary,
      report = report,
    }
    result_artifacts[#result_artifacts + 1] = input.elf
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
    metadata = { operation_id = plan.id, analysis = analyses },
  })
end

local function current_project(opts)
  if opts.project then
    return opts.project
  end
  return require("nvim-stm32.discover.project").resolve(opts.dir)
end

function M.current(opts, callback)
  opts = vim.deepcopy(opts or {})
  local project, project_err = current_project(opts)
  if not project then
    vim.notify(project_err.message or tostring(project_err), vim.log.levels.WARN)
    return nil
  end
  local cfg = vim.tbl_deep_extend("force", require("nvim-stm32").get_config(), opts)
  cfg.configuration = opts.configuration or opts.preset or cfg.preset
  local plan, plan_err = M.plan(project, cfg)
  if not plan then
    vim.notify(plan_err.message or tostring(plan_err), vim.log.levels.WARN)
    return nil
  end
  return require("nvim-stm32.operation").run(plan, cfg, function(result)
    if result.ok then
      require("nvim-stm32.ui.analysis").show(result)
    else
      vim.notify(result.error.message, vim.log.levels.ERROR)
    end
    if callback then
      callback(result)
    end
  end)
end

return M
