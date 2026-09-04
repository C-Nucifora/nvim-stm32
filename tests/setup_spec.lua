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
