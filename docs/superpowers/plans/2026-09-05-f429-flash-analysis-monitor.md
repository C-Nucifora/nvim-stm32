# F429 analysis, flash, and UART implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add clean, rebuild, safe build analysis, ST-LINK probe selection, flash and verify, mass erase, reset, and UART monitoring for the user's NUCLEO-F429ZI without requiring hardware during development.

**Architecture:** Pure parsers and driver modules produce validated records and command arguments. Operation modules resolve project context, artifacts, probes, locks, and safety policy before the shared executor starts a child process. CubeProgrammer is the preferred F429 backend, while `st-flash` and OpenOCD use the same driver contract and receive full command-generation coverage.

**Tech Stack:** Lua 5.1/LuaJIT, Neovim 0.11+, `vim.system`, plenary-busted, GNU Arm Embedded `size` and `objdump`, STM32CubeProgrammer 2.23, stlink 1.8, OpenOCD 0.12, POSIX `stty` and `cat`.

**Spec:** `docs/superpowers/specs/2026-09-04-neovim-native-stm32-suite-design.md`

## Global constraints

- The 13 firmware folders under `~/Documents/University/CSSE3010/repo` and the NUCLEO-F429ZI remain the first release gate.
- The coursework repository is read-only. Only ignored build output may change.
- Every backend returns structured argv. No generated command goes through a shell.
- `STM32_Programmer_CLI` resolution checks the explicit option, `PATH`, and versioned standalone install paths in numeric version order.
- Passive discovery may list devices, but it may not connect, reset, halt, erase, or program the target.
- Every hardware operation validates its complete artifact and command set before the first hardware command starts.
- A pinned backend never falls through to another backend after an unavailable-tool error or process failure.
- Flash uses the selected configuration and the fresh artifacts recorded by a successful build. It never globs for a convenient ELF.
- Multi-image ordering follows `project.flash_order`, then project image order. One final reset occurs only after every selected image is programmed and verified.
- Mass erase requires explicit confirmation and is never implied by another operation.
- Only a process started by the plugin may be cancelled by the plugin.
- The plugin core has no required Lua plugin dependency. Snacks remains optional.
- Neovim support remains 0.11 and newer on macOS and Linux.
- Required gates remain `scripts/test.sh` and `stylua --check lua/ tests/` on stable and nightly Neovim.

---

### Task 1: Shared selection context and model records

**Files:**

- Create: `lua/nvim-stm32/operations/context.lua`
- Modify: `lua/nvim-stm32/operations/build.lua`
- Modify: `lua/nvim-stm32/model.lua`
- Modify: `lua/nvim-stm32/session.lua`
- Modify: `lua/nvim-stm32/config.lua`
- Test: `tests/context_spec.lua`
- Test: `tests/model_spec.lua`
- Test: `tests/session_spec.lua`
- Test: `tests/config_spec.lua`

**Interfaces:**

- Consumes: `build.presets.configurations(root)`, `session.get(project)`, and validated `Project` records.
- Produces: `context.resolve(project, opts) -> { project, configuration, images } | nil, ModelError`, `model.probe(spec) -> Probe`, validated lock records on `model.plan`, and explicit session fields for `monitor_device` and `probe_serial`.

- [ ] **Step 1: Write failing shared-context tests**

  Cover explicit configuration and image selection, session fallback, sole-configuration fallback, all-image fallback, unknown selections, deduplication, and preservation of project order. The expected F429 context is literal:

  ```lua
  local resolved = assert(context.resolve(project, {
    configuration = "Debug",
    images = { "application" },
  }))
  assert.equals("Debug", resolved.configuration.name)
  assert.same({ "application" }, vim.tbl_map(function(image)
    return image.id
  end, resolved.images))
  ```

- [ ] **Step 2: Run the context tests and verify RED**

  Run: `scripts/test.sh tests/context_spec.lua`

  Expected: FAIL because `nvim-stm32.operations.context` does not exist.

- [ ] **Step 3: Implement context resolution and delegate build planning to it**

  Export these functions so later operations do not duplicate build's private selection rules:

  ```lua
  function M.configurations(project) end
  function M.resolve_configuration(project, opts, available) end
  function M.resolve_images(project, opts) end
  function M.resolve(project, opts)
    return {
      project = model.project(project),
      configuration = model.configuration(configuration),
      images = selected_image_records,
    }
  end
  ```

  Keep `operations.build.plan()` output byte-for-byte compatible except for harmless table key order.

- [ ] **Step 4: Write failing model and configuration tests**

  Add tests for a probe record with `backend`, `serial`, optional firmware, voltage, and target identity. Reject missing or empty serial numbers. Add plan lock validation for dense `{ kind, id }` records. Require `monitor.baud` to be a positive integer and reject zero, negative, fractional, and string values.

