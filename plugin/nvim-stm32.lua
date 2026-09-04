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

vim.api.nvim_create_user_command("STM32Clean", function()
  require("nvim-stm32.operations.build").current({ mode = "clean" })
end, { desc = "nvim-stm32: clean the current firmware" })

vim.api.nvim_create_user_command("STM32Rebuild", function()
  require("nvim-stm32.operations.build").current({ mode = "rebuild" })
end, { desc = "nvim-stm32: clean and rebuild the current firmware" })

vim.api.nvim_create_user_command("STM32Analyze", function()
  require("nvim-stm32.operations.analyze").current()
end, { desc = "nvim-stm32: analyze memory use for the current firmware" })

vim.api.nvim_create_user_command("STM32Plan", function(args)
  require("nvim-stm32.ui.plan").current(args.args ~= "" and args.args or "build")
end, {
  nargs = "?",
  complete = function()
    return { "build", "clean", "rebuild", "analyze" }
  end,
  desc = "nvim-stm32: preview an operation plan",
})

vim.api.nvim_create_user_command("STM32SelectConfig", function()
  require("nvim-stm32.operations.build").select_configuration()
end, { desc = "nvim-stm32: select a build configuration" })
