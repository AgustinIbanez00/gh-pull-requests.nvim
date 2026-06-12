local M = {}

function M.begin(label)
  local text = "  " .. (label or "Working...") .. "  "
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { text })
  vim.bo[buf].modifiable = false

  local width = vim.fn.strwidth(text)
  local win = vim.api.nvim_open_win(buf, false, {
    relative = "editor",
    width = width,
    height = 1,
    row = math.floor((vim.o.lines - 1) / 2) - 1,
    col = math.floor((vim.o.columns - width) / 2),
    style = "minimal",
    border = "rounded",
    noautocmd = true,
    zindex = 200,
    focusable = false,
  })

  pcall(vim.api.nvim_set_option_value, "winhighlight",
    "Normal:GhPrActivity,FloatBorder:GhPrActivityBorder", { win = win })

  return { win = win, buf = buf }
end

function M.done(handle)
  if type(handle) ~= "table" then
    return
  end
  if handle.win and vim.api.nvim_win_is_valid(handle.win) then
    pcall(vim.api.nvim_win_close, handle.win, true)
  end
  if handle.buf and vim.api.nvim_buf_is_valid(handle.buf) then
    pcall(vim.api.nvim_buf_delete, handle.buf, { force = true })
  end
end

return M
