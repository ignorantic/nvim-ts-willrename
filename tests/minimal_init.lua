local root = vim.fn.getcwd()
vim.opt.runtimepath:append(root)
package.path = table.concat({
  root .. "/lua/?.lua",
  root .. "/lua/?/init.lua",
  package.path,
}, ";")

local plenary = root .. "/tests/plenary"
if vim.fn.isdirectory(plenary) == 1 then
  vim.opt.runtimepath:append(plenary)
end

vim.cmd("filetype off | syntax off")

