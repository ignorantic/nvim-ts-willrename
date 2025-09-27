local M = {}

function M.tmpdir(prefix)
  prefix = prefix or "wr-"
  local base = vim.loop.os_tmpdir():gsub("\\","/")
  local path = vim.loop.fs_mkdtemp(base .. "/" .. prefix .. "XXXXXX")
  assert(path, "failed to create tmp dir")
  return path:gsub("\\","/")
end

function M.write(path, lines)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  vim.fn.writefile(lines, path)
end

function M.read(path)
  local ok, data = pcall(vim.fn.readfile, path)
  return ok and data or {}
end

function M.join(a,b)
  if a:sub(-1) == "/" then return a .. b end
  return a .. "/" .. b
end

return M

