return {
  "folke/trouble.nvim",
  opts = {
    win = {
      position = "right",
      size = { width = 0.3 },
    },
    modes = {
      quickfix = {
        groups = { "directory" },
        format = "{file_icon} {basename} {count} {pos}",
        win = {
          position = "right",
          size = { width = 0.3 },
        },
      },
    },
  },
  init = function()
    vim.api.nvim_create_autocmd("BufRead", {
      callback = function(ev)
        if vim.bo[ev.buf].buftype == "quickfix" then
          vim.schedule(function()
            vim.cmd([[cclose]])
            vim.cmd([[Trouble quickfix toggle]])
          end)
        end
      end,
    })
  end,
}
