return {
  "saxon1964/neovim-tips",
  enabled = false,
  version = "*", -- Only update on tagged releases
  lazy = false, -- Load on startup for daily tip
  dependencies = {
    "MunifTanjim/nui.nvim",
    -- OPTIONAL: Choose your preferred markdown renderer (or omit for raw markdown)
    "MeanderingProgrammer/render-markdown.nvim", -- Clean rendering
    -- OR: "OXY2DEV/markview.nvim", -- Rich rendering with advanced features
  },
  opts = {
    -- OPTIONAL: Daily tip mode (default: 1)
    daily_tip = 1, -- 0 = off, 1 = once per day, 2 = every startup
    -- OPTIONAL: Bookmark symbol (default: "🌟 ")
    bookmark_symbol = "🌟 ",
  },
}
