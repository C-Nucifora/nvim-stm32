--- nvim-stm32: `:checkhealth nvim-stm32`.
---
--- Answers the two questions a broken setup raises: which external programs did
--- the plugin find, and which optional Neovim plugins is it able to use.
local M = {}

local h = vim.health

function M.cmake_project_status(project, opts)
  opts = opts or {}
  local cmake_path = opts.cmake_path
  if cmake_path == nil then
    cmake_path = vim.fn.exepath("cmake")
  end
  if cmake_path == "" then
    return "warn", "cmake not found; project configuration cannot run"
  end

  local adapter = project.build and project.build.adapter or project.kind
  if adapter ~= "cmake_presets" and adapter ~= "cmake_plain" then
    return "info", "CMake File API does not apply to this build backend"
  end

  local binary_dir = opts.binary_dir
  if not binary_dir and adapter == "cmake_presets" then
    local configurations, configuration_err =
      require("nvim-stm32.build.presets").configurations(project.root)
    if not configurations then
      return "warn", "CMake configurations are malformed: " .. configuration_err.message
    end
    local selected = require("nvim-stm32.session").get(project).configuration
    for _, configuration in ipairs(configurations) do
      if configuration.name == selected or (#configurations == 1 and not selected) then
        binary_dir = configuration.binary_dir
        break
      end
    end
    if not binary_dir then
      return "info", "CMake configuration not selected"
    end
  end
  binary_dir = binary_dir or project.root .. "/build"
  local reply_dir = binary_dir .. "/.cmake/api/v1/reply"
  if #vim.fn.glob(reply_dir .. "/index-*.json", false, true) == 0 then
    return "info", "CMake File API reply absent; project is not configured yet"
  end
  local reply, reply_err = require("nvim-stm32.build.file_api").reply(binary_dir)
  if not reply then
    return "warn", "CMake File API reply is malformed: " .. reply_err.message
  end
  return "ok", ("CMake File API reply: %d executable target(s)"):format(#reply.targets)
end

--- Classify a resolved tool path.
---
--- Pure, so the specs pin the wording without a real toolchain on the runner,
--- and so a missing tool always reports the config key that overrides its path
--- instead of a bare "not found".
--- `path == ""` counts as not found: vim.fn.exepath() returns "" rather than
--- nil for a missing program, and an unguarded `if path then` would treat that
--- as truthy and print an ok line with nothing after the colon.
---@param label string        the program's name, as the user would type it
---@param path string|nil     the resolved path, "", or nil
---@param opt_key string|nil  config key that overrides this path
---@return "ok"|"warn" level, string msg, string[]|nil advice
function M.tool_status(label, path, opt_key)
  if path and path ~= "" then
    return "ok", label .. ": " .. path
  end
  local advice = opt_key
      and { ("Install %s, or set opts.%s to its path."):format(label, opt_key) }
    or { ("Install %s and put it on $PATH."):format(label) }
  return "warn", label .. " not found", advice
end

function M.monitor_status(cfg, opts)
  opts = opts or {}
  local devices = require("nvim-stm32.monitor.devices")
  local platform = devices.platform(opts)
  local supported = devices.pattern(platform) ~= nil
  local statuses = {
    supported and { level = "ok", message = "UART platform: " .. platform } or {
      level = "warn",
      message = "UART platform unsupported: " .. tostring(platform),
    },
  }

  local exepath = opts.exepath or vim.fn.exepath
  for _, name in ipairs({ "stty", "cat" }) do
    local level, message = M.tool_status(name, exepath(name), nil)
    statuses[#statuses + 1] = { level = level, message = message }
  end

  local configured = cfg.monitor and cfg.monitor.device or nil
  if not configured then
    statuses[#statuses + 1] = {
      level = "info",
      message = "configured UART device: none",
    }
  elseif not supported then
    statuses[#statuses + 1] = {
      level = "warn",
      message = "configured UART device unavailable: " .. configured,
    }
  elseif devices.validate(configured, opts) then
    statuses[#statuses + 1] = {
      level = "ok",
      message = "configured UART device: " .. configured,
    }
  else
    statuses[#statuses + 1] = {
      level = "warn",
      message = "configured UART device unavailable: " .. configured,
    }
  end

  local candidates, candidates_err
  if supported then
    candidates, candidates_err = devices.list(opts)
  else
    candidates_err = true
  end
  statuses[#statuses + 1] = {
    level = "info",
    message = candidates_err and "UART candidates: unavailable"
      or #candidates == 0 and "UART candidates: none"
      or "UART candidates: " .. table.concat(candidates, ", "),
  }
  return statuses
end

--- Render one tool_status verdict.
---@param label string
---@param path string|nil
---@param opt_key string|nil
local function report_tool(label, path, opt_key)
  local level, msg, advice = M.tool_status(label, path, opt_key)
  if level == "ok" then
    h.ok(msg)
  else
    h.warn(msg, advice)
  end
end

function M.check()
  local cfg = require("nvim-stm32").get_config()
  local tools = require("nvim-stm32.tools")

  h.start("nvim-stm32: Neovim")
  if vim.fn.has("nvim-0.11") == 1 then
    h.ok("Neovim " .. tostring(vim.version()))
  else
    h.error("Neovim >= 0.11 required")
  end
  if vim.fn.has("win32") == 1 then
    h.error("Windows is not supported; nvim-stm32 targets macOS and Linux")
  end

  h.start("nvim-stm32: detected project")
  local previous = vim.fn.bufname("#")
  local start = previous ~= ""
      and previous ~= "health://"
      and vim.fn.fnamemodify(previous, ":p:h")
    or nil
  local project, detection_error = require("nvim-stm32.discover.project").resolve(start)
  if not project then
    h.info(detection_error.message or tostring(detection_error))
  else
    h.ok("project: " .. project.id)
    h.info("build backend: " .. (project.build.adapter or project.kind or "none"))
    for _, image in ipairs(project.images) do
      local target = image.target or {}
      if target.mcu then
        local report = target.confidence == "exact" and h.ok or h.warn
        report(
          ("image %s MCU: %s (%s)"):format(
            image.id,
            target.mcu,
            target.confidence or "unknown"
          )
        )
      else
        h.warn("image " .. image.id .. " MCU not resolved", {
          "Add a CubeMX .ioc, a startup file or a named linker script to the project.",
        })
      end
    end
    local cmake_level, cmake_message = M.cmake_project_status(project)
    if cmake_level == "ok" then
      h.ok(cmake_message)
    elseif cmake_level == "warn" then
      h.warn(cmake_message)
    else
      h.info(cmake_message)
    end
  end

  h.start("nvim-stm32: build tools")
  if cfg.toolchain_path then
    h.info("toolchain_path: " .. cfg.toolchain_path)
  else
    h.info("toolchain_path unset; children inherit $PATH")
  end
  report_tool("arm-none-eabi-gcc", tools.gcc(cfg), "toolchain_path")
  report_tool("cmake", vim.fn.exepath("cmake"), nil)
  for _, gen in ipairs({ "ninja", "make" }) do
    local path = vim.fn.exepath(gen)
    if path ~= "" then
      h.ok(gen .. ": " .. path)
    else
      h.info(gen .. " not found")
    end
  end

  h.start("nvim-stm32: programmers")
  report_tool("STM32_Programmer_CLI", tools.programmer(cfg), "programmer_path")
  report_tool("st-flash", tools.stlink(cfg), "stlink_path")
  report_tool("openocd", tools.openocd(cfg), "openocd_path")
  if cfg.flash_backend then
    h.info("flash_backend pinned to " .. cfg.flash_backend)
  else
    h.info("flash probe order: " .. table.concat(cfg.flash_order, ", "))
  end

  h.start("nvim-stm32: UART monitor")
  for _, status in ipairs(M.monitor_status(cfg)) do
    if status.level == "ok" then
      h.ok(status.message)
    elseif status.level == "warn" then
      h.warn(status.message)
    else
      h.info(status.message)
    end
  end

  h.start("nvim-stm32: debug")
  report_tool("arm-none-eabi-gdb", tools.gdb(cfg), "gdb_path")

  h.start("nvim-stm32: optional integrations")
  for _, mod in ipairs({
    {
      "snacks",
      "floats and notifications; a plain nvim_open_win float is used without it",
    },
    { "dap", "debugging" },
    { "dap-cortex-debug", "richer debugging, RTT and SVD support" },
    { "compiler", "STM32 entries in the compiler.nvim picker" },
  }) do
    if pcall(require, mod[1]) then
      h.ok(mod[1] .. ": " .. mod[2])
    else
      h.info(mod[1] .. " not installed, so no " .. mod[2])
    end
  end
end

return M
