# nvim-stm32 foundation (build-order steps 1 and 2) implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up the `nvim-stm32` repository with its config, tool resolution and
`:checkhealth`, then make it resolve a `Target` from a real STM32 project on disk.

**Architecture:** Four leaf modules with no cross-talk. `config.lua` turns user opts
into a validated table. `tools.lua` finds executables (`$PATH`, config override,
versioned glob) and builds the child `PATH`. `targets.lua` is pure part-number data.
`detect.lua` walks up from the buffer to a build marker, then resolves the MCU from
four file signals and hands back the one `Target` table every later backend consumes.

**Tech Stack:** Lua, Neovim >= 0.11, plenary-busted, stylua, GitHub Actions.

**Spec:** `docs/design.md` (the approved handoff, copied into the repo verbatim)

## Global constraints

- **Repository:** `/Users/christiannucifora/Documents/dev/nvim-stm32`, published as
  `C-Nucifora/nvim-stm32`, public, default branch `main`.
- **Never write to** `~/Documents/University/CSSE3010/repo`. Read it freely as test
  input. Its `origin` dual-pushes to a UQ Gitea server.
- **Commit author:** `C-Nucifora <143251500+C-Nucifora@users.noreply.github.com>`,
  set as repo-local git config in Task 1.
- **No Claude/Anthropic/AI attribution** in any commit message, code comment, or
  doc. No `Co-Authored-By` trailer.
- **Apply the `unslop` skill** to every piece of prose: README, comments, commit
  messages, `:checkhealth` strings, error text.
- **Neovim >= 0.11.** This is a floor choice for this repo: `vim.validate`'s
  four-argument form and `vim.fs.normalize`'s `~` expansion both need it, and
  hand-writing 0.10 fallbacks for a brand-new plugin buys nothing.
- **macOS and Linux only.** Path separators, device globs and the CubeProgrammer
  locations are POSIX. Do not add Windows branches.
- **stylua:** `column_width = 88`, 2-space indent, double quotes, always call
  parens. CI runs `stylua --check lua/ tests/`, so run it before every commit.
- **Commit at the end of every task**, never mid-task.

## Additions to the design (deliberate, flagged)

The approved design does not name these. They are gap-fills, not redesigns:

1. **`lua/nvim-stm32/tools.lua`.** The design lists `config.lua` as "defaults, user
   opts, validation". Globbing the filesystem for `STM32_Programmer_CLI` is not
   that, and both `health.lua` and (later) `backend/flash/cubeprogrammer.lua` need
   the same answer. One module owns executable resolution.
2. **Four extra `Target` fields:** `marker` (absolute path to the file that decided
   the root), `openocd_cfg` (the design already says `targets.lua` maps it, but the
   `Target` class listing omits it), `signals` and `agreement` (what `:STM32Info`
   and `:checkhealth` print to explain a `confidence` verdict). All additive.
3. **`confidence` follows the design's table literally:** `.ioc` gives `exact`,
   every other signal gives `inferred`, nothing gives `unknown`. The design also
   says "agreement between signals raises confidence", but there is no level
   between `inferred` and `exact`, and promoting a linker-script guess to `exact`
   would be a real design change. Instead `agreement` reports how many signals
   named the same device, and the UI shows it.

---

### Task 1: Repository skeleton, test harness, CI

**Files:**
- Create: `/Users/christiannucifora/Documents/dev/nvim-stm32/.stylua.toml`
- Create: `.gitignore`, `VERSION`, `LICENSE`, `README.md`
- Create: `tests/minimal_init.lua`, `tests/smoke_spec.lua`
- Create: `scripts/test.sh`
- Create: `.github/workflows/ci.yml`, `.github/workflows/release.yml`, `.github/dependabot.yml`

**Interfaces:**
- Consumes: nothing.
- Produces: a green `scripts/test.sh`, and the `lua/nvim-stm32/` module namespace on
  the runtimepath for every later task.

- [ ] **Step 1: Create the repo and set the commit identity**

```bash
mkdir -p ~/Documents/dev/nvim-stm32
cd ~/Documents/dev/nvim-stm32
git init -b main
git config user.name "C-Nucifora"
git config user.email "143251500+C-Nucifora@users.noreply.github.com"
mkdir -p lua/nvim-stm32 tests/fixtures scripts .github/workflows docs/plans
```

The repo-local email matters: the CSSE3010 repo commits as
`s4882272@student.uq.edu.au`, which is not verified on the GitHub account, so an
inherited global identity would leave unattributed commits.

- [ ] **Step 2: Write the static files**

`.stylua.toml` (identical to nvim-m1, so both repos format the same way):

```toml
column_width = 88
line_endings = "Unix"
indent_type = "Spaces"
indent_width = 2
quote_style = "AutoPreferDouble"
call_parentheses = "Always"
```

`.gitignore`:

```gitignore
.luarc.json
.luarc.jsonc
*.swp
*~
.DS_Store
```

`VERSION`:

```
0.1.0
```

`LICENSE`: GPL-3.0, matching nvim-m1. Fetch the canonical text rather than
retyping it:

```bash
cd ~/Documents/dev/nvim-stm32
cp ~/Documents/dev/m1-lang/nvim-m1/LICENSE LICENSE
```

`README.md` (the full README is build-order step 8; this is the placeholder that
still has to be honest about the state):

````markdown
# nvim-stm32

Build, flash, erase, monitor and debug STM32 projects from Neovim. The plugin
detects the project and the chip itself, so there is nothing to configure per
firmware folder.

**Status: under construction.** Detection and the health check work. Build,
flash, monitor and debug are not wired up yet.

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
````

- [ ] **Step 3: Write the test harness**

`tests/minimal_init.lua`:

```lua
-- Minimal init for headless plenary-busted runs.
--
-- Puts this plugin on the runtimepath and locates plenary via $PLENARY_PATH
-- (set by scripts/test.sh and CI) or the standard lazy.nvim data dir.
local here =
  vim.fn.fnamemodify(vim.fn.resolve(debug.getinfo(1, "S").source:sub(2)), ":p:h")
local root = vim.fn.fnamemodify(here, ":h")

vim.opt.runtimepath:prepend(root)

local function add(path)
  if path ~= "" and vim.fn.isdirectory(path) == 1 then
    vim.opt.runtimepath:append(path)
    return true
  end
  return false
end

local plenary = vim.env.PLENARY_PATH or ""
if not add(plenary) then
  add(vim.fn.stdpath("data") .. "/lazy/plenary.nvim")
end

vim.cmd("runtime plugin/plenary.vim")
require("plenary.busted")
```

`scripts/test.sh`:

```bash
#!/usr/bin/env bash
# Run the nvim-stm32 test suite headless with plenary-busted.
#
#   scripts/test.sh                        # the whole suite
#   scripts/test.sh tests/detect_spec.lua  # one file
#
# plenary is located via $PLENARY_PATH or the lazy.nvim data dir.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PLENARY_PATH="${PLENARY_PATH:-$HOME/.local/share/nvim/lazy/plenary.nvim}"

if [ "$#" -gt 0 ]; then
  nvim --headless --noplugin -u "$here/tests/minimal_init.lua" \
    -c "PlenaryBustedFile $1"
else
  nvim --headless --noplugin -u "$here/tests/minimal_init.lua" \
    -c "PlenaryBustedDirectory $here/tests { minimal_init = '$here/tests/minimal_init.lua', sequential = true }"
fi
```

```bash
chmod +x ~/Documents/dev/nvim-stm32/scripts/test.sh
```

`tests/smoke_spec.lua` proves the harness itself works before anything depends on
it:

```lua
describe("test harness", function()
  it("puts the plugin on the runtimepath", function()
    local found = vim.api.nvim_get_runtime_file("lua/nvim-stm32/", true)
    assert.is_true(#found > 0)
  end)

  it("runs on a Neovim the plugin supports", function()
    assert.equals(1, vim.fn.has("nvim-0.11"))
  end)
end)
```

- [ ] **Step 4: Run the suite and watch it fail**

```bash
cd ~/Documents/dev/nvim-stm32 && scripts/test.sh
```

Expected: the runtimepath assertion fails, because `lua/nvim-stm32/` is empty and
`nvim_get_runtime_file` returns nothing for it.

- [ ] **Step 5: Add the module namespace so it passes**

Create `lua/nvim-stm32/init.lua`:

```lua
--- nvim-stm32: build, flash, monitor and debug STM32 projects from Neovim.
---
--- The public API arrives over the next tasks; this file exists so the module
--- namespace resolves.
local M = {}

return M
```

- [ ] **Step 6: Run the suite and watch it pass**

```bash
cd ~/Documents/dev/nvim-stm32 && scripts/test.sh
```

Expected: 2 successes, 0 failures.

- [ ] **Step 7: Write the CI workflows**

`.github/workflows/ci.yml`:

```yaml
name: CI

on:
  push:
    branches: [main, "feat/**", "fix/**"]
  pull_request:
    branches: [main]
  workflow_dispatch: {}

permissions:
  contents: read

# Cancel superseded runs of the same branch or PR instead of queueing a
# duplicate job matrix for every push.
concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true

jobs:
  stylua:
    name: Lua Format
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v6
      - uses: JohnnyMorganz/stylua-action@v5
        with:
          token: ${{ secrets.GITHUB_TOKEN }}
          version: latest
          args: --check lua/ tests/

  test:
    name: Tests (Neovim ${{ matrix.neovim }})
    runs-on: ubuntu-latest
    strategy:
      fail-fast: false
      matrix:
        neovim: [stable, nightly]
    steps:
      - uses: actions/checkout@v6

      - uses: rhysd/action-setup-vim@v1
        with:
          neovim: true
          version: ${{ matrix.neovim }}

      - name: Check out plenary.nvim
        uses: actions/checkout@v6
        with:
          repository: nvim-lua/plenary.nvim
          path: deps/plenary.nvim

      - name: Run tests
        env:
          PLENARY_PATH: ${{ github.workspace }}/deps/plenary.nvim
        run: scripts/test.sh
```

`.github/workflows/release.yml` is nvim-m1's, minus its bundled-toolchain table
(this plugin bundles no binaries):

````yaml
name: Release

# Cuts a GitHub Release (and tag) whenever the VERSION file names a version that
# has no release yet. lazy.nvim users can then pin `version = "v0.1.0"` or track
# main. Can also be run manually.

on:
  push:
    branches: [main]
  workflow_dispatch:

permissions:
  contents: write

# Serialize release runs and never cancel one mid-publish; a queued run is
# idempotent for an already-released version.
concurrency:
  group: ${{ github.workflow }}-release
  cancel-in-progress: false

jobs:
  release:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v6
        with:
          fetch-depth: 0
      - id: v
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: |
          VERSION=$(tr -d ' \t\n\r' < VERSION)
          echo "version=$VERSION" >> "$GITHUB_OUTPUT"
          if gh release view "v$VERSION" --repo "$GITHUB_REPOSITORY" >/dev/null 2>&1; then
            echo "should_release=false" >> "$GITHUB_OUTPUT"
            echo "Release v$VERSION already exists, nothing to do."
          else
            echo "should_release=true" >> "$GITHUB_OUTPUT"
            echo "Will release v$VERSION."
          fi
      - name: Publish release
        if: steps.v.outputs.should_release == 'true'
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
          TAG: v${{ steps.v.outputs.version }}
        run: |
          # Body: auto-generated "What's Changed" followed by an install snippet.
          # PR titles may contain backticks, so the generated half never passes
          # through an unquoted heredoc.
          gh api "repos/$GITHUB_REPOSITORY/releases/generate-notes" \
            -f tag_name="$TAG" -f target_commitish="$GITHUB_SHA" \
            -q .body > body.md || echo "_Generated notes unavailable._" > body.md
          cat >> body.md <<'NOTES'

          ## Install

          ```lua
          -- lazy.nvim
          { "{{REPO}}", version = "{{TAG}}" }
          ```
          NOTES
          sed -i "s|{{REPO}}|$GITHUB_REPOSITORY|g; s|{{TAG}}|$TAG|g" body.md
          gh release create "$TAG" \
            --repo "$GITHUB_REPOSITORY" \
            --target "$GITHUB_SHA" \
            --title "nvim-stm32 $TAG" \
            --notes-file body.md
````

`.github/dependabot.yml`:

```yaml
version: 2
updates:
  - package-ecosystem: "github-actions"
    directory: "/"
    schedule:
      interval: "daily"
```

- [ ] **Step 8: Check formatting**

```bash
cd ~/Documents/dev/nvim-stm32 && stylua --check lua/ tests/
```

Expected: no output, exit 0. If it reports a diff, run `stylua lua/ tests/`.

- [ ] **Step 9: Commit, create the public repo, push**

