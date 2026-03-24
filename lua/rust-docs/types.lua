--- Type definitions for rust-docs.nvim (LuaLS / lua-language-server annotations).

---@class RustDocs.Item
---@field name      string   Item name (e.g. "TcpListener")
---@field path      string   Module path (e.g. "std::net")
---@field full_path string   Full qualified path (e.g. "std::net::TcpListener")
---@field kind      string   Item kind (e.g. "struct", "fn", "trait", …)
---@field desc      string   Short description from the search index
---@field url       string   URL to the HTML documentation page
---@field params?   string   Space-separated parameter types for fn/method items (e.g. "BufReader<R> usize")
---@field ret?      string   Return type string for fn/method items (e.g. "Result<usize>")

---@class RustDocs.MethodEntry
---@field section string  Section label (e.g. "Implementations", "Trait Implementations")
---@field sig     string  Method signature (stripped, plain text)
---@field doc     string  First paragraph of the method's doc comment

--- A crate search result from crates.io.
---@class RustDocs.Crate
---@field name        string   Crate name (e.g. "tokio")
---@field version     string   Latest (or selected) version (e.g. "1.35.1")
---@field description string   Short crate description
---@field downloads   number   Total download count

--- A documentation source selection presented in the source picker.
--- kind="std" → browse the local std index.
--- kind="crate" → browse an external crate from docs.rs.
--- kind="search" → special sentinel that triggers a crates.io search input.
---@class RustDocs.Source
---@field kind    "std"|"crate"|"search"
---@field label   string               Display label in the picker
---@field crate?  RustDocs.Crate       Populated when kind == "crate"

