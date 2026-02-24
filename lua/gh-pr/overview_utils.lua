local M = {}

function M.safe_string(value, fallback)
  if type(value) == "string" and value ~= "" then
    return value
  end
  return fallback or ""
end

function M.split_lines(text)
  if type(text) ~= "string" then
    return {}
  end
  return vim.split(text, "\n", { plain = true })
end

function M.first_non_empty_line(text, fallback)
  for _, line in ipairs(M.split_lines(text)) do
    local trimmed = vim.trim(line)
    if trimmed ~= "" then
      return trimmed
    end
  end
  return fallback or ""
end

local function parse_iso_time(value)
  local text = M.safe_string(value, "")
  if text == "" then
    return nil
  end

  local seconds = vim.fn.strptime("%Y-%m-%dT%H:%M:%SZ", text)
  if type(seconds) == "number" and seconds > 0 then
    return seconds
  end

  return nil
end

function M.format_time(value, date_format)
  local text = M.safe_string(value, "")
  if text == "" then
    return "-"
  end

  local seconds = parse_iso_time(text)
  if not seconds then
    return text
  end

  return vim.fn.strftime(date_format, seconds)
end

function M.bool_or_default(value, default_value)
  if type(value) == "boolean" then
    return value
  end
  return default_value
end

function M.open_url(url)
  if type(url) ~= "string" or url == "" then
    return
  end

  if vim.ui and type(vim.ui.open) == "function" then
    vim.ui.open(url)
    return
  end

  vim.notify("Unable to open URL. vim.ui.open is unavailable.", vim.log.levels.WARN)
end

function M.clamp(value, minimum, maximum)
  if type(value) ~= "number" then
    return minimum
  end
  if value < minimum then
    return minimum
  end
  if value > maximum then
    return maximum
  end
  return value
end

function M.clamp_line(bufnr, line)
  local count = vim.api.nvim_buf_line_count(bufnr)
  if count < 1 then
    return 1
  end
  local value = tonumber(line) or 1
  value = math.floor(value)
  if value < 1 then
    return 1
  end
  if value > count then
    return count
  end
  return value
end

function M.valid_buf(bufnr)
  return type(bufnr) == "number" and bufnr > 0 and vim.api.nvim_buf_is_valid(bufnr)
end

function M.valid_win(winid)
  return type(winid) == "number" and winid > 0 and vim.api.nvim_win_is_valid(winid)
end

function M.current_win_for_buf(bufnr)
  local winid = vim.fn.bufwinid(bufnr)
  if type(winid) == "number" and winid > 0 and M.valid_win(winid) then
    return winid
  end
  return nil
end

function M.window_filetype(winid)
  if not M.valid_win(winid) then
    return nil
  end
  local bufnr = vim.api.nvim_win_get_buf(winid)
  return vim.api.nvim_get_option_value("filetype", { buf = bufnr })
end

function M.is_navigation_window(winid)
  return M.window_filetype(winid) ~= "neo-tree"
end

function M.ensure_navigation_window()
  local current = vim.api.nvim_get_current_win()
  if M.is_navigation_window(current) then
    return current
  end

  local alternate = vim.fn.win_getid(vim.fn.winnr("#"))
  if M.valid_win(alternate) and M.is_navigation_window(alternate) then
    pcall(vim.api.nvim_set_current_win, alternate)
    return alternate
  end

  for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if winid ~= current and M.is_navigation_window(winid) then
      pcall(vim.api.nvim_set_current_win, winid)
      return winid
    end
  end

  vim.cmd("vsplit")
  local created = vim.api.nvim_get_current_win()
  if M.window_filetype(created) == "neo-tree" then
    vim.cmd("enew")
  end
  return created
end

function M.find_buffer_by_name(name)
  for _, candidate in ipairs(vim.api.nvim_list_bufs()) do
    if M.valid_buf(candidate) then
      local ok, current_name = pcall(vim.api.nvim_buf_get_name, candidate)
      if ok and current_name == name then
        return candidate
      end
    end
  end
  return nil
end

function M.set_buffer_name_safe(bufnr, name)
  if not M.valid_buf(bufnr) then
    return
  end

  local current_name = vim.api.nvim_buf_get_name(bufnr)
  if current_name == name then
    return
  end

  local existing = M.find_buffer_by_name(name)
  if existing and existing ~= bufnr then
    return
  end

  local ok = pcall(vim.api.nvim_buf_set_name, bufnr, name)
  if ok then
    return
  end

  local suffix = 1
  while true do
    local fallback = string.format("%s:%d", name, suffix)
    if not M.find_buffer_by_name(fallback) then
      pcall(vim.api.nvim_buf_set_name, bufnr, fallback)
      return
    end
    suffix = suffix + 1
  end
