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

      -- For trait sections, emit a compact summary list of trait names first
      if sec_label == "Trait Implementations" or sec_label == "Blanket Implementations" then
        local names = {}
        for _, blk in ipairs(group) do
          if blk.impl_header ~= "" then
            -- Extract just the trait name: "impl Foo<Bar> for Baz" → "Foo<Bar>"
            local trait_name = blk.impl_header:match("^impl%s+(.-)%s+for%s+")
                            or blk.impl_header:match("^impl%s+(.*)")
            if trait_name then
              table.insert(names, trait_name)
            end
          end
        end
        if #names > 0 then
          push("  " .. table.concat(names, " · "))
          push("")
        end
      end

      for _, blk in ipairs(group) do
        -- Emit impl header (e.g. "impl AsFd for TcpListener")
        if blk.impl_header ~= "" then
          push("  " .. blk.impl_header)
        end
        -- Emit availability / portability note
        if blk.availability ~= "" then
          push("  (" .. blk.availability .. ")")
        end
        -- Emit each method
        for _, method in ipairs(blk.methods) do
          table.insert(lines, "    ```rust")
          table.insert(lines, "    " .. method.sig)
          table.insert(lines, "    ```")
          if method.doc ~= "" then
            push("      " .. method.doc)
          end
          table.insert(lines, "")
        end
        -- Blank line between impl blocks (only if there were methods or a header)
        if blk.impl_header ~= "" and #blk.methods == 0 then
          table.insert(lines, "")
        end
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
