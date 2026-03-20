--- rust-docs.nvim — main public API
--- Entry point for all external interaction with the plugin.

local M = {}

--- Detect which picker backend is available.
---@return "telescope"|"snacks"|nil
local function detect_picker()
  local cfg = require("rust-docs.config").options
  if cfg.picker ~= "auto" then
    return cfg.picker
  end
  if pcall(require, "telescope") then
    return "telescope"
  end
  if pcall(require, "snacks") then
    return "snacks"
  end
  return nil
end

--- Open the fuzzy picker. Fetches the search index if needed (cached after first load).
function M.open()
  local index = require("rust-docs.search.index")
  index.get_items(function(err, items)
    if err then
      vim.notify(err, vim.log.levels.ERROR)
      return
    end

    local backend = detect_picker()
    if backend == "telescope" then
      require("rust-docs.pickers.telescope").open(items)
    elseif backend == "snacks" then
      require("rust-docs.pickers.snacks").open(items)
    else
      vim.notify(
        "rust-docs: no picker found. Install telescope.nvim or snacks.nvim",
        vim.log.levels.ERROR
      )
    end
  end)
end

--- Force refresh of the cached search index, then open the picker.
function M.refresh()
  local index = require("rust-docs.search.index")
  index.refresh(function(err)
    if err then
      vim.notify(err, vim.log.levels.ERROR)
      return
    end
    M.open()
  end)
end

--- Setup the plugin with user configuration.
---@param opts? RustDocs.Config
function M.setup(opts)
  require("rust-docs.config").setup(opts)

  local config = require("rust-docs.config").options

  -- Register the global keymap
  if config.keymaps.open and config.keymaps.open ~= "" then
    vim.keymap.set("n", config.keymaps.open, M.open, {
      desc    = "rust-docs: open picker",
      silent  = true,
      noremap = true,
    })
  end

  -- Register user commands
  vim.api.nvim_create_user_command("RustDocs", function(args)
    local sub = args.args:match("^(%S+)")
    if sub == "refresh" then
      M.refresh()
    else
      M.open()
    end
  end, {
    nargs = "?",
    complete = function()
      return { "refresh" }
    end,
    desc = "Open Rust documentation picker (or :RustDocs refresh to re-download index)",
  })
end

return M
