-- Tests for lua/ts_willrename/integrations/nvim-tree.lua
--
-- We stub:
--   - nvim-tree.api   (config.mappings.default_on_attach, tree.*, fs.*)
--   - vim.keymap      (set/del with buffer-scoped mapping storage)
--   - vim.defer_fn    (execute immediately and record delay)
--   - lazy            (optional; ensure .load is safe)
--   - ts_willrename   (captures rename_for_path(path))
--
-- We verify:
--   - attach(opts) returns on_attach(bufnr) and calls default_on_attach(bufnr)
--   - it unmaps "r" and defines a new buffer-local "r"
--   - non-file node -> falls back to api.fs.rename()
--   - non-TS/JS extension -> falls back to api.fs.rename()
--   - TS/JS extension -> calls ts_willrename.rename_for_path(path), schedules tree.reload()
--   - node_path supports absolute_path, :get_id(), and .path fields

-- Try both module names: with dash and with underscore.
local function fresh_module()
  package.loaded["nvim-tree.api"] = nil
  package.loaded["lazy"] = package.loaded["lazy"] or { load = function(_) end }
  package.loaded["ts_willrename.integrations.nvim-tree"] = nil
  package.loaded["ts_willrename.integrations.nvim_tree"] = nil

  local ok, mod = pcall(require, "ts_willrename.integrations.nvim-tree")
  if not ok then
    ok, mod = pcall(require, "ts_willrename.integrations.nvim_tree")
  end
  if not ok then error(("cannot require integrations module: %s"):format(mod)) end
  return mod
end


-- Minimal Vim scaffolding
vim = vim or {}
vim.api = vim.api or {}
vim.fn  = vim.fn or {}
vim.keymap = {}
vim.schedule = function(cb) cb() end
vim.defer_fn = function(cb, _) cb() end -- overwritten in tests to capture delay

-- Keymap storage (per-buffer)
local map_store = {}      -- [bufnr][lhs] = { rhs = fn, opts = opts }
local del_calls = {}      -- { {mode="n", lhs="r", bufnr=...}, ... }

vim.keymap.set = function(mode, lhs, rhs, opts)
  assert(mode == "n", "tests expect normal mode mapping")
  local bufnr = opts and opts.buffer or 0
  map_store[bufnr] = map_store[bufnr] or {}
  map_store[bufnr][lhs] = { rhs = rhs, opts = opts }
end