```bash
cd ~/Documents/dev/nvim-stm32
git add -A
git commit -m "chore: repository skeleton, plenary-busted harness, CI"
gh repo create C-Nucifora/nvim-stm32 --public --source=. --remote=origin \
  --description "Build, flash, monitor and debug STM32 projects from Neovim" --push
```

- [ ] **Step 10: Confirm CI is green**

```bash
cd ~/Documents/dev/nvim-stm32 && gh run watch --exit-status
```

Expected: the `Lua Format` job and both `Tests` jobs pass. Do not start Task 2
until they do; a broken workflow found later is a broken workflow debugged
against a much larger diff.

---

### Task 2: `config.lua`

**Files:**
- Create: `lua/nvim-stm32/config.lua`
- Test: `tests/config_spec.lua`

**Interfaces:**
- Consumes: nothing.
- Produces: `config.defaults` (table), `config.resolve(opts?) -> Stm32Config`,
  `config.flash_backends` (string list). Every later module takes an
  `Stm32Config` as its `cfg` argument.

The option keys here are exactly the ones `docs/design.md` names:
`toolchain_path` (the `PATH` prepend the zsh function does), the four explicit
tool paths, the flash probe order and its override, the default CMake preset,
monitor settings, the compiler.nvim opt-out, and the float's behaviour. Nothing
speculative beyond them.

- [ ] **Step 1: Write the failing test**

`tests/config_spec.lua`:

```lua
local config = require("nvim-stm32.config")

describe("nvim-stm32.config", function()
  it("returns the documented defaults", function()
    local cfg = config.resolve()
    assert.is_nil(cfg.toolchain_path)
    assert.is_nil(cfg.flash_backend)
    assert.same({ "cubeprogrammer", "stlink", "openocd" }, cfg.flash_order)
    assert.equals(115200, cfg.monitor.baud)
    assert.is_true(cfg.compiler_nvim)
  end)

  it("merges user opts over the defaults", function()
    local cfg = config.resolve({ preset = "Release", compiler_nvim = false })
    assert.equals("Release", cfg.preset)
    assert.is_false(cfg.compiler_nvim)
    -- untouched keys keep their defaults
    assert.equals(115200, cfg.monitor.baud)
  end)

  it("merges nested tables key by key", function()
    local cfg = config.resolve({ monitor = { baud = 9600 } })
    assert.equals(9600, cfg.monitor.baud)
    assert.is_nil(cfg.monitor.device)
  end)

  it("does not mutate the defaults", function()
    config.resolve({ flash_order = { "openocd" } })
    assert.same({ "cubeprogrammer", "stlink", "openocd" }, config.defaults.flash_order)
  end)

  it("expands ~ in toolchain_path", function()
    local cfg = config.resolve({ toolchain_path = "~/toolchains/bin" })
    assert.equals(vim.env.HOME .. "/toolchains/bin", cfg.toolchain_path)
  end)

  it("rejects a wrongly-typed option", function()
    assert.has_error(function()
      config.resolve({ compiler_nvim = "yes" })
    end)
  end)

  it("rejects an unknown flash backend", function()
    assert.has_error(function()
      config.resolve({ flash_order = { "jlink" } })
    end)
  end)
end)
```

- [ ] **Step 2: Run it and watch it fail**

```bash
cd ~/Documents/dev/nvim-stm32 && scripts/test.sh tests/config_spec.lua
```

Expected: FAIL, "module 'nvim-stm32.config' not found".

- [ ] **Step 3: Write `lua/nvim-stm32/config.lua`**

```lua
--- nvim-stm32 configuration: defaults, merge, and normalisation.
---
--- The option surface is flat and matches the keys documented in the README.
--- Path options accept `~`; resolve() expands them once so no consumer has to.
local M = {}

--- Flash backends, in the order they are probed when `flash_backend` is unset.
M.flash_backends = { "cubeprogrammer", "stlink", "openocd" }

---@class Stm32Config
---@field toolchain_path? string   Directory prepended to $PATH for build, flash and
---                                 debug children (the arm-none-eabi bin dir). nil
---                                 relies on the inherited $PATH.
---@field programmer_path? string  STM32_Programmer_CLI. nil searches $PATH, then the
---                                 known CubeProgrammer install locations.
---@field openocd_path? string     openocd. nil searches $PATH.
---@field stlink_path? string      st-flash. nil searches $PATH.
---@field gdb_path? string         arm-none-eabi-gdb. nil searches toolchain_path, then $PATH.
---@field flash_backend? string    Force one backend. nil probes `flash_order`.
---@field flash_order string[]     Probe order, first available wins.
---@field preset? string           CMake preset to build. nil asks, listing the real
---                                 preset names out of CMakePresets.json.
---@field monitor Stm32MonitorConfig
---@field compiler_nvim boolean    Patch compiler.nvim's option list when it is loaded.
---@field float Stm32FloatConfig

---@class Stm32MonitorConfig
---@field baud integer             Line speed for the UART monitor.
---@field device? string           Serial device. nil globs and asks when several match.

---@class Stm32FloatConfig
---@field border string            Border style for the output float.
---@field close_on_success_ms integer  Delay before closing after a clean exit.

---@type Stm32Config
M.defaults = {
  toolchain_path = nil,
  programmer_path = nil,
  openocd_path = nil,
  stlink_path = nil,
  gdb_path = nil,

  flash_backend = nil,
  flash_order = { "cubeprogrammer", "stlink", "openocd" },

  preset = nil,

  monitor = {
    baud = 115200,
    device = nil,
  },

  compiler_nvim = true,

  float = {
    border = "rounded",
    close_on_success_ms = 1500,
  },
}

--- Path options that accept `~` and are expanded to absolute paths by resolve().
local PATH_KEYS = {
  "toolchain_path",
  "programmer_path",
  "openocd_path",
  "stlink_path",
  "gdb_path",
}

--- Whether every entry of `order` names a real flash backend.
---@param order any
---@return boolean
local function valid_order(order)
  if type(order) ~= "table" then
    return false
  end
  for _, name in ipairs(order) do
    if not vim.tbl_contains(M.flash_backends, name) then
      return false
    end
  end
  return true
end

--- Merge user opts over the defaults, validate, and expand path options.
---@param opts? table
---@return Stm32Config
function M.resolve(opts)
  local cfg = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})

  for _, key in ipairs(PATH_KEYS) do
    vim.validate(key, cfg[key], "string", true)
  end
  vim.validate("flash_backend", cfg.flash_backend, function(v)
    return v == nil or vim.tbl_contains(M.flash_backends, v)
  end, "nil or one of: " .. table.concat(M.flash_backends, ", "))
  vim.validate(
    "flash_order",
    cfg.flash_order,
    valid_order,
    "a list of: " .. table.concat(M.flash_backends, ", ")
  )
  vim.validate("preset", cfg.preset, "string", true)
  vim.validate("monitor", cfg.monitor, "table")
  vim.validate("monitor.baud", cfg.monitor.baud, "number")
  vim.validate("monitor.device", cfg.monitor.device, "string", true)
  vim.validate("compiler_nvim", cfg.compiler_nvim, "boolean")
  vim.validate("float", cfg.float, "table")
  vim.validate("float.border", cfg.float.border, "string")
  vim.validate("float.close_on_success_ms", cfg.float.close_on_success_ms, "number")

  for _, key in ipairs(PATH_KEYS) do
    if cfg[key] then
      cfg[key] = vim.fs.normalize(cfg[key])
    end
  end

  return cfg
end

return M
```

- [ ] **Step 4: Run it and watch it pass**

```bash
cd ~/Documents/dev/nvim-stm32 && scripts/test.sh tests/config_spec.lua
```

Expected: 7 successes, 0 failures.

- [ ] **Step 5: Format and commit**

```bash
cd ~/Documents/dev/nvim-stm32
stylua lua/ tests/ && stylua --check lua/ tests/
git add lua/nvim-stm32/config.lua tests/config_spec.lua
git commit -m "feat(config): defaults, deep merge, validation and path expansion"
```

---

### Task 3: `tools.lua`

**Files:**
- Create: `lua/nvim-stm32/tools.lua`
- Test: `tests/tools_spec.lua`

**Interfaces:**
- Consumes: `Stm32Config` from Task 2.
- Produces:
  - `tools.by_version_desc(paths: string[]) -> string[]`
  - `tools.resolve(name: string, override: string|nil, globs: string[]|nil) -> string|nil`
  - `tools.programmer(cfg) -> string|nil`, `tools.gdb(cfg) -> string|nil`,
    `tools.openocd(cfg) -> string|nil`, `tools.stlink(cfg) -> string|nil`
  - `tools.child_path(cfg) -> string`, `tools.env(cfg) -> table<string, string>`
  - `tools.globs` (table<string, string[]>)

Two things earn their own tests here. `STM32_Programmer_CLI` is never on `$PATH`
and its install directory is version-stamped, so a plain string sort of the glob
matches puts `2.9.0` above `2.23.0` and silently picks an old programmer. And
`child_path` is the single behaviour the zsh function has that a naive port drops:
without it, builds fail with a compiler-not-found error that points nowhere.

- [ ] **Step 1: Write the failing test**

`tests/tools_spec.lua`:

```lua
local config = require("nvim-stm32.config")
local tools = require("nvim-stm32.tools")

describe("nvim-stm32.tools.by_version_desc", function()
  it("orders version directories numerically, not lexically", function()
    local sorted = tools.by_version_desc({
      "/opt/programmer/2.9.0/bin/STM32_Programmer_CLI",
      "/opt/programmer/2.23.0/bin/STM32_Programmer_CLI",
      "/opt/programmer/2.10.1/bin/STM32_Programmer_CLI",
    })
    assert.equals("/opt/programmer/2.23.0/bin/STM32_Programmer_CLI", sorted[1])
    assert.equals("/opt/programmer/2.10.1/bin/STM32_Programmer_CLI", sorted[2])
    assert.equals("/opt/programmer/2.9.0/bin/STM32_Programmer_CLI", sorted[3])
  end)

  it("leaves the input list untouched", function()
    local input = { "/a/1.0/x", "/a/2.0/x" }
    tools.by_version_desc(input)
    assert.equals("/a/1.0/x", input[1])
  end)

  it("handles an empty list", function()
    assert.same({}, tools.by_version_desc({}))
  end)
end)

describe("nvim-stm32.tools.resolve", function()
  local dir, exe

  before_each(function()
    dir = vim.fn.tempname()
    vim.fn.mkdir(dir .. "/2.23.0/bin", "p")
    vim.fn.mkdir(dir .. "/2.9.0/bin", "p")
    exe = dir .. "/2.23.0/bin/FakeProgrammer"
    for _, v in ipairs({ "2.23.0", "2.9.0" }) do
      local p = dir .. "/" .. v .. "/bin/FakeProgrammer"
      vim.fn.writefile({ "#!/bin/sh" }, p)
      vim.uv.fs_chmod(p, 493) -- 0755
    end
  end)

  after_each(function()
    vim.fn.delete(dir, "rf")
  end)

  it("returns an explicit override when it is executable", function()
    assert.equals(exe, tools.resolve("FakeProgrammer", exe, {}))
  end)

  it("returns nil for an override that is not executable", function()
    assert.is_nil(tools.resolve("FakeProgrammer", dir .. "/nope", {}))
  end)

  it("expands ~ in an override", function()
    -- $HOME itself is always a directory, never executable, so this asserts the
    -- expansion happened rather than the lookup succeeding.
    assert.is_nil(tools.resolve("FakeProgrammer", "~", {}))
  end)

  it("falls back to the globs and picks the highest version", function()
    assert.equals(exe, tools.resolve("FakeProgrammer", nil, { dir .. "/*/bin/FakeProgrammer" }))
  end)

  it("returns nil when nothing matches", function()
    assert.is_nil(tools.resolve("DefinitelyNotAToolOnThisBox", nil, { "/nowhere/*/x" }))
  end)
end)

describe("nvim-stm32.tools.child_path", function()
  it("prepends toolchain_path to the inherited PATH", function()
    local cfg = config.resolve({ toolchain_path = "/opt/arm/bin" })
    local path = tools.child_path(cfg)
    assert.equals("/opt/arm/bin:", path:sub(1, #"/opt/arm/bin:"))
    assert.is_truthy(path:find(vim.env.PATH, 1, true))
  end)

  it("returns the inherited PATH unchanged when toolchain_path is unset", function()
    assert.equals(vim.env.PATH, tools.child_path(config.resolve()))
  end)

  it("env() carries the same PATH", function()
    local cfg = config.resolve({ toolchain_path = "/opt/arm/bin" })
    assert.equals(tools.child_path(cfg), tools.env(cfg).PATH)
  end)
end)
```

- [ ] **Step 2: Run it and watch it fail**

