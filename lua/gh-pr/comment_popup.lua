local M = {}

local active_popups = {
  by_origin = {},
}

local function safe_string(value, fallback)
  if type(value) == "string" and value ~= "" then
    return value
  end
  return fallback or ""
end

local function valid_buf(bufnr)
  return type(bufnr) == "number" and bufnr > 0 and vim.api.nvim_buf_is_valid(bufnr)
end

local function valid_win(winid)
  return type(winid) == "number" and winid > 0 and vim.api.nvim_win_is_valid(winid)
end

local function sanitize_modal_window(winid)
  if not valid_win(winid) then
    return
  end

  pcall(vim.api.nvim_set_option_value, "scrollbind", false, { win = winid })
  pcall(vim.api.nvim_set_option_value, "cursorbind", false, { win = winid })
  pcall(vim.api.nvim_set_option_value, "diff", false, { win = winid })
  pcall(vim.api.nvim_set_option_value, "spell", false, { win = winid })
end

local function clamp(value, minimum, maximum)
  return math.max(minimum, math.min(maximum, value))
end

local function tag_key(tag)
  local value = safe_string(tag, "default")
  return value ~= "" and value or "default"
end

local function set_origin_popup_var(origin_bufnr, tag, popup_win)
  if not valid_buf(origin_bufnr) then
    return
  end
  if tag == "thread" then
    vim.b[origin_bufnr].gh_pr_thread_popup_win = popup_win
    return
  end
  if tag == "line" then
    vim.b[origin_bufnr].gh_pr_comment_popup_win = popup_win
    return
  end
  vim.b[origin_bufnr].gh_pr_comment_popup_win = popup_win
end

local function clear_origin_popup_var(origin_bufnr, tag)
  if not valid_buf(origin_bufnr) then
    return
  end
  if tag == "thread" then
    vim.b[origin_bufnr].gh_pr_thread_popup_win = nil
    return
  end
  if tag == "line" then
    vim.b[origin_bufnr].gh_pr_comment_popup_win = nil
    return
  end
end

local function clear_origin_state(origin_bufnr, tag)
  local by_tag = active_popups.by_origin[origin_bufnr]
  if type(by_tag) ~= "table" then
    return
  end

  if tag then
    by_tag[tag] = nil
    clear_origin_popup_var(origin_bufnr, tag)
  else
    for existing_tag, _ in pairs(by_tag) do
      clear_origin_popup_var(origin_bufnr, existing_tag)
      by_tag[existing_tag] = nil
    end
  end

  if vim.tbl_isempty(by_tag) then
    active_popups.by_origin[origin_bufnr] = nil
  end
end

function M.close_for_origin(origin_bufnr, tag)
  if type(origin_bufnr) ~= "number" then
    return
  end

  local by_tag = active_popups.by_origin[origin_bufnr]
  if type(by_tag) ~= "table" then
    return
  end

  if tag then
    local popup_win = by_tag[tag]
    if valid_win(popup_win) then
      pcall(vim.api.nvim_win_close, popup_win, true)
    end
    clear_origin_state(origin_bufnr, tag)
    return
  end

  for existing_tag, popup_win in pairs(by_tag) do
    if valid_win(popup_win) then
      pcall(vim.api.nvim_win_close, popup_win, true)
    end
    clear_origin_popup_var(origin_bufnr, existing_tag)
  end
  active_popups.by_origin[origin_bufnr] = nil
end

