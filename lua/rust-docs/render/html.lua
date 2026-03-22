--- HTML to Markdown-ish renderer for Rust documentation pages.
--- Parses the rustdoc-generated HTML and produces structured plain text
--- with section headings, code blocks, and method signature lists.
---
--- We deliberately avoid a full HTML parser dependency. Rustdoc's HTML output
--- is consistent enough that targeted pattern matching works reliably.
---
--- Approach for impl sections:
---   1. Collect all <h2 id="..."> section markers with their byte offsets.
---   2. Iterate all <details class="...implementors-toggle..."> blocks.
---      Each block = one trait/impl group with an impl header, optional
---      availability note, and zero or more nested method-toggle details.
---   3. Assign each impl block to whichever h2 section precedes it.
---
---   For the "Implementations" section (inherent methods) there is typically
---   one outer implementors-toggle wrapping all method-toggle children, so the
---   same logic applies uniformly.

local M = {}

-- ---------------------------------------------------------------------------
-- Low-level HTML utilities
-- ---------------------------------------------------------------------------

--- Strip all HTML tags from a string, decoding common entities.
---@param s string
---@return string
local function strip_tags(s)
  -- Remove button elements entirely (e.g. "Copy item path" in h1)
  s = s:gsub("<button[^>]*>.-</button>", "")
  -- Headings → markdown (before generic tag removal)
  s = s:gsub("<h3[^>]*>(.-)</h3>", function(inner)
    inner = inner:gsub("<[^>]+>", ""):gsub("\xC2\xA7", ""):gsub("^%s+", ""):gsub("%s+$", "")
    return "\n### " .. inner .. "\n"
  end)
  s = s:gsub("<h2[^>]*>(.-)</h2>", function(inner)
    inner = inner:gsub("<[^>]+>", ""):gsub("\xC2\xA7", ""):gsub("^%s+", ""):gsub("%s+$", "")
    return "\n## " .. inner .. "\n"
  end)
  -- Block-level tags → newlines
  s = s:gsub("</p>",   "\n")
  s = s:gsub("</li>",  "\n")
  s = s:gsub("<br%s*/?>", "\n")
  s = s:gsub("<hr%s*/?>", "\n---\n")
  -- Inline code → backticks (process before stripping other tags)
  s = s:gsub("<code[^>]*>(.-)</code>", function(inner)
    -- strip any tags inside code (e.g. <a>, <span>)
    inner = inner:gsub("<[^>]+>", "")
    return "`" .. inner .. "`"
  end)
  -- Pre / code blocks
  s = s:gsub("<pre[^>]*>(.-)</pre>", function(inner)
    inner = inner:gsub("<[^>]+>", "")
    return "\n```rust\n" .. inner .. "\n```\n"
  end)
  -- Anchors: keep link text
  s = s:gsub("<a[^>]*>(.-)</a>", "%1")
  -- Remove remaining tags
  s = s:gsub("<[^>]+>", "")
  -- Decode common HTML entities
  s = s:gsub("&amp;",  "&")
  s = s:gsub("&lt;",   "<")
  s = s:gsub("&gt;",   ">")
  s = s:gsub("&quot;", '"')
  s = s:gsub("&#39;",  "'")
  s = s:gsub("&nbsp;", " ")
  s = s:gsub("&#x27;", "'")
  s = s:gsub("&#x2F;", "/")
  s = s:gsub("&#60;",  "<")
  s = s:gsub("&#62;",  ">")
  -- Section-anchor character (§) that rustdoc adds to headings
  s = s:gsub("\xC2\xA7", "")  -- UTF-8 for §
  -- Collapse excessive blank lines
  s = s:gsub("\n\n\n+", "\n\n")
  return s
end

-- ---------------------------------------------------------------------------
-- Section extractors
-- ---------------------------------------------------------------------------

--- Extract the item title from the <h1> tag.
---@param html string
---@return string
local function extract_title(html)
  local title = html:match("<h1[^>]*>(.-)</h1>")
  if title then
    return strip_tags(title):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
  end
  return ""
end

