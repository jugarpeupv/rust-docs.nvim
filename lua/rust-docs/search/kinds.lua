--- Kind-aware query helpers for rust-docs.nvim.
---
--- Users naturally type things like "read trait" or "vec struct", expecting
--- the kind badge shown in the picker ([trait], [struct], …) to count for the
--- search. The underlying engines don't work that way:
---   - the std rustdoc engine treats "read trait" as a single literal query
---     and returns zero results,
---   - the crates.io/docs.rs item filter only matches name/path/desc.
---
--- This module splits a raw query into text tokens + kind groups so callers
--- can send the text remainder to the engine and filter results by kind.

local M = {}

--- Map a lowercase query token to a canonical kind group.
--- Brackets (as displayed, e.g. "[trait]") and plurals are accepted.
---@type table<string,string>
local TOKEN_TO_GROUP = {
  fn = "fn", func = "fn", ["function"] = "fn", functions = "fn",
  method = "method", methods = "method", tymethod = "method",
  struct = "struct", structs = "struct",
  enum = "enum", enums = "enum",
  trait = "trait", traits = "trait",
  mod = "mod", mods = "mod", module = "mod", modules = "mod",
  const = "const", constant = "const", constants = "const",
  static = "static", statics = "static",
  type = "typedef", types = "typedef", typedef = "typedef", typedefs = "typedef",
  typealias = "typedef", alias = "typedef",
  macro = "macro", macros = "macro", derive = "macro", attr = "macro",
  attribute = "macro", attributes = "macro",
  primitive = "primitive", primitives = "primitive", prim = "primitive",
  keyword = "keyword", keywords = "keyword",
  union = "union", unions = "union",
  variant = "variant", variants = "variant",
  field = "field", fields = "field", structfield = "field",
}

--- Normalize an item kind (as produced by the search engines) to a group key.
---@param kind string|nil
---@return string
function M.normalize_kind(kind)
  local k = (kind or ""):lower()
  if k == "tymethod" or k == "method" then return "method" end
  if k == "constant" or k == "associatedconstant" or k == "const" then return "const" end
  if k == "associatedtype" then return "typedef" end
  if k == "attr" or k == "derive" or k == "macro" then return "macro" end
  if k == "structfield" then return "field" end
  if k == "traitalias" then return "typedef" end
  return k
end

--- Split a raw query into an engine query plus requested kind groups.
---
--- Kind tokens are only extracted when at least one non-kind (text) token
--- remains, so a bare "trait" still searches for items literally named
--- "trait" instead of filtering everything out.
---
---@param query string
---@return string engine_query  text remainder joined with spaces (may equal query)
---@return string[] kinds       canonical kind groups requested (empty if none)
function M.split(query)
  local text_tokens = {}
  local kinds = {}
  local seen = {}

  for raw in (query or ""):gmatch("%S+") do
    local tok = raw:lower():gsub("^%[", ""):gsub("%]$", "")
    local group = TOKEN_TO_GROUP[tok]
    if group then
      if not seen[group] then
        seen[group] = true
        table.insert(kinds, group)
      end
    else
      table.insert(text_tokens, raw)
    end
  end

  -- Kind-only query (e.g. just "trait"): don't filter, search literally.
  if #text_tokens == 0 then
    return query or "", {}
  end

  return table.concat(text_tokens, " "), kinds
end

--- Return true if an item kind satisfies one of the requested kind groups.
---@param item_kind string|nil
---@param kinds string[]
---@return boolean
function M.kind_matches(item_kind, kinds)
  if not kinds or #kinds == 0 then return true end
  local group = M.normalize_kind(item_kind)
  for _, k in ipairs(kinds) do
    if group == k then return true end
  end
  return false
end

return M