```bash
cd ~/Documents/dev/nvim-stm32 && scripts/test.sh tests/tools_spec.lua
```

Expected: FAIL, "module 'nvim-stm32.tools' not found".

- [ ] **Step 3: Write `lua/nvim-stm32/tools.lua`**

```lua
--- nvim-stm32: finding the external programs, and the environment to run them in.
---
--- Resolution order for every tool is the same: an explicit path from the
--- config, then $PATH, then the known install locations. STM32_Programmer_CLI
--- is the reason the third step exists at all; ST never puts it on $PATH.
local M = {}

--- Where a tool lives when it is not on $PATH. Adding a platform or an install
--- layout is a new entry, never a branch in code.
---@type table<string, string[]>
M.globs = {
  STM32_Programmer_CLI = {
    "~/Library/Application Support/stm32cube/bundles/programmer/*/bin/STM32_Programmer_CLI",
    "/Applications/STMicroelectronics/STM32Cube/STM32CubeProgrammer/STM32CubeProgrammer.app/Contents/MacOs/bin/STM32_Programmer_CLI",
    "~/STMicroelectronics/STM32Cube/STM32CubeProgrammer/bin/STM32_Programmer_CLI",
    "/opt/st/stm32cubeprogrammer/bin/STM32_Programmer_CLI",
  },
}

--- Sort version-bearing paths newest first.
---
--- Called on the matches of a single glob, where every path differs only in its
--- version directory, so comparing the runs of digits in order is a version
--- compare. A string sort is not: it puts ".../2.9.0/..." above ".../2.23.0/...".
---@param paths string[]
---@return string[]  a new list, newest first
function M.by_version_desc(paths)
  local function digits(p)
    local out = {}
    for n in p:gmatch("%d+") do
      out[#out + 1] = tonumber(n)
    end
    return out
  end

  local sorted = vim.deepcopy(paths)
  table.sort(sorted, function(a, b)
    local da, db = digits(a), digits(b)
    for i = 1, math.max(#da, #db) do
      local x, y = da[i] or -1, db[i] or -1
      if x ~= y then
        return x > y
      end
    end
    return a > b
  end)
  return sorted
end

--- Locate an executable.
---@param name string          basename to look for on $PATH
---@param override string|nil  explicit path from the config
---@param globs string[]|nil   install-location patterns; defaults to M.globs[name]
---@return string|nil
function M.resolve(name, override, globs)
  if override and override ~= "" then
    local path = vim.fs.normalize(override)
    return vim.fn.executable(path) == 1 and path or nil
  end

  local on_path = vim.fn.exepath(name)
  if on_path ~= "" then
    return on_path
  end

  for _, pattern in ipairs(globs or M.globs[name] or {}) do
    local hits = M.by_version_desc(vim.fn.glob(vim.fs.normalize(pattern), false, true))
    for _, hit in ipairs(hits) do
      if vim.fn.executable(hit) == 1 then
        return hit
      end
    end
  end

  return nil
end

--- $PATH for child processes, with the configured toolchain directory in front.
---
--- The zsh function this plugin replaces does exactly this. Dropping it is what
--- turns a working setup into "arm-none-eabi-gcc: not found" from inside Neovim
--- while the same build works in a terminal.
---@param cfg Stm32Config
---@return string
function M.child_path(cfg)
  local path = vim.env.PATH or ""
  if cfg.toolchain_path and cfg.toolchain_path ~= "" then
    return cfg.toolchain_path .. ":" .. path
  end
  return path
end

--- Environment overlay for vim.system(). Without `clear_env`, vim.system merges
--- this over the parent environment, so PATH alone is enough.
---@param cfg Stm32Config
---@return table<string, string>
function M.env(cfg)
  return { PATH = M.child_path(cfg) }
end

--- STM32_Programmer_CLI, or nil.
---@param cfg Stm32Config
---@return string|nil
function M.programmer(cfg)
  return M.resolve("STM32_Programmer_CLI", cfg.programmer_path)
end

--- arm-none-eabi-gdb, or nil. Looks in toolchain_path first: the ARM toolchain
--- ships its own gdb and a system gdb cannot debug a Cortex-M target.
---@param cfg Stm32Config
---@return string|nil
function M.gdb(cfg)
  if cfg.gdb_path then
    return M.resolve("arm-none-eabi-gdb", cfg.gdb_path)
  end
  if cfg.toolchain_path then
    local bundled = cfg.toolchain_path .. "/arm-none-eabi-gdb"
    if vim.fn.executable(bundled) == 1 then
      return bundled
    end
  end
  return M.resolve("arm-none-eabi-gdb", nil)
end

--- openocd, or nil.
---@param cfg Stm32Config
---@return string|nil
function M.openocd(cfg)
  return M.resolve("openocd", cfg.openocd_path)
end

--- st-flash (stlink-tools), or nil.
---@param cfg Stm32Config
---@return string|nil
function M.stlink(cfg)
  return M.resolve("st-flash", cfg.stlink_path)
end

return M
```

- [ ] **Step 4: Run it and watch it pass**

```bash
cd ~/Documents/dev/nvim-stm32 && scripts/test.sh tests/tools_spec.lua
```

Expected: 11 successes, 0 failures.

- [ ] **Step 5: Check it finds the real programmer on this machine**

```bash
cd ~/Documents/dev/nvim-stm32
nvim --headless --noplugin -u tests/minimal_init.lua -c '
  lua local c = require("nvim-stm32.config").resolve()
  lua print("programmer:", require("nvim-stm32.tools").programmer(c))
  lua print("gdb:", require("nvim-stm32.tools").gdb(c))
' -c q
```

Expected: the programmer line prints
`.../stm32cube/bundles/programmer/2.23.0/bin/STM32_Programmer_CLI` and the gdb
line prints the `arm-gnu-toolchain-15.2.rel1` binary, which is already on the
login shell's `$PATH`.

- [ ] **Step 6: Format and commit**

```bash
cd ~/Documents/dev/nvim-stm32
stylua lua/ tests/ && stylua --check lua/ tests/
git add lua/nvim-stm32/tools.lua tests/tools_spec.lua
git commit -m "feat(tools): executable resolution, versioned globs, child PATH"
```

---

### Task 4: `setup()` and `:checkhealth nvim-stm32`

**Files:**
- Modify: `lua/nvim-stm32/init.lua` (replace the Task 1 stub entirely)
- Create: `lua/nvim-stm32/health.lua`
- Test: `tests/setup_spec.lua`, `tests/health_spec.lua`

**Interfaces:**
- Consumes: `config.resolve` (Task 2), `tools.*` (Task 3).
- Produces:
  - `require("nvim-stm32").setup(opts?) -> M`, `M.config` (Stm32Config|nil)
  - `require("nvim-stm32").get_config() -> Stm32Config` (defaults before setup)
  - `health.tool_status(label, path, opt_key) -> level, msg, advice`
  - `health.check()`, reached by `:checkhealth nvim-stm32`

`health.check()` itself calls into `vim.health`, which headless specs cannot
assert against cleanly. So the wording lives in `tool_status`, a pure function the
spec pins, and `check()` only renders. That is the same split nvim-m1 uses for
`version_status`.

- [ ] **Step 1: Write the failing tests**

`tests/setup_spec.lua`:

```lua
local nvim_stm32 = require("nvim-stm32")

describe("nvim-stm32.setup", function()
  after_each(function()
    nvim_stm32.config = nil
  end)

  it("stores the resolved config", function()
    nvim_stm32.setup({ preset = "Release" })
    assert.equals("Release", nvim_stm32.config.preset)
    assert.equals(115200, nvim_stm32.config.monitor.baud)
  end)

  it("is idempotent", function()
    nvim_stm32.setup({ preset = "Release" })
    nvim_stm32.setup({ preset = "Debug" })
    assert.equals("Debug", nvim_stm32.config.preset)
  end)

  it("returns the module so calls can be chained", function()
    assert.equals(nvim_stm32, nvim_stm32.setup())
  end)

  it("get_config falls back to the defaults before setup runs", function()
    assert.is_nil(nvim_stm32.config)
    assert.equals(115200, nvim_stm32.get_config().monitor.baud)
  end)

  it("propagates a validation error instead of storing a bad config", function()
    assert.has_error(function()
      nvim_stm32.setup({ compiler_nvim = "yes" })
    end)
    assert.is_nil(nvim_stm32.config)
  end)
end)
```

`tests/health_spec.lua`:

```lua
local health = require("nvim-stm32.health")

describe("nvim-stm32.health.tool_status", function()
  it("reports a found tool with its path", function()
    local level, msg = health.tool_status("openocd", "/opt/homebrew/bin/openocd", "openocd_path")
    assert.equals("ok", level)
    assert.equals("openocd: /opt/homebrew/bin/openocd", msg)
  end)

  it("names the config key that overrides a missing tool", function()
    local level, msg, advice =
      health.tool_status("STM32_Programmer_CLI", nil, "programmer_path")
    assert.equals("warn", level)
    assert.is_truthy(msg:find("STM32_Programmer_CLI", 1, true))
    assert.is_truthy(table.concat(advice, " "):find("opts.programmer_path", 1, true))
  end)

  it("falls back to a PATH hint when no key overrides the tool", function()
    local level, _, advice = health.tool_status("cmake", nil, nil)
    assert.equals("warn", level)
    assert.is_truthy(table.concat(advice, " "):find("$PATH", 1, true))
  end)
end)

describe("nvim-stm32.health.check", function()
  it("runs without error", function()
    -- :checkhealth loads the module and calls check(); a nil index in there is a
    -- traceback in the user's face, so at least prove it survives a real run.
    local out = vim.api.nvim_exec2("checkhealth nvim-stm32", { output = true }).output
    assert.is_truthy(out:find("nvim%-stm32"))
  end)
end)
```

- [ ] **Step 2: Run them and watch them fail**

```bash
cd ~/Documents/dev/nvim-stm32 && scripts/test.sh tests/setup_spec.lua
cd ~/Documents/dev/nvim-stm32 && scripts/test.sh tests/health_spec.lua
```

Expected: setup fails on `attempt to call field 'setup' (a nil value)`, health
fails on "module 'nvim-stm32.health' not found".

- [ ] **Step 3: Replace `lua/nvim-stm32/init.lua`**

```lua
--- nvim-stm32: build, flash, monitor and debug STM32 projects from Neovim.
---
--- The plugin finds the project and the chip on its own, so there is nothing to
--- configure per firmware folder:
---
---     require("nvim-stm32").setup()
---
--- Options are documented in the README and typed as |Stm32Config|.
local config = require("nvim-stm32.config")

local M = {}

--- The resolved configuration from the last setup() call, or nil.
---@type Stm32Config|nil
M.config = nil

--- Configure the plugin. Idempotent; the last call wins.
---@param opts? table  See |Stm32Config|.
---@return table  this module, so calls can be chained
function M.setup(opts)
  M.config = config.resolve(opts)
  return M
end

--- The resolved configuration, falling back to the defaults when setup() has not
--- run. Commands and health checks go through this so they work in a config that
--- lazy-loads the plugin on its commands.
---@return Stm32Config
function M.get_config()
  return M.config or config.resolve()
end

return M
```

- [ ] **Step 4: Write `lua/nvim-stm32/health.lua`**

