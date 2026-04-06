--- Search index for rust-docs.nvim
---
--- Runs the official rustdoc search engine (search-*.js) in Node.js so that
--- results are ranked exactly as on doc.rust-lang.org.
---
--- Public API
--- ----------
--- M.search(query, source, callback)
---   Run a live search and call callback(err, items).
---   `source` is { kind="std" } or { kind="crate", crate=..., version=... }.
---
--- M.refresh(callback)
---   No-op for std (the search engine reads the toolchain files directly).
---   For crates, clears any per-crate cache.
---
--- M.item_url(path, name, kind)
---   Build a doc.rust-lang.org URL from a path+name+kind triple.
---   (kept for compatibility with buffer.lua)

local M = {}

local config = require("rust-docs.config")

-- ---------------------------------------------------------------------------
-- Locate toolchain paths
-- ---------------------------------------------------------------------------

--- Locate the nightly (preferred) toolchain's HTML directory.
---@return string|nil html_dir, string|nil err
local function find_toolchain_html()
  -- 1. rustup toolchains directory
  local rustup_home = os.getenv("RUSTUP_HOME") or (os.getenv("HOME") .. "/.rustup")
  local toolchains_dir = rustup_home .. "/toolchains"

  local handle = vim.uv.fs_scandir(toolchains_dir)
  if handle then
    local candidates = {}
    while true do
      local name, ftype = vim.uv.fs_scandir_next(handle)
      if not name then break end
      if ftype == "directory" then
        local html = toolchains_dir .. "/" .. name .. "/share/doc/rust/html"
        local stat = vim.uv.fs_stat(html .. "/search.index")
        if stat then
          table.insert(candidates, { name = name, html = html })
        end
      end
    end
    table.sort(candidates, function(a, b)
      local function score(n)
        if n:find("nightly") then return 0 end
        if n:find("beta")    then return 1 end
        return 2
      end
      return score(a.name) < score(b.name)
    end)
    if #candidates > 0 then
      return candidates[1].html, nil
    end
  end

  -- 2. Fallback: rustc --print sysroot
  local result = vim.system({ "rustc", "--print", "sysroot" }, { text = true }):wait()
  if result.code == 0 then
    local sysroot = result.stdout:gsub("%s+$", "")
    local html = sysroot .. "/share/doc/rust/html"
    if vim.uv.fs_stat(html .. "/search.index") then
      return html, nil
    end
  end

  return nil, table.concat({
    "rust-docs: rustdoc search index not found.",
    "Install the rust-docs component:",
    "  rustup component add rust-docs  (or: --toolchain nightly)",
  }, "\n")
end

-- ---------------------------------------------------------------------------
-- Node.js script path
-- ---------------------------------------------------------------------------

--- Path to the bundled rustdoc_search.js runner.
---@return string
local function script_path()
  -- This file lives at: lua/rust-docs/search/index.lua
  -- The JS script is:   lua/rust-docs/search/rustdoc_search.js
  local this = debug.getinfo(1, "S").source:sub(2)  -- strip leading '@'
  return vim.fn.fnamemodify(this, ":h") .. "/rustdoc_search.js"
end

-- ---------------------------------------------------------------------------
-- URL helpers (for buffer.lua compatibility)
-- ---------------------------------------------------------------------------

--- URL segment for each kind (used to build doc.rust-lang.org URLs).
---@type table<string, string|nil>
local KIND_URL_SEG = {
  struct      = "struct",
  enum        = "enum",
  fn          = "fn",
  trait       = "trait",
  mod         = "index",       -- modules link to index.html
  const       = "constant",
  static      = "static",
  typedef     = "type",
  macro       = "macro",
  primitive   = "primitive",
  keyword     = "keyword",
}