local function build_lines(opts)
  if type(opts.lines) == "table" and not vim.tbl_isempty(opts.lines) then
    local lines = vim.deepcopy(opts.lines)
    local footer_lines = type(opts.footer_lines) == "table" and opts.footer_lines or {}
    if not vim.tbl_isempty(footer_lines) then
      if #lines > 0 and lines[#lines] ~= "" then
        lines[#lines + 1] = ""
      end
      for _, line in ipairs(footer_lines) do
        lines[#lines + 1] = type(line) == "string" and line or tostring(line)
      end
    end
    return lines, {}, {}
  end

  local lines = {}
  local line_items = {}
  local normalized_items = {}
  lines[#lines + 1] = safe_string(opts.title, "PR comments")

  local location = safe_string(opts.location, "")
  if location ~= "" then
    lines[#lines + 1] = "Location: " .. location
  end

  local subtitle = safe_string(opts.subtitle, "")
  if subtitle ~= "" then
    lines[#lines + 1] = subtitle
  end

  lines[#lines + 1] = string.rep("=", 60)
  lines[#lines + 1] = ""

  local items = type(opts.items) == "table" and opts.items or {}
  if vim.tbl_isempty(items) then
    lines[#lines + 1] = "(no comments)"
    local footer_lines = type(opts.footer_lines) == "table" and opts.footer_lines or {}
    if not vim.tbl_isempty(footer_lines) then
      lines[#lines + 1] = ""
      for _, line in ipairs(footer_lines) do
        lines[#lines + 1] = type(line) == "string" and line or tostring(line)
      end
    end
    return lines, line_items, normalized_items
  end

  for index, item in ipairs(items) do
    local normalized = {
      id = safe_string(item.id, tostring(index)),
      marker = safe_string(item.marker, " "),
      state = safe_string(item.state, "OPEN"),
      author = safe_string(item.author, "unknown"),
      created_at = safe_string(item.created_at, "-"),
      body = safe_string(item.body, "(empty comment)"),
      url = safe_string(item.url, ""),
      meta = type(item.meta) == "table" and vim.deepcopy(item.meta) or nil,
    }
    normalized_items[#normalized_items + 1] = normalized

    local marker = normalized.marker
    local state = normalized.state
    local author = normalized.author
    local created_at = normalized.created_at
    local first_line = #lines + 1
    lines[#lines + 1] = string.format("%s[%s] @%s - %s", marker, state, author, created_at)

    local body = normalized.body
    local body_lines = vim.split(body, "\n", { plain = true })
    if vim.tbl_isempty(body_lines) then
      body_lines = { "(empty comment)" }
    end
    for _, body_line in ipairs(body_lines) do
      lines[#lines + 1] = "  " .. body_line
    end

    local reaction_groups = type(normalized.meta) == "table" and normalized.meta.reaction_groups or nil
    if type(reaction_groups) == "table" and not vim.tbl_isempty(reaction_groups) then
      local reaction_parts = {}
      for _, group in ipairs(reaction_groups) do
        local content = safe_string(type(group) == "table" and group.content or "", "")
        local total_count = tonumber(type(group) == "table" and group.total_count or 0) or 0
        if content ~= "" and total_count > 0 then
          local suffix = type(group) == "table" and group.viewer_has_reacted == true and "*" or ""
          reaction_parts[#reaction_parts + 1] = string.format("%s:%d%s", content, total_count, suffix)
        end
      end
      if not vim.tbl_isempty(reaction_parts) then
        lines[#lines + 1] = "  Reactions: " .. table.concat(reaction_parts, "  ")
      end
    end

    local url = normalized.url
    if url ~= "" then
      lines[#lines + 1] = "  " .. url
    end

    if index < #items then
      lines[#lines + 1] = ""
    end

    local last_line = #lines
    for line = first_line, last_line do
      line_items[line] = index
    end
  end

  local footer_lines = type(opts.footer_lines) == "table" and opts.footer_lines or {}
  if not vim.tbl_isempty(footer_lines) then
    lines[#lines + 1] = ""
    for _, line in ipairs(footer_lines) do
      lines[#lines + 1] = type(line) == "string" and line or tostring(line)
    end
  end

  return lines, line_items, normalized_items
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

local function popup_size(lines, opts)
  local editor_width = math.max(40, vim.o.columns)
  local editor_height = math.max(10, vim.o.lines - vim.o.cmdheight - 1)

  local max_width = math.floor(tonumber(opts.max_width) or math.floor(editor_width * 0.95))
  max_width = clamp(max_width, 20, math.floor(editor_width * 0.95))
  local min_width = math.floor(tonumber(opts.min_width) or 40)
  min_width = clamp(min_width, 20, max_width)

  local width_ratio = tonumber(opts.width_ratio)
  local preferred_width
  if width_ratio and width_ratio > 0 then
    preferred_width = clamp(math.floor(editor_width * width_ratio), min_width, max_width)
  else
    preferred_width = min_width
  end

  local content_width = min_width
  for _, line in ipairs(lines) do
    content_width = math.max(content_width, vim.fn.strdisplaywidth(line) + 2)
  end
  content_width = clamp(content_width, min_width, max_width)
  local width = clamp(math.max(preferred_width, content_width), min_width, max_width)

  local max_height = math.floor(tonumber(opts.max_height) or math.floor(editor_height * 0.9))
  max_height = clamp(max_height, 6, math.floor(editor_height * 0.9))
  local min_height = math.floor(tonumber(opts.min_height) or 6)
  min_height = clamp(min_height, 3, max_height)

  local height_ratio = tonumber(opts.height_ratio)
  local preferred_height
  if height_ratio and height_ratio > 0 then
    preferred_height = clamp(math.floor(editor_height * height_ratio), min_height, max_height)
  else
    preferred_height = min_height
  end

  local content_height = wrapped_rows(lines, math.max(1, width - 2))
  local height = clamp(math.max(preferred_height, math.min(content_height, max_height)), min_height, max_height)

  return width, height
end

local function popup_position(width, height, opts)
  local position = safe_string(opts.position, "editor")
  if position == "cursor" then
    return {
      relative = "cursor",
      row = 1,
      col = 1,
    }
  end

  local use_preview_window = position == "preview_window" or safe_string(opts.mode, "") == "preview"
  local anchor_win = type(opts.anchor_win) == "number" and opts.anchor_win or nil
  if use_preview_window and valid_win(anchor_win) then
    local window_width = vim.api.nvim_win_get_width(anchor_win)
    local window_height = vim.api.nvim_win_get_height(anchor_win)
    local bounded_width = math.max(20, math.min(width, window_width))
    local bounded_height = math.max(6, math.min(height, window_height))
    local row = math.max(0, math.floor((window_height - bounded_height) / 2))
    local col = math.max(0, math.floor((window_width - bounded_width) / 2))
    return {
      relative = "win",
      win = anchor_win,
      row = row,
      col = col,
      width = bounded_width,
      height = bounded_height,
    }
  end

  local row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1)
  local col = math.max(0, math.floor((vim.o.columns - width) / 2))
  return {
    relative = "editor",
    row = row,
    col = col,
  }
end

local function current_item(popup_buf)
  if not valid_buf(popup_buf) then
    return nil
  end

  local line = vim.api.nvim_win_get_cursor(0)[1]
  local line_items = vim.b[popup_buf].gh_pr_popup_line_items
  local item_index = type(line_items) == "table" and line_items[line] or nil
  local items = vim.b[popup_buf].gh_pr_popup_items
  if type(items) ~= "table" or not item_index then
    return nil
  end
  return items[item_index]
end

local function setup_keymaps(popup_buf, popup_win, origin_bufnr, tag, opts)
  local function close_current_popup()
    if valid_win(popup_win) then
      pcall(vim.api.nvim_win_close, popup_win, true)
    end
  end

  local function with_item(callback)
    return function()
      local item = current_item(popup_buf)
      if not item then
        vim.notify("Move the cursor onto a comment first", vim.log.levels.INFO)
        return
      end

      callback(item, {
        popup_bufnr = popup_buf,
        popup_winid = popup_win,
        origin_bufnr = origin_bufnr,
        tag = tag,
        close_popup = close_current_popup,
      })
    end
  end

  vim.keymap.set("n", "q", close_current_popup, {
    buffer = popup_buf,
    silent = true,
    nowait = true,
    desc = "Close PR comments popup",
  })
  vim.keymap.set("n", "<Esc>", close_current_popup, {
    buffer = popup_buf,
    silent = true,
    nowait = true,
    desc = "Close PR comments popup",
  })

  local actions = type(opts.actions) == "table" and opts.actions or {}
  if type(actions.reply) == "function" then
    vim.keymap.set("n", "r", with_item(actions.reply), {
      buffer = popup_buf,
      silent = true,
      nowait = true,
      desc = "Reply to selected PR thread",
    })
  end
  if type(actions.quote) == "function" then
    vim.keymap.set("n", "R", with_item(actions.quote), {
      buffer = popup_buf,
      silent = true,
      nowait = true,
      desc = "Quote-reply to selected PR thread",
    })
  end
  if type(actions.toggle_thread) == "function" then
    vim.keymap.set("n", "x", with_item(actions.toggle_thread), {
      buffer = popup_buf,
      silent = true,
      nowait = true,
      desc = "Resolve or unresolve selected PR thread",
    })
  end
  if type(actions.edit) == "function" then
    vim.keymap.set("n", "e", with_item(actions.edit), {
      buffer = popup_buf,
      silent = true,
      nowait = true,
      desc = "Edit selected PR comment",
    })
  end
  if type(actions.delete) == "function" then
    vim.keymap.set("n", "D", with_item(actions.delete), {
      buffer = popup_buf,
      silent = true,
      nowait = true,
      desc = "Delete selected PR comment",
    })
  end
  if type(actions.add_reaction) == "function" then
    vim.keymap.set("n", "+", with_item(actions.add_reaction), {
      buffer = popup_buf,
      silent = true,
      nowait = true,
      desc = "Add reaction to selected PR comment",
    })
  end
  if type(actions.remove_reaction) == "function" then
    vim.keymap.set("n", "-", with_item(actions.remove_reaction), {
      buffer = popup_buf,
      silent = true,
      nowait = true,
      desc = "Remove reaction from selected PR comment",
    })
  end
end

function M.open(opts)
  opts = type(opts) == "table" and opts or {}

  local origin_bufnr = type(opts.origin_bufnr) == "number" and opts.origin_bufnr or vim.api.nvim_get_current_buf()
  local tag = tag_key(opts.tag)
  M.close_for_origin(origin_bufnr, tag)

  local lines, line_items, normalized_items = build_lines(opts)
  local width, height = popup_size(lines, opts)
  local placement = popup_position(width, height, opts)
  local final_width = placement.width or width
  local final_height = placement.height or height

  local popup_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_option(popup_buf, "buftype", "nofile")
  vim.api.nvim_buf_set_option(popup_buf, "bufhidden", "wipe")
  vim.api.nvim_buf_set_option(popup_buf, "swapfile", false)
  vim.api.nvim_buf_set_option(popup_buf, "filetype", safe_string(opts.filetype, "markdown"))
  vim.api.nvim_buf_set_lines(popup_buf, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(popup_buf, "modifiable", false)
  pcall(vim.api.nvim_set_option_value, "modified", false, { buf = popup_buf })

  local enter_popup = opts.enter == true
  local popup_win = vim.api.nvim_open_win(popup_buf, enter_popup, {
    relative = placement.relative,
    win = placement.win,
    row = placement.row,
    col = placement.col,
    width = final_width,
    height = final_height,
    style = "minimal",
    border = safe_string(opts.border, "rounded"),
    focusable = true,
    noautocmd = true,
  })

  local wrap = opts.wrap ~= false
  sanitize_modal_window(popup_win)
  vim.api.nvim_win_set_option(popup_win, "wrap", wrap)
  vim.api.nvim_win_set_option(popup_win, "linebreak", wrap)
  vim.api.nvim_win_set_option(popup_win, "winhl", safe_string(opts.winhl, "NormalFloat:NormalFloat,FloatBorder:FloatBorder"))

  vim.b[popup_buf].gh_pr_popup_items = normalized_items
  vim.b[popup_buf].gh_pr_popup_line_items = line_items
  setup_keymaps(popup_buf, popup_win, origin_bufnr, tag, opts)

  active_popups.by_origin[origin_bufnr] = active_popups.by_origin[origin_bufnr] or {}
  active_popups.by_origin[origin_bufnr][tag] = popup_win
  set_origin_popup_var(origin_bufnr, tag, popup_win)

  vim.api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(popup_win),
    once = true,
    callback = function(args)
      local closed = tonumber(args and args.match or "")
      if closed == popup_win then
        clear_origin_state(origin_bufnr, tag)
      end
    end,
  })

  if valid_buf(origin_bufnr) then
    vim.api.nvim_create_autocmd({ "BufWipeout", "BufUnload", "BufDelete" }, {
      buffer = origin_bufnr,
      once = true,
      callback = function()
        M.close_for_origin(origin_bufnr, tag)
      end,
    })

    if opts.close_on_origin_move == true then
      vim.api.nvim_create_autocmd({ "CursorMoved", "InsertEnter", "WinScrolled" }, {
        buffer = origin_bufnr,
        once = true,
        callback = function()
          M.close_for_origin(origin_bufnr, tag)
        end,
      })
    end
  end

  return true, nil
end

return M
