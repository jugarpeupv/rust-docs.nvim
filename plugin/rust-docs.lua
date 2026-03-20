-- plugin/rust-docs.lua
-- Loaded automatically by Neovim's plugin loader.
-- Defers setup to prevent startup cost; user must call require("rust-docs").setup().

if vim.g.loaded_rust_docs then
  return
end
vim.g.loaded_rust_docs = true

-- Require Neovim 0.10+ for vim.system
if vim.fn.has("nvim-0.10") == 0 then
  vim.notify(
    "rust-docs.nvim requires Neovim >= 0.10",
    vim.log.levels.WARN
  )
  return
end
