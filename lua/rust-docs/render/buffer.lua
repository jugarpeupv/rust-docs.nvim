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

--- Module-level cache: buf_number → link_map ({ [line_nr] = url })
--- Using a plain Lua table so integer keys are preserved (vim.b doesn't allow that).
local buf_link_maps = {}

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

  -- Follow link under cursor (gd, configurable)
  local go_key = km.go_to_doc or "gd"
  vim.keymap.set("n", go_key, function()
    local cur_line = vim.api.nvim_win_get_cursor(0)[1]
    local lmap = buf_link_maps[buf]
    local target_url = lmap and lmap[cur_line]
    if not target_url then
      vim.notify("rust-docs: no link on this line", vim.log.levels.INFO)
      return
    end
    -- Derive a display name from the URL path (last two segments)
    local display = target_url:match("/([^/]+/[^/]+)$") or target_url:match("/([^/]+)$") or target_url
    -- Strip trailing .html
    display = display:gsub("%.html$", ""):gsub("/", "::")
    M.open_url(target_url, display)
  end, vim.tbl_extend("force", opts, { desc = "rust-docs: follow link to doc page" }))

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
---@param link_map table<integer,string>|nil
local function write_lines(buf, lines, link_map)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified   = false
  -- Update the link map (clear old, set new)
  buf_link_maps[buf] = link_map or {}
end

--- Create a new doc buffer (not yet populated).
---@param name string
---@param url string
---@return integer buf
local function create_buf(name, url)
  local buf = vim.api.nvim_create_buf(true, false)  -- buflisted=true, scratch=false
  vim.api.nvim_buf_set_name(buf, name)

  -- Buffer options
  vim.bo[buf].filetype    = "rust-docs"
  vim.bo[buf].syntax      = "markdown"
  vim.bo[buf].buftype     = "nofile"
  vim.bo[buf].swapfile    = false
  vim.bo[buf].modifiable  = false
  vim.bo[buf].readonly    = false  -- we manage modifiable manually
  vim.bo[buf].buflisted   = true

  -- Enable markdown-heading folds (window-local, set when buffer is displayed)
  vim.api.nvim_create_autocmd("BufWinEnter", {
    buffer  = buf,
    once    = true,
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

  fetch.fetch(url, function(err, html)
    if err then
      write_lines(buf, { "# Error", "", err, "", "Press R to retry." })
      return
    end
    local ok, lines, link_map = pcall(render.render, html, url)
    if not ok then
      -- pcall packs error into `lines` when it fails
      write_lines(buf, { "# Render error", "", tostring(lines) })
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
  fetch.fetch(item.url, function(err, html)
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

    local ok, lines, link_map = pcall(render.render, html, item.url)
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

  fetch.fetch(url, function(err, html)
    if err then
      write_lines(buf, { "Error: " .. err })
      return
    end
    local ok, lines, link_map = pcall(render.render, html, url)
    if not ok then
      write_lines(buf, { "Render error: " .. tostring(lines) })
      return
    end
    write_lines(buf, lines, link_map)
  end)
end

return M
