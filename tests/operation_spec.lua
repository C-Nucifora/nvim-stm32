local model = require("nvim-stm32.model")
local operation = require("nvim-stm32.operation")
local build = require("nvim-stm32.operations.build")
local process = require("nvim-stm32.process")
local session = require("nvim-stm32.session")

local function write_json(path, value)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  vim.fn.writefile({ vim.json.encode(value) }, path)
end

local function preset_document(root, names)
  local configure, builds = {}, {}
  for _, name in ipairs(names) do
    configure[#configure + 1] = {
      name = name,
      binaryDir = "${sourceDir}/build/${presetName}",
    }
    builds[#builds + 1] = { name = name, configurePreset = name }
  end
  write_json(root .. "/CMakePresets.json", {
    version = 3,
    configurePresets = configure,
    buildPresets = builds,
  })
end

local function project(root, images)
  return model.project({
    id = root,
    root = root,
    kind = "cmake_presets",
    build = { adapter = "cmake_presets", marker = root .. "/CMakePresets.json" },
    images = images or {
      {
        id = "application",
        name = "application",
        build_target = "app",
        target = { mcu = "STM32F429ZITx" },
      },
    },
  })
end

local function write_reply(root, target_name)
  local binary = root .. "/build/Debug"
  local replies = binary .. "/.cmake/api/v1/reply"
  vim.fn.mkdir(replies, "p")
  vim.fn.writefile({ "elf" }, binary .. "/" .. target_name .. ".elf")
  write_json(replies .. "/index-test.json", {
    objects = {
      {
        kind = "codemodel",
        version = { major = 2 },
        jsonFile = "codemodel-test.json",
      },
    },
  })
  write_json(replies .. "/codemodel-test.json", {
    kind = "codemodel",
    version = { major = 2 },
    paths = { source = root, build = binary },
    configurations = {
      {
        targets = { { name = target_name, jsonFile = "target-test.json" } },
      },
    },
  })
  write_json(replies .. "/target-test.json", {
    name = target_name,
    type = "EXECUTABLE",
    paths = { source = root, build = binary },
    artifacts = { { path = target_name .. ".elf" } },
  })
end

describe("nvim-stm32 build operation plans", function()
  local root

  before_each(function()
    root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
    preset_document(root, { "Debug", "Release" })
    session.clear()
  end)

  after_each(function()
    session.clear()
    vim.fn.delete(root, "rf")
  end)

  it("plans query, configure, and build for the selected configuration", function()
    local plan = assert(build.plan(project(root), { configuration = "Debug" }))

    assert.equals("build", plan.kind)
    assert.equals(root, plan.project_id)
    assert.same({ "application" }, plan.images)
    assert.same({ "cmake", "--preset", "Debug" }, plan.commands[1].argv)
    assert.same(
      { "cmake", "--build", "--preset", "Debug", "--target", "app" },
      plan.commands[2].argv
    )
    assert.same({}, plan.locks)
    assert.equals("none", plan.reset_policy)
    assert.equals("Debug", plan.metadata.configuration.name)
    assert.equals(
      root .. "/build/Debug/.cmake/api/v1/query/client-nvim-stm32/query.json",
      plan.metadata.query_path
    )
    assert.equals(root .. "/build/Debug/.cmake/api/v1/reply", plan.metadata.reply_dir)
    assert.equals(
      root .. "/build/Debug/.cmake/api/v1/query/client-nvim-stm32/query.json",
      plan.metadata.file_api.query_path
    )
    assert.equals(
      root .. "/build/Debug/.cmake/api/v1/reply",
      plan.metadata.file_api.reply_dir
    )
  end)

  it("does not write the File API query while planning", function()
    local plan = assert(build.plan(project(root), { configuration = "Debug" }))
    assert.equals(0, vim.fn.filereadable(plan.metadata.file_api.query_path))
  end)

  it(
    "uses explicit configuration before session and session before a sole choice",
    function()
      session.select(root, { configuration = "Release" })
      local explicit = assert(build.plan(project(root), { configuration = "Debug" }))
      assert.equals("Debug", explicit.metadata.configuration.name)

      local remembered = assert(build.plan(project(root)))
      assert.equals("Release", remembered.metadata.configuration.name)

      preset_document(root, { "Debug" })
      session.clear(root)
      local sole = assert(build.plan(project(root)))
      assert.equals("Debug", sole.metadata.configuration.name)
    end
  )

  it("requires a choice when several configurations remain", function()
    local plan, err = build.plan(project(root))
    assert.is_nil(plan)
    assert.equals("configuration-required", err.code)
  end)

  it("builds selected image targets in one command", function()
    local multi = project(root, {
      { id = "CM4", name = "CM4", build_target = "app_cm4", target = {} },
      { id = "CM7", name = "CM7", build_target = "app_cm7", target = {} },
    })
    local plan = assert(build.plan(multi, {
      configuration = "Debug",
      images = { "CM7", "CM4" },
    }))

    assert.same({ "CM7", "CM4" }, plan.images)
    assert.same({
      "cmake",
      "--build",
      "--preset",
      "Debug",
      "--target",
      "app_cm7",
      "app_cm4",
    }, plan.commands[2].argv)
    assert.equals(2, #plan.commands)
  end)

  it("uses the session-selected image when options do not select one", function()
    local multi = project(root, {
      { id = "CM4", name = "CM4", build_target = "app_cm4", target = {} },
      { id = "CM7", name = "CM7", build_target = "app_cm7", target = {} },
    })
    session.select(root, { image_id = "CM7" })

    local plan = assert(build.plan(multi, { configuration = "Debug" }))

    assert.same({ "CM7" }, plan.images)
    assert.same({
      "cmake",
      "--build",
      "--preset",
      "Debug",
      "--target",
      "app_cm7",
    }, plan.commands[2].argv)
  end)

  it("uses explicit image options before the session selection", function()
    local multi = project(root, {
      { id = "CM4", name = "CM4", build_target = "app_cm4", target = {} },
      { id = "CM7", name = "CM7", build_target = "app_cm7", target = {} },
    })
    session.select(root, { image_id = "CM7" })

    local plan = assert(build.plan(multi, {
      configuration = "Debug",
      image_id = "CM4",
    }))

    assert.same({ "CM4" }, plan.images)
  end)

  it("rejects an unknown session-selected image", function()
    local multi = project(root, {
      { id = "CM4", name = "CM4", build_target = "app_cm4", target = {} },
      { id = "CM7", name = "CM7", build_target = "app_cm7", target = {} },
    })
    session.select(root, { image_id = "missing" })

    local plan, err = build.plan(multi, { configuration = "Debug" })

    assert.is_nil(plan)
    assert.equals("image-not-found", err.code)
  end)

  it("deep-copies the project and options used to create a plan", function()
    local source = project(root)
    local images = { "application" }
    local plan = assert(build.plan(source, {
      configuration = "Debug",
      images = images,
    }))
    source.images[1].build_target = "changed"
    images[1] = "changed"

    assert.same({ "application" }, plan.images)
    assert.equals("app", plan.metadata.project.images[1].build_target)
    assert.equals("app", plan.commands[2].argv[#plan.commands[2].argv])
  end)
end)

describe("nvim-stm32 operation execution", function()
  local root
  local original_process_run
  local original_process_system
  local original_executable
  local original_path

  before_each(function()
    root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
    preset_document(root, { "Debug" })
    session.clear()
    original_process_run = process.run
    original_process_system = process.system
    original_executable = vim.fn.executable
    original_path = vim.env.PATH
  end)

  after_each(function()
    process.run = original_process_run
    process.system = original_process_system
    vim.fn.executable = original_executable
    vim.env.PATH = original_path
    session.clear()
    vim.fn.delete(root, "rf")
  end)

  it("writes the query immediately before delegating all commands", function()
    local planned = assert(build.plan(project(root), { configuration = "Debug" }))
    local snapshot = vim.deepcopy(planned)
    local calls = 0
    local result

    process.run = function(commands, opts, callback)
      calls = calls + 1
      assert.equals(1, vim.fn.filereadable(planned.metadata.file_api.query_path))
      assert.same(snapshot.commands, commands)
      assert.equals(root, opts.cwd)
      assert.equals("/toolchain", opts.toolchain_path)
      write_reply(root, "app")
      callback({
        code = 0,
        signal = 0,
        output = "built",
        command = commands[2].argv,
        started_ns = 10,
        ended_ns = 20,
      })
      return { id = 9 }
    end

    local handle = operation.run(
      planned,
      { toolchain_path = "/toolchain" },
      function(value)
        result = value
      end
    )

    assert.equals(9, handle.id)
    assert.equals(1, calls)
    assert.is_true(result.ok, vim.inspect(result))
    assert.equals("application", result.artifacts[1].image_id)
    assert.equals(planned.id, result.artifacts[1].build_id)
    assert.equals(root .. "/build/Debug/app.elf", result.elf)
    assert.same(result.artifacts, session.get(root).artifacts)
    assert.same(snapshot, planned)
  end)

  it("deep-copies a plan before handing commands to the process manager", function()
    local planned = assert(build.plan(project(root), { configuration = "Debug" }))
    local received
    process.run = function(commands)
      received = commands
      return { id = 1 }
    end

    operation.run(planned, {}, function() end)
    planned.commands[1].argv[1] = "changed"
    planned.metadata.configuration.name = "changed"

    assert.equals("cmake", received[1].argv[1])
  end)

  it("prefixes the toolchain once for command-local and inherited PATH", function()
    local planned = assert(build.plan(project(root), { configuration = "Debug" }))
    planned.commands[1].env = { PATH = "/configure-path" }
    vim.env.PATH = "/inherited-path"
    vim.fn.executable = function()
      return 1
    end
    write_reply(root, "app")
    local paths = {}
    local result
    process.system = function(_, opts, callback)
      paths[#paths + 1] = opts.env.PATH
      callback({ code = 0, signal = 0 })
      return { pid = #paths, kill = function() end }
    end

    operation.run(planned, { toolchain_path = "/toolchain" }, function(value)
      result = value
    end)
    assert.is_true(vim.wait(200, function()
      return result ~= nil
    end))

    assert.same({
      "/toolchain:/configure-path",
      "/toolchain:/inherited-path",
    }, paths)
    assert.is_true(result.ok, vim.inspect(result))
  end)

  it("calls completion exactly once when a process callback repeats", function()
    local planned = assert(build.plan(project(root), { configuration = "Debug" }))
    local completions = 0
    process.run = function(commands, _, callback)
      callback({ code = 2, signal = 0, output = "failed", command = commands[1].argv })
      callback({ code = 2, signal = 0, output = "failed", command = commands[1].argv })
      return { id = 1 }
    end

    operation.run(planned, {}, function()
      completions = completions + 1
    end)

    assert.equals(1, completions)
  end)

  it("returns a completed handle and structured result when preflight fails", function()
    local planned = assert(build.plan(project(root), { configuration = "Debug" }))
    vim.fn.mkdir(root .. "/build/Debug", "p")
    vim.fn.writefile({ "blocked" }, root .. "/build/Debug/.cmake")
    local calls = 0
    local result
    process.run = function()
      calls = calls + 1
    end

    local handle = operation.run(planned, {}, function(value)
      result = value
    end)

    assert.equals(0, calls)
    assert.equals("completed", handle.state())
    assert.is_false(handle.cancel())
    assert.is_nil(handle.pid())
    assert.is_false(result.ok)
    assert.equals("cmake-file-api-query", result.error.code)
  end)

  it("checks for CMake before writing a File API query", function()
    local planned = assert(build.plan(project(root), { configuration = "Debug" }))
    local calls = 0
    local result
    vim.fn.executable = function(name)
      return name == "cmake" and 0 or original_executable(name)
    end
    process.run = function()
      calls = calls + 1
    end

    local handle = operation.run(planned, {}, function(value)
      result = value
    end)

    assert.equals(0, calls)
    assert.equals(0, vim.fn.filereadable(planned.metadata.query_path))
    assert.equals("completed", handle.state())
    assert.equals("build-tool-unavailable", result.error.code)
  end)

  it("checks for Make before delegating a build", function()
    local make_project = model.project({
      id = root,
      root = root,
      kind = "make",
      build = { adapter = "make", marker = root .. "/Makefile" },
      images = {
        { id = "application", name = "application", target = {} },
      },
    })
    local planned = assert(build.plan(make_project))
    local calls = 0
    local result
    vim.fn.executable = function(name)
      return name == "make" and 0 or original_executable(name)
    end
    process.run = function()
      calls = calls + 1
    end

    local handle = operation.run(planned, {}, function(value)
      result = value
    end)

    assert.equals(0, calls)
    assert.equals("completed", handle.state())
    assert.equals("build-tool-unavailable", result.error.code)
  end)

  it("rejects malformed plans without throwing or spawning", function()
    local calls = 0
    local completions = 0
    local result
    process.run = function()
      calls = calls + 1
    end

    local ok, handle = pcall(operation.run, { kind = "build" }, {}, function(value)
      completions = completions + 1
      result = value
    end)

    assert.is_true(ok)
    assert.equals(0, calls)
    assert.equals(1, completions)
    assert.equals("operation-plan-invalid", result.error.code)
    assert.equals("completed", handle.state())
  end)
end)

describe("nvim-stm32 current build compatibility", function()
  local root
  local original_operation_run
  local original_float_open
  local original_select
  local float = require("nvim-stm32.ui.float")

  before_each(function()
    root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
    preset_document(root, { "Debug", "Release" })
    session.clear()
    original_operation_run = operation.run
    original_float_open = float.open
    original_select = vim.ui.select
  end)

  after_each(function()
    operation.run = original_operation_run
    float.open = original_float_open
    vim.ui.select = original_select
    session.clear()
    vim.fn.delete(root, "rf")
  end)

  it("keeps the preset picker and forwards its result to the callback", function()
    local selected_plan
    local completed
    vim.ui.select = function(items, _, callback)
      assert.same({ "Debug", "Release" }, items)
      callback("Release")
    end
    float.open = function()
      return {
        append = function() end,
        finish = function() end,
      }
    end
    operation.run = function(plan, _, callback)
      selected_plan = plan
      local result = { ok = true, code = 0, output = "", artifacts = {} }
      callback(result)
      return { id = 12 }
    end

    build.current({ project = project(root) }, function(result)
      completed = result
    end)

    assert.equals("Release", selected_plan.metadata.configuration.name)
    assert.is_true(completed.ok)
    assert.equals("Release", session.get(root).configuration)
  end)
end)

describe("nvim-stm32 plan UI and command registration", function()
  it("renders project, configuration, images, cwd, and shell-escaped argv", function()
    local lines = require("nvim-stm32.ui.plan").lines({
      id = "build-1",
      kind = "build",
      project_id = "/tmp/project name",
      images = { "application" },
      commands = {
        { argv = { "cmake", "--preset", "Debug Mode" }, cwd = "/tmp/project name" },
      },
      locks = {},
      reset_policy = "none",
      metadata = { configuration = { name = "Debug Mode" } },
    })
    local text = table.concat(lines, "\n")

    assert.matches("Project: /tmp/project name", text, 1, true)
    assert.matches("Configuration: Debug Mode", text, 1, true)
    assert.matches("Images: application", text, 1, true)
    assert.matches("Cwd: /tmp/project name", text, 1, true)
    assert.matches("'Debug Mode'", text, 1, true)
  end)

  it(":STM32Plan and :STM32SelectConfig are registered without setup", function()
    pcall(vim.api.nvim_del_user_command, "STM32Plan")
    pcall(vim.api.nvim_del_user_command, "STM32SelectConfig")
    vim.g.loaded_nvim_stm32 = nil
    vim.cmd("runtime plugin/nvim-stm32.lua")

    assert.equals(2, vim.fn.exists(":STM32Plan"))
    assert.equals(2, vim.fn.exists(":STM32SelectConfig"))
  end)
end)
