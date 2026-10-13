--- Doc buffer management.
--- Creates or reuses a named, buflisted Neovim buffer for each doc page.
--- Buffer name format: "rust-docs://std::net::TcpListener"

local M = {}

local config  = require("rust-docs.config")
local fetch   = require("rust-docs.search.fetch")
local render  = require("rust-docs.render.html")

--- Return true if a line is a markdown heading (starts with one or more #).
local function is_heading(line)
  return line ~= nil and line:match("^#+ ")
end

--- Module-level cache: buf_number → link spans ({ [line_nr] = { url, c0, c1 } })
--- c0/c1 are 0-based byte columns (end-exclusive) for the navigable word.
--- Using a plain Lua table so integer keys are preserved (vim.b doesn't allow that).
local buf_link_maps = {}

--- Namespace for navigable-word highlights (see write_lines).
local LINK_NS = vim.api.nvim_create_namespace("rust-docs-links")

-- Underline for the navigable word that <CR>/gd can follow.
-- User-overridable: :hi RustDocsLink guifg=... etc.
pcall(vim.api.nvim_set_hl, 0, "RustDocsLink", { link = "Underlined", default = true })

--- Return the buffer name for an item.
---@param full_path string  e.g. "std::net::TcpListener"
---@return string
local function buf_name(full_path)
  return "rust-docs://" .. full_path
end

--- Find an existing buffer by name, or return nil.
---@param name string
---@return integer|nil
local function find_buf(name)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_get_name(buf) == name then
      return buf
    end
  end
  return nil
end

--- Open the buffer in the current window (or split/vsplit/tab per config).
---@param buf integer
local function show_buf(buf)
  local mode = config.options.open_mode
  if mode == "split" then
    vim.cmd("split")
  elseif mode == "vsplit" then
    vim.cmd("vsplit")
  elseif mode == "tab" then
    vim.cmd("tabnew")
  end
  vim.api.nvim_win_set_buf(0, buf)
end

--- Set buffer-local keymaps for navigation.
---@param buf integer
---@param url string  Source URL for gx
local function set_keymaps(buf, url)
  local km   = config.options.keymaps
  local opts = { buffer = buf, silent = true, noremap = true }

  -- Jump to next markdown heading
  vim.keymap.set("n", km.section_next, function()
    local cur = vim.api.nvim_win_get_cursor(0)[1]
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    for i = cur + 1, #lines do
      if is_heading(lines[i]) then
        vim.api.nvim_win_set_cursor(0, { i, 0 })
        return
      end
    end
  end, vim.tbl_extend("force", opts, { desc = "rust-docs: next section" }))

  -- Jump to previous markdown heading
  vim.keymap.set("n", km.section_prev, function()
    local cur = vim.api.nvim_win_get_cursor(0)[1]
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    for i = cur - 1, 1, -1 do
      if is_heading(lines[i]) then
        vim.api.nvim_win_set_cursor(0, { i, 0 })
        return
      end
    end
  end, vim.tbl_extend("force", opts, { desc = "rust-docs: prev section" }))

  -- Open in browser
  vim.keymap.set("n", km.open_browser, function()
    local open_cmd
    if vim.fn.has("mac") == 1 then
      open_cmd = "open"
    elseif vim.fn.has("unix") == 1 then
      open_cmd = "xdg-open"
    else
      open_cmd = "start"
    end
    vim.system({ open_cmd, url })
    vim.notify("rust-docs: opened in browser", vim.log.levels.INFO)
  end, vim.tbl_extend("force", opts, { desc = "rust-docs: open in browser" }))

  -- Helper to find an anchor heading within the buffer
  local function find_anchor_line(b, anchor)
    local lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
    local start_i = 1
    for i, line in ipairs(lines) do
      if i > 5 and line:match("^# ") and not line:match("^# Table of Contents") then
        start_i = i
        break
      end
    end

    local is_method = anchor:match("^#?method%.") or anchor:match("^#?tymethod%.")
    local is_type   = anchor:match("^#?associatedtype%.")
    local is_const  = anchor:match("^#?associatedconstant%.")
    local clean     = anchor:gsub("^#", ""):gsub("^method%.", ""):gsub("^tymethod%.", ""):gsub("^associatedtype%.", ""):gsub("^associatedconstant%.", ""):gsub("%-", " "):lower()

    for i = start_i, #lines do
      local line = lines[i]
      if line:match("^#+") then
        local heading = line:gsub("^#+%s*", ""):lower()
        if is_method then
          if heading:match("^fn%s+" .. clean .. "$") or heading:match("^fn%s+" .. clean .. "%f[%W]") then
            return i
          end
        elseif is_type then
          if heading:match("^type%s+" .. clean .. "$") or heading:match("^type%s+" .. clean .. "%f[%W]") then
            return i
          end
        elseif is_const then
          if heading:match("^const%s+" .. clean .. "$") or heading:match("^const%s+" .. clean .. "%f[%W]") then
            return i
          end
        else
          if heading == clean then
            return i
          end
        end
      end
    end

    for i = start_i, #lines do
      local line = lines[i]
      if line:match("^#+") then
        local heading = line:gsub("^#+%s*", ""):lower()
        if heading:find(clean, 1, true) then
          return i
        end
      end
    end

    return nil
  end

  -- Derive a display name from a target URL
  local function display_name_from_url(target_url)
    local clean = target_url:gsub("^https?://[^/]+/", ""):gsub("%.html$", ""):gsub("[?#].*", "")
    clean = clean:gsub("/index$", "")
    local parts = {}
    for p in clean:gmatch("[^/]+") do
      table.insert(parts, p)
    end
    -- For docs.rs URLs (e.g. crate/version/crate/...)
    if #parts >= 3 and parts[1] == parts[3] then
      table.remove(parts, 2)
    end
    if #parts >= 2 and parts[1] == parts[2] then
      table.remove(parts, 1)
    end
    -- Clean rustdoc item kind prefixes (e.g. struct.File -> File)
    if #parts > 0 then
      parts[#parts] = parts[#parts]:gsub("^(%a+)%.", "")
    end
    return table.concat(parts, "::")
  end

  local function follow_link(mode)
    mode = mode or "current"
    local cur_line = vim.api.nvim_win_get_cursor(0)[1]
    local lmap = buf_link_maps[buf]
    local entry = lmap and lmap[cur_line]
    -- Back-compat: older buffers stored a plain string per line
    if type(entry) == "string" then
      entry = { url = entry }
    end
    if not entry or not entry.url then
      vim.notify("rust-docs: no link on this line", vim.log.levels.INFO)
      return
    end
    -- Single link per line: jump regardless of cursor column.
    -- The underline only marks the navigable word.
    local target_url = entry.url

    if target_url:match("^#") then
      local line_nr = find_anchor_line(buf, target_url)
      if line_nr then
        vim.api.nvim_win_set_cursor(0, { line_nr, 0 })
        return
      end
      vim.notify("rust-docs: section anchor not found: " .. target_url, vim.log.levels.INFO)
      return
    end

    local display = display_name_from_url(target_url)
    if mode == "current" then
      M.open_url(target_url, display)
    else
      local orig_mode = config.options.open_mode
      config.options.open_mode = mode
      M.open_url(target_url, display)
      config.options.open_mode = orig_mode
    end
  end

  -- Follow link (current window via gd / <CR> by default)
  local go_key = km.go_to_doc or "gd"
  if go_key ~= "" then
    vim.keymap.set("n", go_key, function() follow_link("current") end, vim.tbl_extend("force", opts, { desc = "rust-docs: follow link" }))
  end
  local confirm_key = km.follow_link or "<CR>"
  if confirm_key ~= "" and confirm_key ~= go_key then
    vim.keymap.set("n", confirm_key, function() follow_link("current") end, vim.tbl_extend("force", opts, { desc = "rust-docs: follow link" }))
  end
  -- Same link in a split: horizontal / vertical (configurable, "" disables)
  local split_key = km.follow_link_split or "<C-s>"
  if split_key ~= "" then
    vim.keymap.set("n", split_key, function() follow_link("split") end, vim.tbl_extend("force", opts, { desc = "rust-docs: follow link in split" }))
  end
  local vsplit_key = km.follow_link_vsplit or "<C-v>"
  if vsplit_key ~= "" then
    vim.keymap.set("n", vsplit_key, function() follow_link("vsplit") end, vim.tbl_extend("force", opts, { desc = "rust-docs: follow link in vsplit" }))
  end

  -- Reload (re-fetch)
  vim.keymap.set("n", "R", function()
    M.reload(buf)
  end, vim.tbl_extend("force", opts, { desc = "rust-docs: reload" }))

  -- Close
  vim.keymap.set("n", "q", function()
    vim.api.nvim_buf_delete(buf, { force = false })
  end, vim.tbl_extend("force", opts, { desc = "rust-docs: close" }))
end

--- Write lines into the buffer and update the link map.
---@param buf integer
---@param lines string[]
---@param link_map table<integer,{url:string,c0:integer,c1:integer}|string>|nil
local function write_lines(buf, lines, link_map)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified   = false
  -- Update the link map (clear old, set new)
  buf_link_maps[buf] = link_map or {}
  -- Highlight only the navigable word so it is discoverable
  if vim.api.nvim_buf_is_valid(buf) then
    pcall(vim.api.nvim_buf_clear_namespace, buf, LINK_NS, 0, -1)
    if link_map then
      for ln, entry in pairs(link_map) do
        local url, c0, c1
        if type(entry) == "string" then
          url, c0, c1 = entry, 0, #lines[ln]
        elseif type(entry) == "table" then
          url, c0, c1 = entry.url, entry.c0, entry.c1
        end
        if type(ln) == "number" and url and ln >= 1 and ln <= #lines then
          local line_len = #lines[ln]
          c0 = math.max(0, math.min(c0 or 0, line_len))
          c1 = math.max(c0, math.min(c1 or line_len, line_len))
          if c1 > c0 then
            pcall(vim.api.nvim_buf_set_extmark, buf, LINK_NS, ln - 1, c0, {
              end_col = c1,
              hl_group = "RustDocsLink",
            })
          end
        end
      end
    end
  end
end

--- Create a new doc buffer (not yet populated).
---@param name string
---@param url string
---@return integer buf
local function create_buf(name, url)
  local buf = vim.api.nvim_create_buf(true, false)  -- buflisted=true, scratch=false
  vim.api.nvim_buf_set_name(buf, name)

  -- Buffer options.
  -- NOTE: filetype is plain `markdown` (not a custom one) so that everything
  -- behaves exactly like in any other markdown file: treesitter highlighting,
  -- render-markdown.nvim (`:RenderMarkdown toggle`), conceal settings, and
  -- the user's own markdown autocmds. The buffer is still identifiable by its
  -- `rust-docs://…` name and `b:rust_docs_url`.
  vim.bo[buf].filetype    = "markdown"
  vim.bo[buf].buftype     = "nofile"
  vim.bo[buf].swapfile    = false
  vim.bo[buf].modifiable  = false
  vim.bo[buf].readonly    = false  -- we manage modifiable manually
  vim.bo[buf].buflisted   = true

  -- Markdown folds via treesitter (sections, lists, code blocks).
  -- NOTE: no `once = true` here — window options must be (re-)applied every
  -- time the buffer is displayed (splits, re-visits), otherwise the new
  -- window keeps whatever options the previously shown buffer had.
  -- Conceal is deliberately left alone so render-markdown.nvim and friends
  -- behave exactly as in other markdown buffers.
  vim.api.nvim_create_autocmd("BufWinEnter", {
    buffer  = buf,
    callback = function()
      for _, win in ipairs(vim.fn.win_findbuf(buf)) do
        vim.wo[win].foldmethod = "expr"
        vim.wo[win].foldexpr   = "v:lua.vim.treesitter.foldexpr()"
        vim.wo[win].foldenable = true
        vim.wo[win].foldlevel  = 99  -- start with all folds open
      end
    end,
  })

  set_keymaps(buf, url)

  -- Store metadata as buffer variable
  vim.b[buf].rust_docs_url = url

  -- Clean up link map when buffer is deleted
  vim.api.nvim_buf_attach(buf, false, {
    on_detach = function()
      buf_link_maps[buf] = nil
    end,
  })

  return buf
end

--- Show a loading placeholder while fetching.
---@param buf integer
---@param item RustDocs.Item
local function show_loading(buf, item)
  write_lines(buf, {
    "# " .. item.full_path,
    "",
    "Loading from " .. item.url .. " ...",
    "",
    "(press R to reload)",
  })
end

--- Open a doc buffer for a raw URL (e.g. a crate's index page).
--- The buffer is named "rust-docs://<display_name>".
---@param url string
---@param display_name string   Used as the buffer name suffix (e.g. "serde_json 1.0.149")
function M.open_url(url, display_name)
  local name = buf_name(display_name)
  local buf  = find_buf(name)
  local is_new = buf == nil

  if is_new then
    buf = create_buf(name, url)
  end

  show_buf(buf)

  if not is_new then
    local line_count = vim.api.nvim_buf_line_count(buf)
    if line_count > 5 then return end
  end

  write_lines(buf, { "# " .. display_name, "", "Loading " .. url .. " …" })

  fetch.fetch(url, function(err, html, sidebar_data, final_url)
    if err then
      write_lines(buf, { "# Error", "", err, "", "Press R to retry." })
      return
    end
    if not html or html == "" then
      write_lines(buf, { "# Error", "", "rust-docs: empty response for " .. url, "", "Press R to retry." })
      return
    end
    -- If docs.rs redirected (meta refresh), remember the final URL for gx/R
    local render_url = final_url or url
    vim.b[buf].rust_docs_url = render_url
    local ok, lines, link_map = pcall(render.render, html, render_url, sidebar_data)
    if not ok then
      -- pcall packs error into `lines` when it fails
      write_lines(buf, { "# Render error", "", tostring(lines) })
      return
    end
    if #lines <= 5 then
      write_lines(buf, { "# Error", "", "rust-docs: could not parse content from " .. render_url, "", "Press gx to open in browser." })
      return
    end
    write_lines(buf, lines, link_map)
    local wins = vim.fn.win_findbuf(buf)
    for _, win in ipairs(wins) do
      vim.api.nvim_win_set_cursor(win, { 1, 0 })
    end
  end)
end

--- Open a doc buffer for the given item. Creates or reuses an existing buffer.
---@param item RustDocs.Item
function M.open(item)
  local name = buf_name(item.full_path)
  local buf = find_buf(name)
  local is_new = buf == nil

  if is_new then
    buf = create_buf(name, item.url)
  end

  -- Show the buffer immediately
  show_buf(buf)

  -- If buffer already has content, don't re-fetch
  if not is_new then
    local line_count = vim.api.nvim_buf_line_count(buf)
    if line_count > 5 then
      return
    end
  end

  -- Show loading placeholder
  show_loading(buf, item)

  -- Fetch the doc page
  fetch.fetch(item.url, function(err, html, sidebar_data, final_url)
    if err then
      write_lines(buf, {
        "# Error loading " .. item.full_path,
        "",
        err,
        "",
        "Press R to retry.",
      })
      return
    end

    if not html or html == "" then
      write_lines(buf, {
        "# Error loading " .. item.full_path,
        "",
        "rust-docs: empty response for " .. item.url,
        "",
        "Press R to retry.",
      })
      return
    end

    local render_url = final_url or item.url
    vim.b[buf].rust_docs_url = render_url
    local ok, lines, link_map = pcall(render.render, html, render_url, sidebar_data)
    if not ok then
      write_lines(buf, {
        "# Render error for " .. item.full_path,
        "",
        tostring(lines),
      })
      return
    end

    write_lines(buf, lines, link_map)
    -- Jump to top
    local wins = vim.fn.win_findbuf(buf)
    for _, win in ipairs(wins) do
      vim.api.nvim_win_set_cursor(win, { 1, 0 })
    end
  end)
end

--- Reload a buffer by re-fetching its URL.
---@param buf integer
function M.reload(buf)
  local url = vim.b[buf].rust_docs_url
  if not url then
    vim.notify("rust-docs: no URL stored for this buffer", vim.log.levels.WARN)
    return
  end

  write_lines(buf, { "Reloading...", "", url })

  fetch.fetch(url, function(err, html, sidebar_data, final_url)
    if err then
      write_lines(buf, { "Error: " .. err })
      return
    end
    local render_url = final_url or url
    vim.b[buf].rust_docs_url = render_url
    local ok, lines, link_map = pcall(render.render, html, render_url, sidebar_data)
    if not ok then
      write_lines(buf, { "Render error: " .. tostring(lines) })
      return
    end
    write_lines(buf, lines, link_map)
  end)
end

return M
