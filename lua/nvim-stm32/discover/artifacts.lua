local model = require("nvim-stm32.model")

local M = {}

local kinds = {
  [".elf"] = "elf",
  [".hex"] = "hex",
  [".bin"] = "bin",
  [".map"] = "map",
}

local function error(code, message, image_id)
  return model.error({
    code = code,
    message = "nvim-stm32: " .. message,
    operation = "build",
    image_id = image_id,
    hint = "check the selected build configuration and build again",
  })
end

local function has_prefix(root, path)
  return path == root or path:sub(1, #root + 1) == root .. "/"
end

local function binary_root(config)
  local root = vim.fs.normalize(config.binary_dir)
  local real = vim.uv.fs_realpath(root)
  if not real then
    return nil,
      nil,
      error("artifact-missing", "selected binary directory does not exist: " .. root)
  end
  return root, vim.fs.normalize(real)
end

local function existing_path(root, path, image_id)
  local normalized = vim.fs.normalize(path)
  local stat = vim.uv.fs_stat(normalized)
  if not stat or stat.type ~= "file" then
    return nil,
      error("artifact-missing", "artifact does not exist: " .. normalized, image_id)
  end
  local real = vim.uv.fs_realpath(normalized)
  if not real or not has_prefix(root, real) then
    return nil,
      error(
        "artifact-outside-binary-dir",
        "artifact is outside the selected binary directory: " .. normalized,
        image_id
      )
  end
  return normalized, stat
end

local function modified_ns(stat)
  local mtime = stat.mtime or {}
  if type(mtime.nsec) == "number" then
    return mtime.sec * 1000000000 + mtime.nsec
  end
  return (mtime.sec or 0) * 1000000000
end

local function kind_for(path)
  return kinds[path:lower():match("(%.[^.]+)$")]
end

local function add_artifact(
  found,
  seen,
  root_real,
  config,
  image,
  build_target,
  path,
  build_id,
  source
)
  local real, stat_or_err = existing_path(root_real, path, image.id)
  if not real then
    return nil, stat_or_err
  end
  local kind = kind_for(real)
  local identity = real
  if stat_or_err.dev and stat_or_err.ino then
    identity = tostring(stat_or_err.dev) .. ":" .. tostring(stat_or_err.ino)
  end
  if not kind or seen[identity] then
    return true
  end
  seen[identity] = true
  found[#found + 1] = model.artifact({
    image_id = image.id,
    kind = kind,
    path = real,
    configuration = config.name,
    build_target = build_target,
    modified_ns = modified_ns(stat_or_err),
    size = stat_or_err.size,
    build_id = build_id,
    provenance = { source = source },
  })
  return true
end

local function image_for_target(project, executables, target)
  local matches = {}
  for _, image in ipairs(project.images) do
    if image.build_target and image.build_target == target.name then
      matches[#matches + 1] = image
    end
  end
  if #matches == 1 then
    return matches[1], target.name
  end
  if #project.images == 1 and #executables == 1 then
    return project.images[1], target.name
  end
  return nil,
    error(
      "artifact-ambiguous",
      "cannot map executable target " .. tostring(target.name) .. " to an image"
    )
end

function M.from_cmake(project, config, reply, build_id)
  local root, root_real, root_err = binary_root(config)
  if not root then
    return nil, root_err
  end
  local executables = {}
  for _, target in ipairs(reply.targets or {}) do
    if target.type == "EXECUTABLE" then
      executables[#executables + 1] = target
    end
  end

  local found, seen = {}, {}
  for _, target in ipairs(executables) do
    local image, build_target_or_err = image_for_target(project, executables, target)
    if not image then
      return nil, build_target_or_err
    end
    local build_target = build_target_or_err
    local elf_paths = {}
    for _, path in ipairs(target.artifacts or {}) do
      local real, path_err = existing_path(root_real, path, image.id)
      if not real then
        return nil, path_err
      end
      if kind_for(real) == "elf" then
        elf_paths[#elf_paths + 1] = real
      end
    end
    if #elf_paths == 0 then
      return nil,
        error(
          "artifact-missing",
          "executable target has no ELF artifact: " .. target.name,
          image.id
        )
    end
    for _, elf in ipairs(elf_paths) do
      local added, add_err = add_artifact(
        found,
        seen,
        root_real,
        config,
        image,
        build_target,
        elf,
        build_id,
        "cmake-file-api"
      )
      if not added then
        return nil, add_err
      end
      local directory = vim.fs.dirname(elf)
      local stem = vim.fn.fnamemodify(elf, ":r")
      local siblings = vim.fs.find(function(name)
        return kind_for(name) ~= nil
      end, { path = directory, type = "file", limit = math.huge })
      table.sort(siblings)
      for _, sibling in ipairs(siblings) do
        if
          vim.fs.dirname(sibling) == directory
          and vim.fn.fnamemodify(sibling, ":r") == stem
        then
          local added, add_err = add_artifact(
            found,
            seen,
            root_real,
            config,
            image,
            build_target,
            sibling,
            build_id,
            "cmake-file-api"
          )
          if not added then
            return nil, add_err
          end
        end
      end
    end
  end
  if #found == 0 then
    return nil, error("artifact-missing", "no executable artifacts found")
  end
  return found
end

local function image_for_path(project, elf_stems, path)
  local stem = vim.fn.fnamemodify(vim.fn.fnamemodify(path, ":t"), ":r")
  local matches = {}
  for _, image in ipairs(project.images) do
    if image.build_target and image.build_target == stem then
      matches[#matches + 1] = image
    end
  end
  if #matches == 1 then
    return matches[1], stem
  end
  if #project.images == 1 and #elf_stems == 1 and stem == elf_stems[1] then
    return project.images[1], stem
  end
  return nil,
    error("artifact-ambiguous", "cannot map artifact " .. stem .. " to an image")
end

function M.from_tree(project, config, build_id)
  local root, root_real, root_err = binary_root(config)
  if not root then
    return nil, root_err
  end
  local paths = vim.fs.find(function(name)
    return kind_for(name) ~= nil
  end, { path = root, type = "file", limit = math.huge })
  table.sort(paths)
  if #paths == 0 then
    return nil, error("artifact-missing", "no artifacts found under " .. root)
  end

  local elf_stems = {}
  for _, path in ipairs(paths) do
    if kind_for(path) == "elf" then
      elf_stems[#elf_stems + 1] =
        vim.fn.fnamemodify(vim.fn.fnamemodify(path, ":t"), ":r")
    end
  end

  local found, seen = {}, {}
  for _, path in ipairs(paths) do
    local image, build_target_or_err = image_for_path(project, elf_stems, path)
    if not image then
      return nil, build_target_or_err
    end
    local added, add_err = add_artifact(
      found,
      seen,
      root_real,
      config,
      image,
      build_target_or_err,
      path,
      build_id,
      "tree"
    )
    if not added then
      return nil, add_err
    end
  end
  return found
end

function M.for_image(all, image_id, kind)
  local found = {}
  for _, artifact in ipairs(all or {}) do
    if artifact.image_id == image_id and (not kind or artifact.kind == kind) then
      found[#found + 1] = artifact
    end
  end
  return found
end

function M.format_error(err)
  if type(err) == "string" then
    return err
  end
  return err and err.message or "nvim-stm32: artifact discovery failed"
end

return M
