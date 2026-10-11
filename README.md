# micron.nvim

Neovim support for **Micron**, the markup of Reticulum / Nomad Network page nodes, with a terminal preview that runs scripted pages. Port of the [rns-micron-vsix](rns://06a54b505bb67b25ef3f8097e8001edc/public/rns-micron-vsix) VS Code extension.

- `.mu` → `filetype=micron`: syntax highlighting, `>` section folding, `K` tag hints, omni completion with snippets
- Shebang Python pages stay `filetype=python`, with Micron tags highlighted inside triple-quoted strings
- Colour swatches on `` `Fxxx `` / `` `Bxxx ``; hex ↔ Micron conversion; wrap selection in bold/italic/underline/colour
- Diagnostics for unclosed links/fields, missing local `/page` and `/file` targets, and unterminated literal blocks
- Terminal preview: Micron colours, headings, alignment, dividers, tables, and literal blocks
  - Runs scripted pages (only under trusted node roots)
  - Follows links, edits and submits form fields, and refreshes partials
  - Back history, raw view, and live re-render as you type

Requires Neovim 0.11+. Turn on `termguicolors` for exact colours.

## Install

lazy.nvim:

```lua
{ "zer0pink/micron.nvim", lazy = false, opts = {} }
```

The plugin's only work at startup is setting up autocommands; everything else loads through `require`.

## Usage

1. Open a `.mu` page.
2. Run `:Micron preview`. The preview opens beside the page and focus stays in the editor.
3. Edit the page. The preview re-renders as you type and re-runs scripts on write.

In the preview window:

| Key | Action |
| --- | --- |
| `<CR>` | Follow a link, edit a field, or toggle a checkbox/radio |
| `<Tab>` / `<S-Tab>` | Next / previous link or field |
| `<BS>` | Back |
| `r` / `R` | Re-run / toggle raw markup |
| `F` / `C` | Edit / reset sticky fields |
| `q` / `g?` | Close / help |

Scripted pages run only under node roots you trust. The first time a page needs to run, the preview asks once per session. You can also run `:Micron trust` or `:Micron untrust`.

All commands are listed in `:help micron-commands`. The syntax cheat sheet is `:help micron-syntax`, or `:Micron reference`.

## Completion

Micron buffers use the plugin's `omnifunc`: type `` ` `` and press `<C-x><C-o>`. For blink.cmp:

```lua
sources = {
  per_filetype = { micron = { "micron", "snippets", "buffer" } },
  providers = { micron = { name = "Micron", module = "micron.blink" } },
}
```

`snippets/micron.json` is in VS Code format. LuaSnip's `from_vscode` loader and similar loaders find it through `package.json`.

## Configuration

Defaults are listed in `:help micron-config`. A few examples:

```lua
require("micron").setup({
  preview = {
    theme = "auto",              -- "dark" / "light" force the Micron palette
    split = "vertical",          -- "horizontal" | "tab"
    default_fields = { user = "me" },
    request_env = { link_id = "preview-link", remote_identity = "preview-identity" },
  },
  editor = { diagnostics = true, color_swatches = true },
})
```

## Development

```sh
nvim --clean --headless -l test/run.lua
```

`test/fixtures/reference.json` holds the outputs of the VS Code extension's `parseMicronHref`, `mergePreviewFields` and `isShebangScript`. The Lua tests assert that this plugin produces the same results. To regenerate it after changing the extension, run `test/gen-reference.js`; its header has the exact commands.

## Third-party

The renderer follows the state machine of [micron-parser-js](https://github.com/RFnexus/micron-parser-js) (Unlicense), which is derived from NomadNet's `MicronParser.py` by Mark Qvist.
