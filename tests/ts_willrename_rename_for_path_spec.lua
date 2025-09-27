local eq = assert.are.same
local fs = require("tests.helpers.fs")

describe("ts_willrename.rename_for_path()", function()
  local wr
  local old_get = vim.lsp.get_clients

  before_each(function()
    for k in pairs(package.loaded) do
      if k:match("^ts_willrename") then package.loaded[k] = nil end
    end
    wr = require("ts_willrename")
    wr.setup({ silent_apply = false, autosave = true, wipe_unlisted = true, respect_root = false })

    local tmp = fs.tmpdir("wrf-")
    local root = tmp
    local a = fs.join(tmp, "a.ts")
    local b = fs.join(tmp, "b.ts")
    local c = fs.join(tmp, "dir/c.ts") -- test renaming into a folder

    fs.write(a, { 'import "./b";', "export const z = 1" })
    fs.write(b, { "export {}" })

    vim.g.__wrf = { root = root, a = a, b = b, c = c }

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
    vim.g.__wrf = nil
  end)

  it("works when called as if from nvim-tree (no TS buffer focused)", function(done)
    local a, b, c = vim.g.__wrf.a, vim.g.__wrf.b, vim.g.__wrf.c

    -- simulate nvim-tree flow: invoke non-interactive path API
    require("ts_willrename").rename_paths(b, c)

    vim.defer_fn(function()
      -- file moved to dir/c.ts
      eq(false, vim.loop.fs_stat(b) ~= nil)
      eq(true,  vim.loop.fs_stat(c) ~= nil)

      -- a.ts updated on disk
      local text = table.concat(fs.read(a), "\n")
      assert.truthy(text:find('import "dir/c"'), "a.ts import was not updated to dir/c")

      done()
    end, 80)
  end)
end)

