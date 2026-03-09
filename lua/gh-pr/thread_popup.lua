local M = {}

local comment_thread_actions = require("gh-pr.comment_thread_actions")
local comment_popup = require("gh-pr.comment_popup")
local config = require("gh-pr.config")

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
    enter = thread_popup.enter ~= false,
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
      is_pending = item.is_pending == true,
      path = safe_string(item.path, ""),
      line = tonumber(item.line),
      original_line = tonumber(item.original_line),
      viewer_did_author = item.viewer_did_author == true,
      reaction_groups = type(item.reaction_groups) == "table" and vim.deepcopy(item.reaction_groups) or {},
    }
  end

  table.sort(comments, function(left, right)
    local left_key = safe_string(left.created_at, "") .. ":" .. safe_string(left.id, "")
    local right_key = safe_string(right.created_at, "") .. ":" .. safe_string(right.id, "")
    return left_key < right_key
  end)
  return comments
end

local function thread_location(thread)
  local path = safe_string(thread.path, "?")
  local line = tonumber(thread.line) or tonumber(thread.original_line) or 0
  if line > 0 then
    return string.format("%s:%d", path, line)
  end
  return path
end

function M.close_for_origin(origin_bufnr)
  comment_popup.close_for_origin(origin_bufnr, "thread")
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

  local normalized_comments = normalize_comments(comments)
  if vim.tbl_isempty(normalized_comments) then
    return false, "thread has no comments"
  end

  local state = thread_state_label(thread)
  local selected_comment_id = safe_string(thread.selected_comment_id, "")
  local items = {}

  for _, comment in ipairs(normalized_comments) do
    local item_state = safe_string(comment.state, "")
    if item_state == "" then
      if comment.is_pending == true then
        item_state = "PENDING"
      else
        item_state = state
      end
    end
    items[#items + 1] = {
      id = comment.id,
      marker = comment.id == selected_comment_id and ">" or " ",
      state = item_state,
      author = comment.author,
      created_at = comment.created_at,
      body = comment.body,
      url = comment.url,
      meta = {
        pr_number = tonumber(thread.pr_number),
        thread_id = safe_string(thread.thread_id, ""),
        path = safe_string(comment.path, safe_string(thread.path, "")),
        line = tonumber(comment.line) or tonumber(thread.line),
        original_line = tonumber(comment.original_line) or tonumber(thread.original_line),
        comment_id = comment.id,
        comment_database_id = tonumber(comment.database_id) or tonumber(comment.comment_database_id),
        comment_author = comment.author,
        comment_body = comment.body,
        comment_state = item_state,
        comment_is_pending = comment.is_pending == true,
        viewer_did_author = comment.viewer_did_author == true,
        reaction_groups = type(comment.reaction_groups) == "table" and vim.deepcopy(comment.reaction_groups) or {},
        thread_is_resolved = thread.is_resolved == true,
        thread_is_outdated = thread.is_outdated == true,
      },
    }
  end

  local origin_bufnr = type(open_opts.origin_bufnr) == "number" and open_opts.origin_bufnr or vim.api.nvim_get_current_buf()
  local enter_popup = type(open_opts.enter) == "boolean" and open_opts.enter or opts.enter
  local title = string.format("PR Thread [%s] (%d)", state, #items)
  local popup_context = {
    pr_number = tonumber(thread.pr_number),
    details = type(thread.details) == "table" and thread.details or nil,
    thread_id = safe_string(thread.thread_id, ""),
    path = safe_string(thread.path, ""),
    line = tonumber(thread.line),
    original_line = tonumber(thread.original_line),
    thread_is_resolved = thread.is_resolved == true,
    thread_is_outdated = thread.is_outdated == true,
  }
  local popup_actions = comment_thread_actions.build_popup_actions(popup_context)

  return comment_popup.open({
    origin_bufnr = origin_bufnr,
    tag = "thread",
    title = title,
    location = thread_location(thread),
    subtitle = "Thread: " .. safe_string(thread.thread_id, "-"),
    items = items,
    actions = popup_actions,
    footer_provider = comment_thread_actions.build_popup_footer_provider(popup_context),
    mode = safe_string(open_opts.mode, "open"),
    anchor_win = open_opts.anchor_win,
    enter = enter_popup,
    position = opts.position,
    border = opts.border,
    wrap = opts.wrap,
    width_ratio = opts.width_ratio,
    height_ratio = opts.height_ratio,
    min_width = opts.min_width,
    min_height = opts.min_height,
    max_width = opts.max_width,
    max_height = opts.max_height,
    close_on_origin_move = false,
  })
end

return M
