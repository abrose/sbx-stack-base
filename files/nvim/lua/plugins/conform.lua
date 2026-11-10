return {
  {
    "stevearc/conform.nvim",
    opts = {
      formatters_by_ft = {
        json = { "prettier" },
        markdown = { "prettier" },
        yaml = { "yamlfmt" },
        css = { "prettier" },
      },
      formatters = {
        yamlfmt = {
          prepend_args = { "-formatter", "type=basic,retain_line_breaks_single=true,force_quote_style=double" },
        },
      },
    },
  },
}
