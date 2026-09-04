# F429 project foundation implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the single-target and single-ELF assumptions with project, image, configuration, artifact, session, and cancellable-process foundations, then verify the result across the user's 13 current STM32F429 firmware folders.

**Architecture:** Keep current-buffer and Git-bounded discovery, but return a project containing images and build configurations. Use CMake presets for command selection and the CMake File API for target and artifact identity. Preserve `detect.target()`, `:STM32Info`, and `:STM32Build` through compatibility wrappers while new code consumes immutable operation plans.

**Tech Stack:** Lua 5.1 under Neovim 0.11+, `vim.system`, CMake Presets, CMake File API v1, plenary-busted, StyLua, shell scripts for explicit local corpus validation.

**Spec:** `docs/superpowers/specs/2026-09-04-neovim-native-stm32-suite-design.md`

## Global constraints

- Work only in the `nvim-stm32` repository and its worktrees. Treat `~/Documents/University/CSSE3010/repo` as read-only source input.
- Keep the core free of required Lua plugin dependencies.
- Start project discovery from the current buffer and stop at the Git root.
- Keep all external commands as argv arrays. Do not route generated commands through a shell.
- Prepend `toolchain_path` to `PATH` for every build and debug child.
- Preserve `:STM32Info`, `:STM32Build`, and `detect.target()` throughout this plan.
- Require Neovim 0.11 or newer. Support macOS and Linux.
- Do not read VS Code configuration or ST bundle metadata.
- Do not add AI authorship or co-author trailers to commits.
- Run `scripts/test.sh` and `stylua --check lua/ tests/` before every task commit.

---

## File map

### New production files

- `lua/nvim-stm32/model.lua`: constructors and validation for project, image, configuration, artifact, command, plan, and result records.
- `lua/nvim-stm32/discover/root.lua`: current-buffer and Git-bounded project-root selection.
- `lua/nvim-stm32/discover/signals.lua`: collect every MCU signal with provenance.
- `lua/nvim-stm32/discover/project.lua`: group signals into images and construct a project.
- `lua/nvim-stm32/discover/artifacts.lua`: map CMake targets to fresh artifacts.
- `lua/nvim-stm32/build/presets.lua`: load preset documents and expose configure/build configuration pairs.
- `lua/nvim-stm32/build/file_api.lua`: create CMake File API queries and parse codemodel replies.
- `lua/nvim-stm32/session.lua`: in-memory selections and last results keyed by project root.
- `lua/nvim-stm32/operation.lua`: immutable plan validation and execution entry point.
- `lua/nvim-stm32/operations/build.lua`: build plan creation and result assembly.
- `lua/nvim-stm32/corpus.lua`: reusable discovery and build validation for an explicit local corpus.
- `lua/nvim-stm32/ui/plan.lua`: readable operation-plan buffer.
- `scripts/validate-corpus.sh`: explicit local validation across a supplied firmware corpus.
- `scripts/validate_corpus.lua`: Neovim-side discovery and build runner used by the shell entry point.

### Existing production files to modify

- `lua/nvim-stm32/detect.lua`: retain old entry points as wrappers over `discover/*`.
- `lua/nvim-stm32/backend/build/init.lua`: retain the old build API while delegating to `operations/build.lua`.
- `lua/nvim-stm32/backend/build/cmake_presets.lua`: delegate preset handling to `build/presets.lua`.
- `lua/nvim-stm32/process.lua`: add command specifications, handles, cancellation, bounded output, and long-running support.
- `lua/nvim-stm32/ui/info.lua`: render projects, images, configurations, artifacts, and provenance.
- `lua/nvim-stm32/health.lua`: report the resolved project model and CMake File API capability.
- `lua/nvim-stm32/init.lua`: expose project resolution, plan creation, execution, and session access.
- `plugin/nvim-stm32.lua`: register `:STM32Plan` and `:STM32SelectConfig`.
- `README.md`: document the new model, commands, and corpus validation command.

### New test files and fixtures

- `tests/model_spec.lua`
- `tests/discover_project_spec.lua`
- `tests/presets_spec.lua`
- `tests/file_api_spec.lua`
- `tests/artifacts_spec.lua`
- `tests/session_spec.lua`
- `tests/operation_spec.lua`
- `tests/corpus_runner_spec.lua`
- `tests/fixtures/multi_image/*`
- `tests/fixtures/preset_inheritance/*`
- `tests/fixtures/file_api_reply/*`

## Task 1: Add validated records without changing current behavior

**Files:**

- Create: `lua/nvim-stm32/model.lua`
- Create: `tests/model_spec.lua`

**Interfaces:**

- Produces: `model.project(spec) -> Project`
- Produces: `model.image(spec) -> Image`
- Produces: `model.configuration(spec) -> BuildConfiguration`
- Produces: `model.artifact(spec) -> Artifact`
- Produces: `model.command(spec) -> CommandSpec`
- Produces: `model.plan(spec) -> OperationPlan`
- Produces: `model.result(spec) -> OperationResult`
- Produces: `model.error(spec) -> Stm32Error`
- Constructors return deep copies and raise validation errors with the bad field name.

- [ ] **Step 1: Write model tests that fix the record shapes**