```lua
--- nvim-stm32: `:checkhealth nvim-stm32`.
---
--- Answers the two questions a broken setup raises: which external programs did
--- the plugin find, and which optional Neovim plugins is it able to use.
local M = {}

local h = vim.health

--- Classify a resolved tool path.
---
--- Pure, so the specs pin the wording without a real toolchain on the runner,
--- and so a missing tool always reports the config key that overrides its path
--- instead of a bare "not found".
---@param label string        the program's name, as the user would type it
---@param path string|nil     the resolved path, or nil
---@param opt_key string|nil  config key that overrides this path
---@return "ok"|"warn" level, string msg, string[]|nil advice
function M.tool_status(label, path, opt_key)
  if path then
    return "ok", label .. ": " .. path
  end
  local advice = opt_key
      and { ("Install %s, or set opts.%s to its path."):format(label, opt_key) }
    or { ("Install %s and put it on $PATH."):format(label) }
  return "warn", label .. " not found", advice
end

--- Render one tool_status verdict.
---@param label string
---@param path string|nil
---@param opt_key string|nil
local function report_tool(label, path, opt_key)
  local level, msg, advice = M.tool_status(label, path, opt_key)
  if level == "ok" then
    h.ok(msg)
  else
    h.warn(msg, advice)
  end
end

function M.check()
  local cfg = require("nvim-stm32").get_config()
  local tools = require("nvim-stm32.tools")

  h.start("nvim-stm32: Neovim")
  if vim.fn.has("nvim-0.11") == 1 then
    h.ok("Neovim " .. tostring(vim.version()))
  else
    h.error("Neovim >= 0.11 required")
  end
  if vim.fn.has("win32") == 1 then
    h.error("Windows is not supported; nvim-stm32 targets macOS and Linux")
  end

  h.start("nvim-stm32: build tools")
  if cfg.toolchain_path then
    h.info("toolchain_path: " .. cfg.toolchain_path)
  else
    h.info("toolchain_path unset; children inherit $PATH")
  end
  report_tool("arm-none-eabi-gcc", vim.fn.exepath("arm-none-eabi-gcc"), "toolchain_path")
  report_tool("cmake", vim.fn.exepath("cmake"), nil)
  for _, gen in ipairs({ "ninja", "make" }) do
    local path = vim.fn.exepath(gen)
    if path ~= "" then
      h.ok(gen .. ": " .. path)
    else
      h.info(gen .. " not found")
    end
  end

  h.start("nvim-stm32: programmers")
  report_tool("STM32_Programmer_CLI", tools.programmer(cfg), "programmer_path")
  report_tool("st-flash", tools.stlink(cfg), "stlink_path")
  report_tool("openocd", tools.openocd(cfg), "openocd_path")
  if cfg.flash_backend then
    h.info("flash_backend pinned to " .. cfg.flash_backend)
  else
    h.info("flash probe order: " .. table.concat(cfg.flash_order, ", "))
  end

  h.start("nvim-stm32: debug")
  report_tool("arm-none-eabi-gdb", tools.gdb(cfg), "gdb_path")

  h.start("nvim-stm32: optional integrations")
  for _, mod in ipairs({
    { "snacks", "floats and notifications; a plain nvim_open_win float is used without it" },
    { "dap", "debugging" },
    { "dap-cortex-debug", "richer debugging, RTT and SVD support" },
    { "compiler", "STM32 entries in the compiler.nvim picker" },
  }) do
    if pcall(require, mod[1]) then
      h.ok(mod[1] .. ": " .. mod[2])
    else
      h.info(mod[1] .. " not installed, so no " .. mod[2])
    end
  end
end

return M
```

- [ ] **Step 5: Run both specs and watch them pass**

```bash
cd ~/Documents/dev/nvim-stm32 && scripts/test.sh
```

Expected: every spec passes (smoke 2, config 7, tools 11, setup 5, health 4).

- [ ] **Step 6: Look at the real health report**

```bash
cd ~/Documents/dev/nvim-stm32
nvim --headless --noplugin -u tests/minimal_init.lua \
  -c 'checkhealth nvim-stm32' -c '%p' -c 'q!'
```

Expected: `arm-none-eabi-gcc`, `cmake`, `ninja`, `make`, `STM32_Programmer_CLI`,
`st-flash`, `openocd` and `arm-none-eabi-gdb` all report `ok` with real paths on
this machine. `dap-cortex-debug` reports "not installed"; that is correct, it is
not installed yet.

- [ ] **Step 7: Format and commit**

```bash
cd ~/Documents/dev/nvim-stm32
stylua lua/ tests/ && stylua --check lua/ tests/
git add lua/nvim-stm32/init.lua lua/nvim-stm32/health.lua tests/setup_spec.lua tests/health_spec.lua
git commit -m "feat: setup() and :checkhealth nvim-stm32"
git push
```

Build-order step 1 is done here: the plugin installs, configures and reports what
it can find.

---

### Task 5: `targets.lua`

**Files:**
- Create: `lua/nvim-stm32/targets.lua`
- Test: `tests/targets_spec.lua`

**Interfaces:**
- Consumes: nothing. This module is pure data plus three pure functions.
- Produces:
  - `targets.families` (table keyed by the two-character series code)
  - `targets.flash_sizes` (table<string, integer>), `targets.ram_kb` (table<string, integer>)
  - `targets.parse(mcu: string) -> Stm32Parts|nil`
  - `targets.resolve(mcu: string) -> table|nil` with fields
    `device, family, core, fpu, openocd_cfg, flash_kb, ram_kb`
  - `targets.device_name(mcu: string) -> string|nil`

`parse` has to swallow every spelling the detectors in Task 7 produce:
`STM32F429ZITx` from a `.ioc`, `STM32F429xx` from a compile macro,
`stm32f429xx` from a startup file name, `STM32F429ZITX` from a linker script.
Uppercase once, then read fixed positions. Every series code is exactly two
characters and every device code exactly four, `WB55` and `WLE5` included, so
there is no branching.

Note on `openocd_cfg`: the table names the config as upstream OpenOCD spells it.
The installed OpenOCD 0.12.0 ships no `stm32c0x.cfg` or `stm32h5x.cfg`; those
arrived later. The OpenOCD flash backend in build-order step 4 checks the file
exists and says so. Do not paper over it here.

- [ ] **Step 1: Write the failing test**

`tests/targets_spec.lua`:

```lua
local targets = require("nvim-stm32.targets")

describe("nvim-stm32.targets.parse", function()
  it("reads a full part number from a .ioc", function()
    local p = targets.parse("STM32F429ZITx")
    assert.equals("F4", p.series)
    assert.equals("STM32F429", p.device)
    assert.equals("Z", p.pins)
    assert.equals("I", p.flash)
    assert.equals("T", p.package)
  end)

  it("reads a wildcard part number from a compile macro", function()
    local p = targets.parse("STM32F429xx")
    assert.equals("STM32F429", p.device)
    assert.is_nil(p.pins)
    assert.is_nil(p.flash)
  end)

  it("is case insensitive, as startup file names are lower case", function()
    assert.same(targets.parse("STM32F429XX"), targets.parse("stm32f429xx"))
  end)

  it("reads the two-letter series codes", function()
    assert.equals("STM32WB55", targets.parse("STM32WB55RGVx").device)
    assert.equals("STM32WLE5", targets.parse("STM32WLE5JCIx").device)
  end)

  it("rejects an unknown series", function()
    assert.is_nil(targets.parse("STM32Q999ZITx"))
  end)

  it("rejects strings that are not part numbers", function()
    assert.is_nil(targets.parse("STM32F4"))
    assert.is_nil(targets.parse("main.c"))
    assert.is_nil(targets.parse(""))
    assert.is_nil(targets.parse(nil))
  end)
end)

describe("nvim-stm32.targets.resolve", function()
  it("resolves the board on the desk", function()
    local t = targets.resolve("STM32F429ZITx")
    assert.equals("STM32F4", t.family)
    assert.equals("cortex-m4", t.core)
    assert.equals("fpv4-sp-d16", t.fpu)
    assert.equals(2048, t.flash_kb)
    assert.equals(256, t.ram_kb)
    assert.equals("target/stm32f4x.cfg", t.openocd_cfg)
  end)

  it("resolves family facts from a wildcard part number, minus the memory", function()
    local t = targets.resolve("STM32F429xx")
    assert.equals("cortex-m4", t.core)
    assert.is_nil(t.flash_kb)
  end)

  it("reports no FPU on the cores that have none", function()
    assert.is_nil(targets.resolve("STM32F103C8Tx").fpu)
    assert.is_nil(targets.resolve("STM32G071RBTx").fpu)
    assert.is_nil(targets.resolve("STM32WLE5JCIx").fpu)
  end)

  it("covers every family the design lists", function()
    local want = {
      "STM32C031C6Tx", "STM32F030R8Tx", "STM32F103C8Tx", "STM32F207ZGTx",
      "STM32F303RETx", "STM32F429ZITx", "STM32F746ZGTx", "STM32G071RBTx",
      "STM32G474RETx", "STM32H563ZITx", "STM32H743ZITx", "STM32L010RBTx",
      "STM32L152RETx", "STM32L432KCUx", "STM32L552ZETx", "STM32U575ZITx",
      "STM32WB55RGVx", "STM32WLE5JCIx",
    }
    for _, mcu in ipairs(want) do
      local t = targets.resolve(mcu)
      assert.is_truthy(t, mcu .. " must resolve")
      assert.is_truthy(t.core:match("^cortex%-m"), mcu .. " needs a core")
      assert.is_truthy(t.openocd_cfg:match("^target/stm32"), mcu .. " needs a cfg")
    end
  end)

  it("returns nil for an unparseable part number", function()
    assert.is_nil(targets.resolve("nonsense"))
  end)
end)

describe("nvim-stm32.targets.device_name", function()
  it("drops the package and temperature codes", function()
    assert.equals("STM32F429ZI", targets.device_name("STM32F429ZITx"))
  end)

  it("falls back to the device code for a wildcard part number", function()
    assert.equals("STM32F429", targets.device_name("STM32F429xx"))
  end)

  it("returns nil for an unparseable part number", function()
    assert.is_nil(targets.device_name("main.c"))
  end)
end)
```

- [ ] **Step 2: Run it and watch it fail**

```bash
cd ~/Documents/dev/nvim-stm32 && scripts/test.sh tests/targets_spec.lua
```

Expected: FAIL, "module 'nvim-stm32.targets' not found".

- [ ] **Step 3: Write `lua/nvim-stm32/targets.lua`**

```lua
--- nvim-stm32: what a part number tells you about the chip.
---
--- Everything here is a table lookup on ST's part-number scheme:
---
---     STM32 F4 29 Z I T x
---           |  |  | | | temperature range
---           |  |  | | package
---           |  |  | flash size
---           |  |  pin count
---           |  device
---           series
---
--- Supporting another family is a new entry in M.families. It must never become
--- a branch in code.
local M = {}

---@class Stm32FamilyInfo
---@field family string       marketing family, e.g. "STM32F4"
---@field core string         e.g. "cortex-m4"
---@field fpu string|nil      GCC -mfpu value, nil when the core has no FPU
---@field openocd_cfg string  target config, relative to OpenOCD's scripts dir

--- Series code (the two characters after "STM32") to family facts.
---
--- `fpu` is the family's usual FPU. A handful of parts differ from their family
--- (some STM32F7 devices are single precision), so the CMake signal in
--- detect.lua overrides this with the -mfpu the project actually builds with.
---
--- The OpenOCD configs are named as upstream spells them. OpenOCD 0.12.0 ships
--- no stm32c0x.cfg or stm32h5x.cfg; the OpenOCD backend checks and reports it.
---@type table<string, Stm32FamilyInfo>
M.families = {
  C0 = { family = "STM32C0", core = "cortex-m0plus", fpu = nil, openocd_cfg = "target/stm32c0x.cfg" },
  F0 = { family = "STM32F0", core = "cortex-m0", fpu = nil, openocd_cfg = "target/stm32f0x.cfg" },
  F1 = { family = "STM32F1", core = "cortex-m3", fpu = nil, openocd_cfg = "target/stm32f1x.cfg" },
  F2 = { family = "STM32F2", core = "cortex-m3", fpu = nil, openocd_cfg = "target/stm32f2x.cfg" },
  F3 = { family = "STM32F3", core = "cortex-m4", fpu = "fpv4-sp-d16", openocd_cfg = "target/stm32f3x.cfg" },
  F4 = { family = "STM32F4", core = "cortex-m4", fpu = "fpv4-sp-d16", openocd_cfg = "target/stm32f4x.cfg" },
  F7 = { family = "STM32F7", core = "cortex-m7", fpu = "fpv5-d16", openocd_cfg = "target/stm32f7x.cfg" },
  G0 = { family = "STM32G0", core = "cortex-m0plus", fpu = nil, openocd_cfg = "target/stm32g0x.cfg" },
  G4 = { family = "STM32G4", core = "cortex-m4", fpu = "fpv4-sp-d16", openocd_cfg = "target/stm32g4x.cfg" },
  H5 = { family = "STM32H5", core = "cortex-m33", fpu = "fpv5-sp-d16", openocd_cfg = "target/stm32h5x.cfg" },
  H7 = { family = "STM32H7", core = "cortex-m7", fpu = "fpv5-d16", openocd_cfg = "target/stm32h7x.cfg" },
  L0 = { family = "STM32L0", core = "cortex-m0plus", fpu = nil, openocd_cfg = "target/stm32l0.cfg" },
  L1 = { family = "STM32L1", core = "cortex-m3", fpu = nil, openocd_cfg = "target/stm32l1.cfg" },
  L4 = { family = "STM32L4", core = "cortex-m4", fpu = "fpv4-sp-d16", openocd_cfg = "target/stm32l4x.cfg" },
  L5 = { family = "STM32L5", core = "cortex-m33", fpu = "fpv5-sp-d16", openocd_cfg = "target/stm32l5x.cfg" },
  U5 = { family = "STM32U5", core = "cortex-m33", fpu = "fpv5-sp-d16", openocd_cfg = "target/stm32u5x.cfg" },
  WB = { family = "STM32WB", core = "cortex-m4", fpu = "fpv4-sp-d16", openocd_cfg = "target/stm32wbx.cfg" },
  WL = { family = "STM32WL", core = "cortex-m4", fpu = nil, openocd_cfg = "target/stm32wlx.cfg" },
}

--- Flash-size code to size in KiB. Position 6 of the part number.
---@type table<string, integer>
M.flash_sizes = {
  ["3"] = 8,
  ["4"] = 16,
  ["6"] = 32,
  ["8"] = 64,
  B = 128,
  Z = 192,
  C = 256,
  D = 384,
  E = 512,
  F = 768,
  G = 1024,
  H = 1536,
  I = 2048,
  J = 4096,
}

--- SRAM in KiB, by device code. The part number encodes flash but not RAM, so
--- this is per-device data and only the devices worth naming are listed. An
--- unlisted device reports nil, which every consumer already handles.
---@type table<string, integer>
M.ram_kb = {
  STM32F429 = 256, -- 192 KiB SRAM plus 64 KiB CCM
}

---@class Stm32Parts
---@field mcu string        the input, upper cased
---@field series string     two-character series code, e.g. "F4"
---@field device string     e.g. "STM32F429"
---@field pins string|nil   pin-count code, nil where the part number wildcards it
---@field flash string|nil  flash-size code
---@field package string|nil
---@field temp string|nil

--- Split a part number into its coded fields.
---
--- Accepts every spelling the detectors produce: "STM32F429ZITx" from a .ioc,
--- "STM32F429xx" from a compile macro, "stm32f429xx" from a startup file name,
--- "STM32F429ZITX" from a linker script. An `X` in any position is ST's
--- wildcard and reads back as nil.
---@param mcu string|nil
---@return Stm32Parts|nil
function M.parse(mcu)
  if type(mcu) ~= "string" then
    return nil
  end
  local rest = mcu:upper():match("^STM32([%u%d]+)$")
  if not rest or #rest < 4 then
    return nil
  end
  local series = rest:sub(1, 2)
  if not M.families[series] then
    return nil
  end

  local function code(i)
    local c = rest:sub(i, i)
    if c == "" or c == "X" then
      return nil
    end
    return c
  end

  return {
    mcu = mcu:upper(),
    series = series,
    device = "STM32" .. rest:sub(1, 4),
    pins = code(5),
    flash = code(6),
    package = code(7),
    temp = code(8),
  }
end

--- Everything this module knows about a part number.
---@param mcu string|nil
---@return table|nil  { device, family, core, fpu, openocd_cfg, flash_kb, ram_kb }
function M.resolve(mcu)
  local parts = M.parse(mcu)
  if not parts then
    return nil
  end
  local fam = M.families[parts.series]
  return {
    device = parts.device,
    family = fam.family,
    core = fam.core,
    fpu = fam.fpu,
    openocd_cfg = fam.openocd_cfg,
    flash_kb = parts.flash and M.flash_sizes[parts.flash] or nil,
    ram_kb = M.ram_kb[parts.device],
  }
end

--- The name ST's own tools want: the part number without its package and
--- temperature codes, so STM32F429ZITx becomes STM32F429ZI. CubeProgrammer,
--- cortex-debug's `device` field and SVD file names all use this form. Falls
--- back to the device code when the part number wildcards the pin count.
---@param mcu string|nil
---@return string|nil
function M.device_name(mcu)
  local parts = M.parse(mcu)
  if not parts then
    return nil
  end
  if parts.pins and parts.flash then
    return parts.device .. parts.pins .. parts.flash
  end
  return parts.device
end

return M
```

