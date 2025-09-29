-- Tests for lua/ts_willrename/config.lua

-- Minimal vim stubs used by the module
vim = vim or {}

-- simple shallow-ish deep_extend for this module's needs (tables of scalars/lists)
vim.tbl_deep_extend = function(strategy, base, overrides)
  assert(strategy == "force", "expected 'force' strategy")
  local function copy(t)
    local r = {}
    for k, v in pairs(t or {}) do
      if type(v) == "table" then
        local t2 = {}
        for k2, v2 in pairs(v) do t2[k2] = v2 end
        r[k] = t2
      else
        r[k] = v
      end
    end
    return r
  end
  local out = copy(base or {})
  for k, v in pairs(overrides or {}) do
    if type(v) == "table" and type(out[k]) == "table" then
      -- numeric keys: replace (Neovim replaces list part when force)
      local has_n = false
      for kk, _ in pairs(v) do if type(kk) == "number" then has_n = true break end end
      if has_n then
        out[k] = copy(v)
      else
        out[k] = vim.tbl_deep_extend("force", out[k], v)
      end
    else
      out[k] = v
    end
  end
  return out
end

vim.tbl_map = function(fn, t)
  local r = {}
  for i, v in ipairs(t) do r[i] = fn(v) end
  return r
end

vim.inspect = function(x)
  local ok, ser = pcall(function() return require("vim.inspect")(x) end)
  if ok then return ser end
  -- tiny fallback
  if type(x) ~= "table" then return tostring(x) end
  local parts = {}
  for k, v in pairs(x) do table.insert(parts, tostring(k) .. "=" .. tostring(v)) end
  table.sort(parts)
  return "{" .. table.concat(parts, ", ") .. "}"
end

vim.log = { levels = { INFO = 0, WARN = 1, ERROR = 2 } }

-- capture notify calls
local notified = {}
vim.notify = function(msg, level)
  table.insert(notified, { msg = msg, level = level })
end

-- fresh require helper
local function reload()
  package.loaded["ts_willrename.config"] = nil
  return require("ts_willrename.config")
end

describe("ts_willrename.config", function()
  before_each(function()
    -- reset capture
    for i = #notified, 1, -1 do notified[i] = nil end
  end)

  it("exposes defaults via get()", function()
    local C = reload()
    local cfg = C.get()
    assert.same(true,  cfg.silent_apply)
    assert.same(false, cfg.autosave)
    assert.same(false, cfg.wipe_unlisted)
    assert.same(true,  cfg.notify_did_rename)
    assert.same("warn", cfg.respect_root)
    assert.same("utf-16", cfg.encoding)
    assert.same({}, cfg.ignore)
    assert.same(false, cfg.debug)
  end)

  it("setup() merges user options (force) and get() returns a fresh table", function()
    local C = reload()
    local before = C.get()

    C.setup({
      autosave = true,
      respect_root = "error",
      ignore = { "/dist/", "/types/" },
    })

    local after = C.get()
    -- setup() rebuilds cfg, so the reference changes
    assert.is_false(before == after)
    -- but values are merged as expected
    assert.same(true, after.autosave)
    assert.same("error", after.respect_root)
    assert.same({ "/dist/", "/types/" }, after.ignore)
  end)

  it("setup() with nil/empty does not crash and keeps previous values", function()
    local C = reload()
    C.setup({ autosave = true })
    local prev = C.get()

    C.setup()  -- nil; should be a no-op merge
    local now = C.get()

    -- reference may stay or change — important is that values persist
    assert.same(true, now.autosave)
    assert.same(prev.respect_root, now.respect_root)
    assert.same(prev.encoding, now.encoding)
  end)

  it("log(...) formats args and uses INFO level", function()
    local C = reload()
    C.log("hello", 123, { a = 1 })

    assert.is_true(#notified >= 1)
    local last = notified[#notified]
    assert.equals(vim.log.levels.INFO, last.level)
    -- message should contain all pieces
    assert.matches("hello", last.msg)
    assert.matches("123", last.msg)
    assert.is_true(last.msg:match("{") ~= nil or last.msg:match("a=1") ~= nil)
  end)

  it("dlog(...) emits only when debug = true", function()
    local C = reload()

    -- debug=false by default -> no new notify
    local base_n = #notified
    C.dlog("hidden")
    assert.equals(base_n, #notified)

    -- enable debug, then emits
    C.setup({ debug = true })
    C.dlog("visible", 42)
    assert.equals(base_n + 1, #notified)
    local last = notified[#notified]
    assert.matches("visible", last.msg)
    assert.matches("42", last.msg)
  end)
end)

