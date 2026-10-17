local model = require("nvim-stm32.model")
local operation = require("nvim-stm32.operation")
local build = require("nvim-stm32.operations.build")
local process = require("nvim-stm32.process")
local session = require("nvim-stm32.session")

local function write_presets(root)
  vim.fn.writefile({
    vim.json.encode({
      version = 3,
      configurePresets = {
        { name = "Debug", binaryDir = "${sourceDir}/build/Debug" },
      },
      buildPresets = {
        { name = "Debug", configurePreset = "Debug" },
      },
    }),
  }, root .. "/CMakePresets.json")
end

local function project(root, adapter)
  return model.project({
    id = root,
    root = root,
    kind = adapter,
    build = { adapter = adapter, marker = root .. "/CMakeLists.txt" },
    images = {
      {
        id = "application",
        name = "application",
        build_target = "app",
        target = { mcu = "STM32F429ZITx" },
      },
    },
  })
end

local function artifact(root, image_id, configuration, kind)
  return model.artifact({
    image_id = image_id,
    configuration = configuration,
    kind = kind,
    path = root .. "/build/" .. image_id .. "." .. kind,
    build_target = image_id,
    modified_ns = 1,
    build_id = "build-old",
  })
end

describe("nvim-stm32 build lifecycle", function()
  local root
  local original_process_run
  local original_executable

  before_each(function()
    root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
    write_presets(root)
    session.clear()
    original_process_run = process.run
    original_executable = vim.fn.executable
  end)

  after_each(function()
    process.run = original_process_run
    vim.fn.executable = original_executable
    session.clear()
    vim.fn.delete(root, "rf")
  end)

  it("keeps omitted mode and explicit build mode identical", function()
    local implicit = assert(build.plan(project(root, "cmake_presets"), {
      configuration = "Debug",
    }))
    local explicit = assert(build.plan(project(root, "cmake_presets"), {
      configuration = "Debug",
      mode = "build",
    }))

    assert.same(implicit.commands, explicit.commands)
    assert.equals("build", implicit.metadata.mode)
    assert.equals("build", explicit.metadata.mode)
  end)

  it("plans clean commands for every build adapter", function()
    local preset = assert(build.plan(project(root, "cmake_presets"), {
      configuration = "Debug",
      mode = "clean",
    }))
    local plain = assert(build.plan(project(root, "cmake_plain"), {
      mode = "clean",
    }))
    local make = assert(build.plan(project(root, "make"), { mode = "clean" }))

    assert.same(
      {
        { "cmake", "--build", "--preset", "Debug", "--target", "clean" },
      },
      vim.tbl_map(function(command)
        return command.argv
      end, preset.commands)
    )
    assert.same(
      {
        { "cmake", "--build", "build", "--target", "clean" },
      },
      vim.tbl_map(function(command)
        return command.argv
      end, plain.commands)
    )
    assert.same(
      { { "make", "clean" } },
      vim.tbl_map(function(command)
        return command.argv
      end, make.commands)
    )
  end)

  it("plans rebuild as clean, configure when applicable, and build", function()
    local preset = assert(build.plan(project(root, "cmake_presets"), {
      configuration = "Debug",
      mode = "rebuild",
    }))
    local plain = assert(build.plan(project(root, "cmake_plain"), {
      mode = "rebuild",
    }))
    local make = assert(build.plan(project(root, "make"), { mode = "rebuild" }))

    assert.same(
      {
        { "cmake", "--build", "--preset", "Debug", "--target", "clean" },
        { "cmake", "--preset", "Debug" },
        { "cmake", "--build", "--preset", "Debug", "--target", "app" },
      },
      vim.tbl_map(function(command)
        return command.argv
      end, preset.commands)
    )
    assert.same(
      {
        { "cmake", "--build", "build", "--target", "clean" },
        { "cmake", "-S", ".", "-B", "build" },
        { "cmake", "--build", "build", "--target", "app" },
      },
      vim.tbl_map(function(command)
        return command.argv
      end, plain.commands)
    )
    assert.same(
      { { "make", "clean" }, { "make" } },
      vim.tbl_map(function(command)
        return command.argv
      end, make.commands)
    )
  end)

  it("rejects an unknown lifecycle mode", function()
    local plan, err = build.plan(project(root, "make"), { mode = "scrub" })

    assert.is_nil(plan)
    assert.equals("build-mode-invalid", err.code)
  end)

  it("removes only selected artifacts after a successful clean", function()
    local selected = artifact(root, "application", "Debug", "elf")
    local other_config = artifact(root, "application", "Release", "elf")
    local other_image = artifact(root, "boot", "Debug", "elf")
    session.select(root, { artifacts = { selected, other_config, other_image } })
    local previous = session.record(root, {
      ok = true,
      code = 0,
      output = "built",
      artifacts = { selected },
      metadata = { operation_id = "build-old" },
    }).last_result
    local planned = assert(build.plan(project(root, "cmake_presets"), {
      configuration = "Debug",
      mode = "clean",
    }))
    local result
    vim.fn.executable = function()
      return 1
    end
    process.run = function(_, _, callback)
      callback({ code = 0, signal = 0, output = "cleaned" })
      return { id = 1 }
    end

    operation.run(planned, {}, function(value)
      result = value
    end)

    assert.is_true(result.ok, vim.inspect(result))
    assert.same({}, result.artifacts)
    assert.same({ other_config, other_image }, session.get(root).artifacts)
    assert.same(previous, session.get(root).last_result)
    assert.equals(0, vim.fn.filereadable(planned.metadata.query_path))
  end)

  it("keeps prior artifacts when clean fails", function()
    local selected = artifact(root, "application", "Debug", "elf")
    session.select(root, { artifacts = { selected } })
    local planned = assert(build.plan(project(root, "cmake_presets"), {
      configuration = "Debug",
      mode = "clean",
    }))
    local result
    vim.fn.executable = function()
      return 1
    end
    process.run = function(_, _, callback)
      callback({ code = 2, signal = 0, output = "clean failed" })
      return { id = 2 }
    end

    operation.run(planned, {}, function(value)
      result = value
    end)

    assert.is_false(result.ok)
    assert.same({ selected }, session.get(root).artifacts)
  end)

  it("keeps prior artifacts when clean exits zero after SIGTERM", function()
    local selected = artifact(root, "application", "Debug", "elf")
    session.select(root, { artifacts = { selected } })
    local planned = assert(build.plan(project(root, "cmake_presets"), {
      configuration = "Debug",
      mode = "clean",
    }))
    local result
    vim.fn.executable = function()
      return 1
    end
    process.run = function(_, _, callback)
      callback({ code = 0, signal = 15, output = "terminated" })
      return { id = 3 }
    end

    operation.run(planned, {}, function(value)
      result = value
    end)

    assert.is_false(result.ok)
    assert.same({ selected }, session.get(root).artifacts)
  end)

  it("registers clean and rebuild commands and plan completion", function()
    pcall(vim.api.nvim_del_user_command, "STM32Clean")
    pcall(vim.api.nvim_del_user_command, "STM32Rebuild")
    pcall(vim.api.nvim_del_user_command, "STM32Plan")
    vim.g.loaded_nvim_stm32 = nil
    vim.cmd("runtime plugin/nvim-stm32.lua")

    assert.equals(2, vim.fn.exists(":STM32Clean"))
    assert.equals(2, vim.fn.exists(":STM32Rebuild"))
    local completion = vim.api.nvim_get_commands({ builtin = false }).STM32Plan.complete
    assert.same({
      "build",
      "clean",
      "rebuild",
      "analyze",
      "flash",
      "erase",
      "reset",
      "monitor",
    }, completion())
  end)
end)

