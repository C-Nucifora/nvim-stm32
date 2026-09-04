local root = require("nvim-stm32.discover.root")
local signals = require("nvim-stm32.discover.signals")
local project = require("nvim-stm32.discover.project")
local detect = require("nvim-stm32.detect")

local function fixture(rel)
  local here =
    vim.fn.fnamemodify(vim.fn.resolve(debug.getinfo(1, "S").source:sub(2)), ":p:h")
  return here .. "/fixtures/" .. rel
end

describe("nvim-stm32 project discovery", function()
  it("prefers the outer project over generated nested CMake", function()
    local found = assert(root.find(fixture("nucleo_cmake/cmake/stm32cubemx")))
    assert.equals(fixture("nucleo_cmake"), found)
  end)

  it("collects both images without flattening their cores", function()
    local resolved = assert(project.resolve(fixture("multi_image/CM4")))
    assert.equals(2, #resolved.images)
    assert.same(
      { "CM4", "CM7" },
      vim.tbl_map(function(image)
        return image.id
      end, resolved.images)
    )
  end)

  it("keeps image hints on every collected signal", function()
    local found = signals.collect(fixture("multi_image"))
    assert.equals(4, #found)
    assert.same(
      { "CM4", "CM7", "CM4", "CM7" },
      vim.tbl_map(function(signal)
        return signal.image_hint
      end, found)
    )
    assert.same(
      { "ioc", "ioc", "startup", "startup" },
      vim.tbl_map(function(signal)
        return signal.source
      end, found)
    )
  end)

  it("keeps the compatibility target on a single-image project", function()
    local target = assert(detect.target(fixture("nucleo_cmake/Core/Src")))
    assert.equals("STM32F429ZITx", target.mcu)
    assert.equals("cmake_presets", target.build_backend)
  end)

  it("selects the image nearest the compatibility target directory", function()
    local target = assert(detect.target(fixture("multi_image/CM7")))
    assert.equals("CM7", target.image_id)
    assert.equals("cortex-m7", target.core)
  end)
end)
