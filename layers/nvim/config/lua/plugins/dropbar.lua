-- Winbar breadcrumb: shows the current file's path components + code symbol
-- at the top of each window. Interactive (click a segment to jump).
return {
  "Bekaboo/dropbar.nvim",
  event = "VeryLazy",
  opts = {
    bar = {
      -- Show path relative to cwd so the winbar stays short; symbols still append.
      sources = function(buf, _)
        local sources = require("dropbar.sources")
        local utils = require("dropbar.utils")
        if vim.bo[buf].ft == "markdown" then
          return { sources.path, sources.markdown }
        end
        return {
          sources.path,
          utils.source.fallback({ sources.lsp, sources.treesitter }),
        }
      end,
    },
  },
  config = function(_, opts)
    require("dropbar").setup(opts)
    -- Toggle the winbar on/off if it ever gets in the way.
    -- Deferred so it overrides LazyVim's default <leader>ub (toggle background),
    -- which is also set on VeryLazy. Background toggle is intentionally replaced.
    vim.schedule(function()
      vim.keymap.set("n", "<leader>ub", function()
        if vim.o.winbar == "" then
          vim.o.winbar = "%{%v:lua.dropbar()%}"
        else
          vim.o.winbar = ""
        end
      end, { desc = "Toggle winbar breadcrumb" })
    end)
  end,
}
