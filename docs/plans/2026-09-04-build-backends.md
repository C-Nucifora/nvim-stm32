# STM32 build backends implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> superpowers:subagent-driven-development or superpowers:executing-plans to
> implement this plan task by task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Add `:STM32Build` with CMake preset, plain CMake, and Make backends,
live output, and ELF discovery.

**Architecture:** Each backend keeps command construction pure. CMake backends
add `configure_cmd()` because configuration and compilation are separate
processes; the required `cmd()` method remains the compilation command. A small
process runner executes argv arrays in order, and one presenter owns the output
buffer and optional snacks window.

**Tech stack:** Lua, Neovim 0.11 or newer, `vim.system`, plenary-busted,
snacks.nvim when available.

**Spec:** `docs/design.md`, build-order step 3.

## Global constraints

- Work only in `C-Nucifora/nvim-stm32`. The CSSE3010 repository is read-only
  test input.
- Keep backend `cmd()` functions pure and return argv arrays. Never join a
  command into a shell string.
- Pass `tools.env(config)` to every child process.
- Use the current buffer for project detection.
- Keep snacks optional. The fallback must use `nvim_open_win`.
- A failed process leaves its output window open. A successful build closes it
  after `config.float.close_on_success_ms`.
- Write a failing test before each production change.
- Run `scripts/test.sh` and `stylua --check lua/ tests/` before each commit.
- Commit as `C-Nucifora <143251500+C-Nucifora@users.noreply.github.com>` with
  no AI attribution.

---

### Task 1: Pure build backends

**Files:**

- Create `lua/nvim-stm32/backend/build/cmake_presets.lua`
- Create `lua/nvim-stm32/backend/build/cmake_plain.lua`
- Create `lua/nvim-stm32/backend/build/make.lua`
- Create `tests/build_backends_spec.lua`

**Interfaces:**

- Every module exposes `available()`, `cmd(target, opts)`, and
  `parse(output, code)`.
- CMake modules also expose `configure_cmd(target, opts)`.
- `cmake_presets.presets(root)` returns visible build preset names or an error.

- [ ] **Step 1: Write the failing backend tests**

```lua
local presets = require("nvim-stm32.backend.build.cmake_presets")
local plain = require("nvim-stm32.backend.build.cmake_plain")
local make = require("nvim-stm32.backend.build.make")

local target = { root = "/work/fw", build_backend = "cmake_presets" }

describe("build backends", function()
  it("builds preset CMake argv without a shell", function()
    assert.same({ "cmake", "--preset", "Debug" }, presets.configure_cmd(target, {
      preset = "Debug",
    }))
    assert.same({ "cmake", "--build", "build/Debug" }, presets.cmd(target, {
      preset = "Debug",
    }))
  end)

  it("builds plain CMake argv", function()
    assert.same({ "cmake", "-S", ".", "-B", "build" }, plain.configure_cmd(target, {}))
    assert.same({ "cmake", "--build", "build" }, plain.cmd(target, {}))
  end)

  it("builds Make argv", function()
    assert.same({ "make" }, make.cmd(target, {}))
  end)

  it("returns structured process results", function()
    assert.same({ ok = true, code = 0, output = "done" }, make.parse("done", 0))
    assert.same({ ok = false, code = 2, output = "bad" }, make.parse("bad", 2))
  end)
end)
```

Add cases using `tests/fixtures/nucleo_cmake/CMakePresets.json` that expect
`{ "Debug", "Release" }`, exclude the hidden `default` preset, and return a
plain error for malformed JSON and a missing file.

- [ ] **Step 2: Verify the tests fail**

Run `scripts/test.sh tests/build_backends_spec.lua`.

Expected: module `nvim-stm32.backend.build.cmake_presets` is not found.

- [ ] **Step 3: Implement the backend modules**

Use this result shape in all three modules:

```lua
function M.parse(output, code)
  return { ok = code == 0, code = code, output = output }
end
```

`cmake_presets.presets(root)` must read `root .. "/CMakePresets.json"`, decode
it with `pcall(vim.json.decode, text)`, prefer `buildPresets` when present, and
fall back to `configurePresets`. Include entries with a string `name` and no
truthy `hidden` field. Preserve file order.

Command builders must return these exact arrays:

```lua
function M.configure_cmd(_, opts)
  return { "cmake", "--preset", assert(opts.preset, "preset is required") }
end

function M.cmd(_, opts)
  return { "cmake", "--build", "build/" .. assert(opts.preset, "preset is required") }
end
```

Plain CMake returns `{ "cmake", "-S", ".", "-B", "build" }` and
`{ "cmake", "--build", "build" }`. Make returns `{ "make" }`.
`available()` returns a boolean by comparing `vim.fn.executable("cmake")` or
`vim.fn.executable("make")` with `1`.

