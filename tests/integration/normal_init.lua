local root = assert(vim.env.NVIM_STM32_RPC_REPO, "missing RPC repository root")

vim.opt.runtimepath:prepend(root)
vim.cmd("runtime plugin/nvim-stm32.lua")
