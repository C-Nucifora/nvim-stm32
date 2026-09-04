local float = require("nvim-stm32.ui.float")
local process = require("nvim-stm32.process")
local tools = require("nvim-stm32.tools")

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
    commands[#commands + 1] = backend.configure_cmd(target, opts)
  end
  commands[#commands + 1] = backend.cmd(target, opts)
  return commands
end

function M.find_elf(target, opts)
  opts = opts or {}
  local search_root = target.root .. "/build"
  if target.build_backend == "cmake_presets" then
    if not opts.preset then
      return nil, "nvim-stm32: preset is required to find the built .elf"
    end
    search_root = search_root .. "/" .. opts.preset
  end

  local files = vim.fs.find(function(name)
    return name:sub(-4):lower() == ".elf"
  end, { path = search_root, type = "file", limit = 2 })
  table.sort(files)

  if #files == 0 then
    return nil, "nvim-stm32: no .elf found under " .. search_root
  end
  if #files > 1 then
    return nil, "nvim-stm32: multiple .elf files found: " .. table.concat(files, ", ")
  end
  return files[1]
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

function M.current(opts)
  local target, detect_err = require("nvim-stm32.detect").target()
  if not target then
    vim.notify(detect_err, vim.log.levels.WARN)
    return
  end
  if not target.build_backend then
    vim.notify("nvim-stm32: project has no supported build file", vim.log.levels.WARN)
    return
  end

  local config = resolved_config(opts)
  if target.build_backend ~= "cmake_presets" or config.preset then
    return M.run(target, config)
  end

  local names, preset_err = M.backends.cmake_presets.presets(target.root)
  if not names then
    vim.notify(preset_err, vim.log.levels.ERROR)
    return
  end
  if #names == 0 then
    vim.notify("nvim-stm32: no visible CMake presets found", vim.log.levels.WARN)
    return
  end

  vim.ui.select(names, { prompt = "STM32 build preset" }, function(choice)
    if not choice then
      return
    end
    config.preset = choice
    M.run(target, config)
  end)
end

return M
