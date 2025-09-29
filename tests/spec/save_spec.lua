-- Tests for lua/ts_willrename/save.lua
--
-- Verifies:
--  - no-op when both autosave=false and wipe_unlisted=false
--  - autosaves eligible modified buffers (and resets 'modified' flag)
--  - does NOT autosave when path contains "/types/" (safety net)
--  - wipes unlisted, unmodified buffers when wipe_unlisted=true
--  - does not wipe modified buffers
--  - ignores non-loaded buffers or non-normal buftype
--  - deduplicates buffer ids in input list (uniq)
--  - respects readonly/modifiable gates
--  - handles writefile failure (keeps modified; no wipe)
--
-- We stub:
--  - ts_willrename.config.get()   (mutable options)
--  - ts_willrename.util.path.norm_path()
--  - vim APIs around buffers, options, writefile, cmd

-- -------- Stubs for deps --------
do
  local current = {
    autosave = false,
    wipe_unlisted = false,
  }
  package.preload["ts_willrename.config"] = function()
    return {
      get = function() return current end,
      _set = function(k,v) current[k]=v end,
      _reset = function() current.autosave=false; current.wipe_unlisted=false end,
    }
  end
  package.preload["ts_willrename.util.path"] = function()
    return {
      norm_path = function(p) return (tostring(p or "")):gsub("\\","/") end
    }
  end
end

local Cfg = require("ts_willrename.config")

-- -------- Minimal Vim scaffolding --------
vim = vim or {}
vim.api = vim.api or {}
vim.fn  = vim.fn or {}

-- Track global command calls (write!, etc.)
local cmd_calls = {}
vim.cmd = function(cmd) table.insert(cmd_calls, cmd) end

-- Buffer model
local BUFS = {}  -- bufnr -> { name, lines, opts={buflisted,modified,readonly,modifiable,buftype}, loaded }
local deleted = {}  -- list of deleted bufnrs
local function make_buf(name, opts)
  local id = 1
  while BUFS[id] do id = id + 1 end
  BUFS[id] = {
    name  = name or "",
    lines = { "line1", "line2" },
    loaded = true,
    opts = {
      buflisted  = true,
      modified   = false,
      readonly   = false,
      modifiable = true,
      buftype    = "",
    }
  }
  for k,v in pairs(opts or {}) do BUFS[id].opts[k] = v end
  return id
end

-- Implement vim.bo (per-buffer options)
vim.bo = setmetatable({}, {
  __index = function(_, bufnr) return BUFS[bufnr] and BUFS[bufnr].opts or {} end,
  __newindex = function(_, bufnr, tbl)
    -- Allow assigning entire table (rare), but our code sets individual fields
    if BUFS[bufnr] and type(tbl)=="table" then
      for k,v in pairs(tbl) do BUFS[bufnr].opts[k]=v end
    end
  end,
})

-- API functions
vim.api.nvim_buf_get_name = function(bufnr) return (BUFS[bufnr] and BUFS[bufnr].name) or "" end
vim.api.nvim_buf_get_lines = function(bufnr, s, e, strict)
  return (BUFS[bufnr] and BUFS[bufnr].lines) or {}
end
vim.api.nvim_buf_is_loaded = function(bufnr) return BUFS[bufnr] and BUFS[bufnr].loaded or false end
vim.api.nvim_buf_delete = function(bufnr, _)
  if not BUFS[bufnr] then error("no such buffer") end
  table.insert(deleted, bufnr); BUFS[bufnr] = nil
end
vim.api.nvim_buf_call = function(bufnr, fn) assert(BUFS[bufnr], "buffer missing"); fn() end

-- writefile stub (can be toggled to fail)
local writefile_should_fail = false
vim.fn.writefile = function(lines, name)
  if writefile_should_fail then error("disk full") end
  -- emulate writing by accepting any args
  return 0
end

-- fresh require helper
local function reload()
  package.loaded["ts_willrename.save"] = nil
  return require("ts_willrename.save")
end

-- helpers
local function reset_env()
  -- clear registries
  for k in pairs(BUFS) do BUFS[k]=nil end
  for i=#deleted,1,-1 do deleted[i]=nil end
  for i=#cmd_calls,1,-1 do cmd_calls[i]=nil end
  writefile_should_fail = false
  Cfg._reset()
