--- External crate documentation support for rust-docs.nvim.
---
--- Searches crates.io for crate names, lists available versions, then downloads
--- the rustdoc JSON from docs.rs and parses it into RustDocs.Item[] — the same
--- format produced by search/index.lua for std.
---
--- docs.rs rustdoc JSON URL:  https://docs.rs/crate/{name}/{version}/json.gz
--- crates.io search API:     https://crates.io/api/v1/crates?q={query}&per_page=20
--- crates.io versions API:   https://crates.io/api/v1/crates/{name}/versions

local M = {}

local config = require("rust-docs.config")
local fetch  = require("rust-docs.search.fetch")

local CRATES_IO_UA = "rust-docs.nvim/1.0 (Neovim plugin; github.com/jugarpeupv/rust-docs.nvim)"

--- Return the cache path for a crate's parsed item list.
---@param name string
---@param version string  "latest" or a semver string
---@return string
local function crate_cache_path(name, version)
  -- Sanitize version: "latest" stays as-is, semver uses dashes
  local safe_ver = version:gsub("[^%w%.]", "_")
  return config.options.cache_dir .. "/" .. name .. "_" .. safe_ver .. "_items.json"
end

--- Return the cache path for the raw rustdoc JSON download.
---@param name string
---@param version string
---@return string
local function crate_json_cache_path(name, version)
  local safe_ver = version:gsub("[^%w%.]", "_")
  -- Always keep the .gz extension so the Python parser knows to decompress it.
  return config.options.cache_dir .. "/" .. name .. "_" .. safe_ver .. ".json.gz"
end

--- Check if a cached items file is still valid (within TTL).
---@param path string
---@return boolean
local function items_cache_valid(path)
  local stat = vim.uv.fs_stat(path)
  if not stat then return false end
  local age = os.time() - stat.mtime.sec
  return age < config.options.index_ttl
end

--- Search crates.io for crates matching a query string.
--- Calls callback(err, crates) where crates is RustDocs.Crate[].
---@param query string
---@param callback fun(err: string|nil, crates: RustDocs.Crate[]|nil)
function M.search_crates(query, callback)
  if not query or query == "" then
    callback("rust-docs: empty crate search query", nil)
    return
  end

  local url = "https://crates.io/api/v1/crates?q="
    .. vim.uri_encode(query)
    .. "&per_page=20&sort=downloads"

  -- crates.io requires a User-Agent
  vim.system(
    { "curl", "--silent", "--fail", "--location", "--compressed",
      "--user-agent", CRATES_IO_UA, url },
    { text = true },
    function(result)
      vim.schedule(function()
        if result.code ~= 0 then
          callback("rust-docs: crates.io search failed: " .. (result.stderr or ""), nil)
          return
        end

        local ok, data = pcall(vim.json.decode, result.stdout,
          { luanil = { object = true, array = true } })
        if not ok or not data or not data.crates then
          callback("rust-docs: could not parse crates.io response", nil)
          return
        end

        ---@type RustDocs.Crate[]
        local crates = {}
        for _, c in ipairs(data.crates) do
          table.insert(crates, {
            name        = c.name or "",
            version     = c.newest_version or c.max_version or "latest",
            description = (c.description or ""):gsub("\n", " "):sub(1, 120),
            downloads   = c.downloads or 0,
          })
        end
        callback(nil, crates)
      end)
    end
  )
end

--- Fetch available versions for a crate from crates.io.
--- Calls callback(err, versions) where versions is a string[] (newest first, non-yanked).
---@param name string
---@param callback fun(err: string|nil, versions: string[]|nil)
function M.get_versions(name, callback)
  local url = "https://crates.io/api/v1/crates/" .. name .. "/versions"

  vim.system(
    { "curl", "--silent", "--fail", "--location", "--compressed",
      "--user-agent", CRATES_IO_UA, url },
    { text = true },
    function(result)
      vim.schedule(function()
        if result.code ~= 0 then
          callback("rust-docs: failed to fetch versions for " .. name .. ": " .. (result.stderr or ""), nil)
          return
        end

        local ok, data = pcall(vim.json.decode, result.stdout,
          { luanil = { object = true, array = true } })
        if not ok or not data or not data.versions then
          callback("rust-docs: could not parse versions response for " .. name, nil)
          return
        end

        local versions = {}
        for _, v in ipairs(data.versions) do
          -- Skip yanked versions
          if not v.yanked and v.num then
            table.insert(versions, v.num)
          end
        end
        callback(nil, versions)
      end)
    end
  )
