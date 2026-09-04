# AGENTS.md for nvim-stm32

Guidance for coding agents working in this repository.

## Purpose

Build, flash, erase, monitor, and debug STM32 projects from Neovim. Existing
plugins require manual project configuration. Automatic detection is the main
reason this plugin exists. `docs/design.md` contains the approved design.

## Deliberate choices

- Detection starts from the current buffer, not the working directory. One
  repository can hold many firmware folders. The walk stops at the Git root so
  a parent marker cannot select the wrong project.
- `targets.lua` is data-driven. Add support for a family with a table entry. A
  family-specific code branch means the table shape needs work.
- Backends expose a pure `cmd()`. This keeps most behavior testable without a
  connected board.
- Every build and debug child gets `toolchain_path` prepended to `$PATH`.
  Otherwise a configured compiler can disappear from child processes.
- snacks is optional. The float presenter uses `snacks.win` when available and
  `nvim_open_win` otherwise.
- Confidence follows the source. Only a `.ioc` result is `exact`. The
  `agreement` count records corroborating signals separately.

## Known traps

- `STM32_Programmer_CLI` is not normally on `$PATH`, and its installation path
  contains a version. Compare numeric version segments. Lexical sorting puts
  `2.9.0` above `2.23.0`.
- CubeMX puts the device macro in `cmake/stm32cubemx/CMakeLists.txt`. Compiler
  flags live in the toolchain file under `cmake/`, not the top-level CMake file.
- Linker scripts use both `STM32F429xx_FLASH.ld` and
  `STM32F429ZITX_FLASH.ld` spellings.
- `scripts/test.sh` starts Neovim with `--noplugin`. Tests for anything under
  `plugin/` must load its shim explicitly.
- `:checkhealth` changes the current buffer to `health://` before the plugin's
  check runs. Project detection there must use the previous buffer.

## Build and test gate

```sh
scripts/test.sh
stylua --check lua/ tests/
```

Fixtures under `tests/fixtures/` are trimmed copies of real CubeMX projects.
Use genuine inputs for detection tests. Headless tests cannot expose UI stalls,
so check user-facing flows in a normal Neovim session as well.

## Releases

The release workflow reads `VERSION` on `main` and tags `vX.Y.Z`.
