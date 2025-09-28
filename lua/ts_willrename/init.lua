-- Public API: rename(), rename_paths(), rename_for_path(), setup()
local Config = require("ts_willrename.config")
local cfg    = Config.get
local path   = require("ts_willrename.util.path")
local lspu   = require("ts_willrename.util.lsp")
local filter = require("ts_willrename.edit.filter").filter_edit
local save   = require("ts_willrename.save").autosave_and_cleanup
local apply_silent =
  require("ts_willrename.lsp_apply_silent").apply_workspace_edit_silent

local M = {}

-- Collect URIs from WorkspaceEdit (for non-silent applier)
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

---Internal: willRename → apply edits → callback(touched)
local function will_rename(old_abs, new_abs, done)
  lspu.preload_plugins()

  old_abs = path.norm_path(path.realpath(old_abs) or old_abs)
  new_abs = path.norm_path(path.realpath(new_abs) or new_abs)

  lspu.ensure_buf_loaded_for_path(old_abs)
  lspu.wait_clients_for_path(old_abs, 800)

  local params = {
    files = { { oldUri = vim.uri_from_fname(old_abs), newUri = vim.uri_from_fname(new_abs) } }
  }

  local touched, any, pending = {}, false, 0
  local clients = lspu.clients_for_path(old_abs)
  if #clients == 0 then clients = vim.lsp.get_clients() or {} end

  if #clients == 0 then
    Config.log("No LSP clients available")
    return done(false, touched)
  end

  for _, c in ipairs(clients) do
    if c.supports_method and c:supports_method("workspace/willRenameFiles") then
      any, pending = true, pending + 1
      c.request("workspace/willRenameFiles", params, function(_err, res)
        Config.dlog("WR from", c.name, "hasEdits:", res and "yes" or "no")

        res = filter(res)

        if res then
          local cfgv = cfg()
          if cfgv.silent_apply then
            local bufs = apply_silent(res, cfgv.encoding)
            vim.list_extend(touched, bufs)
          else
            for _, uri in ipairs(uris_from_edit(res)) do
              table.insert(touched, vim.uri_to_bufnr(uri))
            end
            vim.lsp.util.apply_workspace_edit(res, cfgv.encoding)
          end
        end

        pending = pending - 1
        if pending == 0 then done(true, touched) end
      end)
    end
  end

  if not any then
    Config.log("No client handled workspace/willRenameFiles")
    done(false, touched)
  end
end

-- ── Public API ─────────────────────────────────────────

function M.setup(user)
  Config.setup(user)
end

---Interactive rename for current buffer.
function M.rename()
  local old = vim.api.nvim_buf_get_name(0)
  if old == "" then Config.log("Open a TS/JS file first"); return end

  local function prompt(cb)
    if vim.ui and vim.ui.input then
      vim.ui.input({ prompt = "New path: ", default = old }, cb)
    else
      cb(vim.fn.input("New path: ", old))
    end
  end

  prompt(function(new)
    if not new or new == "" then return end

    local old_abs = path.norm_path(old)
    local new_abs = new

    local st = vim.loop.fs_stat(new_abs)
    if (st and st.type == "directory") or new_abs:match("[/\\]$") then
      new_abs = path.join(new_abs, vim.fn.fnamemodify(old_abs, ":t"))
    end
    new_abs = path.norm_path(new_abs)
    if new_abs == old_abs then return end

    if not lspu.guard_root(old_abs, new_abs) then return end

    will_rename(old_abs, new_abs, function(had_handler, touched)
      local cur = vim.api.nvim_get_current_buf()
      local cur_abs = path.norm_path(vim.api.nvim_buf_get_name(cur))

      if cur_abs == old_abs then
        vim.fn.mkdir(vim.fn.fnamemodify(new_abs, ":h"), "p")
        vim.cmd("keepalt file " .. vim.fn.fnameescape(new_abs))
        vim.cmd("noautocmd silent write!")
        if old_abs ~= new_abs and vim.loop.fs_stat(old_abs) then pcall(vim.fn.delete, old_abs) end

        local cfgv = cfg()
        if cfgv.notify_did_rename and had_handler then
          local files = { { oldUri = vim.uri_from_fname(old_abs), newUri = vim.uri_from_fname(new_abs) } }
          for _, cl in ipairs(vim.lsp.get_clients({ bufnr = cur })) do
            if cl.supports_method and cl:supports_method("workspace/didRenameFiles") then
              cl.notify("workspace/didRenameFiles", { files = files })
            end
          end
        end

        save(touched)
        Config.log("RENAMED:", "true", "→", new_abs)
      else
        vim.fn.mkdir(vim.fn.fnamemodify(new_abs, ":h"), "p")
        local ok = (vim.fn.rename(old_abs, new_abs) == 0)
        if ok then vim.cmd("edit " .. vim.fn.fnameescape(new_abs)) end
        save(touched)
        Config.log("RENAMED:", ok and "true" or "false", "→", new_abs)
      end
    end)
  end)
end

---Non-interactive rename by absolute paths (for integrations).
function M.rename_paths(old_abs, new_abs)
  old_abs, new_abs = (old_abs or ""), (new_abs or "")
  old_abs, new_abs = old_abs ~= "" and old_abs or vim.api.nvim_buf_get_name(0), new_abs
  if old_abs == "" or new_abs == "" then return end

  old_abs, new_abs = path.norm_path(old_abs), path.norm_path(new_abs)
  if new_abs == old_abs then return end

  will_rename(old_abs, new_abs, function(had_handler, touched)
    vim.fn.mkdir(vim.fn.fnamemodify(new_abs, ":h"), "p")
    local ok = (vim.fn.rename(old_abs, new_abs) == 0)

    local cfgv = cfg()
    if cfgv.notify_did_rename and had_handler then
      local files = { { oldUri = vim.uri_from_fname(old_abs), newUri = vim.uri_from_fname(new_abs) } }
      for _, cl in ipairs(vim.lsp.get_clients()) do
        if cl.supports_method and cl:supports_method("workspace/didRenameFiles") then
          cl.notify("workspace/didRenameFiles", { files = files })
        end
      end
    end

    save(touched)
    Config.log("RENAMED:", ok and "true" or "false", "→", new_abs)
  end)
end

---Interactive rename seeded with a specific path (used by nvim-tree).
function M.rename_for_path(seed_path)
  local old = path.norm_path(seed_path or "")
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
      new_abs = path.join(new_abs, vim.fn.fnamemodify(old, ":t"))
    end
    new_abs = path.norm_path(new_abs)
    if new_abs == old then return end
    M.rename_paths(old, new_abs)
  end)
end

return M