end

--- Download the rustdoc JSON (.gz) from docs.rs and parse it into RustDocs.Item[].
--- Results are cached per (name, version).
---
--- Uses the same Python-based parsing as index.lua, adapted for external crates:
---   - base_url is https://docs.rs/{name}/{version}/{name}
---   - No method extraction from local HTML (not available), but #method.* anchors
---     from the already-parsed HTML pages will still work on demand via buffer.lua.
---
---@param name string
---@param version string   "latest" or a specific semver string
---@param callback fun(err: string|nil, items: RustDocs.Item[]|nil)
function M.get_crate_items(name, version, callback)
  local items_path = crate_cache_path(name, version)

  -- Check cache first
  if items_cache_valid(items_path) then
    local fd = io.open(items_path, "r")
    if fd then
      local raw = fd:read("*a")
      fd:close()
      local ok, items = pcall(vim.json.decode, raw,
        { luanil = { object = true, array = true } })
      if ok and items then
        callback(nil, items)
        return
      end
    end
  end

  -- Download the rustdoc JSON
  local json_url = "https://docs.rs/crate/" .. name .. "/" .. version .. "/json.gz"
  local json_path = crate_json_cache_path(name, version)

  vim.notify("rust-docs: downloading docs for " .. name .. " " .. version .. "…", vim.log.levels.INFO)

  -- Download with curl directly to file (gzip, not --compressed so we get raw .gz)
  vim.system(
    { "curl", "--silent", "--fail", "--location",
      "--user-agent", CRATES_IO_UA,
      "-o", json_path, json_url },
    { text = true },
    function(dl_result)
      vim.schedule(function()
        if dl_result.code ~= 0 then
          callback(
            "rust-docs: failed to download " .. json_url ..
            " (exit " .. dl_result.code .. "): " .. (dl_result.stderr or ""),
            nil
          )
          return
        end

        -- Check the file is not empty / HTML error page
        local stat = vim.uv.fs_stat(json_path)
        if not stat or stat.size < 100 then
          vim.uv.fs_unlink(json_path, function() end)
          callback("rust-docs: docs.rs returned an empty response for " .. name .. " " .. version, nil)
          return
        end

        -- Run Python to decompress + parse the JSON (reuse same logic as index.lua)
        _parse_crate_json(name, version, json_path, items_path, callback)
      end)
    end
  )
end

