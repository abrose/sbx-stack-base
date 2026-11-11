-- Neo-tree used ONLY as a changed-files tree (git_status source).
-- Snacks explorer stays the default file browser; this is lazy-loaded on the keymap.
return {
  "nvim-neo-tree/neo-tree.nvim",
  branch = "v3.x",
  dependencies = {
    "nvim-lua/plenary.nvim",
    "MunifTanjim/nui.nvim",
    "nvim-tree/nvim-web-devicons",
  },
  cmd = "Neotree",
  keys = {
    {
      "<leader>gt",
      "<cmd>Neotree git_status right toggle<cr>",
      desc = "Changed files tree (git status)",
    },
  },
  opts = {
    sources = { "git_status" },
    git_status = {
      window = {
        mappings = {
          -- Enter opens the file in the normal editor (default), plus common git actions:
          ["A"] = "git_add_all",
          ["ga"] = "git_add_file",
          ["gu"] = "git_unstage_file",
        },
      },
    },
  },
}
