local size = require("nvim-stm32.inspect.size")

local function fixture(rel)
  local here =
    vim.fn.fnamemodify(vim.fn.resolve(debug.getinfo(1, "S").source:sub(2)), ":p:h")
  return table.concat(vim.fn.readfile(here .. "/fixtures/" .. rel), "\n")
end

describe("nvim-stm32 GNU size parsing", function()
  it("reads the literal Berkeley text, data, and bss values", function()
    local summary = assert(size.parse(fixture("f429_size.txt")))

    assert.same({ text = 0x4cbc, data = 0x68, bss = 0xed8 }, summary)
  end)

  it("accepts decimal Berkeley values", function()
    local summary = assert(size.parse([[
      text data bss dec hex filename
      19644 104 3800 23548 5bfc dt.elf
    ]]))

    assert.same({ text = 19644, data = 104, bss = 3800 }, summary)
  end)

  it("returns a structured error for malformed output", function()
    local summary, err = size.parse("arm-none-eabi-size: file format not recognized")

    assert.is_nil(summary)
    assert.equals("size-output-invalid", err.code)
  end)
end)