- [ ] **Step 4: Verify and commit Task 1**

Run:

```sh
scripts/test.sh tests/build_backends_spec.lua
scripts/test.sh
stylua lua/ tests/
stylua --check lua/ tests/
```

Commit with `feat(build): add pure CMake and Make backends`.

---

### Task 2: Sequential process runner

**Files:**

- Create `lua/nvim-stm32/process.lua`
- Create `tests/process_spec.lua`

**Interfaces:**

- `process.run(commands, opts, callback)` executes `string[][]` in order.
- `opts` has `cwd`, `env`, and `on_output`.
- The callback receives `{ code, signal, output, command }`.
- `process.system` defaults to `vim.system` and is replaceable by tests.

- [ ] **Step 1: Write failing runner tests**

Use a fake `process.system` that records argv and options, calls both stream
callbacks, and completes with configured exit codes. Cover these cases:

```lua
it("runs configure before build with the requested cwd and PATH", function()
  process.run({ { "cmake", "--preset", "Debug" }, { "cmake", "--build", "build/Debug" } }, {
    cwd = "/work/fw",
    env = { PATH = "/toolchain:/usr/bin" },
    on_output = function(chunk)
      output[#output + 1] = chunk
    end,
  }, function(result)
    done = result
  end)

  assert.same({ "cmake", "--preset", "Debug" }, calls[1].cmd)
  assert.same({ "cmake", "--build", "build/Debug" }, calls[2].cmd)
  assert.equals("/work/fw", calls[1].opts.cwd)
  assert.equals("/toolchain:/usr/bin", calls[1].opts.env.PATH)
  vim.wait(100, function()
    return done ~= nil
  end)
  assert.equals(0, done.code)
end)
```

Add one case where configure exits with code 1. It must not start the build.
Assert that stdout and stderr chunks reach `on_output`, that `result.output`
contains those chunks in arrival order, and that `result.command` is the argv
array which failed. Because completion is scheduled, wait for `done` before
each final assertion. Restore `process.system` in `after_each`.

- [ ] **Step 2: Verify the tests fail**

Run `scripts/test.sh tests/process_spec.lua`.

Expected: module `nvim-stm32.process` is not found.

- [ ] **Step 3: Implement the runner**

`run()` starts one `vim.system` call at a time with `text = true`, the supplied
cwd and environment, plus stdout and stderr callbacks. Append every chunk to an
output table and forward it to `on_output`. On a nonzero exit, call the final
callback immediately and do not start another command. Wrap process-exit work
in `vim.schedule()` because `vim.system` callbacks can run during a fast event.

Expose `M.system = vim.system` so the test replaces the operating-system
boundary without mocking the runner itself.

- [ ] **Step 4: Verify and commit Task 2**

Run the focused test, the full suite, and the formatter gate. Commit with
`feat(process): run backend commands in sequence`.

---

### Task 3: Shared output window

**Files:**

- Create `lua/nvim-stm32/ui/float.lua`
- Create `tests/float_spec.lua`

**Interfaces:**

- `float.open(target, config)` returns a presenter.
- A presenter exposes `append(chunk)`, `finish(ok)`, and `close()`.
- It owns `buf`, `win`, and any snacks window object.

- [ ] **Step 1: Write failing presenter tests**

With snacks absent, open a presenter for an `STM32F429ZITx` target. Assert that
the returned buffer and window are valid, its title contains the MCU, and two
partial chunks become complete lines rather than split fragments:

```lua
presenter:append("configuring\nbuil")
presenter:append("ding\n")
assert.same({ "configuring", "building" }, vim.api.nvim_buf_get_lines(
  presenter.buf,
  0,
  -1,
  false
))
```

Assert that `finish(false)` leaves the window open. With
`close_on_success_ms = 0`, assert that `finish(true)` closes it after
`vim.wait(100, predicate)`.

For the optional branch, install a test double in `package.loaded.snacks` whose
`win(opts)` records `opts.buf`, returns an object with `show()` and `close()`,
and sets a valid `win` after `show()`. Assert that `float.open()` uses it. Restore
`package.loaded.snacks` after each case.

- [ ] **Step 2: Verify the tests fail**

Run `scripts/test.sh tests/float_spec.lua`.

Expected: module `nvim-stm32.ui.float` is not found.

- [ ] **Step 3: Implement the presenter**

Create an unlisted scratch buffer. Use `snacks.win` when `require("snacks")`
succeeds and exposes a callable `win`; otherwise call `nvim_open_win` with an
80 percent width, 70 percent height, the configured border, and a title naming
the target MCU or family.

