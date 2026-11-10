-- Keymaps are automatically loaded on the VeryLazy event
-- Default keymaps that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/keymaps.lua
-- Add any additional keymaps here

vim.keymap.set("n", "<leader>fy", function()
  local path = vim.fn.expand("%:.") -- relative path
  vim.fn.setreg("+", path)
  Snacks.notify.info("Copied: " .. path)
end, { desc = "Copy Relative Path" })

vim.keymap.set("n", "<leader>fY", function()
  local path = vim.fn.expand("%:p") -- absolute path
  vim.fn.setreg("+", path)
  Snacks.notify.info("Copied: " .. path)
end)

vim.keymap.set("n", "<leader>am", function()
  require("minuet.virtualtext").action.toggle_auto_trigger()
end, { desc = "Toggle Minuet Auto-completion" })

-- Branch changed files -> picker (browse/open individually or <C-q> to quickfix, unlike <leader>gb diffview)
vim.keymap.set("n", "<leader>gB", function()
  local base = "main"
  Snacks.picker.pick({
    source = "branch_changes",
    title = "Branch changes vs " .. base,
    format = "file",
    finder = function()
      -- Merge-base diff (same range as `main...HEAD`), only files changed on the branch.
      local out = vim.fn.systemlist({ "git", "diff", "--name-only", "--diff-filter=d", base .. "...HEAD" })
      if vim.v.shell_error ~= 0 then
        vim.notify(table.concat(out, "\n"), vim.log.levels.ERROR, { title = "git diff" })
        return {}
      end
      local root = vim.fn.systemlist({ "git", "rev-parse", "--show-toplevel" })[1]
      return vim.tbl_map(function(f)
        return { text = f, file = root .. "/" .. f }
      end, out)
    end,
  })
end, { desc = "Branch changed files (picker)" })

-- Open the current file in your default browser, as-is.
-- Browsers render what they can (html, svg, png, pdf, ...); anything
-- else (md, mmd, ...) just shows as raw text.
vim.keymap.set("n", "<leader>ob", function()
  local path = vim.fn.expand("%:p")
  if path == "" then
    vim.notify("No file to open (unnamed buffer)", vim.log.levels.WARN)
    return
  end
  if not vim.fn.filereadable(path) then
    vim.notify("Not on disk yet — write the buffer first", vim.log.levels.WARN)
    return
  end

  -- file:// URL, percent-encoded. `open` sends any URL to the default
  -- browser, so this works for any extension.
  local url = "file://"
    .. (path:gsub("[^A-Za-z0-9/~._%-]", function(c)
      return string.format("%%%02X", c:byte())
    end))

  vim.fn.jobstart({ "open", url }, { detach = true })
end, { desc = "Open file in browser" })
