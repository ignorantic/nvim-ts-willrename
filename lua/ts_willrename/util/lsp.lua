local cfg   = require("ts_willrename.config").get
local path  = require("ts_willrename.util.path")
local C     = require("ts_willrename.config")

local M = {}

---Pick clients whose root_dir covers the given absolute path.
function M.clients_for_path(abs_path)
  abs_path = path.norm_path(abs_path or "")
  if abs_path == "" then return {} end
  local out = {}
  for _, c in ipairs(vim.lsp.get_clients() or {}) do
    local root = c.config and c.config.root_dir and path.norm_path(c.config.root_dir) or nil
    if root and path.startswith(abs_path, root) then
      table.insert(out, c)
    end
  end
  return out
end

---Ensure a file is loaded in a hidden buffer so tsserver can "see" it.
function M.ensure_buf_loaded_for_path(abs_path)
  local bufnr = vim.fn.bufadd(abs_path)
  vim.fn.bufload(bufnr)
  pcall(vim.api.nvim_buf_set_option, bufnr, "buflisted", false)
  if vim.bo[bufnr].filetype == "" then
    local ft = vim.filetype.match({ filename = abs_path }) or ""
    if ft ~= "" then
      vim.bo[bufnr].filetype = ft
      vim.api.nvim_exec_autocmds("FileType", { buffer = bufnr })
    end
  end
  return bufnr
end

---Wait until at least one client covering this path is attached (<= timeout).
function M.wait_clients_for_path(abs_path, timeout_ms)
  timeout_ms = timeout_ms or 800
  return vim.wait(timeout_ms, function()
    return #M.clients_for_path(abs_path) > 0
  end, 50)
end

---Lazy-load deps when invoked from non-TS buffers (e.g. nvim-tree).
function M.preload_plugins()
  if package.loaded["lazy"] then
    pcall(require("lazy").load, { plugins = {
      "nvim-ts-willrename",
      "typescript-tools.nvim",
      "nvim-lsp-file-operations",
    }})
  end
end

---Guard: ensure new path is inside primary root for the file (if configured).
function M.guard_root(old_abs, new_abs)
  local cfgv = cfg()
  if not (cfgv.respect_root and cfgv.respect_root ~= false) then return true end
  local rel = (M.clients_for_path(old_abs) or {})[1]
  local root = rel and rel.config and rel.config.root_dir and path.norm_path(rel.config.root_dir) or nil
  if root and not path.startswith(new_abs, root) then
    local msg = ("New path is outside LSP root: %s"):format(root)
    vim.schedule(function()
      vim.notify(msg, cfgv.respect_root == "error" and vim.log.levels.ERROR or vim.log.levels.WARN)
    end)
    return cfgv.respect_root ~= "error"
  end
  return true
end

return M

