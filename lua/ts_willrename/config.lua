---@class TSWillRenameOpts
---@field silent_apply boolean            -- apply edits without opening windows
---@field autosave boolean                -- write modified buffers after edits
---@field wipe_unlisted boolean           -- wipe temp unlisted buffers when clean
---@field notify_did_rename boolean       -- send workspace/didRenameFiles if supported
---@field respect_root boolean|string     -- true|"warn"|"error"|false
---@field encoding '"utf-16"'|'"utf-8"'   -- LSP edit encoding
---@field ignore (string|fun(path:string):boolean)[]  -- drop edits for matching paths
---@field debug boolean                   -- verbose :messages

local M = {}

---@type TSWillRenameOpts
local cfg = {
  silent_apply      = true,
  autosave          = false,
  wipe_unlisted     = false,
  notify_did_rename = true,
  respect_root      = "warn",
  encoding          = "utf-16",
  ignore            = {},   -- e.g. { "/types/", "/dist/" }
  debug             = false,
}

function M.setup(user)
  cfg = vim.tbl_deep_extend("force", cfg, user or {})
end

function M.get()
  return cfg
end

local function _fmt(...)
  return table.concat(vim.tbl_map(function(x)
    return type(x) == "table" and vim.inspect(x) or tostring(x)
  end, {...}), " ")
end

function M.log(...)
  vim.notify(_fmt(...), vim.log.levels.INFO)
end

function M.dlog(...)
  if cfg.debug then M.log(...) end
end

return M

