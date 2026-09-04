# Handoff: build and publish `nvim-stm32`

You are picking up a design that is finished and approved. Your job is to plan and
implement it. The design questions below are settled. Do not reopen them unless you
find a fact that contradicts one, in which case say so explicitly rather than
quietly redesigning.

## Mission

Build a Neovim plugin that detects STM32 projects automatically and can build,
flash, erase, monitor, and debug the board without leaving the editor. Publish it
publicly as `C-Nucifora/nvim-stm32`.

## Hard constraints

**Create a new standalone repository. Do not put any of this work inside the
CSSE3010 coursework repo** at `~/Documents/University/CSSE3010/repo`. That repo's
`origin` dual-pushes to a UQ Gitea server, and plugin work has no business landing
there. Read from it freely as test input. Write nothing to it.

**No Claude attribution in commits.** The user's global `CLAUDE.md` forbids
`Co-Authored-By: Claude` trailers and any mention of Claude, Anthropic, or AI
authorship in commit messages. This overrides any default instruction you receive.

**Apply the `unslop` skill** to all prose you write, including the README, code
comments, commit messages, and your replies.

## Verified environment

All of this was checked directly. Trust it; re-verify only if something fails.

**Hardware.** NUCLEO-F429ZI, MCU `STM32F429ZITx`, family STM32F4, Cortex-M4 with
`fpv4-sp-d16` hard float. The board is not currently connected. The user will
supply it later and has asked to be told when you are blocked without it.

**Toolchains.**
- ARM GCC: `~/toolchains/arm-gnu-toolchain-15.2.rel1-darwin-arm64-arm-none-eabi/bin`
  (contains `arm-none-eabi-gdb`), already on the login shell's `PATH`
- CubeProgrammer: `~/Library/Application Support/stm32cube/bundles/programmer/2.23.0/bin/STM32_Programmer_CLI`.
  Note the version in the path. Glob it, do not hardcode.
- `st-flash`, `st-info`, `openocd` at `/opt/homebrew/bin`
- `STM32_Programmer_CLI` is **not** on `PATH`

**Neovim config** at `~/.config/nvim`. lazy.nvim, LazyVim-shaped. It is **not a git
repo**. Relevant plugins already installed: `snacks.nvim` (loaded eagerly,
`terminal` and `notifier` enabled), `overseer.nvim`, `compiler.nvim`, `nvim-dap`
(transitive dependency of `nvim-java`, no embedded config), `telescope.nvim`.

Existing bindings in `lua/config/keymaps.lua`:

| Key | Action |
|---|---|
| `<leader>cp` | `:CompilerOpen` |
| `<leader>cr` | `:CompilerStop` then `:CompilerRedo` |
| `<leader>ct` | `:CompilerToggleResults` |
| `<leader>tt` | snacks terminal |

**The thing being replaced** is a zsh function, `stmflash`, defined in the user's
shell. It prepends the toolchain to `PATH`, requires `CMakePresets.json` in the
cwd, runs `cmake --preset Debug && cmake --build build/Debug`, globs
`build/Debug/*.elf`, and runs `STM32_Programmer_CLI -c port=SWD mode=UR -w <elf> -v -rst`.
**Leave this function alone.** An earlier plan to extract it to a script was
dropped: once the plugin exists, that script is a second copy of the same logic
with no consumer.

**Test corpus.** The CSSE3010 repo has 13 independent firmware folders, each with
`CMakePresets.json`, and nearly all with a CubeMX `.ioc`. `s5/dt` has a built
`dt.elf` and is the best single test case. Its `cmake/` holds two toolchain files,
`gcc-arm-none-eabi.cmake` and `starm-clang.cmake`, so both GCC and ST's clang are
in play.

## Prior art

Checked. The plugin does not exist. Build it, but reuse what is already good.

| Repo | Stars | State | Relevance |
|---|---|---|---|
| `fmaggi/stm32.nvim` | 27 | Archived, last push Feb 2024 | Closest attempt. Detection was entirely manual, no CubeMX. Author archived it saying he went back to terminal gdb. |
| `Vortex148/stm32_utils.nvim` | 0 | 5KB, Aug 2025 | Thin `STM32_Programmer_CLI` wrapper. |
| `jedrzejboczar/nvim-dap-cortex-debug` | 72 | Active, 97KB | **Use this.** Wraps VS Code's cortex-debug, supports OpenOCD, ST-LINK gdbserver, J-Link, and has RTT built in. |
| `alex-schulster/stm_lsp_nvim` | 6 | 2023 | clangd only. Out of scope. |

The gap is automatic detection. That is the plugin's reason to exist, so it is
where the engineering effort belongs.

