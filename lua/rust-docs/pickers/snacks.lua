--- Snacks.picker integration for Rust documentation search.
--- Requires folke/snacks.nvim with the picker module enabled.

local M = {}

--- Kind to highlight group mapping for display.
local KIND_HL = {
  ["fn"]        = "Function",
  ["method"]    = "Function",
  ["struct"]    = "Structure",
  ["enum"]      = "Type",
  ["trait"]     = "Interface",
  ["mod"]       = "Namespace",
  ["const"]     = "Constant",
  ["static"]    = "Constant",
  ["typedef"]   = "Type",
  ["macro"]     = "Macro",
  ["primitive"] = "Type",
  ["keyword"]   = "Keyword",
}

--- Require snacks or notify and return nil.
---@return table|nil
local function require_snacks()
  local ok, snacks = pcall(require, "snacks")
  if not ok or not snacks.picker then
    vim.notify("rust-docs: snacks.nvim (with picker) not found", vim.log.levels.ERROR)
    return nil
  end
  return snacks
end

--- Open the source picker (std | pinned crates | Search crates.io…).
---@param sources RustDocs.Source[]
---@param on_select fun(source: RustDocs.Source)
function M.open_source(sources, on_select)
  local snacks = require_snacks()
  if not snacks then return end

  local source_hl = {
    std    = "Special",
    crate  = "Function",
    search = "Comment",
  }

  local entries = {}
  for _, s in ipairs(sources) do
    local badge = s.kind == "std" and "[std]"
      or s.kind == "crate" and "[crate]"
      or "[search]"
    table.insert(entries, {
      text    = badge .. " " .. s.label,
      badge   = badge,
      hl      = source_hl[s.kind] or "Normal",
      _source = s,
    })
  end

  snacks.picker({
    title     = "Rust Docs — Select Source",
    items     = entries,
    format    = function(entry, _ctx)
      return {
        { string.format("%-10s", entry.badge), entry.hl },
        { "  " },
        { entry._source.label, "Normal" },
      }
    end,
    confirm   = function(picker, entry)
      picker:close()
      if entry and entry._source then
        on_select(entry._source)
      end
    end,
    previewer = false,
  })
end

--- Open a version picker for a crate.
---@param crate RustDocs.Crate
---@param versions string[]
---@param on_select fun(version: string)
function M.open_version(crate, versions, on_select)
  local snacks = require_snacks()
  if not snacks then return end

  local entries = {}
  for _, v in ipairs(versions) do
    table.insert(entries, {
      text     = v,
      label    = v,
      _version = v,
    })
  end

  snacks.picker({
    title     = "Rust Docs — " .. crate.name .. " — Select Version",
    items     = entries,
    format    = function(entry, _ctx)
      return { { entry.label, "Normal" } }
    end,
    confirm   = function(picker, entry)
      picker:close()
      if entry and entry._version then
        on_select(entry._version)
      end
    end,
    previewer = false,
  })
end

--- Open a live crates.io search picker.
--- Queries crates.io after a 300 ms debounce (not on every keystroke).
---@param on_select fun(crate: RustDocs.Crate)
function M.open_crate_search(on_select)
  local snacks = require_snacks()
  if not snacks then return end

  local CRATES_IO_UA  = "rust-docs.nvim/1.0 (Neovim plugin)"
  local DEBOUNCE_MS   = 300

  -- State shared across `source` invocations for the lifetime of this picker.
  local debounce_timer = nil   -- uv timer handle
  local inflight       = nil   -- vim.system handle (so we can kill stale requests)
  local request_seq    = 0     -- monotonic counter; lets the callback discard stale results
  local last_searched  = nil   -- last query that actually fired a network request

  snacks.picker({
    title     = "Search crates.io",
    -- `source(filter, cb)` is called by snacks on every filter change,
    -- including cursor navigation — so we must guard against re-firing when
    -- only the cursor moved and the query text is unchanged.
    source = function(filter, cb)
      local query = filter and filter.search or ""

      -- If the query hasn't changed (e.g. cursor up/down), do nothing —
      -- the existing results are still valid and should not be replaced.
      if query == last_searched then
        return
      end

      -- Cancel any pending debounce timer.
      if debounce_timer then
        debounce_timer:stop()
        debounce_timer:close()
        debounce_timer = nil
      end

      -- Kill any in-flight HTTP request so it does not deliver stale results.
      if inflight then
        pcall(function() inflight:kill(9) end)
        inflight = nil
      end

      if query == "" then
        last_searched = nil
        cb()
        return
      end

      -- Bump the sequence number; the callback checks it to discard old replies.
      request_seq = request_seq + 1
      local my_seq = request_seq

      -- Start a new debounce timer.
      debounce_timer = vim.uv.new_timer()
      debounce_timer:start(DEBOUNCE_MS, 0, vim.schedule_wrap(function()
        -- Timer fired — clean up handle.
        if debounce_timer then
          debounce_timer:close()
          debounce_timer = nil
        end

        -- Guard: query might have already been superseded.
        if my_seq ~= request_seq then
          cb()
          return
        end

        -- Mark this query as the one currently being searched.
        last_searched = query

        local url = "https://crates.io/api/v1/crates?q="
          .. vim.uri_encode(query)
          .. "&per_page=20&sort=downloads"

        inflight = vim.system(
          { "curl", "--silent", "--fail", "--location", "--compressed",
            "--user-agent", CRATES_IO_UA, url },
          { text = true },
          function(result)
            vim.schedule(function()
              inflight = nil

              -- Discard if a newer request has already been issued.
              if my_seq ~= request_seq then return end

              if result.code ~= 0 then
                cb()
                return
              end

              local ok, data = pcall(vim.json.decode, result.stdout,
                { luanil = { object = true, array = true } })
              if not ok or not data or not data.crates then
                cb()
                return
              end

              for _, c in ipairs(data.crates) do
                local crate = {
                  name        = c.name or "",
                  version     = c.newest_version or c.max_version or "latest",
                  description = (c.description or ""):gsub("\n", " "):sub(1, 120),
                  downloads   = c.downloads or 0,
                }
                cb({
                  text   = crate.name .. " " .. crate.description,
                  label  = crate.name,
                  ver    = crate.version,
                  desc   = crate.description,
                  _crate = crate,
                })
              end
              cb() -- signal completion
            end)
          end
        )
      end))
    end,

    format = function(entry, _ctx)
      return {
        { string.format("%-30s", (entry.label or "") .. "  " .. (entry.ver or "")), "Function" },
        { "  " },
        { (entry.desc or ""):sub(1, 80), "Comment" },
      }
    end,

    confirm = function(picker, entry)
      picker:close()
      if entry and entry._crate then
        on_select(entry._crate)
      end
    end,

    previewer = false,
  })
