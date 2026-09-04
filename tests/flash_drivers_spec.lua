local flash = require("nvim-stm32.drivers.flash")

describe("nvim-stm32 flash driver resolution", function()
  local dir

  before_each(function()
    dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
  end)

  after_each(function()
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

    local driver, tool = assert(flash.resolve(cfg, { backend = "stlink" }))
    assert.equals("stlink", driver.id)
    assert.equals(cfg.stlink_path, tool)
  end)

  it("uses a configured pin when no explicit option is present", function()
    local cfg = unavailable_paths()
    cfg.flash_backend = "openocd"
    cfg.openocd_path = executable("openocd")
    cfg.flash_order = { "cubeprogrammer", "stlink" }

    local driver, tool = assert(flash.resolve(cfg, {}))
    assert.equals("openocd", driver.id)
    assert.equals(cfg.openocd_path, tool)
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

    local driver, tool = assert(flash.resolve(cfg, {}))
    assert.equals("openocd", driver.id)
    assert.equals(cfg.openocd_path, tool)
  end)

  it("honors order even when several backends are available", function()
    local cfg = unavailable_paths()
    cfg.programmer_path = executable("STM32_Programmer_CLI")
    cfg.stlink_path = executable("st-flash")
    cfg.flash_order = { "stlink", "cubeprogrammer" }

    local driver, tool = assert(flash.resolve(cfg, {}))
    assert.equals("stlink", driver.id)
    assert.equals(cfg.stlink_path, tool)
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
