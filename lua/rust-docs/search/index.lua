--- Search index loader for rust-docs.nvim
---
--- Primary source: local rustdoc JSON shipped with the rust-docs-json component.
---   rustup component add rust-docs-json [--toolchain nightly]
---   File: <sysroot>/share/doc/rust/json/std.json
---
--- The JSON format (rustdoc-types) is stable and structured, with full paths,
--- item kinds, doc comments, and impl references.

local M = {}

local config = require("rust-docs.config")

-- Map rustdoc JSON "kind" strings to display labels used elsewhere in the plugin.
---@type table<string, string>
local KIND_MAP = {
  struct       = "struct",
  enum         = "enum",
  ["function"] = "fn",
  trait        = "trait",
  module       = "mod",
  constant     = "const",
  static       = "static",
  type_alias   = "typedef",
  macro        = "macro",
  primitive    = "primitive",
  assoc_type   = "associated type",
  assoc_const  = "associated const",
  variant      = "variant",
  struct_field = "struct field",
  impl         = "impl",
  use          = "use",
}

-- URL segment for each kind (used to build doc.rust-lang.org URLs).
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

--- Build the doc.rust-lang.org URL for an item.
---@param path_parts string[]  e.g. {"std", "net", "TcpListener"}
---@param kind string          display kind, e.g. "struct"
---@return string
local function build_url(path_parts, kind)
  local base = config.options.base_url  -- e.g. "https://doc.rust-lang.org/std"

  -- path_parts = ["std", "net", "TcpListener"]
  -- base already covers "std", so module path is parts[2..n-1]
  -- and item name is parts[n]
  if #path_parts == 0 then
    return base .. "/index.html"
  end

  local name = path_parts[#path_parts]
  -- Module path segments between "std" and the item name
  local mid = {}
  for i = 2, #path_parts - 1 do
    table.insert(mid, path_parts[i])
  end
  local mid_seg = (#mid > 0) and (table.concat(mid, "/") .. "/") or ""

  local type_seg = KIND_URL_SEG[kind]
  if type_seg == "index" then
    -- Module itself
    return base .. "/" .. mid_seg .. name .. "/index.html"
  elseif type_seg then
    return base .. "/" .. mid_seg .. type_seg .. "." .. name .. ".html"
  else
    -- Items without their own page (impls, fields, variants) link to parent
    if #mid > 0 then
      return base .. "/" .. mid_seg .. "index.html"
    end
    return base .. "/index.html"
  end
end

--- Locate the std.json file from any installed toolchain.
--- Checks: config.toolchain_json (user override), then rustup toolchains,
--- then a plain `rustc --print sysroot` fallback.
---@return string|nil path, string|nil err
local function find_std_json()
  -- 1. User-supplied explicit path
  if config.options.toolchain_json and config.options.toolchain_json ~= "" then
    local stat = vim.uv.fs_stat(config.options.toolchain_json)
    if stat then return config.options.toolchain_json, nil end
    return nil, "toolchain_json path does not exist: " .. config.options.toolchain_json
  end

  -- 2. Search rustup toolchains (prefer nightly, accept stable)
  local rustup_home = os.getenv("RUSTUP_HOME")
    or (os.getenv("HOME") .. "/.rustup")
  local toolchains_dir = rustup_home .. "/toolchains"

  local handle = vim.uv.fs_scandir(toolchains_dir)
  if handle then
    local candidates = {}
    while true do
      local name, ftype = vim.uv.fs_scandir_next(handle)
      if not name then break end
      if ftype == "directory" then
        local json_path = toolchains_dir .. "/" .. name .. "/share/doc/rust/json/std.json"
        local stat = vim.uv.fs_stat(json_path)
        if stat then
          table.insert(candidates, { name = name, path = json_path })
        end
      end
    end
    -- Sort: prefer nightly > beta > stable
    table.sort(candidates, function(a, b)
      local function score(n)
        if n:find("nightly") then return 0 end
        if n:find("beta")    then return 1 end
        return 2
      end
      return score(a.name) < score(b.name)
    end)
    if #candidates > 0 then
      return candidates[1].path, nil
    end
  end

  -- 3. Fallback: rustc --print sysroot
  local result = vim.system({ "rustc", "--print", "sysroot" }, { text = true }):wait()
  if result.code == 0 then
    local sysroot = result.stdout:gsub("%s+$", "")
    local json_path = sysroot .. "/share/doc/rust/json/std.json"
    local stat = vim.uv.fs_stat(json_path)
    if stat then return json_path, nil end
  end

  return nil, table.concat({
    "rust-docs: std.json not found. Install it with:",
    "  rustup component add rust-docs-json",
    "  (or: rustup component add rust-docs-json --toolchain nightly)",
  }, "\n")
end

--- Return path to the pre-processed item cache (avoids re-parsing the large JSON).
---@return string
local function cache_path()
  return config.options.cache_dir .. "/items.json"
end

--- Check whether the cache is valid against the source std.json mtime.
---@param source_path string
---@return boolean
local function cache_valid(source_path)
  local cache = vim.uv.fs_stat(cache_path())
  if not cache then return false end
  local source = vim.uv.fs_stat(source_path)
  if not source then return false end
  -- Cache is valid if it is newer than the source JSON and within TTL
  local age = os.time() - cache.mtime.sec
  return cache.mtime.sec >= source.mtime.sec and age < config.options.index_ttl
end

--- Parse std.json into a flat list of RustDocs.Item, then cache as compact JSON.
--- Runs in a separate thread via vim.system to avoid blocking the main loop.
---@param json_path string
---@param callback fun(err: string|nil, items: RustDocs.Item[]|nil)
local function parse_and_cache(json_path, callback)
  vim.notify("rust-docs: parsing std.json (first run, may take a moment)...", vim.log.levels.INFO)

  -- Use Python3 to do the heavy lifting off the Lua/Neovim main loop.
  -- This extracts only the fields we need and writes a compact JSON array.
  --
  -- Key design decisions:
  --   - The rustdoc JSON `paths` dict reflects INTERNAL module structure, not the
  --     public re-export path. E.g. TcpListener has internal path std::net::tcp::TcpListener
  --     but is publicly re-exported at std::net::TcpListener. We resolve this by following
  --     `use` items to find the shortest public path for each item.
  --   - Items without a resolved std path are skipped (internal/private items).
  local out_path = cache_path()
  local script = string.format([[
import json, os, re

with open(%q) as f:
    data = json.load(f)

index = data["index"]
paths = data["paths"]

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
HTML_BASE = os.path.join(os.path.dirname(os.path.dirname(%q)), "html")  # <sysroot>/share/doc/rust/html

# Items whose kind has no standalone doc page (skip from picker)
SKIP_KINDS = {"impl", "use", "struct_field", "variant", "assoc_type", "assoc_const"}

# Kinds whose HTML pages may contain #method.* anchors worth indexing
METHOD_PARENT_KINDS = {"struct", "enum", "trait", "primitive", "type_alias"}

# ---- Type-to-string helper (for params/ret extraction) ----
def type_to_str(t, depth=0):
    """Recursively convert a rustdoc JSON type object to a short readable string."""
    if depth > 6 or t is None:
        return ""
    if isinstance(t, str):
        return t
    if not isinstance(t, dict):
        return ""
    if "primitive" in t:
        return t["primitive"]
    if "generic" in t:
        return t["generic"]
    if "resolved_path" in t:
        rp = t["resolved_path"]
        name = (rp.get("path") or "").split("::")[-1]
        args = rp.get("args") or {}
        ab = args.get("angle_bracketed", {})
        type_args = [type_to_str(a["type"], depth+1) for a in ab.get("args", []) if "type" in a]
        type_args = [s for s in type_args if s]
        return (name + "<" + ", ".join(type_args) + ">") if type_args else name
    if "borrowed_ref" in t:
        br = t["borrowed_ref"]
        inner = type_to_str(br.get("type"), depth+1)
        return "&" + ("mut " if br.get("is_mutable") else "") + inner
    if "raw_pointer" in t:
        rp = t["raw_pointer"]
        return "*" + ("mut " if rp.get("is_mutable") else "const ") + type_to_str(rp.get("type"), depth+1)
    if "slice" in t:
        return "[" + type_to_str(t["slice"], depth+1) + "]"
    if "array" in t:
        return "[" + type_to_str(t["array"].get("type"), depth+1) + "]"
    if "tuple" in t:
        return "(" + ", ".join(type_to_str(x, depth+1) for x in t["tuple"]) + ")"
    if "impl_trait" in t:
        names = [b["trait_bound"]["trait"].get("path","").split("::")[-1]
                 for b in t["impl_trait"] if "trait_bound" in b]
        return "impl " + " + ".join(names)
    if "dyn_trait" in t:
        names = [tb.get("trait",{}).get("path","").split("::")[-1]
                 for tb in t["dyn_trait"].get("traits", [])]
        return "dyn " + " + ".join(names)
    return ""

def sig_to_params_ret(inner, kind_key):
    """Extract (params_str, ret_str) from a function/method inner dict."""
    fn_inner = inner.get(kind_key) or {}
    sig = fn_inner.get("sig") or {}
    inputs = sig.get("inputs") or []
    params = []
    for pname, ptype in inputs:
        if pname == "self":
            continue
        s = type_to_str(ptype)
        if s:
            params.append(s)
    output = sig.get("output")
    ret = type_to_str(output) if output else ""
    return " ".join(params), ret

# ---- Build public re-export paths from 'use' items ----
# The paths[] dict uses internal module paths; re-exports give us the public path.
# We walk module.items to find parent modules, then follow use items to their targets.

# child_id -> parent_module_id (string keys)
child_to_module = {}
# module_id -> path parts (only for modules with a known std path)
module_paths_by_id = {}

for item_id, item in index.items():
    inner = item.get("inner") or {}
    if "module" not in inner:
        continue
    for child_id in inner["module"].get("items", []):
        child_to_module[str(child_id)] = item_id
    if item_id in paths and paths[item_id]["path"][:1] == ["std"]:
        module_paths_by_id[item_id] = paths[item_id]["path"]

# target_id -> shortest public std path
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

# ---- Extract top-level items ----
items = []
seen_full_paths = set()
# parent_url -> (full_path, kind_key) for method extraction pass
method_parents = []

for item_id, item in index.items():
    if not item.get("name"):
        continue
    inner = item.get("inner") or {}
    kind_key = list(inner.keys())[0] if inner else None
    if not kind_key or kind_key in SKIP_KINDS:
        continue

    # Prefer public re-export path; fall back to paths dict
    pub_path = public_paths.get(item_id)
    orig_info = paths.get(item_id)

    if pub_path and pub_path[:1] == ["std"]:
        path_parts = pub_path
    elif orig_info and orig_info["path"][:1] == ["std"]:
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
    parent_path = "::".join(path_parts[:-1]) if len(path_parts) > 1 else "std"

    # Build URL from the (public) path
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
        "params":    sig_to_params_ret(inner, kind_key)[0] if kind_key in ("function", "method") else "",
        "ret":       sig_to_params_ret(inner, kind_key)[1] if kind_key in ("function", "method") else "",
    })

    if kind_key in METHOD_PARENT_KINDS and type_seg and type_seg != "index":
        method_parents.append((full_path, url))

# ---- Extract methods from local HTML pages ----
# The rustdoc JSON does not include methods from re-exported foreign crate types
# (e.g. sort_by on [T] comes from alloc but is documented under std::primitive::slice).
# Parsing #method.* anchors from the local HTML is the most complete source.

METHOD_ANCHOR = re.compile(r'id="method\.([^"]+)"')

def url_to_html_path(url):
    # https://doc.rust-lang.org/std/net/struct.TcpListener.html
    #   -> <html_base>/std/net/struct.TcpListener.html
    suffix = url.replace("https://doc.rust-lang.org/", "")
    return os.path.join(HTML_BASE, suffix)

for parent_full_path, parent_url in method_parents:
    html_path = url_to_html_path(parent_url)
    if not os.path.exists(html_path):
        continue
    try:
        with open(html_path, encoding="utf-8", errors="ignore") as f:
            content = f.read()
    except OSError:
        continue

    seen_methods = set()
    for method_name in METHOD_ANCHOR.findall(content):
        # Deduplicate; strip numeric suffix used for overloads (e.g. sort_floats-1)
        base_name = method_name.split("-")[0] if method_name[-1].isdigit() and "-" in method_name else method_name
        if base_name in seen_methods:
            continue
        seen_methods.add(base_name)
        full_path = parent_full_path + "::" + base_name
        if full_path in seen_full_paths:
            continue
        seen_full_paths.add(full_path)
        items.append({
            "name":      base_name,
            "path":      parent_full_path,
            "full_path": full_path,
            "kind":      "method",
            "desc":      "",
            "params":    "",
            "ret":       "",
            "url":       parent_url + "#method." + base_name,
        })

with open(%q, "w") as f:
    json.dump(items, f, separators=(",", ":"))

print(len(items))
]], json_path, config.options.base_url, json_path, out_path)

  -- Write script to a temp file to avoid shell quoting issues
  local script_path = config.options.cache_dir .. "/parse_index.py"
  local fd = io.open(script_path, "w")
  if not fd then
    callback("rust-docs: could not write temp script to " .. script_path, nil)
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
          local err_msg = result.stderr or result.stdout or "unknown error"
          callback("rust-docs: parse failed:\n" .. err_msg, nil)
        else
          local count = tonumber(result.stdout:match("^%d+")) or 0
          vim.notify(
            string.format("rust-docs: index ready (%d items)", count),
            vim.log.levels.INFO
          )
          callback(nil, nil)  -- signal success; caller will load from cache
        end
      end)
    end
  )
