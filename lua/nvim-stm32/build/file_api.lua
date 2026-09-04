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

local function path_in_reply(reply_dir, name)
  if type(name) ~= "string" or name == "" then
    return nil
  end
  local root = vim.fs.normalize(reply_dir)
  local path = vim.fs.normalize(root .. "/" .. name)
  if path == root or path:sub(1, #root + 1) ~= root .. "/" then
    return nil
  end
  return path
end

local function is_absolute(path)
  return path:sub(1, 1) == "/"
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
            if
              codemodel
              and codemodel.kind == "codemodel"
              and type(codemodel.version) == "table"
              and codemodel.version.major == 2
              and type(codemodel.configurations) == "table"
            then
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
  if target.type ~= "EXECUTABLE" then
    return false
  end

  local directory = {}
  if type(target_ref.directoryIndex) == "number" then
    directory = directories[target_ref.directoryIndex + 1] or {}
  end
  local paths = target.paths or {}
  local source_dir = paths.source or directory.source
  local build_dir = paths.build or directory.build
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
  if target.link and target.link.commandFragments then
    if type(target.link.commandFragments) ~= "table" then
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

function M.write_query(binary_dir)
  local query_dir = binary_dir .. "/.cmake/api/v1/query/client-nvim-stm32"
  local query_path = query_dir .. "/query.json"
  local temp_path = query_path .. ".tmp"
  local mkdir_ok, mkdir_result = pcall(vim.fn.mkdir, query_dir, "p")
  if not mkdir_ok or (mkdir_result ~= 1 and vim.fn.isdirectory(query_dir) ~= 1) then
    return nil,
      file_error("cmake-file-api-query", query_dir, "could not create query directory")
  end
  local contents =
    vim.json.encode({ requests = { { kind = "codemodel", version = 2 } } })
  local write_ok, write_result = pcall(vim.fn.writefile, { contents }, temp_path)
  if not write_ok or write_result ~= 0 then
    return nil, file_error("cmake-file-api-query", temp_path, "could not write query")
  end
  local renamed, rename_err = vim.uv.fs_rename(temp_path, query_path)
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
        target_record(reply_dir, codemodel_path, directories, target_ref)
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
