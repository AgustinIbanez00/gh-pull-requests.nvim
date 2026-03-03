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

local function compute_geometry(window_opts, layout_opts)
  local width, height = utils.resolve_float_size(window_opts)
  local editor_width = math.max(1, vim.o.columns)
  local editor_height = math.max(1, vim.o.lines - vim.o.cmdheight - 2)

  local row = math.max(0, math.floor((editor_height - height) / 2))
  local col = math.max(0, math.floor((editor_width - width) / 2))
  local gap = layout_opts.gap

  local sidebar_width = math.floor(width * layout_opts.sidebar_width_ratio)
  local max_sidebar_width = math.max(layout_opts.min_sidebar_width, width - layout_opts.min_left_width - gap)
  sidebar_width = utils.clamp(sidebar_width, layout_opts.min_sidebar_width, max_sidebar_width)

  local left_width = width - sidebar_width - gap
  if left_width < layout_opts.min_left_width then
    left_width = layout_opts.min_left_width
    sidebar_width = width - left_width - gap
  end
  if sidebar_width < layout_opts.min_sidebar_width then
    sidebar_width = layout_opts.min_sidebar_width
    left_width = width - sidebar_width - gap
  end

  local summary_height = math.floor(height * layout_opts.summary_height_ratio)
  local max_summary_height = math.max(layout_opts.min_summary_height, height - layout_opts.min_activity_height - gap)
  summary_height = utils.clamp(summary_height, layout_opts.min_summary_height, max_summary_height)
  local activity_height = height - summary_height - gap

  return {
    summary = {
      row = row,
      col = col,
      width = left_width,
      height = summary_height,
    },
    activity = {
      row = row + summary_height + gap,
      col = col,
      width = left_width,
      height = activity_height,
    },
    meta = {
      row = row,
      col = col + left_width + gap,
      width = sidebar_width,
      height = height,
    },
  }
end

local function open_float(bufnr, geometry, title, window_opts, enter)
  local config = {
    relative = "editor",
    style = "minimal",
    border = window_opts.border == "none" and "none" or window_opts.border,
    row = geometry.row,
    col = geometry.col,
    width = geometry.width,
    height = geometry.height,
    title = title,
    title_pos = "left",
    noautocmd = true,
    zindex = 80,
  }

  local ok, winid = pcall(vim.api.nvim_open_win, bufnr, enter, config)
  if not ok then
    config.title = nil
    config.title_pos = nil
    local fallback_ok, fallback_winid = pcall(vim.api.nvim_open_win, bufnr, enter, config)
    if not fallback_ok then
      error("Unable to open overview float window: " .. tostring(fallback_winid))
    end
    winid = fallback_winid
  end

  utils.ensure_window_options(winid)
  return winid
end

function M.windows_valid(windows)
  if type(windows) ~= "table" then
    return false
  end
  return utils.valid_win(windows.summary) and utils.valid_win(windows.activity) and utils.valid_win(windows.meta)
end

function M.open_windows(buffers, window_opts, layout_opts, focus_role)
  local geometry = compute_geometry(window_opts, layout_opts)
  local windows = {
    summary = open_float(buffers.summary, geometry.summary, " Summary ", window_opts, focus_role == "summary"),
    activity = open_float(buffers.activity, geometry.activity, " Activity ", window_opts, focus_role == "activity"),
    meta = open_float(buffers.meta, geometry.meta, " Collaboration ", window_opts, focus_role == "meta"),
  }

  return windows
end

return M
