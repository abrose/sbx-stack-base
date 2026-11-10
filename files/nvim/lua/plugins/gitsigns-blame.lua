-- Re-enable gitsigns purely for git blame.
-- The `editor.mini-diff` extra sets gitsigns `enabled = false`, and mini.diff
-- has no blame feature. We turn gitsigns back on but disable its signs/gutter
-- so mini.diff keeps owning the sign column, and use gitsigns only for blame.
return {
  {
    "lewis6991/gitsigns.nvim",
    enabled = true,
    event = "LazyFile",
    opts = {
      signcolumn = false, -- mini.diff owns the gutter
      numhl = false,
      linehl = false,
      -- Inline "GitLens-style" blame at end of the current line.
      current_line_blame = true,
      current_line_blame_opts = {
        virt_text = true,
        virt_text_pos = "eol",
        delay = 300,
        ignore_whitespace = false,
      },
      current_line_blame_formatter = "  <author>, <author_time:%R> · <summary>",
    },
    keys = {
      {
        "<leader>ghb",
        function()
          require("gitsigns").blame_line({ full = true })
        end,
        desc = "Blame Line (popup)",
      },
      {
        "<leader>ghB",
        function()
          require("gitsigns").blame()
        end,
        desc = "Blame Buffer",
      },
      {
        "<leader>uB",
        function()
          require("gitsigns").toggle_current_line_blame()
        end,
        desc = "Toggle Inline Blame",
      },
    },
  },
}
