-- Options are automatically loaded before lazy.nvim startup
-- Default options that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/options.lua
-- Add any additional options here

vim.g.lazyvim_blink_main = true
vim.opt.exrc = true
vim.opt.wrap = true
vim.opt.linebreak = true

-- Reload files that have changed on disk outside of Neovim
vim.o.autoread = true

vim.api.nvim_create_autocmd("BufWinEnter", {
  callback = function(ev)
    local buf = ev.buf
    if vim.bo[buf].buftype == "" and vim.bo[buf].filetype == "" and vim.api.nvim_buf_get_name(buf) ~= "" then
      local ft = vim.filetype.match({ buf = buf })
      if ft then
        vim.bo[buf].filetype = ft
      end
    end
  end,
})
