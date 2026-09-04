local M = {}
local preset_resolver = require("nvim-stm32.build.presets")

function M.available()
  return vim.fn.executable("cmake") == 1
end

local function selected_configuration(target, opts)
  local preset = assert(opts.preset, "preset is required")
  if type(target.root) ~= "string" or target.root == "" then
    return require("nvim-stm32.model").configuration({
      name = preset,
      configure_preset = preset,
      build_preset = preset,
      binary_dir = "build/" .. preset,
    })
  end

  local configurations, configuration_err = preset_resolver.configurations(target.root)
  if not configurations then
    error(configuration_err.message)
  end
  for _, configuration in ipairs(configurations) do
    if configuration.name == preset then
      return configuration
    end
  end
  error("unknown CMake preset: " .. preset)
end

function M.configure_cmd(target, opts)
  local configuration = selected_configuration(target, opts)
  return preset_resolver.configure_command(target, configuration).argv
end

function M.cmd(target, opts)
  local configuration = selected_configuration(target, opts)
  return preset_resolver.build_command(target, configuration, opts.targets).argv
end

function M.parse(output, code)
  return { ok = code == 0, code = code, output = output }
end

function M.presets(root)
  local names = {}
  local configurations, configuration_err = preset_resolver.configurations(root)
  if not configurations then
    return nil, configuration_err
  end
  for _, configuration in ipairs(configurations) do
    names[#names + 1] = configuration.name
  end
  return names
end

return M
