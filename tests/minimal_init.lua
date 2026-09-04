-- Minimal init for headless plenary-busted runs.
--
-- Puts this plugin on the runtimepath and locates plenary via $PLENARY_PATH
-- (set by scripts/test.sh and CI) or the standard lazy.nvim data dir.
local here =
  vim.fn.fnamemodify(vim.fn.resolve(debug.getinfo(1, "S").source:sub(2)), ":p:h")
local root = vim.fn.fnamemodify(here, ":h")

vim.opt.runtimepath:prepend(root)

local function add(path)
  if path ~= "" and vim.fn.isdirectory(path) == 1 then
    vim.opt.runtimepath:append(path)
    return true
  end
  return false
end

local plenary = vim.env.PLENARY_PATH or ""
if not add(plenary) then
  add(vim.fn.stdpath("data") .. "/lazy/plenary.nvim")
end

vim.cmd("runtime plugin/plenary.vim")
require("plenary.busted")
