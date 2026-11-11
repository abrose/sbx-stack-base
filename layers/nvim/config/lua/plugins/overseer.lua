return {
  {
    "stevearc/overseer.nvim",
    opts = {
      component_aliases = {
        default_neotest = {
          "on_output_summarize",
          "on_exit_set_status",
          "on_complete_notify",
          { "on_complete_dispose", timeout = 300 },
        },
      },
    },
    -- stylua: ignore
    keys = {
      { "<leader>or", "<cmd>OverseerRun<cr>", desc = "Run Task" },
      { "<leader>ot", "<cmd>OverseerToggle<cr>", desc = "Toggle Task List" },
      { "<leader>oa", "<cmd>OverseerTaskAction<cr>", desc = "Task Action" },
      {
        "<leader>ol",
        function()
          local overseer = require("overseer")
          local tasks = overseer.list_tasks({ recent_first = true })
          if vim.tbl_isempty(tasks) then
            vim.notify("No tasks found", vim.log.levels.WARN)
          else
            overseer.run_action(tasks[1], "restart")
          end
        end,
        desc = "Restart Last Task",
      },
    },
  },
}
