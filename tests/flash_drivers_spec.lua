local flash = require("nvim-stm32.drivers.flash")

describe("nvim-stm32 flash driver resolution", function()
  local dir
  local old_path

  before_each(function()
    dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    old_path = vim.env.PATH
  end)

  after_each(function()
    vim.env.PATH = old_path
    vim.fn.delete(dir, "rf")
  end)

  local function executable(name)
    local path = dir .. "/" .. name
    vim.fn.writefile({ "#!/bin/sh" }, path)
    vim.uv.fs_chmod(path, 493)
    return path
  end

  local function unavailable_paths()
    return {
      programmer_path = dir .. "/missing-programmer",
      stlink_path = dir .. "/missing-st-flash",
      openocd_path = dir .. "/missing-openocd",
    }
  end

  it("uses the explicit backend option before a configured pin", function()
    local cfg = unavailable_paths()
    cfg.flash_backend = "cubeprogrammer"
    cfg.stlink_path = executable("st-flash")
    local st_info = executable("st-info")

    local driver, resolved_tools = assert(flash.resolve(cfg, { backend = "stlink" }))
    assert.equals("stlink", driver.id)
    assert.same({
      program = cfg.stlink_path,
      identify = st_info,
      list = st_info,
    }, resolved_tools)
  end)

  it("uses a configured pin when no explicit option is present", function()
    local cfg = unavailable_paths()
    cfg.flash_backend = "openocd"
    cfg.openocd_path = executable("openocd")
    cfg.flash_order = { "cubeprogrammer", "stlink" }

    local driver, resolved_tools = assert(flash.resolve(cfg, {}))
    assert.equals("openocd", driver.id)
    assert.same({
      program = cfg.openocd_path,
      identify = cfg.openocd_path,
    }, resolved_tools)
  end)

  it("does not fall back when a pinned backend is unavailable", function()
    local cfg = unavailable_paths()
    cfg.flash_backend = "cubeprogrammer"
    cfg.stlink_path = executable("st-flash")
    cfg.flash_order = { "stlink" }

    local driver, err = flash.resolve(cfg, {})
    assert.is_nil(driver)
    assert.equals("flash-backend-unavailable", err.code)
    assert.matches("cubeprogrammer", err.message, 1, true)
  end)

  it("selects the first available driver in flash_order", function()
    local cfg = unavailable_paths()
    cfg.openocd_path = executable("openocd")
    cfg.flash_order = { "cubeprogrammer", "openocd", "stlink" }

    local driver, resolved_tools = assert(flash.resolve(cfg, {}))
    assert.equals("openocd", driver.id)
    assert.same({
      program = cfg.openocd_path,
      identify = cfg.openocd_path,
    }, resolved_tools)
  end)

  it("returns one explicit CubeProgrammer tool map for every capability", function()
    local cfg = unavailable_paths()
    cfg.programmer_path = executable("STM32_Programmer_CLI")
    cfg.flash_backend = "cubeprogrammer"

    local driver, resolved_tools = assert(flash.resolve(cfg, {}))
    assert.equals("cubeprogrammer", driver.id)
    assert.same({
      program = cfg.programmer_path,
      identify = cfg.programmer_path,
      list = cfg.programmer_path,
    }, resolved_tools)
  end)

  it("honors order even when several backends are available", function()
    local cfg = unavailable_paths()
    cfg.programmer_path = executable("STM32_Programmer_CLI")
    cfg.stlink_path = executable("st-flash")
    local st_info = executable("st-info")
    cfg.flash_order = { "stlink", "cubeprogrammer" }

    local driver, resolved_tools = assert(flash.resolve(cfg, {}))
    assert.equals("stlink", driver.id)
    assert.same({
      program = cfg.stlink_path,
      identify = st_info,
      list = st_info,
    }, resolved_tools)
  end)

  it("uses resolved st-info for identity and st-flash for state changes", function()
    local cfg = unavailable_paths()
    local st_flash = executable("st-flash")
    local st_info = executable("st-info")
    cfg.stlink_path = st_flash
    cfg.flash_backend = "stlink"

    local driver, resolved_tools = assert(flash.resolve(cfg, {}))
    local probe = { serial = "ABC123" }
    assert.same(
      { st_info, "--probe" },
      driver.identify_command(resolved_tools.identify, probe).argv
    )
    assert.same(
      {
        st_flash,
        "--serial",
        "0xABC123",
        "write",
        "/tmp/app.bin",
        "0x08000000",
      },
      driver.program_command(resolved_tools.program, {
        probe = probe,
        artifact = { kind = "bin", path = "/tmp/app.bin" },
        address = 0x08000000,
      }).argv
    )
    assert.equals(st_flash, driver.erase_command(resolved_tools.program, probe).argv[1])
    assert.equals(st_flash, driver.reset_command(resolved_tools.program, probe).argv[1])
  end)

  it("does not fall back from pinned stlink when st-info is unavailable", function()
    local cfg = unavailable_paths()
    cfg.stlink_path = executable("st-flash")
    cfg.openocd_path = executable("openocd")
    cfg.flash_backend = "stlink"
    cfg.flash_order = { "openocd" }
    vim.env.PATH = dir .. "/empty-path"

    local driver, err = flash.resolve(cfg, {})
    assert.is_nil(driver)
    assert.equals("flash-backend-unavailable", err.code)
    assert.matches("stlink", err.message, 1, true)
  end)

  it("returns a structured error when no automatic backend is available", function()
    local cfg = unavailable_paths()
    cfg.flash_order = { "cubeprogrammer", "stlink", "openocd" }

    local driver, err = flash.resolve(cfg, {})
    assert.is_nil(driver)
    assert.equals("flash-backend-unavailable", err.code)
  end)

  it("rejects an unknown explicit backend", function()
    local driver, err = flash.resolve(unavailable_paths(), { backend = "jlink" })
    assert.is_nil(driver)
    assert.equals("flash-backend-unknown", err.code)
  end)
end)
