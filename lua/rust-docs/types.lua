--- Type definitions for rust-docs.nvim (LuaLS / lua-language-server annotations).

---@class RustDocs.Item
---@field name      string   Item name (e.g. "TcpListener")
---@field path      string   Module path (e.g. "std::net")
---@field full_path string   Full qualified path (e.g. "std::net::TcpListener")
---@field kind      string   Item kind (e.g. "struct", "fn", "trait", …)
---@field desc      string   Short description from the search index
---@field url       string   URL to the HTML documentation page

---@class RustDocs.MethodEntry
---@field section string  Section label (e.g. "Implementations", "Trait Implementations")
---@field sig     string  Method signature (stripped, plain text)
---@field doc     string  First paragraph of the method's doc comment
