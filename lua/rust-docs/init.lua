--- rust-docs.nvim — main public API
--- Entry point for all external interaction with the plugin.

local M = {}

-- ---------------------------------------------------------------------------
-- Session memory
-- ---------------------------------------------------------------------------

--- The last source the user picked in this Neovim session.
--- @type { kind: "std" } | { kind: "crate", crate: RustDocs.Crate, version: string } | nil
M._last_source = nil

--- Forget the remembered source so the next M.open() shows the source picker.
function M.clear_source()
  M._last_source = nil
  vim.notify("rust-docs: source cleared — next open will show source picker", vim.log.levels.INFO)
end

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

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

--- Build a human-readable label for the current remembered source.
---@return string
local function source_label()
  local src = M._last_source
  if not src then return "" end
  if src.kind == "std" then return "std" end
  return src.crate.name .. " " .. src.version
end

--- Dispatch a live search picker for the given source.
--- Pickers own the search loop — they call index.search() on each keystroke.
--- `index_url` is the crate's root HTML page (nil for std).
---@param source { kind: "std" } | { kind: "crate", crate: RustDocs.Crate, version: string }
---@param index_url string|nil
local function open_live_picker(source, index_url)
  local backend = detect_picker()
  local title   = "Rust Docs — " .. source_label()
  if backend == "telescope" then
    require("rust-docs.pickers.telescope").open(source, title, index_url)
  elseif backend == "snacks" then
    require("rust-docs.pickers.snacks").open(source, title, index_url)
  else
    vim.notify(
      "rust-docs: no picker found. Install telescope.nvim or snacks.nvim",
      vim.log.levels.ERROR
    )
  end
end

-- ---------------------------------------------------------------------------
-- Crate flow
-- ---------------------------------------------------------------------------

--- Open the items picker for an external crate.
--- Skips the version picker if a version is already remembered or if
--- prompt_version = false.
---@param crate RustDocs.Crate
---@param forced_version string|nil  Pass a version to skip the picker
function M.open_crate(crate, forced_version)
  local cfg = require("rust-docs.config").options

  local function load_version(version)
    -- Remember this choice for the rest of the session
    M._last_source = { kind = "crate", crate = crate, version = version }

    local index_url = "https://docs.rs/" .. crate.name .. "/" .. version .. "/" .. crate.name .. "/"
    open_live_picker(M._last_source, index_url)
  end

  -- If a version was already decided (session memory or caller), skip the picker
  if forced_version then
    load_version(forced_version)
    return
  end

  if not cfg.prompt_version then
    load_version("latest")
    return
  end

  -- Fetch available versions, then show version picker
  local crate_mod = require("rust-docs.search.crates")
  crate_mod.get_versions(crate.name, function(err, versions)
    if err or not versions or #versions == 0 then
      vim.notify(
        "rust-docs: could not fetch versions for " .. crate.name .. ", using latest",
        vim.log.levels.WARN
      )
      load_version("latest")
      return
    end

    local backend = detect_picker()
    if backend == "telescope" then
      require("rust-docs.pickers.telescope").open_version(crate, versions, load_version)
    elseif backend == "snacks" then
      require("rust-docs.pickers.snacks").open_version(crate, versions, load_version)
    end
  end)
end

-- ---------------------------------------------------------------------------
-- Source picker
-- ---------------------------------------------------------------------------

