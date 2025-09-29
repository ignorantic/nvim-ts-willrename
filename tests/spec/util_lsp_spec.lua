-- Tests for lua/ts_willrename/util/lsp.lua

-- Stub deps BEFORE requiring the module
do
  -- Config stub
  local current = { respect_root = false }
  package.preload["ts_willrename.config"] = function()
    return {
      get = function() return current end,
      respect_root = current.respect_root,
      _set = function(k, v) current[k] = v end,
      _get = function() return current end,
    }
  end

  -- Path utils stub
  package.preload["ts_willrename.util.path"] = function()
    local M = {}
    function M.norm_path(p)
      if not p then return "" end
      p = tostring(p):gsub("\\","/"):gsub("/+$","")
      return p
    end
    function M.startswith(s, prefix)
      s, prefix = tostring(s or ""), tostring(prefix or "")
      return s:sub(1, #prefix) == prefix
    end
    return M
  end
end

local cfg_mod  = require("ts_willrename.config")

-- Minimal vim stubs
vim = vim or {}
vim.fn = vim.fn or {}
vim.api = vim.api or {}
vim.lsp = vim.lsp or {}
vim.log = vim.log or { levels = { WARN = 1, ERROR = 2 } }
vim.schedule = function(cb) cb() end
vim.notify = function(_) end
vim.filetype = vim.filetype or {}
vim.wait = function(_, cond, _) return cond() end

-- Buffer options emulation
do
  local store = {}
  vim.bo = setmetatable({}, {
    __index = function(_, bufnr)
      store[bufnr] = store[bufnr] or { filetype = "" }
      return store[bufnr]
    end,
    __newindex = function() error("do not set vim.bo directly") end,
  })
  vim.api.nvim_buf_set_option = function(bufnr, name, val)
    local slot = vim.bo[bufnr]
    slot[name] = val
  end
end

-- Track fired autocmds
local fired_autocmds = {}
vim.api.nvim_exec_autocmds = function(event, opts)
  table.insert(fired_autocmds, { event = event, buffer = opts and opts.buffer })
end

-- bufadd/bufload stubs — cache by absolute path
do
  local next_nr = 10
  local by_path = {}
  vim.fn.bufadd = function(abs_path)
    abs_path = tostring(abs_path or "")
    if by_path[abs_path] then return by_path[abs_path] end
    next_nr = next_nr + 1
    by_path[abs_path] = next_nr
    return next_nr
  end
  vim.fn.bufload = function(_) end
end

-- uri/filetype helpers
vim.uri_to_fname = function(uri) return uri:gsub("^file://", "") end
vim.filetype.match = function(tbl)
  local fname = tbl and tbl.filename or ""
  if fname:match("%.ts$") then return "typescript" end
  if fname:match("%.tsx$") then return "typescriptreact" end
  return ""
end

-- lsp client registry stub (overwritable)
vim.lsp.get_clients = function() return {} end

-- Helper to reload module under test
local function reload()
  package.loaded["ts_willrename.util.lsp"] = nil
  return require("ts_willrename.util.lsp")
end

describe("ts_willrename.util.lsp", function()
  before_each(function()
    cfg_mod._set("respect_root", false)
    vim.lsp.get_clients = function() return {} end
    for i=#fired_autocmds,1,-1 do fired_autocmds[i] = nil end
  end)

  describe("clients_for_path()", function()
    it("returns only clients whose root_dir prefixes the absolute path", function()
      local clients = {
        { name="ts1", config = { root_dir = "/proj" } },
        { name="ts2", config = { root_dir = "/proj/app" } },
        { name="py",  config = { root_dir = "/other" } },
        { name="bad", config = { } },
      }
      vim.lsp.get_clients = function() return clients end

      local lsp = reload()
      local out = lsp.clients_for_path("/proj/app/src/file.ts")
      local names = {}
      for _, c in ipairs(out) do names[#names+1] = c.name end
      table.sort(names)
      assert.same({ "ts1", "ts2" }, names)
    end)

    it("returns empty for empty path", function()
      local lsp = reload()
      assert.same({}, lsp.clients_for_path(""))
    end)
  end)

  describe("ensure_buf_loaded_for_path()", function()
    it("creates hidden buffer, sets filetype if empty, and fires FileType", function()
      local lsp = reload()

      local bufnr = lsp.ensure_buf_loaded_for_path("/proj/app/src/index.ts")
      assert.is_number(bufnr)
      assert.is_false(vim.bo[bufnr].buflisted ~= false) -- explicitly false
      assert.equals("typescript", vim.bo[bufnr].filetype)

      local seen = false
      for _, ev in ipairs(fired_autocmds) do
        if ev.event == "FileType" and ev.buffer == bufnr then seen = true end
      end
      assert.is_true(seen)
    end)

    it("does not override non-empty filetype and returns same bufnr for same path", function()
      local lsp = reload()
      local p = "/proj/app/src/comp.tsx"

      local b1 = lsp.ensure_buf_loaded_for_path(p)
      -- simulate that something set filetype already
      vim.bo[b1].filetype = "preset"

      local b2 = lsp.ensure_buf_loaded_for_path(p)
      assert.equals(b1, b2)                    -- same buffer
      assert.equals("preset", vim.bo[b2].filetype) -- preserved
    end)
  end)

  describe("wait_clients_for_path()", function()
    it("returns true when clients appear within timeout", function()
      local lsp = reload()
      local calls = 0
      lsp.clients_for_path = function()
        calls = calls + 1
        if calls >= 3 then return { {name="ts"} } end
        return {}
      end
      vim.wait = function(timeout, cond, interval)
        local elapsed = 0
        while elapsed <= timeout do
          if cond() then return true end
          elapsed = elapsed + (interval or 50)
        end
        return false
      end
      assert.is_true(lsp.wait_clients_for_path("/proj/app/file.ts", 200))
    end)

    it("returns false when timeout elapses", function()
      local lsp = reload()
      lsp.clients_for_path = function(_) return {} end
      vim.wait = function(timeout, cond, interval)
        local elapsed = 0
        while elapsed <= timeout do
          if cond() then return true end
          elapsed = elapsed + (interval or 50)
        end
        return false
      end
      assert.is_false(lsp.wait_clients_for_path("/proj/app/file.ts", 100))
    end)
  end)

  describe("preload_plugins()", function()
    it("calls lazy.load with the plugin list when lazy is loaded", function()
      -- Provide a stub module for 'lazy'
      package.preload["lazy"] = function()
        return {
          load = function(arg)
            assert.is_table(arg)
            assert.is_table(arg.plugins)
            table.sort(arg.plugins)
            assert.same({
              "nvim-lsp-file-operations",
              "nvim-ts-willrename",
              "typescript-tools.nvim",
            }, arg.plugins)
          end
        }
      end
      package.loaded["lazy"] = nil
      local lsp = reload()

      -- Mark lazy as LOADED by storing the actual module table, not boolean
      local lazy_mod = require("lazy")
      package.loaded["lazy"] = lazy_mod

      assert.has_no.errors(function() lsp.preload_plugins() end)

      -- cleanup
      package.loaded["lazy"] = nil
      package.preload["lazy"] = nil
    end)

    it("does nothing when lazy is not loaded", function()
      package.loaded["lazy"] = nil
      package.preload["lazy"] = nil
      local lsp = reload()
      assert.has_no.errors(function() lsp.preload_plugins() end)
    end)
  end)

  describe("guard_root()", function()
    it("returns true when respect_root is false/nil", function()
      cfg_mod._set("respect_root", false)
      local lsp = reload()
      assert.is_true(lsp.guard_root("/proj/a.ts", "/anywhere/else.ts"))
    end)

    it("returns true when new path is inside client root; no notify", function()
      cfg_mod._set("respect_root", true)
      vim.lsp.get_clients = function() return { { config = { root_dir = "/proj" } } } end

      local notified = {}
      vim.notify = function(msg, level) table.insert(notified, {msg=msg, level=level}) end

      local lsp = reload()
      local ok = lsp.guard_root("/proj/src/a.ts", "/proj/new/place.ts")
      assert.is_true(ok)
      assert.equals(0, #notified)
    end)

    it("warns and returns true when outside root and respect_root=true", function()
      cfg_mod._set("respect_root", true)
      vim.lsp.get_clients = function() return { { config = { root_dir = "/proj" } } } end

      local notified = {}
      vim.notify = function(msg, level) table.insert(notified, {msg=msg, level=level}) end

      local lsp = reload()
      local ok = lsp.guard_root("/proj/src/a.ts", "/other/place.ts")
      assert.is_true(ok)
      assert.equals(1, #notified)
      assert.matches("outside LSP root", notified[1].msg)
      assert.equals(vim.log.levels.WARN, notified[1].level)
    end)

    it("notifies with ERROR and returns false when respect_root='error'", function()
      cfg_mod._set("respect_root", "error")
      vim.lsp.get_clients = function() return { { config = { root_dir = "/proj" } } } end

      local notified = {}
      vim.notify = function(msg, level) table.insert(notified, {msg=msg, level=level}) end

      local lsp = reload()
      local ok = lsp.guard_root("/proj/src/a.ts", "/OUT/of/root.ts")
      assert.is_false(ok)
      assert.equals(1, #notified)
      assert.matches("outside LSP root", notified[1].msg)
      assert.equals(vim.log.levels.ERROR, notified[1].level)
    end)

    it("returns true when client has no root", function()
      cfg_mod._set("respect_root", true)
      vim.lsp.get_clients = function() return { { config = {} } } end

      local lsp = reload()
      assert.is_true(lsp.guard_root("/proj/src/a.ts", "/outside.ts"))
    end)
  end)
end)

