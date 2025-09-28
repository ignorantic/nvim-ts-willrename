-- lua/ts_willrename/init.lua
-- TypeScript/JavaScript–aware file rename for Neovim.
-- 1) Ask LSP (workspace/willRenameFiles) before FS rename
-- 2) Apply returned edits (silently by default)
-- 3) Rename on disk and optionally send didRename
-- 4) Autosave touched buffers
--
-- Public API:
--   :TSWillRename                         -- interactive for current buffer
--   require("ts_willrename").rename()     -- same as command
--   require("ts_willrename").rename_paths(old_abs, new_abs)
--   require("ts_willrename").rename_for_path(abs_path)

local apply_silent =
  require("ts_willrename.lsp_apply_silent").apply_workspace_edit_silent

local M = {}

---@class TSWillRenameOpts
---@field silent_apply boolean            -- apply edits without opening windows
---@field autosave boolean                -- write modified buffers after edits
---@field wipe_unlisted boolean           -- wipe temp unlisted buffers when clean
---@field notify_did_rename boolean       -- send workspace/didRenameFiles if supported
---@field respect_root boolean|string     -- true|"warn"|"error"|false (guard FS target by LSP root)
---@field encoding '"utf-16"'|'"utf-8"'   -- LSP edit encoding
---@field ignore (string|fun(path:string):boolean)[]  -- paths to ignore when applying edits
---@field debug boolean                   -- verbose messages to :messages

---@type TSWillRenameOpts
local cfg = {
  silent_apply      = true,
  autosave          = false,
  wipe_unlisted     = false,
  notify_did_rename = true,
  respect_root      = "warn",
  encoding          = "utf-16",
  ignore            = {},   -- e.g. { "/types/", "/dist/" }
  debug             = false,
}

-- ── utils ──────────────────────────────────────────────────────────────────

local function log(...)
  vim.notify(table.concat(vim.tbl_map(function(x)
    return type(x) == "table" and vim.inspect(x) or tostring(x)
  end, {...}), " "), vim.log.levels.INFO)
end

local function dlog(...)
  if cfg.debug then log(...) end
end

local function is_windows()
  return vim.loop.os_uname().sysname:match("Windows")
end

---Normalize path:
--- - absolute
--- - forward slashes
--- - trim trailing slash
--- - lower case on Windows (case-insensitive FS)
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

local function uri_path(uri)
  return norm_path(vim.uri_to_fname(uri))
end

