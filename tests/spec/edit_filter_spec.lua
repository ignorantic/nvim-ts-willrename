-- Tests for lua/ts_willrename/edit/filter.lua
--
-- Stub dependencies BEFORE requiring the module under test
do
  -- keep current config for tests
  local current = { ignore = {} }

  package.preload["ts_willrename.config"] = function()
    return {
      get = function() return current end,
      -- helpers for tests
      _set_ignore = function(v) current.ignore = v or {} end,
      _get_current = function() return current end,
    }
  end

  package.preload["ts_willrename.util.path"] = function()
    local M = {}

    -- Basic path normalization for cross-platform behavior
    function M.norm_path(p)
      p = tostring(p or "")
      -- convert backslashes to '/'
      p = p:gsub("\\", "/")
      -- collapse repeated slashes (but keep URI scheme)
      p = p:gsub("([^:])/+", "%1/")
      return p
    end

    -- Convert file:// URI to a normalized filesystem path
    function M.uri_path(uri)
      local s = tostring(uri or "")
      s = s:gsub("^file://", "")
      -- percent-decoding
      s = s:gsub("%%(%x%x)", function(hex)
        return string.char(tonumber(hex, 16))
      end)
      return M.norm_path(s)
    end

    return M
  end
end

local config = require("ts_willrename.config")
local path   = require("ts_willrename.util.path")
local filter = require("ts_willrename.edit.filter")

describe("ts_willrename.filter.filter_edit", function()
  before_each(function()
    -- reset ignore rules before each test
    config._set_ignore({})
  end)

  it("returns nil when edit is nil", function()
    assert.is_nil(filter.filter_edit(nil))
  end)

  it("keeps non-ignored URIs in edit.changes and removes ignored by string rules", function()
    config._set_ignore({ "/dist/", "/coverage/" })

    local edit = {
      changes = {
        ["file:///proj/src/a.ts"]        = { { newText = "x" } },
        ["file:///proj/dist/gen.ts"]     = { { newText = "y" } },
        ["file:///proj/coverage/map.js"] = { { newText = "z" } },
      }
    }

    local res = filter.filter_edit(vim.deepcopy(edit))

    -- only src/a.ts should remain
    assert.is_table(res.changes)
    assert.is_truthy(res.changes["file:///proj/src/a.ts"])
    assert.is_nil(res.changes["file:///proj/dist/gen.ts"])
    assert.is_nil(res.changes["file:///proj/coverage/map.js"])
  end)

  it("filters documentChanges when textDocument.uri points to an ignored path", function()
    config._set_ignore({ "/dist/" })

    local dc1 = {
      textDocument = { uri = "file:///proj/src/ok.ts", version = 1 },
      edits = { { newText = "ok" } },
    }
    local dc2 = {
      textDocument = { uri = "file:///proj/dist/skip.ts", version = 1 },
      edits = { { newText = "nope" } },
    }

    local res = filter.filter_edit({
      documentChanges = { dc1, dc2 }
    })

    assert.is_nil(res.changes)                              -- untouched
    assert.equals(1, #res.documentChanges)                  -- only one remains
    assert.equals("file:///proj/src/ok.ts", res.documentChanges[1].textDocument.uri)
  end)

  it("supports textDocument as a string URI (not only table with .uri)", function()
    config._set_ignore({ "/dist/" })

    local dc_tbl = {
      textDocument = { uri = "file:///proj/src/ok.ts" },
      edits = {}
    }
    local dc_str = {
      textDocument = "file:///proj/dist/skip.ts",           -- as string
      edits = {}
    }

    local res = filter.filter_edit({
      documentChanges = { dc_tbl, dc_str }
    })

    assert.equals(1, #res.documentChanges)
    assert.equals("file:///proj/src/ok.ts", res.documentChanges[1].textDocument.uri)
  end)

  it("drops documentChanges entirely when all entries are ignored", function()
    config._set_ignore({ "/dist/" })

    local edit = {
      documentChanges = {
        { textDocument = { uri = "file:///proj/dist/a.ts" }, edits = {} },
        { textDocument = "file:///proj/dist/b.ts", edits = {} },
      }
    }

    local res = filter.filter_edit(edit)
    assert.is_nil(res.documentChanges)
  end)

  it("accepts function-based ignore rules that return true", function()
    config._set_ignore({
      function(p) return p:match("%.gen%.ts$") ~= nil end
    })

    local edit = {
      changes = {
        ["file:///proj/src/keep.ts"]       = { { newText = "x" } },
        ["file:///proj/src/model.gen.ts"]  = { { newText = "y" } },
      },
      documentChanges = {
        { textDocument = { uri = "file:///proj/src/also.gen.ts" }, edits = {} },
        { textDocument = { uri = "file:///proj/src/ok.ts" },       edits = {} },
      }
    }

    local res = filter.filter_edit(vim.deepcopy(edit))

    -- changes: only keep.ts should remain
    assert.is_truthy(res.changes["file:///proj/src/keep.ts"])
    assert.is_nil(res.changes["file:///proj/src/model.gen.ts"])

    -- documentChanges: only ok.ts should remain
    assert.equals(1, #res.documentChanges)
    assert.equals("file:///proj/src/ok.ts", res.documentChanges[1].textDocument.uri)
  end)

  it("ignores function rules that error (protected by pcall) and does not filter by them", function()
    config._set_ignore({
      function(_) error("boom") end,     -- should be safely ignored
      "/dist/",
    })

    local edit = {
      changes = {
        ["file:///proj/dist/a.ts"] = { { newText = "x" } },
        ["file:///proj/src/b.ts"]  = { { newText = "y" } },
      }
    }

    local res = filter.filter_edit(vim.deepcopy(edit))
    -- dist entry removed by string rule
    assert.is_nil(res.changes["file:///proj/dist/a.ts"])
    -- src entry remains
    assert.is_truthy(res.changes["file:///proj/src/b.ts"])
  end)

  it("leaves empty `changes` table as empty (does not force it to nil)", function()
    config._set_ignore({ "/dist/" })

    local res = filter.filter_edit({
      changes = {
        ["file:///proj/dist/a.ts"] = { { newText = "x" } },
      }
    })

    -- everything removed; keep an empty table as a valid state
    assert.is_table(res.changes)
    local count = 0
    for _ in pairs(res.changes) do count = count + 1 end
    assert.equals(0, count)
  end)

  it("works when both `changes` and `documentChanges` are present", function()
    config._set_ignore({ "/generated/", function(p) return p:match("/skip/") ~= nil end })

    local edit = {
      changes = {
        ["file:///proj/src/keep.ts"]       = { { newText = "x" } },
        ["file:///proj/generated/drop.ts"] = { { newText = "y" } },
      },
      documentChanges = {
        { textDocument = { uri = "file:///proj/src/ok.ts" },       edits = {} },
        { textDocument = { uri = "file:///proj/skip/ignored.ts" }, edits = {} },
      }
    }

    local res = filter.filter_edit(vim.deepcopy(edit))

    assert.is_truthy(res.changes["file:///proj/src/keep.ts"])
    assert.is_nil(res.changes["file:///proj/generated/drop.ts"])

    assert.equals(1, #res.documentChanges)
    assert.equals("file:///proj/src/ok.ts", res.documentChanges[1].textDocument.uri)
  end)
end)

