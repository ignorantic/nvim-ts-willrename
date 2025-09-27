local eq = assert.are.same
local fs = require("tests.helpers.fs")

describe("ts_willrename.rename_paths()", function()
  local wr
  local old_get = vim.lsp.get_clients

  before_each(function()
    for k in pairs(package.loaded) do
      if k:match("^ts_willrename") then package.loaded[k] = nil end
    end
    wr = require("ts_willrename")
    wr.setup({ silent_apply = false, autosave = true, wipe_unlisted = true, respect_root = false })

    -- stub lsp client that supports fileOperations and returns a WorkspaceEdit
    local tmp = fs.tmpdir("wrp-")
    local root = tmp
    local a = fs.join(tmp, "a.ts")
    local b = fs.join(tmp, "b.ts")
    local c = fs.join(tmp, "c.ts")

    -- Prepare files: a.ts imports ./b; we will rename b -> c and fix a.ts import
    fs.write(a, { 'import { x } from "./b";', "export const y = x" })
    fs.write(b, { "export const x = 1" })

    -- Expose paths to tests via upvalues
    vim.g.__wrp = { root = root, a = a, b = b, c = c }

    vim.lsp.get_clients = function()
      return {
        {
          name = "fake-ts",
          config = { root_dir = root },
          supports_method = function(_, m)
            return m == "workspace/willRenameFiles" or m == "workspace/didRenameFiles"
          end,
          request = function(method, params, cb)
            if method == "workspace/willRenameFiles" then
              local edit = {
                changes = {
                  ["file://" .. a] = {
                    {
                      range = {
                        start = {
                          line = 0, character = 20
                        },
                        ["end"] = {
                          line = 0, character = 24
                        }
                      },
                      newText = "c"
                    }
                  }
                }
              }
              cb(nil, edit)
            else
              cb(nil, nil)
            end
          end,
          notify = function() end,
        }
      }
    end
  end)

  after_each(function()
    vim.lsp.get_clients = old_get
    vim.g.__wrp = nil
  end)

  it("applies edits and renames file on disk", function(done)
    local a, b, c = vim.g.__wrp.a, vim.g.__wrp.b, vim.g.__wrp.c
    -- sanity preconditions
    eq(true, vim.loop.fs_stat(a) ~= nil)
    eq(true, vim.loop.fs_stat(b) ~= nil)
    eq(false, vim.loop.fs_stat(c) ~= nil)

    -- run rename_paths(b -> c)
    require("ts_willrename").rename_paths(b, c)

    -- give plenary/LSP loop a tick to apply edits and write files
    vim.defer_fn(function()
      -- file moved
      eq(false, vim.loop.fs_stat(b) ~= nil)
      eq(true,  vim.loop.fs_stat(c) ~= nil)

      -- a.ts import fixed on disk (autosave=true)
      local text = table.concat(fs.read(a), "\n")
      assert.truthy(text:find('from "./c"'), "a.ts import was not updated to ./c")

      done()
    end, 80)
  end)
end)

