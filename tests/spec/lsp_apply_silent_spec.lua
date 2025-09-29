-- Tests for lua/ts_willrename/lsp_apply_silent.lua
--
-- Verifies:
--   - applies edits for URIs from both `changes` (map) and `documentChanges` (array)
--   - uses default encoding "utf-16" or the provided override
--   - loads buffer by uri and marks it unlisted + modified
--   - sets & restores vim.o.eventignore around the apply
--   - returns list of touched buffer numbers
--   - ignores non-text-edit documentChanges (e.g. create/rename/delete)
--
-- We stub:
--   - vim.uri_to_bufnr (stable mapping uri->bufnr)
--   - vim.api.nvim_buf_set_option / nvim_buf_call
--   - vim.lsp.util.apply_text_edits (capture calls)
--   - vim.bo (per-buffer options), vim.o (global options table)

-- ---------- Minimal Vim stubs ----------
vim = vim or {}
vim.api = vim.api or {}
vim.lsp = vim.lsp or {}
vim.lsp.util = vim.lsp.util or {}

-- global options table
vim.o = vim.o or { eventignore = "" }

-- per-buffer options
do
  local store = {}
  vim.bo = setmetatable({}, {
    __index = function(_, bufnr)
      store[bufnr] = store[bufnr] or { buflisted = true, modified = false }
      return store[bufnr]
    end,
    __newindex = function() error("do not assign vim.bo directly in tests") end,
  })
end

-- stable uri->bufnr mapper
local next_buf = 100
local uri_to_buf = {}
vim.uri_to_bufnr = function(uri)
  if not uri_to_buf[uri] then
    next_buf = next_buf + 1
    uri_to_buf[uri] = next_buf
  end
  return uri_to_buf[uri]
end

-- capture nvim_buf_set_option
local setopt_calls = {}
vim.api.nvim_buf_set_option = function(bufnr, name, val)
  table.insert(setopt_calls, { bufnr = bufnr, name = name, val = val })
  local slot = vim.bo[bufnr]
  slot[name] = val
end

-- run fn() "inside" buffer, while manipulating vim.o.eventignore
vim.api.nvim_buf_call = function(_buf, fn)
  fn()
end

-- capture apply_text_edits calls
local apply_calls = {}
vim.lsp.util.apply_text_edits = function(edits, bufnr, enc)
  table.insert(apply_calls, { edits = edits, bufnr = bufnr, enc = enc })
end

-- fresh require helper
local function reload()
  package.loaded["ts_willrename.lsp_apply_silent"] = nil
  return require("ts_willrename.lsp_apply_silent")
end

-- reset helpers
local function reset_captures()
  for i = #setopt_calls, 1, -1 do setopt_calls[i] = nil end
  for i = #apply_calls, 1, -1 do apply_calls[i] = nil end
  -- reset eventignore
  vim.o.eventignore = ""
end

describe("ts_willrename.edit.apply", function()
  before_each(function()
    reset_captures()
  end)

  it("returns empty list when edit is nil/empty", function()
    local M = reload()
    assert.same({}, M.apply_workspace_edit_silent(nil))
    assert.same({}, M.apply_workspace_edit_silent({}))
  end)

  it("applies edits from `changes` map with default encoding and marks buffers", function()
    local M = reload()
    local e = {
      changes = {
        ["file:///p/a.ts"]  = { {range={}, newText="A"} },
        ["file:///p/b.tsx"] = { {range={}, newText="B"} },
      }
    }

    local touched = M.apply_workspace_edit_silent(e) -- default enc = utf-16

    -- touched contains both buffers in some order (pairs is unordered)
    assert.equals(2, #touched)
    -- check apply calls (2 of them)
    assert.equals(2, #apply_calls)
    for _, call in ipairs(apply_calls) do
      assert.equals("utf-16", call.enc)
      -- buffer is unlisted and marked modified
      assert.is_false(vim.bo[call.bufnr].buflisted)
      assert.is_true(vim.bo[call.bufnr].modified)
    end
  end)

  it("applies edits from `documentChanges` array; supports textDocument as table.uri and as string", function()
    local M = reload()
    local e = {
      documentChanges = {
        { textDocument = { uri = "file:///p/c.ts" }, edits = { {range={}, newText="C"} } },
        { textDocument = "file:///p/d.tsx",          edits = { {range={}, newText="D"} } },
        { kind = "create", uri = "file:///p/skip.ts" }, -- should be ignored
      }
    }

    local touched = M.apply_workspace_edit_silent(e, "utf-8") -- override encoding

    assert.equals(2, #touched)
    assert.equals(2, #apply_calls)
    for _, call in ipairs(apply_calls) do
      assert.equals("utf-8", call.enc)
      assert.is_true(vim.bo[call.bufnr].modified)
    end
  end)

  it("sets & restores eventignore around apply_text_edits", function()
    local M = reload()
    vim.o.eventignore = "User" -- previous value to be restored
    local e = {
      changes = {
        ["file:///p/e.ts"] = { {range={}, newText="E"} },
      }
    }

    -- spy on eventignore during apply via wrapper
    local seen_before, seen_after
    local real_apply = vim.lsp.util.apply_text_edits
    vim.lsp.util.apply_text_edits = function(edits, bufnr, enc)
      seen_before = vim.o.eventignore
      return real_apply(edits, bufnr, enc)
    end

    local touched = M.apply_workspace_edit_silent(e)

    -- after apply, eventignore restored
    seen_after = vim.o.eventignore
    assert.equals("User", seen_after)
    -- inside apply, it should contain our suppress list (comma-joined)
    assert.is_true(type(seen_before) == "string" and #seen_before > 0)
    assert.is_truthy(seen_before:match("BufAdd"))
    assert.equals(1, #touched)

    -- restore stub
    vim.lsp.util.apply_text_edits = real_apply
  end)

  it("returns all touched buffers across both changes & documentChanges", function()
    local M = reload()
    local e = {
      changes = {
        ["file:///p/x.ts"] = {{}},
      },
      documentChanges = {
        { textDocument = { uri = "file:///p/y.ts" }, edits = {{}} },
      }
    }
    local touched = M.apply_workspace_edit_silent(e)
    -- two buffers
    assert.equals(2, #touched)
    -- those buffers correspond to the URIs we passed
    local b_x = vim.uri_to_bufnr("file:///p/x.ts")
    local b_y = vim.uri_to_bufnr("file:///p/y.ts")
    table.sort(touched)
    local expected = { math.min(b_x, b_y), math.max(b_x, b_y) }
    assert.same(expected, touched)
  end)
end)

