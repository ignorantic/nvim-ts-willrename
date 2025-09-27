-- Put the plugin under test on runtimepath
vim.opt.runtimepath:prepend(vim.fn.fnamemodify(".", ":p"))

-- Add plenary to runtimepath (fetch if missing)
local lazypath = vim.fn.stdpath("data") .. "/lazy/plenary.nvim"
if not vim.loop.fs_stat(lazypath) then
  vim.fn.system({ "git", "clone", "https://github.com/nvim-lua/plenary.nvim", lazypath })
end
vim.opt.runtimepath:append(lazypath)

-- Make vim.notify visible in headless mode
vim.notify = function(msg, level)
  local lvl = ({ [vim.log.levels.ERROR]="ERROR", [vim.log.levels.WARN]="WARN", [vim.log.levels.INFO]="INFO" })[level] or "INFO"
  print(("NOTIFY[%s] %s"):format(lvl, msg))
end