--- Extract the item declaration/signature from <pre class="rust item-decl">.
--- This gives the full pub fn / pub struct / pub enum signature with where clauses.
---@param html string
---@return string   empty string if not found
local function extract_signature(html)
  -- Match the entire <pre class="rust item-decl">...</pre> block
  local pre_s, pre_e = html:find('<pre[^>]+class="[^"]*item%-decl[^"]*"[^>]*>')
  if not pre_s then return "" end
  local close_s = html:find("</pre>", pre_e)
  if not close_s then return "" end
  local inner = html:sub(pre_e + 1, close_s - 1)
  -- Strip tags but preserve newlines that come from <br> / <div class="where">
  inner = inner:gsub('<div[^>]*class="[^"]*where[^"]*"[^>]*>', "\n")
  inner = inner:gsub("</div>", "")
  inner = inner:gsub("<br%s*/?>", "\n")
  inner = inner:gsub("<[^>]+>", "")
  -- Decode entities
  inner = inner:gsub("&amp;",  "&")
  inner = inner:gsub("&lt;",   "<")
  inner = inner:gsub("&gt;",   ">")
  inner = inner:gsub("&quot;", '"')
  inner = inner:gsub("&#39;",  "'")
  inner = inner:gsub("&nbsp;", " ")
  inner = inner:gsub("&#x27;", "'")
  inner = inner:gsub("&#x2F;", "/")
  -- Normalise indentation: trim leading/trailing blank lines, keep internal lines
  local result_lines = {}
  for line in (inner .. "\n"):gmatch("([^\n]*)\n") do
    table.insert(result_lines, line)
  end
  -- Trim leading/trailing blank lines
  while #result_lines > 0 and result_lines[1]:match("^%s*$") do
    table.remove(result_lines, 1)
  end
  while #result_lines > 0 and result_lines[#result_lines]:match("^%s*$") do
    table.remove(result_lines)
  end
  return table.concat(result_lines, "\n")
end

--- Finds the first <div class="docblock"> and extracts it by counting
--- <div>/<\/div> pairs so we get the full nested content.
---@param html string
---@return string
local function extract_main_desc(html)
  local tag_s, tag_e = html:find('<div[^>]+class="[^"]*docblock[^"]*"[^>]*>')
  if not tag_s then return "" end

  local pos   = tag_e + 1
  local depth = 1
  while depth > 0 and pos <= #html do
    local open_s  = html:find("<div[^>]*>", pos)
    local close_s, close_e = html:find("</div>", pos)

    if not close_s then break end

    if open_s and open_s < close_s then
      depth = depth + 1
      -- advance past the found open tag (at least 1 char)
      pos = open_s + 1
    else
      depth = depth - 1
      if depth == 0 then
        local inner = html:sub(tag_e + 1, close_s - 1)
        return strip_tags(inner):gsub("^%s+", ""):gsub("%s+$", "")
      end
      pos = close_e + 1
    end
  end
  return ""
end

--- Collect all <h2 id="..."> markers as a sorted list of {pos, id, label}.
--- Used to assign methods to their enclosing section.
---@param html string
---@return {pos:integer, id:string, label:string}[]
local function collect_section_markers(html)
  local markers = {}
  local search_pos = 1
  while true do
    -- Find next <h2 ... id="...">
    local tag_s, tag_e = html:find("<h2[^>]+>", search_pos)
    if not tag_s then break end
    local tag = html:sub(tag_s, tag_e)
    local id  = tag:match('id%s*=%s*"([^"]*)"')
    -- Grab the text inside the h2
    local close_s = html:find("</h2>", tag_e)
    local label = ""
    if close_s then
      label = strip_tags(html:sub(tag_e + 1, close_s - 1))
             :gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    end
    if id then
      table.insert(markers, { pos = tag_s, id = id, label = label })
    end
    search_pos = tag_e + 1
  end
  return markers
end

--- Given a byte position and the sorted section markers, return the label
--- of the section that contains that position.
---@param pos integer
---@param markers {pos:integer, id:string, label:string}[]
---@return string
local function section_for_pos(pos, markers)
  local label = "Implementations"
  for _, m in ipairs(markers) do
    if m.pos <= pos then
      label = m.label
    else
      break
    end
  end
  return label
end

--- Find the matching </details> for a <details> opening tag at `tag_e`,
--- correctly handling arbitrary nesting depth.
---@param html string
---@param tag_e integer  byte offset of end of the opening <details ...> tag
---@return integer|nil   byte offset of the first char of the closing </details>
local function find_details_close(html, tag_e)
  local pos   = tag_e + 1
  local depth = 1
  while depth > 0 and pos <= #html do
    local open_s  = html:find("<details[^>]*>", pos)
    local close_s, close_e = html:find("</details>", pos)
    if not close_s then return nil end
    if open_s and open_s < close_s then
      depth = depth + 1
      pos   = open_s + 1
    else
      depth = depth - 1
      if depth == 0 then return close_s end
      pos = close_e + 1
    end
  end
  return nil
