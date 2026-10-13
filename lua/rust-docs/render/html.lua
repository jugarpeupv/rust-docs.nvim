--- HTML to Markdown renderer for Rust documentation pages.
--- Parses rustdoc HTML and produces structured plain text with section headings,
--- code blocks, method signatures, full docblocks, implementors, TOC, and module items.
---
--- Works without external HTML parser dependencies.

local M = {}

-- ---------------------------------------------------------------------------
-- Low-level HTML utilities
-- ---------------------------------------------------------------------------

--- Resolve a relative href against a base URL.
--- Preserves in-page anchors ("#...") and absolute URLs ("https://...").
--- e.g. base = "https://doc.rust-lang.org/std/io/trait.Read.html"
---       href = "../fs/struct.File.html"
---       → "https://doc.rust-lang.org/std/fs/struct.File.html"
---@param base string
---@param href string
---@return string
function M.resolve_url(base, href)
  if href:match("^https?://") or href:match("^#") then
    return href
  end
  -- Strip query/fragment from href before resolving path
  local clean_href = href:gsub("[?#].*", "")
  local proto, rest = base:match("^(https?://)(.*)")
  if not proto then
    proto = "https://"
    rest  = base
  end
  local dir = rest:match("^(.*/)") or ""
  local parts = {}
  for seg in dir:gmatch("[^/]+") do
    table.insert(parts, seg)
  end
  for seg in clean_href:gmatch("[^/]+") do
    if seg == ".." then
      if #parts > 0 then parts[#parts] = nil end
    elseif seg ~= "." then
      table.insert(parts, seg)
    end
  end
  return proto .. table.concat(parts, "/")
end

local resolve_url = M.resolve_url

--- Find matching closing tag </tag_name> for an opening tag at tag_e.
--- Correctly handles arbitrary nesting depth.
---@param str string
---@param tag_e integer
---@param tag_name string
---@return integer|nil
local function find_element_close(str, tag_e, tag_name)
  local pos = tag_e + 1
  local depth = 1
  local open_pat = "<" .. tag_name .. "[%s>]"
  local close_pat = "</" .. tag_name .. ">"
  while depth > 0 and pos <= #str do
    local open_s = str:find(open_pat, pos)
    local close_s, close_e = str:find(close_pat, pos)
    if not close_s then return nil end
    if open_s and open_s < close_s then
      depth = depth + 1
      pos = open_s + #tag_name + 1
    else
      depth = depth - 1
      if depth == 0 then return close_s end
      pos = close_e + 1
    end
  end
  return nil
end

--- Find the matching </details> for a <details> opening tag at `tag_e`.
---@param html string
---@param tag_e integer
---@return integer|nil
local function find_details_close(html, tag_e)
  return find_element_close(html, tag_e, "details")
end

--- Strip all HTML tags from a string, decoding entities and converting markdown formatting.
---@param s string
---@return string
local function strip_tags(s)
  -- Remove interactive/UI elements
  s = s:gsub("<button[^>]*>.-</button>", "")
  s = s:gsub('<a[^>]+class="[^"]*srclink[^"]*"[^>]*>.-</a>', "")
  s = s:gsub('<span[^>]+class="[^"]*rightside[^"]*"[^>]*>.-</span>', "")
  s = s:gsub('<a[^>]+class="[^"]*anchor[^"]*"[^>]*>.-</a>', "")
  s = s:gsub('<a[^>]+class="[^"]*test%-arrow[^"]*"[^>]*>.-</a>', "")

  -- Code blocks: handle <pre> BEFORE <code> so backticks aren't double-wrapped
  s = s:gsub("<pre[^>]*>(.-)</pre>", function(inner)
    inner = inner:gsub("<[^>]+>", "")
    return "\n```rust\n" .. inner .. "\n```\n"
  end)

  -- Inline code
  s = s:gsub("<code[^>]*>(.-)</code>", function(inner)
    inner = inner:gsub("<[^>]+>", "")
    return "`" .. inner .. "`"
  end)

  -- Headings → markdown
  s = s:gsub("<h4[^>]*>(.-)</h4>", function(inner)
    inner = inner:gsub("<[^>]+>", ""):gsub("\xC2\xA7", ""):gsub("^%s+", ""):gsub("%s+$", "")
    return "\n#### " .. inner .. "\n"
  end)
  s = s:gsub("<h3[^>]*>(.-)</h3>", function(inner)
    inner = inner:gsub("<[^>]+>", ""):gsub("\xC2\xA7", ""):gsub("^%s+", ""):gsub("%s+$", "")
    return "\n### " .. inner .. "\n"
  end)
  s = s:gsub("<h2[^>]*>(.-)</h2>", function(inner)
    inner = inner:gsub("<[^>]+>", ""):gsub("\xC2\xA7", ""):gsub("^%s+", ""):gsub("%s+$", "")
    return "\n## " .. inner .. "\n"
  end)

  -- Block elements → newlines / lists
  s = s:gsub("</p>",   "\n\n")
  s = s:gsub("<li[^>]*>", "  - ")
  s = s:gsub("</li>",  "\n")
  s = s:gsub("<br%s*/?>", "\n")
  s = s:gsub("<hr%s*/?>", "\n---\n")

  -- Formatting: bold and italic
  s = s:gsub("<strong[^>]*>(.-)</strong>", "**%1**")
  s = s:gsub("<b[^>]*>(.-)</b>", "**%1**")
  s = s:gsub("<em[^>]*>(.-)</em>", "*%1*")
  s = s:gsub("<i[^>]*>(.-)</i>", "*%1*")

  -- Anchors: keep link text
  s = s:gsub("<a[^>]*>(.-)</a>", "%1")

  -- Remove all remaining HTML tags
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
  s = s:gsub("&ldquo;", '"')
  s = s:gsub("&rdquo;", '"')
  s = s:gsub("&lsquo;", "'")
  s = s:gsub("&rsquo;", "'")
  s = s:gsub("&mdash;", "—")
  s = s:gsub("&ndash;", "–")

  -- Strip section-anchor character (§)
  s = s:gsub("\xC2\xA7", "")

  -- Normalize line endings and collapse excessive blank lines
  s = s:gsub("\r\n", "\n")
  s = s:gsub("\n\n\n+", "\n\n")
  return s
