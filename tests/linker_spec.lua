local linker = require("nvim-stm32.inspect.linker")

local function fixture(rel)
  local here =
    vim.fn.fnamemodify(vim.fn.resolve(debug.getinfo(1, "S").source:sub(2)), ":p:h")
  return here .. "/fixtures/" .. rel
end

local function parse(text)
  return linker.parse("MEMORY\n{\n" .. text .. "\n}")
end

describe("nvim-stm32 linker MEMORY parsing", function()
  it("reads the exact F429 regions from a CubeMX linker script", function()
    local contents =
      table.concat(vim.fn.readfile(fixture("nucleo_cmake/STM32F429xx_FLASH.ld")), "\n")

    assert.same({
      { name = "RAM", attributes = "xrw", origin = 0x20000000, length = 192 * 1024 },
      { name = "CCMRAM", attributes = "xrw", origin = 0x10000000, length = 64 * 1024 },
      { name = "FLASH", attributes = "rx", origin = 0x08000000, length = 2048 * 1024 },
    }, assert(linker.parse(contents)))
  end)

  it("accepts decimal origins and byte, K, and M lengths after comments", function()
    local regions = assert(parse([[
      /* the parser must ignore this fake region:
         NOPE (rw) : ORIGIN = bad, LENGTH = bad */
      A (rw) : ORIGIN = 16, LENGTH = 32
      B (rx) : ORIGIN = 0x100, LENGTH = 2K
      C (r) : ORIGIN = 4096, LENGTH = 1M
    ]]))

    assert.same({
      { name = "A", attributes = "rw", origin = 16, length = 32 },
      { name = "B", attributes = "rx", origin = 0x100, length = 2 * 1024 },
      { name = "C", attributes = "r", origin = 4096, length = 1024 * 1024 },
    }, regions)
  end)

  it("rejects a malformed origin without returning partial regions", function()
    local regions, err = parse([[
      RAM (xrw) : ORIGIN = 0x20000000, LENGTH = 192K
      FLASH (rx) : ORIGIN = 0xZZ000000, LENGTH = 2M
    ]])

    assert.is_nil(regions)
    assert.equals("linker-origin-invalid", err.code)
  end)

  it("rejects an unsupported length suffix", function()
    local regions, err = parse("FLASH (rx) : ORIGIN = 0x08000000, LENGTH = 2G")

    assert.is_nil(regions)
    assert.equals("linker-length-invalid", err.code)
  end)

  it("rejects regions that overflow the 32-bit address space", function()
    local regions, err = parse("FLASH (rx) : ORIGIN = 0xfffff000, LENGTH = 8K")

    assert.is_nil(regions)
    assert.equals("linker-region-overflow", err.code)
  end)

  it("rejects duplicate region names case-insensitively", function()
    local regions, err = parse([[
      FLASH (rx) : ORIGIN = 0x08000000, LENGTH = 1M
      flash (rx) : ORIGIN = 0x08100000, LENGTH = 1M
    ]])

    assert.is_nil(regions)
    assert.equals("linker-region-duplicate", err.code)
  end)

  it("rejects overlapping address ranges", function()
    local regions, err = parse([[
      RAM (rw) : ORIGIN = 0x20000000, LENGTH = 192K
      SRAM2 (rw) : ORIGIN = 0x20020000, LENGTH = 128K
    ]])

    assert.is_nil(regions)
    assert.equals("linker-region-overlap", err.code)
  end)

  it("returns the sole case-insensitive FLASH region", function()
    local regions = assert(parse([[
      RAM (rw) : ORIGIN = 0x20000000, LENGTH = 128K
      flash (rx) : ORIGIN = 0x08000000, LENGTH = 1M
    ]]))

    assert.same(regions[2], assert(linker.flash_region(regions)))
  end)

  it("reports missing and ambiguous FLASH regions", function()
    local region, missing = linker.flash_region({
      { name = "ROM", attributes = "rx", origin = 0x08000000, length = 1024 },
    })
    assert.is_nil(region)
    assert.equals("linker-flash-missing", missing.code)

    region, missing = linker.flash_region({
      { name = "FLASH", attributes = "rx", origin = 0x08000000, length = 1024 },
      { name = "flash", attributes = "rx", origin = 0x08100000, length = 1024 },
    })
    assert.is_nil(region)
    assert.equals("linker-flash-ambiguous", missing.code)
  end)
end)
