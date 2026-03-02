local M = {}

local function safe_string(value, fallback)
  if type(value) == "string" and value ~= "" then
    return value
  end
  return fallback or ""
end

local function clamp(value, minimum, maximum)
  return math.max(minimum, math.min(maximum, value))
end

local function valid_win(winid)
  return type(winid) == "number" and winid > 0 and vim.api.nvim_win_is_valid(winid)
end

local function valid_buf(bufnr)
  return type(bufnr) == "number" and bufnr > 0 and vim.api.nvim_buf_is_valid(bufnr)
end

local function sanitize_modal_window(winid)
  if not valid_win(winid) then
    return
  end

  pcall(vim.api.nvim_set_option_value, "scrollbind", false, { win = winid })
  pcall(vim.api.nvim_set_option_value, "cursorbind", false, { win = winid })
  pcall(vim.api.nvim_set_option_value, "diff", false, { win = winid })
end

local function compute_size(opts)
  local editor_width = math.max(40, vim.o.columns)
  local editor_height = math.max(12, vim.o.lines - vim.o.cmdheight - 1)

  local width_ratio = tonumber(opts.width_ratio) or 0.72
  local height_ratio = tonumber(opts.height_ratio) or 0.55

  local min_width = clamp(math.floor(tonumber(opts.min_width) or 70), 40, editor_width)
  local max_width = clamp(math.floor(tonumber(opts.max_width) or 140), min_width, editor_width)
  local min_height = clamp(math.floor(tonumber(opts.min_height) or 10), 6, editor_height)
  local max_height = clamp(math.floor(tonumber(opts.max_height) or 40), min_height, editor_height)

  local width = clamp(math.floor(editor_width * width_ratio), min_width, max_width)
  local height = clamp(math.floor(editor_height * height_ratio), min_height, max_height)

  return width, height
end

local function trim_text(lines)
  local first = 1
  local last = #lines

  while first <= last and vim.trim(lines[first]) == "" do
    first = first + 1
  end

  while last >= first and vim.trim(lines[last]) == "" do
    last = last - 1
  end

  if first > last then
    return ""
  end

  local selected = {}
  for index = first, last do
    selected[#selected + 1] = lines[index]
  end
  return table.concat(selected, "\n")
end

local function ensure_initial_lines(initial)
  local lines = type(initial) == "table" and vim.deepcopy(initial) or { "" }
  if vim.tbl_isempty(lines) then
    lines = { "" }
  end
  return lines
end

local function focus_origin_window(winid)
  if valid_win(winid) then
    pcall(vim.api.nvim_set_current_win, winid)
  end
end

function M.open(opts)
  opts = type(opts) == "table" and opts or {}
  local on_submit = type(opts.on_submit) == "function" and opts.on_submit or function() end
  local on_cancel = type(opts.on_cancel) == "function" and opts.on_cancel or function() end
  local origin_win = vim.api.nvim_get_current_win()

  local width, height = compute_size(opts)
  local row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1)
  local col = math.max(0, math.floor((vim.o.columns - width) / 2))

  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_option(bufnr, "buftype", "nofile")
  vim.api.nvim_buf_set_option(bufnr, "bufhidden", "wipe")
  vim.api.nvim_buf_set_option(bufnr, "swapfile", false)
  vim.api.nvim_buf_set_option(bufnr, "modifiable", true)
  vim.api.nvim_buf_set_option(bufnr, "filetype", safe_string(opts.filetype, "markdown"))
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, ensure_initial_lines(opts.initial_lines))

  local winid = vim.api.nvim_open_win(bufnr, opts.enter ~= false, {
    relative = "editor",
    row = row,
    col = col,
    width = width,
    height = height,
    style = "minimal",
    border = safe_string(opts.border, "rounded"),
    title = safe_string(opts.title, "PR review comment"),
    title_pos = "center",
    noautocmd = true,
  })

  sanitize_modal_window(winid)
  vim.api.nvim_win_set_option(winid, "wrap", true)
  vim.api.nvim_win_set_option(winid, "linebreak", true)
  vim.api.nvim_win_set_option(winid, "cursorline", true)
  vim.api.nvim_win_set_option(winid, "winhl", "NormalFloat:NormalFloat,FloatBorder:FloatBorder")

  local finished = false

  local function finish_cancel()
    if finished then
      return
    end
    finished = true
    if valid_win(winid) then
      pcall(vim.api.nvim_win_close, winid, true)
    end
    focus_origin_window(origin_win)
    on_cancel()
  end

  local function finish_submit()
    if finished then
      return
    end
    finished = true
    local lines = {}
    if valid_buf(bufnr) then
      lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    end
    local text = trim_text(lines)
    if valid_win(winid) then
      pcall(vim.api.nvim_win_close, winid, true)
    end
    focus_origin_window(origin_win)
    on_submit(text)
  end

  vim.keymap.set("n", "<C-s>", finish_submit, {
    buffer = bufnr,
    silent = true,
    nowait = true,
    desc = "Submit PR review comment",
  })
  vim.keymap.set("i", "<C-s>", function()
    finish_submit()
  end, {
    buffer = bufnr,
    silent = true,
    nowait = true,
    desc = "Submit PR review comment",
  })
  vim.keymap.set("n", "q", finish_cancel, {
    buffer = bufnr,
    silent = true,
    nowait = true,
    desc = "Cancel PR review comment",
  })
  vim.keymap.set("n", "<Esc>", finish_cancel, {
    buffer = bufnr,
    silent = true,
    nowait = true,
    desc = "Cancel PR review comment",
  })

  vim.api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(winid),
    once = true,
    callback = function()
      if not finished then
        finished = true
        focus_origin_window(origin_win)
        on_cancel()
      end
    end,
  })

  if opts.enter ~= false and valid_win(winid) then
    pcall(vim.api.nvim_set_current_win, winid)
    vim.cmd("startinsert")
  end

  return bufnr, winid
end

return M
