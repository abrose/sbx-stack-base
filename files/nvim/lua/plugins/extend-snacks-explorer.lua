return {
  {
    "folke/snacks.nvim",
    opts = {
      picker = {
        hidden = false,
        ignored = false,
        sources = {
          explorer = {
            hidden = true, -- Show hidden/dotfiles by default
            ignored = true, -- Optionally also show gitignored files
            layout = {
              preset = "sidebar",
              preview = "main",
              layout = {
                width = 0.2, -- 20% of screen width
                min_width = 40,
                max_width = 60,
              },
            },
          },
          files = {
            hidden = false,
            ignored = false,
          },
        },
      },
      scratch = {
        win = {
          width = 0.8,
          height = 0.8,
        },
      },
    },
  },
}
