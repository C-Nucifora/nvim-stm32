local info = require("nvim-stm32.ui.info")

-- PlenaryBustedFile starts a child with --noplugin, so load the plugin shim as
-- a normal Neovim startup would.
vim.cmd("runtime plugin/nvim-stm32.lua")

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
    agreement = 2,
    signals = {
      { source = "ioc", mcu = "STM32F429ZITx", file = "/w/s5/dt/dt.ioc" },
      {
        source = "linker",
        mcu = "STM32F429XX",
        file = "/w/s5/dt/STM32F429xx_FLASH.ld",
      },
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
    local unresolved = target({ confidence = "unknown", agreement = 0, signals = {} })
    unresolved.mcu = nil
    unresolved.family = nil
    unresolved.core = nil
    unresolved.fpu = nil
    unresolved.flash_kb = nil
    unresolved.ram_kb = nil
    unresolved.board = nil
    unresolved.openocd_cfg = nil

    local text = table.concat(info.lines(unresolved), "\n")
    assert.is_truthy(text:find("not resolved", 1, true))
    assert.is_truthy(text:find("/w/s5/dt", 1, true))
  end)

  it("says when a root has no build file", function()
    local no_build = target()
    no_build.build_backend = nil
    local text = table.concat(info.lines(no_build), "\n")
    assert.is_truthy(text:find("no build file", 1, true))
  end)

  it("lists project images, MCUs, configuration, and known artifacts", function()
    local project = {
      id = "/w/dual",
      root = "/w/dual",
      kind = "cmake_presets",
      build = { marker = "/w/dual/CMakePresets.json" },
      images = {
        { id = "CM4", target = { mcu = "STM32H747XIHx" } },
        { id = "CM7", target = { mcu = "STM32H747XIHx" } },
      },
    }
    local state = {
      configuration = "Debug",
      artifacts = {
        { image_id = "CM4", kind = "elf", path = "/w/dual/build/Debug/cm4.elf" },
      },
    }
    local text = table.concat(info.lines(project, state), "\n")

    assert.matches("Project: /w/dual", text, 1, true)
    assert.matches("CM4: STM32H747XIHx", text, 1, true)
    assert.matches("CM7: STM32H747XIHx", text, 1, true)
    assert.matches("Configuration: Debug", text, 1, true)
    assert.matches("cm4.elf", text, 1, true)
  end)
end)

describe(":STM32Info", function()
  it("is registered without setup() having run", function()
    assert.is_truthy(vim.fn.exists(":STM32Info") == 2)
  end)
end)
