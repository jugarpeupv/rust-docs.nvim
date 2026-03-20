--- HTML to Markdown-ish renderer for Rust documentation pages.
--- Parses the rustdoc-generated HTML and produces structured plain text
--- with section headings, code blocks, and method signature lists.
---
--- We deliberately avoid a full HTML parser dependency. Rustdoc's HTML output
--- is consistent enough that targeted pattern matching works reliably.
---
--- Approach for impl sections:
---   Instead of trying to extract bounded div regions (which breaks due to
---   deeply nested HTML), we:
---   1. Collect all <h2 id="..."> section markers with their byte offsets.
---   2. Iterate all <details class="...method-toggle..."> elements.
---   3. Assign each method to whichever h2 section precedes it.
---   This avoids any depth-counting and is robust against HTML nesting.

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

--- Extract the main description docblock.
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

--- Find all method-toggle <details> blocks in the HTML, returning a list
--- of {section_label, sig, doc} tables.
---
--- Each <details class="...method-toggle..."> contains:
---   <h4 class="code-header">…signature…</h4>
---   <div class="docblock">…doc…</div>   (optional)
---
---@param html string
---@param markers {pos:integer, id:string, label:string}[]
---@return {section:string, sig:string, doc:string}[]
local function collect_methods(html, markers)
  local results = {}
  local search_pos = 1

  while true do
    -- Find the next method-toggle opening tag
    local tag_s, tag_e = html:find('<details[^>]+class="[^"]*method%-toggle[^"]*"[^>]*>', search_pos)
    if not tag_s then break end

    -- Find the matching </details> — method-toggle details are never nested
    -- so a simple search for the next </details> works.
    local close_s = html:find("</details>", tag_e)
    if not close_s then break end

    local inner = html:sub(tag_e + 1, close_s - 1)
    local sec   = section_for_pos(tag_s, markers)

    -- Extract signature from <h4 class="code-header"> or <h3 class="code-header">
    local sig_html = inner:match('<h4[^>]*class="[^"]*code%-header[^"]*"[^>]*>(.-)</h4>')
                  or inner:match('<h3[^>]*class="[^"]*code%-header[^"]*"[^>]*>(.-)</h3>')
    local sig = ""
    if sig_html then
      sig = strip_tags(sig_html):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    end

    -- Extract first-line doc comment (the docblock div is not deeply nested here)
    local doc = ""
    local doc_s, doc_e = inner:find('<div[^>]+class="[^"]*docblock[^"]*"[^>]*>')
    if doc_s then
      -- Grab up to the next closing </div> (first one suffices for the first paragraph)
      local doc_close = inner:find("</div>", doc_e)
      if doc_close then
        local raw = strip_tags(inner:sub(doc_e + 1, doc_close - 1))
        doc = (raw:match("^([^\n]+)") or raw):gsub("^%s+", ""):gsub("%s+$", "")
      end
    end

    if sig ~= "" then
      table.insert(results, { section = sec, sig = sig, doc = doc })
    end

    search_pos = close_s + 1
  end

  return results
end

-- ---------------------------------------------------------------------------
-- Renderer: assemble lines
-- ---------------------------------------------------------------------------

--- Render a parsed doc page into a list of lines suitable for a Neovim buffer.
---@param html string
---@param url string
---@return string[]
function M.render(html, url)
  local lines = {}

  local function push(s)
    for _, line in ipairs(vim.split(s or "", "\n", { plain = true })) do
      table.insert(lines, line)
    end
  end

  local function separator()
    table.insert(lines, string.rep("─", 78))
  end

  local function section_header(label)
    table.insert(lines, "")
    separator()
    table.insert(lines, "  " .. label:upper())
    separator()
    table.insert(lines, "")
  end

  -- ── Title ──────────────────────────────────────────────────────────────────
  local title = extract_title(html)
  if title ~= "" then
    push("# " .. title)
    push("")
    push(string.rep("═", 78))
    push("")
  end

  -- Source URL (for gx keymap)
  push("URL: " .. url)
  push("")

  -- ── Description ────────────────────────────────────────────────────────────
  local desc = extract_main_desc(html)
  if desc ~= "" then
    section_header("Description")
    push(desc)
    push("")
  end

  -- ── Implementations ────────────────────────────────────────────────────────
  local markers = collect_section_markers(html)
  local methods = collect_methods(html, markers)

  -- Group methods by section (preserving first-seen order)
  local section_order  = {}
  local section_groups = {}
  for _, m in ipairs(methods) do
    if not section_groups[m.section] then
      table.insert(section_order, m.section)
      section_groups[m.section] = {}
    end
    table.insert(section_groups[m.section], m)
  end

  -- Sections to actually render (skip overly noisy blanket impls by default)
  local render_sections = {
    "Implementations",
    "Trait Implementations",
    "Auto Trait Implementations",
  }
  -- Include blanket only if there are user-visible sections
  if #section_order > 0 then
    table.insert(render_sections, "Blanket Implementations")
  end

  for _, sec_label in ipairs(render_sections) do
    local group = section_groups[sec_label]
    if group and #group > 0 then
      section_header(sec_label)
      for _, method in ipairs(group) do
        table.insert(lines, "  ```rust")
        table.insert(lines, "  " .. method.sig)
        table.insert(lines, "  ```")
        if method.doc ~= "" then
          push("    " .. method.doc)
        end
        table.insert(lines, "")
      end
    end
  end

  -- ── Footer ─────────────────────────────────────────────────────────────────
  separator()
  push("  vim: ft=markdown | rust-docs.nvim")
  separator()

  return lines
end

return M
