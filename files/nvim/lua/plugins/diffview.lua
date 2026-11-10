return {
  "sindrets/diffview.nvim",
  cmd = { "DiffviewOpen", "DiffviewFileHistory" },
  keys = {
    { "<leader>gd", "<cmd>DiffviewOpen<cr>", desc = "Diffview: Open (unstaged changes)" },
    { "<leader>gD", "<cmd>DiffviewOpen HEAD~1<cr>", desc = "Diffview: Last commit" },
    {
      "<leader>gb",
      function()
        -- Diff against this branch's base. git-machete tracks the parent
        -- in the stack (branchA for branchB, main for branchA, etc.);
        -- fall back to main when the branch isn't in the machete stack.
        local base = vim.fn.system("git machete show up 2>/dev/null"):gsub("%s+", "")
        if base == "" then
          base = "main"
        end
        vim.cmd("DiffviewOpen " .. base .. "...HEAD")
      end,
      desc = "Diffview: Full branch diff (vs base)",
    },
    { "<leader>gf", "<cmd>DiffviewFileHistory %<cr>", desc = "Diffview: File history" },
    { "<leader>gq", "<cmd>DiffviewClose<cr>", desc = "Diffview: Close" },
  },
  opts = {
    enhanced_diff_hl = true,
    view = {
      default = {
        winbar_info = true, -- shows file path in winbar
      },
    },
    file_panel = {
      listing_style = "tree", -- tree view like you saw, groups by directory
      win_config = {
        width = 46,
      },
    },
  },
}
