local M = {}

---@class RustDocs.Config
---@field cache_dir string          Directory where the search index is cached
---@field base_url string           Base URL for fetching std docs
---@field picker string             "telescope" | "snacks" | "auto"
---@field open_mode string          "current" | "split" | "vsplit" | "tab"
---@field keymaps RustDocs.Keymaps
---@field index_ttl number          Seconds before cached index is considered stale (default 1 week)
---@field prompt_version boolean    Ask for a crate version before browsing (default false, uses latest). Use select_version keymap to change it later.
---@field pinned_crates string[]    Crates to always show at the top of the source picker.

---@class RustDocs.Keymaps
---@field open string               Keymap to open the picker (respects session memory)
---@field clear_source string       Keymap to forget the remembered crate and open the source picker
---@field open_crate_index string   Keymap (inside item picker) to open the crate's top-level index page
---@field select_version string     Keymap (inside item picker, crates only) to pick another version
---@field go_to_doc string          Buffer-local: follow link in current window
---@field follow_link string        Buffer-local: follow link in current window (default <CR>)
---@field follow_link_split string  Buffer-local: follow link in horizontal split
---@field follow_link_vsplit string Buffer-local: follow link in vertical split
---@field section_next string       Jump to next section in doc buffer
---@field section_prev string       Jump to previous section in doc buffer
---@field open_browser string       Open current doc in browser

---@type RustDocs.Config
M.defaults = {
  cache_dir = vim.fn.stdpath("cache") .. "/rust-docs",
  base_url = "https://doc.rust-lang.org/std",
  picker = "auto",
  open_mode = "current",
  index_ttl = 60 * 60 * 24 * 7, -- 1 week
  prompt_version = false,
  pinned_crates = {},
  keymaps = {
    -- Global: open picker (re-uses remembered source if set)
    open             = "<leader>rd",
    -- Picker-local: forget remembered source and re-open the source picker
    clear_source     = "<C-b>",
    -- Picker-local: open the crate's root index page without picking an item
    open_crate_index = "<C-o>",
    -- Picker-local (crates only): open the version picker for the current crate
    select_version   = "<C-e>",
    -- Buffer-local: follow the link on the current line to its doc page
    go_to_doc        = "gd",
    -- Buffer-local: same as go_to_doc (current window)
    follow_link        = "<CR>",
    -- Buffer-local: follow link in a split
    follow_link_split  = "<C-s>",
    follow_link_vsplit = "<C-v>",
    -- Buffer-local navigation
    section_next     = "]]",
    section_prev     = "[[",
    open_browser     = "gx",
  },
}

---@type RustDocs.Config
M.options = {}

---@param opts? RustDocs.Config
function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", M.defaults, opts or {})
  -- Ensure cache directory exists
  vim.fn.mkdir(M.options.cache_dir, "p")
end

return M