- [ ] **Step 5: Implement records and explicit session defaults**

  ```lua
  function M.probe(spec)
    return {
      backend = required_string_value,
      serial = required_string_value,
      transport = optional_string,
      firmware = optional_string,
      target = optional_table,
      voltage_mv = optional_number,
      provenance = table_or_empty,
    }
  end
  ```

  `model.plan()` must normalize each lock through `model.lock()`. `session.empty_state()` must include `monitor_device = nil` and retain `probe_serial = nil`.

- [ ] **Step 6: Run focused and full tests**

  Run:

  ```sh
  scripts/test.sh tests/context_spec.lua
  scripts/test.sh tests/model_spec.lua
  scripts/test.sh tests/config_spec.lua
  scripts/test.sh tests/operation_spec.lua
  scripts/test.sh
  ```

  Expected: all pass with zero errors.

- [ ] **Step 7: Commit**

  ```sh
  git add lua/nvim-stm32/operations/context.lua lua/nvim-stm32/operations/build.lua lua/nvim-stm32/model.lua lua/nvim-stm32/session.lua lua/nvim-stm32/config.lua tests/context_spec.lua tests/model_spec.lua tests/session_spec.lua tests/config_spec.lua
  git commit -m "refactor(operations): share project selection context"
  ```

### Task 2: Build lifecycle, linker memory, and GNU analysis

**Files:**

- Create: `lua/nvim-stm32/inspect/linker.lua`
- Create: `lua/nvim-stm32/inspect/size.lua`
- Create: `lua/nvim-stm32/inspect/objdump.lua`
- Create: `lua/nvim-stm32/operations/analyze.lua`
- Create: `lua/nvim-stm32/ui/analysis.lua`
- Modify: `lua/nvim-stm32/tools.lua`
- Modify: `lua/nvim-stm32/init.lua`
- Modify: `plugin/nvim-stm32.lua`
- Test: `tests/build_lifecycle_spec.lua`
- Test: `tests/linker_spec.lua`
- Test: `tests/size_spec.lua`
- Test: `tests/objdump_spec.lua`
- Test: `tests/analyze_spec.lua`

**Interfaces:**

- Consumes: fresh ELF artifacts from the resolved session context, optional matching MAP artifacts for provenance, and linker signal paths retained on each image target.
- Produces: `build.plan(project, { mode = "build"|"clean"|"rebuild" })`, `linker.parse(text) -> MemoryRegion[] | nil, ModelError`, `size.parse(text) -> SizeSummary | nil, ModelError`, `objdump.parse_sections(text) -> ElfSection[] | nil, ModelError`, `analyze.plan(project, opts) -> OperationPlan`, and `analyze.complete(plan, process_result) -> Result` with `metadata.analysis`.

- [ ] **Step 1: Write failing build lifecycle tests**

  Keep `mode = "build"` and omitted mode identical to current behavior. Pin clean and rebuild commands for CMake presets, plain CMake, and Make:

  ```lua
  { "cmake", "--build", "--preset", "Debug", "--target", "clean" }
  { "cmake", "--build", "build", "--target", "clean" }
  { "make", "clean" }
  ```

  Rebuild runs clean, configure where applicable, then build. Clean returns no artifacts and removes matching session artifacts only after success. A failed clean leaves the prior successful artifacts in the session.

- [ ] **Step 2: Run build lifecycle tests and verify RED**

  Run: `scripts/test.sh tests/build_lifecycle_spec.lua`

  Expected: FAIL because build planning does not accept clean or rebuild modes.

- [ ] **Step 3: Implement clean and rebuild without changing build output**

  Add `:STM32Clean` and `:STM32Rebuild`. Add `clean` and `rebuild` to `:STM32Plan` completion. Rebuild performs fresh artifact discovery and records a new build ID. Clean never fabricates a build result.

- [ ] **Step 4: Write failing linker parser tests using the F429 fixture**

  Assert exact parsed values for the real CubeMX `MEMORY` block:

  ```lua
  assert.same({
    { name = "RAM", attributes = "xrw", origin = 0x20000000, length = 192 * 1024 },
    { name = "CCMRAM", attributes = "xrw", origin = 0x10000000, length = 64 * 1024 },
    { name = "FLASH", attributes = "rx", origin = 0x08000000, length = 2048 * 1024 },
  }, assert(linker.parse(contents)))
  ```

  Add malformed origin, malformed length suffix, overflow, duplicate name, and overlapping-region cases.

- [ ] **Step 5: Run linker tests and verify RED**

  Run: `scripts/test.sh tests/linker_spec.lua`

  Expected: FAIL because the parser module does not exist.

- [ ] **Step 6: Implement a pure linker `MEMORY` parser**

  Accept hexadecimal or decimal origins and `K`, `M`, or byte lengths. Strip C comments before matching. Return structured errors instead of partial regions. Add `linker.flash_region(regions)` which returns the sole region named `FLASH`, case-insensitively, or an ambiguity error.

