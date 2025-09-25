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

## Requirements

* Neovim **0.8+**
* A TS LSP that **supports** `workspace/willRenameFiles`
  (Recommended: `pmizio/typescript-tools.nvim` + capabilities from
  `antosha417/nvim-lsp-file-operations`.)

---

## Installation (lazy.nvim)

```lua
{
  "ignorantic/nvim-ts-willrename",
  -- Optional but recommended if your client doesn’t announce fileOperations:
  dependencies = { "antosha417/nvim-lsp-file-operations" },
  config = function()
    require("ts_willrename").setup({
      -- defaults shown
      silent_apply      = true,   -- apply edits without opening windows
      autosave          = false,  -- write modified buffers after edits
      wipe_unlisted     = false,  -- wipe unlisted buffers after saving
      notify_did_rename = true,   -- send workspace/didRenameFiles
      respect_root      = true,   -- warn if new path is outside LSP root
      encoding          = "utf-16",
    })
  end,
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

| Option              | Type                  | Default    | Description                                                                                           |
| ------------------- | --------------------- | ---------- | ----------------------------------------------------------------------------------------------------- |
| `silent_apply`      | boolean               | `true`     | Apply LSP edits without opening windows; affected buffers are loaded unlisted and not shown in `:ls`. |
| `autosave`          | boolean               | `false`    | Automatically `:write` modified normal buffers after edits.                                           |
| `wipe_unlisted`     | boolean               | `false`    | Wipe unlisted temp buffers after saving (frees memory / keeps buffer list clean).                     |
| `notify_did_rename` | boolean               | `true`     | Notify clients with `workspace/didRenameFiles` after a successful rename.                             |
| `respect_root`      | boolean               | `true`     | Warn if the target path is outside the current LSP root (helpful in monorepos).                       |
| `encoding`          | `"utf-16"`\|`"utf-8"` | `"utf-16"` | Position encoding used by TS edits (TS uses UTF-16).                                                  |

---

## Commands

* `:TSWillRename` – Interactive rename for the **current** file (prompts for new path).

---

## Monorepo tips

* Keep renames **inside** the active client’s root (`:LspInfo` → `Root directory`).
  Cross-package renames may not produce edits if the other package isn’t part of the same TS project.
* Prefer **Project References** (`composite: true`, `references: [...]`) so the server “sees” dependent packages.
* If you must rename across roots, disable `respect_root` or attach an LSP at monorepo root.

---

## Troubleshooting

* **“No client handled `workspace/willRenameFiles`”**
  Your TS client doesn’t advertise fileOperations. Merge capabilities (see **Setup**) or set them manually.
* **Edits apply but buffers pop up**
  Ensure `silent_apply = true`. If some plugin still opens windows via autocmds, file an issue with details.
* **Old buffer remains / new file opens separately**
  This plugin renames the **current buffer in place**. If you still see the old buffer, check for custom autocmds or save-hooks that reopen files.

---

## Minimal API (for scripting)

```lua
require("ts_willrename").setup({ silent_apply = true })

-- Trigger programmatically:
require("ts_willrename").rename()
```

---

## License

MIT. See [LICENSE](./LICENSE).

---

If you want, tell me your GitHub username and repo name and I’ll tailor the install snippet (`"ignorantic/nvim-ts-willrename"`) and add a short badge block.

