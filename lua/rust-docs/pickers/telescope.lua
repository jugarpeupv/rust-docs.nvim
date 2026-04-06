--- Telescope picker for Rust documentation search.

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

--- Shared helper: require telescope modules or notify and return nil.
local function require_telescope()
  local ok, _ = pcall(require, "telescope")
  if not ok then
    vim.notify("rust-docs: telescope.nvim not found", vim.log.levels.ERROR)
    return nil
  end
  return {
    pickers      = require("telescope.pickers"),
    finders      = require("telescope.finders"),
    conf         = require("telescope.config").values,
    sorters      = require("telescope.sorters"),
    actions      = require("telescope.actions"),
    state        = require("telescope.actions.state"),
    displayer    = require("telescope.pickers.entry_display"),
  }
end

--- Open the source picker (std | pinned crates | Search crates.io…).
---@param sources RustDocs.Source[]
---@param on_select fun(source: RustDocs.Source)
function M.open_source(sources, on_select)
  local t = require_telescope()
  if not t then return end

  local displayer = t.displayer.create({
    separator = "  ",
    items = {
      { width = 10 },      -- kind badge
      { remaining = true },-- label / description
    },
  })

  local kind_hl = {
    std    = "Special",
    crate  = "Function",
    search = "Comment",
  }

  local function make_display(entry)
    local s = entry.value
    local badge = s.kind == "std" and "[std]"
      or s.kind == "crate" and "[crate]"
      or "[search]"
    return displayer({
      { badge,   kind_hl[s.kind] or "Normal" },
      { s.label, "Normal" },
    })
  end

  t.pickers.new({}, {
    prompt_title  = "Rust Docs — Select Source",
    results_title = "Sources",
    finder = t.finders.new_table({
      results = sources,
      entry_maker = function(s)
        return {
          value   = s,
          display = make_display,
          ordinal = s.label,
        }
      end,
    }),
    sorter = t.conf.generic_sorter({}),
    previewer = false,
    attach_mappings = function(prompt_buf, _)
      t.actions.select_default:replace(function()
        local sel = t.state.get_selected_entry()
        t.actions.close(prompt_buf)
        if sel then on_select(sel.value) end
      end)
      return true
    end,
  }):find()
end

--- Open a version picker for a crate.
---@param crate RustDocs.Crate
---@param versions string[]
---@param on_select fun(version: string)
function M.open_version(crate, versions, on_select)
  local t = require_telescope()
  if not t then return end

  t.pickers.new({}, {
    prompt_title  = "Rust Docs — " .. crate.name .. " — Select Version",
    results_title = "Versions",
    finder = t.finders.new_table({
      results = versions,
      entry_maker = function(v)
        return { value = v, display = v, ordinal = v }
      end,
    }),
    sorter = t.conf.generic_sorter({}),
    previewer = false,
    attach_mappings = function(prompt_buf, _)
      t.actions.select_default:replace(function()
        local sel = t.state.get_selected_entry()
        t.actions.close(prompt_buf)
        if sel then on_select(sel.value) end
      end)
      return true
    end,
  }):find()
end