```lua
local model = require("nvim-stm32.model")

it("constructs a project with one F429 image", function()
  local project = model.project({
    id = "/fw",
    root = "/fw",
    kind = "cubemx-cmake",
    build = { adapter = "cmake-presets", configurations = {} },
    images = {
      model.image({ id = "application", name = "application", target = {
        identity = { cpn = "STM32F429ZITx" },
        cores = { { id = "CM4", architecture = "cortex-m4" } },
      } }),
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
```

- [ ] **Step 2: Run the new model tests and confirm the missing module failure**

Run: `scripts/test.sh tests/model_spec.lua`

Expected: FAIL because `nvim-stm32.model` does not exist.

- [ ] **Step 3: Implement focused constructors and shared validation helpers**

Implement `required_string`, `optional_string`, `list`, `unique_ids`, and a
`copy` helper inside `model.lua`. Keep the record constructors explicit. For
example:

```lua
function M.artifact(spec)
  local out = copy(spec)
  required_string("artifact.image_id", out.image_id)
  required_string("artifact.kind", out.kind)
  required_string("artifact.path", out.path)
  required_string("artifact.configuration", out.configuration)
  required_string("artifact.build_target", out.build_target)
  vim.validate("artifact.modified_ns", out.modified_ns, "number")
  out.path = vim.fs.normalize(out.path)
  out.provenance = out.provenance or {}
  return out
end
```

`project()` must normalize `root`, require a non-empty image list, reject duplicate
image IDs, and validate that each `flash_order` ID exists. `configuration()` owns
`name`, `configure_preset`, optional `build_preset`, and `binary_dir`. `plan()`
must validate `kind`, `project_id`, `images`, `commands`, `locks`, and
`reset_policy`. `result()` owns `ok`, `code`, `output`, `artifacts`, optional
`error`, and process timing. `error()` owns `code`, `message`, optional operation,
image, command and output, plus a concrete hint. `command()` accepts only a
non-empty argv list of strings.

- [ ] **Step 4: Run the focused and full gates**

Run: `scripts/test.sh tests/model_spec.lua`

Expected: all model tests pass.

Run: `scripts/test.sh && stylua --check lua/ tests/`

Expected: 0 failures and clean formatting.

- [ ] **Step 5: Commit the record layer**

```sh
git add lua/nvim-stm32/model.lua tests/model_spec.lua
git commit -m "feat(model): add project and artifact records"
```

## Task 2: Separate root selection from project discovery

**Files:**

- Create: `lua/nvim-stm32/discover/root.lua`
- Create: `lua/nvim-stm32/discover/signals.lua`
- Create: `lua/nvim-stm32/discover/project.lua`
- Create: `tests/discover_project_spec.lua`
- Create: `tests/fixtures/multi_image/CMakePresets.json`
- Create: `tests/fixtures/multi_image/CM7/app.ioc`
- Create: `tests/fixtures/multi_image/CM7/startup_stm32h747xx.s`
- Create: `tests/fixtures/multi_image/CM4/app.ioc`
- Create: `tests/fixtures/multi_image/CM4/startup_stm32h747xx.s`
- Modify: `lua/nvim-stm32/detect.lua`
- Modify: `tests/detect_root_spec.lua`
- Modify: `tests/detect_mcu_spec.lua`

**Interfaces:**

- Consumes: `model.project(spec)` and `model.image(spec)` from Task 1.
- Produces: `root.start_dir(bufnr?) -> string`
- Produces: `root.find(dir?) -> root, adapter, marker | nil, nil, nil`
- Produces: `signals.collect(project_root) -> Stm32Signal[]`
- Produces: `project.resolve(dir?) -> Project | nil, Stm32Error | nil`
- Preserves: `detect.root`, `detect.read_ioc`, `detect.mcu`, and `detect.target`.

- [ ] **Step 1: Add tests for strong roots and multiple images**

```lua
it("prefers the outer project over generated nested CMake", function()
  local found = assert(root.find(fixture("nucleo_cmake/cmake/stm32cubemx")))
  assert.equals(fixture("nucleo_cmake"), found)
end)

it("collects both images without flattening their cores", function()
  local resolved = assert(project.resolve(fixture("multi_image/CM4")))
  assert.equals(2, #resolved.images)
  assert.same({ "CM4", "CM7" }, vim.tbl_map(function(image)
    return image.id
  end, resolved.images))
end)

it("keeps the compatibility target on a single-image project", function()
  local target = assert(detect.target(fixture("nucleo_cmake/Core/Src")))
  assert.equals("STM32F429ZITx", target.mcu)
  assert.equals("cmake_presets", target.build_backend)
end)
```

The two `.ioc` files must contain different `Mcu.UserName` values and explicit
`Mcu.IP0=NVIC`, `ProjectManager.ProjectName`, and `ProjectManager.DeviceId`
fields so grouping does not depend on directory names alone.

- [ ] **Step 2: Run discovery tests and confirm failures**

Run:

```sh
scripts/test.sh tests/discover_project_spec.lua
scripts/test.sh tests/detect_root_spec.lua
scripts/test.sh tests/detect_mcu_spec.lua
```

Expected: FAIL because the new discovery modules do not exist and the old root
logic accepts the generated nested CMake directory.

- [ ] **Step 3: Implement root selection with strong-marker precedence**

Treat `CMakePresets.json` and a root-level `.ioc` as strong project markers.
Collect candidates while walking toward the Git root. Return the nearest strong
candidate. Only use the nearest `CMakeLists.txt` or `Makefile` candidate when no
strong marker exists.

