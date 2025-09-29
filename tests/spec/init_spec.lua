-- Tests for lua/ts_willrename/init.lua (public API)
-- Covered:
--   - setup() forwards options to Config.setup
--   - rename_paths():
--       * issues willRenameFiles to capable clients
--       * applies edits via either silent or standard applier
--       * (when applicable) sends didRenameFiles
--       * calls Config.log("RENAMED:", <true|false>, "→", <new_path>)
--   - rename_paths() fallback paths (no handler; using vim.lsp.get_clients())
--   - rename_for_path() prompts then delegates to rename_paths()
--   - rename() early exits when current buffer has no name

------------------------------------------------------------
-- Preload plugin-internal dependencies (stubs)
------------------------------------------------------------

-- Config stub: mutable defaults, call capture, reset, and structured log capture.
package.preload["ts_willrename.config"] = function()
  local M = {}
  local defaults = {
    silent_apply      = true,
    autosave          = false,
    wipe_unlisted     = false,
    notify_did_rename = true,
    respect_root      = "warn",
    encoding          = "utf-16",
    ignore            = {},
    debug             = false,
  }
  local function copy(t) local r = {}; for k,v in pairs(t) do r[k]=v end; return r end
  local current = copy(defaults)
  local setup_calls = {}
  local log_calls = {}   -- <— structured log calls as { ...args }

  function M.setup(user)
    setup_calls[#setup_calls+1] = user or {}
    for k, v in pairs(user or {}) do current[k] = v end
  end
  function M.get() return current end
  function M._setup_calls() return setup_calls end
  function M._reset()
    for k in pairs(current) do current[k] = nil end
    for k, v in pairs(defaults) do current[k] = v end
    for i = #setup_calls, 1, -1 do setup_calls[i] = nil end
    for i = #log_calls, 1, -1 do log_calls[i] = nil end
  end
  function M._log_calls() return log_calls end

  -- Structured logging (we also mirror to vim._logs.text if present, but tests read _log_calls)
  local function _fmt_args(...)
    local out = {}
    for i,v in ipairs({...}) do out[i] = v end
    return out
  end
  function M.log(...)
    log_calls[#log_calls+1] = _fmt_args(...)
    if vim._logs and vim._logs.add then
      vim._logs.add("log", ...)
    end
  end
  function M.dlog(...)
    if current.debug then M.log(...) end
  end

  return M
end

-- Path utils stub: normalize, realpath passthrough, join.
package.preload["ts_willrename.util.path"] = function()
  local M = {}
  function M.norm_path(p)
    if not p or p == "" then return p or "" end
    return tostring(p):gsub("\\", "/"):gsub("/+$", "")
  end
  function M.realpath(p) return p end
  function M.join(a, b) return (a:sub(-1) == "/") and (a .. b) or (a .. "/" .. b) end
  return M
end

-- LSP utility stub: behavior overridden per test via upvalues.
local lspu_stub = {
  preload_plugins = function() end,
  ensure_buf_loaded_for_path = function(_) end,
  wait_clients_for_path = function(_, _) return true end,
  clients_for_path = function(_) return {} end,
  guard_root = function(_, _) return true end,
}
package.preload["ts_willrename.util.lsp"] = function() return lspu_stub end

-- Filter stub: pass-through.
package.preload["ts_willrename.edit.filter"] = function()
  return { filter_edit = function(e) return e end }
end

-- Save stub: capture calls (not asserted strictly).
local save_calls = {}
package.preload["ts_willrename.save"] = function()
  return {
    autosave_and_cleanup = function(bufs)
      table.insert(save_calls, { bufs = bufs })
    end
  }
end

-- Silent applier stub: capture calls and pretend it touched two buffers.
local silent_apply_calls = {}
package.preload["ts_willrename.lsp_apply_silent"] = function()
  return {
    apply_workspace_edit_silent = function(edit, enc)
      table.insert(silent_apply_calls, { edit = edit, enc = enc })
      return { 201, 202 }
    end
  }
end

------------------------------------------------------------
-- Minimal Vim runtime stubs and utilities
------------------------------------------------------------
vim = vim or {}
vim.api = vim.api or {}
vim.fn  = vim.fn or {}
vim.lsp = vim.lsp or {}
vim.ui  = vim.ui or {}
vim.loop = vim.loop or {}

-- Optional text log collector (not used for assertions)
vim._logs = {
  entries = {},
  add = function(kind, ...)
    local parts = {}
    for i, v in ipairs({...}) do parts[i] = tostring(v) end
    table.insert(vim._logs.entries, { kind = kind, msg = table.concat(parts, " ") })
  end
}

-- URI helpers
vim.uri_from_fname = function(p) return "file://" .. p end
local next_buf = 100
local by_uri = {}
vim.uri_to_bufnr = function(uri)
  if not by_uri[uri] then next_buf = next_buf + 1; by_uri[uri] = next_buf end
  return by_uri[uri]
end

-- list extend
vim.list_extend = function(dst, src)
  for i = 1, #src do dst[#dst + 1] = src[i] end
  return dst
end

-- Registry of LSP clients (used by vim.lsp.get_clients fallback AND for didRenameFiles)
local lsp_clients = {}
vim.lsp.get_clients = function(_) return lsp_clients end

-- Standard (non-silent) workspace edit application
local std_apply_calls = {}
vim.lsp.util = vim.lsp.util or {}
vim.lsp.util.apply_workspace_edit = function(edit, enc)
  table.insert(std_apply_calls, { edit = edit, enc = enc })
end

-- Filesystem + UI + buffer helpers
vim.loop.fs_stat = function(_) return nil end
vim.fn.fnameescape = function(s) return s end
vim.fn.fnamemodify = function(p, mod)
  local s = tostring(p):gsub("\\", "/")
  if mod == ":t" then
    return s:match("([^/]+)$") or s
  elseif mod == ":h" then
    return s:match("^(.*)/[^/]+$") or s
  end
  return p
end
vim.fn.mkdir = function(_, _) return 1 end
vim.fn.rename = function(_, _) return 0 end

-- Current buffer scaffolding for rename()
local current_buf = 1
local buf_names = { [1] = "" }
vim.api.nvim_get_current_buf = function() return current_buf end
vim.api.nvim_buf_get_name = function(bufnr) return buf_names[bufnr] or "" end
vim.cmd = function(_) end
vim.fn.delete = function(_) return 0 end

-- UI input stub (enabled per test when needed)
vim.fn.input = function(_, default) return default end
vim.ui.input = nil

------------------------------------------------------------
-- Module reload helper
------------------------------------------------------------
local function reload()
  package.loaded["ts_willrename.init"] = nil
  return require("ts_willrename.init")
end

------------------------------------------------------------
-- Reset helpers between tests
------------------------------------------------------------
local function reset_captures()
  save_calls = {}
  silent_apply_calls = {}
  std_apply_calls = {}
  vim._logs.entries = {}
  lsp_clients = {}

  -- restore default lsp utils behavior
  lspu_stub.preload_plugins = function() end
  lspu_stub.ensure_buf_loaded_for_path = function(_) end
  lspu_stub.wait_clients_for_path = function(_, _) return true end
  lspu_stub.clients_for_path = function(_) return {} end
  lspu_stub.guard_root = function(_, _) return true end
end

------------------------------------------------------------
-- Specs
------------------------------------------------------------
describe("ts_willrename.init", function()
  before_each(function()
    reset_captures()

    -- Reset config to canonical defaults
    local Config = require("ts_willrename.config")
    Config._reset()
    Config.setup({
      encoding          = "utf-16",
      silent_apply      = true,
      debug             = false,
      autosave          = false,
      notify_did_rename = true,
    })

    -- Ensure fresh dependency modules (defensive)
    package.loaded["ts_willrename.lsp_apply_silent"] = nil
    package.loaded["ts_willrename.edit.filter"] = nil
    package.loaded["ts_willrename.save"] = nil

    -- Reset current buffer identity
    current_buf = 1
    buf_names[1] = ""
  end)

  it("setup() forwards options to Config.setup", function()
    local M = reload()
    M.setup({ autosave = true, debug = true, encoding = "utf-8" })
    local Config = require("ts_willrename.config")
    local calls = Config._setup_calls()
    assert.is_true(#calls >= 1)
    assert.same(true,  calls[#calls].autosave)
    assert.same(true,  calls[#calls].debug)
    assert.same("utf-8", calls[#calls].encoding)
  end)

  it("rename_paths() applies edits, and notifies didRenameFiles", function()
    -- Arrange a capable client; must also be visible to vim.lsp.get_clients() for didRenameFiles
    local did_notifies = {}
    local req_seen = {}
    local client = {
      name = "tsserver",
      config = { root_dir = "/proj" },
      supports_method = function(_, m)
        return m == "workspace/willRenameFiles" or m == "workspace/didRenameFiles"
      end,
      request = function(method, params, cb)
        req_seen[#req_seen+1] = { method = method, params = params }
        cb(nil, {
          changes = {
            ["file:///old.ts"]   = { { range = {}, newText = "x" } },
            ["file:///other.ts"] = { { range = {}, newText = "y" } },
          }
        })
      end,
      -- NOTE: notify is called with dot-call, no implicit self
      notify = function(method, payload)
        table.insert(did_notifies, { method = method, payload = payload })
      end,
    }
    lspu_stub.clients_for_path = function(_) return { client } end
    lsp_clients = { client } -- ensure didRenameFiles is delivered

    local M = reload()
    local old_abs, new_abs = "/old.ts", "/new.ts"

    -- Act
    M.rename_paths(old_abs, new_abs)

    -- Assert request & URIs
    assert.is_true(#req_seen >= 1)
    assert.equals("workspace/willRenameFiles", req_seen[1].method)
    assert.equals("file://"..old_abs, req_seen[1].params.files[1].oldUri)
    assert.equals("file://"..new_abs, req_seen[1].params.files[1].newUri)

    -- Some edit applier must have been called (silent or standard)
    local used = #silent_apply_calls + #std_apply_calls
    assert.is_true(used >= 1)

    -- Encoding must be utf-16 on whichever applier ran
    if #silent_apply_calls > 0 then
      assert.equals("utf-16", silent_apply_calls[1].enc)
    elseif #std_apply_calls > 0 then
      assert.equals("utf-16", std_apply_calls[1].enc)
    end

    -- didRenameFiles notification sent once
    assert.equals(1, #did_notifies)
    assert.equals("workspace/didRenameFiles", did_notifies[1].method)
    assert.equals("file://"..old_abs, did_notifies[1].payload.files[1].oldUri)
    assert.equals("file://"..new_abs, did_notifies[1].payload.files[1].newUri)

    -- Config.log must have been called with a "RENAMED:" record
    local Config = require("ts_willrename.config")
    local logs = Config._log_calls()
    local saw = false
    for _, args in ipairs(logs) do
      if args[1] == "RENAMED:" and (args[2] == true or args[2] == "true") and tostring(args[4]):match("/new%.ts$") then
        saw = true
        break
      end
    end
    assert.is_true(saw)
  end)

  it("rename_paths() still logs RENAMED when no client handles willRenameFiles; does not send didRenameFiles", function()
    -- No client supports willRenameFiles
    local req_seen = 0
    local did_notifies = 0
    local client = {
      name = "foo",
      supports_method = function(_, _) return false end,
      request = function() req_seen = req_seen + 1 end,
      notify = function(method, _)
        if method == "workspace/didRenameFiles" then did_notifies = did_notifies + 1 end
      end,
    }
    lspu_stub.clients_for_path = function(_) return { client } end
    lsp_clients = { client } -- visible globally, but it won't be used for didRenameFiles

    local M = reload()
    M.rename_paths("/a.ts", "/b.ts")

    -- No willRenameFiles request was made
    assert.equals(0, req_seen)
    -- No didRenameFiles notification
    assert.equals(0, did_notifies)

    -- Config.log must include a RENAMED record (true or false)
    local Config = require("ts_willrename.config")
    local logs = Config._log_calls()
    local saw = false
    for _, args in ipairs(logs) do
      if args[1] == "RENAMED:" and (args[2] == true or args[2] == "true" or args[2] == false or args[2] == "false") then
        saw = true
        break
      end
    end
    assert.is_true(saw)
  end)

  it("rename_paths() uses vim.lsp.get_clients() when clients_for_path() returns empty", function()
    -- lspu reports none; fallback to global client which supports will/did
    local did_notifies = 0
    lspu_stub.clients_for_path = function(_) return {} end
    lsp_clients = { {
      name = "bar",
      supports_method = function(_, m)
        return m == "workspace/willRenameFiles" or m == "workspace/didRenameFiles"
      end,
      request = function(method, params, cb)
        cb(nil, { changes = { ["file:///z.ts"] = { {} } } })
      end,
      notify = function(method, _)
        if method == "workspace/didRenameFiles" then did_notifies = did_notifies + 1 end
      end,
    } }

    local M = reload()
    M.rename_paths("/src/old.ts", "/src/new.ts")

    -- Some applier must have executed
    assert.is_true((#silent_apply_calls + #std_apply_calls) >= 1)
    -- didRenameFiles was sent by the fallback client
    assert.equals(1, did_notifies)

    -- Config.log must include RENAMED:true
    local Config = require("ts_willrename.config")
    local logs = Config._log_calls()
    local saw = false
    for _, args in ipairs(logs) do
      if args[1] == "RENAMED:" and (args[2] == true or args[2] == "true") then
        saw = true
        break
      end
    end
    assert.is_true(saw)
  end)

  it("rename_for_path() prompts for path and delegates to rename_paths() with directory input handling", function()
    -- ui.input returns a directory path ending with slash
    local asked = {}
    vim.ui.input = function(opts, cb)
      asked[#asked+1] = opts
      cb("/dest/") -- directory; should append basename of seed
    end

    -- Spy on rename_paths to capture args
    package.loaded["ts_willrename.init"] = nil
    local M = require("ts_willrename.init")
    local captured = {}
    local real = M.rename_paths
    M.rename_paths = function(old_abs, new_abs)
      captured[#captured+1] = { old = old_abs, new = new_abs }
      -- do not execute actual rename here
    end

    M.rename_for_path("/src/app/file.ts")

    assert.equals(1, #asked)
    assert.equals(1, #captured)
    assert.equals("/src/app/file.ts", captured[1].old)
    assert.equals("/dest/file.ts", captured[1].new)

    -- restore
    M.rename_paths = real
    vim.ui.input = nil
  end)

  it("rename() early-exits with message when current buffer has no name", function()
    local M = reload()
    buf_names[1] = "" -- unnamed
    M.rename()
    -- We assert via structured log capture
    local Config = require("ts_willrename.config")
    local logs = Config._log_calls()
    local saw = false
    for _, args in ipairs(logs) do
      if tostring(args[1]):match("Open a TS/JS file first") then
        saw = true; break
      end
    end
    assert.is_true(saw)
  end)
end)

