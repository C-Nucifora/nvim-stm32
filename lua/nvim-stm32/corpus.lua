local plugin = require("nvim-stm32")
local presets = require("nvim-stm32.build.presets")
local targets = require("nvim-stm32.targets")

local M = {}

local USAGE = "usage: scripts/validate-corpus.sh CORPUS_ROOT [--build]"
local BUILD_TIMEOUT_MS = 300000
local CALLBACK_GRACE_MS = 2000
local F429_REQUIREMENT =
  "project must resolve exactly one application image with MCU STM32F429ZITx or STM32F429xx"

local source_extensions = {
  c = true,
  cc = true,
  cpp = true,
  cxx = true,
  s = true,
  asm = true,
}

local function error_message(err)
  if type(err) == "table" then
    return err.message or vim.inspect(err)
  end
  return tostring(err)
end

local function scan(dir, visit)
  local handle, open_err = vim.uv.fs_scandir(dir)
  if not handle then
    return nil, open_err
  end
  while true do
    local name, kind = vim.uv.fs_scandir_next(handle)
    if not name then
      break
    end
    local path = dir .. "/" .. name
    if kind == "directory" then
      local ok, walk_err = scan(path, visit)
      if not ok then
        return nil, walk_err
      end
    elseif kind == "file" then
      visit(path, name)
    end
  end
  return true
end