end

--- Load items from the pre-processed cache file.
---@return RustDocs.Item[]
local function load_from_cache()
  local path = cache_path()
  local fd = io.open(path, "r")
  if not fd then
    error("rust-docs: cache not found: " .. path)
  end
  local raw = fd:read("*a")
  fd:close()
  local ok, items = pcall(vim.json.decode, raw, { luanil = { object = true, array = true } })
  if not ok then
    error("rust-docs: cache decode failed: " .. tostring(items))
  end
  return items
end

--- Get the search index items, building the cache when needed.
---@param callback fun(err: string|nil, items: RustDocs.Item[]|nil)
function M.get_items(callback)
  local json_path, err = find_std_json()
  if not json_path then
    callback(err, nil)
    return
  end

  if cache_valid(json_path) then
    local ok, result = pcall(load_from_cache)
    if ok then
      callback(nil, result)
      return
    end
    -- Cache corrupted — fall through to rebuild
  end

  parse_and_cache(json_path, function(parse_err, _)
    if parse_err then
      callback(parse_err, nil)
      return
    end
    local ok, result = pcall(load_from_cache)
    if not ok then
      callback("rust-docs: failed to load cache: " .. tostring(result), nil)
    else
      callback(nil, result)
    end
  end)
end

--- Force rebuild of the index cache.
---@param callback? fun(err: string|nil)
function M.refresh(callback)
  -- Delete cache so next get_items call rebuilds
  vim.uv.fs_unlink(cache_path(), function() end)
  M.get_items(function(err, _)
    if callback then callback(err) end
  end)
end

-- Re-export item_url for use by other modules (e.g. buffer.lua)
function M.item_url(path, name, kind)
  local parts = {}
  for p in (path .. "::" .. name):gmatch("[^:]+") do
    table.insert(parts, p)
  end
  return build_url(parts, kind)
end

return M