end

--- Clean up a signature snippet (remove links, tooltips, source buttons, format where clauses).
--- <pre> content is preformatted: rustdoc lays out newlines and indentation
--- (params, where-clauses) literally in the HTML source, so leading
--- whitespace is preserved and only trailing whitespace is trimmed.
---@param s string
---@return string
local function strip_signature(s)
  s = s:gsub('<span[^>]+class="[^"]*rightside[^"]*"[^>]*>.-</span>', "")
  s = s:gsub('<a[^>]+class="[^"]*src[^"]*"[^>]*>.-</a>', "")
  s = s:gsub('<a[^>]+class="[^"]*tooltip[^"]*"[^>]*>.-</a>', "")
  s = s:gsub('<span[^>]+class="since"[^>]*>.-</span>', "")
  -- Drop "Show N methods" toggle summaries (UI chrome); the <details> tags
  -- themselves are stripped below, leaving the listed items expanded.
  s = s:gsub("<summary[^>]*>.-</summary>", "")
  s = s:gsub('<div[^>]*class="[^"]*where[^"]*"[^>]*>', "\n")
  s = s:gsub("</div>", "")
  s = s:gsub("<br%s*/?>", "\n")
  s = s:gsub("<[^>]+>", "")
  s = s:gsub("&amp;", "&"):gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&quot;", '"')
  s = s:gsub("&#39;", "'"):gsub("&#x27;", "'"):gsub("&nbsp;", " "):gsub("&#x2F;", "/")
  s = s:gsub("\xC2\xA7", "")
  local lines = {}
  for raw in (s .. "\n"):gmatch("([^\n]*)\n") do
    local line = raw:gsub("%s+$", ""):gsub("^·+", "")
    if line:gsub("^%s+", "") ~= "" then table.insert(lines, line) end
  end
  return table.concat(lines, "\n")
end

--- Extract full docblock content from a snippet of HTML.
--- Counts <div> / </div> depth to capture complete paragraphs, lists, and code blocks.
---@param snippet string
---@return string
local function extract_docblock(snippet)
  local doc_s, doc_e = snippet:find('<div[^>]+class=["\']?[^"\']*docblock[^"\']*["\']?[^>]*>')
  if not doc_s then return "" end
  local close_s = find_element_close(snippet, doc_e, "div")
  if not close_s then return "" end
  local inner = snippet:sub(doc_e + 1, close_s - 1)
  return strip_tags(inner):gsub("^%s+", ""):gsub("%s+$", "")
end

-- ---------------------------------------------------------------------------
-- Section extractors
-- ---------------------------------------------------------------------------

--- Extract module breadcrumbs (e.g. "std::io" or "alloc::string").
---@param html string
---@return string
local function extract_breadcrumbs(html)
  local bc = html:match('<div[^>]+class="[^"]*rustdoc%-breadcrumbs[^"]*"[^>]*>(.-)</div>')
  if bc then
    local cleaned = bc:gsub("<wbr>", ""):gsub("<[^>]+>", ""):gsub("%s+", "")
    return cleaned
  end
  return ""
end

--- Extract item title from <h1>.
---@param html string
---@return string
local function extract_title(html)
  local title = html:match("<h1[^>]*>(.-)</h1>")
  if title then
    return strip_tags(title):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
  end
  return ""
end

--- Extract the item declaration from <pre class="rust item-decl">.
---@param html string
---@return string
local function extract_signature(html)
  local pre_s, pre_e = html:find('<pre[^>]+class="[^"]*item%-decl[^"]*"[^>]*>')
  if not pre_s then return "" end
  local close_s = html:find("</pre>", pre_e)
  if not close_s then return "" end
  local inner = html:sub(pre_e + 1, close_s - 1)
  return strip_signature(inner)
end

