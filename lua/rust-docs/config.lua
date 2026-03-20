local M = {}

---@class RustDocs.Config
---@field cache_dir string        Directory where the search index is cached
---@field base_url string         Base URL for fetching docs
---@field picker string           "telescope" | "snacks" | "auto"
---@field open_mode string        "current" | "split" | "vsplit" | "tab"
---@field keymaps RustDocs.Keymaps
---@field index_ttl number        Seconds before cached index is considered stale (default 1 week)

---@class RustDocs.Keymaps
---@field open string             Keymap to open the picker
---@field section_next string     Jump to next section in doc buffer
---@field section_prev string     Jump to previous section in doc buffer
---@field open_browser string     Open current doc in browser

---@type RustDocs.Config
M.defaults = {
  cache_dir = vim.fn.stdpath("cache") .. "/rust-docs",
  base_url = "https://doc.rust-lang.org/std",
  picker = "auto",
  open_mode = "current",
  index_ttl = 60 * 60 * 24 * 7, -- 1 week
  keymaps = {
    open = "<leader>rd",
    section_next = "]]",
    section_prev = "[[",
    open_browser = "gx",
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
