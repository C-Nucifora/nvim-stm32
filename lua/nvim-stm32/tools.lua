--- nvim-stm32: finding the external programs, and the environment to run them in.
---
--- Resolution order for every tool is the same: an explicit path from the
--- config, then $PATH, then the known install locations. STM32_Programmer_CLI
--- is the reason the third step exists at all; ST never puts it on $PATH.
local M = {}

--- Where a tool lives when it is not on $PATH. Adding a platform or an install
--- layout is a new entry, never a branch in code.
---@type table<string, string[]>
M.globs = {
  STM32_Programmer_CLI = {
    "~/Library/Application Support/stm32cube/bundles/programmer/*/bin/STM32_Programmer_CLI",
    "/Applications/STMicroelectronics/STM32Cube/STM32CubeProgrammer/STM32CubeProgrammer.app/Contents/MacOs/bin/STM32_Programmer_CLI",
    "~/STMicroelectronics/STM32Cube/STM32CubeProgrammer/bin/STM32_Programmer_CLI",
    "/opt/st/stm32cubeprogrammer/bin/STM32_Programmer_CLI",
  },
}

--- Sort version-bearing paths newest first.
---
--- Called on the matches of a single glob, where every path differs only in its
--- version directory, so comparing the runs of digits in order is a version
--- compare. A string sort is not: it puts ".../2.9.0/..." above ".../2.23.0/...".
---@param paths string[]
---@return string[]  a new list, newest first
function M.by_version_desc(paths)
  local function digits(p)
    local out = {}
    for n in p:gmatch("%d+") do
      out[#out + 1] = tonumber(n)
    end
    return out
  end

  local sorted = vim.deepcopy(paths)
  table.sort(sorted, function(a, b)
    local da, db = digits(a), digits(b)
    for i = 1, math.max(#da, #db) do
      local x, y = da[i] or -1, db[i] or -1
      if x ~= y then
        return x > y
      end
    end
    return a > b
  end)
  return sorted
end

--- Locate an executable.
---@param name string          basename to look for on $PATH
---@param override string|nil  explicit path from the config
---@param globs string[]|nil   install-location patterns; defaults to M.globs[name]
---@return string|nil
function M.resolve(name, override, globs)
  if override and override ~= "" then
    local path = vim.fs.normalize(override)
    return vim.fn.executable(path) == 1 and path or nil
  end

  local on_path = vim.fn.exepath(name)
  if on_path ~= "" then
    return on_path
  end

  for _, pattern in ipairs(globs or M.globs[name] or {}) do
    local hits = M.by_version_desc(vim.fn.glob(vim.fs.normalize(pattern), false, true))
    for _, hit in ipairs(hits) do
      if vim.fn.executable(hit) == 1 then
        return hit
      end
    end
  end

  return nil
end

--- $PATH for child processes, with the configured toolchain directory in front.
---
--- The zsh function this plugin replaces does exactly this. Dropping it is what
--- turns a working setup into "arm-none-eabi-gcc: not found" from inside Neovim
--- while the same build works in a terminal.
---@param cfg Stm32Config
---@return string
function M.child_path(cfg)
  local path = vim.env.PATH or ""
  if cfg.toolchain_path and cfg.toolchain_path ~= "" then
    return cfg.toolchain_path .. ":" .. path
  end
  return path
end

--- Environment overlay for vim.system(). Without `clear_env`, vim.system merges
--- this over the parent environment, so PATH alone is enough.
---@param cfg Stm32Config
---@return table<string, string>
function M.env(cfg)
  return { PATH = M.child_path(cfg) }
end

--- STM32_Programmer_CLI, or nil.
---@param cfg Stm32Config
---@return string|nil
function M.programmer(cfg)
  return M.resolve("STM32_Programmer_CLI", cfg.programmer_path)
end

--- Resolve a tool that ships inside the ARM toolchain: an explicit override
--- first, then toolchain_path, then $PATH.
---
--- toolchain_path exists precisely for users whose ARM toolchain is not on
--- Neovim's $PATH, so it has to be tried before $PATH, not after: a bare
--- $PATH lookup would report the tool missing in the one setup the option
--- exists to serve.
---@param name string           basename to look for, e.g. "arm-none-eabi-gcc"
---@param cfg Stm32Config
---@param override string|nil   explicit path from the config, if any
---@return string|nil
local function resolve_toolchain(name, cfg, override)
  if override then
    return M.resolve(name, override)
  end
  if cfg.toolchain_path then
    local bundled = cfg.toolchain_path .. "/" .. name
    if vim.fn.executable(bundled) == 1 then
      return bundled
    end
  end
  return M.resolve(name, nil)
end

--- arm-none-eabi-gcc, or nil. There is no gcc_path config key: toolchain_path
--- is the documented override for the compiler. See resolve_toolchain().
---@param cfg Stm32Config
---@return string|nil
function M.gcc(cfg)
  return resolve_toolchain("arm-none-eabi-gcc", cfg, nil)
end

--- arm-none-eabi-gdb, or nil. Looks in toolchain_path first: the ARM toolchain
--- ships its own gdb and a system gdb cannot debug a Cortex-M target.
---@param cfg Stm32Config
---@return string|nil
function M.gdb(cfg)
  return resolve_toolchain("arm-none-eabi-gdb", cfg, cfg.gdb_path)
end

--- openocd, or nil.
---@param cfg Stm32Config
---@return string|nil
function M.openocd(cfg)
  return M.resolve("openocd", cfg.openocd_path)
end

--- st-flash (stlink-tools), or nil.
---@param cfg Stm32Config
---@return string|nil
function M.stlink(cfg)
  return M.resolve("st-flash", cfg.stlink_path)
end

return M
