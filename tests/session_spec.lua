local model = require("nvim-stm32.model")
local nvim_stm32 = require("nvim-stm32")
local session = require("nvim-stm32.session")

local function artifact(image_id, configuration, kind, path)
  return model.artifact({
    image_id = image_id,
    configuration = configuration,
    kind = kind,
    path = path,
    build_target = image_id,
    modified_ns = 1,
  })
end

describe("nvim-stm32 session", function()
  before_each(function()
    session.clear()
  end)

  after_each(function()
    session.clear()
  end)

  it("isolates selections by normalized project root", function()
    session.select("/one/../one", { image_id = "app", configuration = "Debug" })
    session.select("/two", { image_id = "boot", configuration = "Release" })

    assert.equals("app", session.get("/one").image_id)
    assert.equals("boot", session.get("/two").image_id)
  end)

  it("accepts a project object and keeps its normalized project id", function()
    local selected = session.select({ root = "/one/../one", id = "/one/../one" }, {
      image_id = "app",
    })

    assert.equals("/one", selected.project_id)
    assert.equals("/one", session.get("/one").project_id)
  end)

  it("does not expose mutable internal state", function()
    local value = session.select("/one", { image_id = "app" })
    value.image_id = "changed"
    value.artifacts[1] = { path = "changed" }

    assert.equals("app", session.get("/one").image_id)
    assert.same({}, session.get("/one").artifacts)
  end)

  it("copies nested selections on input and output", function()
    local patch = { artifacts = { { path = "/one/app.elf" } } }
    session.select("/one", patch)
    patch.artifacts[1].path = "changed"

    local value = session.get("/one")
    assert.equals("/one/app.elf", value.artifacts[1].path)
    value.artifacts[1].path = "changed again"
    assert.equals("/one/app.elf", session.get("/one").artifacts[1].path)
  end)

  it("replaces matching artifacts while retaining unrelated artifacts", function()
    local debug_elf = artifact("app", "Debug", "elf", "/one/debug.elf")
    local debug_bin = artifact("app", "Debug", "bin", "/one/debug.bin")
    local release_elf = artifact("app", "Release", "elf", "/one/release.elf")
    session.select("/one", { artifacts = { debug_elf, debug_bin, release_elf } })

    local replacement = artifact("app", "Debug", "elf", "/one/new-debug.elf")
    local recorded = session.record("/one", {
      ok = true,
      artifacts = { replacement },
    })

    assert.same({ replacement, debug_bin, release_elf }, recorded.artifacts)
  end)

  it("compares artifact identity fields without delimiter collisions", function()
    local unrelated = {
      image_id = "a\0b",
      configuration = "c",
      kind = "elf",
      path = "/one/unrelated.elf",
    }
    local replacement = {
      image_id = "a",
      configuration = "b\0c",
      kind = "elf",
      path = "/one/replacement.elf",
    }
    session.select("/one", { artifacts = { unrelated } })

    local recorded = session.record("/one", { artifacts = { replacement } })

    assert.same({ unrelated, replacement }, recorded.artifacts)
  end)

  it("rejects a malformed artifact result with a field-specific error", function()
    session.select("/one", { image_id = "app" })

    local ok, err = pcall(function()
      session.record("/one", { artifacts = "not a list" })
    end)

    assert.is_false(ok)
    assert.matches("result.artifacts", err, 1, true)
    assert.equals("app", session.get("/one").image_id)
  end)

  it("rejects sparse artifact results before changing the session", function()
    session.select("/one", { image_id = "app" })

    local ok, err = pcall(function()
      session.record("/one", {
        artifacts = {
          [1] = { image_id = "app", configuration = "Debug", kind = "elf" },
          [3] = { image_id = "app", configuration = "Debug", kind = "bin" },
        },
      })
    end)

    assert.is_false(ok)
    assert.matches("result.artifacts", err, 1, true)
    assert.equals("app", session.get("/one").image_id)
    assert.same({}, session.get("/one").artifacts)
  end)

  it("rejects non-table artifact records before changing the session", function()
    session.select("/one", { image_id = "app" })

    local ok, err = pcall(function()
      session.record("/one", { artifacts = { "not a record" } })
    end)

    assert.is_false(ok)
    assert.matches("result.artifacts", err, 1, true)
    assert.equals("app", session.get("/one").image_id)
    assert.same({}, session.get("/one").artifacts)
  end)

  it("stores the result without exposing mutable nested state", function()
    local result = {
      ok = true,
      code = 0,
      output = "built",
      artifacts = {},
      metadata = { build_id = "build-1" },
    }
    session.record("/one", result)
    result.metadata.build_id = "changed"

    local value = session.get("/one")
    assert.equals("build-1", value.last_result.metadata.build_id)
    value.last_result.metadata.build_id = "changed again"
    assert.equals("build-1", session.get("/one").last_result.metadata.build_id)
  end)

  it("clears one project or every project", function()
    session.select("/one", { image_id = "app" })
    session.select("/two", { image_id = "boot" })
    session.clear("/one/../one")

    assert.is_nil(session.get("/one").image_id)
    assert.equals("boot", session.get("/two").image_id)

    session.clear()
    assert.is_nil(session.get("/two").image_id)
  end)

  it("exposes session and project resolution through the public module", function()
    session.select("/one", { image_id = "app" })
    assert.equals("app", nvim_stm32.get_session("/one").image_id)
    assert.is_function(nvim_stm32.resolve_project)
  end)
end)