- [ ] **Step 4: Run it and watch it pass**

```bash
cd ~/Documents/dev/nvim-stm32 && scripts/test.sh tests/targets_spec.lua
```

Expected: 14 successes, 0 failures. If the "covers every family" case fails, the
message names the part number that did not resolve.

- [ ] **Step 5: Format and commit**

```bash
cd ~/Documents/dev/nvim-stm32
stylua lua/ tests/ && stylua --check lua/ tests/
git add lua/nvim-stm32/targets.lua tests/targets_spec.lua
git commit -m "feat(targets): part-number parsing and family table for 18 series"
```

---

### Task 6: Test fixtures and the project-root walk

**Files:**
- Create: `lua/nvim-stm32/detect.lua`
- Create: `tests/fixtures/` (eight directories, built from the CSSE3010 corpus)
- Test: `tests/detect_root_spec.lua`

**Interfaces:**
- Consumes: nothing yet (Task 7 adds the `targets.lua` dependency).
- Produces:
  - `detect.markers` (ordered list of `{ file|glob, backend }`)
  - `detect.start_dir() -> string`
  - `detect.markers_in(dir: string) -> string|nil backend, string|nil marker`
  - `detect.root(dir?: string) -> string|nil root, string|nil backend, string|nil marker`

The root walk is the crux of the whole plugin. Neovim gets opened at
`~/Documents/University/CSSE3010/repo`, which holds thirteen independent firmware
folders, so the working directory says nothing about which board is being built.
The buffer's own path is the only anchor.

**Read from the CSSE3010 repo, never write to it.** Every command below copies out.

- [ ] **Step 1: Build the fixtures**

```bash
set -euo pipefail
src=~/Documents/University/CSSE3010/repo
dst=~/Documents/dev/nvim-stm32/tests/fixtures

# 1. Every signal present and agreeing: trimmed from s5/dt (a NUCLEO-F429ZI).
mkdir -p "$dst/nucleo_cmake/cmake/stm32cubemx" "$dst/nucleo_cmake/Core/Src"
grep -E '^(Mcu\.(Name|Family|CPN|Package|UserName)|ProjectManager\.(DeviceId|ProjectName|TargetToolchain|FirmwarePackage)|board|boardIOC)=' \
  "$src/s5/dt/dt.ioc" > "$dst/nucleo_cmake/dt.ioc"
cp "$src/s5/dt/CMakePresets.json" "$dst/nucleo_cmake/CMakePresets.json"
cp "$src/s5/dt/CMakeLists.txt" "$dst/nucleo_cmake/CMakeLists.txt"
cp "$src/s5/dt/cmake/gcc-arm-none-eabi.cmake" "$dst/nucleo_cmake/cmake/"
head -20 "$src/s5/dt/cmake/stm32cubemx/CMakeLists.txt" \
  > "$dst/nucleo_cmake/cmake/stm32cubemx/CMakeLists.txt"
head -20 "$src/s5/dt/STM32F429xx_FLASH.ld" > "$dst/nucleo_cmake/STM32F429xx_FLASH.ld"
head -20 "$src/s5/dt/startup_stm32f429xx.s" > "$dst/nucleo_cmake/startup_stm32f429xx.s"
printf 'int main(void) {\n  for (;;) {\n  }\n}\n' > "$dst/nucleo_cmake/Core/Src/main.c"

# 2. Linker script only: Stage0/GPIO_IOToggle has no .ioc and no startup file,
#    and its linker script carries the FULL part number rather than the wildcard.
mkdir -p "$dst/linker_only"
cp "$src/Stage0/GPIO_IOToggle/CMakePresets.json" "$dst/linker_only/"
cp "$src/Stage0/GPIO_IOToggle/STM32F429ZITX_FLASH.ld" "$dst/linker_only/"

# 3. Startup file only.
mkdir -p "$dst/startup_only"
cp "$src/s5/dt/CMakePresets.json" "$dst/startup_only/"
head -20 "$src/s5/dt/startup_stm32f429xx.s" > "$dst/startup_only/startup_stm32f429xx.s"

# 4. CMake files only: the device macro lives in CubeMX's generated
#    subdirectory, not the top-level CMakeLists.txt.
mkdir -p "$dst/cmake_only/cmake/stm32cubemx"
cp "$src/s5/dt/CMakePresets.json" "$dst/cmake_only/"
cp "$src/s5/dt/cmake/gcc-arm-none-eabi.cmake" "$dst/cmake_only/cmake/"
head -20 "$src/s5/dt/cmake/stm32cubemx/CMakeLists.txt" \
  > "$dst/cmake_only/cmake/stm32cubemx/CMakeLists.txt"

# 5. .ioc only: a project root with nothing to build.
mkdir -p "$dst/ioc_only"
cp "$dst/nucleo_cmake/dt.ioc" "$dst/ioc_only/"

# 6. Presets and a Makefile side by side, as s2/Prep really is.
mkdir -p "$dst/presets_and_makefile"
cp "$src/s2/Prep/CMakePresets.json" "$dst/presets_and_makefile/"
head -40 "$src/s2/Prep/Makefile" > "$dst/presets_and_makefile/Makefile"

# 7. Makefile only.
mkdir -p "$dst/makefile_only"
head -40 "$src/s2/Prep/Makefile" > "$dst/makefile_only/Makefile"

# 8. Signals that disagree: the .ioc says F429ZI, the linker script says F401RE.
mkdir -p "$dst/conflict"
cp "$dst/nucleo_cmake/dt.ioc" "$dst/conflict/"
sed 's/STM32F429xx/STM32F401xE/g' "$dst/nucleo_cmake/STM32F429xx_FLASH.ld" \
  > "$dst/conflict/STM32F401RETX_FLASH.ld"

find "$dst" -type f | sort
```

Confirm before moving on that `tests/fixtures/nucleo_cmake/dt.ioc` contains
`Mcu.Name=STM32F429ZITx` and `board=NUCLEO-F429ZI`, and that
`tests/fixtures/cmake_only/cmake/stm32cubemx/CMakeLists.txt` contains the token
`STM32F429xx`. If `head -20` truncated the macro away, raise the line count until
it is there.

- [ ] **Step 2: Write the failing test**

`tests/detect_root_spec.lua`:

```lua
local detect = require("nvim-stm32.detect")

--- Absolute path to a fixture, resolved from this spec's own location so the
--- suite does not care what the working directory is.
---@param rel string
---@return string
local function fixture(rel)
  local here =
    vim.fn.fnamemodify(vim.fn.resolve(debug.getinfo(1, "S").source:sub(2)), ":p:h")
  return here .. "/fixtures/" .. rel
end

describe("nvim-stm32.detect.markers_in", function()
  it("prefers CMakePresets.json over a Makefile in the same directory", function()
    local backend, marker = detect.markers_in(fixture("presets_and_makefile"))
    assert.equals("cmake_presets", backend)
    assert.equals(fixture("presets_and_makefile") .. "/CMakePresets.json", marker)
  end)

  it("falls back to the Makefile when there are no CMake files", function()
    local backend = detect.markers_in(fixture("makefile_only"))
    assert.equals("make", backend)
  end)

  it("marks an .ioc-only directory as a root with nothing to build", function()
    local backend, marker = detect.markers_in(fixture("ioc_only"))
    assert.is_nil(backend)
    assert.equals(fixture("ioc_only") .. "/dt.ioc", marker)
  end)

  it("finds nothing in a directory with no markers", function()
    local backend, marker = detect.markers_in(fixture("nucleo_cmake/Core/Src"))
    assert.is_nil(backend)
    assert.is_nil(marker)
  end)
end)

describe("nvim-stm32.detect.root", function()
  it("walks up from a source file to the firmware folder", function()
    local root, backend = detect.root(fixture("nucleo_cmake/Core/Src"))
    assert.equals(fixture("nucleo_cmake"), root)
    assert.equals("cmake_presets", backend)
  end)

  it("returns the directory itself when it is already a root", function()
    assert.equals(fixture("nucleo_cmake"), (detect.root(fixture("nucleo_cmake"))))
  end)

  it("stops at the nearest root, not the outermost one", function()
    -- CubeMX generates cmake/stm32cubemx/CMakeLists.txt, so that directory is a
    -- root of its own. Nearest wins; this pins the behaviour rather than
    -- pretending it cannot happen.
    local root, backend = detect.root(fixture("nucleo_cmake/cmake/stm32cubemx"))
    assert.equals(fixture("nucleo_cmake/cmake/stm32cubemx"), root)
    assert.equals("cmake_plain", backend)
  end)

  it("returns nil below a git root that holds no markers", function()
    local tmp = vim.fn.tempname()
    vim.fn.mkdir(tmp .. "/.git", "p")
    vim.fn.mkdir(tmp .. "/src/deep", "p")
    assert.is_nil(detect.root(tmp .. "/src/deep"))
    vim.fn.delete(tmp, "rf")
  end)

  it("does not escape the git root to find a marker above it", function()
    -- A Makefile outside the repository must not be adopted as this project's
    -- root; running a build from the wrong directory is the failure mode the
    -- design calls out by name.
    local tmp = vim.fn.tempname()
    vim.fn.mkdir(tmp .. "/repo/src", "p")
    vim.fn.mkdir(tmp .. "/repo/.git", "p")
    vim.fn.writefile({ "all:" }, tmp .. "/Makefile")
    assert.is_nil(detect.root(tmp .. "/repo/src"))
    vim.fn.delete(tmp, "rf")
  end)
end)

describe("nvim-stm32.detect.start_dir", function()
  it("uses the current buffer's directory", function()
    vim.cmd("edit " .. vim.fn.fnameescape(fixture("nucleo_cmake/Core/Src/main.c")))
    assert.equals(fixture("nucleo_cmake/Core/Src"), detect.start_dir())
    vim.cmd("bwipeout!")
  end)

  it("falls back to the working directory for an unnamed buffer", function()
    vim.cmd("enew")
    assert.equals(vim.fn.getcwd(), detect.start_dir())
    vim.cmd("bwipeout!")
  end)
end)
```

