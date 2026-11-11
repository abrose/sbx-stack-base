-- Installs the parsers of LazyVim's list. LazyVim starts the same installs in the background when nvim-treesitter
-- loads, and nvim-treesitter waits only 60 s for an install that runs already. So the script also waits, up to
-- 10 min, until nvim-treesitter's parser folder has every parser of the list.
local TS = require("nvim-treesitter")
local want = LazyVim.opts("nvim-treesitter").ensure_installed
TS.install(want):wait(1800000)
vim.wait(600000, function()
  local have = TS.get_installed("parsers")
  for _, lang in ipairs(want) do
    if not vim.list_contains(have, lang) then
      return false
    end
  end
  return true
end, 500)
