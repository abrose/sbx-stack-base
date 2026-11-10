return {
  "nvim-mini/mini.diff",
  opts = {},
  keys = {
    {
      "<leader>ghs",
      function()
        require("mini.diff").do_hunks(0, "apply")
      end,
      desc = "Stage Hunk",
    },
    {
      "<leader>ghr",
      function()
        require("mini.diff").do_hunks(0, "reset")
      end,
      desc = "Reset Hunk",
    },
    {
      "<leader>ghs",
      function()
        require("mini.diff").do_hunks(0, "apply")
      end,
      mode = "x",
      desc = "Stage Selection",
    },
    {
      "<leader>ghr",
      function()
        require("mini.diff").do_hunks(0, "reset")
      end,
      mode = "x",
      desc = "Reset Selection",
    },
  },
}
