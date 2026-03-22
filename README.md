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

| Command / Keymap    | Action                                                          |
|---------------------|-----------------------------------------------------------------|
| `<leader>rd`        | Open picker — jumps straight to items if a source is remembered |
| `:RustDocs`         | Same as `<leader>rd`                                            |
| `:RustDocs source`  | Reset session memory and open the source picker                 |
| `:RustDocs refresh` | Rebuild the std index from local rustdoc, then open             |

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

Items are ordered by kind (types first, callables last), then alphabetically
within each kind. Fuzzy scoring takes over as you type.

| Key     | Action                                       |
|---------|----------------------------------------------|
| `<CR>`  | Open selected item in current window         |
| `<C-s>` | Open in horizontal split                     |
| `<C-v>` | Open in vertical split                       |
| `<C-t>` | Open in new tab                              |
| `<C-b>` | Forget remembered source, open source picker |
| `<C-e>` | Open the crate's root index page (no item)   |

`<C-e>` is only shown in the picker title and only active when browsing an
external crate (not std). `<C-b>` is also only active inside the item picker,
not globally.

When using Telescope, all standard actions work as expected — including sending
results to the quickfix list (`<C-q>` / `<M-q>`).

### Inside the doc buffer

The buffer is rendered as Markdown. Top-level sections (`# Signature`,
`# Description`, `# Implementations`, …) use `#` headings. Within the
description, any sub-headings from the original rustdoc page are preserved as
`##` / `###`. Impl block headers appear as `##` subheadings.

| Key  | Action                       |
|------|------------------------------|
| `]]` | Jump to next heading         |
| `[[` | Jump to previous heading     |
| `gx` | Open current doc in browser  |
| `gd` | Follow link under cursor     |
| `R`  | Reload / re-fetch this page  |
| `q`  | Close the buffer             |

`]]` / `[[` navigate across all heading levels (`#`, `##`, `###`).

Folds are enabled automatically (`foldmethod=expr`) using the Treesitter
markdown fold expression. All folds start open (`foldlevel=99`). Use `za` to
toggle a section fold.

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
    -- Buffer-local: follow a link under the cursor to its doc page
    go_to_doc        = "gd",
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

### Item ordering

Items in the picker are sorted by kind before fuzzy scoring kicks in:

| Priority | Kinds                                          |
|----------|------------------------------------------------|
| 1        | `mod`                                          |
| 2        | `struct`                                       |
| 3        | `enum`                                         |
| 4        | `trait`                                        |
| 5        | `typedef`                                      |
| 6        | `primitive`                                    |
| 7        | `macro`                                        |
| 8        | `const`                                        |
| 9        | `static`                                       |
| 10       | `fn`                                           |
| 11       | `method`                                       |

Within each kind, items are sorted alphabetically by their fully-qualified path.

### Doc buffer

Selecting an item fetches its HTML page with `curl` and renders it as Markdown:

- **Title** — from `<h1>`, rendered as `# Title`.
- **Signature** — from `<pre class="rust item-decl">`, rendered under `# Signature` as a fenced `rust` code block.
- **Description** — from the first `<div class="docblock">`, rendered under `# Description`. Sub-headings from the original rustdoc page (`<h2>`, `<h3>`) are preserved as `##` / `###` headings.
- **Implementations** — rendered under `# Implementations` (and `# Trait Implementations`, etc.). Each `impl` block is a `##` subheading; method signatures are fenced code blocks.
- **Crate index sections** (Modules, Structs, Functions, …) — present on crate/module index pages, each as a `# Section` heading with an aligned item list.

The result is written to a named, buflisted buffer
(`rust-docs://serde_json::Value`). Re-visiting the same item reuses the existing
buffer without re-fetching.

## Limitations / known issues

- The HTML renderer is pattern-based, not a DOM parser. Rare edge cases in
  rustdoc output may produce malformed sections.
- Requires an internet connection for external crates (or a local mirror).
- `core` and `alloc` are not separately indexed; their re-exported items appear
  under `std`.