--- Open a live crates.io search picker.
--- Queries crates.io after a 300 ms debounce (not on every keystroke).
---@param on_select fun(crate: RustDocs.Crate)
function M.open_crate_search(on_select)
  local t = require_telescope()
  if not t then return end

  local CRATES_IO_UA = "rust-docs.nvim/1.0 (Neovim plugin)"
  local DEBOUNCE_MS  = 300

  local displayer = t.displayer.create({
    separator = "  ",
    items = {
      { width = 30 },       -- crate name + version
      { remaining = true }, -- description
    },
  })

  local function make_display(entry)
    local c = entry.value
    return displayer({
      { c.name .. "  " .. c.version, "Function" },
      { c.description,               "Comment"  },
    })
  end

  -- Debounce state
  local debounce_timer = nil
  local inflight       = nil
  local request_seq    = 0
  local last_searched  = nil   -- guard: skip network call when query unchanged

  local function do_search(query)
    -- Kill stale request.
    if inflight then
      pcall(function() inflight:kill(9) end)
      inflight = nil
    end

    if not query or query == "" then
      last_searched = nil
      return
    end

    -- Skip if we already fetched results for this exact query (e.g. j/k navigation
    -- fires on_input_filter_cb with the same prompt text, which would reset the cursor).
    if query == last_searched then return end
    last_searched = query

    request_seq = request_seq + 1
    local my_seq = request_seq

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
          if my_seq ~= request_seq then return end
          if result.code ~= 0 then return end

          local ok, data = pcall(vim.json.decode, result.stdout,
            { luanil = { object = true, array = true } })
          if not ok or not data or not data.crates then return end

          local crates = {}
          for _, c in ipairs(data.crates) do
            table.insert(crates, {
              name        = c.name or "",
              version     = c.newest_version or c.max_version or "latest",
              description = (c.description or ""):gsub("\n", " "):sub(1, 100),
              downloads   = c.downloads or 0,
            })
          end

          -- Swap the finder on the live picker so results appear.
          if picker_ref then
            picker_ref:refresh(
              t.finders.new_table({
                results = crates,
                entry_maker = function(c)
                  return {
                    value   = c,
                    display = make_display,
                    ordinal = c.name .. " " .. c.description,
                  }
                end,
              }),
              { reset_prompt = false }
            )
          end
        end)
      end
    )
  end

  picker_ref = t.pickers.new({}, {
    prompt_title  = "Search crates.io",
    results_title = "Crates",
    -- Start empty; results arrive async after the debounce fires.
    finder = t.finders.new_table({ results = {} }),
    sorter = t.conf.generic_sorter({}),
    previewer = false,

    -- on_input_filter_cb runs on every keystroke; we debounce here.
    on_input_filter_cb = function(query)
      if debounce_timer then
        debounce_timer:stop()
        debounce_timer:close()
        debounce_timer = nil
      end
      debounce_timer = vim.uv.new_timer()
      debounce_timer:start(DEBOUNCE_MS, 0, vim.schedule_wrap(function()
        if debounce_timer then
          debounce_timer:close()
          debounce_timer = nil
        end
        do_search(query)
      end))
      -- Return the query unmodified so telescope still updates its internal state.
      return { prompt = query }
    end,

    attach_mappings = function(prompt_buf, _)
      t.actions.select_default:replace(function()
        local sel = t.state.get_selected_entry()
        t.actions.close(prompt_buf)
        if sel then on_select(sel.value) end
      end)
      return true
    end,
  })

  picker_ref:find()
end

