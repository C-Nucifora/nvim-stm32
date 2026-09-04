local model = require("nvim-stm32.model")

local M = {}

local preset_fields = { "configurePresets", "buildPresets" }

local function preset_error(code, source, preset, reason)
  return model.error({
    code = code,
    message = string.format("nvim-stm32: %s preset %s: %s", source, preset, reason),
    operation = "build",
    hint = "fix the CMake preset definition and try again",
  })
end

local function read_json(path, required)
  local read_ok, lines = pcall(vim.fn.readfile, path)
  if not read_ok then
    if not required and vim.fn.filereadable(path) == 0 then
      return {}
    end
    return nil,
      preset_error("cmake-presets-read", path, "document", "could not read file")
  end

  local decode_ok, document = pcall(vim.json.decode, table.concat(lines, "\n"))
  if not decode_ok or type(document) ~= "table" then
    return nil, preset_error("cmake-presets-json", path, "document", "invalid JSON")
  end
  return document
end

function M.load(root)
  local base_path = root .. "/CMakePresets.json"
  local base, base_err = read_json(base_path, true)
  if not base then
    return nil, base_err
  end

  local user_path = root .. "/CMakeUserPresets.json"
  local user, user_err = read_json(user_path, false)
  if not user then
    return nil, user_err
  end

  local document = vim.deepcopy(base)
  document._nvim_stm32_sources = {}
  for _, field in ipairs(preset_fields) do
    document[field] = {}
    document._nvim_stm32_sources[field] = {}
    for _, source in ipairs({
      { document = base, path = base_path },
      { document = user, path = user_path },
    }) do
      for _, preset in ipairs(source.document[field] or {}) do
        if type(preset) == "table" then
          local entry = vim.deepcopy(preset)
          document[field][#document[field] + 1] = entry
          document._nvim_stm32_sources[field][entry] = source.path
        end
      end
    end
  end
  return document
end

local function named_presets(document, field)
  local names, entries, sources = {}, {}, {}
  for _, preset in ipairs(document[field] or {}) do
    if type(preset.name) == "string" and preset.name ~= "" then
      if not entries[preset.name] then
        names[#names + 1] = preset.name
      end
      entries[preset.name] = preset
      sources[preset.name] = document._nvim_stm32_sources[field][preset]
    end
  end
  return names, entries, sources
end

local function inherited_names(value)
  if type(value) == "string" then
    return { value }
  end
  if type(value) == "table" then
    return value
  end
  return {}
end

local function resolve(entries, sources, name, stack, cache)
  if cache[name] then
    return cache[name]
  end
  local preset = entries[name]
  if not preset then
    return nil,
      preset_error(
        "cmake-presets-reference",
        sources[stack[#stack]] or "CMakePresets.json",
        name,
        "referenced preset does not exist"
      )
  end
  if stack[name] then
    return nil,
      preset_error("cmake-presets-cycle", sources[name], name, "inherits recursively")
  end

  stack[#stack + 1] = name
  stack[name] = true
  local resolved = {}
  local parents = inherited_names(preset.inherits)
  for index = #parents, 1, -1 do
    local parent = parents[index]
    if type(parent) ~= "string" or parent == "" then
      stack[name] = nil
      table.remove(stack)
      return nil,
        preset_error(
          "cmake-presets-reference",
          sources[name],
          name,
          "has an invalid inherited preset"
        )
    end
    local inherited, inherited_err = resolve(entries, sources, parent, stack, cache)
    if not inherited then
      stack[name] = nil
      table.remove(stack)
      return nil, inherited_err
    end
    inherited = vim.deepcopy(inherited)
    inherited.hidden = nil
    resolved = vim.tbl_deep_extend("force", resolved, inherited)
  end
  stack[name] = nil
  table.remove(stack)

  resolved = vim.tbl_deep_extend("force", resolved, preset)
  resolved.inherits = nil
  cache[name] = resolved
  return resolved
end

local function binary_dir(root, preset)
  local value = preset.binaryDir or "${sourceDir}/build/${presetName}"
  value = value:gsub("${sourceDir}", root)
  value = value:gsub("${presetName}", preset.name)
  return value
end

function M.configurations(root)
  local document, load_err = M.load(root)
  if not document then
    return nil, load_err
  end

  local configure_names, configure_entries, configure_sources =
    named_presets(document, "configurePresets")
  local build_names, build_entries, build_sources =
    named_presets(document, "buildPresets")
  local configure_cache, build_cache = {}, {}
  local configurations, paired = {}, {}

  for _, build_name in ipairs(build_names) do
    local build, build_err =
      resolve(build_entries, build_sources, build_name, {}, build_cache)
    if not build then
      return nil, build_err
    end
    if not build.hidden then
      local configure_name = build.configurePreset
      if type(configure_name) ~= "string" or configure_name == "" then
        return nil,
          preset_error(
            "cmake-presets-reference",
            build_sources[build_name],
            build_name,
            "does not name a configurePreset"
          )
      end
      local configure, configure_err = resolve(
        configure_entries,
        configure_sources,
        configure_name,
        {},
        configure_cache
      )
      if not configure then
        return nil, configure_err
      end
      if not configure.hidden then
        configurations[#configurations + 1] = model.configuration({
          name = build.name,
          configure_preset = configure_name,
          build_preset = build.name,
          binary_dir = binary_dir(root, configure),
        })
        paired[configure_name] = true
      end
    end
  end

  for _, configure_name in ipairs(configure_names) do
    local configure, configure_err =
      resolve(configure_entries, configure_sources, configure_name, {}, configure_cache)
    if not configure then
      return nil, configure_err
    end
    if not configure.hidden and not paired[configure_name] then
      configurations[#configurations + 1] = model.configuration({
        name = configure.name,
        configure_preset = configure.name,
        binary_dir = binary_dir(root, configure),
      })
    end
  end
  return configurations
end

function M.configure_command(project, config)
  return model.command({
    argv = { "cmake", "--preset", config.configure_preset },
    cwd = project.root,
    lifecycle = "short",
  })
end

function M.build_command(project, config, targets)
  local argv = config.build_preset
      and { "cmake", "--build", "--preset", config.build_preset }
    or { "cmake", "--build", config.binary_dir }
  if targets and #targets > 0 then
    argv[#argv + 1] = "--target"
    vim.list_extend(argv, targets)
  end
  return model.command({ argv = argv, cwd = project.root, lifecycle = "short" })
end

return M
