--- HTML fetcher for individual Rust doc pages and their sidebar items.
--- Fetches HTML from doc.rust-lang.org or docs.rs asynchronously.

local M = {}

--- In-memory cache for sidebar-items data by URL
local sidebar_cache = {}

--- Resolve relative href against base URL
local function resolve_url(base, href)
  if href:match("^https?://") or href:match("^#") then
    return href
  end
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

--- Fetch the HTML content and optional sidebar-items data of a URL asynchronously.
--- Follows docs.rs `<meta http-equiv="refresh">` redirections (curl -L only
--- follows HTTP redirects, not meta refresh) up to 5 hops.
--- Calls callback(err, html, sidebar_data, final_url) on the main Neovim loop.
---@param url string
---@param callback fun(err: string|nil, html: string|nil, sidebar_data: table|nil, final_url: string|nil)
function M.fetch(url, callback)
  local function do_curl(target_url, done)
    return vim.system(
      {
        "curl",
        "--silent",
        "--fail",
        "--location",
        "--compressed",
        "--http1.1",   -- avoid HTTP/2 stream resets on docs.rs 404s (exit 56)
        "--user-agent", "rust-docs.nvim/1.0 (Neovim plugin)",
        target_url,
      },
      { text = true },
      done
    )
  end

  local function fetch_sidebar(html, page_url, done)
    local sidebar_src = html:match('<script[^>]+src="([^"]*sidebar%-items[^"]*%.js)"')
    if not sidebar_src then
      done(nil)
      return
    end

    local sidebar_url = resolve_url(page_url, sidebar_src)
    if sidebar_cache[sidebar_url] then
      done(sidebar_cache[sidebar_url])
      return
    end

    vim.system(
      {
        "curl",
        "--silent",
        "--fail",
        "--location",
        "--compressed",
        "--http1.1",
        "--user-agent", "rust-docs.nvim/1.0 (Neovim plugin)",
        sidebar_url,
      },
      { text = true },
      function(s_res)
        vim.schedule(function()
          local s_data = nil
          if s_res.code == 0 and s_res.stdout then
            local json_str = s_res.stdout:match("([%[{].*[%]}])")
            if json_str then
              pcall(function()
                s_data = vim.json.decode(json_str)
              end)
            end
          end
          if s_data then
            sidebar_cache[sidebar_url] = s_data
          end
          done(s_data)
        end)
      end
    )
  end

  local hops = 0
  local function fetch_page(target_url)
    hops = hops + 1
    return do_curl(target_url, function(result)
      vim.schedule(function()
        if result.code ~= 0 then
          callback(
            "rust-docs: fetch failed for " .. target_url ..
            " (exit " .. result.code .. "): " .. (result.stderr or ""),
            nil,
            nil,
            nil
          )
          return
        end

        local html = result.stdout or ""
        -- docs.rs re-exports (e.g. serde_json::read::Read) serve a meta-refresh
        -- redirection page instead of HTTP redirect. Follow it manually.
        if hops < 5 then
          local refresh = html:match('<meta[^>]+http%-equiv%s*=%s*["\']?refresh["\']?[^>]*content%s*=%s*["\']([^"\']+)["\']')
            or html:match('<meta[^>]+content%s*=%s*["\'][^"\']*URL=([^"\']+)["\']')
          if refresh then
            local redir = refresh:match("[Uu][Rr][Ll]%s*=%s*(.+)")
            if redir then
              redir = redir:gsub("^%s+", ""):gsub("%s+$", "")
              local next_url = resolve_url(target_url, redir)
              fetch_page(next_url)
              return
            end
          end
        end

        fetch_sidebar(html, target_url, function(s_data)
          callback(nil, html, s_data, target_url)
        end)
      end)
    end)
  end

  return fetch_page(url)
end

return M
