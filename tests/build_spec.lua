local build = require("nvim-stm32.backend.build")
local float = require("nvim-stm32.ui.float")
local plugin = require("nvim-stm32")
local process = require("nvim-stm32.process")
local session = require("nvim-stm32.session")

local function fixture(rel)
  local here =
    vim.fn.fnamemodify(vim.fn.resolve(debug.getinfo(1, "S").source:sub(2)), ":p:h")
  return here .. "/fixtures/" .. rel
end

describe("nvim-stm32 build command resolution", function()
  it("configures before compiling preset CMake projects", function()
    local commands = assert(build.commands({ build_backend = "cmake_presets" }, {
      preset = "Debug",
    }))
    assert.same({
      { "cmake", "--preset", "Debug" },
      { "cmake", "--build", "--preset", "Debug" },
    }, commands)
  end)

  it("configures before compiling plain CMake projects", function()
    local commands = assert(build.commands({ build_backend = "cmake_plain" }, {}))
    assert.same({
      { "cmake", "-S", ".", "-B", "build" },
      { "cmake", "--build", "build" },
    }, commands)
  end)

  it("runs one command for Make projects", function()
    assert.same({ { "make" } }, (build.commands({ build_backend = "make" }, {})))
  end)

  it("rejects an unknown backend", function()
    local commands, err = build.commands({ build_backend = "mystery" }, {})
    assert.is_nil(commands)
    assert.matches("unknown build backend", err, 1, true)
  end)

  it(
    "returns a string error for an explicit preset with malformed preset JSON",
    function()
      local root = vim.fn.tempname()
      vim.fn.mkdir(root, "p")
      vim.fn.writefile({ "not json" }, root .. "/CMakePresets.json")

      local commands, err = build.commands(
        { root = root, build_backend = "cmake_presets" },
        {
          preset = "Debug",
        }
      )
      assert.is_nil(commands)
      assert.equals("string", type(err))
      assert.matches("invalid JSON", err, 1, true)
      vim.fn.delete(root, "rf")
    end
  )
end)

describe("nvim-stm32 ELF discovery", function()
  local root

  before_each(function()
    root = vim.fn.tempname()
    vim.fn.mkdir(root .. "/build", "p")
  end)

  after_each(function()
    session.clear()
    vim.fn.delete(root, "rf")
  end)

  it("returns the sole ELF from a nested plain build directory", function()
    vim.fn.mkdir(root .. "/build/bin", "p")
    local elf = root .. "/build/bin/firmware.elf"
    vim.fn.writefile({ "elf" }, elf)

    assert.equals(
      elf,
      (build.find_elf({ root = root, build_backend = "cmake_plain" }, {}))
    )
  end)

  it("searches only the selected preset directory", function()
    vim.fn.mkdir(root .. "/build/Debug", "p")
    vim.fn.mkdir(root .. "/build/Release", "p")
    local elf = root .. "/build/Debug/firmware.elf"
    vim.fn.writefile({ "debug" }, elf)
    vim.fn.writefile({ "release" }, root .. "/build/Release/firmware.elf")

    assert.equals(
      elf,
      (
        build.find_elf({ root = root, build_backend = "cmake_presets" }, {
          preset = "Debug",
        })
      )
    )
  end)

  it("reports when no ELF exists", function()
    local elf, err = build.find_elf({ root = root, build_backend = "make" }, {})
    assert.is_nil(elf)
    assert.matches("no .elf", err, 1, true)
  end)

  it("refuses to guess when several ELF files exist", function()
    vim.fn.writefile({ "one" }, root .. "/build/one.elf")
    vim.fn.writefile({ "two" }, root .. "/build/two.elf")

    local elf, err = build.find_elf({ root = root, build_backend = "make" }, {})
    assert.is_nil(elf)
    assert.matches("cannot map artifact", err, 1, true)
  end)

  it("uses selected-image artifacts when they are supplied", function()
    vim.fn.writefile({ "app" }, root .. "/build/app.elf")
    vim.fn.writefile({ "other" }, root .. "/build/other.elf")

    assert.equals(
      root .. "/build/app.elf",
      (
        build.find_elf(
          { root = root, build_backend = "make", image_id = "application" },
          {
            artifacts = {
              {
                image_id = "application",
                kind = "elf",
                path = root .. "/build/app.elf",
              },
              {
                image_id = "other",
                kind = "elf",
                path = root .. "/build/other.elf",
              },
            },
          }
        )
      )
    )
  end)

  it("uses the session artifact view for compatibility lookup", function()
    local elf = root .. "/artifacts/app.elf"
    vim.fn.mkdir(root .. "/artifacts", "p")
    vim.fn.writefile({ "app" }, elf)
    session.record(root, {
      artifacts = {
        {
          image_id = "application",
          kind = "elf",
          path = elf,
          configuration = "Debug",
          build_target = "app",
          modified_ns = 1,
        },
      },
    })

    assert.equals(elf, build.find_elf({ root = root, build_backend = "make" }, {}))
  end)

  it("restricts the session artifact view to the selected configuration", function()
    local debug_elf = root .. "/artifacts/Debug/app.elf"
    local release_elf = root .. "/artifacts/Release/app.elf"
    vim.fn.mkdir(vim.fs.dirname(debug_elf), "p")
    vim.fn.mkdir(vim.fs.dirname(release_elf), "p")
    vim.fn.writefile({ "debug" }, debug_elf)
    vim.fn.writefile({ "release" }, release_elf)
    session.select(root, { image_id = "application", configuration = "Debug" })
    session.record(root, {
      artifacts = {
        {
          image_id = "application",
          kind = "elf",
          path = debug_elf,
          configuration = "Debug",
          build_target = "app",
          modified_ns = 1,
        },
        {
          image_id = "application",
          kind = "elf",
          path = release_elf,
          configuration = "Release",
          build_target = "app",
          modified_ns = 2,
        },
      },
    })

    assert.equals(
      debug_elf,
      build.find_elf({ root = root, build_backend = "make" }, {})
    )
  end)
end)