- [ ] **Step 7: Write failing GNU size and objdump parser tests**

  Use fixtures matching `arm-none-eabi-size -B -x` and `arm-none-eabi-objdump -h` output. Assert the size summary's literal `text`, `data`, and `bss` values. Assert each objdump section's size, VMA, LMA, and flags. Debug sections and non-allocated sections must not count toward memory use.

  ```lua
  local summary = assert(size.parse(size_output))
  assert.same({ text = 0x4cbc, data = 0x68, bss = 0xed8 }, summary)

  local report = assert(objdump.report(assert(objdump.parse_sections(section_output)), regions))
  assert.equals(0x4d24, report.totals.flash)
  assert.equals(0xf40, report.totals.ram)
  ```

- [ ] **Step 8: Implement size, objdump, and region accounting**

  Parse the Berkeley size row and objdump's two-line section records. Runtime bytes use VMA and flash load bytes use LMA. Reject an allocated or loaded section whose end exceeds its matched region. Sum occupied bytes, not address-span padding, so the F429 result matches GNU size's `text + data` flash and `data + bss` RAM totals. Keep unassigned and debug sections visible but out of percentage totals.

- [ ] **Step 9: Add tool resolution and failing analysis-operation tests**

  Add `tools.size(cfg)` and `tools.objdump(cfg)` through the existing toolchain resolver. The plan must generate both commands in this order:

  ```lua
  model.command({
    argv = { resolved_size_path, "-B", "-x", elf.path },
    cwd = project.root,
    image_id = image.id,
    lifecycle = "short",
  })
  model.command({
    argv = { resolved_objdump_path, "-h", elf.path },
    cwd = project.root,
    image_id = image.id,
    lifecycle = "short",
  })
  ```

  Test wrong configuration, no ELF, several ELF artifacts, missing linker signal, missing `arm-none-eabi-size`, process failure, and successful metadata.

- [ ] **Step 10: Implement analysis planning, completion, and UI**

  Register `analyze` in `init.operation_module`. Capture command output separately through the shared executor so the two parsers never guess where one tool's output ends. `:STM32Analyze` displays one line per memory region with used bytes, total bytes, and percentage, followed by section rows. `:STM32Plan analyze` shows both exact argv lists without running either tool.

- [ ] **Step 11: Verify against the real `s5/dt` ELF**

  Run the operation against:

  `/Users/christiannucifora/Documents/University/CSSE3010/repo/s5/dt/build/Debug/dt.elf`

  Compare its summary with direct `arm-none-eabi-size -B -x` output and its region accounting with direct `arm-none-eabi-objdump -h` output. The plugin must not change any source file.

- [ ] **Step 12: Run full tests and commit**

  ```sh
  scripts/test.sh
  stylua --check lua/ tests/
  git add lua/nvim-stm32/inspect lua/nvim-stm32/operations/build.lua lua/nvim-stm32/operations/analyze.lua lua/nvim-stm32/ui/analysis.lua lua/nvim-stm32/tools.lua lua/nvim-stm32/init.lua plugin/nvim-stm32.lua tests/build_lifecycle_spec.lua tests/linker_spec.lua tests/size_spec.lua tests/objdump_spec.lua tests/analyze_spec.lua
  git commit -m "feat(build): add lifecycle and F429 analysis"
  ```

### Task 3: Pure programmer drivers and backend selection

**Files:**

- Create: `lua/nvim-stm32/drivers/cubeprogrammer.lua`
- Create: `lua/nvim-stm32/drivers/stlink.lua`
- Create: `lua/nvim-stm32/drivers/openocd.lua`
- Create: `lua/nvim-stm32/drivers/flash.lua`
- Modify: `lua/nvim-stm32/tools.lua`
- Modify: `lua/nvim-stm32/targets.lua`
- Test: `tests/cubeprogrammer_driver_spec.lua`
- Test: `tests/stlink_driver_spec.lua`
- Test: `tests/openocd_driver_spec.lua`
- Test: `tests/flash_drivers_spec.lua`

**Interfaces:**

- Consumes: resolved tool paths, validated probes, artifacts, image targets, and optional flash addresses.
- Produces: programming drivers with `id`, `available(cfg)`, `identify_command(tool, probe)`, `program_command(tool, request)`, `erase_command(tool, probe)`, and `reset_command(tool, probe)`. CubeProgrammer and stlink also expose optional `list_command(tool)` and `parse_probes(output)` capabilities; OpenOCD does not pretend it can enumerate USB probes.

- [ ] **Step 1: Write failing CubeProgrammer driver tests**

  Pin exact structured commands for the installed 2.23 CLI:

  ```lua
  assert.same({ programmer, "-l", "st-link-only" }, driver.list_command(programmer).argv)
  assert.same({
    programmer,
    "-c", "port=SWD", "mode=UR", "sn=ABC123",
    "-w", "/tmp/app.elf", "-v",
  }, driver.program_command(programmer, request).argv)
  assert.same({
    programmer,
    "-c", "port=SWD", "mode=UR", "sn=ABC123",
    "-e", "all",
  }, driver.erase_command(programmer, probe).argv)
  ```

  The program command must not contain `-rst`. Reset is a separate final command.

