local file_api = require("nvim-stm32.build.file_api")

local function fixture(rel)
  local here =
    vim.fn.fnamemodify(vim.fn.resolve(debug.getinfo(1, "S").source:sub(2)), ":p:h")
  return here .. "/fixtures/" .. rel
end

local function write_json(path, value)
  vim.fn.writefile({ vim.json.encode(value) }, path)
end

local function reply_dir(root)
  local path = root .. "/.cmake/api/v1/reply"
  vim.fn.mkdir(path, "p")
  return path
end

local function valid_codemodel(target_file)
  return {
    kind = "codemodel",
    version = { major = 2 },
    configurations = {
      {
        targets = { { name = "app", jsonFile = target_file } },
      },
    },
  }
end

local function valid_target()
  return {
    name = "app",
    type = "EXECUTABLE",
    paths = { source = "/source", build = "/build" },
    artifacts = {},
  }
end

local function write_index(path, codemodel_file, mtime)
  write_json(path, {
    objects = {
      {
        kind = "codemodel",
        version = { major = 2 },
        jsonFile = codemodel_file,
      },
    },
  })
  assert(vim.uv.fs_utime(path, mtime, mtime))
end

local function assert_target_error(root)
  local ok, reply, err = pcall(file_api.reply, root)
  assert.is_true(ok)
  assert.is_nil(reply)
  assert.equals("cmake-file-api-target", err.code)
end

