local nvim_stm32 = require("nvim-stm32")
local probes = require("nvim-stm32.probes")
local project_discovery = require("nvim-stm32.discover.project")
local session = require("nvim-stm32.session")

-- PlenaryBustedFile starts a child with --noplugin, so load the lazy command
-- shim as a normal Neovim startup would.
vim.cmd("runtime plugin/nvim-stm32.lua")

local project = { root = "/firmware", id = "/firmware" }
local listed = {
  {
    backend = "cubeprogrammer",
    serial = "003F002A3138510E34383839",
    firmware = "V3J15M7",
    provenance = {},
  },
  {
    backend = "cubeprogrammer",
    serial = "066DFF515450657867190941",
    firmware = "V2J45S7",
    provenance = {},
  },
}

describe("nvim-stm32 probe selector", function()
  local ui
  local original_enumerate
  local original_select
  local original_resolve
  local original_setup
  local picker_items
  local picker_opts
  local picker_callback

  before_each(function()
    package.loaded["nvim-stm32.ui.probes"] = nil
    ui = require("nvim-stm32.ui.probes")
    session.clear()
    nvim_stm32.config = nil
    original_enumerate = probes.enumerate
    original_select = vim.ui.select
    original_resolve = project_discovery.resolve
    original_setup = nvim_stm32.setup

    probes.enumerate = function(_, callback)
      callback(vim.deepcopy(listed), nil)
      return { id = 41 }
    end
    vim.ui.select = function(items, opts, callback)
      picker_items = items
      picker_opts = opts
      picker_callback = callback
    end
  end)

  after_each(function()
    probes.enumerate = original_enumerate
    vim.ui.select = original_select
    project_discovery.resolve = original_resolve
    nvim_stm32.setup = original_setup
    nvim_stm32.config = nil
    session.clear()
    package.loaded["nvim-stm32.ui.probes"] = nil
  end)

  it("lists serial and firmware labels and saves the chosen serial", function()
    local chosen
    local handle = ui.select({ project = project }, function(probe_value)
      chosen = probe_value
    end)

    assert.equals(41, handle.id)
    assert.same({
      "003F002A3138510E34383839 (V3J15M7)",
      "066DFF515450657867190941 (V2J45S7)",
    }, picker_items)
    assert.matches("STM32 probe", picker_opts.prompt, 1, true)

    picker_callback(picker_items[2], 2)

    assert.equals("066DFF515450657867190941", session.get(project).probe_serial)
    assert.equals("066DFF515450657867190941", chosen.serial)
  end)

  it("does not change the session when the picker is cancelled", function()
    session.select(project, { probe_serial = "EXISTING" })
    ui.select({ project = project })

    picker_callback(nil, nil)

    assert.equals("EXISTING", session.get(project).probe_serial)
  end)

  it("registers a lazy command that works without setup", function()
    local setup_called = false
    nvim_stm32.setup = function()
      setup_called = true
      error("setup must not run")
    end
    project_discovery.resolve = function()
      return project
    end

    assert.equals(2, vim.fn.exists(":STM32SelectProbe"))
    vim.cmd("STM32SelectProbe")

    assert.is_false(setup_called)
    assert.is_nil(nvim_stm32.config)
    picker_callback(picker_items[1], 1)
    assert.equals("003F002A3138510E34383839", session.get(project).probe_serial)
  end)

  it("exposes probe selection through the public module", function()
    assert.is_function(nvim_stm32.select_probe)
  end)
end)
