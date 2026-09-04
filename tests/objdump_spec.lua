local objdump = require("nvim-stm32.inspect.objdump")

local function fixture(rel)
  local here =
    vim.fn.fnamemodify(vim.fn.resolve(debug.getinfo(1, "S").source:sub(2)), ":p:h")
  return table.concat(vim.fn.readfile(here .. "/fixtures/" .. rel), "\n")
end

local regions = {
  { name = "RAM", attributes = "xrw", origin = 0x20000000, length = 192 * 1024 },
  { name = "CCMRAM", attributes = "xrw", origin = 0x10000000, length = 64 * 1024 },
  { name = "FLASH", attributes = "rx", origin = 0x08000000, length = 2048 * 1024 },
}

describe("nvim-stm32 GNU objdump section parsing", function()
  it("reads every section field and its flags", function()
    local sections =
      assert(objdump.parse_sections(fixture("f429_objdump_sections.txt")))

    assert.equals(12, #sections)
    assert.same({
      index = 0,
      name = ".isr_vector",
      size = 0x1ac,
      vma = 0x08000000,
      lma = 0x08000000,
      file_offset = 0x1000,
      alignment = 1,
      flags = { "CONTENTS", "ALLOC", "LOAD", "READONLY", "DATA" },
    }, sections[1])
    assert.same({
      index = 7,
      name = ".data",
      size = 0x68,
      vma = 0x20000000,
      lma = 0x08004cc0,
      file_offset = 0x6000,
      alignment = 4,
      flags = { "CONTENTS", "ALLOC", "LOAD", "DATA" },
    }, sections[8])
    assert.same({
      index = 8,
      name = ".bss",
      size = 0x8d4,
      vma = 0x20000068,
      lma = 0x08004d28,
      file_offset = 0x6068,
      alignment = 4,
      flags = { "ALLOC" },
    }, sections[9])
    assert.same({
      index = 11,
      name = ".debug_info",
      size = 0xedc7,
      vma = 0,
      lma = 0,
      file_offset = 0x60dd,
      alignment = 1,
      flags = { "CONTENTS", "READONLY", "DEBUGGING", "OCTETS" },
    }, sections[12])
  end)

  it("accounts for occupied load and runtime bytes by region", function()
    local sections =
      assert(objdump.parse_sections(fixture("f429_objdump_sections.txt")))
    local report = assert(objdump.report(sections, regions))

    assert.equals(0x4d24, report.totals.flash)
    assert.equals(0xf40, report.totals.ram)
    assert.same(
      { 0xf40, 0, 0x4d24 },
      vim.tbl_map(function(region)
        return region.used
      end, report.regions)
    )
  end)

  it("keeps debug and unassigned sections visible but out of totals", function()
    local sections =
      assert(objdump.parse_sections(fixture("f429_objdump_sections.txt")))
    sections[#sections + 1] = {
      index = 12,
      name = ".external",
      size = 0x20,
      vma = 0x60000000,
      lma = 0x60000000,
      file_offset = 0x20000,
      alignment = 4,
      flags = { "CONTENTS", "ALLOC", "LOAD", "DATA" },
    }
    local report = assert(objdump.report(sections, regions))

    assert.equals(0x4d24, report.totals.flash)
    assert.equals(0xf40, report.totals.ram)
    assert.is_true(report.sections[12].debug)
    assert.is_false(report.sections[12].counted)
    assert.is_true(report.sections[13].unassigned)
    assert.is_false(report.sections[13].counted)
  end)

  it("keeps a non-allocated loaded section out of flash totals", function()
    local report = assert(objdump.report({
      {
        index = 0,
        name = ".metadata",
        size = 0x20,
        vma = 0,
        lma = 0x08000000,
        file_offset = 0x1000,
        alignment = 4,
        flags = { "CONTENTS", "LOAD", "READONLY" },
      },
    }, regions))

    assert.equals(0, report.totals.flash)
    assert.equals(0, report.totals.ram)
    assert.equals(".metadata", report.sections[1].name)
    assert.is_false(report.sections[1].counted)
  end)

  it("rejects a section that extends beyond its matched region", function()
    local report, err = objdump.report({
      {
        index = 0,
        name = ".overflow",
        size = 0x20,
        vma = 0x080ffff0,
        lma = 0x080ffff0,
        file_offset = 0,
        alignment = 4,
        flags = { "CONTENTS", "ALLOC", "LOAD" },
      },
    }, {
      { name = "FLASH", attributes = "rx", origin = 0x08000000, length = 1024 * 1024 },
    })

    assert.is_nil(report)
    assert.equals("objdump-section-overflow", err.code)
  end)

  it("returns a structured error for malformed output", function()
    local sections, err = objdump.parse_sections("Sections:\nIdx Name Size VMA LMA")

    assert.is_nil(sections)
    assert.equals("objdump-output-invalid", err.code)
  end)
end)
