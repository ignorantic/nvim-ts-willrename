local M = {}

function M.is_windows()
  return vim.loop.os_uname().sysname:match("Windows")
end

---Normalize to absolute, forward slashes, no trailing slash; lowercase on Windows.
function M.norm_path(p)
  if not p or p == "" then return p end
  p = vim.fn.fnamemodify(p, ":p")
  p = p:gsub("\\", "/"):gsub("/+$", "")
  if M.is_windows() then p = p:lower() end
  return p
end

function M.join(a, b)
  if a:sub(-1) == "/" then return a .. b end
  return a .. "/" .. b
end

function M.uri_path(uri)
  return M.norm_path(vim.uri_to_fname(uri))
end

function M.startswith(s, prefix)
  if vim.startswith then return vim.startswith(s, prefix) end
  return type(s) == "string" and s:sub(1, #prefix) == prefix
end

function M.realpath(p)
  local r = p and vim.loop.fs_realpath(p) or nil
  return r or p
end

return M

