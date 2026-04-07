local utils = require("gh-pr.overview_utils")

local M = {}

local function sanitize_ratio(value, fallback, min_value, max_value)
  local number = tonumber(value)
  if type(number) ~= "number" then
    return fallback
  end
  if number < min_value or number > max_value then
    return fallback
  end
  return number
end

local function sanitize_non_negative_integer(value, fallback, max_value)
  local number = tonumber(value)
  if type(number) ~= "number" then
    return fallback
  end
  number = math.floor(number)
  if number < 0 then
    return fallback
  end
  if type(max_value) == "number" and number > max_value then
    return max_value
  end
  return number
end

local function sanitize_positive_integer(value, fallback, min_value, max_value)
  local number = tonumber(value)
  if type(number) ~= "number" then
    return fallback
  end
  number = math.floor(number)
  if type(min_value) == "number" and number < min_value then
    return fallback
  end
  if type(max_value) == "number" and number > max_value then
    return fallback
  end
  return number
end

function M.sanitize_layout_opts(input)
  local source = type(input) == "table" and input or {}
  local sidebar_width_ratio = sanitize_ratio(source.sidebar_width_ratio, 0.34, 0.2, 0.6)
  local summary_height_ratio = sanitize_ratio(source.summary_height_ratio, 0.38, 0.2, 0.8)
  local gap = sanitize_non_negative_integer(source.gap, 1, 3)
  local min_left_width = sanitize_positive_integer(source.min_left_width, 58, 40, 220)
  local min_sidebar_width = sanitize_positive_integer(source.min_sidebar_width, 30, 20, 180)
  local min_summary_height = sanitize_positive_integer(source.min_summary_height, 10, 6, 90)
  local min_activity_height = sanitize_positive_integer(source.min_activity_height, 12, 6, 120)

  return {
    sidebar_width_ratio = sidebar_width_ratio,
    summary_height_ratio = summary_height_ratio,
    gap = gap,
    min_left_width = min_left_width,
    min_sidebar_width = min_sidebar_width,
    min_summary_height = min_summary_height,
    min_activity_height = min_activity_height,
  }
end

local function tabpage_valid(tabpage)
  return type(tabpage) == "number" and tabpage > 0 and vim.api.nvim_tabpage_is_valid(tabpage)
end

local function set_window_buffer(winid, bufnr)
  if not utils.valid_win(winid) or not utils.valid_buf(bufnr) then
    return
  end
  vim.api.nvim_win_set_buf(winid, bufnr)
end

local function safe_set_width(winid, width)
  if not utils.valid_win(winid) then
    return
  end
  local value = math.max(1, math.floor(tonumber(width) or 1))
  pcall(vim.api.nvim_win_set_width, winid, value)
end

local function apply_dimensions(windows, layout_opts)
  if not M.windows_valid(windows) then
    return
  end

  local summary_width = vim.api.nvim_win_get_width(windows.summary)
  local meta_width = vim.api.nvim_win_get_width(windows.meta)
  local total_width = math.max(1, summary_width + meta_width)

  local preferred_sidebar_width = math.floor(total_width * layout_opts.sidebar_width_ratio)
  local max_sidebar_width = math.max(layout_opts.min_sidebar_width, total_width - layout_opts.min_left_width)
  local sidebar_width = utils.clamp(preferred_sidebar_width, layout_opts.min_sidebar_width, max_sidebar_width)
  local left_width = total_width - sidebar_width

  if left_width < layout_opts.min_left_width then
    left_width = layout_opts.min_left_width
    sidebar_width = math.max(layout_opts.min_sidebar_width, total_width - left_width)
  end
  if sidebar_width < layout_opts.min_sidebar_width then
    sidebar_width = layout_opts.min_sidebar_width
    left_width = math.max(layout_opts.min_left_width, total_width - sidebar_width)
  end

  safe_set_width(windows.meta, sidebar_width)
  safe_set_width(windows.summary, left_width)
end

local function restore_previous_location(tabpage, winid)
  if tabpage_valid(tabpage) then
    pcall(vim.api.nvim_set_current_tabpage, tabpage)
  end
  if utils.valid_win(winid) then
    pcall(vim.api.nvim_set_current_win, winid)
  end
end

function M.windows_valid(windows)
  if type(windows) ~= "table" then
    return false
  end
  return utils.valid_win(windows.summary) and utils.valid_win(windows.meta)
end

function M.open_windows(buffers, _window_opts, layout_opts, focus_role)
  -- `_window_opts` is kept for backward-compatible config shape; panes now use normal windows in a tabpage.

  local previous_tab = vim.api.nvim_get_current_tabpage()
  local previous_win = vim.api.nvim_get_current_win()

  vim.cmd("tabnew")
  local overview_tab = vim.api.nvim_get_current_tabpage()
  local summary_win = vim.api.nvim_get_current_win()
  set_window_buffer(summary_win, buffers.summary)

  vim.cmd("vsplit")
  local meta_win = vim.api.nvim_get_current_win()
  set_window_buffer(meta_win, buffers.meta)

  local windows = {
    summary = summary_win,
    meta = meta_win,
  }

  apply_dimensions(windows, layout_opts)

  for _, role in ipairs({ "summary", "meta" }) do
    utils.ensure_window_options(windows[role])
  end

  if type(focus_role) == "string" and windows[focus_role] then
    vim.api.nvim_set_current_win(windows[focus_role])
  else
    restore_previous_location(previous_tab, previous_win)
  end

  return windows, overview_tab
end

return M