--- Open the items picker with live search powered by the rustdoc search engine.
--- Calls index.search() on each keystroke (debounced ~200 ms).
--- Results are already ranked by rustdoc; no custom sorter is applied.
---@param source { kind: "std" } | { kind: "crate", crate: RustDocs.Crate, version: string }
---@param title string          Picker title
---@param index_url string|nil  If set, <C-e> opens this URL as the crate index page
function M.open(source, title, index_url)
  local t = require_telescope()
  if not t then return end

  local index          = require("rust-docs.search.index")
  local buffer         = require("rust-docs.render.buffer")
  local cfg            = require("rust-docs.config").options
  local open_index_key = cfg.keymaps.open_crate_index or "<C-e>"
  local clear_src_key  = cfg.keymaps.clear_source
  local DEBOUNCE_MS    = 200

  -- Build display with aligned columns: [kind]  path::Name  — description
  local displayer = t.displayer.create({
    separator = "  ",
    items = {
      { width = 18 },       -- kind
      { width = 50 },       -- full_path
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

  local function items_to_finder(items)
    return t.finders.new_table({
      results = items or {},
      entry_maker = function(item)
        return {
          value    = item,
          display  = make_display,
          -- ordinal is used only for the sorter; with empty() sorter it's irrelevant,
          -- but set it so Telescope doesn't error on nil ordinal.
          ordinal  = item.full_path,
          filename = item.url,
          text     = "[" .. (item.kind or "?") .. "] " .. item.full_path
                     .. (item.desc ~= "" and ("  " .. item.desc) or ""),
        }
      end,
    })
  end

  -- Debounce state (closed over by on_input_filter_cb)
  local debounce_timer = nil
  local request_seq    = 0
  local last_query     = nil   -- guard: skip refresh when only cursor moved
  local picker_ref     = nil   -- set after pickers.new():find()

  local function do_search(query)
    request_seq = request_seq + 1
    local my_seq = request_seq

    index.search(query, source, function(err, items)
      if my_seq ~= request_seq then return end
      if err then
        vim.notify("rust-docs: " .. err, vim.log.levels.WARN)
        items = {}
      end
      if picker_ref then
        picker_ref:refresh(items_to_finder(items), { reset_prompt = false })
      end
    end)
  end

  picker_ref = t.pickers.new({}, {
    prompt_title   = index_url
      and (title or "Rust Docs") .. "  [" .. open_index_key .. "] Open index page"
      or  (title or "Rust Docs"),
    results_title  = "Items  (type to search)",
    -- Start empty; results arrive async after first search fires.
    finder    = items_to_finder({}),
    -- Pass-through sorter: results are already ranked by the rustdoc engine.
    sorter    = t.sorters.empty(),
    previewer = false,

    -- Fire a debounced search on every keystroke, but NOT on cursor movement.
    -- on_input_filter_cb fires for every keypress (including <C-j>/<C-k>);
    -- the last_query guard prevents picker:refresh() on navigation keys.
    on_input_filter_cb = function(query)
      -- Navigation keys (<C-j>/<C-k>/arrows) fire this with the same prompt text.
      -- Bail immediately — do not touch the debounce or results list.
      if query == last_query then
        return { prompt = query }
      end
      last_query = query

      if debounce_timer then
        debounce_timer:stop()
        debounce_timer:close()
        debounce_timer = nil
      end

      if not query or query == "" then
        -- Clear results on empty prompt
        if picker_ref then
          picker_ref:refresh(items_to_finder({}), { reset_prompt = false })
        end
        return { prompt = query }
      end

      debounce_timer = vim.uv.new_timer()
      debounce_timer:start(DEBOUNCE_MS, 0, vim.schedule_wrap(function()
        if debounce_timer then
          debounce_timer:close()
          debounce_timer = nil
        end
        do_search(query)
      end))
      return { prompt = query }
    end,

    attach_mappings = function(prompt_buf, map)
      -- Default action: open doc buffer
      t.actions.select_default:replace(function()
        local selection = t.state.get_selected_entry()
        t.actions.close(prompt_buf)
        if selection then
          buffer.open(selection.value)
        end
      end)

      -- Open in split/vsplit/tab
      map("i", "<C-s>", function()
        local selection = t.state.get_selected_entry()
        t.actions.close(prompt_buf)
        if selection then
          local orig_mode = require("rust-docs.config").options.open_mode
          require("rust-docs.config").options.open_mode = "split"
          buffer.open(selection.value)
          require("rust-docs.config").options.open_mode = orig_mode
        end
      end)

      map("i", "<C-v>", function()
        local selection = t.state.get_selected_entry()
        t.actions.close(prompt_buf)
        if selection then
          local orig_mode = require("rust-docs.config").options.open_mode
          require("rust-docs.config").options.open_mode = "vsplit"
          buffer.open(selection.value)
          require("rust-docs.config").options.open_mode = orig_mode
        end
      end)

      map("i", "<C-t>", function()
        local selection = t.state.get_selected_entry()
        t.actions.close(prompt_buf)
        if selection then
          local orig_mode = require("rust-docs.config").options.open_mode
          require("rust-docs.config").options.open_mode = "tab"
          buffer.open(selection.value)
          require("rust-docs.config").options.open_mode = orig_mode
        end
      end)

      -- Forget remembered source and re-open the source picker
      if clear_src_key and clear_src_key ~= "" then
        local function do_clear_source()
          t.actions.close(prompt_buf)
          local rd = require("rust-docs")
          rd.clear_source()
          rd.open_source_picker()
        end
        map("i", clear_src_key, do_clear_source)
        map("n", clear_src_key, do_clear_source)
      end

      -- Open the crate index page (no item selected)
      if index_url then
        local function open_index()
          t.actions.close(prompt_buf)
          local src = require("rust-docs")._last_source
          local display_name = (src and src.kind == "crate")
            and (src.crate.name .. " " .. src.version)
            or index_url
          buffer.open_url(index_url, display_name)
        end
        map("i", open_index_key, open_index)
        map("n", open_index_key, open_index)
      end

      return true
    end,
  })

  picker_ref:find()
end

return M