- [ ] **Step 3: Run it and watch it fail**

```bash
cd ~/Documents/dev/nvim-stm32 && scripts/test.sh tests/detect_root_spec.lua
```

Expected: FAIL, "module 'nvim-stm32.detect' not found".

- [ ] **Step 4: Write `lua/nvim-stm32/detect.lua`**

```lua
--- nvim-stm32: finding the project, and working out what chip it targets.
---
--- Neovim is normally opened at a repository root that holds many independent
--- firmware folders, so the working directory says nothing about which board is
--- being built. The buffer's own path is the only reliable anchor, and the walk
--- upward stops at the git root so a build can never run outside the project.
local M = {}

--- Build markers, highest precedence first. The first directory holding any of
--- these is the project root, and the highest-precedence marker it holds names
--- the build backend. An .ioc marks a root with nothing to build yet, so its
--- backend is nil.
---@type { file?: string, glob?: string, backend?: string }[]
M.markers = {
  { file = "CMakePresets.json", backend = "cmake_presets" },
  { file = "CMakeLists.txt", backend = "cmake_plain" },
  { file = "Makefile", backend = "make" },
  { glob = "*.ioc", backend = nil },
}

--- Where a detection walk starts: the current buffer's directory, or the working
--- directory when the buffer has no file.
---@return string
function M.start_dir()
  local name = vim.api.nvim_buf_get_name(0)
  if name ~= "" and vim.uv.fs_stat(name) then
    return vim.fs.dirname(name)
  end
  return vim.fn.getcwd()
end

--- The highest-precedence build marker sitting directly in `dir`.
---@param dir string
---@return string|nil backend, string|nil marker  absolute path to the marker file
function M.markers_in(dir)
  for _, m in ipairs(M.markers) do
    if m.file then
      local path = dir .. "/" .. m.file
      if vim.uv.fs_stat(path) then
        return m.backend, path
      end
    else
      local hits = vim.fn.glob(dir .. "/" .. m.glob, false, true)
      if #hits > 0 then
        table.sort(hits)
        return m.backend, hits[1]
      end
    end
  end
  return nil, nil
end

--- The nearest project root at or above `dir`.
---
--- The git root is checked and is then the hard stop: a marker above it belongs
--- to a different project, and adopting it would run a build in the wrong
--- directory.
---@param dir? string  defaults to start_dir()
---@return string|nil root, string|nil backend, string|nil marker
function M.root(dir)
  dir = vim.fs.normalize(dir or M.start_dir())

  local git = vim.fs.find(".git", { path = dir, upward = true, limit = 1 })[1]
  local stop = git and vim.fs.dirname(git) or nil

  local current = dir
  while current and current ~= "" do
    local backend, marker = M.markers_in(current)
    if marker then
      return current, backend, marker
    end
    if current == stop then
      break
    end
    local parent = vim.fs.dirname(current)
    if parent == current then
      break
    end
    current = parent
  end

  return nil, nil, nil
end

return M
```

- [ ] **Step 5: Run it and watch it pass**

```bash
cd ~/Documents/dev/nvim-stm32 && scripts/test.sh tests/detect_root_spec.lua
```

Expected: 10 successes, 0 failures.

- [ ] **Step 6: Check it against the real corpus**

```bash
cd ~/Documents/dev/nvim-stm32
nvim --headless --noplugin -u tests/minimal_init.lua -c '
  lua local d = require("nvim-stm32.detect")
  lua local base = vim.env.HOME .. "/Documents/University/CSSE3010/repo"
  lua for _, p in ipairs({ "s5/dt/Core/Src", "s2/Prep", "Stage0/GPIO_IOToggle", "" }) do
  lua   print(p, d.root(base .. "/" .. p))
  lua end
' -c q
```

Expected: `s5/dt/Core/Src` resolves to `.../s5/dt` with `cmake_presets`, `s2/Prep`
to itself with `cmake_presets` (not `make`), `Stage0/GPIO_IOToggle` to itself, and
the repository root to `nil` because it holds no build files of its own.

- [ ] **Step 7: Format and commit**

```bash
cd ~/Documents/dev/nvim-stm32
stylua lua/ tests/ && stylua --check lua/ tests/
git add lua/nvim-stm32/detect.lua tests/detect_root_spec.lua tests/fixtures
git commit -m "feat(detect): project-root walk from the buffer, bounded by the git root"
```

---

### Task 7: MCU resolution and the `Target` table

**Files:**
- Modify: `lua/nvim-stm32/detect.lua` (append; do not touch the Task 6 functions)
- Test: `tests/detect_mcu_spec.lua`

**Interfaces:**
- Consumes: `detect.root` (Task 6), `targets.parse` and `targets.resolve` (Task 5).
- Produces:
  - `detect.read_ioc(path) -> string|nil mcu, string|nil board`
  - `detect.mcu_from_startup(basename) -> string|nil`
  - `detect.mcu_from_linker(basename) -> string|nil`
  - `detect.scan_cmake(root) -> string|nil mcu, string|nil core, string|nil fpu, string|nil file`
  - `detect.signal_ioc|signal_startup|signal_linker|signal_cmake (root) -> Stm32Signal|nil`
  - `detect.mcu(root) -> table` with fields
    `mcu?, board?, core?, fpu?, confidence, signals, agreement`
  - `detect.target(dir?) -> Stm32Target|nil, string|nil err`

Each signal is its own function returning one signal or nil, so `detect.mcu` is a
flat loop and every finder is testable on its own. Every candidate part number is
run through `targets.parse` before it counts, which is what stops a stray `.ld`
file from inventing a chip.

- [ ] **Step 1: Write the failing test**

`tests/detect_mcu_spec.lua`:

```lua
local detect = require("nvim-stm32.detect")

local function fixture(rel)
  local here =
    vim.fn.fnamemodify(vim.fn.resolve(debug.getinfo(1, "S").source:sub(2)), ":p:h")
  return here .. "/fixtures/" .. rel
end

describe("nvim-stm32.detect file readers", function()
  it("reads Mcu.Name and board out of a real .ioc", function()
    local mcu, board = detect.read_ioc(fixture("nucleo_cmake/dt.ioc"))
    assert.equals("STM32F429ZITx", mcu)
    assert.equals("NUCLEO-F429ZI", board)
  end)

  it("returns nil for a file that is not an .ioc", function()
    assert.is_nil(detect.read_ioc(fixture("nucleo_cmake/CMakeLists.txt")))
  end)

  it("reads the part number out of a startup file name", function()
    assert.equals("STM32F429XX", detect.mcu_from_startup("startup_stm32f429xx.s"))
    assert.is_nil(detect.mcu_from_startup("main.c"))
  end)

  it("reads both linker script spellings", function()
    -- Twelve of the thirteen CSSE3010 folders use the wildcard name; Stage0
    -- uses the full part number.
    assert.equals("STM32F429XX", detect.mcu_from_linker("STM32F429xx_FLASH.ld"))
    assert.equals("STM32F429ZITX", detect.mcu_from_linker("STM32F429ZITX_FLASH.ld"))
    assert.equals("STM32F401RETX", detect.mcu_from_linker("STM32F401RETx_RAM.ld"))
  end)

  it("rejects a linker script whose name is not a part number", function()
    assert.is_nil(detect.mcu_from_linker("linker_script.ld"))
    assert.is_nil(detect.mcu_from_linker("STM32F429xx_FLASH.txt"))
  end)

  it("finds the device macro in CubeMX's generated CMakeLists", function()
    local mcu, core, fpu = detect.scan_cmake(fixture("cmake_only"))
    assert.equals("STM32F429xx", mcu)
    assert.equals("cortex-m4", core)
    assert.equals("fpv4-sp-d16", fpu)
  end)
end)

describe("nvim-stm32.detect.mcu", function()
  it("takes the .ioc and calls it exact when every signal agrees", function()
    local res = detect.mcu(fixture("nucleo_cmake"))
    assert.equals("STM32F429ZITx", res.mcu)
    assert.equals("NUCLEO-F429ZI", res.board)
    assert.equals("exact", res.confidence)
    assert.equals(4, #res.signals)
    assert.equals(4, res.agreement)
    assert.equals("ioc", res.signals[1].source)
  end)

  it("resolves from the linker script alone, as inferred", function()
    local res = detect.mcu(fixture("linker_only"))
    assert.equals("STM32F429ZITX", res.mcu)
    assert.equals("inferred", res.confidence)
    assert.equals(1, res.agreement)
  end)

  it("resolves from the startup file alone, as inferred", function()
    local res = detect.mcu(fixture("startup_only"))
    assert.equals("STM32F429XX", res.mcu)
    assert.equals("inferred", res.confidence)
    assert.equals("startup", res.signals[1].source)
  end)

  it("resolves from the CMake files alone, and keeps the measured flags", function()
    local res = detect.mcu(fixture("cmake_only"))
    assert.equals("STM32F429xx", res.mcu)
    assert.equals("inferred", res.confidence)
    assert.equals("cortex-m4", res.core)
    assert.equals("fpv4-sp-d16", res.fpu)
  end)

  it("lets the .ioc win over a linker script that disagrees", function()
    local res = detect.mcu(fixture("conflict"))
    assert.equals("STM32F429ZITx", res.mcu)
    assert.equals("exact", res.confidence)
    assert.equals(2, #res.signals)
    -- Only the .ioc names STM32F429; the linker script names STM32F401.
    assert.equals(1, res.agreement)
  end)

  it("reports unknown when no signal fires", function()
    local res = detect.mcu(fixture("makefile_only"))
    assert.equals("unknown", res.confidence)
    assert.is_nil(res.mcu)
    assert.equals(0, res.agreement)
  end)
end)

describe("nvim-stm32.detect.target", function()
  it("assembles the whole Target for the board on the desk", function()
    local t = detect.target(fixture("nucleo_cmake/Core/Src"))
    assert.equals(fixture("nucleo_cmake"), t.root)
    assert.equals("cmake_presets", t.build_backend)
    assert.equals("STM32F429ZITx", t.mcu)
    assert.equals("STM32F4", t.family)
    assert.equals("cortex-m4", t.core)
    assert.equals("fpv4-sp-d16", t.fpu)
    assert.equals(2048, t.flash_kb)
    assert.equals(256, t.ram_kb)
    assert.equals("NUCLEO-F429ZI", t.board)
    assert.equals("target/stm32f4x.cfg", t.openocd_cfg)
    assert.equals("exact", t.confidence)
    assert.is_nil(t.elf)
  end)

  it("still returns a buildable Target when the chip is unknown", function()
    -- The design is explicit: an unresolved MCU degrades the family-specific
    -- features and nothing else. Build and flash still have a root to work in.
    local t = detect.target(fixture("makefile_only"))
    assert.equals("unknown", t.confidence)
    assert.equals("make", t.build_backend)
    assert.is_nil(t.mcu)
    assert.is_nil(t.family)
  end)

  it("returns an error naming the directory when there is no project", function()
    local tmp = vim.fn.tempname()
    vim.fn.mkdir(tmp .. "/.git", "p")
    vim.fn.mkdir(tmp .. "/src", "p")
    local t, err = detect.target(tmp .. "/src")
    assert.is_nil(t)
    assert.is_truthy(err:find(tmp, 1, true))
    vim.fn.delete(tmp, "rf")
  end)
end)
```

- [ ] **Step 2: Run it and watch it fail**

```bash
cd ~/Documents/dev/nvim-stm32 && scripts/test.sh tests/detect_mcu_spec.lua
```

Expected: FAIL, "attempt to call field 'read_ioc' (a nil value)".

- [ ] **Step 3: Append the MCU resolution to `lua/nvim-stm32/detect.lua`**

Insert this above the final `return M`, and add `local targets =
require("nvim-stm32.targets")` next to the module header:

