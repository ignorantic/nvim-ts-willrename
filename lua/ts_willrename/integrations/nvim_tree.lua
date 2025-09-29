local M = {}

---Return an on_attach function that replaces "r" with a TS-aware rename.
---It calls willRename → applies edits silently → FS rename → optional autosave.
---@param opts? { extensions?: string[] }
function M.attach(opts)
  opts = opts or {}
  local exts = opts.extensions or { "ts","tsx","js","jsx","mts","cts","mjs","cjs" }

  local api = require("nvim-tree.api")

  local function matches(path)
    if not path then return false end
    local ext = path:match("%.([%w]+)$")
    if not ext then return false end
    ext = ext:lower()
    for _, e in ipairs(exts) do
      if e == ext then return true end
    end
    return false
  end

  local function node_path(node)
    -- Support different nvim-tree versions: prefer absolute_path, then get_id(), then path
    return (node and (node.absolute_path or (node.get_id and node:get_id()) or node.path)) or nil
  end

  return function(bufnr)
    -- Keep default mappings first
    api.config.mappings.default_on_attach(bufnr)

    -- Ensure our plugin is loaded if it's lazy-loaded
    pcall(function()
      require("lazy").load({ plugins = {
        "nvim-ts-willrename",
        "typescript-tools.nvim",
        "nvim-lsp-file-operations"
      } })
    end)

    -- Remove the default "r" binding, then set our custom one
    pcall(vim.keymap.del, "n", "r", { buffer = bufnr })

    vim.keymap.set("n", "r", function()
      local node = api.tree.get_node_under_cursor()
      if not node or node.type ~= "file" then
        return api.fs.rename() -- fallback for non-file nodes
      end

      local path = node_path(node)
      if not matches(path) then
        return api.fs.rename() -- fallback for non-TS/JS files
      end


      -- Call our plugin safely
      local ok, wr = pcall(require, "ts_willrename")
      if not ok then
        return api.fs.rename()
      end

      wr.rename_for_path(path)

      -- Slight delay to allow FS operations to complete, then refresh the tree
      vim.defer_fn(function()
        if api.tree.is_tree_buf(bufnr) then
          api.tree.reload()
        end
      end, 120)
    end, { buffer = bufnr, desc = "TS willRename (fix imports) & rename file" })
  end
end

return M

