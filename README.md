# mlir-inc-previewer.nvim

A Neovim plugin that previews and manages MLIR `.inc` files inline — expand the
content of a TableGen-generated `#include "...inc"` directly into your buffer
(similar to `:r path/to/file.inc`, but tag-wrapped and reversible), so you can
read the generated declarations without leaving the file.

This is a Lua port of the
[MLIR Inc Previewer](https://github.com/ConvolutedDog/mlir-inc-previewer) VS Code
extension.

## Features

- Expand/collapse a single `.inc` include near the cursor, or expand all in the buffer.
- **Macro-aware** mode: drops `#ifdef`/`#if ...` blocks that are not active given
  the macros defined in the host file.
- **Macro-unaware** mode: expands the full `.inc` content as-is.
- `.inc` path resolution via the LSP (clangd) first, then a filesystem fallback.
- Expanded blocks are never written to disk (clean-on-save).
- Statusline component showing the number of open preview blocks.

## Requirements

- Neovim >= 0.9 (developed/tested on 0.11)
- An LSP such as `clangd` is recommended for accurate `.inc` path resolution.

## Installation

lazy.nvim / LazyVim:

```lua
{
  'ConvolutedDog/mlir-inc-previewer.nvim',
  event = { 'BufReadPre', 'BufNewFile' },
  -- Register commands so lazy loads the plugin (needed for :help too):
  cmd = {
    'MlirIncToggle', 'MlirIncToggleFull', 'MlirIncExpandAll',
    'MlirIncExpandAllFull', 'MlirIncClean', 'MlirIncCleanAndSave',
    'MlirIncNext', 'MlirIncHelp',
  },
  opts = {},
}
```

LazyVim: save the above as `~/.config/nvim/lua/plugins/mlir-inc-previewer.lua`.

packer.nvim:

```lua
use({
  'ConvolutedDog/mlir-inc-previewer.nvim',
  config = function() require('mlir-inc-previewer').setup() end,
})
```

## Configuration

`setup()` is optional for the commands, but required to enable keymaps and
clean-on-save. Defaults shown below:

```lua
require('mlir-inc-previewer').setup({
  -- File extensions the plugin attaches keymaps / clean-on-save to.
  extensions = {
    'c', 'cpp', 'cxx', 'h', 'hpp', 'hxx',   -- standard
    'cc', 'cp', 'c++', 'hh', 'hp', 'h++',   -- variants
    'inl', 'inc', 'ipp', 'tcc', 'tpp',      -- inline / template
    'def',                                  -- definitions
    'cu', 'cuh',                            -- CUDA
  },
  clean_on_save = true,   -- clean preview blocks before :write
  use_lsp = true,         -- resolve .inc paths via the LSP (clangd) when supported
  search_range = 3,       -- look this many lines above/below the cursor for an include
  deep_search = true,     -- last-resort recursive project search (disable on huge repos)
  keymaps = {
    toggle = '<leader>iu',          -- Expand/Collapse (macro-aware)
    toggle_full = '<leader>ij',     -- Expand/Collapse (macro-unaware)
    expand_all = '<leader>iy',      -- Expand all (macro-aware)
    expand_all_full = '<leader>ih', -- Expand all (macro-unaware)
    clean = '<leader>ic',           -- Clean all preview blocks
    next = '<leader>in',            -- Navigate to next preview block
  },
})
```

Set any keymap to `false` or `''` to disable it.

## Commands

| Command                 | Action                                              |
|-------------------------|-----------------------------------------------------|
| `:MlirIncToggle`        | Expand/Collapse preview near cursor (macro-aware)   |
| `:MlirIncToggleFull`    | Expand/Collapse preview near cursor (macro-unaware) |
| `:MlirIncExpandAll`     | Expand all previews (macro-aware)                   |
| `:MlirIncExpandAllFull` | Expand all previews (macro-unaware)                 |
| `:MlirIncClean`         | Remove all preview blocks                           |
| `:MlirIncCleanAndSave`  | Clean all preview blocks, then write the file       |
| `:MlirIncNext`          | Jump to the next preview block                      |

The cursor does not need to be exactly on the `#include` line; the plugin
searches +/-3 lines around the cursor and also recognises when the cursor is
inside an expanded preview block.

## Statusline

```lua
-- lualine example
sections = {
  lualine_x = { function() return require('mlir-inc-previewer').statusline() end },
}
```

## Testing

A headless smoke test is included:

```sh
nvim --headless -u NONE -c "set noswapfile" -c "set rtp+=." -c "luafile scripts/nvim_smoketest.lua"
```

## Performance & resolution notes

- `.inc` paths are resolved via the LSP only when an attached server actually
  supports `textDocument/definition`. If none does (e.g. clangd is not running),
  no error is shown and a filesystem fallback is used instead. For best accuracy
  and speed on MLIR projects, run **clangd**.
- `:MlirIncExpandAll` builds the whole result in memory and writes the buffer
  once, so it stays fast even for very large expansions (10k+ lines). The main
  remaining cost on huge buffers is your LSP/treesitter re-parsing the inserted
  text, which is outside this plugin's control.
- If the filesystem fallback feels slow on a very large repository, set
  `deep_search = false` and rely on the LSP for resolution.

## Help

Lazy-loaded plugins are not in `&rtp` until loaded, so `:help mlir-inc-previewer`
may fail with "no help" if the plugin has not started yet. Use either:

```
:MlirIncHelp
```

or load the plugin first, then open help:

```
:Lazy load mlir-inc-previewer.nvim
:help mlir-inc-previewer
```

Opening a C/C++ file (or any configured extension) also loads the plugin.
Helptags are generated automatically when the plugin starts.

## License

MIT — see [LICENSE](LICENSE).