```lua
---@class Stm32Signal
---@field source "ioc"|"startup"|"linker"|"cmake"
---@field mcu string                      part number as that source spells it
---@field confidence "exact"|"inferred"
---@field file string                     the file it was read from
---@field board string|nil                only the .ioc names a board
---@field core string|nil                 only the CMake scan measures the core
---@field fpu string|nil

--- Read the part number and board out of a CubeMX .ioc. The file is flat
--- key=value, one pair per line, so no XML or JSON parsing is involved.
---@param path string
---@return string|nil mcu, string|nil board
function M.read_ioc(path)
  local fh = io.open(path, "r")
  if not fh then
    return nil, nil
  end
  local mcu, device_id, board
  for line in fh:lines() do
    line = line:gsub("\r$", "")
    mcu = mcu or line:match("^Mcu%.Name=(.+)$")
    device_id = device_id or line:match("^ProjectManager%.DeviceId=(.+)$")
    board = board or line:match("^board=(.+)$")
  end
  fh:close()
  return mcu or device_id, board
end

--- Part number from a CubeMX startup file name: startup_stm32f429xx.s.
---@param name string  basename
---@return string|nil
function M.mcu_from_startup(name)
  local stem = name:match("^startup_(.+)%.s$")
  if not stem or not targets.parse(stem) then
    return nil
  end
  return stem:upper()
end

--- Part number from a linker script name. CubeMX writes both
--- STM32F429xx_FLASH.ld and STM32F429ZITX_FLASH.ld depending on its vintage, and
--- STM32CubeIDE adds _RAM variants.
---@param name string  basename
---@return string|nil
function M.mcu_from_linker(name)
  local stem = name:match("^(.+)%.ld$")
  if not stem then
    return nil
  end
  stem = stem:upper():gsub("_FLASH$", ""):gsub("_RAM$", "")
  if not targets.parse(stem) then
    return nil
  end
  return stem
end

--- Scan the project's CMake files for the device macro and the compiler flags.
---
--- CubeMX puts the device macro in the generated cmake/stm32cubemx subdirectory
--- and the -mcpu/-mfpu flags in the toolchain file, so neither is in the
--- top-level CMakeLists.txt and both have to be looked for by name.
---@param root string
---@return string|nil mcu, string|nil core, string|nil fpu, string|nil file
function M.scan_cmake(root)
  local files = {
    root .. "/CMakeLists.txt",
    root .. "/cmake/stm32cubemx/CMakeLists.txt",
  }
  vim.list_extend(files, vim.fn.glob(root .. "/cmake/*.cmake", false, true))

  local mcu, core, fpu, file
  for _, path in ipairs(files) do
    local fh = io.open(path, "r")
    if fh then
      local text = fh:read("*a")
      fh:close()
      if not mcu then
        -- Device macros are always the wildcard spelling, STM32F429xx.
        local hit = text:match("(STM32%u%d[%u%d]+[Xx][Xx])")
        if hit and targets.parse(hit) then
          mcu, file = hit, path
        end
      end
      core = core or text:match("%-mcpu=([%w%-%.]+)")
      fpu = fpu or text:match("%-mfpu=([%w%-%.]+)")
    end
  end
  return mcu, core, fpu, file
end

--- The .ioc signal. The only source that names the full part number by design,
--- and the only one that knows the board.
---@param root string
---@return Stm32Signal|nil
function M.signal_ioc(root)
  for _, path in ipairs(vim.fn.glob(root .. "/*.ioc", false, true)) do
    local mcu, board = M.read_ioc(path)
    if mcu and targets.parse(mcu) then
      return {
        source = "ioc",
        mcu = mcu,
        board = board,
        file = path,
        confidence = "exact",
      }
    end
  end
  return nil
end

--- The startup-file signal. CubeMX writes it at the project root; CubeIDE writes
--- it under Core/Startup.
---@param root string
---@return Stm32Signal|nil
function M.signal_startup(root)
  for _, dir in ipairs({ root, root .. "/Core/Startup" }) do
    for _, path in ipairs(vim.fn.glob(dir .. "/startup_*.s", false, true)) do
      local mcu = M.mcu_from_startup(vim.fs.basename(path))
      if mcu then
        return { source = "startup", mcu = mcu, file = path, confidence = "inferred" }
      end
    end
  end
  return nil
end

--- The linker-script signal.
---@param root string
---@return Stm32Signal|nil
function M.signal_linker(root)
  for _, path in ipairs(vim.fn.glob(root .. "/*.ld", false, true)) do
    local mcu = M.mcu_from_linker(vim.fs.basename(path))
    if mcu then
      return { source = "linker", mcu = mcu, file = path, confidence = "inferred" }
    end
  end
  return nil
end

--- The CMake signal. Carries the measured -mcpu and -mfpu, which beat the
--- family defaults because they are what the project actually builds with.
---@param root string
---@return Stm32Signal|nil
function M.signal_cmake(root)
  local mcu, core, fpu, file = M.scan_cmake(root)
  if not mcu then
    return nil
  end
  return {
    source = "cmake",
    mcu = mcu,
    core = core,
    fpu = fpu,
    file = file,
    confidence = "inferred",
  }
end

--- Resolve the MCU under `root` from four signals, best first.
---
--- The first signal to fire decides the part number and the confidence, exactly
--- as the design's table says. `agreement` then counts how many signals named
--- the same device, so the UI can say how well corroborated that answer is
--- without inventing a confidence level between "inferred" and "exact".
---@param root string
---@return table  { mcu?, board?, core?, fpu?, confidence, signals, agreement }
function M.mcu(root)
  local signals = {}
  for _, find in ipairs({ M.signal_ioc, M.signal_startup, M.signal_linker, M.signal_cmake }) do
    local signal = find(root)
    if signal then
      signals[#signals + 1] = signal
    end
  end

  local best = signals[1]
  if not best then
    return { confidence = "unknown", signals = signals, agreement = 0 }
  end

  local device = targets.parse(best.mcu).device
  local agreement, board, core, fpu = 0, nil, nil, nil
  for _, signal in ipairs(signals) do
    if targets.parse(signal.mcu).device == device then
      agreement = agreement + 1
    end
    board = board or signal.board
    core = core or signal.core
    fpu = fpu or signal.fpu
  end

  return {
    mcu = best.mcu,
    board = board,
    core = core,
    fpu = fpu,
    confidence = best.confidence,
    signals = signals,
    agreement = agreement,
  }
end

---@class Stm32Target
---@field root string             project root, the directory holding the build file
---@field marker string           absolute path to the file that decided the root
---@field build_backend string|nil  "cmake_presets"|"cmake_plain"|"make", nil for an .ioc-only root
---@field mcu string|nil          e.g. "STM32F429ZITx"
---@field family string|nil       e.g. "STM32F4"
---@field core string|nil         e.g. "cortex-m4"
---@field fpu string|nil          e.g. "fpv4-sp-d16"
---@field flash_kb integer|nil
---@field ram_kb integer|nil
---@field board string|nil        e.g. "NUCLEO-F429ZI"
---@field openocd_cfg string|nil  OpenOCD target config for the family
---@field elf string|nil          resolved after a build
---@field confidence "exact"|"inferred"|"unknown"
---@field signals Stm32Signal[]   what fired, in precedence order
---@field agreement integer       how many signals named the same device

--- The Target for `dir`, or the current buffer.
---
--- A root with an unresolved MCU is still a usable Target: build and flash work
--- through the generic path and only the family-specific features degrade. No
--- root at all is an error, because guessing one would run a build in someone
--- else's directory.
---@param dir? string
---@return Stm32Target|nil, string|nil err
function M.target(dir)
  local from = dir or M.start_dir()
  local root, backend, marker = M.root(from)
  if not root then
    return nil, "nvim-stm32: no STM32 project found at or above " .. from
  end

  local found = M.mcu(root)
  local info = found.mcu and targets.resolve(found.mcu) or {}

  return {
    root = root,
    marker = marker,
    build_backend = backend,
    mcu = found.mcu,
    family = info.family,
    core = found.core or info.core,
    fpu = found.fpu or info.fpu,
    flash_kb = info.flash_kb,
    ram_kb = info.ram_kb,
    board = found.board,
    openocd_cfg = info.openocd_cfg,
    elf = nil,
    confidence = found.confidence,
    signals = found.signals,
    agreement = found.agreement,
  }
end
```

- [ ] **Step 4: Run it and watch it pass**

```bash
cd ~/Documents/dev/nvim-stm32 && scripts/test.sh tests/detect_mcu_spec.lua
```

Expected: 16 successes, 0 failures.

- [ ] **Step 5: Run the whole suite**

```bash
cd ~/Documents/dev/nvim-stm32 && scripts/test.sh
```

Expected: everything green. Task 6's specs must still pass untouched.

- [ ] **Step 6: Check every folder in the real corpus resolves**

```bash
cd ~/Documents/dev/nvim-stm32
nvim --headless --noplugin -u tests/minimal_init.lua -c '
  lua local d = require("nvim-stm32.detect")
  lua local base = vim.env.HOME .. "/Documents/University/CSSE3010/repo/"
  lua for _, p in ipairs(vim.fn.glob(base .. "*/*", false, true)) do
  lua   local t = d.target(p)
  lua   if t then
  lua     print(("%-34s %-14s %-14s %-10s x%d"):format(
  lua       vim.fn.fnamemodify(p, ":t:r"), t.mcu or "?", t.build_backend or "-",
  lua       t.confidence, t.agreement))
  lua   end
  lua end
' -c q
```

Expected: thirteen rows. Twelve report `STM32F429ZITx cmake_presets exact` with
agreement 4 (or 3 where CubeMX omitted a file), and `GPIO_IOToggle` reports
`STM32F429ZITX cmake_presets inferred x1`. Any row showing `?` is a detection gap;
fix it before committing.

- [ ] **Step 7: Format and commit**

```bash
cd ~/Documents/dev/nvim-stm32
stylua lua/ tests/ && stylua --check lua/ tests/
git add lua/nvim-stm32/detect.lua tests/detect_mcu_spec.lua
git commit -m "feat(detect): resolve the MCU from four signals into a Target"
```

---

### Task 8: `:STM32Info`, health integration, AGENTS.md

