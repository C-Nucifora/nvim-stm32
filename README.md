# nvim-stm32

Build, flash, erase, monitor and debug STM32 projects from Neovim. The plugin
detects the project and the chip itself, so there is nothing to configure per
firmware folder.

**Status: under construction.** Project and image detection, build planning,
CMake and Make builds, artifact discovery, `:STM32Info`, and
`:checkhealth nvim-stm32` work. Flash, monitor, and debug are not wired up yet.

## What it detects

Open a file in a firmware folder and run `:STM32Info`. The plugin walks up from
the buffer to the nearest build file and stops at the Git root. It reads the
chip from the CubeMX `.ioc`, startup filename, linker-script filename, and
CMake device macro and compiler flags, in that order. The report lists each
signal and the number that agree.

Detection starts from the buffer because a course repository or monorepo can
hold several independent firmware folders. The directory where Neovim started
does not identify one of them.

The resolved project keeps its images separate. Each image has its own target
and artifacts, and build results retain the selected configuration and build
identifier. This prevents a later flash or debug command from guessing between
ELF files.

## Commands

- `:STM32Info` shows the detected project, chip, board, and supporting signals.
- `:STM32Plan build` previews the selected project, configuration, images,
  working directory, and command arguments without running them.
- `:STM32SelectConfig` selects one of the project's visible CMake
  configurations.
- `:STM32Build` configures and builds the current firmware. CMake preset
  projects use their declared configure and build preset relationship. Plain
  CMake and Make projects run directly. Successful builds read CMake File API
  replies and assign ELF, HEX, BIN, and MAP artifacts to the matching image and
  configuration.
- `:checkhealth nvim-stm32` reports project detection and tool availability.

## Requirements

- Neovim >= 0.11
- macOS or Linux
- An `arm-none-eabi` toolchain, plus at least one of STM32CubeProgrammer,
  `st-flash` or `openocd`

## Development

```sh
scripts/test.sh              # headless plenary-busted suite
stylua --check lua/ tests/   # formatting gate, same as CI
```

To check a local firmware corpus, pass its root directory explicitly:

```sh
scripts/validate-corpus.sh /path/to/firmware-corpus
scripts/validate-corpus.sh /path/to/firmware-corpus --build
```

The first command reports detected projects, images, configurations, and
binary directories. `--build` runs each Debug build in sequence and requires a
current application ELF. Corpus validation depends on local firmware and is not
part of public CI.
