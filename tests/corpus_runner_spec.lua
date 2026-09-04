local runner = require("nvim-stm32.corpus")

local function fixture(rel)
  local here =
    vim.fn.fnamemodify(vim.fn.resolve(debug.getinfo(1, "S").source:sub(2)), ":p:h")
  return here .. "/fixtures/" .. rel
end

describe("nvim-stm32 corpus validation", function()
  it("sorts firmware roots by relative path and skips build directories", function()
    local roots = assert(runner.find_projects(fixture("corpus")))
    assert.same({
      fixture("corpus/s1/app"),
      fixture("corpus/s2/app"),
    }, roots)
  end)

  it("returns failure when any project fails", function()
    local code, lines = runner.summary({
      { root = "/one", ok = true },
      { root = "/two", ok = false, error = "build failed" },
    })

    assert.equals(1, code)
    assert.same({
      "PASS /one",
      "FAIL /two: build failed",
      "1/2 projects passed",
    }, lines)
  end)

  it("selects the first source under Core/Src and otherwise uses the root", function()
    local root = vim.fn.tempname()
    vim.fn.mkdir(root .. "/Core/Src", "p")
    vim.fn.writefile({ "void z(void) {}" }, root .. "/Core/Src/z.c")
    vim.fn.writefile({ "void a(void) {}" }, root .. "/Core/Src/a.c")
    vim.fn.writefile({ "metadata" }, root .. "/Core/Src/.DS_Store")

    assert.equals(root .. "/Core/Src/a.c", runner.source_file(root))
    vim.fn.delete(root .. "/Core", "rf")
    assert.equals(root, runner.source_file(root))
    vim.fn.delete(root, "rf")
  end)

  it("accepts the exact F429ZI part and compatible F429 wildcards", function()
    assert.is_true(
      runner.is_f429({ images = { { target = { mcu = "STM32F429ZITx" } } } })
    )
    assert.is_true(
      runner.is_f429({ images = { { target = { mcu = "STM32F429xx" } } } })
    )
    assert.is_false(
      runner.is_f429({ images = { { target = { mcu = "STM32F401RETx" } } } })
    )
  end)

  it("requires a fresh application ELF from the current build result", function()
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
    local elf = root .. "/app.elf"
    vim.fn.writefile({ "elf" }, elf)
    local result = {
      ok = true,
      metadata = { operation_id = "build-4" },
      artifacts = {
        {
          image_id = "application",
          kind = "elf",
          path = elf,
          build_id = "build-4",
        },
      },
    }

    assert.equals(elf, assert(runner.application_elf(result)))
    result.artifacts[1].build_id = "build-3"
    local missing, err = runner.application_elf(result)
    assert.is_nil(missing)
    assert.matches("fresh application ELF", err, 1, true)
    vim.fn.delete(root, "rf")
  end)

  it("validates the command arguments exactly", function()
    assert.same({ root = "/corpus", build = false }, runner.parse_args({ "/corpus" }))
    assert.same(
      { root = "/corpus", build = true },
      runner.parse_args({ "/corpus", "--build" })
    )

    for _, args in ipairs({
      {},
      { "/corpus", "--other" },
      { "/corpus", "--build", "extra" },
    }) do
      local parsed, err = runner.parse_args(args)
      assert.is_nil(parsed)
      assert.matches("usage:", err, 1, true)
    end
  end)
end)
