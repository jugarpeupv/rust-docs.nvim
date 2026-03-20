--- Snacks.picker integration for Rust documentation search.
--- Requires folke/snacks.nvim with the picker module enabled.

local M = {}

--- Open the Snacks picker with the given list of items.
---@param items RustDocs.Item[]
function M.open(items)
  local ok, snacks = pcall(require, "snacks")
  if not ok or not snacks.picker then
    vim.notify("rust-docs: snacks.nvim (with picker) not found", vim.log.levels.ERROR)
    return
  end

  local buffer = require("rust-docs.render.buffer")

  snacks.picker({
    title  = "Rust Docs",
    items  = (function()
      -- Transform items into snacks picker format
      local entries = {}
      for _, item in ipairs(items) do
        table.insert(entries, {
          -- Fields used for fuzzy matching (text)
          text  = item.full_path .. " " .. (item.kind or "") .. " " .. (item.desc or ""),
          -- Display fields
          label = item.full_path,
          kind  = item.kind or "?",
          desc  = item.desc or "",
          -- Original item reference
          _item = item,
        })
      end
      return entries
    end)(),

    -- Custom format function for each row
    format = function(entry, _ctx)
      local parts = {}

      -- Kind badge
      local kind_str = string.format("%-18s", "[" .. entry.kind .. "]")
      table.insert(parts, { kind_str, hl = "SnacksPickerLabel" })
      table.insert(parts, { "  " })

      -- Full path
      local path_str = string.format("%-50s", entry.label)
      table.insert(parts, { path_str, hl = "Identifier" })
      table.insert(parts, { "  " })

      -- Description (truncated)
      local desc = entry.desc or ""
      if #desc > 60 then
        desc = desc:sub(1, 57) .. "..."
      end
      table.insert(parts, { desc, hl = "Comment" })

      return parts
    end,

    -- Action on confirm
    confirm = function(picker, entry)
      picker:close()
      if entry and entry._item then
        buffer.open(entry._item)
      end
    end,

    -- Additional keymaps within the picker
    actions = {
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
    },

    win = {
      input = {
        keys = {
          ["<C-s>"] = { "open_split",  mode = { "i", "n" } },
          ["<C-v>"] = { "open_vsplit", mode = { "i", "n" } },
          ["<C-t>"] = { "open_tab",    mode = { "i", "n" } },
        },
      },
    },
  })
end

return M
