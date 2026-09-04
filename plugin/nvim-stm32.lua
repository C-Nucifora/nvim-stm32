-- Register commands that work without setup().
if vim.g.loaded_nvim_stm32 then
  return
end
vim.g.loaded_nvim_stm32 = true

vim.api.nvim_create_user_command("STM32Info", function()
  require("nvim-stm32.ui.info").show()
end, { desc = "nvim-stm32: show the detected project and chip" })

vim.api.nvim_create_user_command("STM32Build", function()
  require("nvim-stm32.backend.build").current()
end, { desc = "nvim-stm32: configure and build the current firmware" })