--- Extract the top-level description docblock.
---@param html string
---@return string
local function extract_main_desc(html)
  local main_s = html:find('<section[^>]+id="main%-content"[^>]*>') or 1

  -- First look inside <details class="toggle top-doc" open>
  local top_doc_s, top_doc_e = html:find('<details[^>]+class="[^"]*top%-doc[^"]*"[^>]*>', main_s)
  if top_doc_s then
    local close_s = find_details_close(html, top_doc_e)
    if close_s then
      local inner = html:sub(top_doc_e + 1, close_s - 1)
      local doc = extract_docblock(inner)
      if doc ~= "" then return doc end
    end
  end

  -- Fallback to the first <div class="docblock"> inside main-content
  local doc_s, doc_e = html:find('<div[^>]+class="[^"]*docblock[^"]*"[^>]*>', main_s)
  if doc_s then
    local close_s = find_element_close(html, doc_e, "div")
    if close_s then
      return strip_tags(html:sub(doc_e + 1, close_s - 1)):gsub("^%s+", ""):gsub("%s+$", "")
    end
  end

  return ""
end

--- Extract Table of Contents from <section id="rustdoc-toc">.
--- Returns categories with items and anchor hrefs.
---@param html string
---@return { title:string, href:string, items:{text:string, href:string}[] }[]
local function extract_toc(html)
  local toc_s, toc_e = html:find('<section[^>]+id="rustdoc%-toc"[^>]*>')
  if not toc_s then return {} end
  local toc_close = find_element_close(html, toc_e, "section") or html:find("</section>", toc_e)
  if not toc_close then return {} end
  local toc_html = html:sub(toc_e + 1, toc_close - 1)

  local categories = {}
  local pos = 1
  while true do
    local h3_s, h3_e = toc_html:find("<h3[^>]*>", pos)
    if not h3_s then break end
    local h3_close = toc_html:find("</h3>", h3_e)
    if not h3_close then break end

    local h3_inner = toc_html:sub(h3_e + 1, h3_close - 1)
    local href = h3_inner:match('href%s*=%s*"([^"]*)"') or ""
    local title = strip_tags(h3_inner):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")

    -- Find any <ul> before next <h3>
    local ul_s, ul_e = toc_html:find("<ul[^>]*>", h3_close)
    local next_h3 = toc_html:find("<h3[^>]*>", h3_close)
    local items = {}
    if ul_s and (not next_h3 or ul_s < next_h3) then
      local ul_close = find_element_close(toc_html, ul_e, "ul") or toc_html:find("</ul>", ul_e)
      if ul_close then
        local ul_inner = toc_html:sub(ul_e + 1, ul_close - 1)
        for li in ul_inner:gmatch("<li[^>]*>(.-)</li>") do
          local item_href = li:match('href%s*=%s*"([^"]*)"') or ""
          local item_text = strip_tags(li):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
          if item_text ~= "" then
            table.insert(items, { text = item_text, href = item_href })
          end
        end
        pos = ul_close + 1
      else
        pos = h3_close + 1
      end
    else
      pos = h3_close + 1
    end

    if title ~= "" then
      table.insert(categories, { title = title, href = href, items = items })
    end
  end

  return categories
end

--- Collect all top-level <h2 id="..."> section markers in main-content.
---@param html string
---@return {pos:integer, id:string, label:string}[]
local function collect_section_markers(html)
  local main_s = html:find('<section[^>]+id="main%-content"[^>]*>') or 1

  -- Skip past top-doc details so internal subheadings in description aren't treated as main sections
  local top_doc_s, top_doc_e = html:find('<details[^>]+class="[^"]*top%-doc[^"]*"', main_s)
  local search_pos = main_s
  if top_doc_s then
    local close_s = find_details_close(html, top_doc_e)
    if close_s then search_pos = close_s + 1 end
  end

  local markers = {}
  while true do
    local tag_s, tag_e = html:find("<h2[^>]+>", search_pos)
    if not tag_s then break end
    local tag = html:sub(tag_s, tag_e)
    local id  = tag:match('id%s*=%s*"([^"]*)"') or ""
    local close_s = html:find("</h2>", tag_e)
    local label = ""
    if close_s then
      label = strip_tags(html:sub(tag_e + 1, close_s - 1))
             :gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    end
    table.insert(markers, { pos = tag_s, id = id, label = label })
    search_pos = (close_s or tag_e) + 1
  end
  return markers
end