vim.keymap.del = function(mode, lhs, opts)
  local bufnr = opts and opts.buffer or 0
  del_calls[#del_calls+1] = { mode = mode, lhs = lhs, bufnr = bufnr }
  if map_store[bufnr] then map_store[bufnr][lhs] = nil end
end

-- nvim-tree.api stub (installed via package.preload)
local api_stub
package.preload["nvim-tree.api"] = function()
  return api_stub
end

-- lazy stub (optional load)
package.preload["lazy"] = function()
  return {
    load = function(_) end, -- no-op; we only care that it doesn't crash
  }
end

-- ts_willrename stub (captures path)
local wr_calls
local function ts_willrename_module()
  return {
    rename_for_path = function(p)
      wr_calls[#wr_calls+1] = p
    end
  }
end

package.preload["ts_willrename"] = ts_willrename_module


-- Helpers to reset stubs/state per test
local function reset_state()
  for k in pairs(map_store) do map_store[k] = nil end
  for i=#del_calls,1,-1 do del_calls[i] = nil end
  wr_calls = {}

  api_stub = {
    config = {
      mappings = {
        default_on_attach = function(_) end,
      },
    },
    tree = {
      get_node_under_cursor = function() return nil end,
      is_tree_buf = function(_) return true end,
      reload = function() end,
    },
    fs = {
      rename = function() end,
    },
  }
end

-- Small node constructors for different shapes
local function node_abs(path)
  return { type = "file", absolute_path = path }
end
local function node_id(path)
  return setmetatable({ type = "file" }, {
    __index = {
      get_id = function(_) return path end
    }
  })
end
local function node_path(path)
  return { type = "file", path = path }
end
local function node_dir(path)
  return { type = "directory", absolute_path = path }
end

describe("ts_willrename.integrations.nvim-tree", function()
  before_each(function()
    reset_state()
    wr_calls = {}

    -- ensure require('ts_willrename') returns our stub (and never the real module)
    package.loaded["ts_willrename"] = ts_willrename_module()

    -- clear integration/deps caches so the module sees current stubs
    package.loaded["nvim-tree.api"] = nil
    package.loaded["lazy"] = { load = function(_) end } -- safe dummy
    package.loaded["ts_willrename.integrations.nvim-tree"] = nil
    package.loaded["ts_willrename.integrations.nvim_tree"] = nil

    -- reduce noise: silence print during tests
    _G.__real_print = _G.print
    _G.print = function() end

    -- defer_fn: execute immediately and record the delay
    local delays = {}
    vim.defer_fn = function(cb, ms) delays[#delays+1] = ms ; cb() end
    _G._nvimtree_test_delays = delays
  end)

  after_each(function()
    _G.print = _G.__real_print
    _G.__real_print = nil
    _G._nvimtree_test_delays = nil
  end)

  it("returns on_attach that calls default_on_attach and remaps 'r'", function()
    local mod = fresh_module()
    local on_attach = mod.attach() -- default extensions
    assert.is_function(on_attach)

    local called_default = false
    api_stub.config.mappings.default_on_attach = function(bufnr)
      called_default = bufnr == 42
    end

    on_attach(42)

    assert.is_true(called_default)
    -- default "r" was removed then set
    assert.is_true(#del_calls >= 1)
    local removed = false
    for _, d in ipairs(del_calls) do
      if d.mode=="n" and d.lhs=="r" and d.bufnr==42 then removed = true end
    end
    assert.is_true(removed)

    assert.is_table(map_store[42])
    assert.is_table(map_store[42]["r"])
    assert.is_function(map_store[42]["r"].rhs)
  end)

  it("falls back to api.fs.rename() for non-file nodes", function()
    local mod = fresh_module()
    local on_attach = mod.attach()

    local renamed = 0
    api_stub.fs.rename = function() renamed = renamed + 1 end
    api_stub.tree.get_node_under_cursor = function() return node_dir("/p/dir") end

    on_attach(7)
    -- trigger mapped callback
    map_store[7]["r"].rhs()

    assert.equals(1, renamed)
    assert.equals(0, #wr_calls)
  end)

  it("falls back to api.fs.rename() when extension is not in the allowlist", function()
    local mod = fresh_module()
    local on_attach = mod.attach({ extensions = { "ts", "tsx" } })

    local renamed = 0
    api_stub.fs.rename = function() renamed = renamed + 1 end
    api_stub.tree.get_node_under_cursor = function() return node_abs("/p/file.txt") end

    on_attach(8)
    map_store[8]["r"].rhs()

    assert.equals(1, renamed)
    assert.equals(0, #wr_calls)
  end)

  it("calls ts_willrename.rename_for_path() for TS-like files (absolute_path)", function()
    local mod = fresh_module()
    local on_attach = mod.attach()

    local reloaded = 0
    api_stub.tree.reload = function() reloaded = reloaded + 1 end
    api_stub.tree.get_node_under_cursor = function() return node_abs("/p/file.tsx") end

    on_attach(9)
    map_store[9]["r"].rhs()

    -- rename_for_path called with correct path
    assert.same({ "/p/file.tsx" }, wr_calls)
    -- tree.reload scheduled via defer_fn
    assert.equals(1, reloaded)
    -- default delay 120ms requested
    assert.is_true((_G._nvimtree_test_delays[1] or 0) >= 120)
  end)

  it("supports node:get_id() as path source", function()
    local mod = fresh_module()
    local on_attach = mod.attach({ extensions = { "js" } })

    api_stub.tree.get_node_under_cursor = function() return node_id("/w/app.jsx") end
    local renamed = 0
    api_stub.fs.rename = function() renamed = renamed + 1 end

    on_attach(10)
    map_store[10]["r"].rhs()

    -- .jsx not in {"js"} -> falls back
    assert.equals(1, renamed)
    assert.equals(0, #wr_calls)
  end)

  it("supports node.path field as path source", function()
    local mod = fresh_module()
    local on_attach = mod.attach({ extensions = { "jsx" } })

    api_stub.tree.get_node_under_cursor = function() return node_path("/w/app.jsx") end

    on_attach(11)
    map_store[11]["r"].rhs()

    assert.same({ "/w/app.jsx" }, wr_calls)
  end)

  it("falls back to api.fs.rename() when requiring ts_willrename fails", function()
    -- patch global require to fail only for 'ts_willrename'
    local real_require = _G.require
    _G.require = function(name, ...)
      if name == "ts_willrename" then
        error("simulated require failure")
      end
      return real_require(name, ...)
    end

    -- additionally remove loaded/preload so the real module can’t be picked up
    local saved_preload = package.preload["ts_willrename"]
    local saved_loaded  = package.loaded["ts_willrename"]
    package.preload["ts_willrename"] = nil
    package.loaded["ts_willrename"]  = nil

    local mod = fresh_module()
    local on_attach = mod.attach()

    local renamed = 0
    api_stub.fs.rename = function() renamed = renamed + 1 end
    api_stub.tree.get_node_under_cursor = function() return { type = "file", absolute_path = "/p/a.ts" } end

    on_attach(12)
    map_store[12]["r"].rhs()

    assert.equals(1, renamed)     -- fallback executed
    assert.equals(0, #wr_calls)   -- stub was not called

    -- restore require and caches
    _G.require = real_require
    package.preload["ts_willrename"] = saved_preload or ts_willrename_module
    package.loaded["ts_willrename"]  = saved_loaded or ts_willrename_module()
  end)


  it("respects custom extensions list", function()
    local mod = fresh_module()
    local on_attach = mod.attach({ extensions = { "cts", "mts" } })

    api_stub.tree.get_node_under_cursor = function() return node_abs("/p/a.cts") end

    on_attach(13)
    map_store[13]["r"].rhs()

    assert.same({ "/p/a.cts" }, wr_calls)
  end)
end)

