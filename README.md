# rust-docs.nvim

Browse Rust documentation — `std` and external crates from `docs.rs` — from
inside Neovim using a fuzzy picker (Telescope or Snacks). Fetches rustdoc HTML
and renders it as a navigable, buflisted Markdown buffer with signatures,
descriptions, and implementation listings.

## Requirements

- Neovim >= 0.10
- `curl` on `$PATH`
- [telescope.nvim](https://github.com/nvim-telescope/telescope.nvim) **or** [snacks.nvim](https://github.com/folke/snacks.nvim) (with `picker` enabled)
- A `nightly` (or stable) Rust toolchain installed via `rustup` with the `rust-docs` component

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

| Command / Keymap        | Action                                                               |
|-------------------------|----------------------------------------------------------------------|
| `<leader>rd`            | Open picker — jumps straight to items if a source is remembered      |
| `:RustDocs`             | Same as `<leader>rd`                                                 |
| `:RustDocs source`      | Resets session memory and opens the source picker                    |
| `:RustDocs refresh`     | Rebuild the std index from local rustdoc, then open                  |

### Session memory

After you pick a source (std or an external crate + version), **rust-docs.nvim
remembers it for the rest of the Neovim session**. The next time you press
`<leader>rd` the source picker is skipped and you land directly in the item
fuzzy-finder, already scoped to your crate.

Use `<C-b>` **inside the item picker** (or `:RustDocs source`) whenever you
want to switch to a different crate or back to `std`.

### Flow

1. **First open** — `<leader>rd` shows the source picker (std / pinned crates /
   Search crates.io…). After picking, the source is remembered.
2. **Subsequent opens** — `<leader>rd` goes directly to the item picker for the
   remembered source. The picker title shows the active crate and version.
3. **Switch source** — press `<C-b>` from within the item picker to forget the
   memory and show the source picker.

### Inside the item picker

| Key      | Action                                      |
|----------|---------------------------------------------|
| `<CR>`   | Open selected item in current window        |
| `<C-s>`  | Open in horizontal split                    |
| `<C-v>`  | Open in vertical split                      |
| `<C-t>`  | Open in new tab                             |
| `<C-b>`  | Forget remembered source, open source picker|
| `<C-e>`  | Open the crate's root index page (no item)  |

`<C-e>` is only active when browsing an external crate (not std). It fetches
`https://docs.rs/<crate>/<version>/<crate>/` and renders it as a buffer — useful
when you just want a high-level overview without drilling into a specific item.

### Inside the doc buffer

| Key   | Action                        |
|-------|-------------------------------|
| `]]`  | Jump to next section          |
| `[[`  | Jump to previous section      |
| `gx`  | Open current doc in browser   |
| `R`   | Reload / re-fetch this page   |
| `q`   | Close the buffer              |

## Configuration

```lua
require("rust-docs").setup({
  -- Picker backend: "telescope" | "snacks" | "auto" (auto-detects)
  picker = "auto",

  -- How to open the doc buffer: "current" | "split" | "vsplit" | "tab"
  open_mode = "current",

  -- When true, show a version picker before loading an external crate's items.
  -- When false, always use the latest stable version automatically.
  prompt_version = true,

  -- Crates that always appear at the top of the source picker (by crate name).
  -- Example: pinned_crates = { "serde", "tokio", "anyhow" }
  pinned_crates = {},

  keymaps = {
    -- Global: open picker (re-uses remembered source if set)
    open             = "<leader>rd",
    -- Picker-local: forget remembered source and re-open the source picker
    clear_source     = "<C-b>",
    -- Picker-local: open the crate's root index page without picking an item
    open_crate_index = "<C-e>",
    -- Buffer-local navigation
    section_next     = "]]",
    section_prev     = "[[",
    open_browser     = "gx",
  },
})
```

## How it works

### std

The local rustdoc JSON file installed by `rustup` (`std.json`, ~11 MB) is
parsed once and cached at `~/.cache/nvim/rust-docs/items.json`. The cache
includes top-level items and all methods extracted from impl blocks. Run
`:RustDocs refresh` to rebuild the cache (e.g. after updating your toolchain).

### External crates

When you search for a crate name in the source picker, `rust-docs.nvim` queries
the crates.io API live (debounced). Selecting a crate downloads its rustdoc JSON
from `docs.rs` (gzip-compressed), extracts all public items and their methods,
and feeds them into the item picker. The raw JSON is cached locally so
subsequent opens of the same crate version are instant.

### Doc buffer

Selecting an item fetches its HTML page with `curl`, then:

- Extracts the item title from `<h1>`.
- Extracts the full **signature** from `<pre class="rust item-decl">`, including
  `where` clauses.
- Extracts the top-level **description** from the first `<div class="docblock">`.
- Extracts **Implementations**, **Trait Implementations**, **Auto Trait
  Implementations**, and **Blanket Implementations** from the impl-toggle
  `<details>` blocks, showing each method's signature and first doc line.

The result is written to a named, buflisted buffer
(`rust-docs://serde_json::Value`). Re-visiting the same item reuses the existing
buffer without re-fetching.

## Limitations / known issues

- The HTML renderer is pattern-based, not a DOM parser. Rare edge cases in
  rustdoc output may produce malformed sections.
- Requires an internet connection for external crates (or a local mirror).
- `core` and `alloc` are not separately indexed; their re-exported items appear
  under `std`.
