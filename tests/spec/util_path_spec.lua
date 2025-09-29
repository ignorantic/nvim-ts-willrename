-- Tests for lua/ts_willrename/util/path.lua

local saved = {}

local function stub(tbl, key, val)
  saved[tbl] = saved[tbl] or {}
  if saved[tbl][key] == nil then
    saved[tbl][key] = tbl[key]
  end
  tbl[key] = val
end

local function restore_all()
  for tbl, map in pairs(saved) do
    for k, v in pairs(map) do tbl[k] = v end
  end
  saved = {}
end

describe("ts_willrename.util.path", function()
  local path

  before_each(function()
    package.loaded["ts_willrename.util.path"] = nil
    vim.loop = vim.loop or {}
    vim.fn   = vim.fn   or {}
    restore_all()
    path = require("ts_willrename.util.path")
  end)

  after_each(function()
    restore_all()
  end)

  describe("is_windows()", function()
    it("returns truthy when os_uname().sysname contains 'Windows'", function()
      stub(vim.loop, "os_uname", function() return { sysname = "Windows_NT" } end)
      -- .match("Windows") returns "Windows" (string), not boolean true
      assert.is_truthy(path.is_windows())
    end)

    it("returns falsy for non-Windows sysname", function()
      stub(vim.loop, "os_uname", function() return { sysname = "Linux" } end)
      assert.is_falsy(path.is_windows())
    end)
  end)

  describe("norm_path()", function()
    it("returns input as-is for nil or empty", function()
      assert.is_nil(path.norm_path(nil))
      assert.equals("", path.norm_path(""))
    end)

    it("normalizes slashes and trims trailing slash; lowercases on Windows", function()
      stub(vim.loop, "os_uname", function() return { sysname = "Windows_NT" } end)
      stub(vim.fn, "fnamemodify", function(p, mod)
        assert.equals(":p", mod)
        return "C:\\Work\\Proj\\Subdir\\"
      end)
      assert.equals("c:/work/proj/subdir", path.norm_path("whatever"))
    end)

    it("keeps case on non-Windows and collapses trailing slashes", function()
      stub(vim.loop, "os_uname", function() return { sysname = "Linux" } end)
      stub(vim.fn, "fnamemodify", function() return "/home/User/Proj//" end)
      assert.equals("/home/User/Proj", path.norm_path("x"))
    end)
  end)

  describe("join()", function()
    it("inserts a slash when base has no trailing slash", function()
      assert.equals("a/b", path.join("a", "b"))
    end)

    it("does not duplicate slash when base already ends with slash", function()
      assert.equals("a/b", path.join("a/", "b"))
    end)
  end)

  describe("uri_path()", function()
    it("converts file URI to normalized path via vim.uri_to_fname + norm_path", function()
      stub(vim.fn, "fnamemodify", function() return "/proj/src/file.ts/" end)
      stub(vim.loop, "os_uname", function() return { sysname = "Linux" } end)
      stub(vim, "uri_to_fname", function(uri)
        assert.equals("file:///proj/src/file.ts", uri)
        return "/proj/src/file.ts/"
      end)
      assert.equals("/proj/src/file.ts", path.uri_path("file:///proj/src/file.ts"))
    end)
  end)

  describe("startswith()", function()
    it("uses vim.startswith when available", function()
      stub(vim, "startswith", function(s, p) return s:sub(1, #p) == p end)
      assert.is_true(path.startswith("foobar", "foo"))
      assert.is_false(path.startswith("foobar", "bar"))
    end)

    it("falls back when vim.startswith is not available (simulate by swapping global vim)", function()
      -- Save original global vim and replace with a minimal one without .startswith
      local original_vim = vim
      _G.vim = { }          -- no startswith; fallback branch must be used
      -- Call directly; fallback does not use any other vim members
      local ok1 = path.startswith("hello", "he")
      local ok2 = path.startswith("hello", "lo")
      -- Restore global vim
      _G.vim = original_vim
      assert.is_true(ok1)
      assert.is_false(ok2)
    end)
  end)

  describe("realpath()", function()
    it("returns fs_realpath(p) when it resolves (stubbed)", function()
      stub(vim.loop, "fs_realpath", function(_) return "/abs/resolved/path" end)
      assert.equals("/abs/resolved/path", path.realpath("/something"))
    end)

    it("returns original path when fs_realpath returns nil", function()
      stub(vim.loop, "fs_realpath", function(_) return nil end)
      assert.equals("not/exist", path.realpath("not/exist"))
    end)
  end)
end)

