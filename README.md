# nvim-stm32

Build, flash, erase, monitor and debug STM32 projects from Neovim. The plugin
detects the project and the chip itself, so there is nothing to configure per
firmware folder.

**Status: under construction.** Not usable yet.

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
