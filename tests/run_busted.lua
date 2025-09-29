-- Run each *_spec.lua in a separate headless Neovim process.
-- This avoids busted's auto-:qall! killing our loop.

local scan = require("plenary.scandir")

-- Collect spec files
local files = scan.scan_dir("tests/spec", {
  add_dirs = false,
  depth = 50,
  search_pattern = "_spec%.lua$",
})

-- Normalize & sort
for i, f in ipairs(files) do files[i] = (f or ""):gsub("\\", "/") end
table.sort(files)
if #files == 0 then error("No spec files found under tests/spec") end

-- Absolute path to minimal init (to be robust on Windows)
local init = vim.fn.fnamemodify("tests/minimal_init.lua", ":p"):gsub("\\", "/")

-- nvim binary (assume in PATH; customize via NVIM env if needed)
local NVIM = os.getenv("NVIM") or "nvim"

local function shell_quote(s)
  -- Quote for both PowerShell/CMD and POSIX-ish shells
  -- We wrap with double quotes and escape embedded double quotes
  return '"' .. tostring(s):gsub('"', '\\"') .. '"'
end

local failures = 0

for _, spec in ipairs(files) do
  local cmd = table.concat({
    NVIM, "--headless",
    "-u", shell_quote(init),
    "-c", shell_quote(("lua require('plenary.busted').run(%q)"):format(spec)),
    "-c", shell_quote("qa!"),
  }, " ")

  -- Run child process; os.execute returns true/n == 0 on success (LuaJIT semantics vary)
  io.stdout:write("\n==> ", spec, "\n")
  local ok, why, code = os.execute(cmd)
  local exit_ok =
    (type(ok) == "number" and ok == 0) or
    (type(ok) == "boolean" and ok) or
    (why == "exit" and code == 0)

  if not exit_ok then
    failures = failures + 1
    io.stderr:write("[busted] spec failed: ", spec, "\n")
  end
end

if failures > 0 then
  error(("Some specs failed: %d"):format(failures))
end