end

--- Extract the first doc-comment line from a snippet of HTML.
--- Looks for the first <div class="docblock"> and returns the first paragraph.
---@param snippet string
---@return string
local function extract_first_doc(snippet)
  local doc_s, doc_e = snippet:find('<div[^>]+class=["\']?[^"\']*docblock[^"\']*["\']?[^>]*>')
  if not doc_s then return "" end
  -- Walk forward counting <div>/<\/div> pairs to find the real closing tag
  local pos   = doc_e + 1
  local depth = 1
  while depth > 0 and pos <= #snippet do
    local open_s  = snippet:find("<div[^>]*>", pos)
    local close_s, close_e = snippet:find("</div>", pos)
    if not close_s then break end
    if open_s and open_s < close_s then
      depth = depth + 1
      pos   = open_s + 1
    else
      depth = depth - 1
      if depth == 0 then
        local raw = strip_tags(snippet:sub(doc_e + 1, close_s - 1))
        -- Return first non-empty line
        for line in raw:gmatch("[^\n]+") do
          line = line:gsub("^%s+", ""):gsub("%s+$", "")
          if line ~= "" then return line end
        end
        return ""
      end
      pos = close_e + 1
    end
  end
  return ""
end

--- Collect bare <section class="impl"> blocks that are NOT wrapped in a
--- <details> element. This covers "Auto Trait Implementations" (rustdoc's
--- synthetic-implementations-list), where each impl is just a plain section:
---
---   <section id="impl-Freeze-for-TcpListener" class="impl">
---     <h3 class="code-header">impl Freeze for TcpListener</h3>
---   </section>
---
--- Returns entries in the same shape as collect_impl_blocks so they can be
--- merged into the same rendering pipeline.
---
---@param html string
---@param markers {pos:integer, id:string, label:string}[]
---@return {section:string, impl_header:string, availability:string, methods:{sig:string,doc:string}[]}[]
local function collect_bare_impl_sections(html, markers)
  local results    = {}
  local search_pos = 1

  while true do
    -- Find <section ... class="impl" ...> (attribute order may vary)
    local tag_s, tag_e = html:find('<section[^>]+class="[^"]*%f[%w]impl%f[%W][^"]*"[^>]*>', search_pos)
    if not tag_s then break end

    -- Skip any that are already inside a <details> — find the nearest preceding
    -- <details> and </details> and check containment. Fast heuristic: look
    -- backward for the closest unclosed <details>.
    -- Simpler approach: skip if the immediately enclosing context is a <details>.
    -- We detect this by checking whether there is a <details ...> that started
    -- before tag_s and whose </details> ends after tag_s.
    -- Rather than doing a full backwards parse, we use the fact that we already
    -- handle implementors-toggle blocks via collect_impl_blocks. We want ONLY
    -- sections that are direct children of a list div (no surrounding <details>).
    -- Heuristic: if the 200 chars before tag_s contain an unclosed <details>,
    -- skip this section.
    local preceding = html:sub(math.max(1, tag_s - 300), tag_s - 1)
    local details_open  = select(2, preceding:gsub("<details[^>]*>", ""))
    local details_close = select(2, preceding:gsub("</details>", ""))
    if details_open > details_close then
      -- Inside a <details> block — already handled by collect_impl_blocks
      search_pos = tag_e + 1
      goto continue
    end

    do
      local close_s = html:find("</section>", tag_e)
      if not close_s then break end

      local inner = html:sub(tag_e + 1, close_s - 1)
      local sec   = section_for_pos(tag_s, markers)

      local impl_header = ""
      local h3_html = inner:match('<h3[^>]*class="[^"]*code%-header[^"]*"[^>]*>(.-)</h3>')
      if h3_html then
        impl_header = strip_tags(h3_html):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
      end

      if impl_header ~= "" then
        table.insert(results, {
          section      = sec,
          impl_header  = impl_header,
          availability = "",
          methods      = {},
        })
      end

      search_pos = close_s + 1
    end

    ::continue::
  end

  return results
end