end

function M.ensure_overview_buffer(pr_number, bufnr)
  local target_name = string.format("ghpr://overview/%d", tonumber(pr_number) or 0)
  local existing = M.find_buffer_by_name(target_name)
  if M.valid_buf(existing) then
    return existing
  end

  if M.valid_buf(bufnr) then
    M.set_buffer_name_safe(bufnr, target_name)
    return bufnr
  end

  local created = vim.api.nvim_create_buf(false, true)
  M.set_buffer_name_safe(created, target_name)
  return created
end

function M.ensure_buffer_options(bufnr)
  if not M.valid_buf(bufnr) then
    return
  end

  vim.api.nvim_set_option_value("buftype", "nofile", { buf = bufnr })
  vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = bufnr })
  vim.api.nvim_set_option_value("swapfile", false, { buf = bufnr })
  vim.api.nvim_set_option_value("modifiable", false, { buf = bufnr })
  vim.api.nvim_set_option_value("filetype", "ghpr_overview", { buf = bufnr })
end

function M.ensure_window_options(winid)
  if not M.valid_win(winid) then
    return
  end

  vim.api.nvim_set_option_value("number", false, { win = winid })
  vim.api.nvim_set_option_value("relativenumber", false, { win = winid })
  vim.api.nvim_set_option_value("signcolumn", "no", { win = winid })
  vim.api.nvim_set_option_value("wrap", true, { win = winid })
  vim.api.nvim_set_option_value("linebreak", true, { win = winid })
  vim.api.nvim_set_option_value("breakindent", true, { win = winid })
  vim.api.nvim_set_option_value("cursorline", true, { win = winid })
  vim.api.nvim_set_option_value("foldcolumn", "0", { win = winid })
  vim.api.nvim_set_option_value("spell", false, { win = winid })
end

function M.sanitize_window_opts(input)
  local source = type(input) == "table" and input or {}
  local border = M.safe_string(source.border, "rounded")
  if border ~= "rounded"
    and border ~= "single"
    and border ~= "double"
    and border ~= "solid"
    and border ~= "shadow"
    and border ~= "none" then
    border = "rounded"
  end

  local backdrop = source.backdrop
  if type(backdrop) == "number" then
    backdrop = M.clamp(math.floor(backdrop), 0, 100)
  elseif backdrop ~= false then
    backdrop = 0
  end

  local min_width = M.clamp(math.floor(tonumber(source.min_width) or 100), 40, 400)
  local min_height = M.clamp(math.floor(tonumber(source.min_height) or 28), 10, 200)
  local max_width = M.clamp(math.floor(tonumber(source.max_width) or 180), min_width, 600)
  local max_height = M.clamp(math.floor(tonumber(source.max_height) or 60), min_height, 300)

  local width_ratio = tonumber(source.width_ratio) or 0.88
  local height_ratio = tonumber(source.height_ratio) or 0.88
  width_ratio = M.clamp(width_ratio, 0.2, 1.0)
  height_ratio = M.clamp(height_ratio, 0.2, 1.0)

  return {
    enabled = M.bool_or_default(source.enabled, true),
    border = border,
    width_ratio = width_ratio,
    height_ratio = height_ratio,
    min_width = min_width,
    min_height = min_height,
    max_width = max_width,
    max_height = max_height,
    backdrop = backdrop,
    enter = M.bool_or_default(source.enter, true),
  }
end

function M.sanitize_theme_opts(input)
  local source = type(input) == "table" and input or {}
  return {
    state_colors = M.bool_or_default(source.state_colors, true),
    checks_colors = M.bool_or_default(source.checks_colors, true),
    labels = M.bool_or_default(source.labels, true),
    reviewers = M.bool_or_default(source.reviewers, true),
    timeline_kinds = M.bool_or_default(source.timeline_kinds, true),
  }
end

function M.resolve_float_size(window_opts)
  local editor_width = math.max(1, vim.o.columns)
  local editor_height = math.max(1, vim.o.lines - vim.o.cmdheight - 2)

  local width = math.floor(editor_width * window_opts.width_ratio)
  local height = math.floor(editor_height * window_opts.height_ratio)
  width = M.clamp(width, window_opts.min_width, window_opts.max_width)
  height = M.clamp(height, window_opts.min_height, window_opts.max_height)

  local max_visible_width = math.max(20, editor_width - 4)
  local max_visible_height = math.max(8, editor_height - 2)
  width = math.min(width, max_visible_width)
  height = math.min(height, max_visible_height)
  return width, height
end

return M
