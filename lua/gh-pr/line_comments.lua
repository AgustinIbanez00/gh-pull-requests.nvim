local M = {}

local config = require("gh-pr.config")

local namespace = vim.api.nvim_create_namespace("gh-pr-line-comments")
local sign_group = "gh_pr_line_comments"

local sign_names = {
  open = "GhPrCommentSignOpen",
  resolved = "GhPrCommentSignResolved",
  outdated = "GhPrCommentSignOutdated",
}

local hl_groups = {
  open = "GhPrCommentLineOpen",
  resolved = "GhPrCommentLineResolved",
  outdated = "GhPrCommentLineOutdated",
}

local function notify_info(message)
  vim.notify(message, vim.log.levels.INFO)
end

local function safe_string(value, fallback)
  if type(value) == "string" and value ~= "" then
    return value
  end
  return fallback or ""
end

local function normalize_paths(primary, alternatives)
  local seen = {}
  local ordered = {}

  local function add(path)
    if type(path) ~= "string" or path == "" then
      return
    end
    if seen[path] then
      return
    end
    seen[path] = true
    ordered[#ordered + 1] = path
  end

  add(primary)
  for _, path in ipairs(type(alternatives) == "table" and alternatives or {}) do
    add(path)
  end

  return ordered
end

local function infer_side(bufnr, ctx)
  if type(ctx.side) == "string" and (ctx.side == "base" or ctx.side == "head") then
    return ctx.side
  end

  local buffer_side = vim.b[bufnr].gh_pr_comment_side
  if type(buffer_side) == "string" and (buffer_side == "base" or buffer_side == "head") then
    return buffer_side
  end

  local file_kind = vim.b[bufnr].gh_pr_file_kind
  if file_kind == "base" then
    return "base"
  end
  if file_kind == "head" then
    return "head"
  end

  return nil
end

local function entry_key(entry)
  return table.concat({
    safe_string(entry.thread_id, ""),
    safe_string(entry.comment_id, ""),
    safe_string(entry.author, ""),
    safe_string(entry.created_at, ""),
    safe_string(entry.body, ""),
  }, ":")
end

local function collect_line_map(index, side, primary_path, alternatives)
  local line_map = {}
  local dedup = {}
  local paths = normalize_paths(primary_path, alternatives)

  for _, path in ipairs(paths) do
    local by_path = index[path]
    local side_map = by_path and by_path[side] or nil
    if type(side_map) == "table" then
      for line, entries in pairs(side_map) do
        local line_number = tonumber(line)
        if line_number and line_number >= 1 and type(entries) == "table" then
          line_map[line_number] = line_map[line_number] or {}
          dedup[line_number] = dedup[line_number] or {}
          for _, entry in ipairs(entries) do
            local key = entry_key(entry)
            if not dedup[line_number][key] then
              dedup[line_number][key] = true
              line_map[line_number][#line_map[line_number] + 1] = vim.deepcopy(entry)
            end
          end
        end
      end
    end
  end

  for _, entries in pairs(line_map) do
    table.sort(entries, function(left, right)
      local left_key = safe_string(left.created_at, "") .. ":" .. safe_string(left.comment_id, "")
      local right_key = safe_string(right.created_at, "") .. ":" .. safe_string(right.comment_id, "")
      return left_key < right_key
    end)
  end

  return line_map
end

local function marker_kind(entries)
  local has_open = false
  local has_outdated = false

  for _, entry in ipairs(entries or {}) do
    if entry.is_outdated then
      has_outdated = true
    end
    if not entry.is_resolved and not entry.is_outdated then
      has_open = true
    end
  end

  if has_open then
    return "open"
  end
  if has_outdated then
    return "outdated"
  end
  return "resolved"
end

local function ensure_highlights()
  vim.api.nvim_set_hl(0, hl_groups.open, { default = true, link = "DiffText" })
  vim.api.nvim_set_hl(0, hl_groups.resolved, { default = true, link = "DiffAdd" })
  vim.api.nvim_set_hl(0, hl_groups.outdated, { default = true, link = "DiffChange" })
end

local function ensure_signs(sign_config)
  local open_text = safe_string(sign_config.open, "C>")
  local resolved_text = safe_string(sign_config.resolved, "C=")
  local outdated_text = safe_string(sign_config.outdated, "C~")

  vim.fn.sign_define(sign_names.open, { text = open_text, texthl = "DiagnosticHint" })
  vim.fn.sign_define(sign_names.resolved, { text = resolved_text, texthl = "DiffAdd" })
  vim.fn.sign_define(sign_names.outdated, { text = outdated_text, texthl = "WarningMsg" })
end

local function close_popup(bufnr)
  local popup = vim.b[bufnr].gh_pr_comment_popup_win
  if type(popup) == "number" and vim.api.nvim_win_is_valid(popup) then
    pcall(vim.api.nvim_win_close, popup, true)
  end
  vim.b[bufnr].gh_pr_comment_popup_win = nil
end

function M.clear_buffer(bufnr)
  if type(bufnr) ~= "number" or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  close_popup(bufnr)
  vim.api.nvim_buf_clear_namespace(bufnr, namespace, 0, -1)
  pcall(vim.fn.sign_unplace, sign_group, { buffer = bufnr })
  vim.b[bufnr].gh_pr_line_comments = {}
end

local function format_line_comment_popup(entries, line)
  local lines = {
    string.format("PR line comments (%d) at line %d", #entries, line),
    string.rep("=", 42),
    "",
  }

  for index, entry in ipairs(entries) do
    local state = "OPEN"
    if entry.is_resolved then
      state = "RESOLVED"
    elseif entry.is_outdated then
      state = "OUTDATED"
    end

    lines[#lines + 1] = string.format("[%s] @%s - %s", state, safe_string(entry.author, "unknown"), safe_string(entry.created_at, "-"))
    local body_lines = vim.split(safe_string(entry.body, "(empty comment)"), "\n", { plain = true })
    for _, body_line in ipairs(body_lines) do
      lines[#lines + 1] = "  " .. body_line
    end
    if safe_string(entry.url, "") ~= "" then
      lines[#lines + 1] = "  " .. entry.url
    end
    if index < #entries then
      lines[#lines + 1] = ""
    end
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

local function popup_dimensions(lines, max_width, max_height)
  local width = 40
  for _, line in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(line) + 2)
  end
  local screen_width = math.max(20, vim.o.columns - 4)
  width = math.min(width, math.max(20, math.min(max_width, screen_width)))
  local screen_height = math.max(8, vim.o.lines - vim.o.cmdheight - 2)
  local bounded_height = math.max(6, math.min(max_height, screen_height))
  local content_height = wrapped_rows(lines, math.max(1, width - 2))
  local height = math.max(3, math.min(content_height, bounded_height))
  return width, height
end

function M.show_at_cursor(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  local line_map = vim.b[bufnr].gh_pr_line_comments
  if type(line_map) ~= "table" then
    notify_info("No PR comments available for this buffer")
    return
  end

  local line = vim.api.nvim_win_get_cursor(0)[1]
  local entries = line_map[line]
  if type(entries) ~= "table" or vim.tbl_isempty(entries) then
    notify_info("No PR comments for the current line")
    return
  end

  close_popup(bufnr)

  local popup_lines = format_line_comment_popup(entries, line)
  local popup_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_option(popup_buf, "bufhidden", "wipe")
  vim.api.nvim_buf_set_option(popup_buf, "filetype", "markdown")
  vim.api.nvim_buf_set_lines(popup_buf, 0, -1, false, popup_lines)

  local max_width = tonumber(vim.b[bufnr].gh_pr_comment_popup_width) or 90
  local max_height = tonumber(vim.b[bufnr].gh_pr_comment_popup_height) or 18
  local width, height = popup_dimensions(popup_lines, max_width, max_height)

  local popup_win = vim.api.nvim_open_win(popup_buf, false, {
    relative = "cursor",
    row = 1,
    col = 1,
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    focusable = true,
    noautocmd = true,
  })

  vim.api.nvim_win_set_option(popup_win, "wrap", true)
  vim.api.nvim_win_set_option(popup_win, "linebreak", true)
  vim.api.nvim_win_set_option(popup_win, "winhl", "NormalFloat:NormalFloat,FloatBorder:FloatBorder")

  vim.b[bufnr].gh_pr_comment_popup_win = popup_win

  local function close_current_popup()
    close_popup(bufnr)
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

  vim.api.nvim_create_autocmd({ "CursorMoved", "InsertEnter", "WinScrolled" }, {
    buffer = bufnr,
    once = true,
    callback = function()
      close_popup(bufnr)
    end,
  })
end

function M.attach_to_buffer(bufnr, ctx)
  ctx = ctx or {}
  if type(bufnr) ~= "number" or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  local lc_config = (config.get() or {}).line_comments or {}
  M.clear_buffer(bufnr)

  if lc_config.enabled == false then
    return
  end

  local side = infer_side(bufnr, ctx)
  if not side then
    return
  end

  vim.b[bufnr].gh_pr_comment_side = side
  vim.b[bufnr].gh_pr_comment_popup_width = tonumber(ctx.max_popup_width) or tonumber(lc_config.max_popup_width) or 90
  vim.b[bufnr].gh_pr_comment_popup_height = tonumber(ctx.max_popup_height) or tonumber(lc_config.max_popup_height) or 18

  local keymap = safe_string(ctx.keymap, safe_string(lc_config.keymap, "K"))
  vim.keymap.set("n", keymap, function()
    M.show_at_cursor(bufnr)
  end, {
    buffer = bufnr,
    silent = true,
    nowait = true,
    desc = "GH PR: show line comments",
  })

  local index = type(ctx.index) == "table" and ctx.index or {}
  if vim.tbl_isempty(index) then
    vim.b[bufnr].gh_pr_line_comments = {}
    return
  end

  local file_path = safe_string(ctx.file_path, vim.b[bufnr].gh_pr_path)
  local alternatives = type(ctx.alternate_paths) == "table" and ctx.alternate_paths or {}
  local line_map = collect_line_map(index, side, file_path, alternatives)

  vim.b[bufnr].gh_pr_line_comments = line_map

  ensure_highlights()
  ensure_signs(type(ctx.signs) == "table" and ctx.signs or (lc_config.signs or {}))

  for line, entries in pairs(line_map) do
    local kind = marker_kind(entries)
    local style = safe_string(lc_config.indicator_style, "sign_and_highlight")
    if style ~= "highlight_only" then
      pcall(vim.fn.sign_place, 0, sign_group, sign_names[kind], bufnr, {
        lnum = line,
        priority = 30,
      })
    end
    if style ~= "sign_only" then
      pcall(vim.api.nvim_buf_set_extmark, bufnr, namespace, line - 1, 0, {
        line_hl_group = hl_groups[kind],
        hl_eol = true,
        priority = 80,
      })
    end
  end

end

return M
