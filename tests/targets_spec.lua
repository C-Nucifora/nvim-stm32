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
      "STM32C031C6Tx",
      "STM32F030R8Tx",
      "STM32F103C8Tx",
      "STM32F207ZGTx",
      "STM32F303RETx",
      "STM32F429ZITx",
      "STM32F746ZGTx",
      "STM32G071RBTx",
      "STM32G474RETx",
      "STM32H563ZITx",
      "STM32H743ZITx",
      "STM32L010RBTx",
      "STM32L152RETx",
      "STM32L432KCUx",
      "STM32L552ZETx",
      "STM32U575ZITx",
      "STM32WB55RGVx",
      "STM32WLE5JCIx",
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