```lua
local STRONG = { ["CMakePresets.json"] = true, ioc = true }

function M.find(dir)
  local candidates = walk_candidates(vim.fs.normalize(dir or M.start_dir()))
  for _, candidate in ipairs(candidates) do
    if candidate.strong then
      return candidate.root, candidate.adapter, candidate.marker
    end
  end
  local candidate = candidates[1]
  if candidate then
    return candidate.root, candidate.adapter, candidate.marker
  end
  return nil, nil, nil
end
```

- [ ] **Step 4: Move readers into `signals.lua` and collect all matches**

Each signal must include `source`, `file`, `mcu`, `confidence`, `board`, `core`,
`fpu`, and an `image_hint` derived from a build target, core field, or relative
directory. Keep `.ioc` precedence, but never stop after the first match.

```lua
function M.collect(project_root)
  local out = {}
  append_ioc_signals(out, project_root)
  append_startup_signals(out, project_root)
  append_linker_signals(out, project_root)
  append_cmake_signals(out, project_root)
  table.sort(out, by_precedence_then_path)
  return out
end
```

- [ ] **Step 5: Construct projects and retain compatibility wrappers**

`project.resolve()` groups exact signals by image hint and MCU/core identity. A
single group receives ID `application`. Explicit `CM4` and `CM7` hints become
stable uppercase IDs. Ambiguous unhinted signals stay in project provenance and
produce a structured warning.

`detect.target()` returns a compatibility table for the selected or sole image.
It must keep every existing field and set `project` and `image_id` as new fields.

- [ ] **Step 6: Run the focused and full gates**

Run:

```sh
scripts/test.sh tests/discover_project_spec.lua
scripts/test.sh tests/detect_root_spec.lua
scripts/test.sh tests/detect_mcu_spec.lua
```

Expected: all discovery tests pass, including the changed nested-CMake result.

Run: `scripts/test.sh && stylua --check lua/ tests/`

Expected: all tests pass.

- [ ] **Step 7: Commit project discovery**

```sh
git add lua/nvim-stm32/discover lua/nvim-stm32/detect.lua tests/discover_project_spec.lua tests/detect_root_spec.lua tests/detect_mcu_spec.lua tests/fixtures/multi_image
git commit -m "feat(discovery): resolve projects with multiple images"
```

## Task 3: Resolve real CMake configure and build presets

**Files:**

- Create: `lua/nvim-stm32/build/presets.lua`
- Create: `tests/presets_spec.lua`
- Create: `tests/fixtures/preset_inheritance/CMakePresets.json`
- Create: `tests/fixtures/preset_inheritance/CMakeUserPresets.json`
- Modify: `lua/nvim-stm32/backend/build/cmake_presets.lua`
- Modify: `tests/build_backends_spec.lua`

**Interfaces:**

- Consumes: `model.configuration(spec)`.
- Produces: `presets.load(root) -> document | nil, Stm32Error | nil`
- Produces: `presets.configurations(root) -> BuildConfiguration[] | nil, Stm32Error | nil`
- Produces: `presets.configure_command(project, config) -> CommandSpec`
- Produces: `presets.build_command(project, config, targets?) -> CommandSpec`
- Preserves: `backend.build.cmake_presets.presets(root) -> string[]`.

- [ ] **Step 1: Add preset relationship and command tests**

```lua
it("maps a build preset to its configure preset", function()
  local configs = assert(presets.configurations(fixture("preset_inheritance")))
  assert.same({
    {
      name = "Debug",
      configure_preset = "gcc-debug",
      build_preset = "Debug",
      binary_dir = fixture("preset_inheritance/build/gcc-debug"),
    },
  }, configs)
end)

it("uses cmake build presets instead of assuming build slash preset", function()
  local command = presets.build_command({ root = "/fw" }, {
    name = "Debug",
    configure_preset = "gcc-debug",
    build_preset = "Debug",
    binary_dir = "/fw/out/debug",
  })
  assert.same({ "cmake", "--build", "--preset", "Debug" }, command.argv)
end)

it("falls back to the resolved binary directory without a build preset", function()
  local command = presets.build_command({ root = "/fw" }, {
    name = "Size",
    configure_preset = "size",
    binary_dir = "/fw/out/size",
  })
  assert.same({ "cmake", "--build", "/fw/out/size" }, command.argv)
end)
```

- [ ] **Step 2: Run focused tests and confirm the missing-module failure**

Run:

```sh
scripts/test.sh tests/presets_spec.lua
scripts/test.sh tests/build_backends_spec.lua
```

Expected: FAIL because `nvim-stm32.build.presets` does not exist.

- [ ] **Step 3: Implement document loading and preset inheritance**

Load `CMakePresets.json`, then merge `CMakeUserPresets.json` when present. Resolve
`inherits` recursively with cycle detection. Hidden presets may be inherited but
must not appear as selectable configurations. Expand `${sourceDir}` and
`${presetName}` in `binaryDir`. Pair each visible build preset with its named
`configurePreset`. Add visible configure presets that have no build preset.

Return error codes `cmake-presets-read`, `cmake-presets-json`,
`cmake-presets-cycle`, and `cmake-presets-reference` with the source file and
preset name.

- [ ] **Step 4: Generate pure configure and build command specifications**