- [ ] **Step 2: Run CubeProgrammer driver tests and verify RED**

  Run: `scripts/test.sh tests/cubeprogrammer_driver_spec.lua`

  Expected: FAIL because the driver does not exist.

- [ ] **Step 3: Implement CubeProgrammer commands and parsers**

  `identify_command` uses `mode=HOTPLUG` so an explicit identity check does not request reset. Parse probe-list blocks into stable serial and firmware fields. Parse connection output for device ID, device name, and voltage without treating missing optional fields as success evidence.

- [ ] **Step 4: Write failing stlink and OpenOCD driver tests**

  Pin these F429 forms:

  ```lua
  { st_flash, "--serial", "0xABC123", "write", "/tmp/app.bin", "0x08000000" }
  { st_flash, "--serial", "0xABC123", "erase" }
  { st_flash, "--serial", "0xABC123", "reset" }
  ```

  ```lua
  {
    openocd,
    "-f", "interface/stlink.cfg",
    "-c", "adapter serial ABC123",
    "-f", "target/stm32f4x.cfg",
    "-c", "program /tmp/app.elf verify; shutdown",
  }
  {
    openocd,
    "-f", "interface/stlink.cfg",
    "-c", "adapter serial ABC123",
    "-f", "target/stm32f4x.cfg",
    "-c", "init; reset run; shutdown",
  }
  ```

  OpenOCD quoting stays inside individual argv entries. No shell interprets the strings.

- [ ] **Step 5: Implement stlink and OpenOCD drivers**

  stlink accepts only a BIN plus a validated address. Its program parser requires the tool's verification-success marker. Add `tools.stinfo(cfg)` which uses an executable `st-info` beside an explicit `st-flash` first, then searches `PATH`. Its passive command is `{ st_info, "--probe" }`. OpenOCD accepts ELF and includes `verify`; every short-lived OpenOCD command ends in `shutdown`. A program command and final reset are separate OpenOCD invocations so a failed verification cannot reset the MCU.

  Add a data-driven observed-device table in `targets.lua`. The STM32F429 entry accepts debug ID `0x419`, shared by STM32F42x/F43x devices, and records the DBGMCU IDCODE address `0xE0042000`. Driver code may compare observed IDs with this table, but it may not branch on the F4 family name. CubeProgrammer parses `Device ID`; stlink uses the selected record from `st-info --probe`; OpenOCD reads the configured IDCODE address with `mdw` and parses the low 12-bit device ID.

- [ ] **Step 6: Write and implement backend registry tests**

  `drivers.flash.resolve(cfg, opts)` follows explicit option, configured pin, then `flash_order`. An unavailable pinned backend returns `flash-backend-unavailable`; it does not try the next tool. The automatic path returns the first available driver and resolved executable.

- [ ] **Step 7: Run full tests and commit**

  ```sh
  scripts/test.sh
  stylua --check lua/ tests/
  git add lua/nvim-stm32/drivers lua/nvim-stm32/tools.lua lua/nvim-stm32/targets.lua tests/*driver_spec.lua tests/flash_drivers_spec.lua tests/targets_spec.lua
  git commit -m "feat(flash): add pure programmer drivers"
  ```

### Task 4: Passive probe discovery and selection

**Files:**

- Create: `lua/nvim-stm32/probes.lua`
- Create: `lua/nvim-stm32/ui/probes.lua`
- Modify: `lua/nvim-stm32/session.lua`
- Modify: `lua/nvim-stm32/init.lua`
- Modify: `plugin/nvim-stm32.lua`
- Test: `tests/probes_spec.lua`
- Test: `tests/probes_ui_spec.lua`

**Interfaces:**

- Consumes: optional driver `list_command` and `parse_probes` capabilities, `process.run`, and session `probe_serial`.
- Produces: `probes.enumerate(cfg, callback) -> Handle`, `probes.resolve(project, list, opts) -> Probe | nil, ModelError`, and `:STM32SelectProbe`.

- [ ] **Step 1: Write failing passive-enumeration tests**

  Use a fake CubeProgrammer executable that records argv and prints two canned ST-LINK blocks. Assert that the only argv is `{ tool, "-l", "st-link-only" }` and that records preserve serial numbers and firmware versions. Add a fake `st-info --probe` fallback test. OpenOCD alone must return `probe-enumerator-unavailable` rather than connect to guess a device.

- [ ] **Step 2: Run probe tests and verify RED**

  Run: `scripts/test.sh tests/probes_spec.lua`

  Expected: FAIL because the coordinator does not exist.

- [ ] **Step 3: Implement enumeration and deterministic selection**

  Enumerator precedence is CubeProgrammer, then `st-info`, independent of the programming backend. Selection precedence is `opts.probe_serial`, session serial, then the sole detected probe. No probes returns `probe-not-found`; several probes return `probe-selection-required`. A stale requested serial returns `probe-not-found` and never silently selects another probe.