--- Collect impl blocks structured as:
---   { section, impl_header, availability, methods[] }
--- where methods[] = { sig, doc }
---
--- Walks all <details class="...implementors-toggle..."> in the HTML.
--- Each such block represents one impl group (inherent impl or trait impl).
--- Its inner <details class="...method-toggle..."> children are the methods.
---
---@param html string
---@param markers {pos:integer, id:string, label:string}[]
---@return {section:string, impl_header:string, availability:string, methods:{sig:string,doc:string}[]}[]
local function collect_impl_blocks(html, markers)
  local results    = {}
  local search_pos = 1

  while true do
    -- Find the next implementors-toggle opening tag
    local tag_s, tag_e = html:find('<details[^>]+class="[^"]*implementors%-toggle[^"]*"[^>]*>', search_pos)
    if not tag_s then break end

    -- Find the matching </details> (depth-aware — methods are nested inside)
    local close_s = find_details_close(html, tag_e)
    if not close_s then break end

    local block = html:sub(tag_e + 1, close_s - 1)
    local sec   = section_for_pos(tag_s, markers)

    -- ── impl header from <h3 class="code-header"> inside <summary> ──────────
    local impl_header = ""
    local h3_html = block:match('<h3[^>]*class="[^"]*code%-header[^"]*"[^>]*>(.-)</h3>')
    if h3_html then
      impl_header = strip_tags(h3_html):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    end

    -- ── availability / portability note (optional) ───────────────────────────
    local availability = ""
    local stab_html = block:match('<div[^>]+class="[^"]*stab portability[^"]*"[^>]*>(.-)</div>')
    if stab_html then
      availability = strip_tags(stab_html):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    end

    -- ── methods: nested method-toggle details ────────────────────────────────
    local methods    = {}
    local meth_pos   = 1
    while true do
      local mt_s, mt_e = block:find('<details[^>]+class="[^"]*method%-toggle[^"]*"[^>]*>', meth_pos)
      if not mt_s then break end

      local mt_close = find_details_close(block, mt_e)
      if not mt_close then break end

      local minner = block:sub(mt_e + 1, mt_close - 1)

      -- Signature: prefer h4, fall back to h3
      local sig_html = minner:match('<h4[^>]*class="[^"]*code%-header[^"]*"[^>]*>(.-)</h4>')
                    or minner:match('<h3[^>]*class="[^"]*code%-header[^"]*"[^>]*>(.-)</h3>')
      local sig = ""
      if sig_html then
        sig = strip_tags(sig_html):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
      end

      local doc = extract_first_doc(minner)

      if sig ~= "" then
        table.insert(methods, { sig = sig, doc = doc })
      end

      meth_pos = mt_close + 1
    end

    -- Only include blocks that have at least a header or methods
    if impl_header ~= "" or #methods > 0 then
      table.insert(results, {
        section      = sec,
        impl_header  = impl_header,
        availability = availability,
        methods      = methods,
      })
    end

    search_pos = close_s + 1
  end

  return results
end

-- ---------------------------------------------------------------------------
-- Crate index section extractor
-- ---------------------------------------------------------------------------

--- Resolve a relative href against a base URL.
--- e.g. base = "https://docs.rs/serde_json/1.0/serde_json/"
---       href = "fn.from_reader.html"
---       → "https://docs.rs/serde_json/1.0/serde_json/fn.from_reader.html"
---@param base string
---@param href string
---@return string
local function resolve_url(base, href)
  if href:match("^https?://") then return href end
  -- Strip query/fragment from href
  href = href:gsub("[?#].*", "")
  -- Separate protocol from the rest so we never mangle the "//"
  local proto, rest = base:match("^(https?://)(.*)")
  if not proto then
    proto = "https://"
    rest  = base
  end
  -- rest = "docs.rs/serde_json/1.0/serde_json/" (no protocol)
  -- Drop everything after the last "/" to get the directory
  local dir = rest:match("^(.*/)") or ""
  -- Split dir into path segments
  local parts = {}
  for seg in dir:gmatch("[^/]+") do table.insert(parts, seg) end
  -- Apply href segments (handle ../ and ./)
  for seg in href:gmatch("[^/]+") do
    if seg == ".." then
      if #parts > 0 then parts[#parts] = nil end
    elseif seg ~= "." then
      table.insert(parts, seg)
    end
  end
  return proto .. table.concat(parts, "/")
end