--- Internal: run Python to parse a downloaded crate JSON into items.json.
---@param crate_name string
---@param version string
---@param json_gz_path string   path to the downloaded .gz file
---@param out_path string       destination for items.json
---@param callback fun(err: string|nil, items: RustDocs.Item[]|nil)
function _parse_crate_json(crate_name, version, json_gz_path, out_path, callback)
  -- The base URL for this crate on docs.rs.
  -- Pattern: https://docs.rs/{name}/{version}/{name}
  -- "latest" in the URL resolves to the concrete version at render time.
  local base_url = "https://docs.rs/" .. crate_name .. "/" .. version .. "/" .. crate_name

  local script = string.format([[
import json, gzip, os, re

# Decompress if .gz, else read directly
gz_path = %q
if gz_path.endswith(".gz"):
    with gzip.open(gz_path, "rt", encoding="utf-8", errors="ignore") as f:
        data = json.load(f)
else:
    with open(gz_path, encoding="utf-8", errors="ignore") as f:
        data = json.load(f)

index = data.get("index", {})
paths = data.get("paths", {})
crate_name = %q

KIND_URL_SEG = {
    "struct": "struct", "enum": "enum", "function": "fn", "trait": "trait",
    "module": "index", "constant": "constant", "static": "static",
    "type_alias": "type", "macro": "macro", "primitive": "primitive",
    "keyword": "keyword",
}
KIND_LABEL = {
    "struct": "struct", "enum": "enum", "function": "fn", "trait": "trait",
    "module": "mod", "constant": "const", "static": "static",
    "type_alias": "typedef", "macro": "macro", "primitive": "primitive",
    "assoc_type": "associated type", "assoc_const": "associated const",
    "variant": "variant", "struct_field": "struct field",
}
BASE_URL = %q

SKIP_KINDS = {"impl", "use", "struct_field", "variant", "assoc_type", "assoc_const"}
METHOD_PARENT_KINDS = {"struct", "enum", "trait", "primitive", "type_alias"}

# Build public re-export paths from 'use' items (same logic as std)
child_to_module = {}
module_paths_by_id = {}

for item_id, item in index.items():
    inner = item.get("inner") or {}
    if "module" not in inner:
        continue
    for child_id in inner["module"].get("items", []):
        child_to_module[str(child_id)] = item_id
    if item_id in paths and paths[item_id]["path"][:1] == [crate_name]:
        module_paths_by_id[item_id] = paths[item_id]["path"]

public_paths = {}
for item_id, item in index.items():
    inner = item.get("inner") or {}
    if "use" not in inner:
        continue
    use_info = inner["use"]
    if use_info.get("is_glob"):
        continue
    target_id = use_info.get("id")
    name = use_info.get("name")
    if target_id is None or not name:
        continue
    target_id = str(target_id)
    parent_mod = child_to_module.get(item_id)
    if not parent_mod or parent_mod not in module_paths_by_id:
        continue
    pub_path = module_paths_by_id[parent_mod] + [name]
    current = public_paths.get(target_id)
    if current is None or len(pub_path) < len(current):
        public_paths[target_id] = pub_path

items = []
seen_full_paths = set()

for item_id, item in index.items():
    if not item.get("name"):
        continue
    inner = item.get("inner") or {}
    kind_key = list(inner.keys())[0] if inner else None
    if not kind_key or kind_key in SKIP_KINDS:
        continue

    pub_path = public_paths.get(item_id)
    orig_info = paths.get(item_id)

    if pub_path and pub_path[:1] == [crate_name]:
        path_parts = pub_path
    elif orig_info and orig_info["path"][:1] == [crate_name]:
        path_parts = orig_info["path"]
    else:
        continue

    full_path = "::".join(path_parts)
    if full_path in seen_full_paths:
        continue
    seen_full_paths.add(full_path)

    name = item["name"]
    docs = (item.get("docs") or "").strip()
    first_line = docs.split("\n")[0][:120] if docs else ""
    kind_label = KIND_LABEL.get(kind_key, kind_key)
    parent_path = "::".join(path_parts[:-1]) if len(path_parts) > 1 else crate_name

    name_part = path_parts[-1]
    mid = path_parts[1:-1]
    mid_seg = "/".join(mid) + "/" if mid else ""
    type_seg = KIND_URL_SEG.get(kind_key)
    if type_seg == "index":
        url = BASE_URL + "/" + mid_seg + name_part + "/index.html"
    elif type_seg:
        url = BASE_URL + "/" + mid_seg + type_seg + "." + name_part + ".html"
    else:
        url = BASE_URL + "/" + (mid_seg or "") + "index.html"

    items.append({
        "name":      name,
        "path":      parent_path,
        "full_path": full_path,
        "kind":      kind_label,
        "desc":      first_line,
        "url":       url,
    })

    # Also index methods from impl blocks inside the JSON itself
    # (external crates: no local HTML, but assoc functions live in impl items)

# Extract methods from impl items.
#
# Two-level lookup to correctly bridge internal paths (from `paths[id]`) to the
# public re-export paths used as keys in `parent_map`:
#
#   id_to_public_full_path : item_id (str) -> public full_path string
#   parent_map             : public full_path -> url  (only method-bearing types)
#
# The impl loop resolves `for_id` -> public full_path -> url, bypassing the
# mismatch between paths[id]["path"] (internal) and the re-export path we stored.

id_to_public_full_path = {}
for item in items:
    pub_path = public_paths.get(item.get("_id", ""))  # not stored; rebuild below
    pass  # will be filled in the loop below

# Rebuild: walk index again to collect id -> chosen full_path (same logic as above)
id_to_public_full_path = {}
for item_id, item in index.items():
    if not item.get("name"):
        continue
    inner = item.get("inner") or {}
    kind_key = list(inner.keys())[0] if inner else None
    if not kind_key or kind_key in SKIP_KINDS:
        continue
    pub_path = public_paths.get(item_id)
    orig_info = paths.get(item_id)
    if pub_path and pub_path[:1] == [crate_name]:
        path_parts = pub_path
    elif orig_info and orig_info["path"][:1] == [crate_name]:
        path_parts = orig_info["path"]
    else:
        continue
    id_to_public_full_path[item_id] = "::".join(path_parts)

parent_map = {item["full_path"]: item["url"] for item in items
              if item["kind"] in ("struct", "enum", "trait", "primitive", "typedef")}

def extract_type_id(for_val):
    """Extract the numeric rustdoc ID from a 'for' type expression.
    The field is always a type object, never a plain int.
    Most common shape: {"resolved_path": {"id": <int>, ...}}
    Also handles {"borrowed_ref": {"type": <nested>}}.
    Returns str(id) suitable for paths/index lookup, or None if unresolvable.
    """
    if not isinstance(for_val, dict):
        return None
    rp = for_val.get("resolved_path")
    if rp and isinstance(rp, dict):
        tid = rp.get("id")
        if tid is not None:
            return str(tid)
    br = for_val.get("borrowed_ref")
    if br and isinstance(br, dict):
        return extract_type_id(br.get("type"))
    return None

for item_id, item in index.items():
    inner = item.get("inner") or {}
    if "impl" not in inner:
        continue
    impl_info = inner["impl"]
    for_val = impl_info.get("for")
    if not for_val:
        continue
    for_id = extract_type_id(for_val)
    if not for_id:
        continue
    # Resolve the parent type's public full_path (handles re-export path mismatches)
    parent_full_path = id_to_public_full_path.get(for_id)
    if not parent_full_path:
        # Fallback: try paths directly (works when no re-export remapping occurred)
        parent_info = paths.get(for_id)
        if not parent_info or parent_info["path"][:1] != [crate_name]:
            continue
        parent_full_path = "::".join(parent_info["path"])
    parent_url = parent_map.get(parent_full_path)
    if not parent_url:
        continue
    impl_info = inner["impl"]
    for_val = impl_info.get("for")
    if not for_val:
        continue
    for_id = extract_type_id(for_val)
    if not for_id:
        continue
    # Look up the parent type in paths
    parent_info = paths.get(for_id)
    if not parent_info:
        continue
    p_path = parent_info["path"]
    if p_path[:1] != [crate_name]:
        continue
    parent_full_path = "::".join(p_path)
    parent_url = parent_map.get(parent_full_path)
    if not parent_url:
        continue

    for method_id in impl_info.get("items", []):
        method_id = str(method_id)
        method_item = index.get(method_id)
        if not method_item or not method_item.get("name"):
            continue
        m_inner = method_item.get("inner") or {}
        m_kind = list(m_inner.keys())[0] if m_inner else None
        if m_kind not in ("function", "method"):
            continue
        m_name = method_item["name"]
        full_path = parent_full_path + "::" + m_name
        if full_path in seen_full_paths:
            continue
        seen_full_paths.add(full_path)
        m_docs = (method_item.get("docs") or "").strip()
        m_desc = m_docs.split("\n")[0][:120] if m_docs else ""
        items.append({
            "name":      m_name,
            "path":      parent_full_path,
            "full_path": full_path,
            "kind":      "method",
            "desc":      m_desc,
            "url":       parent_url + "#method." + m_name,
        })

with open(%q, "w") as f:
    json.dump(items, f, separators=(",", ":"))

print(len(items))
]], json_gz_path, crate_name, base_url, out_path)

  -- Write script to temp file
  local script_path = config.options.cache_dir .. "/parse_crate_" .. crate_name .. ".py"
  local fd = io.open(script_path, "w")
  if not fd then
    callback("rust-docs: could not write parse script for " .. crate_name, nil)
    return
  end
  fd:write(script)
  fd:close()

  vim.system(
    { "python3", script_path },
    { text = true },
    function(result)
      vim.schedule(function()
        if result.code ~= 0 then
          callback(
            "rust-docs: parse failed for " .. crate_name .. ":\n" .. (result.stderr or result.stdout or ""),
            nil
          )
          return
        end

        local count = tonumber(result.stdout:match("^%d+")) or 0
        vim.notify(
          string.format("rust-docs: %s index ready (%d items)", crate_name, count),
          vim.log.levels.INFO
        )

        -- Load from cache
        local f = io.open(out_path, "r")
        if not f then
          callback("rust-docs: cache not found after parse: " .. out_path, nil)
          return
        end
        local raw = f:read("*a")
        f:close()
        local ok, items = pcall(vim.json.decode, raw,
          { luanil = { object = true, array = true } })
        if not ok then
          callback("rust-docs: cache decode failed for " .. crate_name, nil)
        else
          callback(nil, items)
        end
      end)
    end
  )
end

return M
