local file_api = require("nvim-stm32.build.file_api")

local function fixture(rel)
  local here =
    vim.fn.fnamemodify(vim.fn.resolve(debug.getinfo(1, "S").source:sub(2)), ":p:h")
  return here .. "/fixtures/" .. rel
end

local function write_json(path, value)
  vim.fn.writefile({ vim.json.encode(value) }, path)
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

  it("skips a newer unusable index and reads the newest valid codemodel", function()
    local reply = assert(file_api.reply(fixture("file_api_reply")))
    assert.equals("app", reply.targets[1].name)
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
end)
