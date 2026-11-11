return {
  "folke/snacks.nvim",
  keys = {
    {
      "<leader>fr",
      function()
        Snacks.picker.recent({
          filter = { cwd = Snacks.git.get_root() or vim.fn.getcwd() },
        })
      end,
      desc = "Recent (worktree)",
    },
    {
      "<leader>fR",
      function()
        Snacks.picker.recent({
          filter = {},
        })
      end,
      desc = "Recent (global)",
    },
  },
}
