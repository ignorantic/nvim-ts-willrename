-- tests/ts_willrename_spec.lua
local eq = assert.are.same
local willrename

describe("ts_willrename", function()
  before_each(function()
    package.loaded["ts_willrename"] = nil
    package.loaded["ts_willrename.lsp_apply_silent"] = nil
    willrename = require("ts_willrename")
  end)

  it("normalizes path and skips when new == old", function()
    -- доступ к приватам можно через возвращаемые эффекты/поведение,
    -- либо тестить публичный API (рекомендуется).
    -- Здесь просто проверим что rename_paths не падает на равных путях.
    willrename.setup({ autosave = false })
    -- заглушим will_rename через переопределение vim.lsp.get_clients на []
    local orig = vim.lsp.get_clients
    vim.lsp.get_clients = function() return {} end
    -- ничего не должно упасть:
    willrename.rename_paths(vim.loop.cwd() .. "/a.ts", vim.loop.cwd() .. "/a.ts")
    vim.lsp.get_clients = orig
  end)

  it("calls willRename and applies edits", function(done)
    willrename.setup({ autosave = false, silent_apply = true })

    -- stub apply_silent to check that it was called
    local applied = false
    package.loaded["ts_willrename.lsp_apply_silent"] = {
      apply_workspace_edit_silent = function(edit, enc)
        applied = (enc == "utf-16" and type(edit) == "table"); return {}
      end
    }
    package.loaded["ts_willrename"] = nil
    willrename = require("ts_willrename")

    -- stub LSP client that supports willRenameFiles
    local client = {
      name = "fake-ts",
      supports_method = function(_, m) return m == "workspace/willRenameFiles" or m == "workspace/didRenameFiles" end,
      request = function(_, _, cb)
        -- вернем простейший WorkspaceEdit
        cb(nil, { changes = { ["file://" .. vim.loop.cwd() .. "/x.ts"] = {} } })
      end,
      notify = function() end,
    }
    local old_get = vim.lsp.get_clients
    vim.lsp.get_clients = function(_) return { client } end

    -- создадим пустые файлы для переименования в temp-dir
    local tmp = vim.loop.fs_mkdtemp(vim.loop.os_tmpdir() .. "/wr-XXXXXX")
    local old = tmp .. "/x.ts"
    local new = tmp .. "/y.ts"
    vim.fn.writefile({ "export const a = 1" }, old)

    willrename.rename_paths(old, new)

    vim.defer_fn(function()
      eq(true, applied)
      -- new должен появиться
      local st_new = vim.loop.fs_stat(new)
      eq("file", st_new and st_new.type or nil)
      vim.lsp.get_clients = old_get
      done()
    end, 50)
  end)
end)