```lua
function M.configure_command(project, config)
  return model.command({
    argv = { "cmake", "--preset", config.configure_preset },
    cwd = project.root,
    lifecycle = "short",
  })
end

function M.build_command(project, config, targets)
  local argv = config.build_preset
      and { "cmake", "--build", "--preset", config.build_preset }
    or { "cmake", "--build", config.binary_dir }
  if targets and #targets > 0 then
    argv[#argv + 1] = "--target"
    vim.list_extend(argv, targets)
  end
  return model.command({ argv = argv, cwd = project.root, lifecycle = "short" })
end
```

- [ ] **Step 5: Keep the old backend functions as adapters**

`presets(root)` returns configuration names. `configure_cmd()` and `cmd()` return
the new command's argv. Existing tests for the coursework fixture must continue
to expect `cmake --preset Debug`; update only the build expectation to
`cmake --build --preset Debug` because the fixture defines a real build preset.

- [ ] **Step 6: Run the focused and full gates**

Run:

```sh
scripts/test.sh tests/presets_spec.lua
scripts/test.sh tests/build_backends_spec.lua
scripts/test.sh tests/build_spec.lua
```

Expected: all preset and compatibility tests pass.

Run: `scripts/test.sh && stylua --check lua/ tests/`

Expected: all tests pass.

- [ ] **Step 7: Commit preset resolution**

```sh
git add lua/nvim-stm32/build/presets.lua lua/nvim-stm32/backend/build/cmake_presets.lua tests/presets_spec.lua tests/build_backends_spec.lua tests/fixtures/preset_inheritance
git commit -m "feat(build): resolve CMake preset relationships"
```

## Task 4: Read executable targets through the CMake File API

**Files:**

- Create: `lua/nvim-stm32/build/file_api.lua`
- Create: `tests/file_api_spec.lua`
- Create: `tests/fixtures/file_api_reply/.cmake/api/v1/reply/index-test.json`
- Create: `tests/fixtures/file_api_reply/.cmake/api/v1/reply/codemodel-v2-test.json`
- Create: `tests/fixtures/file_api_reply/.cmake/api/v1/reply/target-app-test.json`
- Create: `tests/fixtures/file_api_reply/.cmake/api/v1/reply/target-helper-test.json`

**Interfaces:**

- Consumes: `BuildConfiguration.binary_dir` from Task 3.
- Produces: `file_api.write_query(binary_dir) -> query_path | nil, Stm32Error | nil`
- Produces: `file_api.reply(binary_dir) -> CmakeReply | nil, Stm32Error | nil`
- `CmakeReply.targets` contains target name, type, source directory, build directory, artifacts, and optional linker command fragments.

- [ ] **Step 1: Add query and codemodel parsing tests**

```lua
it("writes a client-owned codemodel query", function()
  local root = vim.fn.tempname()
  local path = assert(file_api.write_query(root))
  assert.equals(root .. "/.cmake/api/v1/query/client-nvim-stm32/query.json", path)
  local query = vim.json.decode(table.concat(vim.fn.readfile(path), "\n"))
  assert.same({ requests = { { kind = "codemodel", version = 2 } } }, query)
  vim.fn.delete(root, "rf")
end)

it("returns executable targets and ignores utility targets", function()
  local reply = assert(file_api.reply(fixture("file_api_reply")))
  assert.equals(1, #reply.targets)
  assert.equals("app", reply.targets[1].name)
  assert.equals("EXECUTABLE", reply.targets[1].type)
  assert.same({ fixture("file_api_reply/app.elf") }, reply.targets[1].artifacts)
end)
```

- [ ] **Step 2: Run the tests and confirm the missing-module failure**

Run: `scripts/test.sh tests/file_api_spec.lua`

Expected: FAIL because `nvim-stm32.build.file_api` does not exist.

- [ ] **Step 3: Implement an atomic query writer**

Create the client query directory with `vim.fn.mkdir(path, "p")`. Encode the
query with `vim.json.encode`, write to `query.json.tmp`, then rename it to
`query.json`. Return `cmake-file-api-query` if directory creation, writing, or
rename fails.

- [ ] **Step 4: Parse the newest valid index and codemodel reply**

List `index-*.json` files by modification time, newest first. Read the first
valid index containing a codemodel v2 reply. Resolve referenced JSON files under
the same reply directory. Keep targets whose type is `EXECUTABLE`. Normalize
relative artifacts against the target build directory.

Return errors `cmake-file-api-index`, `cmake-file-api-codemodel`, or
`cmake-file-api-target`, each with the failing path.

- [ ] **Step 5: Run the focused and full gates**

Run: `scripts/test.sh tests/file_api_spec.lua`

Expected: all File API tests pass.

Run: `scripts/test.sh && stylua --check lua/ tests/`

Expected: all tests pass.

- [ ] **Step 6: Commit File API support**

```sh
git add lua/nvim-stm32/build/file_api.lua tests/file_api_spec.lua tests/fixtures/file_api_reply
git commit -m "feat(build): read targets from CMake File API"
```

## Task 5: Track fresh artifacts per image and configuration

**Files:**

- Create: `lua/nvim-stm32/discover/artifacts.lua`
- Create: `tests/artifacts_spec.lua`
- Modify: `tests/fixtures/file_api_reply/.cmake/api/v1/reply/target-app-test.json`
- Modify: `lua/nvim-stm32/backend/build/init.lua`
- Modify: `tests/build_spec.lua`

**Interfaces:**