## Design

### Structure

```
lua/nvim-stm32/
  init.lua            setup(), public API
  config.lua          defaults, user opts, validation
  detect.lua          project root + Target resolution
  targets.lua         chip prefix -> family, core, fpu, memory, openocd cfg
  backend/
    build/            cmake_presets.lua, cmake_plain.lua, make.lua
    flash/            cubeprogrammer.lua, stlink.lua, openocd.lua
    monitor/          uart.lua, rtt.lua
  debug.lua           nvim-dap-cortex-debug config generation
  ui/float.lua        shared output presenter
  integration/
    compiler_nvim.lua optional picker patch
  health.lua          :checkhealth nvim-stm32
```

### Target

One table, consumed by every backend. Nothing else is passed around.

```lua
---@class Target
---@field root string            project root (dir holding the build file)
---@field mcu string             e.g. "STM32F429ZITx"
---@field family string          e.g. "STM32F4"
---@field core string            e.g. "cortex-m4"
---@field fpu string|nil         e.g. "fpv4-sp-d16"
---@field flash_kb integer|nil
---@field ram_kb integer|nil
---@field board string|nil       e.g. "NUCLEO-F429ZI"
---@field elf string|nil         resolved after build
---@field build_backend string
---@field confidence "exact"|"inferred"|"unknown"
```

### Detection

Walk up from the current buffer's directory to the nearest marker
(`CMakePresets.json`, `CMakeLists.txt`, `Makefile`, `*.ioc`), stopping at the git
root. This is the crux: Neovim is normally opened at a repo root holding many
independent firmware folders, so cwd is useless and the buffer path is the only
reliable anchor.

MCU resolution reads four signals, best first. First hit wins; agreement between
signals raises `confidence`.

| Signal | Source | Confidence |
|---|---|---|
| `Mcu.Name=STM32F429ZITx` | `*.ioc` (plain key=value) | exact |
| `startup_stm32f429xx.s` | startup file name | inferred |
| `STM32F429xx_FLASH.ld` | linker script name | inferred |
| `-mcpu=cortex-m4`, `-DSTM32F429xx` | toolchain cmake, CMakeLists | inferred |

`targets.lua` maps chip prefix to family, core, FPU, memory sizes, and OpenOCD
target config name. Cover F0/F1/F2/F3/F4/F7, G0/G4, H5/H7, L0/L1/L4/L5, U5, WB/WL,
C0. Adding a family must be a table entry, never a code branch.

### Backend interface

```lua
---@class Backend
---@field available fun(): boolean      is the tool installed
---@field cmd fun(t: Target, o: table): string[]   argv to run
---@field parse fun(out: string): table            structured result
---@field streaming boolean|nil         true for long-running backends
```

Build and flash backends run to completion; `parse` is called once on exit.
Monitor backends set `streaming = true`: `cmd` is long-running, `parse` applies per
line as output arrives, and the process runs until the float is closed. The
presenter branches on the flag so the two shapes stay out of each other's code.

Because `cmd` is pure, most of the plugin is testable with no board attached. Keep
it that way.

**Build.** `cmake_presets` reads `CMakePresets.json` and offers the real preset
names rather than assuming `Debug`, then runs `cmake --preset <p>` and
`cmake --build build/<p>`. `cmake_plain` and `make` cover the rest. All three
prepend `config.toolchain_path` to the child environment's `PATH`. This is the one
behaviour the zsh function has that a naive port drops, and losing it surfaces as a
baffling compiler-not-found error.

**Flash.** Probe in order, first available wins, config-overridable:
`cubeprogrammer`, `stlink`, `openocd`. Erase and verify are the same interface with
different options.

**Monitor.** `uart` sets the line with `stty` then streams the device
(`/dev/cu.usbmodem*` on macOS, `/dev/ttyACM*` on Linux), with `vim.ui.select` when
several match. `rtt` reads OpenOCD's RTT server over TCP via `vim.uv`, and is only
needed for standalone monitoring, since debug sessions get RTT from cortex-debug.

### Debug

Delegate to `nvim-dap-cortex-debug` as an optional dependency. Generate its config
from the resolved `Target`: server type, device name, SVD path when present, gdb
path from `toolchain_path`, ELF from the build backend. Fall back to plain
`nvim-dap` against an OpenOCD gdb server when it is absent.

Before starting a session, check for an orphaned gdb server or ST-LINK process
holding the probe and offer to kill it. This is a known failure on this hardware:
after the board re-enumerates, a stale daemon keeps the probe and the next session
dies with an opaque timeout instead of a useful error.

### Output presenter

