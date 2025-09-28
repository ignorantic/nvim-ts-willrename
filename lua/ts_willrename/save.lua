local cfg = require("ts_willrename.config").get
local path = require("ts_willrename.util.path")

local M = {}

local function uniq(list)
  local out, seen = {}, {}
  for _, v in ipairs(list or {}) do
    if v and not seen[v] then seen[v] = true; table.insert(out, v) end
  end
  return out
end

local function write_buf_force(buf)
  vim.api.nvim_buf_call(buf, function()
    vim.cmd("noautocmd silent! keepalt keepjumps write!")
  end)
  if not vim.bo[buf].modified then return true end
  local name = vim.api.nvim_buf_get_name(buf)
  if name == "" then return false end
  local ok = pcall(vim.fn.writefile, vim.api.nvim_buf_get_lines(buf, 0, -1, true), name)
  if ok then vim.bo[buf].modified = false end
  return ok
end

function M.autosave_and_cleanup(touched)
  local cfgv = cfg()
  if not (cfgv.autosave or cfgv.wipe_unlisted) then return end
  for _, buf in ipairs(uniq(touched)) do
    if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].buftype == "" then
      if cfgv.autosave
        and vim.bo[buf].modified
        and not vim.bo[buf].readonly
        and vim.bo[buf].modifiable
        and not path.norm_path(vim.api.nvim_buf_get_name(buf)):find("/types/")  -- safety net; real filter happens earlier
      then
        write_buf_force(buf)
      end
      if cfgv.wipe_unlisted and not vim.bo[buf].buflisted and not vim.bo[buf].modified then
        pcall(vim.api.nvim_buf_delete, buf, { force = false })
      end
    end
  end
end

return M