- [ ] **Step 4: Add and implement the selector UI tests**

  `:STM32SelectProbe` lists `SERIAL (firmware)` labels through `vim.ui.select`, saves the chosen serial for the current project, and changes no state when the picker is cancelled. The command is lazy-load safe and does not call setup.

- [ ] **Step 5: Confirm health remains passive**

  Add a test that `health.check()` resolves tools but never calls probe enumeration. Health may say that probe enumeration is available; it may not open the probe.

- [ ] **Step 6: Run full tests and commit**

  ```sh
  scripts/test.sh
  stylua --check lua/ tests/
  git add lua/nvim-stm32/probes.lua lua/nvim-stm32/ui/probes.lua lua/nvim-stm32/session.lua lua/nvim-stm32/init.lua plugin/nvim-stm32.lua lua/nvim-stm32/health.lua tests/probes_spec.lua tests/probes_ui_spec.lua tests/health_spec.lua
  git commit -m "feat(probes): discover and select ST-LINK devices"
  ```

### Task 5: Locking and the shared operation executor

**Files:**

- Create: `lua/nvim-stm32/locks.lua`
- Modify: `lua/nvim-stm32/process.lua`
- Modify: `lua/nvim-stm32/operation.lua`
- Modify: `lua/nvim-stm32/operations/build.lua`
- Test: `tests/locks_spec.lua`
- Test: `tests/process_spec.lua`
- Test: `tests/operation_spec.lua`

**Interfaces:**

- Consumes: validated plans and the current sequential process runner.
- Produces: `locks.acquire(owner_id, requested) -> release | nil, ModelError`, process results with `command_index` and `commands`, and `operation.execute(plan, opts, hooks, callback) -> Handle`.

- [ ] **Step 1: Write failing lock-manager tests**

  Test atomic acquisition of all requested locks, contention diagnostics, release exactly once, and successful reacquisition after release. A failed second lock acquisition must not retain the first lock.

- [ ] **Step 2: Run lock tests and verify RED**

  Run: `scripts/test.sh tests/locks_spec.lua`

  Expected: FAIL because the lock manager does not exist.

- [ ] **Step 3: Implement the in-memory lock manager**

  Use keys derived without delimiter collisions:

  ```lua
  local function same_lock(a, b)
    return a.kind == b.kind and a.id == b.id
  end
  ```

  Return a closure that releases only locks still owned by that operation ID.

- [ ] **Step 4: Write failing process and executor tests**

  Add `command_index` expectations for success, middle-command failure, cancellation, timeout, and spawn failure. Each entry in `result.commands` must retain its own argv, output, exit code, and signal so analysis and target-identification parsers never split aggregated output. Write executor tests for lock release on every terminal path and no release when cancellation is merely requested but the child has not exited.

- [ ] **Step 5: Add `command_index` without changing process semantics**

  Preserve ordered execution, bounded output, callback-once behavior, SIGTERM and same-child SIGKILL fallback. The result identifies the last started command with a one-based index and contains a dense list of completed command results. Add `opts.after_command(command_result)`; returning `nil, err` stops before the next child and attaches that structured error to the terminal process result.

- [ ] **Step 6: Extract the generic executor**

  ```lua
  function M.execute(plan, opts, hooks, callback)
    -- model.plan copy
    -- hooks.validate(plan)
    -- tool preflight
    -- hooks.preflight(plan, cfg)
    -- lock acquisition
    -- process.run with hooks.after_command
    -- hooks.complete(plan, process_result)
    -- release after terminal callback
  end
  ```

  Keep `operation.run(plan, opts, callback)` as the build-compatible wrapper. Build still writes its File API query immediately before execution and records artifacts only after a zero exit.

- [ ] **Step 7: Run the full existing operation and process suites**

  ```sh
  scripts/test.sh tests/locks_spec.lua
  scripts/test.sh tests/process_spec.lua
  scripts/test.sh tests/operation_spec.lua
  scripts/test.sh
  ```

- [ ] **Step 8: Commit**

  ```sh
  git add lua/nvim-stm32/locks.lua lua/nvim-stm32/process.lua lua/nvim-stm32/operation.lua lua/nvim-stm32/operations/build.lua tests/locks_spec.lua tests/process_spec.lua tests/operation_spec.lua
  git commit -m "refactor(operations): add locks and shared execution"
  ```

### Task 6: Flash with verification, reset, and mass erase operations

**Files:**

- Create: `lua/nvim-stm32/flash/layout.lua`
- Create: `lua/nvim-stm32/operations/flash.lua`
- Modify: `lua/nvim-stm32/init.lua`
- Modify: `lua/nvim-stm32/ui/plan.lua`
- Test: `tests/flash_layout_spec.lua`
- Test: `tests/flash_operation_spec.lua`

**Interfaces:**

- Consumes: shared context, fresh session artifacts, linker regions, selected backend, selected probe, and shared executor.
- Produces: `layout.resolve(context, artifacts, backend) -> FlashImage[] | nil, ModelError`, `flash.plan(action, project, opts) -> OperationPlan`, and `flash.current(action, opts, callback) -> composite Handle`, where action is `flash`, `erase`, or `reset`.