end

--- Open the Snacks picker with the given list of items.
---@param items RustDocs.Item[]
---@param title string          Picker title (e.g. "Rust Docs — serde_json 1.0.149")
---@param index_url string|nil  If set, open_crate_index keymap opens this URL
function M.open(items, title, index_url)
  local snacks = require_snacks()
  if not snacks then return end

  local buffer         = require("rust-docs.render.buffer")
  local cfg            = require("rust-docs.config").options
  local open_index_key = cfg.keymaps.open_crate_index or "<C-e>"
  local clear_src_key  = cfg.keymaps.clear_source

  -- Build actions table
  local actions = {
    open_split = function(picker, entry)
      picker:close()
      if entry and entry._item then
        local orig = require("rust-docs.config").options.open_mode
        require("rust-docs.config").options.open_mode = "split"
        buffer.open(entry._item)
        require("rust-docs.config").options.open_mode = orig
      end
    end,
    open_vsplit = function(picker, entry)
      picker:close()
      if entry and entry._item then
        local orig = require("rust-docs.config").options.open_mode
        require("rust-docs.config").options.open_mode = "vsplit"
        buffer.open(entry._item)
        require("rust-docs.config").options.open_mode = orig
      end
    end,
    open_tab = function(picker, entry)
      picker:close()
      if entry and entry._item then
        local orig = require("rust-docs.config").options.open_mode
        require("rust-docs.config").options.open_mode = "tab"
        buffer.open(entry._item)
        require("rust-docs.config").options.open_mode = orig
      end
    end,
  }

  -- Forget remembered source and re-open the source picker
  if clear_src_key and clear_src_key ~= "" then
    actions.clear_source = function(picker, _entry)
      picker:close()
      local rd = require("rust-docs")
      rd.clear_source()
      rd.open_source_picker()
    end
    key_defs[clear_src_key] = { "clear_source", mode = { "i", "n" } }
  end

  -- Wire the crate-index action only when a URL is provided
  local key_defs = {
    ["<C-s>"] = { "open_split",  mode = { "i", "n" } },
    ["<C-v>"] = { "open_vsplit", mode = { "i", "n" } },
    ["<C-t>"] = { "open_tab",    mode = { "i", "n" } },
  }

  if index_url then
    actions.open_crate_index = function(picker, _entry)
      picker:close()
      local src = require("rust-docs")._last_source
      local display_name = (src and src.kind == "crate")
        and (src.crate.name .. " " .. src.version)
        or index_url
      buffer.open_url(index_url, display_name)
    end
    key_defs[open_index_key] = { "open_crate_index", mode = { "i", "n" } }
  end

  snacks.picker({
    title  = index_url and (title or "Rust Docs") .. "  [" .. open_index_key .. "] Open index page" or (title or "Rust Docs"),
    items  = (function()
      local entries = {}
      for _, item in ipairs(items) do
        table.insert(entries, {
          text  = item.full_path .. " " .. (item.kind or "") .. " " .. (item.desc or ""),
          label = item.full_path,
          kind  = item.kind or "?",
          desc  = item.desc or "",
          _item = item,
        })
      end
      return entries
    end)(),

    format = function(entry, _ctx)
      local parts = {}
      local kind_str = string.format("%-18s", "[" .. entry.kind .. "]")
      local kind_hl = KIND_HL[entry.kind] or "SnacksPickerLabel"
      table.insert(parts, { kind_str, hl = kind_hl })
      table.insert(parts, { "  " })
      local path_str = string.format("%-50s", entry.label)
      table.insert(parts, { path_str, hl = "Identifier" })
      table.insert(parts, { "  " })
      local desc = entry.desc or ""
      if #desc > 60 then desc = desc:sub(1, 57) .. "..." end
      table.insert(parts, { desc, hl = "Comment" })
      return parts
    end,

    confirm = function(picker, entry)
      picker:close()
      if entry and entry._item then
        buffer.open(entry._item)
      end
    end,

    actions = actions,

    win = {
      input = {
        keys = key_defs,
      },
    },
  })
end

return M
