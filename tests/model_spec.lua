local model = require("nvim-stm32.model")

describe("model records", function()
  it("constructs a project with one F429 image", function()
    local project = model.project({
      id = "/fw",
      root = "/fw",
      kind = "cubemx-cmake",
      build = { adapter = "cmake-presets", configurations = {} },
      images = {
        model.image({
          id = "application",
          name = "application",
          target = {
            identity = { cpn = "STM32F429ZITx" },
            cores = { { id = "CM4", architecture = "cortex-m4" } },
          },
        }),
      },
    })

    assert.equals("/fw", project.id)
    assert.equals("application", project.images[1].id)
    assert.equals("STM32F429ZITx", project.images[1].target.identity.cpn)
  end)

  it("rejects duplicate image ids", function()
    assert.has_error(function()
      model.project({
        id = "/fw",
        root = "/fw",
        kind = "cmake",
        build = { adapter = "cmake", configurations = {} },
        images = {
          model.image({ id = "app", name = "app", target = { cores = {} } }),
          model.image({ id = "app", name = "second", target = { cores = {} } }),
        },
      })
    end, "duplicate image id: app")
  end)

  it("normalizes artifact paths and preserves provenance", function()
    local artifact = model.artifact({
      image_id = "application",
      kind = "elf",
      path = "/fw/build/Debug/../Debug/app.elf",
      configuration = "Debug",
      build_target = "app",
      modified_ns = 42,
      provenance = { source = "cmake-file-api" },
    })
    assert.equals("/fw/build/Debug/app.elf", artifact.path)
    assert.equals("cmake-file-api", artifact.provenance.source)
  end)

  it("constructs a stable structured error", function()
    local err = model.error({
      code = "artifact-missing",
      message = "application ELF does not exist",
      operation = "build",
      image_id = "application",
      command = { "cmake", "--build", "--preset", "Debug" },
      output = "",
      hint = "run :STM32Build again",
    })
    assert.equals("artifact-missing", err.code)
    assert.equals("application", err.image_id)
  end)

  it("deep copies constructor input", function()
    local spec = { id = "app", name = "app", target = { cores = {} } }
    local image = model.image(spec)
    spec.target.cores[1] = { id = "CM4" }
    spec.name = "changed"
    assert.equals("app", image.name)
    assert.equals(0, #image.target.cores)
  end)

  it("validates the remaining record shapes", function()
    local config = model.configuration({
      name = "Debug",
      configure_preset = "debug-configure",
      build_preset = "debug-build",
      binary_dir = "/fw/build/Debug",
    })
    assert.equals("Debug", config.name)

    local command = model.command({ argv = { "cmake", "--build" }, cwd = "/fw" })
    assert.equals("cmake", command.argv[1])

    local plan = model.plan({
      id = "op-1",
      kind = "build",
      project_id = "/fw",
      images = { "app" },
      commands = { command },
      locks = {},
      reset_policy = "none",
    })
    assert.equals("build", plan.kind)

    local result = model.result({
      ok = true,
      code = 0,
      output = "done",
      artifacts = {},
      duration_ms = 2,
    })
    assert.is_true(result.ok)
    assert.equals(0, result.code)
  end)

  it("rejects malformed required fields by name", function()
    assert.has_error(function()
      model.command({ argv = {} })
    end)
    assert.has_error(function()
      model.configuration({ name = "Debug", configure_preset = "cfg" })
    end)
    assert.has_error(function()
      model.project({
        id = "/fw",
        root = "/fw",
        kind = "cmake",
        build = {},
        images = {},
      })
    end)
  end)
end)