--- Extract method items from a trait method section (e.g. required-methods, provided-methods).
--- Returns optional note and list of { id, name, sig, stability, doc }.
---@param sec_html string
---@return string, { id:string, name:string, sig:string, stability:string, doc:string }[]
local function extract_trait_methods(sec_html)
  local note = sec_html:match('<div[^>]+class="[^"]*must_implement[^"]*"[^>]*>(.-)</div>')
            or sec_html:match('<div[^>]+class="[^"]*stab [^"]*"[^>]*>(.-)</div>')
  local note_text = ""
  if note then
    note_text = strip_tags(note):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
  end

  local methods = {}
  local pos = 1
  while true do
    local dt_s, dt_e = sec_html:find('<details[^>]+class="[^"]*method%-toggle[^"]*"', pos)
    if not dt_s then
      dt_s, dt_e = sec_html:find('<details[^>]+class="[^"]*toggle[^"]*"', pos)
    end
    if not dt_s then break end

    local dt_close = find_details_close(sec_html, dt_e)
    if not dt_close then break end

    local minner = sec_html:sub(dt_e + 1, dt_close - 1)

    -- Item ID / anchor
    local id = minner:match('id%s*=%s*"([^"]*)"') or ""

    -- Signature
    local sig_html = minner:match('<h4[^>]*class="[^"]*code%-header[^"]*"[^>]*>(.-)</h4>')
                  or minner:match('<h3[^>]*class="[^"]*code%-header[^"]*"[^>]*>(.-)</h3>')
    local sig = ""
    if sig_html then
      sig = strip_signature(sig_html)
    end

    -- Derive a short name for the heading
    local name = id:gsub("^method%.", ""):gsub("^tymethod%.", ""):gsub("^associatedtype%.", ""):gsub("^associatedconstant%.", "")
    if name == "" and sig ~= "" then
      name = sig:match("^%a+%s+([%w_]+)") or sig:match("^([%w_]+)") or ""
    end

    -- Stability / Portability note
    local stab = minner:match('<span[^>]+class="[^"]*item%-info[^"]*"[^>]*>(.-)</span>')
              or minner:match('<div[^>]+class="[^"]*stab [^"]*"[^>]*>(.-)</div>')
    local stab_text = ""
    if stab then
      stab_text = strip_tags(stab):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    end

    -- Full docblock
    local doc = extract_docblock(minner)

    if sig ~= "" then
      table.insert(methods, {
        id        = id,
        name      = name,
        sig       = sig,
        stability = stab_text,
        doc       = doc,
      })
    end

    pos = dt_close + 1
  end

  return note_text, methods
end

--- Extract Dyn Compatibility note from sec_html.
---@param sec_html string
---@return string
local function extract_dyn_compatibility(sec_html)
  local info = sec_html:match('<div[^>]+class="[^"]*dyn%-compatibility%-info[^"]*"[^>]*>(.-)</div>')
  if info then
    return strip_tags(info):gsub("^%s+", ""):gsub("%s+$", "")
  end
  return ""
end

--- Extract implementors list from <div id="implementors-list">.
--- Resolves target type hrefs so they can be followed with gd.
---@param sec_html string
---@param base_url string
---@return { header:string, href:string|nil, stability:string, doc:string }[]
local function extract_implementors(sec_html, base_url)
  local results = {}
  local pos = 1
  while true do
    local sec_s, sec_e = sec_html:find('<section[^>]+class="[^"]*impl[^"]*"[^>]*>', pos)
    if not sec_s then break end
    local sec_close = sec_html:find('</section>', sec_e)
    if not sec_close then break end

    local inner = sec_html:sub(sec_e + 1, sec_close - 1)
    local h3_html = inner:match('<h3[^>]*class="[^"]*code%-header[^"]*"[^>]*>(.-)</h3>')
    if h3_html then
      local header = strip_signature(h3_html):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")

      -- Extract target type doc link (e.g. struct.File.html)
      local target_href = nil
      for href in h3_html:gmatch('<a[^>]+href="([^"]*%.html)"') do
        if not href:match("trait%.") then
          target_href = resolve_url(base_url, href)
        end
      end

      -- Stability / portability
      local stab = inner:match('<div[^>]+class="[^"]*portability[^"]*"[^>]*>(.-)</div>')
                or inner:match('<span[^>]+class="[^"]*stab[^"]*"[^>]*>(.-)</span>')
      local stab_text = stab and strip_tags(stab):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "") or ""

      -- Doc comment
      local doc = inner:match('<div[^>]+class="[^"]*docblock[^"]*"[^>]*>(.-)</div>')
      local doc_text = doc and strip_tags(doc):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "") or ""

      if header ~= "" then
        table.insert(results, {
          header    = header,
          href      = target_href,
          stability = stab_text,
          doc       = doc_text,
        })
      end
    end

    pos = sec_close + 1
  end
  return results
end

--- Extract struct fields from a fields section.
---@param sec_html string
---@return { field:string, doc:string }[]
local function extract_fields(sec_html)
  local results = {}
  local pos = 1
  while true do
    local f_s, f_e = sec_html:find('<span[^>]+class="[^"]*structfield[^"]*"[^>]*>', pos)
    if not f_s then break end
    local f_close = sec_html:find('</span>', f_e)
    if not f_close then break end

    local field_raw = sec_html:sub(f_e + 1, f_close - 1)
    local field = strip_signature(field_raw):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")

    -- Docblock following the span
    local next_span = sec_html:find('<span[^>]+class="[^"]*structfield[^"]*"', f_close)
    local limit = next_span or #sec_html
    local snippet = sec_html:sub(f_close + 1, limit)
    local doc = extract_docblock(snippet)

    if field ~= "" then
      table.insert(results, { field = field, doc = doc })
    end
    pos = f_close + 1
  end
  return results