describe("nvim-stm32 CMake File API", function()
  it("writes a client-owned codemodel query", function()
    local root = vim.fn.tempname()
    local path = assert(file_api.write_query(root))
    assert.equals(root .. "/.cmake/api/v1/query/client-nvim-stm32/query.json", path)
    local query = vim.json.decode(table.concat(vim.fn.readfile(path), "\n"))
    assert.same({ requests = { { kind = "codemodel", version = 2 } } }, query)
    assert.equals(0, vim.fn.filereadable(path .. ".tmp"))
    vim.fn.delete(root, "rf")
  end)

  it("returns executable targets and ignores utility targets", function()
    local reply = assert(file_api.reply(fixture("file_api_reply")))
    assert.equals(1, #reply.targets)
    assert.same({
      name = "app",
      type = "EXECUTABLE",
      source_dir = "/placeholder/source",
      build_dir = "/placeholder/build",
      artifacts = { "/placeholder/build/app.elf" },
      linker_command_fragments = {
        "arm-none-eabi-gcc",
        "-Wl,-Tapp.ld",
        "-o",
        "app.elf",
      },
    }, reply.targets[1])
  end)

  it("skips a newer malformed v2 codemodel by modification time", function()
    local root = vim.fn.tempname()
    local replies = reply_dir(root)
    write_json(replies .. "/target-app.json", valid_target())
    write_json(replies .. "/codemodel-old.json", valid_codemodel("target-app.json"))
    write_index(replies .. "/index-old.json", "codemodel-old.json", 100)
    write_json(replies .. "/codemodel-new.json", {
      kind = "codemodel",
      version = { major = 2 },
      configurations = { invalid = true },
    })
    write_index(replies .. "/index-new.json", "codemodel-new.json", 200)

    local reply = assert(file_api.reply(root))
    assert.equals("app", reply.targets[1].name)
    vim.fn.delete(root, "rf")
  end)

  it("skips a newer codemodel with a non-list directory field", function()
    local root = vim.fn.tempname()
    local replies = reply_dir(root)
    write_json(replies .. "/target-app.json", valid_target())
    write_json(replies .. "/codemodel-old.json", valid_codemodel("target-app.json"))
    write_index(replies .. "/index-old.json", "codemodel-old.json", 100)
    write_json(replies .. "/codemodel-new.json", {
      kind = "codemodel",
      version = { major = 2 },
      configurations = { { targets = {}, directories = false } },
    })
    write_index(replies .. "/index-new.json", "codemodel-new.json", 200)

    local reply = assert(file_api.reply(root))
    assert.equals("app", reply.targets[1].name)
    vim.fn.delete(root, "rf")
  end)

  it("rejects a codemodel symlink that escapes the reply directory", function()
    local root = vim.fn.tempname()
    local replies = reply_dir(root)
    local outside = vim.fn.tempname()
    vim.fn.mkdir(outside, "p")
    write_json(outside .. "/codemodel.json", valid_codemodel("target-app.json"))
    write_index(replies .. "/index-test.json", "codemodel.json", 100)
    assert(
      vim.uv.fs_symlink(outside .. "/codemodel.json", replies .. "/codemodel.json")
    )

    local _, err = file_api.reply(root)
    assert.equals("cmake-file-api-codemodel", err.code)

    vim.fn.delete(root, "rf")
    vim.fn.delete(outside, "rf")
  end)

  it("returns structured errors with the failing File API path", function()
    local root = vim.fn.tempname()
    local reply_dir = root .. "/.cmake/api/v1/reply"
    vim.fn.mkdir(reply_dir, "p")
    write_json(reply_dir .. "/index-test.json", {
      objects = {
        {
          kind = "codemodel",
          version = { major = 2 },
          jsonFile = "codemodel-v2-test.json",
        },
      },
    })
    write_json(reply_dir .. "/codemodel-v2-test.json", {
      kind = "codemodel",
      version = { major = 2 },
      configurations = {
        {
          targets = { { name = "app", jsonFile = "target-app-test.json" } },
        },
      },
    })
    write_json(
      reply_dir .. "/target-app-test.json",
      { name = "app", type = "EXECUTABLE" }
    )

    local _, target_err = file_api.reply(root)
    assert.equals("cmake-file-api-target", target_err.code)
    assert.matches("target-app-test.json", target_err.message, 1, true)

    vim.fn.delete(root, "rf")
  end)

  it("returns a query error when it cannot create the query directory", function()
    local root = vim.fn.tempname()
    vim.fn.writefile({ "not a directory" }, root)

    local _, err = file_api.write_query(root)
    assert.equals("cmake-file-api-query", err.code)
    assert.matches(root, err.message, 1, true)

    vim.fn.delete(root)
  end)

  it(
    "rejects a client query directory symlink that escapes the binary directory",
    function()
      local root = vim.fn.tempname()
      local outside = vim.fn.tempname()
      local parent = root .. "/.cmake/api/v1/query"
      vim.fn.mkdir(parent, "p")
      vim.fn.mkdir(outside, "p")
      assert(vim.uv.fs_symlink(outside, parent .. "/client-nvim-stm32"))

      local _, err = file_api.write_query(root)
      assert.equals("cmake-file-api-query", err.code)
      assert.equals(0, vim.fn.filereadable(outside .. "/query.json"))

      vim.fn.delete(root, "rf")
      vim.fn.delete(outside, "rf")
    end
  )

  it("rejects a temporary query symlink before writing through it", function()
    local root = vim.fn.tempname()
    local outside = vim.fn.tempname()
    local query_dir = root .. "/.cmake/api/v1/query/client-nvim-stm32"
    vim.fn.mkdir(query_dir, "p")
    vim.fn.writefile({ "outside" }, outside)
    assert(vim.uv.fs_symlink(outside, query_dir .. "/query.json.tmp"))

    local _, err = file_api.write_query(root)
    assert.equals("cmake-file-api-query", err.code)
    assert.same({ "outside" }, vim.fn.readfile(outside))

    vim.fn.delete(root, "rf")
    vim.fn.delete(outside)
  end)

  it("returns a query error when writing the temporary query fails", function()
    local root = vim.fn.tempname()
    local original = vim.fn.writefile
    vim.fn.writefile = function()
      return 1
    end
    local _, err = file_api.write_query(root)
    vim.fn.writefile = original

    assert.equals("cmake-file-api-query", err.code)
    vim.fn.delete(root, "rf")
  end)

  it("returns a query error when renaming the temporary query fails", function()
    local root = vim.fn.tempname()
    local original = vim.uv.fs_rename
    vim.uv.fs_rename = function()
      return nil, "injected rename failure"
    end
    local _, err = file_api.write_query(root)
    vim.uv.fs_rename = original

    assert.equals("cmake-file-api-query", err.code)
    vim.fn.delete(root, "rf")
  end)

  it("returns target errors for malformed paths", function()
    local root = vim.fn.tempname()
    local replies = reply_dir(root)
    local target = valid_target()
    target.paths = true
    write_json(replies .. "/target-app.json", target)
    write_json(replies .. "/codemodel.json", valid_codemodel("target-app.json"))
    write_index(replies .. "/index-test.json", "codemodel.json", 100)

    assert_target_error(root)
    vim.fn.delete(root, "rf")
  end)

  it("returns target errors for malformed linker metadata", function()
    local root = vim.fn.tempname()
    local replies = reply_dir(root)
    local target = valid_target()
    target.link = true
    write_json(replies .. "/target-app.json", target)
    write_json(replies .. "/codemodel.json", valid_codemodel("target-app.json"))
    write_index(replies .. "/index-test.json", "codemodel.json", 100)

    assert_target_error(root)
    vim.fn.delete(root, "rf")
  end)

  it("returns target errors for a false linker fragment list", function()
    local root = vim.fn.tempname()
    local replies = reply_dir(root)
    local target = valid_target()
    target.link = { commandFragments = false }
    write_json(replies .. "/target-app.json", target)
    write_json(replies .. "/codemodel.json", valid_codemodel("target-app.json"))
    write_index(replies .. "/index-test.json", "codemodel.json", 100)

    assert_target_error(root)
    vim.fn.delete(root, "rf")
  end)

  it("returns target errors for malformed artifacts", function()
    local root = vim.fn.tempname()
    local replies = reply_dir(root)
    local target = valid_target()
    target.artifacts = true
    write_json(replies .. "/target-app.json", target)
    write_json(replies .. "/codemodel.json", valid_codemodel("target-app.json"))
    write_index(replies .. "/index-test.json", "codemodel.json", 100)

    assert_target_error(root)
    vim.fn.delete(root, "rf")
  end)
end)
