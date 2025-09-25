-- Defines the :TSWillRename user command
if vim.fn.has("nvim-0.8") == 0 then
  vim.notify("ts_willrename: Neovim >= 0.8 required", vim.log.levels.WARN)
  return
end

vim.api.nvim_create_user_command("TSWillRename", function()
  require("ts_willrename").rename()
end, { desc = "TS/JS: willRename (fix imports) + in-place file rename" })

