--- Telescope picker for Rust documentation search.

local M = {}

--- Kind to highlight group mapping for display.
local KIND_HL = {
  ["fn"]             = "Function",
  ["struct"]         = "Structure",
  ["enum"]           = "Type",
  ["trait"]          = "Interface",
  ["mod"]            = "Namespace",
  ["const"]          = "Constant",
  ["static"]         = "Constant",
  ["typedef"]        = "Type",
  ["macro"]          = "Macro",
  ["primitive"]      = "Type",
  ["keyword"]        = "Keyword",
}

--- Open the Telescope picker with the given list of items.
---@param items RustDocs.Item[]
function M.open(items)
  local ok_tel, telescope = pcall(require, "telescope")
  if not ok_tel then
    vim.notify("rust-docs: telescope.nvim not found", vim.log.levels.ERROR)
    return
  end

  local pickers     = require("telescope.pickers")
  local finders     = require("telescope.finders")
  local conf        = require("telescope.config").values
  local actions     = require("telescope.actions")
  local action_state = require("telescope.actions.state")
  local entry_display = require("telescope.pickers.entry_display")
  local buffer = require("rust-docs.render.buffer")

  -- Build display with aligned columns: [kind]  path::Name  — description
  local displayer = entry_display.create({
    separator = "  ",
    items = {
      { width = 18 },   -- kind
      { width = 50 },   -- full_path
      { remaining = true }, -- desc
    },
  })

  local function make_display(entry)
    local item = entry.value
    local kind_hl = KIND_HL[item.kind] or "Normal"
    return displayer({
      { "[" .. (item.kind or "?") .. "]", kind_hl },
      { item.full_path,                   "Identifier" },
      { item.desc or "",                  "Comment" },
    })
  end

  pickers.new({}, {
    prompt_title   = "Rust Docs",
    results_title  = "Items (std)",
    finder = finders.new_table({
      results = items,
      entry_maker = function(item)
        return {
          value   = item,
          display = make_display,
          ordinal = item.full_path .. " " .. (item.kind or "") .. " " .. (item.desc or ""),
        }
      end,
    }),
    sorter = conf.generic_sorter({}),
    previewer = false,  -- We open a full buffer instead of a preview pane
    attach_mappings = function(prompt_buf, map)
      -- Default action: open doc buffer
      actions.select_default:replace(function()
        local selection = action_state.get_selected_entry()
        actions.close(prompt_buf)
        if selection then
          buffer.open(selection.value)
        end
      end)

      -- Also support opening in split/vsplit/tab
      map("i", "<C-s>", function()
        local selection = action_state.get_selected_entry()
        actions.close(prompt_buf)
        if selection then
          local orig_mode = require("rust-docs.config").options.open_mode
          require("rust-docs.config").options.open_mode = "split"
          buffer.open(selection.value)
          require("rust-docs.config").options.open_mode = orig_mode
        end
      end)

      map("i", "<C-v>", function()
        local selection = action_state.get_selected_entry()
        actions.close(prompt_buf)
        if selection then
          local orig_mode = require("rust-docs.config").options.open_mode
          require("rust-docs.config").options.open_mode = "vsplit"
          buffer.open(selection.value)
          require("rust-docs.config").options.open_mode = orig_mode
        end
      end)

      map("i", "<C-t>", function()
        local selection = action_state.get_selected_entry()
        actions.close(prompt_buf)
        if selection then
          local orig_mode = require("rust-docs.config").options.open_mode
          require("rust-docs.config").options.open_mode = "tab"
          buffer.open(selection.value)
          require("rust-docs.config").options.open_mode = orig_mode
        end
      end)

      return true
    end,
  }):find()
end

return M
