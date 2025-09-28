local cfg  = require("ts_willrename.config").get
local path = require("ts_willrename.util.path")

local M = {}

local function is_ignored_path(p)
  p = path.norm_path(p or "")
  for _, rule in ipairs(cfg().ignore or {}) do
    if type(rule) == "string" then
      if p:find(rule, 1, true) then return true end
    elseif type(rule) == "function" then
      local ok, res = pcall(rule, p)
      if ok and res then return true end
    end
  end
  return false
end

---Drop all edits that target ignored paths.
---@param edit lsp.WorkspaceEdit|nil
---@return lsp.WorkspaceEdit|nil
function M.filter_edit(edit)
  if not edit then return edit end

  if edit.changes then
    for uri in pairs(edit.changes) do
      if is_ignored_path(path.uri_path(uri)) then
        edit.changes[uri] = nil
      end
    end
  end

  if edit.documentChanges then
    edit.documentChanges = vim.tbl_filter(function(dc)
      local uri = dc.textDocument and (dc.textDocument.uri or dc.textDocument)
      return uri and not is_ignored_path(path.uri_path(uri))
    end, edit.documentChanges)
    if #edit.documentChanges == 0 then
      edit.documentChanges = nil
    end
  end

  return edit
end

return M

