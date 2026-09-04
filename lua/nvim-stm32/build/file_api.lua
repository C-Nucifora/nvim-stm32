local model = require("nvim-stm32.model")

local M = {}

local function file_error(code, path, reason)
  return model.error({
    code = code,
    message = string.format("nvim-stm32: CMake File API %s: %s", path, reason),
    operation = "build",
    hint = "run CMake configure and try again",
  })
end

local function read_json(path, code)
  local read_ok, lines = pcall(vim.fn.readfile, path)
  if not read_ok then
    return nil, file_error(code, path, "could not read JSON")
  end
  local decode_ok, value = pcall(vim.json.decode, table.concat(lines, "\n"))
  if not decode_ok or type(value) ~= "table" then
    return nil, file_error(code, path, "invalid JSON")
  end
  return value
end

local function is_dense_array(value)
  if type(value) ~= "table" then
    return false
  end
  local count = 0
  local maximum = 0
  for key in pairs(value) do
    if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then
      return false
    end
    count = count + 1
    maximum = math.max(maximum, key)
  end
  return maximum == count
end

local function path_is_within(root, path)
  return path == root or path:sub(1, #root + 1) == root .. "/"
end

local function path_in_reply(reply_dir, name)
  if type(name) ~= "string" or name == "" then
    return nil
  end
  local root = vim.fs.normalize(reply_dir)
  local path = vim.fs.normalize(root .. "/" .. name)
  if path == root or not path_is_within(root, path) then
    return nil
  end
  local root_real = vim.uv.fs_realpath(root)
  local stat = vim.uv.fs_lstat(path)
  if not stat then
    return path
  end
  local path_real = vim.uv.fs_realpath(path)
  if not root_real or not path_real or not path_is_within(root_real, path_real) then
    return nil
  end
  return path_real
end

local function is_absolute(path)
  return path:sub(1, 1) == "/"
end

local function resolve_path(root, path)
  if type(path) ~= "string" or path == "" then
    return nil
  end
  if is_absolute(path) then
    return vim.fs.normalize(path)
  end
  if type(root) ~= "string" or root == "" then
    return nil
  end
  return vim.fs.normalize(root .. "/" .. path)
end

local function codemodel_replies(value, found)
  if type(value) ~= "table" then
    return
  end
  if
    value.kind == "codemodel"
    and type(value.version) == "table"
    and value.version.major == 2
  then
    found[#found + 1] = value
  end
  for _, child in pairs(value) do
    if type(child) == "table" then
      codemodel_replies(child, found)
    end
  end
end

local function valid_codemodel(codemodel)
  if
    codemodel.kind ~= "codemodel"
    or type(codemodel.version) ~= "table"
    or codemodel.version.major ~= 2
    or (codemodel.paths ~= nil and type(codemodel.paths) ~= "table")
    or not is_dense_array(codemodel.configurations)
  then
    return false
  end
  for _, configuration in ipairs(codemodel.configurations) do
    if type(configuration) ~= "table" or not is_dense_array(configuration.targets) then
      return false
    end
    local directories = configuration.directories
    if directories == nil then
      directories = {}
    elseif not is_dense_array(directories) then
      return false
    end
    for _, directory in ipairs(directories) do
      if
        type(directory) ~= "table"
        or type(directory.source) ~= "string"
        or directory.source == ""
        or type(directory.build) ~= "string"
        or directory.build == ""
      then
        return false
      end
      if not is_absolute(directory.source) then
        if
          type(codemodel.paths) ~= "table" or type(codemodel.paths.source) ~= "string"
        then
          return false
        end
      end
      if not is_absolute(directory.build) then
        if
          type(codemodel.paths) ~= "table" or type(codemodel.paths.build) ~= "string"
        then
          return false
        end
      end
    end
    for _, target in ipairs(configuration.targets) do
      if
        type(target) ~= "table"
        or type(target.jsonFile) ~= "string"
        or target.jsonFile == ""
      then
        return false
      end
      if target.directoryIndex ~= nil then
        if
          type(target.directoryIndex) ~= "number"
          or target.directoryIndex < 0
          or target.directoryIndex % 1 ~= 0
          or not directories[target.directoryIndex + 1]
        then
          return false
        end
      end
    end
  end
  return true
end

local function index_files(reply_dir)
  local files = vim.fn.glob(reply_dir .. "/index-*.json", false, true)
  table.sort(files, function(left, right)
    local left_stat = vim.uv.fs_stat(left)
    local right_stat = vim.uv.fs_stat(right)
    local left_time = left_stat and left_stat.mtime or { sec = 0, nsec = 0 }
    local right_time = right_stat and right_stat.mtime or { sec = 0, nsec = 0 }
    if left_time.sec == right_time.sec and left_time.nsec == right_time.nsec then
      return left > right
    end
    if left_time.sec == right_time.sec then
      return left_time.nsec > right_time.nsec
    end
    return left_time.sec > right_time.sec
  end)
  return files
end

local function newest_codemodel(reply_dir)
  local last_err = file_error("cmake-file-api-index", reply_dir, "no index reply found")
  for _, index_path in ipairs(index_files(reply_dir)) do
    local index, index_err = read_json(index_path, "cmake-file-api-index")
    if not index then
      last_err = index_err
    else
      local replies = {}
      codemodel_replies(index.objects, replies)
      codemodel_replies(index.reply, replies)
      if #replies == 0 then
        last_err = file_error(
          "cmake-file-api-index",
          index_path,
          "does not contain a codemodel v2 reply"
        )
      else
        for _, response in ipairs(replies) do
          local codemodel_path = path_in_reply(reply_dir, response.jsonFile)
          if not codemodel_path then
            last_err = file_error(
              "cmake-file-api-codemodel",
              index_path,
              "references a codemodel outside the reply directory"
            )
          else
            local codemodel, codemodel_err =
              read_json(codemodel_path, "cmake-file-api-codemodel")
            if codemodel and valid_codemodel(codemodel) then
              return codemodel, codemodel_path
            end
            last_err = codemodel_err
              or file_error(
                "cmake-file-api-codemodel",
                codemodel_path,
                "is not a codemodel v2 reply"
              )
          end
        end
      end
    end
  end
  return nil, last_err
end

local function target_path(reply_dir, target, codemodel_path)
  local path = path_in_reply(reply_dir, target.jsonFile)
  if not path then
    return nil,
      file_error(
        "cmake-file-api-target",
        codemodel_path,
        "references a target outside the reply directory"
      )
  end
  return path
end

local function target_record(reply_dir, codemodel_path, directories, target_ref)
  local path, path_err = target_path(reply_dir, target_ref, codemodel_path)
  if not path then
    return nil, path_err
  end
  local target, target_err = read_json(path, "cmake-file-api-target")
  if not target then
    return nil, target_err
  end
  if type(target.type) ~= "string" then
    return nil, file_error("cmake-file-api-target", path, "has no target type")
  end
  if target.type ~= "EXECUTABLE" then
    return false
  end

  local directory = {}
  if target_ref.directoryIndex ~= nil then
    if
      type(target_ref.directoryIndex) ~= "number"
      or target_ref.directoryIndex < 0
      or target_ref.directoryIndex % 1 ~= 0
      or type(directories[target_ref.directoryIndex + 1]) ~= "table"
    then
      return nil,
        file_error("cmake-file-api-target", path, "has an invalid directory index")
    end
    directory = directories[target_ref.directoryIndex + 1] or {}
  end
  if target.paths ~= nil and type(target.paths) ~= "table" then
    return nil, file_error("cmake-file-api-target", path, "has invalid paths")
  end
  if target.artifacts ~= nil and not is_dense_array(target.artifacts) then
    return nil, file_error("cmake-file-api-target", path, "has invalid artifacts")
  end
  if target.link ~= nil and type(target.link) ~= "table" then
    return nil, file_error("cmake-file-api-target", path, "has invalid linker metadata")
  end
  local paths = target.paths or {}
  local source_dir = directory.source
  local build_dir = directory.build
  if paths.source ~= nil then
    source_dir = resolve_path(directory.source, paths.source)
  end
  if paths.build ~= nil then
    build_dir = resolve_path(directory.build, paths.build)
  end
  local name = target.name or target_ref.name
  if
    type(name) ~= "string"
    or name == ""
    or type(source_dir) ~= "string"
    or source_dir == ""
  then
    return nil,
      file_error("cmake-file-api-target", path, "has incomplete target metadata")
  end
  if type(build_dir) ~= "string" or build_dir == "" then
    return nil, file_error("cmake-file-api-target", path, "has no build directory")
  end

  local artifacts = {}
  for _, artifact in ipairs(target.artifacts or {}) do
    if
      type(artifact) ~= "table"
      or type(artifact.path) ~= "string"
      or artifact.path == ""
    then
      return nil, file_error("cmake-file-api-target", path, "has an invalid artifact")
    end
    if is_absolute(artifact.path) then
      artifacts[#artifacts + 1] = vim.fs.normalize(artifact.path)
    else
      artifacts[#artifacts + 1] = vim.fs.normalize(build_dir .. "/" .. artifact.path)
    end
  end

  local record = {
    name = name,
    type = target.type,
    source_dir = vim.fs.normalize(source_dir),
    build_dir = vim.fs.normalize(build_dir),
    artifacts = artifacts,
  }
  if target.link and target.link.commandFragments ~= nil then
    if not is_dense_array(target.link.commandFragments) then
      return nil,
        file_error(
          "cmake-file-api-target",
          path,
          "has invalid linker command fragments"
        )
    end
    record.linker_command_fragments = {}
    for _, fragment in ipairs(target.link.commandFragments) do
      if type(fragment) ~= "table" or type(fragment.fragment) ~= "string" then
        return nil,
          file_error(
            "cmake-file-api-target",
            path,
            "has invalid linker command fragments"
          )
      end
      record.linker_command_fragments[#record.linker_command_fragments + 1] =
        fragment.fragment
    end
  end
  return record
end

local function query_directory(binary_dir)
  local root = vim.fs.normalize(binary_dir)
  local mkdir_ok, mkdir_result = pcall(vim.fn.mkdir, root, "p")
  if not mkdir_ok or (mkdir_result ~= 1 and vim.fn.isdirectory(root) ~= 1) then
    return nil
  end
  local root_real = vim.uv.fs_realpath(root)
  if not root_real then
    return nil
  end

  local current = root_real
  for _, part in ipairs({ ".cmake", "api", "v1", "query", "client-nvim-stm32" }) do
    local path = current .. "/" .. part
    local stat = vim.uv.fs_lstat(path)
    if stat then
      if stat.type ~= "directory" and stat.type ~= "link" then
        return nil
      end
    else
      local child_ok, child_result = pcall(vim.fn.mkdir, path)
      if not child_ok or child_result ~= 1 then
        return nil
      end
    end
    current = vim.uv.fs_realpath(path)
    if not current or not path_is_within(root_real, current) then
      return nil
    end
  end
  return current
end

local function query_file_is_safe(path)
  local stat = vim.uv.fs_lstat(path)
  return not stat or stat.type ~= "link"
end

function M.write_query(binary_dir)
  local query_path = binary_dir .. "/.cmake/api/v1/query/client-nvim-stm32/query.json"
  local query_dir = query_directory(binary_dir)
  if not query_dir then
    return nil,
      file_error("cmake-file-api-query", query_path, "could not create query directory")
  end
  local write_path = query_dir .. "/query.json"
  local temp_path = write_path .. ".tmp"
  if not query_file_is_safe(write_path) or not query_file_is_safe(temp_path) then
    return nil,
      file_error("cmake-file-api-query", query_path, "refuses a symlinked query path")
  end
  local contents =
    vim.json.encode({ requests = { { kind = "codemodel", version = 2 } } })
  local write_ok, write_result = pcall(vim.fn.writefile, { contents }, temp_path)
  if not write_ok or write_result ~= 0 then
    return nil, file_error("cmake-file-api-query", temp_path, "could not write query")
  end
  local renamed, rename_err = vim.uv.fs_rename(temp_path, write_path)
  if not renamed then
    return nil,
      file_error(
        "cmake-file-api-query",
        query_path,
        "could not rename query: " .. rename_err
      )
  end
  return query_path
end

function M.reply(binary_dir)
  local reply_dir = binary_dir .. "/.cmake/api/v1/reply"
  local codemodel, codemodel_path = newest_codemodel(reply_dir)
  if not codemodel then
    return nil, codemodel_path
  end

  local reply = { targets = {} }
  for _, configuration in ipairs(codemodel.configurations) do
    if type(configuration) ~= "table" or type(configuration.targets) ~= "table" then
      return nil,
        file_error(
          "cmake-file-api-codemodel",
          codemodel_path,
          "has invalid configurations"
        )
    end
    local directories = configuration.directories or {}
    if type(directories) ~= "table" then
      return nil,
        file_error(
          "cmake-file-api-codemodel",
          codemodel_path,
          "has invalid directories"
        )
    end
    local resolved_directories = {}
    for index, directory in ipairs(directories) do
      local source_dir =
        resolve_path(codemodel.paths and codemodel.paths.source, directory.source)
      local build_dir =
        resolve_path(codemodel.paths and codemodel.paths.build, directory.build)
      if not source_dir or not build_dir then
        return nil,
          file_error(
            "cmake-file-api-codemodel",
            codemodel_path,
            "has a directory outside its codemodel paths"
          )
      end
      resolved_directories[index] = { source = source_dir, build = build_dir }
    end
    for _, target_ref in ipairs(configuration.targets) do
      if type(target_ref) ~= "table" then
        return nil,
          file_error(
            "cmake-file-api-codemodel",
            codemodel_path,
            "has an invalid target reference"
          )
      end
      local target, target_err =
        target_record(reply_dir, codemodel_path, resolved_directories, target_ref)
      if target_err then
        return nil, target_err
      end
      if target then
        reply.targets[#reply.targets + 1] = target
      end
    end
  end
  return reply
end

return M
