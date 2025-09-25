local apply_silent = require("ts_willrename.lsp_apply_silent").apply_workspace_edit_silent

local M = {}

---@class TSWillRenameOpts
---@field silent_apply boolean
---@field autosave boolean
---@field wipe_unlisted boolean
---@field notify_did_rename boolean
---@field respect_root boolean|string  -- true|"warn"|"error"|false
---@field encoding '"utf-16"'|'"utf-8"'

local cfg = {
  silent_apply      = true,
  autosave          = false,
  wipe_unlisted     = false,
  notify_did_rename = true,
  respect_root      = "warn",   -- "warn" | "error" | true(=warn) | false
  encoding          = "utf-16",
}

local function log(...)
  vim.notify(table.concat(vim.tbl_map(function(x)
    return type(x) == "table" and vim.inspect(x) or tostring(x)
  end, {...}), " "), vim.log.levels.INFO)
end

local function is_windows()
  return vim.loop.os_uname().sysname:match("Windows")
end

local function norm_path(p)
  if not p or p == "" then return p end
  p = vim.fn.fnamemodify(p, ":p")
  p = p:gsub("\\", "/"):gsub("/+$", "")
  if is_windows() then p = p:lower() end
  return p
end

local function join(a, b)
  if a:sub(-1) == "/" then return a .. b end
  return a .. "/" .. b
end

function M.setup(user)
  cfg = vim.tbl_deep_extend("force", cfg, user or {})
end

-- utils to collect URIs from WorkspaceEdit
local function uris_from_edit(edit)
  local uris = {}
  if edit and edit.changes then
    for uri,_ in pairs(edit.changes) do table.insert(uris, uri) end
  end
  if edit and edit.documentChanges then
    for _, dc in ipairs(edit.documentChanges) do
      if dc.textDocument and dc.edits then
        table.insert(uris, dc.textDocument.uri or dc.textDocument)
      end
    end
  end
  return uris
end

-- request willRenameFiles from all clients; apply edits; return touched buffers
local function will_rename(old_abs, new_abs, done)
  local params = { files = { { oldUri = vim.uri_from_fname(old_abs), newUri = vim.uri_from_fname(new_abs) } } }
  local any, pending = false, 0
  local touched = {}

  local clients = vim.lsp.get_clients({ bufnr = 0 })
  if #clients == 0 then
    log("No LSP clients attached to this buffer")
    return done(false, touched)
  end

  for _, c in ipairs(clients) do
    if c.supports_method and c:supports_method("workspace/willRenameFiles") then
      any, pending = true, pending + 1
      c.request("workspace/willRenameFiles", params, function(_err, res)
        if res then
          if cfg.silent_apply then
            local bufs = apply_silent(res, cfg.encoding)
            vim.list_extend(touched, bufs)
          else
            -- builtin apply: open buffers first so we can save later
            for _, uri in ipairs(uris_from_edit(res)) do
              table.insert(touched, vim.uri_to_bufnr(uri))
            end
            vim.lsp.util.apply_workspace_edit(res, cfg.encoding)
          end
        end
        pending = pending - 1
        if pending == 0 then done(true, touched) end
      end)
    end
  end

  if not any then
    log("No client handled workspace/willRenameFiles")
    done(false, touched)
  end
end

-- save helpers
local function uniq(list)
  local out, seen = {}, {}
  for _, v in ipairs(list or {}) do
    if v and not seen[v] then seen[v] = true; table.insert(out, v) end
  end
  return out
end

local function write_buf_force(buf)
  -- try normal :write! first
  vim.api.nvim_buf_call(buf, function()
    vim.cmd("noautocmd silent! keepalt keepjumps write!")
  end)
  if not vim.bo[buf].modified then return true end

  -- fallback: writefile() if some plugin prevented :write from clearing modified
  local name = vim.api.nvim_buf_get_name(buf)
  if name == "" then return false end
  local ok = pcall(vim.fn.writefile, vim.api.nvim_buf_get_lines(buf, 0, -1, true), name)
  if ok then vim.bo[buf].modified = false end
  return ok
