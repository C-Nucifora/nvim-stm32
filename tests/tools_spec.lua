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
    vim.fn.mkdir(dir .. "/2.10.0/bin", "p")
    exe = dir .. "/2.23.0/bin/FakeProgrammer"
    -- 2.10.0 sorts first alphabetically ("2.1..." < "2.2..." < "2.9...") but
    -- is not the newest version, so this fixture only resolves to 2.23.0 when
    -- resolve() actually applies the numeric sort rather than trusting glob's
    -- alphabetical order.
    for _, v in ipairs({ "2.23.0", "2.9.0", "2.10.0" }) do
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

  it("falls back to the globs and picks the highest version", function()
    assert.equals(
      exe,
      tools.resolve("FakeProgrammer", nil, { dir .. "/*/bin/FakeProgrammer" })
    )
  end)

  it("returns nil when nothing matches", function()
    assert.is_nil(tools.resolve("DefinitelyNotAToolOnThisBox", nil, { "/nowhere/*/x" }))
  end)
end)

describe("nvim-stm32.tools.resolve tilde expansion", function()
  -- The other resolve() fixtures live under vim.fn.tempname(), which is
  -- under /var/folders and unreachable by any "~" path, so a tilde override
  -- needs its own fixture under the real home directory.
  local suffix, home_dir, home_exe

  before_each(function()
    suffix = tostring(vim.uv.hrtime())
    home_dir = vim.env.HOME .. "/.cache/nvim-stm32-test-" .. suffix
    vim.fn.mkdir(home_dir .. "/bin", "p")
    home_exe = home_dir .. "/bin/FakeProgrammer"
    vim.fn.writefile({ "#!/bin/sh" }, home_exe)
    vim.uv.fs_chmod(home_exe, 493) -- 0755
  end)

  after_each(function()
    vim.fn.delete(home_dir, "rf")
  end)

  it("expands ~ in an override that resolves to a real executable", function()
    local override = "~/.cache/nvim-stm32-test-" .. suffix .. "/bin/FakeProgrammer"
    assert.equals(home_exe, tools.resolve("FakeProgrammer", override, {}))
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
