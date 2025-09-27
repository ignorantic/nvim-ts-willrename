-- tests/minimal_init.lua
vim.opt.runtimepath:prepend(vim.fn.fnamemodify(".", ":p"))  -- текущий репо в rtp
-- Подключаем plenary
local lazypath = vim.fn.stdpath("data") .. "/lazy/plenary.nvim"
if not vim.loop.fs_stat(lazypath) then
  vim.fn.system({ "git", "clone", "https://github.com/nvim-lua/plenary.nvim", lazypath })
end
vim.opt.runtimepath:append(lazypath)
-- Загружаем твой плагин (plugin/*.lua автоисполнится)

