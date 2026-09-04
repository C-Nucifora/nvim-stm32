local float = require("nvim-stm32.ui.float")
local process = require("nvim-stm32.process")
local tools = require("nvim-stm32.tools")
local artifacts = require("nvim-stm32.discover.artifacts")

local M = {}

M.backends = {
  cmake_presets = require("nvim-stm32.backend.build.cmake_presets"),
  cmake_plain = require("nvim-stm32.backend.build.cmake_plain"),
  make = require("nvim-stm32.backend.build.make"),
}

M.last_result = nil

local function resolved_config(opts)
  return vim.tbl_deep_extend(
    "force",
    vim.deepcopy(require("nvim-stm32").get_config()),
    opts or {}
  )
end

function M.commands(target, opts)
  opts = opts or {}
  local backend = M.backends[target.build_backend]
  if not backend then
    return nil, "nvim-stm32: unknown build backend " .. tostring(target.build_backend)
  end
  if not backend.available() then
    return nil, "nvim-stm32: build tool is unavailable for " .. target.build_backend
  end

  local commands = {}
  if backend.configure_cmd then
    local configure_command, configure_err = backend.configure_cmd(target, opts)
    if not configure_command then
      return nil, configure_err
    end
    commands[#commands + 1] = configure_command
  end
  local build_command, build_err = backend.cmd(target, opts)
  if not build_command then
    return nil, build_err
  end
  commands[#commands + 1] = build_command
  return commands
end

function M.find_elf(target, opts)
  opts = opts or {}
  local image_id = target.image_id or opts.image_id
  local found

  if not opts.artifacts and target.root then
    local state = require("nvim-stm32.session").get(target.root)
    if #state.artifacts > 0 then
      opts = vim.tbl_extend("force", {}, opts, { artifacts = state.artifacts })
      image_id = image_id or state.image_id
      if not image_id then
        local ids = {}
        for _, artifact in ipairs(state.artifacts) do
          ids[artifact.image_id] = true
        end
        local sole
        for id in pairs(ids) do
          if sole then
            sole = nil
            break
          end
          sole = id
        end
        image_id = sole
      end
    end
  end

  if opts.artifacts then
    if not image_id then
      return nil, "nvim-stm32: image id is required to select a built .elf"
    end
    found = artifacts.for_image(opts.artifacts, image_id, "elf")
  elseif opts.project and opts.configuration then
    local all, artifact_err
    if opts.reply then
      all, artifact_err = artifacts.from_cmake(
        opts.project,
        opts.configuration,
        opts.reply,
        opts.build_id
      )
    else
      all, artifact_err =
        artifacts.from_tree(opts.project, opts.configuration, opts.build_id)
    end
    if not all then
      return nil, artifacts.format_error(artifact_err)
    end
    if not image_id and #opts.project.images == 1 then
      image_id = opts.project.images[1].id
    end
    if not image_id then
      return nil, "nvim-stm32: image id is required to select a built .elf"
    end
    found = artifacts.for_image(all, image_id, "elf")
  else
    local search_root = target.root .. "/build"
    if target.build_backend == "cmake_presets" then
      if not opts.preset then
        return nil, "nvim-stm32: preset is required to find the built .elf"
      end
      search_root = search_root .. "/" .. opts.preset
    end
    image_id = image_id or "legacy"
    local all, artifact_err = artifacts.from_tree({
      images = {
        {
          id = image_id,
          build_target = target.build_target,
        },
      },
    }, {
      name = opts.preset or "default",
      binary_dir = search_root,
    }, opts.build_id)
    if not all then
      if artifact_err.code == "artifact-missing" then
        return nil, "nvim-stm32: no .elf found under " .. search_root
      end
      return nil, artifacts.format_error(artifact_err)
    end
    found = artifacts.for_image(all, image_id, "elf")
  end

  if #found == 0 then
    return nil, "nvim-stm32: no .elf found for image " .. image_id
  end
  if #found > 1 then
    local paths = {}
    for _, artifact in ipairs(found) do
      paths[#paths + 1] = artifact.path
    end
    return nil, "nvim-stm32: multiple .elf files found: " .. table.concat(paths, ", ")
  end
  return found[1].path
end

local function report_error(presenter, result, err)
  result.ok = false
  result.error = err
  presenter:append("\n" .. err .. "\n")
end

function M.run(target, opts, callback)
  local config = resolved_config(opts)
  local commands, command_err = M.commands(target, config)
  if not commands then
    local result = { ok = false, code = -1, output = "", error = command_err }
    M.last_result = result
    vim.notify(command_err, vim.log.levels.ERROR)
    if callback then
      callback(result)
    end
    return nil
  end

  M.last_result = nil
  local presenter = float.open(target, config)
  process.run(commands, {
    cwd = target.root,
    env = tools.env(config),
    on_output = function(chunk)
      presenter:append(chunk)
    end,
  }, function(process_result)
    local backend = M.backends[target.build_backend]
    local result = backend.parse(process_result.output, process_result.code)
    result.signal = process_result.signal
    result.command = process_result.command

    if result.ok then
      local elf, elf_err = M.find_elf(target, config)
      if elf then
        target.elf = elf
        result.elf = elf
      else
        report_error(presenter, result, elf_err)
      end
    end

    presenter:finish(result.ok)
    M.last_result = result
    if callback then
      callback(result)
    end
  end)
  return presenter
end

function M.current(opts, callback)
  return require("nvim-stm32.operations.build").current(opts, callback)
end

return M