- [ ] **Step 1: Write failing artifact and layout safety tests**

  For CubeProgrammer and OpenOCD, accept exactly one fresh ELF per selected image and configuration. For stlink, accept exactly one fresh BIN plus the image's explicit address or the sole parsed FLASH origin. Reject wrong configuration, missing build ID, multiple matching artifacts, a symlink outside the selected binary directory, zero or unaligned addresses, binary size beyond the FLASH region, and overlapping selected image ranges.

- [ ] **Step 2: Run layout tests and verify RED**

  Run: `scripts/test.sh tests/flash_layout_spec.lua`

  Expected: FAIL because the layout module does not exist.

- [ ] **Step 3: Implement complete preflight layout resolution**

  Order selected images through `project.flash_order` and then project order. Re-stat and realpath each artifact. Do all validation before returning any driver command. Return records shaped as:

  ```lua
  {
    image_id = "application",
    artifact = artifact,
    address = 0x08000000,
    size = file_size,
    region = { name = "FLASH", origin = 0x08000000, length = 0x200000 },
  }
  ```

- [ ] **Step 4: Write failing plan tests for every action**

  Pin these policies:

  - `flash`: identify the connected target, program and verify each ordered image, then reset once.
  - `reset`: one reset command, no artifact or build.
  - `erase`: identify the connected target, then run one mass-erase command with no artifact or build. `opts.confirmed == true` is mandatory.
  - Every hardware plan owns `{ kind = "probe", id = backend .. ":" .. serial }`.
  - `reset` also identifies the target before reset when the chosen driver supports identity inspection.
  - Parsed target identity is compared before the first destructive or state-changing command. A mismatch returns `target-mismatch` unless `opts.allow_target_mismatch == true` for that one plan.

- [ ] **Step 5: Implement plan construction and phase metadata**

  Keep phase records aligned with commands:

  ```lua
  plan.metadata.steps = {
    { phase = "identify", image_id = nil },
    { phase = "program-verify", image_id = "application", artifact = artifact },
    { phase = "reset", image_id = nil },
  }
  ```

  The executor's per-command hook parses identity output and returns a structured error before `program-verify`, `erase`, or `reset` starts. `:STM32Plan` remains non-connecting and shows the identify command as the first planned step.

  `:STM32Plan` must render backend, probe serial, artifacts, addresses, phases, and reset policy.

- [ ] **Step 6: Write failing execution and composite-build tests**

  Fake tools must prove:

  - `STM32Flash` runs the selected build first by default.
  - The immediately returned successful build result feeds the flash plan.
  - `build = false` requires a matching fresh session artifact.
  - Write or verification failure stops later images and the final reset.
  - Reset runs exactly once after all program/verify steps succeed.
  - Cancellation delegates to whichever build or hardware handle is active.
  - The failure result names backend, phase, image, command, and captured output.
  - Failed hardware operations do not replace the successful build artifacts.

- [ ] **Step 7: Implement execution through the shared executor**

  Use one composite handle for build then flash. Its `state`, `pid`, and `cancel` delegate to the active child. Once cancelled, it may not start the next stage even if the earlier callback races with cancellation.

- [ ] **Step 8: Run full tests and commit**

  ```sh
  scripts/test.sh
  stylua --check lua/ tests/
  git add lua/nvim-stm32/flash/layout.lua lua/nvim-stm32/operations/flash.lua lua/nvim-stm32/init.lua lua/nvim-stm32/ui/plan.lua tests/flash_layout_spec.lua tests/flash_operation_spec.lua
  git commit -m "feat(flash): add safe F429 programming operations"
  ```

### Task 7: Hardware command UI and confirmations

**Files:**

- Create: `lua/nvim-stm32/ui/operation.lua`
- Modify: `lua/nvim-stm32/ui/float.lua`
- Modify: `plugin/nvim-stm32.lua`
- Modify: `lua/nvim-stm32/init.lua`
- Test: `tests/operation_ui_spec.lua`
- Test: `tests/float_spec.lua`

**Interfaces:**

- Consumes: public operation plan/run calls and the shared float presenter.
- Produces: `:STM32Flash`, `:STM32Erase`, `:STM32Reset`, and operation-specific output titles.

- [ ] **Step 1: Write failing command and confirmation tests**

  Assert command registration without setup. `:STM32Erase` calls `vim.fn.confirm` with a message naming the project and target, and only a literal affirmative result passes `confirmed = true`. Cancellation must create no plan and spawn no process.

- [ ] **Step 2: Run UI tests and verify RED**

  Run: `scripts/test.sh tests/operation_ui_spec.lua`

  Expected: FAIL because the commands do not exist.

- [ ] **Step 3: Generalize the presenter without breaking build**

  Add `title` and `close_on_success` options. Build retains its current title and timed close. Flash, reset, and erase use their operation names. All failures remain open with the full bounded output.