--- The crate items section IDs rustdoc uses and their human-readable labels.
--- Order matches rustdoc's page order.
local CRATE_SECTION_IDS = {
  { id = "reexports",   label = "Re-exports"   },
  { id = "modules",     label = "Modules"      },
  { id = "macros",      label = "Macros"       },
  { id = "structs",     label = "Structs"      },
  { id = "enums",       label = "Enums"        },
  { id = "unions",      label = "Unions"       },
  { id = "constants",   label = "Constants"    },
  { id = "statics",     label = "Statics"      },
  { id = "traits",      label = "Traits"       },
  { id = "functions",   label = "Functions"    },
  { id = "types",       label = "Type Aliases" },
  { id = "attributes",  label = "Attribute Macros" },
  { id = "derives",     label = "Derive Macros" },
}

--- Extract the crate-level item sections (Modules, Structs, Functions, etc.)
--- that rustdoc renders as <dl class="item-table"> blocks after the crate description.
---
--- Returns a list of sections, each with a label and a list of items.
--- Each item has: name, href (absolute), kind, desc, portability (optional note).
---
---@param html string
---@param base_url string   The URL of the page, used to resolve relative hrefs
---@return { label:string, items:{name:string, href:string, kind:string, desc:string, portability:string}[] }[]
local function extract_crate_sections(html, base_url)
  local result = {}

  for _, sec in ipairs(CRATE_SECTION_IDS) do
    -- Find the <h2 id="<sec.id>" ...> tag
    local h2_pat = '<h2[^>]+id%s*=%s*"' .. sec.id .. '"[^>]*>'
    local h2_s, h2_e = html:find(h2_pat)
    if not h2_s then goto continue_sec end

    -- Find the next <dl class="item-table"> after the h2
    local dl_s, dl_e = html:find('<dl[^>]+class="[^"]*item%-table[^"]*"[^>]*>', h2_e)
    if not dl_s then goto continue_sec end

    -- Find its closing </dl>
    local dl_close = html:find("</dl>", dl_e)
    if not dl_close then goto continue_sec end

    local dl_inner = html:sub(dl_e + 1, dl_close - 1)

    -- Walk all <dt>…</dt> / <dd>…</dd> pairs
    local items = {}
    local pos = 1
    while true do
      local dt_s, dt_e = dl_inner:find("<dt[^>]*>", pos)
      if not dt_s then break end
      local dt_close = dl_inner:find("</dt>", dt_e)
      if not dt_close then break end

      local dt_inner = dl_inner:sub(dt_e + 1, dt_close - 1)

      -- Extract href and title from the anchor
      local href_rel = dt_inner:match('<a[^>]+href%s*=%s*"([^"]*)"')
      local kind     = dt_inner:match('<a[^>]+class%s*=%s*"([^"]*)"')
                    or dt_inner:match('title%s*=%s*"([^"]+)%s+[^"]*"') -- fallback
      -- Normalise kind: "fn", "struct", "enum", "mod", "macro", "trait", "type", etc.
      if kind then kind = kind:match("^(%S+)") end

      -- Item name: strip <wbr> and other tags, decode entities
      local name_raw = dt_inner:gsub("<wbr>", ""):gsub('<span[^>]*>.-</span>', "")
      local name = strip_tags(name_raw):gsub("%s+", ""):gsub("^%s+", ""):gsub("%s+$", "")

      -- Portability note (e.g. "std", "nightly-only")
      local portability = ""
      local stab = dt_inner:match('<span[^>]+class="[^"]*stab[^"]*"[^>]*>(.-)</span>')
      if stab then
        portability = strip_tags(stab):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
      end

      -- <dd> immediately after </dt>
      local dd_s, dd_e = dl_inner:find("<dd[^>]*>", dt_close + 1)
      local desc = ""
      if dd_s then
        local dd_close = dl_inner:find("</dd>", dd_e)
        if dd_close then
          desc = strip_tags(dl_inner:sub(dd_e + 1, dd_close - 1))
                  :gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
        end
        pos = (dd_close or dt_close) + 1
      else
        pos = dt_close + 1
      end

      if href_rel and name ~= "" then
        local abs_href = resolve_url(base_url, href_rel)
        table.insert(items, {
          name        = name,
          href        = abs_href,
          kind        = kind or sec.id:gsub("s$", ""),  -- fallback: strip plural
          desc        = desc,
          portability = portability,
        })
      end
    end

    if #items > 0 then
      table.insert(result, { label = sec.label, items = items })
    end

    ::continue_sec::
  end

  return result
end

-- ---------------------------------------------------------------------------
-- Renderer: assemble lines
-- ---------------------------------------------------------------------------