- Consumes: `CmakeReply.targets` from Task 4 and `model.artifact()` from Task 1.
- Produces: `artifacts.from_cmake(project, config, reply, build_id) -> Artifact[] | nil, Stm32Error | nil`
- Produces: `artifacts.from_tree(project, config, build_id) -> Artifact[] | nil, Stm32Error | nil`
- Produces: `artifacts.for_image(all, image_id, kind?) -> Artifact[]`
- Preserves: `backend.build.find_elf(target, opts) -> string | nil, string | nil`.

- [ ] **Step 1: Add tests for target mapping, freshness, and ambiguity**

```lua
it("maps an executable target to its image", function()
  local found = assert(artifacts.from_cmake(project, config, reply, 40))
  assert.equals("application", found[1].image_id)
  assert.equals("app", found[1].build_target)
  assert.equals("elf", found[1].kind)
end)

it("rejects an artifact path that does not exist", function()
  local found, err = artifacts.from_cmake(project, config, missing_reply, "op-1")
  assert.is_nil(found)
  assert.equals("artifact-missing", err.code)
end)

it("accepts an unchanged artifact after a successful no-op build", function()
  local found = assert(artifacts.from_cmake(project, config, reply, "op-2"))
  assert.equals("op-2", found[1].build_id)
end)

it("does not guess between unmapped executable targets", function()
  local found, err = artifacts.from_cmake(two_image_project, config, two_targets, "op-3")
  assert.is_nil(found)
  assert.equals("artifact-ambiguous", err.code)
end)
```

- [ ] **Step 2: Run focused tests and confirm failure**

Run:

```sh
scripts/test.sh tests/artifacts_spec.lua
scripts/test.sh tests/build_spec.lua
```

Expected: FAIL because `nvim-stm32.discover.artifacts` does not exist.

- [ ] **Step 3: Implement CMake target mapping and sibling artifacts**

Map target names to `Image.build_target`. A single executable may map to the sole
image. Several executables require explicit build-target identity. Record the ELF
and existing sibling `.hex`, `.bin`, and `.map` files. Use `vim.uv.fs_stat()`
nanosecond fields where available and seconds converted to nanoseconds otherwise.
Stamp each artifact with the successful operation ID as `build_id`. Accept an
unchanged file after a successful no-op build. Reject missing files and artifacts
outside the selected configuration's binary directory.

- [ ] **Step 4: Implement a conservative Make and legacy fallback**

Search only the selected configuration's declared binary directory. Return every
artifact candidate. The compatibility `find_elf()` succeeds only when exactly one
fresh ELF belongs to the selected image. It returns the old string error form by
formatting the structured error.

- [ ] **Step 5: Run the focused and full gates**

Run:

```sh
scripts/test.sh tests/artifacts_spec.lua
scripts/test.sh tests/build_spec.lua
```

Expected: all artifact and compatibility tests pass.

Run: `scripts/test.sh && stylua --check lua/ tests/`

Expected: all tests pass.

- [ ] **Step 6: Commit artifact tracking**

```sh
git add lua/nvim-stm32/discover/artifacts.lua lua/nvim-stm32/backend/build/init.lua tests/artifacts_spec.lua tests/build_spec.lua tests/fixtures/file_api_reply
git commit -m "feat(build): track fresh artifacts per image"
```

## Task 6: Add project-scoped session state

**Files:**

- Create: `lua/nvim-stm32/session.lua`
- Create: `tests/session_spec.lua`
- Modify: `lua/nvim-stm32/init.lua`

**Interfaces:**

- Consumes: normalized project roots and model records.
- Produces: `session.get(project_or_root) -> Session`
- Produces: `session.select(project_or_root, patch) -> Session`
- Produces: `session.record(project_or_root, result) -> Session`
- Produces: `session.clear(project_or_root?)`
- Session fields: `project_id`, `image_id`, `configuration`, `probe_serial`, `artifacts`, `last_result`.

- [ ] **Step 1: Add isolation and immutability tests**

```lua
it("isolates selections by normalized project root", function()
  session.select("/one/../one", { image_id = "app", configuration = "Debug" })
  session.select("/two", { image_id = "boot", configuration = "Release" })
  assert.equals("app", session.get("/one").image_id)
  assert.equals("boot", session.get("/two").image_id)
end)

it("does not expose mutable internal state", function()
  local value = session.select("/one", { image_id = "app" })
  value.image_id = "changed"
  assert.equals("app", session.get("/one").image_id)
end)
```

- [ ] **Step 2: Run the tests and confirm the missing-module failure**

Run: `scripts/test.sh tests/session_spec.lua`

Expected: FAIL because `nvim-stm32.session` does not exist.

- [ ] **Step 3: Implement the in-memory store**

Use a private `states` table keyed by `vim.fs.normalize(root)`. Merge patches into
a deep copy. `record()` replaces artifacts for the same image, configuration, and
kind while retaining unrelated artifacts. `clear(nil)` clears every session for
tests and explicit reset.

- [ ] **Step 4: Expose session access from the public module**

```lua
function M.get_session(root)
  return require("nvim-stm32.session").get(root)
end
```

Also expose `resolve_project(dir)` through `discover.project.resolve()`.

- [ ] **Step 5: Run the focused and full gates**

Run:

```sh
scripts/test.sh tests/session_spec.lua
scripts/test.sh tests/setup_spec.lua
```

