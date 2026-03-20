--- HTML fetcher for individual Rust doc pages.
--- Fetches HTML from doc.rust-lang.org and returns it as a string.

local M = {}

--- Fetch the HTML content of a URL asynchronously.
--- Calls callback(err, html) on the main Neovim loop.
---@param url string
---@param callback fun(err: string|nil, html: string|nil)
function M.fetch(url, callback)
  vim.system(
    {
      "curl",
      "--silent",
      "--fail",
      "--location",
      "--compressed",
      "--user-agent", "rust-docs.nvim/1.0 (Neovim plugin)",
      url,
    },
    { text = true },
    function(result)
      vim.schedule(function()
        if result.code ~= 0 then
          callback(
            "rust-docs: fetch failed for " .. url ..
            " (exit " .. result.code .. "): " .. (result.stderr or ""),
            nil
          )
        else
          callback(nil, result.stdout)
        end
      end)
    end
  )
end

return M
