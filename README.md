# nvim-ts-willrename

Project-wide **safe file rename** for TypeScript/JavaScript using LSP
`workspace/willRenameFiles` + **silent** WorkspaceEdit apply + **in-place** buffer rename.
Fixes imports across your project without popping open a bunch of buffers.

> Works great with `pmizio/typescript-tools.nvim`.
> If your TS client doesn’t expose file operations by default, you can merge capabilities from `antosha417/nvim-lsp-file-operations` (see **Setup**).

---

## Features

* 🔁 Calls `workspace/willRenameFiles` and applies returned edits
* 💤 **Silent** edit application (no extra windows; unlisted temp buffers)
* 📝 **In-place** buffer rename (`:file {new}` + write) – no “old” buffer left behind
* 💾 Optional autosave of modified buffers and cleanup of unlisted buffers
* 📣 Optional `workspace/didRenameFiles` notification
* 🧭 Optional guard to warn if new path is outside current LSP root (monorepos)
* ⚙️ Minimal config, no external binaries

---

## Installation (lazy.nvim)

```lua
-- nvim-ts-willrename
{
  "<your-username>/nvim-ts-willrename",
  main = "ts_willrename",  -- so `require("ts_willrename")` auto-loads
  cmd = { "TSWillRename" }, -- optional
  keys = {
    { "<leader>mm", function() require("ts_willrename").rename() end,
      desc = "TS: rename file (fix imports)" },
  },
  opts = {
    silent_apply  = true,   -- apply edits without opening windows
    autosave      = true,   -- write modified buffers
    wipe_unlisted = true,   -- delete temp, unlisted buffers after save
    respect_root  = "warn", -- "warn" | "error" | true(=warn) | false
    encoding      = "utf-16",
    -- NEW: skip edits in generated folders, etc.
    ignore        = { "/types/", "/dist/", "/build/" },
  },
}
```

### Make sure your TS client exposes file operations

With **typescript-tools**:

```lua
local base  = vim.lsp.protocol.make_client_capabilities()
local caps  = require("lsp-file-operations").default_capabilities()  -- from antosha417/nvim-lsp-file-operations
local merged = vim.tbl_deep_extend("force", base, caps)

require("typescript-tools").setup({
  capabilities = merged,
  -- your other options...
})
```

> If you don’t want the dependency, you can manually set:
>
> ```lua
> local caps = vim.lsp.protocol.make_client_capabilities()
> caps.workspace = caps.workspace or {}
> caps.workspace.fileOperations = {
>   willRename = {
>     filters = {
>       { scheme = "file", pattern = { glob = "**/*.{ts,tsx,js,jsx,mts,cts,mjs,cjs}", matches = "file" } },
>       { scheme = "file", pattern = { glob = "**/*", matches = "folder" } },
>     },
>   },
> }
> require("typescript-tools").setup({ capabilities = caps })
> ```

---

## Usage

* Run `:TSWillRename` inside a TS/JS buffer → enter a new **path** for the current file.
* The plugin:

  1. Requests `workspace/willRenameFiles`
  2. Applies edits (silently by default)
  3. Renames the **current buffer in place** and writes it to disk
  4. (Optional) Sends `workspace/didRenameFiles`, autosaves, cleans up unlisted buffers

### Keymap example

```lua
vim.keymap.set("n", "<leader>mm", "<cmd>TSWillRename<CR>",
  { desc = "TS: rename file (fix imports)" })
```

---

## Options

```lua
require("ts_willrename").setup({
  silent_apply      = true,     -- use silent workspace edit applier
  autosave          = true,     -- write modified buffers after edits
  wipe_unlisted     = true,     -- wipe temp, unlisted buffers that are clean
  notify_did_rename = true,     -- send workspace/didRenameFiles when supported
  respect_root      = "warn",   -- "warn" | "error" | true(=warn) | false
  encoding          = "utf-16", -- encoding for LSP edits
  debug             = false,    -- log willRename flow to :messages

  -- NEW: ignore edits for matching paths.
  -- Items can be plain substrings (fast) or predicates (path -> boolean).
  ignore            = {
    "/types/", "/dist/", "/build/",
    -- function(p) return p:match("%.d%.ts$") ~= nil end, -- example: ignore *.d.ts
  },
})
```

### Ignoring generated folders

If your build generates artifacts (e.g. types/**, dist/**), you probably
don’t want import updates written there. Set ignore so WorkspaceEdit entries
targeting those paths are dropped. Notes:

* Paths are normalized internally (C:/.../path with forward slashes),
so write patterns with / (not \) even on Windows.

* Predicates receive an absolute normalized path.

Examples:

```lua
-- simple substrings
ignore = { "/types/", "/dist/", "/build/" }

-- mix substrings & predicates
ignore = {
  "/dist/",
  function(p) return p:match("%.d%.ts$") ~= nil end,  -- ignore declaration files
}
```

---

## Requirements

* Neovim **0.8+**
* A TS LSP that **supports** `workspace/willRenameFiles`
  (Recommended: `pmizio/typescript-tools.nvim` + capabilities from
  `antosha417/nvim-lsp-file-operations`.)

---

## Minimal API (for scripting)

```lua
require("ts_willrename").setup({ silent_apply = true })

-- Trigger programmatically:
require("ts_willrename").rename()
```

## nvim-tree integration

Bind TS-aware rename to `r` in nvim-tree:

```lua
{
  "nvim-tree/nvim-tree.lua",
  opts = function(_, opts)
    require("ts_willrename.integrations.nvim_tree").setup({
      extensions = { "ts", "tsx", "js", "jsx", "mts", "cts", "mjs", "cjs" }, -- optional filter
    })
    return opts
  end,
}
```

---

## Development & Tests (with `just`)

This repo includes **plenary+busted** integration tests and a cross-platform `Justfile`.

### Justfile usage

```sh
just test        # run all specs
just test-file tests/ts_willrename_rename_paths_spec.lua
```

It runs Neovim headless with `tests/minimal_init.lua` and executes:

* `PlenaryBustedDirectory tests/`
* or `PlenaryBustedFile <spec>`

Override Neovim path if needed:

```sh
NVIM="/path/to/nvim" just test
```

### Manual run (without just)

```sh
nvim --headless -u tests/minimal_init.lua \
  -c "PlenaryBustedDirectory tests/" \
  -c "qa!"
```

---

## Troubleshooting

* No import updates: ensure your TS LSP supports workspace/willRenameFiles
and is attached to the project. Opening a TS file once or using the nvim-tree
integration fixes this.

* Edits still appear in generated output: check that ignore patterns use
forward slashes and include the relevant segment (e.g. "/types/").

* “New path is outside LSP root”: adjust respect_root or rename within the
server’s root_dir.

* require("ts_willrename") doesn’t load: set main = "ts_willrename" in
the plugin spec.

---

## License

MIT. See [LICENSE](./LICENSE).

