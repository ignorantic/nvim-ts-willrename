-- Apply LSP WorkspaceEdit without opening windows or listing buffers
local M = {}

local function apply_edits_for_uri(uri, edits, enc)
  enc = enc or "utf-16"
  local buf = vim.uri_to_bufnr(uri)                    -- load buffer (no window)
  pcall(vim.api.nvim_buf_set_option, buf, "buflisted", false)

  vim.api.nvim_buf_call(buf, function()
    local prev = vim.o.eventignore
    vim.o.eventignore = table.concat({
      "BufAdd","BufEnter","BufWinEnter","BufReadPost","BufNewFile"
    }, ",")
    pcall(vim.lsp.util.apply_text_edits, edits, buf, enc)
    vim.o.eventignore = prev
  end)

  vim.bo[buf].modified = true
  return buf
end

---Apply WorkspaceEdit silently. Returns list of touched buffer ids.
---@param edit table
---@param enc? string '"utf-16"'|'"utf-8"'
---@return integer[] bufs
function M.apply_workspace_edit_silent(edit, enc)
  enc = enc or "utf-16"
  local touched = {}

  if edit and edit.changes then
    for uri, edits in pairs(edit.changes) do
      table.insert(touched, apply_edits_for_uri(uri, edits, enc))
    end
  end

  if edit and edit.documentChanges then
    for _, dc in ipairs(edit.documentChanges) do
      if dc.textDocument and dc.edits then
        local uri = dc.textDocument.uri or dc.textDocument
        table.insert(touched, apply_edits_for_uri(uri, dc.edits, enc))
      end
      -- create/delete/rename handled by the caller
    end
  end

  return touched
end

return M

