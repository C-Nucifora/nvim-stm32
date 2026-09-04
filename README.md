# nvim-stm32

Build, inspect, flash, erase, reset, and monitor STM32 projects from Neovim.
The plugin starts at the current buffer, finds the nearest firmware project,
and stops at the Git root. A repository can contain several independent
firmware folders without per-folder plugin configuration.

Project detection, build and artifact tracking, F429 memory analysis, ST-LINK
selection, programming, and UART monitoring are wired up. Debugging remains
planned.

## Requirements

- Neovim 0.11 or newer on macOS or Linux
- An `arm-none-eabi` toolchain
- CMake or Make, as required by the firmware project
- One supported programmer for hardware operations: STM32CubeProgrammer,
  stlink tools, or OpenOCD
- `stty` and `cat` for UART monitoring

There are no required Lua dependencies. If
[`folke/snacks.nvim`](https://github.com/folke/snacks.nvim) is installed, the
plugin uses `snacks.win` for output windows. Otherwise it uses Neovim's built-in
floating-window API.

## Setup

Every option is optional. These are the complete keys and their defaults:

```lua
require("nvim-stm32").setup({
  toolchain_path = nil, -- directory containing arm-none-eabi-* programs
  programmer_path = nil, -- full path to STM32_Programmer_CLI
  stlink_path = nil, -- full path to st-flash
  openocd_path = nil, -- full path to openocd
  gdb_path = nil, -- full path to arm-none-eabi-gdb

  flash_backend = nil, -- "cubeprogrammer", "stlink", or "openocd"
  flash_order = { "cubeprogrammer", "stlink", "openocd" },
  preset = nil, -- CMake configuration selected by name

  monitor = {
    baud = 115200,
    device = nil,
  },

  compiler_nvim = true,
  float = {
    border = "rounded",
    close_on_success_ms = 1500,
  },
})
```

An operation-local backend takes precedence over `flash_backend`. A configured
backend stays pinned: an unavailable tool or failed command is returned to the
user and never falls through to another backend. With no pin, `flash_order`
selects the first available backend.

STM32CubeProgrammer is often absent from a shell's `PATH`. Set its standalone
executable directly when automatic discovery does not find it:

```lua
require("nvim-stm32").setup({
  programmer_path = vim.fn.expand(
    "~/Library/Application Support/stm32cube/bundles/programmer/2.23.0/bin/STM32_Programmer_CLI"
  ),
})
```

The plugin also checks the STM32CubeProgrammer application and standalone
installation paths used on macOS and Linux. Run `:checkhealth nvim-stm32` to
see the resolved executable rather than guessing which copy will run.

## Project and target detection

Open a source file inside a firmware folder and run `:STM32Info`. The plugin
reads the CubeMX `.ioc`, startup filename, linker-script filename, CMake device
macro, and compiler flags. An `.ioc` match is exact; other signals are inferred.
The report lists each signal and how many agree.

Each project image keeps its own target and artifacts. Build results record the
selected configuration and build identifier, so flash and analysis never pick
an ELF with a glob or reuse an unrelated build.

## Commands

- `:STM32Info` reports the current project, image, MCU, board, memory, selected
  configuration, artifacts, and detection evidence.
- `:STM32SelectConfig` stores one visible CMake configuration for the current
  project.
- `:STM32Build`, `:STM32Clean`, and `:STM32Rebuild` run the selected build.
  CMake projects use their declared preset relationship or plain build tree;
  Make projects run their Makefile target.
- `:STM32Analyze` runs `arm-none-eabi-size` and `arm-none-eabi-objdump` against
  the current build's ELF, then reports flash and RAM use by linker region.
- `:STM32SelectProbe` passively lists ST-LINK probes and stores the chosen
  serial number for the current project.
- `:STM32Flash` builds the selected configuration, checks the connected target,
  programs and verifies every image in project order, then performs one reset.
- `:STM32Erase` asks for confirmation immediately before it identifies the
  target and issues a mass erase. Declining starts no process. This repeated
  confirmation is behavior of the `:STM32Erase` UI command.
- `:STM32Reset` identifies the selected target and resets it.
- `:STM32Monitor` configures and streams the selected UART device. Closing its
  output window cancels only the monitor process owned by that operation.
- `:STM32Plan {build|clean|rebuild|analyze|flash|erase|reset|monitor}` displays
  the project, configuration, images, backend, probe, artifacts, phases, working
  directory, and escaped argv without starting a process. Erase plans are
  previews and cannot be executed.

On macOS the UART default scan is `/dev/cu.usbmodem*`; on Linux it is
`/dev/ttyACM*`. Set `monitor.device` to skip discovery. If several devices are
present, `:STM32Monitor` asks which one to use and remembers it for the project.
The default baud is 115200 with raw, 8-bit, no-parity, one-stop-bit settings.

## Hardware safety

Project discovery, `:STM32Info`, `:STM32Plan`, and `:checkhealth` are passive.
They do not connect to a target, reset or halt it, erase flash, or program an
image. Probe enumeration uses CubeProgrammer's ST-LINK-only listing or
`st-info --probe`.

Before any hardware-changing command, the plugin validates the project, chosen
configuration, selected probe, target identity policy, artifact freshness, and
flash layout. A target mismatch stops before programming unless the direct API
invocation explicitly allows that one plan. Multi-image flashes retain project
order and reset once, after all images verify. Direct API callers must create a
newly confirmed plan immediately before every erase. Cancellation signals only
the child process started by the plugin and releases its probe or serial-device
lock after that child exits.

## Software-only validation

The regular development gates are:

```sh
scripts/test.sh
stylua --check lua/ tests/
```

Fake CubeProgrammer, stlink, OpenOCD, `stty`, and `cat` executables cover the
complete process path through `vim.system` without inspecting `/dev` or calling
an installed programmer. They write argv logs only inside the test's temporary
directory. The optional real-PTY UART smoke test uses Python's standard library
and the system `stty` and `cat`:

```sh
NVIM_STM32_REAL_PTY=1 scripts/test.sh tests/hardware_operations_spec.lua
```

The F429 acceptance command requires the coursework corpus path explicitly and
runs the unit suite, formatter, 13-project discovery gate, and sequential Debug
build gate:

```sh
scripts/validate-f429-software.sh /path/to/CSSE3010/repo
```

The script accepts the recorded `Stage0/GPIO_IOToggle` failure only when it is
the sole build failure and ARM GCC rejects `-fcyclomatic-complexity`. It reports
that exception separately. The other 12 projects must return fresh application
ELFs. It does not edit corpus source files.

Software fakes do not prove that a physical probe, target power, USB link,
board reset, flash write, verification, erase, or UART wiring works. A connected
NUCLEO-F429ZI run remains the release boundary after all software gates pass.