- [ ] **Step 4: Implement the command wrappers**

  Register:

  ```vim
  :STM32Flash
  :STM32Erase
  :STM32Reset
  :STM32Plan flash
  :STM32Plan erase
  :STM32Plan reset
  ```

  Verification is mandatory inside every flash backend's program command. There is no standalone verify command because CubeProgrammer 2.23's `-v` verifies the preceding programming operation rather than accepting an independent firmware file.

- [ ] **Step 5: Run full tests and commit**

  ```sh
  scripts/test.sh
  stylua --check lua/ tests/
  git add lua/nvim-stm32/ui/operation.lua lua/nvim-stm32/ui/float.lua lua/nvim-stm32/init.lua plugin/nvim-stm32.lua tests/operation_ui_spec.lua tests/float_spec.lua
  git commit -m "feat(ui): expose flash erase and reset commands"
  ```

### Task 8: UART device selection and owned streaming

**Files:**

- Create: `lua/nvim-stm32/monitor/devices.lua`
- Create: `lua/nvim-stm32/drivers/uart.lua`
- Create: `lua/nvim-stm32/operations/monitor.lua`
- Create: `lua/nvim-stm32/ui/monitor.lua`
- Modify: `lua/nvim-stm32/operation.lua`
- Modify: `lua/nvim-stm32/session.lua`
- Modify: `lua/nvim-stm32/health.lua`
- Modify: `lua/nvim-stm32/init.lua`
- Modify: `plugin/nvim-stm32.lua`
- Test: `tests/monitor_devices_spec.lua`
- Test: `tests/uart_driver_spec.lua`
- Test: `tests/monitor_operation_spec.lua`
- Test: `tests/monitor_ui_spec.lua`

**Interfaces:**

- Consumes: configured or discovered serial device, monitor baud, operation locks, process streaming, and float presenter.
- Produces: `devices.list(opts) -> string[]`, `uart.commands(device, baud, platform) -> CommandSpec[]`, `monitor.plan(project, opts) -> OperationPlan`, and `:STM32Monitor`.

- [ ] **Step 1: Write failing platform and device tests**

  Assert Darwin uses `/dev/cu.usbmodem*` and `stty -f`; Linux uses `/dev/ttyACM*` and `stty -F`. Sort and deduplicate candidates. Discovery must only stat paths and must never open a device.

- [ ] **Step 2: Run device tests and verify RED**

  Run: `scripts/test.sh tests/monitor_devices_spec.lua`

  Expected: FAIL because the monitor device module does not exist.

- [ ] **Step 3: Implement platform-aware discovery and validation**

  `devices.validate` requires an existing character device by default. Tests may inject `stat` and glob functions. Unsupported systems return `monitor-platform-unsupported`.

- [ ] **Step 4: Write failing UART driver tests**

  Pin exact argv, including a path containing spaces:

  ```lua
  {
    "stty", "-f", "/dev/cu.usb modem", "115200",
    "raw", "-echo", "cs8", "-parenb", "-cstopb", "clocal",
  }
  { "cat", "/dev/cu.usb modem" }
  ```

  The `stty` command has a 5000 ms timeout. The `cat` command has `lifecycle = "stream"` and no timeout.

- [ ] **Step 5: Implement pure UART commands**

  Return two model commands. Do not use redirection or shell syntax. A failed setup command prevents the stream command through the normal sequential runner.

- [ ] **Step 6: Write failing monitor planning and lifecycle tests**

  Selection precedence is explicit device, configured device, valid session device, sole discovered device, then picker. A missing explicit or stale configured path returns `monitor-device-not-found`. Several discovered devices return `monitor-device-required` until UI selection occurs.

  The plan owns `{ kind = "serial-device", id = device }`, has reset policy `none`, and stores device and baud in metadata. Test lock contention, setup failure, stream EOF, disconnection, cancellation during setup, cancellation during streaming, and release only after the child exits.

- [ ] **Step 7: Implement monitor execution and UI**

  `:STM32Monitor` selects when needed, opens an output window with auto-close disabled, streams bytes unchanged, and closes only the child it owns when the window closes. A clean EOF leaves the buffer open with `monitor ended`; user cancellation leaves `monitor stopped`; a nonzero exit leaves diagnostics visible.

- [ ] **Step 8: Add passive health reporting**

  Report platform support, `stty`, `cat`, configured device validity, and current candidate paths. Do not open a device or start a monitor from health.

- [ ] **Step 9: Run full tests and commit**

  ```sh
  scripts/test.sh
  stylua --check lua/ tests/
  git add lua/nvim-stm32/monitor lua/nvim-stm32/drivers/uart.lua lua/nvim-stm32/operations/monitor.lua lua/nvim-stm32/ui/monitor.lua lua/nvim-stm32/operation.lua lua/nvim-stm32/session.lua lua/nvim-stm32/health.lua lua/nvim-stm32/init.lua plugin/nvim-stm32.lua tests/monitor_devices_spec.lua tests/uart_driver_spec.lua tests/monitor_operation_spec.lua tests/monitor_ui_spec.lua
  git commit -m "feat(monitor): add owned UART streaming"
  ```