end

--- Extract enum variants from a variants section.
---@param sec_html string
---@return { name:string, doc:string }[]
local function extract_variants(sec_html)
  local results = {}
  local pos = 1
  while true do
    local v_s, v_e = sec_html:find('<section[^>]+class="[^"]*variant[^"]*"[^>]*>', pos)
    if not v_s then break end
    local v_close = sec_html:find('</section>', v_e)
    if not v_close then break end

    local v_inner = sec_html:sub(v_e + 1, v_close - 1)
    local h3 = v_inner:match('<h3[^>]*class="[^"]*code%-header[^"]*"[^>]*>(.-)</h3>')
    local name = h3 and strip_signature(h3):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "") or ""

    local next_v = sec_html:find('<section[^>]+class="[^"]*variant[^"]*"', v_close)
    local limit = next_v or #sec_html
    local snippet = sec_html:sub(v_close + 1, limit)
    local doc = extract_docblock(snippet)

    if name ~= "" then
      table.insert(results, { name = name, doc = doc })
    end
    pos = v_close + 1
  end
  return results
end

--- Collect impl blocks structured as:
---   { impl_header, availability, methods[] }
--- Handles inherent implementations, trait implementations, and blanket implementations.
--- Avoids duplicating bare sections that are already enclosed within an implementors-toggle.
---@param sec_html string
---@return { impl_header:string, availability:string, methods:{name:string, sig:string, doc:string}[] }[]
local function extract_impl_blocks(sec_html)
  local results = {}
  local toggle_ranges = {}
  local search_pos = 1

  -- 1. Extract <details class="...implementors-toggle..."> blocks
  while true do
    local tag_s, tag_e = sec_html:find('<details[^>]+class="[^"]*implementors%-toggle[^"]*"[^>]*>', search_pos)
    if not tag_s then break end

    local close_s = find_details_close(sec_html, tag_e)
    if not close_s then break end

    table.insert(toggle_ranges, { s = tag_s, e = close_s })

    local block = sec_html:sub(tag_e + 1, close_s - 1)

    local impl_header = ""
    local h3_html = block:match('<h3[^>]*class="[^"]*code%-header[^"]*"[^>]*>(.-)</h3>')
    if h3_html then
      impl_header = strip_signature(h3_html):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    end

    local availability = ""
    local stab_html = block:match('<div[^>]+class="[^"]*stab portability[^"]*"[^>]*>(.-)</div>')
    if stab_html then
      availability = strip_tags(stab_html):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    end

    local methods = {}
    local meth_pos = 1
    while true do
      local mt_s, mt_e = block:find('<details[^>]+class="[^"]*method%-toggle[^"]*"[^>]*>', meth_pos)
      if not mt_s then break end
      local mt_close = find_details_close(block, mt_e)
      if not mt_close then break end

      local minner = block:sub(mt_e + 1, mt_close - 1)
      local sig_html = minner:match('<h4[^>]*class="[^"]*code%-header[^"]*"[^>]*>(.-)</h4>')
                    or minner:match('<h3[^>]*class="[^"]*code%-header[^"]*"[^>]*>(.-)</h3>')
      local sig = ""
      if sig_html then
        sig = strip_signature(sig_html)
      end
      local doc = extract_docblock(minner)

      local id = minner:match('id%s*=%s*"([^"]*)"') or ""
      local name = id:gsub("^method%.", ""):gsub("^tymethod%.", "")
      if name == "" and sig ~= "" then
        name = sig:match("^%a+%s+([%w_]+)") or ""
      end

      if sig ~= "" then
        table.insert(methods, { name = name, sig = sig, doc = doc })
      end
      meth_pos = mt_close + 1
    end

    if impl_header ~= "" or #methods > 0 then
      table.insert(results, {
        impl_header  = impl_header,
        availability = availability,
        methods      = methods,
      })
    end

    search_pos = close_s + 1
  end

  -- 2. Extract bare <section class="impl"> blocks NOT inside any implementors-toggle
  local bare_pos = 1
  while true do
    local s_s, s_e = sec_html:find('<section[^>]+class="[^"]*%f[%w]impl%f[%W][^"]*"[^>]*>', bare_pos)
    if not s_s then break end

    -- Check if s_s is enclosed in any toggle_range
    local in_toggle = false
    for _, r in ipairs(toggle_ranges) do
      if s_s >= r.s and s_s <= r.e then
        in_toggle = true
        break
      end
    end

    local s_close = sec_html:find("</section>", s_e)
    if not s_close then break end

    if not in_toggle then
      local inner = sec_html:sub(s_e + 1, s_close - 1)
      local h3_html = inner:match('<h3[^>]*class="[^"]*code%-header[^"]*"[^>]*>(.-)</h3>')
      local impl_header = ""
      if h3_html then
        impl_header = strip_signature(h3_html):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
      end

      local stab = inner:match('<div[^>]+class="[^"]*portability[^"]*"[^>]*>(.-)</div>')
      local availability = stab and strip_tags(stab):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "") or ""

      if impl_header ~= "" then
        table.insert(results, {
          impl_header  = impl_header,
          availability = availability,
          methods      = {},
        })
      end
    end

    bare_pos = s_close + 1
  end

  return results