--- Render a parsed doc page into a list of lines suitable for a Neovim buffer.
--- Also returns a link_map: { [1-based line number] = absolute_url } for every
--- item line that has a navigable doc link (used by the gd keymap).
---@param html string
---@param url string
---@return string[], table<integer,string>
function M.render(html, url)
  local lines    = {}
  local link_map = {}  -- [line_number] = absolute_url

  local function push(s)
    for _, line in ipairs(vim.split(s or "", "\n", { plain = true })) do
      table.insert(lines, line)
    end
  end

  --- Push a line that carries a navigable link.
  ---@param s string
  ---@param href string
  local function push_link(s, href)
    for _, line in ipairs(vim.split(s or "", "\n", { plain = true })) do
      local ln = #lines + 1
      table.insert(lines, line)
      link_map[ln] = href
    end
  end

  local function section_header(label)
    table.insert(lines, "")
    table.insert(lines, "# " .. label)
    table.insert(lines, "")
  end

  -- ── Title ──────────────────────────────────────────────────────────────────
  local title = extract_title(html)
  if title ~= "" then
    push("# " .. title)
    push("")
  end

  -- Source URL (for gx keymap)
  push("URL: " .. url)
  push("")

  -- ── Signature ──────────────────────────────────────────────────────────────
  local sig = extract_signature(html)
  if sig ~= "" then
    section_header("Signature")
    push("```rust")
    push(sig)
    push("```")
    push("")
  end

  -- ── Description ────────────────────────────────────────────────────────────
  local desc = extract_main_desc(html)
  if desc ~= "" then
    section_header("Description")
    push(desc)
    push("")
  end

  -- ── Implementations ────────────────────────────────────────────────────────
  local markers     = collect_section_markers(html)
  local impl_blocks = collect_impl_blocks(html, markers)
  local bare_blocks = collect_bare_impl_sections(html, markers)

  -- Merge: bare blocks go after impl_blocks (they appear later in the page)
  for _, blk in ipairs(bare_blocks) do
    table.insert(impl_blocks, blk)
  end

  -- Group impl blocks by section (preserving first-seen order)
  local section_order  = {}
  local section_groups = {}
  for _, blk in ipairs(impl_blocks) do
    if not section_groups[blk.section] then
      table.insert(section_order, blk.section)
      section_groups[blk.section] = {}
    end
    table.insert(section_groups[blk.section], blk)
  end

  -- Sections to render (skip blanket impls unless something else is present)
  local render_sections = {
    "Implementations",
    "Trait Implementations",
    "Auto Trait Implementations",
  }
  if #section_order > 0 then
    table.insert(render_sections, "Blanket Implementations")
  end

  for _, sec_label in ipairs(render_sections) do
    local group = section_groups[sec_label]
    if group and #group > 0 then
      section_header(sec_label)

      for _, blk in ipairs(group) do
        -- Emit impl header as ## subheading (e.g. "impl AsFd for TcpListener")
        if blk.impl_header ~= "" then
          push("")
          push("## " .. blk.impl_header)
          push("")
        end
        -- Emit availability / portability note
        if blk.availability ~= "" then
          push("*" .. blk.availability .. "*")
          push("")
        end
        -- Emit each method
        for _, method in ipairs(blk.methods) do
          push("```rust")
          push(method.sig)
          push("```")
          if method.doc ~= "" then
            push(method.doc)
          end
          push("")
        end
      end
    end
  end

  -- ── Crate item sections (Modules, Structs, Functions, …) ───────────────────
  -- These are present on crate/module index pages. On item pages (fn, struct…)
  -- this will return an empty list so it's a no-op there.
  local crate_sections = extract_crate_sections(html, url)
  for _, csec in ipairs(crate_sections) do
    section_header(csec.label)

    -- Column widths for alignment
    local name_w = 0
    for _, item in ipairs(csec.items) do
      if #item.name > name_w then name_w = #item.name end
    end
    name_w = math.min(name_w, 40)

    for _, item in ipairs(csec.items) do
      -- Format: "  name_padded   desc [portability]"
      local name_col = item.name
      if #name_col < name_w then
        name_col = name_col .. string.rep(" ", name_w - #name_col)
      end
      local portability_suffix = item.portability ~= "" and ("  [" .. item.portability .. "]") or ""
      local line = "  " .. name_col .. "   " .. item.desc .. portability_suffix
      push_link(line, item.href)
    end

    push("")
  end

  -- ── Footer ─────────────────────────────────────────────────────────────────
  push("")
  push("*rust-docs.nvim*")
  push("")

  return lines, link_map
end

return M
