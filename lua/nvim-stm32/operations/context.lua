local model = require("nvim-stm32.model")
local presets = require("nvim-stm32.build.presets")
local session = require("nvim-stm32.session")

local M = {}

local function selection_error(code, message, hint)
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

function M.configurations(project)
  local adapter = adapter_for(project)
  if adapter == "cmake_presets" then
    return presets.configurations(project.root)
  end
  if adapter == "cmake_plain" or adapter == "make" then
    return {
      {
        name = "default",
        configure_preset = "default",
        binary_dir = project.root .. "/build",
      },
    }
  end
  return nil,
    selection_error(
      "build-backend-unknown",
      "unknown build backend " .. tostring(adapter)
    )
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

function M.resolve_configuration(project, opts, available)
  opts = opts or {}
  local requested = opts.configuration
  if requested == nil then
    requested = opts.preset
  end
  if requested == nil then
    requested = session.get(project).configuration
  end
  local selected = named_configuration(available, requested)
  if selected == false then
    return nil,
      selection_error(
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
    selection_error(
      "configuration-required",
      #available == 0 and "no visible build configurations found"
        or "a build configuration must be selected",
      "run :STM32SelectConfig and choose a visible configuration"
    )
end

function M.resolve_images(project, opts)
  opts = opts or {}
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
    return vim.deepcopy(project.images)
  end
  if type(requested) ~= "table" then
    return nil, selection_error("image-selection-invalid", "images must be a list")
  end

  local known = {}
  for _, image in ipairs(project.images) do
    known[image.id] = image
  end

  local selected, seen = {}, {}
  for _, image_id in ipairs(requested) do
    if type(image_id) ~= "string" or image_id == "" or not known[image_id] then
      return nil,
        selection_error(
          "image-not-found",
          "unknown project image " .. tostring(image_id)
        )
    end
    if not seen[image_id] then
      selected[#selected + 1] = model.image(known[image_id])
      seen[image_id] = true
    end
  end
  if #selected == 0 then
    return nil,
      selection_error("image-selection-invalid", "at least one image is required")
  end
  return selected
end

function M.resolve(project, opts)
  opts = vim.deepcopy(opts or {})
  local project_ok, copied_project = pcall(model.project, project)
  if not project_ok then
    return nil, selection_error("project-invalid", tostring(copied_project))
  end

  local available, available_err = M.configurations(copied_project)
  if not available then
    return nil, available_err
  end
  local configuration, configuration_err =
    M.resolve_configuration(copied_project, opts, available)
  if not configuration then
    return nil, configuration_err
  end
  local images, images_err = M.resolve_images(copied_project, opts)
  if not images then
    return nil, images_err
  end

  return {
    project = copied_project,
    configuration = model.configuration(configuration),
    images = images,
  }
end

return M