end

local function autosave_and_cleanup(touched)
  if not (cfg.autosave or cfg.wipe_unlisted) then return end
  for _, buf in ipairs(uniq(touched)) do
    if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].buftype == "" then
      if cfg.autosave and vim.bo[buf].modified and not vim.bo[buf].readonly and vim.bo[buf].modifiable then
        write_buf_force(buf)
      end
      if cfg.wipe_unlisted and not vim.bo[buf].buflisted and not vim.bo[buf].modified then
        pcall(vim.api.nvim_buf_delete, buf, { force = false })
      end
    end
  end
end

---Interactive rename for the current buffer
function M.rename()
  local old = vim.api.nvim_buf_get_name(0)
  if old == "" then log("Open a TS/JS file first"); return end

  local function prompt(cb)
    if vim.ui and vim.ui.input then
      vim.ui.input({ prompt = "New path: ", default = old }, cb)
    else
      cb(vim.fn.input("New path: ", old))
    end
  end

  prompt(function(new)
    if not new or new == "" then return end

    local old_abs = norm_path(old)
    local new_abs = new

    -- if a directory was typed, append the current filename
    local st = vim.loop.fs_stat(new_abs)
    if (st and st.type == "directory") or new_abs:match("[/\\]$") then
      new_abs = join(new_abs, vim.fn.fnamemodify(old_abs, ":t"))
    end
    new_abs = norm_path(new_abs)
    if new_abs == old_abs then return end

    -- root guard (monorepos)
    if cfg.respect_root and cfg.respect_root ~= false then
      local c = (vim.lsp.get_clients({ bufnr = 0 }) or {})[1]
      local root = c and c.config and c.config.root_dir and norm_path(c.config.root_dir) or nil
      if root and not vim.startswith(new_abs, root) then
        local msg = ("New path is outside LSP root: %s"):format(root)
        vim.schedule(function()
          if cfg.respect_root == "error" then
            vim.notify(msg, vim.log.levels.ERROR)
          else
            vim.notify(msg, vim.log.levels.WARN)
          end
        end)
        if cfg.respect_root == "error" then return end
      end
    end

    will_rename(old_abs, new_abs, function(had_handler, touched)
      -- in-place buffer rename (no extra buffers)
      local cur = vim.api.nvim_get_current_buf()
      local cur_abs = norm_path(vim.api.nvim_buf_get_name(cur))

      if cur_abs == old_abs then
        vim.fn.mkdir(vim.fn.fnamemodify(new_abs, ":h"), "p")
        vim.cmd("keepalt file " .. vim.fn.fnameescape(new_abs))
        vim.cmd("noautocmd silent write!")
        if old_abs ~= new_abs and vim.loop.fs_stat(old_abs) then pcall(vim.fn.delete, old_abs) end

        if cfg.notify_did_rename and had_handler then
          local files = { { oldUri = vim.uri_from_fname(old_abs), newUri = vim.uri_from_fname(new_abs) } }
          for _, cl in ipairs(vim.lsp.get_clients({ bufnr = cur })) do
            if cl.supports_method and cl:supports_method("workspace/didRenameFiles") then
              cl.notify("workspace/didRenameFiles", { files = files })
            end
          end
        end

        autosave_and_cleanup(touched)
        log("RENAMED:", "true", "→", new_abs)
      else
        -- fallback: FS rename + open
        vim.fn.mkdir(vim.fn.fnamemodify(new_abs, ":h"), "p")
        local ok = (vim.fn.rename(old_abs, new_abs) == 0)
        if ok then vim.cmd("edit " .. vim.fn.fnameescape(new_abs)) end
        autosave_and_cleanup(touched)
        log("RENAMED:", ok and "true" or "false", "→", new_abs)
      end
    end)
  end)
end

return M