--- Open the source picker (std + pinned crates + crates.io search).
--- Selecting std opens the std items picker directly.
--- Selecting a crate or searching opens the crate flow.
function M.open_source_picker()
  local cfg = require("rust-docs.config").options

  ---@return RustDocs.Source[]
  local function build_sources()
    ---@type RustDocs.Source[]
    local sources = {
      { kind = "std", label = "std  —  Rust Standard Library" },
    }
    for _, name in ipairs(cfg.pinned_crates or {}) do
      table.insert(sources, {
        kind  = "crate",
        label = name,
        crate = { name = name, version = "latest", description = "", downloads = 0 },
      })
    end
    table.insert(sources, {
      kind  = "search",
      label = "Search crates.io…",
    })
    return sources
  end

  local sources = build_sources()
  local backend = detect_picker()

  if backend == "telescope" then
    require("rust-docs.pickers.telescope").open_source(sources, function(source)
      M._handle_source(source)
    end)
  elseif backend == "snacks" then
    require("rust-docs.pickers.snacks").open_source(sources, function(source)
      M._handle_source(source)
    end)
  else
    vim.notify(
      "rust-docs: no picker found. Install telescope.nvim or snacks.nvim",
      vim.log.levels.ERROR
    )
  end
end

-- ---------------------------------------------------------------------------
-- Main entry point (respects session memory)
-- ---------------------------------------------------------------------------

--- Open rust-docs. If a source is remembered from this session, jump directly
--- to the item picker for that source. Otherwise show the source picker.
function M.open()
  local src = M._last_source

  if src == nil then
    -- No memory yet — show source picker
    M.open_source_picker()
    return
  end

  if src.kind == "std" then
    open_live_picker(src, nil)
    return
  end

  if src.kind == "crate" then
    -- Re-use remembered crate + version, skip all pickers
    M.open_crate(src.crate, src.version)
  end
end

-- ---------------------------------------------------------------------------
-- Internal: handle a selected source entry
-- ---------------------------------------------------------------------------

---@param source RustDocs.Source
function M._handle_source(source)
  if source.kind == "std" then
    -- Remember std as the session source
    M._last_source = { kind = "std" }
    open_live_picker(M._last_source, nil)

  elseif source.kind == "crate" then
    M.open_crate(source.crate, nil)

  elseif source.kind == "search" then
    local backend = detect_picker()
    if backend == "telescope" then
      require("rust-docs.pickers.telescope").open_crate_search(function(crate)
        M.open_crate(crate, nil)
      end)
    elseif backend == "snacks" then
      require("rust-docs.pickers.snacks").open_crate_search(function(crate)
        M.open_crate(crate, nil)
      end)
    end
  end
end

-- ---------------------------------------------------------------------------
-- Refresh
-- ---------------------------------------------------------------------------

--- Force refresh of the std cached search index, then open the picker.
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

--- Force re-download and re-parse of the currently active crate's index.
--- If the last source was std (or no source is set), falls back to M.refresh().
function M.refresh_crate()
  local src = M._last_source
  if not src or src.kind ~= "crate" then
    vim.notify("rust-docs: no crate source active — refreshing std index instead", vim.log.levels.INFO)
    M.refresh()
    return
  end
  local crates = require("rust-docs.search.crates")
  crates.refresh_crate(src.crate.name, src.version, function(err)
    if err then
      vim.notify(err, vim.log.levels.ERROR)
      return
    end
    M.open()
  end)
end

-- ---------------------------------------------------------------------------
-- Setup
-- ---------------------------------------------------------------------------

---@param opts? RustDocs.Config
function M.setup(opts)
  require("rust-docs.config").setup(opts)

  local config = require("rust-docs.config").options

  -- `open` keymap — respects session memory
  if config.keymaps.open and config.keymaps.open ~= "" then
    vim.keymap.set("n", config.keymaps.open, M.open, {
      desc    = "rust-docs: open picker (remembers last source)",
      silent  = true,
      noremap = true,
    })
  end

  -- User commands
  vim.api.nvim_create_user_command("RustDocs", function(args)
    local sub = args.args:match("^(%S+)")
    if sub == "refresh" then
      M.refresh()
    elseif sub == "refresh-crate" then
      M.refresh_crate()
    elseif sub == "source" then
      M.clear_source()
      M.open_source_picker()
    else
      M.open()
    end
  end, {
    nargs = "?",
    complete = function()
      return { "refresh", "refresh-crate", "source" }
    end,
    desc = "Open Rust docs picker (:RustDocs source | refresh | refresh-crate)",
  })
end

return M