Expected: all session and setup tests pass.

Run: `scripts/test.sh && stylua --check lua/ tests/`

Expected: all tests pass.

- [ ] **Step 6: Commit session state**

```sh
git add lua/nvim-stm32/session.lua lua/nvim-stm32/init.lua tests/session_spec.lua
git commit -m "feat(session): retain project selections and artifacts"
```

## Task 7: Make process execution cancellable and bounded

**Files:**

- Modify: `lua/nvim-stm32/process.lua`
- Modify: `tests/process_spec.lua`
- Modify: `lua/nvim-stm32/ui/float.lua`
- Modify: `tests/float_spec.lua`

**Interfaces:**

- Consumes: `CommandSpec` from Task 1, while accepting argv arrays for compatibility.
- Produces: `process.run(commands, opts, callback) -> ProcessHandle`
- `ProcessHandle`: `id`, `state()`, `cancel(reason?)`, `pid()`.
- `opts`: `cwd`, `env`, `on_output`, `max_output_bytes`, `timeout_ms`, `streaming`.
- Result adds: `cancelled`, `timed_out`, `truncated`, `started_ns`, `ended_ns`.

- [ ] **Step 1: Add cancellation, timeout, and output-bound tests**

```lua
it("returns a handle that cancels only the active child", function()
  local killed
  process.system = function(_, _, _)
    return { pid = 41, kill = function(_, signal) killed = signal end }
  end
  local handle = process.run({ { "long-job" } }, {}, function() end)
  handle.cancel("user")
  assert.equals(15, killed)
  assert.equals("cancelling", handle.state())
end)

it("bounds captured output but keeps streaming chunks", function()
  local streamed = {}
  local result = run_fake({ "12345", "67890" }, {
    max_output_bytes = 6,
    on_output = function(chunk) streamed[#streamed + 1] = chunk end,
  })
  assert.same({ "12345", "67890" }, streamed)
  assert.equals("567890", result.output)
  assert.is_true(result.truncated)
end)
```

- [ ] **Step 2: Run focused tests and confirm failures**

Run:

```sh
scripts/test.sh tests/process_spec.lua
scripts/test.sh tests/float_spec.lua
```

Expected: FAIL because `run()` returns no handle and does not bound output.

- [ ] **Step 3: Implement handles and compatibility normalization**

Normalize each argv array to a `CommandSpec`. Allocate an operation ID. Keep only
the active `vim.SystemObj` on the handle. State transitions are `pending`,
`running`, `cancelling`, `cancelled`, and `completed`.

On cancel, send SIGTERM to the active object through its `kill()` method. Schedule
a SIGKILL fallback after 1,000 ms only if that same object has not exited. Never
search for or kill a process by executable name.

- [ ] **Step 4: Add timeouts, output bounds, and streaming lifetime**

Default `max_output_bytes` to 1 MiB. Discard bytes from the start of captured
output when the limit is exceeded, but stream every chunk. A timeout calls the
same owned-child cancellation path and sets `timed_out = true`.

For `streaming = true`, a zero exit is still a completed stream. The callback runs
exactly once for success, failure, timeout, or cancellation.

- [ ] **Step 5: Connect presenter closure to an explicit stop action**

`float.open()` accepts `on_close`. A user close calls the supplied action once.
Programmatic close after success does not cancel a completed process. Keep the
existing Snacks and native-window paths equivalent.

- [ ] **Step 6: Run the focused and full gates**

Run:

```sh
scripts/test.sh tests/process_spec.lua
scripts/test.sh tests/float_spec.lua
```

Expected: all lifecycle tests pass without timing sleeps longer than 100 ms.

Run: `scripts/test.sh && stylua --check lua/ tests/`

Expected: all tests pass.

- [ ] **Step 7: Commit the process lifecycle**

```sh
git add lua/nvim-stm32/process.lua lua/nvim-stm32/ui/float.lua tests/process_spec.lua tests/float_spec.lua
git commit -m "feat(process): add cancellation and bounded streams"
```

## Task 8: Build through immutable operation plans

**Files:**

- Create: `lua/nvim-stm32/operation.lua`
- Create: `lua/nvim-stm32/operations/build.lua`
- Create: `lua/nvim-stm32/ui/plan.lua`
- Create: `tests/operation_spec.lua`
- Modify: `lua/nvim-stm32/backend/build/init.lua`
- Modify: `lua/nvim-stm32/ui/info.lua`
- Modify: `lua/nvim-stm32/health.lua`
- Modify: `lua/nvim-stm32/init.lua`
- Modify: `plugin/nvim-stm32.lua`
- Modify: `tests/build_spec.lua`
- Modify: `tests/info_spec.lua`
- Modify: `tests/health_spec.lua`

**Interfaces:**

- Consumes: project, configuration, artifacts, session, process, and CMake interfaces from Tasks 1 through 7.
- Produces: `build.plan(project, opts) -> OperationPlan | nil, Stm32Error | nil`
- Produces: `operation.run(plan, opts, callback) -> ProcessHandle`
- Produces: `build.current(opts?, callback?) -> ProcessHandle | nil`
- Produces: `ui.plan.lines(plan) -> string[]` and `ui.plan.show(plan)`.
- Public API: `nvim_stm32.plan(kind, opts)`, `nvim_stm32.run(kind, opts, callback)`.

- [ ] **Step 1: Add plan and compatibility tests**