describe("nvim-stm32 build execution", function()
  local original_process_run
  local original_float_open
  local original_config
  local presenter
  local captured

  before_each(function()
    original_process_run = process.run
    original_float_open = float.open
    original_config = plugin.config
    captured = nil
    presenter = { chunks = {}, finished = nil }
    function presenter:append(chunk)
      self.chunks[#self.chunks + 1] = chunk
    end
    function presenter:finish(ok)
      self.finished = ok
    end
    float.open = function(target, config)
      captured = { target = target, config = config }
      return presenter
    end
    plugin.setup({ toolchain_path = "/toolchain" })
  end)

  after_each(function()
    process.run = original_process_run
    float.open = original_float_open
    plugin.config = original_config
  end)

  it("streams a successful build and assigns its ELF", function()
    local root = vim.fn.tempname()
    vim.fn.mkdir(root .. "/build", "p")
    local elf = root .. "/build/firmware.elf"
    vim.fn.writefile({ "elf" }, elf)
    local target = { root = root, build_backend = "cmake_plain", mcu = "STM32F429ZITx" }
    local done

    process.run = function(commands, opts, callback)
      captured.commands = commands
      captured.process_opts = opts
      opts.on_output("building\n")
      callback({ code = 0, signal = 0, output = "building\n", command = commands[2] })
    end

    build.run(target, {}, function(result)
      done = result
    end)

    assert.equals(root, captured.process_opts.cwd)
    assert.equals("/toolchain:", captured.process_opts.env.PATH:sub(1, #"/toolchain:"))
    assert.same({ "building\n" }, presenter.chunks)
    assert.equals(elf, target.elf)
    assert.is_true(presenter.finished)
    assert.is_true(done.ok)
    assert.equals(elf, done.elf)
    vim.fn.delete(root, "rf")
  end)

  it("keeps the presenter open when the process fails", function()
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
    local target = { root = root, build_backend = "make", mcu = "STM32F429ZITx" }
    local done

    process.run = function(commands, _, callback)
      callback({ code = 2, signal = 0, output = "bad", command = commands[1] })
    end

    build.run(target, {}, function(result)
      done = result
    end)

    assert.is_false(presenter.finished)
    assert.is_false(done.ok)
    assert.equals(2, done.code)
    assert.is_nil(target.elf)
    vim.fn.delete(root, "rf")
  end)

  it("treats a missing ELF as a failed plugin result", function()
    local root = vim.fn.tempname()
    vim.fn.mkdir(root .. "/build", "p")
    local target = { root = root, build_backend = "make", mcu = "STM32F429ZITx" }
    local done

    process.run = function(commands, _, callback)
      callback({ code = 0, signal = 0, output = "done", command = commands[1] })
    end

    build.run(target, {}, function(result)
      done = result
    end)

    assert.is_false(presenter.finished)
    assert.is_false(done.ok)
    assert.matches("no .elf", done.error, 1, true)
    vim.fn.delete(root, "rf")
  end)
end)

describe("nvim-stm32 current build", function()
  local operations = require("nvim-stm32.operations.build")

  after_each(function()
    pcall(vim.cmd, "bwipeout!")
  end)

  it("delegates current builds to the operation implementation", function()
    local original_current = operations.current
    local captured
    operations.current = function(opts, callback)
      captured = { opts = opts, callback = callback }
      return { id = 17 }
    end
    local callback = function() end

    local handle = build.current({ configuration = "Debug" }, callback)

    operations.current = original_current
    assert.equals(17, handle.id)
    assert.equals("Debug", captured.opts.configuration)
    assert.equals(callback, captured.callback)
  end)
end)

describe("nvim-stm32 preset error presentation", function()
  local discovery = require("nvim-stm32.discover.project")
  local original_resolve
  local original_notify

  before_each(function()
    original_resolve = discovery.resolve
    original_notify = vim.notify
  end)

  after_each(function()
    discovery.resolve = original_resolve
    vim.notify = original_notify
  end)

  it("notifies with a string when the preset picker cannot load presets", function()
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
    vim.fn.writefile({ "not json" }, root .. "/CMakePresets.json")
    local notification
    discovery.resolve = function()
      return {
        id = root,
        root = root,
        kind = "cmake_presets",
        build = { adapter = "cmake_presets" },
        images = {
          { id = "application", name = "application", target = {} },
        },
      }
    end
    vim.notify = function(message, level)
      assert.equals("string", type(message))
      notification = { message = message, level = level }
    end

    local ok, err = pcall(build.current)
    assert.is_true(ok, err)
    assert.matches("invalid JSON", notification.message, 1, true)
    assert.equals(vim.log.levels.ERROR, notification.level)
    vim.fn.delete(root, "rf")
  end)
end)

describe(":STM32Build", function()
  it("is registered by the plugin shim", function()
    pcall(vim.api.nvim_del_user_command, "STM32Info")
    pcall(vim.api.nvim_del_user_command, "STM32Build")
    vim.g.loaded_nvim_stm32 = nil
    vim.cmd("runtime plugin/nvim-stm32.lua")

    assert.equals(2, vim.fn.exists(":STM32Build"))
  end)
end)