--- Build a doc.rust-lang.org URL from path parts + kind.
---@param path_parts string[]  e.g. {"std","net","TcpListener"}
---@param kind string          display kind, e.g. "struct"
---@return string
local function build_url(path_parts, kind)
  local base = config.options.base_url  -- e.g. "https://doc.rust-lang.org/std"
  if #path_parts == 0 then
    return base .. "/index.html"
  end
  local name = path_parts[#path_parts]
  local mid = {}
  for i = 2, #path_parts - 1 do
    table.insert(mid, path_parts[i])
  end
  local mid_seg = (#mid > 0) and (table.concat(mid, "/") .. "/") or ""
  local type_seg = KIND_URL_SEG[kind]
  if type_seg == "index" then
    return base .. "/" .. mid_seg .. name .. "/index.html"
  elseif type_seg then
    return base .. "/" .. mid_seg .. type_seg .. "." .. name .. ".html"
  else
    if #mid > 0 then
      return base .. "/" .. mid_seg .. "index.html"
    end
    return base .. "/index.html"
  end
end

--- Convert a rustdoc href (relative to ROOT_PATH "../") to a full URL.
--- href examples: "../std/vec/struct.Vec.html" → base_doc_url + "std/vec/struct.Vec.html"
---@param href string
---@param base_doc_url string  e.g. "https://doc.rust-lang.org/"
---@return string
local function href_to_url(href, base_doc_url)
  -- Strip leading "../" (ROOT_PATH)
  local rel = href:match("^%.%./(.*)")  or href
  return base_doc_url .. rel
end

-- Base doc URL (no trailing crate segment).
-- config.options.base_url = "https://doc.rust-lang.org/std"
-- We need             "https://doc.rust-lang.org/"
local function base_doc_url()
  local b = config.options.base_url or "https://doc.rust-lang.org/std"
  -- Strip trailing crate segment (last path component)
  return b:match("^(https?://[^/]+/)") or "https://doc.rust-lang.org/"
end

-- ---------------------------------------------------------------------------
-- Result item conversion
-- ---------------------------------------------------------------------------

--- Convert a raw JSON result item from rustdoc_search.js to RustDocs.Item.
---@param r table  raw JSON item: {name, path, kind, desc, href}
---@return RustDocs.Item
local function to_item(r)
  local name      = r.name or ""
  local mod_path  = r.path or ""
  local kind      = r.kind or ""
  local desc      = r.desc or ""
  local href      = r.href or ""

  -- Build full_path from path + name
  local full_path
  if mod_path == "" then
    full_path = name
  else
    full_path = mod_path .. "::" .. name
  end

  -- Build URL
  local url
  if href ~= "" then
    url = href_to_url(href, base_doc_url())
  else
    -- Fallback: build from parts
    local parts = {}
    for p in full_path:gmatch("[^:]+") do
      table.insert(parts, p)
    end
    url = build_url(parts, kind)
  end

  ---@type RustDocs.Item
  return {
    name      = name,
    path      = mod_path,
    full_path = full_path,
    kind      = kind,
    desc      = desc,
    url       = url,
    params    = "",
    ret       = "",
  }
end

-- ---------------------------------------------------------------------------
-- Core: run a search query via Node.js
-- ---------------------------------------------------------------------------

--- Run the rustdoc search engine for std via Node.js and return items.
---@param query string
---@param filter_crate string|nil  e.g. "std" to restrict to std crate
---@param callback fun(err: string|nil, items: RustDocs.Item[]|nil)
local function run_std_search(query, filter_crate, callback)
  local js = script_path()
  if not vim.uv.fs_stat(js) then
    callback("rust-docs: rustdoc_search.js not found at " .. js, nil)
    return
  end

  local html_dir, err = find_toolchain_html()
  if not html_dir then
    callback(err, nil)
    return
  end

  local static_dir = html_dir .. "/static.files"
  local index_dir  = html_dir .. "/search.index"

  local cmd = { "node", js, query, static_dir, index_dir }
  if filter_crate and filter_crate ~= "" then
    table.insert(cmd, filter_crate)
  end

  vim.system(cmd, { text = true }, function(result)
    vim.schedule(function()
      if result.code ~= 0 then
        local msg = result.stderr or result.stdout or "unknown error"
        callback("rust-docs: search failed: " .. msg, nil)
        return
      end

      local ok, raw = pcall(vim.json.decode, result.stdout,
        { luanil = { object = true, array = true } })
      if not ok or type(raw) ~= "table" then
        callback("rust-docs: search output parse error: " .. tostring(raw), nil)
        return
      end

      local items = {}
      for _, r in ipairs(raw) do
        table.insert(items, to_item(r))
      end
      callback(nil, items)
    end)
  end)
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- Run a live search against the given source.
--- For std: calls the Node.js rustdoc search engine.
--- For crates: delegates to the crates module (which uses docs.rs JSON).
---
---@param query string
---@param source { kind: "std" } | { kind: "crate", crate: RustDocs.Crate, version: string }
---@param callback fun(err: string|nil, items: RustDocs.Item[]|nil)
function M.search(query, source, callback)
  if source.kind == "std" then
    -- Filter to the main std/alloc/core crates to avoid noise from core::arch etc.
    -- Pass no filter to search all crates in the std toolchain.
    run_std_search(query, nil, callback)
  elseif source.kind == "crate" then
    require("rust-docs.search.crates").search_items(
      source.crate.name, source.version, query, callback
    )
  else
    callback("rust-docs: unknown source kind: " .. tostring(source.kind), nil)
  end
end

--- Legacy compat: get_items now delegates to a search with empty query.
--- This returns the top-N items matching ""; useful for initial display.
---@param callback fun(err: string|nil, items: RustDocs.Item[]|nil)
function M.get_items(callback)
  callback(nil, {})
end

--- No-op for std (search engine reads toolchain files directly).
---@param callback? fun(err: string|nil)
function M.refresh(callback)
  vim.notify("rust-docs: index refresh not needed (uses live Node.js search)", vim.log.levels.INFO)
  if callback then callback(nil) end
end

--- Build a doc URL from path + name + kind (used by buffer.lua).
---@param path string
---@param name string
---@param kind string
---@return string
function M.item_url(path, name, kind)
  local parts = {}
  for p in (path .. "::" .. name):gmatch("[^:]+") do
    table.insert(parts, p)
  end
  return build_url(parts, kind)
end

return M