end

-- ---------------------------------------------------------------------------
-- Crate / Module index section extractor (<dl class="item-table">)
-- ---------------------------------------------------------------------------

local CRATE_SECTION_IDS = {
  { id = "reexports",   label = "Re-exports"       },
  { id = "modules",     label = "Modules"          },
  { id = "macros",      label = "Macros"           },
  { id = "structs",     label = "Structs"          },
  { id = "enums",       label = "Enums"            },
  { id = "unions",      label = "Unions"           },
  { id = "constants",   label = "Constants"        },
  { id = "statics",     label = "Statics"          },
  { id = "traits",      label = "Traits"           },
  { id = "functions",   label = "Functions"        },
  { id = "types",       label = "Type Aliases"     },
  { id = "attributes",  label = "Attribute Macros" },
  { id = "derives",     label = "Derive Macros"    },
}

--- Extract crate-level item sections from <dl class="item-table"> (present on module/crate index pages).
---@param html string
---@param base_url string
---@return { label:string, items:{name:string, href:string, kind:string, desc:string, portability:string}[] }[]
local function extract_crate_sections(html, base_url)
  local result = {}
  for _, sec in ipairs(CRATE_SECTION_IDS) do
    local h2_pat = '<h2[^>]+id%s*=%s*"' .. sec.id .. '"[^>]*>'
    local h2_s, h2_e = html:find(h2_pat)
    if not h2_s then goto continue_sec end

    local dl_s, dl_e = html:find('<dl[^>]+class="[^"]*item%-table[^"]*"[^>]*>', h2_e)
    if not dl_s then goto continue_sec end

    local dl_close = html:find("</dl>", dl_e)
    if not dl_close then goto continue_sec end

    local dl_inner = html:sub(dl_e + 1, dl_close - 1)
    local items = {}
    local pos = 1
    while true do
      local dt_s, dt_e = dl_inner:find("<dt[^>]*>", pos)
      if not dt_s then break end
      local dt_close = dl_inner:find("</dt>", dt_e)
      if not dt_close then break end

      local dt_inner = dl_inner:sub(dt_e + 1, dt_close - 1)
      local href_rel = dt_inner:match('<a[^>]+href%s*=%s*"([^"]*)"')
      local kind     = dt_inner:match('<a[^>]+class%s*=%s*"([^"]*)"')
                    or dt_inner:match('title%s*=%s*"([^"]+)%s+[^"]*"')
      if kind then kind = kind:match("^(%S+)") end

      local name_raw = dt_inner:gsub("<wbr>", ""):gsub('<span[^>]*>.-</span>', "")
      local name = strip_tags(name_raw):gsub("%s+", ""):gsub("^%s+", ""):gsub("%s+$", "")

      local portability = ""
      local stab = dt_inner:match('<span[^>]+class="[^"]*stab[^"]*"[^>]*>(.-)</span>')
      if stab then
        portability = strip_tags(stab):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
      end

      local dd_s, dd_e = dl_inner:find("<dd[^>]*>", dt_close + 1)
      local desc = ""
      if dd_s then
        local dd_close = dl_inner:find("</dd>", dd_e)
        if dd_close then
          desc = strip_tags(dl_inner:sub(dd_e + 1, dd_close - 1)):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
        end
        pos = (dd_close or dt_close) + 1
      else
        pos = dt_close + 1
      end

      if href_rel and name ~= "" then
        table.insert(items, {
          name        = name,
          href        = resolve_url(base_url, href_rel),
          kind        = kind or sec.id:gsub("s$", ""),
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
-- Sidebar module items category order
-- ---------------------------------------------------------------------------

local SIDEBAR_CATEGORIES = {
  { key = "mod",        label = "Modules",         prefix = "",            suffix = "/index.html" },
  { key = "macro",      label = "Macros",          prefix = "macro.",      suffix = ".html"       },
  { key = "struct",     label = "Structs",         prefix = "struct.",     suffix = ".html"       },
  { key = "enum",       label = "Enums",           prefix = "enum.",       suffix = ".html"       },
  { key = "trait",      label = "Traits",          prefix = "trait.",      suffix = ".html"       },
  { key = "fn",         label = "Functions",       prefix = "fn.",         suffix = ".html"       },
  { key = "type",       label = "Type Aliases",    prefix = "type.",       suffix = ".html"       },
  { key = "constant",   label = "Constants",       prefix = "constant.",   suffix = ".html"       },
  { key = "static",     label = "Statics",         prefix = "static.",     suffix = ".html"       },
  { key = "union",      label = "Unions",          prefix = "union.",      suffix = ".html"       },
  { key = "primitive",  label = "Primitive Types", prefix = "primitive.",  suffix = ".html"       },
  { key = "traitalias", label = "Trait Aliases",   prefix = "traitalias.", suffix = ".html"       },
}

-- ---------------------------------------------------------------------------
-- Renderer
-- ---------------------------------------------------------------------------

--- Render a parsed doc page into lines suitable for a Neovim buffer.
--- Also returns link_map: { [line_number] = { url, c0, c1 } } for gd / <CR>
--- navigation, where c0/c1 are 0-based byte columns (end-exclusive) for the
--- navigable word on that line.
---@param html string
---@param url string
---@param sidebar_data table|nil  Optional parsed SIDEBAR_ITEMS table
---@return string[], table<integer,{url:string,c0:integer,c1:integer}>
function M.render(html, url, sidebar_data)
  local lines    = {}
  local link_map = {}

  local function push(s)
    for _, line in ipairs(vim.split(s or "", "\n", { plain = true })) do
      table.insert(lines, line)
    end
  end

  --- Find the byte range of the navigable word in a rendered line.
  --- Prefers an explicit hl_word, then markdown [text], then `code`,
  --- then the first non-space token.
  ---@param line string
  ---@param hl_word string|nil
  ---@return integer, integer  0-based c0, end-exclusive c1
  local function word_span(line, hl_word)
    if hl_word and hl_word ~= "" then
      local a, b = line:find(hl_word, 1, true)
      if a then return a - 1, b end
    end
    local a, b = line:find("%[([^%]]+)%]")
    if a then return a, b - 1 end
    local ca, cb = line:find("`[^`]+`")
    if ca then return ca - 1, cb end
    local sa, sb = line:find("%S+")
    if sa then return sa - 1, sb end
    return 0, #line
  end

  ---@param s string
  ---@param target string
  ---@param hl_word string|nil  substring to highlight (defaults to link text)
  local function push_link(s, target, hl_word)
    for _, line in ipairs(vim.split(s or "", "\n", { plain = true })) do
      local ln = #lines + 1
      table.insert(lines, line)
      if target and target ~= "" then
        local c0, c1 = word_span(line, hl_word)
        link_map[ln] = { url = target, c0 = c0, c1 = c1 }
      end
    end
  end

  local function section_header(label)
    table.insert(lines, "")
    table.insert(lines, "# " .. label)
    table.insert(lines, "")
  end

  -- ── Header ─────────────────────────────────────────────────────────────────
  local title = extract_title(html)
  if title ~= "" then
    push("# " .. title)
    push("")
  end

  local breadcrumbs = extract_breadcrumbs(html)
  if breadcrumbs ~= "" then
    push("Module: " .. breadcrumbs)
  end

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

  -- ── Table of Contents ──────────────────────────────────────────────────────
  local toc_categories = extract_toc(html)
  if #toc_categories > 0 then
    section_header("Table of Contents")
    for _, cat in ipairs(toc_categories) do
      push("## " .. cat.title)
      push("")
      if #cat.items == 0 and cat.href ~= "" then
        push_link("- [" .. cat.title .. "](" .. cat.href .. ")", cat.href, cat.title)
      else
        for _, it in ipairs(cat.items) do
          local target = it.href ~= "" and it.href or ("#" .. it.text)
          push_link("- [" .. it.text .. "](" .. target .. ")", target, it.text)
        end
      end
      push("")
    end
  end

  -- ── Body Sections ──────────────────────────────────────────────────────────
  local markers = collect_section_markers(html)

  for i, m in ipairs(markers) do
    local sec_start = m.pos
    local sec_end = (markers[i + 1] and (markers[i + 1].pos - 1)) or #html
    local sec_html = html:sub(sec_start, sec_end)
    local sec_id = m.id

    if sec_id == "fields" then
      -- Struct / Union fields
      local fields = extract_fields(sec_html)
      if #fields > 0 then
        section_header(m.label ~= "" and m.label or "Fields")
        for _, f in ipairs(fields) do
          push("- `" .. f.field .. "`")
          if f.doc ~= "" then
            push("  " .. f.doc:gsub("\n", "\n  "))
          end
          push("")
        end
      end

    elseif sec_id == "variants" then
      -- Enum variants
      local variants = extract_variants(sec_html)
      if #variants > 0 then
        section_header(m.label ~= "" and m.label or "Variants")
        for _, v in ipairs(variants) do
          push("## " .. v.name)
          push("")
          if v.doc ~= "" then
            push(v.doc)
          end
          push("")
        end
      end

    elseif sec_id == "required-associated-types"
        or sec_id == "required-associated-consts"
        or sec_id == "required-methods"
        or sec_id == "provided-associated-types"
        or sec_id == "provided-associated-consts"
        or sec_id == "provided-methods" then
      -- Trait method / associated item sections
      local note, methods = extract_trait_methods(sec_html)
      if note ~= "" or #methods > 0 then
        section_header(m.label)
        if note ~= "" then
          push("*" .. note .. "*")
          push("")
        end
        for _, meth in ipairs(methods) do
          local heading = meth.sig:match("^fn%s+[%w_]+")
                       or meth.sig:match("^type%s+[%w_]+")
                       or meth.sig:match("^const%s+[%w_]+")
                       or meth.name
          push("## " .. heading)
          push("")
          push("```rust")
          push(meth.sig)
          push("```")
          if meth.stability ~= "" then
            push("*" .. meth.stability .. "*")
          end
          if meth.doc ~= "" then
            push("")
            push(meth.doc)
          end
          push("")
        end
      end

    elseif sec_id == "dyn-compatibility" then
      -- Trait dyn compatibility note
      local dyn_text = extract_dyn_compatibility(sec_html)
      if dyn_text ~= "" then
        section_header(m.label ~= "" and m.label or "Dyn Compatibility")
        push(dyn_text)
        push("")
      end

    elseif sec_id == "implementors" then
      -- Implementors of this trait
      local implementors = extract_implementors(sec_html, url)
      if #implementors > 0 then
        section_header(m.label ~= "" and m.label or "Implementors")
        for _, imp in ipairs(implementors) do
          local line = "- `" .. imp.header .. "`"
          if imp.stability ~= "" then
            line = line .. " *(" .. imp.stability .. ")*"
          end
          push_link(line, imp.href, imp.header)
          if imp.doc ~= "" then
            push("  " .. imp.doc:gsub("\n", "\n  "))
          end
        end
        push("")
      end

    elseif sec_id == "implementations"
        or sec_id == "trait-implementations"
        or sec_id == "foreign-impls"
        or sec_id == "blanket-implementations" then
      -- Inherent implementations and trait implementations
      local blocks = extract_impl_blocks(sec_html)
      if #blocks > 0 then
        section_header(m.label)
        for _, blk in ipairs(blocks) do
          if blk.impl_header ~= "" then
            push("## " .. blk.impl_header)
            push("")
          end
          if blk.availability ~= "" then
            push("*" .. blk.availability .. "*")
            push("")
          end
          for _, meth in ipairs(blk.methods) do
            push("```rust")
            push(meth.sig)
            push("```")
            if meth.doc ~= "" then
              push(meth.doc)
            end
            push("")
          end
        end
      end

    elseif sec_id == "synthetic-implementations" then
      -- Auto Trait Implementations
      local blocks = extract_impl_blocks(sec_html)
      if #blocks > 0 then
        section_header(m.label ~= "" and m.label or "Auto Trait Implementations")
        for _, blk in ipairs(blocks) do
          if blk.impl_header ~= "" then
            push("## " .. blk.impl_header)
            push("")
          end
        end
        push("")
      end

    else
      -- Any other unhandled sections with docblocks
      local doc = extract_docblock(sec_html)
      if doc ~= "" then
        section_header(m.label)
        push(doc)
        push("")
      end
    end
  end

  -- ── Crate / Module items from item-table (for module/crate index pages) ─────
  local crate_sections = extract_crate_sections(html, url)
  for _, csec in ipairs(crate_sections) do
    section_header(csec.label)
    local name_w = 0
    for _, item in ipairs(csec.items) do
      if #item.name > name_w then name_w = #item.name end
    end
    name_w = math.min(name_w, 40)

    for _, item in ipairs(csec.items) do
      local name_col = item.name
      if #name_col < name_w then
        name_col = name_col .. string.rep(" ", name_w - #name_col)
      end
      local port_suffix = item.portability ~= "" and ("  [" .. item.portability .. "]") or ""
      local line = "  " .. name_col .. "   " .. item.desc .. port_suffix
      push_link(line, item.href, item.name)
    end
    push("")
  end

  -- ── Module items from sidebar-items (for individual item pages) ────────────
  if #crate_sections == 0 then
    local modnav = html:match('<div[^>]+id="rustdoc%-modnav"[^>]*>(.-)</div>')
    local mod_title = ""
    local mod_url = nil
    if modnav then
      local href_rel = modnav:match('href%s*=%s*"([^"]*)"')
      local raw_text = strip_tags(modnav):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
      raw_text = raw_text:gsub("^#+%s*", "")
      mod_title = raw_text ~= "" and raw_text or "In Module"
      if href_rel then
        mod_url = resolve_url(url, href_rel)
      end
    end

    if sidebar_data and next(sidebar_data) then
      local header_label = mod_title ~= "" and mod_title or "Module Items"
      section_header(header_label)

      for _, cat in ipairs(SIDEBAR_CATEGORIES) do
        local cat_items = sidebar_data[cat.key]
        if cat_items and #cat_items > 0 then
          push("## " .. cat.label)
          push("")
          for _, entry in ipairs(cat_items) do
            local name = type(entry) == "table" and entry[1] or entry
            local rel_href = (cat.prefix or "") .. name .. (cat.suffix or ".html")
            local item_url = resolve_url(mod_url or url, rel_href)
            push_link("- [" .. name .. "](" .. item_url .. ")", item_url, name)
          end
          push("")
        end
      end
    elseif mod_url and mod_title ~= "" then
      section_header(mod_title)
      push_link("- [" .. mod_title .. "](" .. mod_url .. ")", mod_url, mod_title)
      push("")
    end
  end

  return lines, link_map
end

return M
