return {
  {
    "rachartier/tiny-inline-diagnostic.nvim",
    enabled = true,
    event = "VeryLazy",
    priority = 1000,
    opts = {
      preset = "ghost",
      transparent_bg = true,
      transparent_cursorline = true,
      multilines = {
        enabled = false,
      },
      add_messages = {
        display_count = true,
      },
    },
  },
  {
    "neovim/nvim-lspconfig",
    opts = { diagnostics = { virtual_text = false } },
  },
}
