local linker = require("nvim-stm32.inspect.linker")
local model = require("nvim-stm32.model")

local M = {}

local kinds = {
  cubeprogrammer = "elf",
  openocd = "elf",
  stlink = "bin",
}

local function layout_error(code, message, image_id)
  return model.error({
    code = code,
    message = "nvim-stm32: " .. message,
    operation = "flash",
    image_id = image_id,
    hint = "select the intended configuration and rebuild before flashing",
  })
end

local function within(root, path)
  return path == root or path:sub(1, #root + 1) == root .. "/"
end

local function backend_id(backend)
  if type(backend) == "table" then
    return backend.id
  end
  return backend
end

local function ordered_images(context)
  local selected = {}
  for _, image in ipairs(context.images or {}) do
    selected[image.id] = image
  end
  local ordered, seen = {}, {}
  local function append(id)
    if selected[id] and not seen[id] then
      ordered[#ordered + 1] = selected[id]
      seen[id] = true
    end
  end
  for _, id in ipairs(context.project.flash_order or {}) do
    append(id)
  end
  for _, image in ipairs(context.project.images) do
    append(image.id)
  end
  return ordered
end

local function linker_file(project, image)
  local matches = {}
  for _, signal in ipairs(image.target.signals or {}) do
    if signal.source == "linker" and type(signal.file) == "string" then
      matches[#matches + 1] = signal.file
    end
  end
  if #matches == 0 then
    return nil,
      layout_error(
        "flash-linker-missing",
        "no linker script identifies the FLASH region for " .. image.id,
        image.id
      )
  end
  if #matches > 1 then
    return nil,
      layout_error(
        "flash-linker-ambiguous",
        "more than one linker script identifies the FLASH region for " .. image.id,
        image.id
      )
  end
  local path = matches[1]
  if path:sub(1, 1) ~= "/" then
    path = project.root .. "/" .. path
  end
  return vim.fs.normalize(path)
end

local function read_flash_region(project, image)
  local path, path_err = linker_file(project, image)
  if not path then
    return nil, path_err
  end
  local file = io.open(path, "r")
  if not file then
    return nil,
      layout_error(
        "flash-linker-read",
        "could not read linker script: " .. path,
        image.id
      )
  end
  local text = file:read("*a")
  file:close()
  local regions, regions_err = linker.parse(text)
  if not regions then
    return nil,
      layout_error(
        regions_err.code,
        regions_err.message:gsub("^nvim%-stm32: ", ""),
        image.id
      )
  end
  local region, region_err = linker.flash_region(regions)
  if not region then
    return nil,
      layout_error(
        region_err.code,
        region_err.message:gsub("^nvim%-stm32: ", ""),
        image.id
      )
  end
  return region
end

local function artifact_for(context, artifacts, image, kind)
  local candidates = {}
  for _, value in ipairs(artifacts or {}) do
    local ok, artifact = pcall(model.artifact, value)
    if not ok then
      return nil,
        layout_error(
          "flash-artifact-invalid",
          "invalid artifact for " .. image.id .. ": " .. tostring(artifact),
          image.id
        )
    end
    if artifact.image_id == image.id and artifact.kind == kind then
      candidates[#candidates + 1] = artifact
    end
  end
  if #candidates == 0 then
    return nil,
      layout_error(
        "flash-artifact-missing",
        "no " .. kind:upper() .. " artifact for " .. image.id,
        image.id
      )
  end

  local configuration = context.configuration.name
  local configured = vim.tbl_filter(function(artifact)
    return artifact.configuration == configuration
  end, candidates)
  if #configured == 0 then
    return nil,
      layout_error(
        "flash-configuration-mismatch",
        "no " .. kind:upper() .. " artifact for " .. image.id .. " in " .. configuration,
        image.id
      )
  end

  local targeted = vim.tbl_filter(function(artifact)
    return not image.build_target or artifact.build_target == image.build_target
  end, configured)
  if #targeted == 0 then
    return nil,
      layout_error(
        "flash-build-target-mismatch",
        "artifact build target does not match image " .. image.id,
        image.id
      )
  end
  if #targeted > 1 then
    return nil,
      layout_error(
        "flash-artifact-ambiguous",
        "more than one " .. kind:upper() .. " artifact matches " .. image.id,
        image.id
      )
  end

  local artifact = targeted[1]
  if type(artifact.build_id) ~= "string" or artifact.build_id == "" then
    return nil,
      layout_error(
        "flash-build-stale",
        "artifact has no successful build id: " .. artifact.path,
        image.id
      )
  end
  if context.build_id and artifact.build_id ~= context.build_id then
    return nil,
      layout_error(
        "flash-build-stale",
        "artifact does not belong to build "
          .. context.build_id
          .. ": "
          .. artifact.path,
        image.id
      )
  end
  return artifact
end

local function checked_artifact(binary_real, artifact)
  local path = vim.fs.normalize(artifact.path)
  local real = vim.uv.fs_realpath(path)
  if not real then
    return nil,
      layout_error(
        "flash-artifact-missing",
        "artifact no longer exists: " .. path,
        artifact.image_id
      )
  end
  real = vim.fs.normalize(real)
  if not within(binary_real, real) then
    return nil,
      layout_error(
        "flash-artifact-outside-build",
        "artifact is outside the selected binary directory: " .. path,
        artifact.image_id
      )
  end
  local stat = vim.uv.fs_stat(real)
  if not stat or stat.type ~= "file" then
    return nil,
      layout_error(
        "flash-artifact-missing",
        "artifact is not a regular file: " .. path,
        artifact.image_id
      )
  end
  local mtime = stat.mtime or {}
  local current_modified_ns = (mtime.sec or 0) * 1000000000 + (mtime.nsec or 0)
  if current_modified_ns ~= artifact.modified_ns then
    return nil,
      layout_error(
        "flash-artifact-changed",
        "artifact changed after its successful build: " .. path,
        artifact.image_id
      )
  end
  local copied = vim.deepcopy(artifact)
  copied.path = real
  return copied, stat.size
end

local function valid_address(address)
  return type(address) == "number"
    and address > 0
    and address <= 0xFFFFFFFF
    and address % 1 == 0
    and address % 4 == 0
end

local function flag_set(flags)
  local found = {}
  for _, flag in ipairs(flags or {}) do
    found[flag] = true
  end
  return found
end

local function elf_ranges(sections, region, image)
  if type(sections) ~= "table" then
    return nil,
      layout_error(
        "flash-elf-layout-unvalidated",
        "ELF load sections were not inspected for " .. image.id,
        image.id
      )
  end
  local ranges = {}
  local total = 0
  for _, section in ipairs(sections) do
    local flags = flag_set(section.flags)
    if section.size > 0 and flags.ALLOC and flags.LOAD then
      local finish = section.lma + section.size
      if
        section.lma < region.origin
        or finish > region.origin + region.length
        or finish > 0x100000000
      then
        return nil,
          layout_error(
            "flash-range-outside-region",
            "ELF section " .. section.name .. " exceeds FLASH for " .. image.id,
            image.id
          )
      end
      ranges[#ranges + 1] = { start = section.lma, finish = finish }
      total = total + section.size
    end
  end
  if #ranges == 0 then
    return nil,
      layout_error(
        "flash-elf-layout-empty",
        "ELF has no allocated load sections for " .. image.id,
        image.id
      )
  end
  table.sort(ranges, function(left, right)
    return left.start < right.start
  end)
  return ranges, total
end

local function resolve_image(context, artifacts, image, kind, binary_real, opts)
  local artifact, artifact_err = artifact_for(context, artifacts, image, kind)
  if not artifact then
    return nil, artifact_err
  end
  local checked, size = checked_artifact(binary_real, artifact)
  if not checked then
    return nil, size
  end
  local region, region_err = read_flash_region(context.project, image)
  if not region then
    return nil, region_err
  end
  if kind == "elf" then
    if opts.defer_elf then
      return {
        image_id = image.id,
        artifact = checked,
        embedded_address = true,
        region = vim.deepcopy(region),
      }
    end
    local ranges, total_or_err =
      elf_ranges(opts.sections and opts.sections[image.id], region, image)
    if not ranges then
      return nil, total_or_err
    end
    return {
      image_id = image.id,
      artifact = checked,
      address = ranges[1].start,
      size = total_or_err,
      ranges = ranges,
      embedded_address = true,
      region = vim.deepcopy(region),
    }
  end

  local address = image.flash and image.flash.address or region.origin
  if not valid_address(address) then
    return nil,
      layout_error(
        "flash-address-invalid",
        "flash address must be a positive aligned 32-bit integer for " .. image.id,
        image.id
      )
  end
  if address < region.origin or address + size > region.origin + region.length then
    return nil,
      layout_error(
        "flash-range-outside-region",
        "artifact range exceeds the FLASH region for " .. image.id,
        image.id
      )
  end
  return {
    image_id = image.id,
    artifact = checked,
    address = address,
    size = size,
    ranges = { { start = address, finish = address + size } },
    region = vim.deepcopy(region),
  }
end

function M.resolve(context, artifacts, backend, opts)
  opts = opts or {}
  vim.validate("context", context, "table")
  vim.validate("context.project", context.project, "table")
  vim.validate("context.images", context.images, "table")
  vim.validate("context.configuration", context.configuration, "table")
  local id = backend_id(backend)
  local kind = kinds[id]
  if not kind then
    return nil,
      layout_error("flash-backend-unknown", "unknown flash backend " .. tostring(id))
  end
  local binary_real = vim.uv.fs_realpath(context.configuration.binary_dir)
  local binary_stat = binary_real and vim.uv.fs_stat(binary_real) or nil
  if not binary_real or not binary_stat or binary_stat.type ~= "directory" then
    return nil,
      layout_error(
        "flash-binary-dir-missing",
        "selected binary directory does not exist: " .. context.configuration.binary_dir
      )
  end
  binary_real = vim.fs.normalize(binary_real)

  local resolved = {}
  for _, image in ipairs(ordered_images(context)) do
    local item, item_err =
      resolve_image(context, artifacts, image, kind, binary_real, opts)
    if not item then
      return nil, item_err
    end
    resolved[#resolved + 1] = item
  end
  for left_index, left in ipairs(resolved) do
    for right_index = left_index + 1, #resolved do
      local right = resolved[right_index]
      for _, left_range in ipairs(left.ranges or {}) do
        for _, right_range in ipairs(right.ranges or {}) do
          if
            left_range.start < right_range.finish
            and right_range.start < left_range.finish
          then
            return nil,
              layout_error(
                "flash-range-overlap",
                "selected image ranges overlap: "
                  .. left.image_id
                  .. " and "
                  .. right.image_id
              )
          end
        end
      end
    end
  end
  return resolved
end

return M