local function scan_projects(dir, found)
  local handle, open_err = vim.uv.fs_scandir(dir)
  if not handle then
    return nil, open_err
  end
  while true do
    local name, kind = vim.uv.fs_scandir_next(handle)
    if not name then
      break
    end
    local path = dir .. "/" .. name
    if kind == "directory" and name ~= "build" then
      local ok, walk_err = scan_projects(path, found)
      if not ok then
        return nil, walk_err
      end
    elseif kind == "file" and name == "CMakePresets.json" then
      found[#found + 1] = dir
    end
  end
  return true
end

local function relative(root, path)
  if path == root then
    return ""
  end
  return path:sub(#root + 2)
end

function M.find_projects(root)
  if type(root) ~= "string" or root == "" then
    return nil, "corpus root must be a non-empty path"
  end
  root = vim.fs.normalize(root)
  local stat = vim.uv.fs_stat(root)
  if not stat or stat.type ~= "directory" then
    return nil, "corpus root is not a directory: " .. root
  end

  local found = {}
  local ok, scan_err = scan_projects(root, found)
  if not ok then
    return nil, "could not scan corpus root " .. root .. ": " .. tostring(scan_err)
  end
  table.sort(found, function(left, right)
    return relative(root, left) < relative(root, right)
  end)
  return found
end

function M.source_file(root)
  local source_root = root .. "/Core/Src"
  local stat = vim.uv.fs_stat(source_root)
  if not stat or stat.type ~= "directory" then
    return root
  end

  local found = {}
  local ok = scan(source_root, function(path, name)
    local extension = name:match("%.([^.]*)$")
    if extension and source_extensions[extension:lower()] then
      found[#found + 1] = path
    end
  end)
  if not ok or #found == 0 then
    return root
  end
  table.sort(found, function(left, right)
    return relative(source_root, left) < relative(source_root, right)
  end)
  return found[1]
end

function M.is_f429(project)
  if
    type(project) ~= "table"
    or type(project.images) ~= "table"
    or #project.images ~= 1
    or project.images[1].id ~= "application"
  then
    return false, F429_REQUIREMENT
  end
  for _, image in ipairs(project.images) do
    local mcu = image.target and image.target.mcu
    local parsed = targets.parse(mcu)
    local normalized = type(mcu) == "string" and mcu:upper() or ""
    if
      not parsed
      or parsed.device ~= "STM32F429"
      or (normalized ~= "STM32F429ZITX" and normalized ~= "STM32F429XX")
    then
      return false, F429_REQUIREMENT
    end
  end
  return true
end

function M.application_elf(result)
  if type(result) ~= "table" or not result.ok then
    return nil, "build did not return a successful result"
  end
  local build_id = result.metadata and result.metadata.operation_id
  if build_id == nil then
    return nil, "build did not return a fresh application ELF/build_id"
  end
  for _, artifact in ipairs(result.artifacts or {}) do
    if
      artifact.image_id == "application"
      and artifact.kind == "elf"
      and artifact.build_id == build_id
      and vim.fn.filereadable(artifact.path) == 1
    then
      return artifact.path
    end
  end
  return nil, "build did not return a fresh application ELF/build_id"
end

function M.parse_args(args)
  if
    type(args) ~= "table"
    or (#args ~= 1 and #args ~= 2)
    or type(args[1]) ~= "string"
    or args[1] == ""
    or (#args == 2 and args[2] ~= "--build")
  then
    return nil, USAGE
  end
  return { root = args[1], build = args[2] == "--build" }
end

function M.summary(results)
  local passed = 0
  local lines = {}
  for _, result in ipairs(results) do
    if result.ok then
      passed = passed + 1
      lines[#lines + 1] = "PASS " .. result.root
    else
      lines[#lines + 1] = "FAIL " .. result.root .. ": " .. result.error
    end
  end
  lines[#lines + 1] = string.format("%d/%d projects passed", passed, #results)
  return passed == #results and 0 or 1, lines
end

local function configurations(project)
  local available, available_err = presets.configurations(project.root)
  if not available then
    return nil, error_message(available_err)
  end
  local planned = {}
  for _, configuration in ipairs(available) do
    local plan, plan_err = plugin.plan("build", {
      project = project,
      configuration = configuration.name,
    })
    if not plan then
      return nil, error_message(plan_err)
    end
    planned[#planned + 1] = plan.metadata.configuration
  end
  return planned
end

local function project_details(project, source, configurations_list)
  local image_names = {}
  for _, image in ipairs(project.images) do
    image_names[#image_names + 1] = string.format(
      "%s=%s",
      image.id,
      tostring(image.target and image.target.mcu or "unknown")
    )
  end
  local lines = {
    "PROJECT " .. project.root,
    "  SOURCE " .. source,
    "  IMAGES " .. table.concat(image_names, ", "),
  }
  for _, configuration in ipairs(configurations_list) do
    lines[#lines + 1] =
      string.format("  CONFIG %s -> %s", configuration.name, configuration.binary_dir)
  end
  return lines
end

local function resolve(root)
  local source = M.source_file(root)
  local project, project_err = plugin.resolve_project(source)
  if not project then
    return nil, error_message(project_err)
  end
  if project.root ~= root then
    return nil,
      string.format(
        "resolved project root %s instead of %s",
        tostring(project.root),
        root
      )
  end
  local valid, validation_err = M.is_f429(project)
  if not valid then
    return nil, validation_err
  end
  local available, available_err = configurations(project)
  if not available then
    return nil, available_err
  end
  return {
    project = project,
    source = source,
    configurations = available,
    details = project_details(project, source, available),
  }
end

local function build_project(resolved, runtime)
  local result
  local handle, run_err = runtime.run("build", {
    project = resolved.project,
    configuration = "Debug",
    timeout_ms = runtime.timeout_ms,
  }, function(value)
    result = value
  end)
  if not handle then
    return nil, error_message(run_err)
  end

  local completed = runtime.wait(runtime.timeout_ms, function()
    return result ~= nil
  end, 20)
  if not completed then
    handle.cancel("corpus-timeout")
    local terminal = runtime.wait(runtime.grace_ms, function()
      local state = handle.state()
      return state == "completed" or state == "cancelled"
    end, 20)
    if not terminal then
      return nil, "Debug build did not reach a terminal state after cancellation", false
    end
    return nil, "timed out waiting for the Debug build callback", true
  end
  if not result.ok then
    local message = error_message(result.error)
    if result.output and result.output ~= "" then
      message = message .. "\n" .. result.output
    end
    return nil, message, true
  end
  local elf, elf_err = M.application_elf(result)
  return elf, elf_err, true
end

function M.build_projects(entries, opts)
  opts = opts or {}
  local runtime = {
    run = opts.run or plugin.run,
    wait = opts.wait or vim.wait,
    timeout_ms = opts.timeout_ms or BUILD_TIMEOUT_MS,
    grace_ms = opts.grace_ms or CALLBACK_GRACE_MS,
  }
  local results = {}
  for index, entry in ipairs(entries) do
    if not entry.resolved then
      results[#results + 1] = {
        root = entry.root,
        ok = false,
        error = entry.error,
      }
    else
      local elf, build_err, terminal = build_project(entry.resolved, runtime)
      results[#results + 1] = {
        root = entry.root,
        ok = elf ~= nil,
        error = build_err,
      }
      if terminal == false then
        for remaining = index + 1, #entries do
          local skipped = entries[remaining]
          results[#results + 1] = {
            root = skipped.root,
            ok = false,
            error = string.format(
              "project %s not run after corpus validation aborted at %s",
              skipped.root,
              entry.root
            ),
          }
        end
        return results, false
      end
    end
  end
  return results, true
end

local function emit(lines)
  for _, line in ipairs(lines) do
    vim.api.nvim_out_write(line .. "\n")
  end
end

function M.main(args)
  local options, args_err = M.parse_args(args)
  if not options then
    vim.api.nvim_err_writeln(args_err)
    return 2
  end
  local roots, roots_err = M.find_projects(options.root)
  if not roots then
    vim.api.nvim_err_writeln(roots_err)
    return 2
  end
  if #roots == 0 then
    vim.api.nvim_err_writeln(
      "no CMakePresets.json projects found under " .. options.root
    )
    return 2
  end

  local results
  if options.build then
    local entries = {}
    for _, root in ipairs(roots) do
      local resolved, resolved_err = resolve(root)
      entries[#entries + 1] = {
        root = root,
        resolved = resolved,
        error = resolved_err,
      }
    end
    results = M.build_projects(entries)
  else
    results = {}
    for _, root in ipairs(roots) do
      local resolved, resolved_err = resolve(root)
      if not resolved then
        results[#results + 1] = { root = root, ok = false, error = resolved_err }
      else
        emit(resolved.details)
        results[#results + 1] = { root = root, ok = true }
      end
    end
  end
  local code, lines = M.summary(results)
  emit(lines)
  return code
end

return M
