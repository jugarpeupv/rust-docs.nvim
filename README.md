# rust-docs.nvim

Fuzzy-search the Rust standard library documentation inside Neovim.

Opens a Telescope or Snacks picker, fetches the selected item's HTML page from
`doc.rust-lang.org`, and renders it as a navigable, buflisted Markdown buffer.

## Requirements

- Neovim >= 0.10
- `curl` on `$PATH`
- [telescope.nvim](https://github.com/nvim-telescope/telescope.nvim) **or** [snacks.nvim](https://github.com/folke/snacks.nvim) (with `picker` enabled)

## Installation

### lazy.nvim

```lua
{
  "your-username/rust-docs.nvim",
  dependencies = {
    -- Pick one:
    "nvim-telescope/telescope.nvim",
    -- or "folke/snacks.nvim",
  },
  opts = {},  -- uses defaults; see Configuration below
}
```

### packer.nvim

```lua
use {
  "your-username/rust-docs.nvim",
  requires = { "nvim-telescope/telescope.nvim" },
  config = function()
    require("rust-docs").setup()
  end,
}
```

## Usage

| Command / Keymap        | Action                                          |
|-------------------------|-------------------------------------------------|
| `<leader>rd`            | Open the fuzzy picker                           |
| `:RustDocs`             | Same as above                                   |
| `:RustDocs refresh`     | Re-download the search index, then open picker  |

### Inside the doc buffer

| Key   | Action                        |
|-------|-------------------------------|
| `]]`  | Jump to next section          |
| `[[`  | Jump to previous section      |
| `gx`  | Open current doc in browser   |
| `R`   | Reload / re-fetch this page   |
| `q`   | Close the buffer              |

### Inside the picker

| Key      | Action                    |
|----------|---------------------------|
| `<CR>`   | Open in current window    |
| `<C-s>`  | Open in horizontal split  |
| `<C-v>`  | Open in vertical split    |
| `<C-t>`  | Open in new tab           |

## Configuration

```lua
require("rust-docs").setup({
  -- Directory for caching the search index (~4 MB download, cached 1 week)
  cache_dir = vim.fn.stdpath("cache") .. "/rust-docs",

  -- Base URL for fetching docs (change for offline / custom rustdoc builds)
  base_url = "https://doc.rust-lang.org/std",

  -- Picker backend: "telescope" | "snacks" | "auto" (auto-detects)
  picker = "auto",

  -- How to open the doc buffer: "current" | "split" | "vsplit" | "tab"
  open_mode = "current",

  -- Seconds before the cached index is considered stale (default: 1 week)
  index_ttl = 60 * 60 * 24 * 7,

  keymaps = {
    open         = "<leader>rd",  -- global keymap to open picker
    section_next = "]]",          -- buffer-local: next section
    section_prev = "[[",          -- buffer-local: prev section
    open_browser = "gx",          -- buffer-local: open in browser
  },
})
```

## How it works

1. **Search index** — On first open, `curl` downloads `search-index.js` from
   `doc.rust-lang.org/std`. This is the same index the browser's search box
   uses. It is cached under `cache_dir` and reused for `index_ttl` seconds.

2. **Picker** — The index is parsed into a flat list of items (`name`, `path`,
   `kind`, `desc`). The list is fed into Telescope or Snacks for fuzzy search.

3. **Doc buffer** — Selecting an item fetches its HTML page with `curl`,
   strips the HTML into structured Markdown-like text (description, inherent
   implementations, trait implementations, etc.), and writes the result into a
   named, buflisted buffer (`rust-docs://std::net::TcpListener`).

   Re-visiting the same item reuses the existing buffer without re-fetching.

## Limitations / known issues

- Only the `std` crate is currently indexed. `core`, `alloc`, and third-party
  crates from `docs.rs` are planned.
- The HTML renderer is pattern-based, not a proper DOM parser. Rare edge cases
  in rustdoc output may produce malformed sections.
- Requires an internet connection (or a local `rustdoc` mirror via `base_url`).