describe("nvim-stm32 build failure output", function()
  local float = require("nvim-stm32.ui.float")
  local original_open, original_executable, original_run
  local presenter

  before_each(function()
    original_open = float.open
    original_executable = vim.fn.executable
    original_run = process.run
    presenter = { chunks = {} }
    function presenter:append(chunk)
      self.chunks[#self.chunks + 1] = chunk
    end
    function presenter:finish(ok)
      self.ok = ok
    end
    float.open = function()
      return presenter
    end
  end)

  after_each(function()
    float.open = original_open
    vim.fn.executable = original_executable
    process.run = original_run
  end)

  it("shows a missing tool error before a child can produce output", function()
    vim.fn.executable = function()
      return 0
    end
    local result
    build.current({ project = project("/firmware/output", "make") }, function(value)
      result = value
    end)

    assert.is_false(presenter.ok)
    assert.equals("build-tool-unavailable", result.error.code)
    assert.matches("tool not found: make", table.concat(presenter.chunks), 1, true)
  end)

  for _, streaming in ipairs({ false, true }) do
    it("shows command failures once with streaming " .. tostring(streaming), function()
      vim.fn.executable = function()
        return 1
      end
      process.run = function(_, opts, callback)
        if streaming then
          opts.on_output("compiler error\n")
        end
        callback({ code = 2, signal = 0, output = "compiler error\n" })
        return {}
      end

      build.current({ project = project("/firmware/output", "make") })

      assert.is_false(presenter.ok)
      local text = table.concat(presenter.chunks)
      local _, count = text:gsub("compiler error", "")
      assert.equals(1, count)
      assert.matches("build command did not complete successfully", text, 1, true)
    end)
  end
end)