`append()` keeps an unfinished final line in `presenter.partial`. Write only
complete lines to the buffer, replacing the scratch buffer's initial empty
placeholder on the first write so output has no leading blank. Then move the
cursor to the last line when the window is valid. `finish()` flushes the
partial line. On success it calls
`vim.defer_fn(close, close_on_success_ms)`. On failure it leaves the window and
buffer intact. `close()` must tolerate an already closed window.

- [ ] **Step 4: Verify and commit Task 3**

Run the focused test, the full suite, and the formatter gate. Commit with
`feat(ui): stream backend output in an optional snacks window`.

---

### Task 4: Build coordinator and `:STM32Build`

**Files:**

- Create `lua/nvim-stm32/backend/build/init.lua`
- Create `tests/build_spec.lua`
- Modify `plugin/nvim-stm32.lua`
- Modify `README.md`

**Interfaces:**

- `build.backends` maps detection names to backend modules.
- `build.commands(target, opts)` returns the configure and build argv arrays.
- `build.find_elf(target, opts)` returns one `.elf` path or an error.
- `build.run(target, opts, callback)` executes a resolved build.
- `build.current(opts)` detects the current target, asks for a preset when
  needed, and starts the build.

- [ ] **Step 1: Write failing coordinator tests**

Cover backend selection for all three `build_backend` values. Assert that
preset CMake produces two commands in configure-then-build order, plain CMake
also produces two, and Make produces one.

Create temporary build directories with zero, one, and two `.elf` files.
`find_elf()` must return the sole file, report that none exist, and refuse to
guess when several exist.

Search recursively with `vim.fs.find`, sort results for deterministic errors,
and use these backend-specific roots:

- preset CMake: `target.root .. "/build/" .. opts.preset`
- plain CMake and Make: `target.root .. "/build"`

Replace `process.run` and `float.open` at their module boundaries. Assert that
`build.run()` passes `tools.env(require("nvim-stm32").get_config())`, uses the
target root as cwd, forwards output to the presenter, assigns `target.elf` after
a successful build, and calls `presenter:finish(false)` on a failed process.

Add this command test:

```lua
vim.cmd("runtime plugin/nvim-stm32.lua")
assert.equals(2, vim.fn.exists(":STM32Build"))
```

- [ ] **Step 2: Verify the tests fail**

Run `scripts/test.sh tests/build_spec.lua`.

Expected: module `nvim-stm32.backend.build` is not found.

- [ ] **Step 3: Implement the coordinator**

`commands()` looks up `target.build_backend`, returns a plain error for an
unknown or unavailable backend, includes `configure_cmd()` when present, and
always appends `cmd()`. `current(opts)` accepts explicit options so headless
and scripted callers can override config values such as `preset` without a UI
prompt.

For preset projects, `current()` uses `config.preset` when set. Otherwise it
calls `cmake_presets.presets(target.root)` and passes those names to
`vim.ui.select`. Cancellation returns without starting a process.

`run()` opens the presenter, calls `process.run()`, and passes
`{ cwd = target.root, env = tools.env(config), on_output = presenter.append }`.
After a zero exit it calls `find_elf()`, assigns `target.elf`, and finishes the
presenter. Missing or ambiguous ELF output is a failed plugin result even when
the compiler exited cleanly, because flashing the wrong file is worse than
stopping.

Register `:STM32Build` in `plugin/nvim-stm32.lua`:

```lua
vim.api.nvim_create_user_command("STM32Build", function()
  require("nvim-stm32.backend.build").current()
end, { desc = "nvim-stm32: configure and build the current firmware" })
```

Update the README status and command list to name `:STM32Build`.

- [ ] **Step 4: Verify against the real project**

Run the full suite and formatter gate, then execute:

```sh
nvim --headless \
  /Users/christiannucifora/Documents/University/CSSE3010/repo/s5/dt/Core/Src/s4882272_hamming.c \
  -c 'lua require("nvim-stm32.backend.build").current({ preset = "Debug" })' \
  -c 'lua vim.wait(30000, function() return require("nvim-stm32.backend.build").last_result ~= nil end)' \
  -c 'lua assert(require("nvim-stm32.backend.build").last_result.code == 0)' \
  -c 'qa!'
```

Confirm the resolved artifact ends in `build/Debug/dt.elf`. This command reads
and builds the coursework project but does not edit its source files.

- [ ] **Step 5: Commit and push Task 4**

Commit with `feat(build): add STM32Build command and live output`, push
`feat/build-backends`, open a pull request to `main`, and wait for all required
CI checks.

## Self-review

- Task 1 covers the three build backends and preserves the required pure
  `cmd()` interface.
- Task 2 supplies one argv-only runner shared by later flash backends.
- Task 3 implements both required window paths and the success/failure lifetime.
- Task 4 connects detection, configuration, child PATH, preset selection,
  output, ELF discovery, and `:STM32Build`.
- Flash, compiler.nvim integration, monitoring, and debugging remain separate
  branches because each is independently testable.