### Task 9: Fake-tool integration, normal Neovim gate, and documentation

**Files:**

- Create: `tests/integration/fake_programmer.sh`
- Create: `tests/integration/fake_st_flash.sh`
- Create: `tests/integration/fake_openocd.sh`
- Create: `tests/integration/fake_stty.sh`
- Create: `tests/integration/fake_cat.sh`
- Create: `tests/hardware_operations_spec.lua`
- Create: `scripts/validate-f429-software.sh`
- Modify: `README.md`
- Modify: `lua/nvim-stm32/health.lua`
- Test: `tests/health_spec.lua`

**Interfaces:**

- Consumes: public commands and APIs from Tasks 1 through 8.
- Produces: a repeatable software-only acceptance script and the exact setup instructions for the user's installed tool paths.

- [ ] **Step 1: Write failing fake-tool integration tests**

  Each fake executable records one argv item per line and emits canned success or selected phase failure. Tests must run through real `vim.system`, not replace the process manager. Cover CubeProgrammer probe listing, target identity output, successful program/verify/reset, write failure, verification failure, erase, reset, stlink BIN programming, OpenOCD ELF programming, and UART setup/stream cancellation.

- [ ] **Step 2: Run integration tests and verify RED**

  Run: `scripts/test.sh tests/hardware_operations_spec.lua`

  Expected: FAIL until the fake executables and integration paths exist.

- [ ] **Step 3: Implement the fake executables and make tests green**

  The fake programs act only on environment variables set by the test. They must never inspect `/dev`, call a real programmer, or write outside the test's temporary directory.

- [ ] **Step 4: Add an opt-in pseudo-terminal UART smoke test**

  Use the system Python standard library `pty` module only to create a temporary PTY pair. Start the real `stty` and `cat` commands through the plugin, write split chunks through the PTY master, verify the Neovim callback receives them, cancel, wait for the owned process to exit, then reopen to prove lock release. Skip with a clear message when PTYs are unavailable.

- [ ] **Step 5: Add the software-only acceptance script**

  `scripts/validate-f429-software.sh <corpus-root>` requires an explicit corpus path and runs, in order:

  ```sh
  scripts/test.sh
  stylua --check lua/ tests/
  scripts/validate-corpus.sh "$corpus_root"
  scripts/validate-corpus.sh "$corpus_root" --build
  ```

  It must report the known `Stage0/GPIO_IOToggle` compiler-flag incompatibility separately rather than hide it or edit the corpus. Every other project must build and return a fresh application ELF.

- [ ] **Step 6: Exercise normal Neovim through RPC**

  Open `s5/dt/Core/Src/main.c` in a normal Neovim instance and verify:

  - `:STM32Info` reports STM32F429ZITx and NUCLEO-F429ZI.
  - `:STM32Analyze` matches direct size output.
  - `:STM32Plan flash` shows the exact CubeProgrammer path, ELF, selected configuration, and no executed process.
  - Fake probe selection persists its serial.
  - A fake `:STM32Flash` builds, programs, verifies, and resets in order.
  - Declining `:STM32Erase` starts nothing.
  - Fake UART selection, streaming, and window-close cancellation work.

- [ ] **Step 7: Update README and health output**

  Document commands, exact configuration keys, backend order, CubeProgrammer standalone path handling, UART defaults, safety rules, fake/software-only testing, and the remaining hardware boundary. Remove the statement that flash and monitor are not wired up.

- [ ] **Step 8: Run final branch gates**

  ```sh
  scripts/test.sh
  stylua --check lua/ tests/
  git diff --check main...HEAD
  scripts/validate-f429-software.sh /Users/christiannucifora/Documents/University/CSSE3010/repo
  ```

  Also run the full test suite in an Ubuntu container with the same stable Neovim and Plenary revisions as CI. Record the one known corpus source failure without changing plugin success criteria.

- [ ] **Step 9: Commit**

  ```sh
  git add tests/integration tests/hardware_operations_spec.lua scripts/validate-f429-software.sh README.md lua/nvim-stm32/health.lua tests/health_spec.lua
  git commit -m "test: add F429 software-only acceptance gate"
  ```

- [ ] **Step 10: Review, push, and merge through protected main**

  Request a specification review and a code-quality review. Fix every blocking finding, rerun the final gates, push `feat/f429-flash-monitor`, open a pull request to `main`, wait for `Lua Format`, `Tests (Neovim stable)`, and `Tests (Neovim nightly)`, then merge through the normal protected-branch path.

## Hardware handoff after this plan

Do not claim hardware success from fake tools. When every software-only gate above passes, ask the user to connect the NUCLEO-F429ZI and run the approved hardware sequence beginning with passive probe enumeration and target identity. Mass erase remains last and is followed immediately by restoring the known `s5/dt` image.
