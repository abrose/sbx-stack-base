-- Fails the build when a plugin, a parser of LazyVim's list or the Rust matcher of blink.cmp is missing.
-- The parsers count only in nvim-treesitter's parser folder: Neovim's bundled ones (c, lua, markdown, vim, vimdoc)
-- do not.
local missing = {}
for _, plugin in ipairs(require("lazy").plugins()) do
  if not plugin._.installed then
    missing[#missing + 1] = plugin.name
  end
end
local parsers = require("nvim-treesitter").get_installed("parsers")
for _, lang in ipairs(LazyVim.opts("nvim-treesitter").ensure_installed) do
  if not vim.list_contains(parsers, lang) then
    missing[#missing + 1] = "parser " .. lang
  end
end
if not require("blink.cmp").library_available() then
  missing[#missing + 1] = "the Rust matcher of blink.cmp"
end
if #missing > 0 then
  io.stderr:write("missing: " .. table.concat(missing, ", ") .. "\n")
  os.exit(1)
end
