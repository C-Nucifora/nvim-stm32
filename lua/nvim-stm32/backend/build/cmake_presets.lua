local M = {}

function M.available()
  return vim.fn.executable("cmake") == 1
end

function M.configure_cmd(_, opts)
  local preset = assert(opts.preset, "preset is required")
  return { "cmake", "--preset", preset }
end

function M.cmd(_, opts)
  local preset = assert(opts.preset, "preset is required")
  return { "cmake", "--build", "build/" .. preset }
end

function M.parse(output, code)
  return { ok = code == 0, code = code, output = output }
end

function M.presets(root)
  local path = root .. "/CMakePresets.json"
  local read_ok, lines = pcall(vim.fn.readfile, path)
  if not read_ok then
    return nil, "could not read " .. path
  end

  local decode_ok, document = pcall(vim.json.decode, table.concat(lines, "\n"))
  if not decode_ok or type(document) ~= "table" then
    return nil, "invalid CMakePresets.json in " .. root
  end

  local source = document.buildPresets or document.configurePresets or {}
  local names = {}
  for _, preset in ipairs(source) do
    if type(preset.name) == "string" and not preset.hidden then
      names[#names + 1] = preset.name
    end
  end
  return names
end

return M