```lua
it("plans query, configure, and build for the selected configuration", function()
  local plan = assert(build.plan(project, { configuration = "Debug" }))
  assert.equals("build", plan.kind)
  assert.equals("application", plan.images[1])
  assert.same({ "cmake", "--preset", "Debug" }, plan.commands[1].argv)
  assert.same({ "cmake", "--build", "--preset", "Debug" }, plan.commands[2].argv)
end)

it("records fresh artifacts after a successful build", function()
  local result = run_build_with_file_api_reply()
  assert.is_true(result.ok)
  assert.equals("application", result.artifacts[1].image_id)
  assert.equals(result.artifacts, session.get(project.root).artifacts)
end)

it(":STM32Plan is registered without setup", function()
  vim.g.loaded_nvim_stm32 = nil
  vim.cmd("runtime plugin/nvim-stm32.lua")
  assert.equals(2, vim.fn.exists(":STM32Plan"))
end)
```

- [ ] **Step 2: Run operation and existing build tests to confirm failures**

Run:

```sh
scripts/test.sh tests/operation_spec.lua
scripts/test.sh tests/build_spec.lua
scripts/test.sh tests/info_spec.lua
scripts/test.sh tests/health_spec.lua
```

Expected: FAIL because operation planning and `:STM32Plan` do not exist.

- [ ] **Step 3: Implement build plan creation**

Resolve the configuration from explicit options, then session state, then a sole
visible configuration. Return `configuration-required` when several choices
remain. Record the intended File API query path in plan metadata without writing
it. Build every selected image target in one CMake command when they share a
configuration.

The plan includes `project_id`, image IDs, command specifications, empty locks,
`reset_policy = "none"`, and metadata containing the configuration and File API
reply directory.

- [ ] **Step 4: Implement generic plan execution and build result assembly**

`operation.run()` deep-copies and validates the plan. Its build preflight writes
the File API query immediately before starting the configure command. It applies
the configured child environment to each command and delegates to `process.run()`.
The build completion handler reads the File API reply, resolves fresh artifacts,
records the result in session state, and reports structured errors without
mutating the project record.

- [ ] **Step 5: Migrate existing build entry points**

`backend.build.current()` delegates to `operations.build.current()`. Preserve the
existing preset picker and callback behavior. `find_elf()` reads the compatibility
artifact view. Existing callers continue to receive `result.elf` for a sole image.

- [ ] **Step 6: Add plan and configuration commands**

Register:

```lua
vim.api.nvim_create_user_command("STM32Plan", function(args)
  require("nvim-stm32.ui.plan").current(args.args ~= "" and args.args or "build")
end, { nargs = "?", complete = function() return { "build" } end })

vim.api.nvim_create_user_command("STM32SelectConfig", function()
  require("nvim-stm32.operations.build").select_configuration()
end, {})
```

The plan buffer lists project, configuration, images, cwd, and escaped argv on
separate lines. It is informational and never executes commands.

- [ ] **Step 7: Update info and health output**

Info must list project ID, each image and MCU, selected configuration, and known
artifacts. Health must distinguish missing CMake, missing File API reply before a
first configure, malformed replies, and successful project resolution.

- [ ] **Step 8: Run the focused and full gates**

Run:

```sh
scripts/test.sh tests/operation_spec.lua
scripts/test.sh tests/build_spec.lua
scripts/test.sh tests/info_spec.lua
scripts/test.sh tests/health_spec.lua
```

Expected: all operation, compatibility, info, and health tests pass.

Run: `scripts/test.sh && stylua --check lua/ tests/`

Expected: all tests pass.

- [ ] **Step 9: Commit operation-based builds**

```sh
git add lua/nvim-stm32/operation.lua lua/nvim-stm32/operations/build.lua lua/nvim-stm32/ui/plan.lua lua/nvim-stm32/backend/build/init.lua lua/nvim-stm32/ui/info.lua lua/nvim-stm32/health.lua lua/nvim-stm32/init.lua plugin/nvim-stm32.lua tests/operation_spec.lua tests/build_spec.lua tests/info_spec.lua tests/health_spec.lua
git commit -m "feat(build): execute immutable project plans"
```

## Task 9: Add explicit validation for the current firmware corpus

**Files:**

- Create: `scripts/validate-corpus.sh`
- Create: `scripts/validate_corpus.lua`
- Create: `lua/nvim-stm32/corpus.lua`
- Create: `tests/corpus_runner_spec.lua`
- Create: `tests/fixtures/corpus/s1/app/CMakePresets.json`
- Create: `tests/fixtures/corpus/s2/app/CMakePresets.json`
- Create: `tests/fixtures/corpus/build/ignored/CMakePresets.json`
- Modify: `README.md`

**Interfaces:**

- Consumes: public `resolve_project`, build planning, build execution, and structured results from Task 8.
- Produces: `scripts/validate-corpus.sh CORPUS_ROOT [--build]`.
- Exit 0 means every discovered project passed. Exit 1 means at least one failed. Exit 2 means command use or corpus discovery was invalid.

- [ ] **Step 1: Add tests for corpus enumeration and summaries**

Put reusable functions in `lua/nvim-stm32/corpus.lua` so tests can load them
without invoking the script entry point:

```lua
it("sorts firmware roots by relative path", function()
  local roots = runner.find_projects(fixture("corpus"))
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
  assert.matches("FAIL /two: build failed", table.concat(lines, "\n"), 1, true)
end)
```

