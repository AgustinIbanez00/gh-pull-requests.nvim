local M = {}

local config = require("gh-pr.config")

local active_popups = {
  by_origin = {},
}

local function safe_string(value, fallback)
  if type(value) == "string" and value ~= "" then
    return value
  end
  return fallback or ""
end

local function options()
  local line_comments = (config.get() or {}).line_comments or {}
  local comments_tree = line_comments.comments_tree or {}
  local thread_popup = comments_tree.thread_popup or {}
  return {
    enabled = thread_popup.enabled ~= false,
    width_ratio = tonumber(thread_popup.width_ratio) or 0.62,
    height_ratio = tonumber(thread_popup.height_ratio) or 0.55,
    min_width = tonumber(thread_popup.min_width) or 80,
    min_height = tonumber(thread_popup.min_height) or 12,
    max_width = tonumber(thread_popup.max_width) or 140,
    max_height = tonumber(thread_popup.max_height) or 40,
    border = safe_string(thread_popup.border, "rounded"),
    wrap = thread_popup.wrap ~= false,
    enter = thread_popup.enter == true,
    position = safe_string(thread_popup.position, "cursor"),
  }
end

local function thread_state_label(thread)
  if thread.is_resolved then
    return "RESOLVED"
  end
  if thread.is_outdated then
    return "OUTDATED"
  end
  return "OPEN"
end

local function normalize_comments(raw_comments)
  local comments = {}
  for index, item in ipairs(type(raw_comments) == "table" and raw_comments or {}) do
    comments[#comments + 1] = {
      id = safe_string(item.id, tostring(index)),
      author = safe_string(item.author, "unknown"),
      created_at = safe_string(item.created_at, "-"),
      body = safe_string(item.body, "(empty comment)"),
      url = safe_string(item.url, ""),
      state = safe_string(item.state, ""),
      outdated = item.outdated == true,
    }
  end

  table.sort(comments, function(left, right)
    local left_key = safe_string(left.created_at, "") .. ":" .. safe_string(left.id, "")
    local right_key = safe_string(right.created_at, "") .. ":" .. safe_string(right.id, "")
    return left_key < right_key
  end)
  return comments
end

