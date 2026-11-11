return {
  "akinsho/git-conflict.nvim",
  event = "BufReadPost", -- defer from startup; only needed when viewing files
  opts = {
    default_mappings = true, -- let the plugin set up <Plug> mappings normally
  },
  keys = {
    { "<leader>ho", "<Plug>(git-conflict-ours)", desc = "Choose Ours" },
    { "<leader>ht", "<Plug>(git-conflict-theirs)", desc = "Choose Theirs" },
    { "<leader>h0", "<Plug>(git-conflict-none)", desc = "Choose None" },
    { "<leader>hB", "<Plug>(git-conflict-both)", desc = "Choose Both" },
    { "]x", "<Plug>(git-conflict-next-conflict)", desc = "Next Conflict" },
    { "[x", "<Plug>(git-conflict-prev-conflict)", desc = "Prev Conflict" },
    { "<leader>gx", "<cmd>GitConflictListQf<cr>", desc = "List Conflicts" },
    { "<leader>gr", "<cmd>GitConflictRefresh<cr>", desc = "Refresh Conflicts" },
  },
}