- [ ] **Step 2: Run focused tests and confirm failure**

Run: `scripts/test.sh tests/corpus_runner_spec.lua`

Expected: FAIL because the corpus runner does not exist.

- [ ] **Step 3: Implement the Lua runner**

`corpus.find_projects(root)` finds `CMakePresets.json` files while excluding any path
component named `build`. For each project, select a real source file under
`Core/Src` when present, resolve from that directory, and verify that the MCU is
`STM32F429ZITx` or a compatible F429 wildcard.

Without `--build`, print project, images, configuration names, and resolved
binary directories. With `--build`, run each project's Debug configuration in
sequence through the public plugin API and wait with `vim.wait()` for its callback.
Print one PASS or FAIL line per project and a final count.

`scripts/validate_corpus.lua` reads arguments after `--`, calls
`require("nvim-stm32.corpus").main(args)`, and exits with
`vim.cmd("cquit " .. code)` for non-zero results or `vim.cmd("quitall")` for
success.

- [ ] **Step 4: Implement the shell entry point**

```sh
#!/bin/sh
set -eu

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
  echo "usage: scripts/validate-corpus.sh CORPUS_ROOT [--build]" >&2
  exit 2
fi

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
exec nvim --headless --noplugin -u "$repo_dir/tests/minimal_init.lua" \
  -l "$repo_dir/scripts/validate_corpus.lua" -- "$@"
```

Make the script executable. Reject a missing corpus root and an option other
than `--build` with exit 2.

- [ ] **Step 5: Run fixture tests and discovery against the real corpus**

Run: `scripts/test.sh tests/corpus_runner_spec.lua`

Expected: all runner tests pass.

Run: `scripts/validate-corpus.sh /Users/christiannucifora/Documents/University/CSSE3010/repo`

Expected: 13 PASS lines, each resolving an F429 project, and exit 0.

- [ ] **Step 6: Build every current project**

Run: `scripts/validate-corpus.sh /Users/christiannucifora/Documents/University/CSSE3010/repo --build`

Expected: every buildable project configures and builds, every successful result
contains a fresh application ELF, and the command exits 0. If a source project
has a genuine independent build failure, record its exact path and compiler output
in the PR instead of weakening detection or artifact checks.

- [ ] **Step 7: Run a normal Neovim smoke test through RPC**

Open a source file from `s5/dt` in the user's existing Neovim instance. Use its
RPC socket to prepend the implementation worktree to `runtimepath`, clear loaded
`nvim-stm32` Lua modules, and reload the plugin shim. Run `:STM32Info`,
`:STM32Plan build`, and `:STM32Build`. Verify the project root, Debug
configuration, command argv, streamed output, and final ELF. Close the plugin
output window and confirm no build child remains. Restore the original
`runtimepath` and loaded main-branch plugin after the test.

- [ ] **Step 8: Document the model and local validation command**

Update the README status, command list, CMake behavior, and development section.
State that the corpus script takes a path and is not part of public CI.

- [ ] **Step 9: Run final gates**

Run: `scripts/test.sh && stylua --check lua/ tests/ && git diff --check`

Expected: all tests pass, formatting is clean, and no whitespace errors remain.

- [ ] **Step 10: Commit corpus validation and docs**

```sh
git add lua/nvim-stm32/corpus.lua scripts/validate-corpus.sh scripts/validate_corpus.lua tests/corpus_runner_spec.lua tests/fixtures/corpus README.md
git commit -m "test(corpus): verify current F429 projects"
```

## Task 10: Review the completed foundation before flash work

**Files:**

- Modify only files needed to correct review findings.

**Interfaces:**

- The public compatibility behavior and all new interfaces in Tasks 1 through 9 are frozen for the next flash plan.

- [ ] **Step 1: Review the branch against the design**

Check these points directly:

- No code reads VS Code or ST bundle metadata.
- Current-buffer discovery stays inside the Git root.
- Single-image F429 projects remain zero-config.
- Multiple images are represented without selecting the wrong ELF.
- CMake commands honor configure and build preset relationships.
- File API artifacts are tied to an image and configuration.
- Every child receives the configured toolchain `PATH`.
- Cancellation touches only the active owned process.
- Existing commands and tests remain compatible.

- [ ] **Step 2: Run the complete software-only acceptance suite**

Run:

```sh
scripts/test.sh
stylua --check lua/ tests/
scripts/validate-corpus.sh /Users/christiannucifora/Documents/University/CSSE3010/repo
scripts/validate-corpus.sh /Users/christiannucifora/Documents/University/CSSE3010/repo --build
git diff --check main...HEAD
```

Expected: repository tests and formatting pass, 13 projects resolve, all buildable
projects build, and the branch has no whitespace errors.

- [ ] **Step 3: Stop on any failed review item**

If review or an acceptance command fails, record the exact command and output and
open a bounded correction task before the pull request. Do not weaken an assertion
or add a later-track feature to make this plan pass.

- [ ] **Step 4: Push the branch and open a pull request**

Push the implementation branch, open a PR against `main`, and wait for these
required checks:

- `Lua Format`
- `Tests (Neovim stable)`
- `Tests (Neovim nightly)`

Merge only after local acceptance and all required checks pass. Admin bypass
remains available for emergencies, not routine merges.