local function format_thread_lines(thread)
  local lines = {}
  local state = thread_state_label(thread)
  local path = safe_string(thread.path, "?")
  local line = tonumber(thread.line) or tonumber(thread.original_line) or 0
  local location = line > 0 and string.format("%s:%d", path, line) or path
  local thread_id = safe_string(thread.thread_id, "-")

  lines[#lines + 1] = string.format("PR Thread [%s]", state)
  lines[#lines + 1] = string.format("Location: %s", location)
  lines[#lines + 1] = string.format("Thread: %s", thread_id)
  lines[#lines + 1] = string.rep("=", 60)
  lines[#lines + 1] = ""

  local selected_comment_id = safe_string(thread.selected_comment_id, "")
  local comments = normalize_comments(thread.comments)
  for index, comment in ipairs(comments) do
    local marker = comment.id == selected_comment_id and ">" or " "
    lines[#lines + 1] = string.format("%s[%d] @%s - %s", marker, index, comment.author, comment.created_at)

    local body_lines = vim.split(comment.body, "\n", { plain = true })
    if vim.tbl_isempty(body_lines) then
      body_lines = { "(empty comment)" }
    end
    for _, body_line in ipairs(body_lines) do
      lines[#lines + 1] = "  " .. body_line
    end

    if comment.url ~= "" then
      lines[#lines + 1] = "  " .. comment.url
    end

    if index < #comments then
      lines[#lines + 1] = ""
    end
  end

  if vim.tbl_isempty(comments) then
    lines[#lines + 1] = "(thread has no comments)"
  end

  return lines
end

local function wrapped_rows(lines, content_width)
  local width = math.max(1, content_width)
  local rows = 0
  for _, line in ipairs(lines) do
    local display_width = vim.fn.strdisplaywidth(line)
    rows = rows + math.max(1, math.ceil(display_width / width))
  end
  return rows
end

local function clamp(value, minimum, maximum)
  return math.max(minimum, math.min(maximum, value))
end

local function popup_size(lines, opts)
  local editor_width = math.max(40, vim.o.columns)
  local editor_height = math.max(10, vim.o.lines - vim.o.cmdheight - 1)

  local max_width = math.min(opts.max_width, math.floor(editor_width * 0.95))
  local min_width = math.min(opts.min_width, max_width)
  local preferred_width = clamp(math.floor(editor_width * opts.width_ratio), min_width, max_width)

  local longest = 0
  for _, line in ipairs(lines) do
    longest = math.max(longest, vim.fn.strdisplaywidth(line) + 2)
  end
  local content_width = clamp(longest, min_width, max_width)
  local width = clamp(math.max(preferred_width, content_width), min_width, max_width)

  local max_height = math.min(opts.max_height, math.floor(editor_height * 0.9))
  local min_height = math.min(opts.min_height, max_height)
  local preferred_height = clamp(math.floor(editor_height * opts.height_ratio), min_height, max_height)
  local content_height = wrapped_rows(lines, width - 2)
  local height = clamp(math.max(preferred_height, math.min(content_height, max_height)), min_height, max_height)

  return width, height
end

local function popup_position(width, height, opts, open_opts)
  local use_preview_window = opts.position == "preview_window" or open_opts.mode == "preview"
  local anchor_win = type(open_opts.anchor_win) == "number" and open_opts.anchor_win or nil

  if use_preview_window and anchor_win and vim.api.nvim_win_is_valid(anchor_win) then
    local window_width = vim.api.nvim_win_get_width(anchor_win)
    local window_height = vim.api.nvim_win_get_height(anchor_win)
    local bounded_width = math.max(20, math.min(width, window_width))
    local bounded_height = math.max(6, math.min(height, window_height))
    local row = math.max(0, math.floor((window_height - bounded_height) / 2))
    local col = math.max(0, math.floor((window_width - bounded_width) / 2))

    return {
      width = bounded_width,
      height = bounded_height,
      config = {
        relative = "win",
        win = anchor_win,
        row = row,
        col = col,
      },
    }
  end

  local row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1)
  local col = math.max(0, math.floor((vim.o.columns - width) / 2))
  return {
    width = width,
    height = height,
    config = {
      relative = "editor",
      row = row,
      col = col,
    },
  }
end

local function clear_origin(origin_bufnr)
  active_popups.by_origin[origin_bufnr] = nil
  if vim.api.nvim_buf_is_valid(origin_bufnr) then
    vim.b[origin_bufnr].gh_pr_thread_popup_win = nil
  end
end

function M.close_for_origin(origin_bufnr)
  if type(origin_bufnr) ~= "number" then
    return
  end

  local popup_win = active_popups.by_origin[origin_bufnr]
  if type(popup_win) == "number" and vim.api.nvim_win_is_valid(popup_win) then
    pcall(vim.api.nvim_win_close, popup_win, true)
  end
  clear_origin(origin_bufnr)
end

local function setup_popup_keymaps(bufnr)
  local function close_current_popup()
    local winid = vim.api.nvim_get_current_win()
    if vim.api.nvim_win_is_valid(winid) then
      pcall(vim.api.nvim_win_close, winid, true)
    end
  end

  vim.keymap.set("n", "q", close_current_popup, {
    buffer = bufnr,
    silent = true,
    nowait = true,
    desc = "Close PR thread popup",
  })
  vim.keymap.set("n", "<Esc>", close_current_popup, {
    buffer = bufnr,
    silent = true,
    nowait = true,
    desc = "Close PR thread popup",
  })
end

function M.open(thread, open_opts)
  open_opts = open_opts or {}
  local opts = options()
  if not opts.enabled then
    return false, "thread popup disabled by config"
  end

  local comments = type(thread) == "table" and type(thread.comments) == "table" and thread.comments or {}
  if vim.tbl_isempty(comments) then
    return false, "thread has no comments"
  end

  local origin_bufnr = type(open_opts.origin_bufnr) == "number" and open_opts.origin_bufnr or vim.api.nvim_get_current_buf()
  M.close_for_origin(origin_bufnr)

  local lines = format_thread_lines(thread)
  local width, height = popup_size(lines, opts)
  local placement = popup_position(width, height, opts, open_opts)

  local popup_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_option(popup_buf, "buftype", "nofile")
  vim.api.nvim_buf_set_option(popup_buf, "bufhidden", "wipe")
  vim.api.nvim_buf_set_option(popup_buf, "swapfile", false)
  vim.api.nvim_buf_set_option(popup_buf, "filetype", "markdown")
  vim.api.nvim_buf_set_lines(popup_buf, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(popup_buf, "modifiable", false)

  local enter_popup = type(open_opts.enter) == "boolean" and open_opts.enter or opts.enter

  local popup_win = vim.api.nvim_open_win(popup_buf, enter_popup, vim.tbl_extend("force", placement.config, {
    width = placement.width,
    height = placement.height,
    style = "minimal",
    border = opts.border,
    focusable = true,
    noautocmd = true,
  }))

  vim.api.nvim_win_set_option(popup_win, "wrap", opts.wrap)
  vim.api.nvim_win_set_option(popup_win, "linebreak", opts.wrap)
  vim.api.nvim_win_set_option(popup_win, "winhl", "NormalFloat:NormalFloat,FloatBorder:FloatBorder")

  setup_popup_keymaps(popup_buf)

  active_popups.by_origin[origin_bufnr] = popup_win
  if vim.api.nvim_buf_is_valid(origin_bufnr) then
    vim.b[origin_bufnr].gh_pr_thread_popup_win = popup_win
  end

  vim.api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(popup_win),
    once = true,
    callback = function(args)
      local closed = tonumber(args and args.match or "")
      if closed == popup_win then
        clear_origin(origin_bufnr)
      end
    end,
  })

  if vim.api.nvim_buf_is_valid(origin_bufnr) then
    vim.api.nvim_create_autocmd({ "BufWipeout", "BufDelete" }, {
      buffer = origin_bufnr,
      once = true,
      callback = function()
        M.close_for_origin(origin_bufnr)
      end,
    })
  end

  return true, nil
end

return M