---Portable starts_with (Neovim 0.9 compatibility)
local function starts_with(s, prefix)
  if vim.startswith then return vim.startswith(s, prefix) end
  return type(s) == "string" and s:sub(1, #prefix) == prefix
end

---Real path (fix symlinks / case on Windows) if available
local function realpath(p)
  local r = p and vim.loop.fs_realpath(p) or nil
  return r or p
end

---Ignore rules: plain substring or predicate(path)->boolean
local function is_ignored_path(p)
  p = norm_path(p or "")
  for _, rule in ipairs(cfg.ignore or {}) do
    if type(rule) == "string" then
      if p:find(rule, 1, true) then return true end
    elseif type(rule) == "function" then
      local ok, res = pcall(rule, p)
      if ok and res then return true end
    end
  end
  return false
end

---Collect URIs from a WorkspaceEdit (for non-silent applier)
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

---Pick LSP clients whose root_dir covers the given absolute path
local function clients_for_path(abs_path)
  abs_path = norm_path(abs_path or "")
  if abs_path == "" then return {} end
  local out = {}
  for _, c in ipairs(vim.lsp.get_clients() or {}) do
    local root = c.config and c.config.root_dir and norm_path(c.config.root_dir) or nil
    if root and starts_with(abs_path, root) then
      table.insert(out, c)
    end
  end
  return out
end

---Ensure a file is loaded in a hidden buffer so tsserver can "see" it
local function ensure_buf_loaded_for_path(abs_path)
  local bufnr = vim.fn.bufadd(abs_path)
  vim.fn.bufload(bufnr)
  pcall(vim.api.nvim_buf_set_option, bufnr, "buflisted", false)
  if vim.bo[bufnr].filetype == "" then
    local ft = vim.filetype.match({ filename = abs_path }) or ""
    if ft ~= "" then
      vim.bo[bufnr].filetype = ft
      vim.api.nvim_exec_autocmds("FileType", { buffer = bufnr })
    end
  end
  return bufnr
end

---Optionally wait for a client covering this path to attach (up to timeout_ms)
local function wait_clients_for_path(abs_path, timeout_ms)
  timeout_ms = timeout_ms or 800
  return vim.wait(timeout_ms, function()
    return #clients_for_path(abs_path) > 0
  end, 50)
end

---Lazy-load dependencies when invoked from non-TS buffers (e.g. nvim-tree)
local function preload_plugins()
  if package.loaded["lazy"] then
    pcall(require("lazy").load, { plugins = {
      "nvim-ts-willrename",
      "typescript-tools.nvim",
      "nvim-lsp-file-operations",
    }})
  end
end

---Remove edits targeting ignored paths
---@param edit lsp.WorkspaceEdit|nil
---@return lsp.WorkspaceEdit|nil
local function filter_edit(edit)
  if not edit then return edit end

  if edit.changes then
    for uri in pairs(edit.changes) do
      if is_ignored_path(uri_path(uri)) then
        edit.changes[uri] = nil
      end
    end
  end

  if edit.documentChanges then
    edit.documentChanges = vim.tbl_filter(function(dc)
      local uri = dc.textDocument and (dc.textDocument.uri or dc.textDocument)
      return uri and not is_ignored_path(uri_path(uri))
    end, edit.documentChanges)
    if #edit.documentChanges == 0 then
      edit.documentChanges = nil
    end
  end

  return edit
end

-- ── autosave helpers ────────────────────────────────────────────────────────

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

  -- fallback: writefile() if some plugin blocked :write from clearing 'modified'
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
      if cfg.autosave
        and vim.bo[buf].modified
        and not vim.bo[buf].readonly
        and vim.bo[buf].modifiable
        and not is_ignored_path(vim.api.nvim_buf_get_name(buf))
      then
        write_buf_force(buf)
      end
      if cfg.wipe_unlisted and not vim.bo[buf].buflisted and not vim.bo[buf].modified then
        pcall(vim.api.nvim_buf_delete, buf, { force = false })
      end
    end
  end
end

-- ── core flow ───────────────────────────────────────────────────────────────

---Internal: run willRename → apply edits → callback with touched buffers
---@param old_abs string
---@param new_abs string
---@param done fun(had_handler:boolean, touched:integer[])
local function will_rename(old_abs, new_abs, done)
  preload_plugins()

  -- normalize & ensure LSP sees the file
  old_abs = norm_path(realpath(old_abs) or old_abs)
  new_abs = norm_path(realpath(new_abs) or new_abs)
  ensure_buf_loaded_for_path(old_abs)
  wait_clients_for_path(old_abs, 800)

  local params = {
    files = { { oldUri = vim.uri_from_fname(old_abs), newUri = vim.uri_from_fname(new_abs) } }
  }

  local touched, any, pending = {}, false, 0
  local clients = clients_for_path(old_abs)
  if #clients == 0 then clients = vim.lsp.get_clients() or {} end

  if #clients == 0 then
    log("No LSP clients available")
    return done(false, touched)
  end

  for _, c in ipairs(clients) do
    if c.supports_method and c:supports_method("workspace/willRenameFiles") then
      any, pending = true, pending + 1
      c.request("workspace/willRenameFiles", params, function(_err, res)
        dlog("WR from", c.name, "hasEdits:", res and "yes" or "no")

        res = filter_edit(res)  -- drop edits for ignored paths

        if res then
          if cfg.silent_apply then
            local bufs = apply_silent(res, cfg.encoding)
            vim.list_extend(touched, bufs)
          else
            for _, uri in ipairs(uris_from_edit(res)) do
              if not is_ignored_path(uri_path(uri)) then
                table.insert(touched, vim.uri_to_bufnr(uri))
              end
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

-- ── public API ──────────────────────────────────────────────────────────────

---Configure plugin options
---@param user TSWillRenameOpts|nil
function M.setup(user)
  cfg = vim.tbl_deep_extend("force", cfg, user or {})
end

---Interactive rename for the current buffer (prompts for path)
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
      local rel = clients_for_path(old_abs)[1]
      local root = rel and rel.config and rel.config.root_dir and norm_path(rel.config.root_dir) or nil
      if root and not starts_with(new_abs, root) then
        local msg = ("New path is outside LSP root: %s"):format(root)
        vim.schedule(function()
          vim.notify(msg, cfg.respect_root == "error" and vim.log.levels.ERROR or vim.log.levels.WARN)
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

---Non-interactive rename with absolute paths (used by integrations)
---@param old_abs string
---@param new_abs string
function M.rename_paths(old_abs, new_abs)
  old_abs, new_abs = (old_abs or ""), (new_abs or "")
  old_abs, new_abs = old_abs ~= "" and old_abs or vim.api.nvim_buf_get_name(0), new_abs
  if old_abs == "" or new_abs == "" then return end

  old_abs, new_abs = norm_path(old_abs), norm_path(new_abs)
  if new_abs == old_abs then return end

  will_rename(old_abs, new_abs, function(had_handler, touched)
    -- no in-place buffer switch here: we’re renaming from tree, not current buf
    vim.fn.mkdir(vim.fn.fnamemodify(new_abs, ":h"), "p")
    local ok = (vim.fn.rename(old_abs, new_abs) == 0)

    if cfg.notify_did_rename and had_handler then
      local files = { { oldUri = vim.uri_from_fname(old_abs), newUri = vim.uri_from_fname(new_abs) } }
      for _, cl in ipairs(vim.lsp.get_clients()) do
        if cl.supports_method and cl:supports_method("workspace/didRenameFiles") then
          cl.notify("workspace/didRenameFiles", { files = files })
        end
      end
    end

    autosave_and_cleanup(touched)
    log("RENAMED:", ok and "true" or "false", "→", new_abs)
  end)
end

---Interactive rename seeded with an arbitrary file path (used by nvim-tree)
---@param seed_path string absolute path of the selected file
function M.rename_for_path(seed_path)
  local old = norm_path(seed_path or "")
  if old == "" then return end

  local function prompt(cb)
    if vim.ui and vim.ui.input then
      vim.ui.input({ prompt = "New path: ", default = old }, cb)
    else
      cb(vim.fn.input("New path: ", old))
    end
  end

  prompt(function(new)
    if not new or new == "" then return end
    local new_abs = new
    local st = vim.loop.fs_stat(new_abs)
    if (st and st.type == "directory") or new_abs:match("[/\\]$") then
      new_abs = join(new_abs, vim.fn.fnamemodify(old, ":t"))
    end
    new_abs = norm_path(new_abs)
    if new_abs == old then return end
    M.rename_paths(old, new_abs)
  end)
end

return M