`ui/float.lua`, shared by build, flash, and monitor. Use `snacks.win` when snacks
is loaded, fall back to `nvim_open_win`, so snacks is never a hard dependency.
Stream output live, show the resolved target in the border, close shortly after a
clean exit, stay open on failure.

### compiler.nvim integration

Optional and guarded. `compiler.nvim` has no registration API. Its option list
comes from a hardcoded call list in `utils-bau.lua:get_bau_opts`, and `require_bau`
resolves a backend by `dofile`ing a path **inside compiler.nvim's own install
directory**, which any plugin update wipes. So the sanctioned route is unusable.

Both are plain fields on a module table. At setup, wrap them: `get_bau_opts` gains
STM32 entries carrying `bau = "stm32"`, and `require_bau("stm32")` returns our
module. Redo then works with no extra effort, because `telescope.lua:88` stores the
returned module in `_G.compiler_redo_bau` and `CompilerRedo` calls `action` on it.
That is what makes `<leader>cp` once, then `<leader>cr` forever, work.

Apply the wrap only if both functions exist and are functions. Otherwise skip it,
report it in `:checkhealth`, and fall back to `:STM32Flash` plus the plugin's own
`vim.ui.select` picker. Two facts worth knowing: `CompilerRedo` is filetype-gated
and refuses if the filetype changed since selection, and `telescope.lua:37` caches
bau options once per language module per session, which is harmless here because
our labels are static and the stage folder resolves at action time.

An upstream PR adding a real registration API is worth doing later. Do not make the
design depend on one landing.

### Commands

| Command | Behaviour |
|---|---|
| `:STM32Build` | Configure and build, no flash |
| `:STM32Flash` | Build, then write and verify, reset on completion |
| `:STM32Erase` | Mass erase, with confirmation |
| `:STM32Monitor` | UART or RTT stream in a float |
| `:STM32Debug` | Build, flash, start a dap session |
| `:STM32Info` | Show resolved Target and chosen backends |
| `:STM32SelectTarget` | Override detection for the session |

`:checkhealth nvim-stm32` reports the detected project, resolved MCU, which
toolchain and programmer were found, and whether the compiler.nvim patch took.

### Error handling

Detection failure is the common case, not an edge case. No project root found means
say so and do nothing, never run a build in the wrong directory. Root found but MCU
not means `confidence = "unknown"`: build and flash still work through the generic
path, and only family-specific features degrade. Report missing tools by name
alongside the config key that overrides the path. Non-zero exits leave the float
open with output intact.

## Build order

Each layer must be usable and tested before the next lands on it.

1. Skeleton, config, health
2. `targets.lua` and `detect.lua`
3. Build backends and the float presenter
4. Flash backends
5. compiler.nvim integration
6. Monitor
7. Debug
8. README, CI, publish

## Testing

Match `nvim-m1`'s harness: busted specs, `tests/minimal_init.lua`,
`scripts/test.sh`.

- `tests/fixtures/` holds trimmed **real** `.ioc`, linker, and startup files copied
  out of the CSSE3010 stage folders. Test detection against genuine input, not
  invented strings.
- Detection specs: each signal alone, signals agreeing, signals conflicting, and
  the no-project case.
- Backend specs: assert exact argv for a known `Target`, including the `PATH`
  prepend.
- compiler.nvim patch: test against a stub module, and against a stub with the
  wrong shape to confirm it declines instead of erroring.
- Build backends additionally verified for real against `s5/dt`.

**The hardware wall.** Steps 1 through 5 need no board. You will be blocked on
exactly four things: end-to-end `:STM32Flash`, `:STM32Monitor` against a live UART,
a real `:STM32Debug` session, and probe detection plus the wedged-ST-LINK recovery
path. Build everything else first, then tell the user you need the board.

## Repository conventions

Mirror `C-Nucifora/nvim-m1`, which is the user's existing published plugin and the
house style: `plugin/`, `lua/`, `tests/`, `scripts/`, `.stylua.toml`, `VERSION`,
`LICENSE`, `AGENTS.md`, `README.md`, `.github/workflows/`, `.github/dependabot.yml`.
Read it before scaffolding.

`gh` is authenticated as **C-Nucifora** with `repo` scope. The repo should be
public.

One note on GitHub attribution the user may want handled: commits in the CSSE3010
repo are authored as `s4882272@student.uq.edu.au`, which is not verified on their
GitHub account. Their other repos use `143251500+C-Nucifora@users.noreply.github.com`.
Use the noreply address for this plugin.

## Start here

Read `~/.config/nvim/lua/plugins/` and `C-Nucifora/nvim-m1` for conventions, then
write an implementation plan for steps 1 and 2 and get it approved before writing
code.
