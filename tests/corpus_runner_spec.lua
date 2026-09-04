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
    assert.is_true(runner.is_f429({
      images = { { id = "application", target = { mcu = "STM32F429ZITx" } } },
    }))
    assert.is_true(runner.is_f429({
      images = { { id = "application", target = { mcu = "STM32F429xx" } } },
    }))
    assert.is_false(runner.is_f429({
      images = { { id = "application", target = { mcu = "STM32F401RETx" } } },
    }))
  end)

  it("rejects an unexpected image count even when every MCU is F429", function()
    assert.is_false(runner.is_f429({
      images = {
        { id = "application", target = { mcu = "STM32F429ZITx" } },
        { id = "other", target = { mcu = "STM32F429xx" } },
      },
    }))
  end)

  it("requires the single image to be named application", function()
    assert.is_false(runner.is_f429({
      images = { { id = "CM4", target = { mcu = "STM32F429ZITx" } } },
    }))
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

  it("aborts traversal when cancellation never reaches a terminal state", function()
    local events = {}
    local state = "running"
    local roots = { "/one", "/two" }
    local entries = vim.tbl_map(function(root)
      return { root = root, resolved = { project = { root = root } } }
    end, roots)

    local results, terminal = runner.build_projects(entries, {
      timeout_ms = 10,
      grace_ms = 5,
      run = function(_, opts)
        events[#events + 1] = "run " .. opts.project.root
        return {
          cancel = function(reason)
            assert.equals("corpus-timeout", reason)
            state = "cancelling"
            events[#events + 1] = "cancel " .. opts.project.root
            return true
          end,
          state = function()
            return state
          end,
        }
      end,
      wait = function(_, predicate)
        assert.is_false(predicate())
        return false
      end,
    })

    assert.is_false(terminal)
    assert.same({ "run /one", "cancel /one" }, events)
    assert.equals(1, #results)
    assert.is_false(results[1].ok)
    assert.matches("did not reach a terminal state", results[1].error, 1, true)
  end)

  it("starts the next build only after cancellation becomes terminal", function()
    local temp = vim.fn.tempname()
    vim.fn.mkdir(temp, "p")
    local elf = temp .. "/app.elf"
    vim.fn.writefile({ "elf" }, elf)
    local events = {}
    local state = "running"
    local first_callback
    local wait_count = 0
    local entries = vim.tbl_map(function(root)
      return { root = root, resolved = { project = { root = root } } }
    end, { "/one", "/two" })

    local results, terminal = runner.build_projects(entries, {
      timeout_ms = 10,
      grace_ms = 5,
      run = function(_, opts, callback)
        local root = opts.project.root
        events[#events + 1] = "run " .. root
        if root == "/one" then
          first_callback = callback
          return {
            cancel = function()
              state = "cancelling"
              events[#events + 1] = "cancel /one"
              return true
            end,
            state = function()
              return state
            end,
          }
        end
        callback({
          ok = true,
          metadata = { operation_id = "build-2" },
          artifacts = {
            {
              image_id = "application",
              kind = "elf",
              path = elf,
              build_id = "build-2",
            },
          },
        })
        events[#events + 1] = "callback /two"
        return {
          cancel = function() end,
          state = function()
            return "completed"
          end,
        }
      end,
      wait = function(_, predicate)
        wait_count = wait_count + 1
        if wait_count == 1 then
          assert.is_false(predicate())
          return false
        end
        if wait_count == 2 then
          state = "cancelled"
          first_callback({ ok = false, error = { message = "cancelled" } })
          events[#events + 1] = "callback /one"
        end
        assert.is_true(predicate())
        return true
      end,
    })

    assert.is_true(terminal)
    assert.same({
      "run /one",
      "cancel /one",
      "callback /one",
      "run /two",
      "callback /two",
    }, events)
    assert.is_false(results[1].ok)
    assert.is_true(results[2].ok)
    vim.fn.delete(temp, "rf")
  end)
end)
