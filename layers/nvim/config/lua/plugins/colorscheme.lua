return {
  {
    "folke/tokyonight.nvim",
    opts = {
      transparent = false,
      styles = {
        sidebars = "normal",
      },
      on_highlights = function(hl, c)
        -- Customize diff highlights (used by mini.diff overlay via links)
        hl.DiffAdd = { bg = "#1a3a14" }
        hl.DiffDelete = { bg = "#440c0c" }
        hl.DiffChange = { bg = "#3a3606" }
        hl.DiffText = { bg = "#4a4608" }
      end,
    },
  },
  {
    "LazyVim/LazyVim",
    opts = {
      colorscheme = "tokyonight",
    },
  },
}