**Files:**
- Create: `plugin/nvim-stm32.lua`
- Create: `lua/nvim-stm32/ui/info.lua`
- Create: `AGENTS.md`, `CLAUDE.md`
- Modify: `lua/nvim-stm32/health.lua` (add one section, keep the rest)
- Modify: `README.md` (replace the Development section's neighbours, keep the rest)
- Test: `tests/info_spec.lua`, `tests/health_spec.lua` (add one case)

**Interfaces:**
- Consumes: `detect.target` (Task 7), `nvim-stm32.get_config()` (Task 4).
- Produces:
  - `info.lines(target: Stm32Target) -> string[]`
  - `:STM32Info`, registered from `plugin/nvim-stm32.lua`

`info.lines` is pure and takes a `Target` rather than looking one up, so the spec
pins the report's wording against a table it builds itself. The command is what
makes build-order step 2 usable by a person rather than only by the test suite.

- [ ] **Step 1: Write the failing test**

`tests/info_spec.lua`:

```lua
local info = require("nvim-stm32.ui.info")

local function target(overrides)
  return vim.tbl_extend("force", {
    root = "/w/s5/dt",
    marker = "/w/s5/dt/CMakePresets.json",
    build_backend = "cmake_presets",
    mcu = "STM32F429ZITx",
    family = "STM32F4",
    core = "cortex-m4",
    fpu = "fpv4-sp-d16",
    flash_kb = 2048,
    ram_kb = 256,
    board = "NUCLEO-F429ZI",
    openocd_cfg = "target/stm32f4x.cfg",
    confidence = "exact",
    agreement = 4,
    signals = {
      { source = "ioc", mcu = "STM32F429ZITx", file = "/w/s5/dt/dt.ioc" },
      { source = "linker", mcu = "STM32F429XX", file = "/w/s5/dt/STM32F429xx_FLASH.ld" },
    },
  }, overrides or {})
end

describe("nvim-stm32.ui.info.lines", function()
  it("reports the chip, the board and the memory", function()
    local text = table.concat(info.lines(target()), "\n")
    assert.is_truthy(text:find("STM32F429ZITx", 1, true))
    assert.is_truthy(text:find("NUCLEO-F429ZI", 1, true))
    assert.is_truthy(text:find("cortex-m4", 1, true))
    assert.is_truthy(text:find("2048 KiB", 1, true))
    assert.is_truthy(text:find("256 KiB", 1, true))
  end)

  it("lists every signal with the file it came from", function()
    local text = table.concat(info.lines(target()), "\n")
    assert.is_truthy(text:find("dt.ioc", 1, true))
    assert.is_truthy(text:find("STM32F429xx_FLASH.ld", 1, true))
    assert.is_truthy(text:find("2 of 2 agree", 1, true))
  end)

  it("says plainly when the chip could not be resolved", function()
    local text = table.concat(
      info.lines(target({
        mcu = nil, family = nil, core = nil, fpu = nil, flash_kb = nil,
        ram_kb = nil, board = nil, openocd_cfg = nil,
        confidence = "unknown", agreement = 0, signals = {},
      })),
      "\n"
    )
    assert.is_truthy(text:find("not resolved", 1, true))
    assert.is_truthy(text:find("/w/s5/dt", 1, true))
  end)

  it("says when a root has no build file", function()
    local text = table.concat(info.lines(target({ build_backend = nil })), "\n")
    assert.is_truthy(text:find("no build file", 1, true))
  end)
end)

describe(":STM32Info", function()
  it("is registered without setup() having run", function()
    assert.is_truthy(vim.fn.exists(":STM32Info") == 2)
  end)
end)
```

Add to `tests/health_spec.lua`:

```lua
describe("nvim-stm32.health project section", function()
  it("names the detected project in the report", function()
    local here =
      vim.fn.fnamemodify(vim.fn.resolve(debug.getinfo(1, "S").source:sub(2)), ":p:h")
    vim.cmd(
      "edit " .. vim.fn.fnameescape(here .. "/fixtures/nucleo_cmake/Core/Src/main.c")
    )
    local out = vim.api.nvim_exec2("checkhealth nvim-stm32", { output = true }).output
    assert.is_truthy(out:find("STM32F429ZITx", 1, true))
    vim.cmd("bwipeout!")
  end)
end)
```

- [ ] **Step 2: Run them and watch them fail**

```bash
cd ~/Documents/dev/nvim-stm32 && scripts/test.sh tests/info_spec.lua
```

Expected: FAIL, "module 'nvim-stm32.ui.info' not found".

- [ ] **Step 3: Write `lua/nvim-stm32/ui/info.lua`**

```lua
--- nvim-stm32: the :STM32Info report.
---
--- lines() is pure and takes a Target rather than resolving one, so the report's
--- wording is testable without a project on disk.
local M = {}

--- Render a Target as the lines :STM32Info prints.
---@param t Stm32Target
---@return string[]
function M.lines(t)
  local out = {
    "Project: " .. t.root,
    "Marker:  " .. vim.fn.fnamemodify(t.marker, ":t"),
    "Build:   " .. (t.build_backend or "no build file in this directory"),
  }

  if not t.mcu then
    out[#out + 1] = "MCU:     not resolved"
    out[#out + 1] = ""
    out[#out + 1] = "Build and flash still work; family-specific features are off."
    return out
  end

  out[#out + 1] = ("MCU:     %s (%s, %s)"):format(t.mcu, t.family, t.confidence)
  out[#out + 1] = "Core:    " .. t.core .. (t.fpu and (" with " .. t.fpu) or ", no FPU")
  if t.board then
    out[#out + 1] = "Board:   " .. t.board
  end
  if t.flash_kb or t.ram_kb then
    out[#out + 1] = ("Memory:  %s flash, %s RAM"):format(
      t.flash_kb and (t.flash_kb .. " KiB") or "unknown",
      t.ram_kb and (t.ram_kb .. " KiB") or "unknown"
    )
  end
  if t.openocd_cfg then
    out[#out + 1] = "OpenOCD: " .. t.openocd_cfg
  end

  out[#out + 1] = ""
  out[#out + 1] = ("Signals: %d of %d agree"):format(t.agreement, #t.signals)
  for _, s in ipairs(t.signals) do
    out[#out + 1] = ("  %-8s %-14s %s"):format(
      s.source,
      s.mcu,
      vim.fn.fnamemodify(s.file, ":t")
    )
  end

  return out
end

--- Resolve the Target for the current buffer and show the report.
function M.show()
  local detect = require("nvim-stm32.detect")
  local target, err = detect.target()
  if not target then
    vim.notify(err, vim.log.levels.WARN)
    return
  end
  -- A notification, not a float: the shared float presenter arrives with the
  -- build backends in build-order step 3, and duplicating it here would leave
  -- two presenters to keep in step.
  vim.notify(table.concat(M.lines(target), "\n"), vim.log.levels.INFO)
end

return M
```

- [ ] **Step 4: Write `plugin/nvim-stm32.lua`**

```lua
-- nvim-stm32 plugin shim. Loaded once on startup.
--
-- Registers the commands that need no configuration, so :STM32Info and
-- :checkhealth work in a config that never calls setup(). Everything else is
-- wired in setup().
if vim.g.loaded_nvim_stm32 then
  return
end
vim.g.loaded_nvim_stm32 = true

vim.api.nvim_create_user_command("STM32Info", function()
  require("nvim-stm32.ui.info").show()
end, { desc = "nvim-stm32: show the detected project and chip" })
```

- [ ] **Step 5: Add the project section to `lua/nvim-stm32/health.lua`**

Insert this block immediately after the `nvim-stm32: Neovim` section and before
`nvim-stm32: build tools`:

```lua
  h.start("nvim-stm32: detected project")
  local target, derr = require("nvim-stm32.detect").target()
  if not target then
    h.info(derr)
  else
    h.ok("project: " .. target.root)
    h.info("build backend: " .. (target.build_backend or "none in this directory"))
    if target.mcu then
      local level = target.confidence == "exact" and h.ok or h.warn
      level(
        ("MCU: %s (%s, %d of %d signals agree)"):format(
          target.mcu,
          target.confidence,
          target.agreement,
          #target.signals
        )
      )
      if target.board then
        h.info("board: " .. target.board)
      end
    else
      h.warn("MCU not resolved; family-specific features are off", {
        "Add a CubeMX .ioc, a startup file or a named linker script to the project.",
      })
    end
  end
```

- [ ] **Step 6: Run the suite and watch it pass**

```bash
cd ~/Documents/dev/nvim-stm32 && scripts/test.sh
```

Expected: everything green, including the two new health cases.

Note the `:STM32Info` registration case only passes because `plugin/` files load
in a normal Neovim start. `scripts/test.sh` passes `--noplugin`, which skips them,
so if that case fails the fix is to require the shim from `tests/minimal_init.lua`
with `vim.cmd("runtime plugin/nvim-stm32.lua")` added after the runtimepath
prepend. Make that change if needed; it belongs to the harness, not the plugin.

- [ ] **Step 7: Try it in a real Neovim against the real board project**

```bash
cd ~/Documents/University/CSSE3010/repo
nvim --cmd "set runtimepath^=$HOME/Documents/dev/nvim-stm32" s5/dt/Core/Src/s4882272_hamming.c
```

Then run `:STM32Info` and `:checkhealth nvim-stm32`. Expected: the info
notification names `STM32F429ZITx`, `NUCLEO-F429ZI`, `cmake_presets`, and four
agreeing signals, from a Neovim opened at the repository root rather than in the
firmware folder. That is the case the whole detection design exists for. Do not
edit or save anything in this repository.

- [ ] **Step 8: Write `AGENTS.md` and `CLAUDE.md`**

`AGENTS.md`:

````markdown
# AGENTS.md — nvim-stm32

Guidance for coding agents working in this repository.

## Purpose

Build, flash, erase, monitor and debug STM32 projects from Neovim. The prior
art all requires the project to be described by hand; automatic detection is
why this plugin exists, so that is where the engineering effort goes.
`docs/design.md` is the approved design and settles the open questions.

## Things that are deliberate (don't "fix" them)

- **Detection anchors on the buffer, not the working directory.** Neovim is
  opened at a repository root holding many independent firmware folders, so
  the working directory names no board. The walk upward stops at the git root:
  a marker above it belongs to somebody else's project.
- **`targets.lua` is data.** Adding a family is a table entry. If supporting a
  chip ever needs a branch in code, the table shape is wrong.
- **Backends expose a pure `cmd()`.** That is what keeps most of the plugin
  testable with no board attached. Keep it that way.
- **Every build and debug child gets `toolchain_path` prepended to `$PATH`.**
  This is the one behaviour the zsh function has that a naive port drops, and
  losing it surfaces as a compiler-not-found error that points nowhere.
- **snacks is optional.** The float presenter uses `snacks.win` when snacks is
  loaded and `nvim_open_win` otherwise. Never make it a hard dependency.
- **Confidence follows the signal, not the vote.** Only a `.ioc` yields
  `exact`; corroboration is reported separately as `agreement`.

## Gotchas that have bitten before

- `STM32_Programmer_CLI` is never on `$PATH` and its install directory is
  version-stamped. Sorting the glob matches as strings puts `2.9.0` above
  `2.23.0`.
- CubeMX puts the device macro in `cmake/stm32cubemx/CMakeLists.txt`, not the
  top-level `CMakeLists.txt`, and the `-mcpu`/`-mfpu` flags in the toolchain
  file under `cmake/`.
- Linker scripts come in two spellings: `STM32F429xx_FLASH.ld` (wildcard) and
  `STM32F429ZITX_FLASH.ld` (full part number).
- `scripts/test.sh` runs with `--noplugin`, so anything registered in
  `plugin/` needs an explicit `runtime` call in `tests/minimal_init.lua`.

## Build / test gate

```sh
scripts/test.sh                    # headless plenary-busted suite
stylua --check lua/ tests/         # separate CI job
```

Fixtures under `tests/fixtures/` are trimmed copies of real CubeMX projects.
Test detection against genuine input, never invented strings. Headless tests
cannot see UI-thread stalls; verify anything user-facing in a real Neovim.

## Releases

Cut from the `VERSION` file on `main`; `release.yml` tags `vX.Y.Z`.
````

`CLAUDE.md`:

```markdown
Read AGENTS.md.
```

- [ ] **Step 9: Bring the README up to date**

Replace the status line in `README.md` with a section that reflects what exists:

```markdown
**Status: under construction.** Detection, `:STM32Info` and
`:checkhealth nvim-stm32` work. Build, flash, monitor and debug are not wired
up yet.

## What it detects

Open any file in a firmware folder and run `:STM32Info`. The plugin walks up
from the buffer to the nearest build file, stopping at the git root, then reads
the chip out of the project: the CubeMX `.ioc`, the startup file name, the
linker script name, and the CMake device macro and compiler flags, in that
order. It reports which signals fired and how many agreed.

Working from the buffer rather than the working directory is the point. A
course repository or a monorepo holds many independent firmware folders, and
the directory Neovim was started in names none of them.
```

- [ ] **Step 10: Format, commit, push**

```bash
cd ~/Documents/dev/nvim-stm32
stylua lua/ tests/ && stylua --check lua/ tests/
scripts/test.sh
git add -A
git commit -m "feat: :STM32Info, project section in checkhealth, contributor docs"
git push
gh run watch --exit-status
```

Build-order step 2 is done here. Steps 3 through 5 (build backends, the float
presenter, flash backends, the compiler.nvim patch) still need no board. Steps 6
and 7 do.

---

## Self-review

**Spec coverage for build-order steps 1 and 2.** `docs/design.md` step 1 is
"Skeleton, config, health": Task 1 is the skeleton, Task 2 the config, Task 3 the
tool resolution health depends on, Task 4 `setup()` and `:checkhealth`. Step 2 is
"`targets.lua` and `detect.lua`": Task 5, Task 6 and Task 7, with Task 8 making
the result visible. The design's testing requirements are all covered: real
trimmed fixtures out of the CSSE3010 stage folders (Task 6 Step 1), each signal
alone (`linker_only`, `startup_only`, `cmake_only`, `ioc_only`), signals agreeing
(`nucleo_cmake`), signals conflicting (`conflict`), and the no-project case (two
tempdir cases). The design's `Target` fields all appear in `Stm32Target`, plus the
four additions flagged at the top.

**Out of scope here, by design.** The backend interface, the float presenter, the
compiler.nvim patch, the monitor, the debug adapter config, `:STM32Build`,
`:STM32Flash`, `:STM32Erase`, `:STM32Monitor`, `:STM32Debug` and
`:STM32SelectTarget` are build-order steps 3 through 7 and get their own plan.
`:STM32Info` lands early because step 2 has no other way to be usable.

**Naming consistency.** `Stm32Config`, `Stm32Target`, `Stm32Signal`, `Stm32Parts`,
`Stm32FamilyInfo`, `Stm32MonitorConfig`, `Stm32FloatConfig` are the type names.
`cfg` is always a resolved `Stm32Config`; `t` or `target` is always an
`Stm32Target`; `root` is always an absolute directory. `build_backend` values are
`cmake_presets`, `cmake_plain`, `make`, matching the design's
`backend/build/*.lua` file names. Flash backend names are `cubeprogrammer`,
`stlink`, `openocd`, matching `backend/flash/*.lua`.

**Known behaviour worth watching.** `detect.root` takes the nearest marker, so a
buffer inside `cmake/stm32cubemx/` resolves to that directory rather than the
firmware folder. Task 6 pins it with a test instead of hiding it. If it turns out
to bite in practice, the fix is a skip list in `M.markers`, not a change to the
walk.
