# nvim-stm32

Build, flash, erase, monitor and debug STM32 projects from Neovim. The plugin
detects the project and the chip itself, so there is nothing to configure per
firmware folder.

**Status: under construction.** Detection, `:STM32Info`, and
`:checkhealth nvim-stm32` work. Build, flash, monitor, and debug are not wired
up yet.

## What it detects

Open a file in a firmware folder and run `:STM32Info`. The plugin walks up from
the buffer to the nearest build file and stops at the Git root. It reads the
chip from the CubeMX `.ioc`, startup filename, linker-script filename, and
CMake device macro and compiler flags, in that order. The report lists each
signal and the number that agree.

Detection starts from the buffer because a course repository or monorepo can
hold several independent firmware folders. The directory where Neovim started
does not identify one of them.

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