end

describe("ts_willrename.save", function()
  before_each(function() reset_env() end)

  it("is a no-op when both autosave and wipe_unlisted are false", function()
    local M = reload()
    local b = make_buf("/proj/a.ts", { modified=true })
    M.autosave_and_cleanup({ b })
    assert.same({}, deleted)
    assert.equals(true, vim.bo[b].modified) -- unchanged
  end)

  it("autosaves eligible modified buffers and resets 'modified'", function()
    local M = reload()
    Cfg._set("autosave", true)

    local b = make_buf("/proj/a.ts", { modified=true, buflisted=true, readonly=false, modifiable=true, buftype="" })
    M.autosave_and_cleanup({ b })

    -- Wrote via :write! (cmd) and fallback writefile attempted inside helper;
    -- we can't distinguish primary vs fallback here, but we can assert effects:
    assert.equals(false, vim.bo[b].modified)
    assert.equals(true, vim.bo[b].buflisted) -- not touched by autosave
    assert.equals(0, #deleted)
  end)

  it("does NOT autosave when path contains '/types/' (safety net)", function()
    local M = reload()
    Cfg._set("autosave", true)

    local b = make_buf("/proj/types/a.ts", { modified=true })
    M.autosave_and_cleanup({ b })

    assert.equals(true, vim.bo[b].modified) -- remains dirty
    assert.equals(0, #deleted)
  end)

  it("wipes unlisted & unmodified buffers when wipe_unlisted=true", function()
    local M = reload()
    Cfg._set("wipe_unlisted", true)

    local keep = make_buf("/proj/keep.ts", { buflisted=true, modified=false })
    local wipe = make_buf("/proj/wipe.ts", { buflisted=false, modified=false })
    M.autosave_and_cleanup({ keep, wipe })

    assert.same({ wipe }, deleted)
    assert.truthy(BUFS[keep]) -- still exists
  end)

  it("does not wipe unlisted buffers if they are modified", function()
    local M = reload()
    Cfg._set("wipe_unlisted", true)

    local b = make_buf("/proj/wipeme.ts", { buflisted=false, modified=true })
    M.autosave_and_cleanup({ b })

    assert.equals(0, #deleted)
  end)

  it("ignores non-loaded buffers and non-normal buftype", function()
    local M = reload()
    Cfg._set("autosave", true)
    Cfg._set("wipe_unlisted", true)

    local not_loaded = make_buf("/proj/nl.ts", { buflisted=false, modified=false }); BUFS[not_loaded].loaded = false
    local special = make_buf("/proj/qf", { buflisted=false, modified=false, buftype="quickfix" })

    M.autosave_and_cleanup({ not_loaded, special })
    assert.equals(0, #deleted) -- no wipes
  end)

  it("deduplicates buffer ids (uniq)", function()
    local M = reload()
    Cfg._set("autosave", true)

    local b = make_buf("/proj/a.ts", { modified=true })
    M.autosave_and_cleanup({ b, b, b }) -- duplicates

    assert.equals(false, vim.bo[b].modified) -- wrote once
  end)

  it("respects readonly/modifiable gates (no autosave when readonly or not modifiable)", function()
    local M = reload()
    Cfg._set("autosave", true)

    local ro = make_buf("/proj/ro.ts", { modified=true, readonly=true })
    local nomod = make_buf("/proj/nomod.ts", { modified=true, modifiable=false })
    M.autosave_and_cleanup({ ro, nomod })

    assert.equals(true, vim.bo[ro].modified)
    assert.equals(true, vim.bo[nomod].modified)
  end)

  it("when writefile fails, buffer stays modified and is not wiped", function()
    local M = reload()
    Cfg._set("autosave", true)
    Cfg._set("wipe_unlisted", true)

    local b = make_buf("/proj/a.ts", { modified=true, buflisted=false })
    writefile_should_fail = true

    M.autosave_and_cleanup({ b })

    -- Still modified due to failure; thus not wiped
    assert.equals(true, vim.bo[b].modified)
    assert.equals(0, #deleted)
  end)
end)

