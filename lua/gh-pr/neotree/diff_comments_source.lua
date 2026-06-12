local config = require("gh-pr.config")
local pr_service = require("gh-pr.pr_service")
local registry = require("gh-pr.neotree.registry")
local thread_popup = require("gh-pr.thread_popup")

local M = {
  name = "gh_pr_diff_comments",
  display_name = "GH Diff Comments",
}

local SOURCE_NAME = "gh_pr_diff_comments"
local SOURCE_MODULE = "gh-pr.neotree.diff_comments_source_entry"

local sessions = {}
local state_by_buffer = {}

local function valid_buf(bufnr)
  return type(bufnr) == "number" and bufnr > 0 and vim.api.nvim_buf_is_valid(bufnr)
end

local function valid_win(winid)
  return type(winid) == "number" and winid > 0 and vim.api.nvim_win_is_valid(winid)
end

local function valid_tab(tabid)
  return type(tabid) == "number" and tabid > 0 and vim.api.nvim_tabpage_is_valid(tabid)
end

local function normalize_path(path)
  if type(path) ~= "string" then
    return ""
  end
  return path:gsub("\\", "/")
end

local function int(value, fallback)
  local number = tonumber(value)
  if not number then
    return fallback
  end

  number = math.floor(number)
  if number < 1 then
    return fallback
  end

  return number
end

local function first_pos(...)
  for index = 1, select("#", ...) do
    local value = select(index, ...)
    value = tonumber(value)
    if value and value > 0 then
      return math.floor(value)
    end
  end
  return nil
end

local function safe_string(value, fallback)
  if type(value) == "string" and value ~= "" then
    return value
  end
  return fallback or ""
end

local function panel_opts()
  local diff_view = (config.get() or {}).diff_view or {}
  local src = type(diff_view.comments_panel) == "table" and diff_view.comments_panel
    or type(diff_view.review_panel) == "table" and diff_view.review_panel
    or {}

  local auto_open = type(src.auto_open) == "string" and src.auto_open or "if_comments"
  if auto_open ~= "never" and auto_open ~= "if_comments" and auto_open ~= "always" then
    auto_open = "if_comments"
  end

  local position = type(src.position) == "string" and src.position:lower() or "bottom"
  if position ~= "bottom" and position ~= "right" then
    position = "bottom"
  end

  local min_height = int(src.min_height, 8)
  local max_height = int(src.max_height, 18)
  if max_height < min_height then
    max_height = min_height
  end

  local height_ratio = tonumber(src.height_ratio)
  if type(height_ratio) ~= "number" or height_ratio < 0.10 or height_ratio > 0.80 then
    height_ratio = 0.28
  end

  return {
    enabled = src.enabled ~= false,
    auto_open = auto_open,
    position = position,
    height_ratio = height_ratio,
    min_height = min_height,
    max_height = max_height,
    follow_cursor = src.follow_cursor ~= false,
    show_resolved = src.show_resolved ~= false,
    show_outdated = src.show_outdated ~= false,
    close_with_dq = src.close_with_dq ~= false,
  }
end

local function panel_window_spec(opts)
  opts = type(opts) == "table" and opts or panel_opts()

  local position = opts.position == "right" and "right" or "bottom"
  local spec = {
    position = position,
    height = nil,
  }

  if position == "bottom" then
    local lines = vim.api.nvim_get_option_value("lines", {}) or 40
    spec.height = math.min(opts.max_height, math.max(opts.min_height, math.floor(lines * opts.height_ratio)))
  end

  return spec
end

local function source_position_matches(session, opts)
  if type(session) ~= "table" then
    return true
  end

  return session.window_position == panel_window_spec(opts).position
end

local function buffer_filetype(bufnr)
  if not valid_buf(bufnr) then
    return ""
  end

  local ok, filetype = pcall(vim.api.nvim_get_option_value, "filetype", { buf = bufnr })
  if ok and type(filetype) == "string" then
    return filetype
  end

  return type(vim.bo[bufnr].filetype) == "string" and vim.bo[bufnr].filetype or ""
end

local function source_buffer(bufnr)
  return buffer_filetype(bufnr) == "neo-tree" and vim.b[bufnr].neo_tree_source == SOURCE_NAME
end

local function live_state_window_buffer(state)
  if type(state) ~= "table" then
    return nil, nil
  end

  local winid = tonumber(state.winid)
  if not valid_win(winid) then
    return nil, nil
  end

  local bufnr = vim.api.nvim_win_get_buf(winid)
  if not valid_buf(bufnr) then
    return nil, nil
  end

  return winid, bufnr
end

local function state_is_live(state)
  local _, bufnr = live_state_window_buffer(state)
  if not bufnr then
    return false
  end

  return source_buffer(bufnr)
end

local function renderer_module()
  local ok, renderer = pcall(require, "neo-tree.ui.renderer")
  if ok then
    return renderer
  end
  return nil
end

local function neotree_integration()
  local ok, neotree = pcall(require, "gh-pr.integrations.neotree")
  if ok then
    return neotree
  end
  return nil
end

local function actions_module()
  local ok, actions = pcall(require, "gh-pr.actions")
  if ok then
    return actions
  end
  return nil
end

local function build_diff_window_entry(winid, bufnr)
  if not valid_win(winid) then
    return nil
  end

  local target_buf = tonumber(bufnr)
  if not valid_buf(target_buf) then
    target_buf = vim.api.nvim_win_get_buf(winid)
  end
  if not valid_buf(target_buf) then
    return nil
  end

  local kind = vim.b[target_buf].gh_pr_file_kind
  if kind ~= "base" and kind ~= "head" and kind ~= "unified" then
    return nil
  end

  return {
    winid = winid,
    bufnr = target_buf,
    kind = kind,
    pr_number = tonumber(vim.b[target_buf].gh_pr_number),
    path = normalize_path(vim.b[target_buf].gh_pr_file_path or vim.b[target_buf].gh_pr_path),
  }
end

local function diff_windows(tabid, pr_number)
  local out = {}
  if not valid_tab(tabid) then
    return out
  end

  for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(tabid)) do
    local entry = build_diff_window_entry(winid)
    if entry and (not pr_number or entry.pr_number == pr_number) then
      out[#out + 1] = entry
    end
  end

  return out
end

local function resolve_candidate_diff_windows(tabid, pr_number, ctx)
  local candidates = diff_windows(tabid, pr_number)
  if #candidates > 0 then
    return candidates
  end

  local out = {}
  local seen = {}
  local function add(entry)
    if not entry or seen[entry.winid] then
      return
    end
    seen[entry.winid] = true
    out[#out + 1] = entry
  end

  ctx = type(ctx) == "table" and ctx or {}
  local origin_win = tonumber(ctx.origin_win)
  if valid_win(origin_win) and vim.api.nvim_win_get_tabpage(origin_win) == tabid then
    add(build_diff_window_entry(origin_win, ctx.origin_buf))
  end

  local current_win = vim.api.nvim_get_current_win()
  if valid_win(current_win) and vim.api.nvim_win_get_tabpage(current_win) == tabid then
    add(build_diff_window_entry(current_win))
  end

  if #out > 0 then
    return out
  end

  for _, entry in ipairs(diff_windows(tabid, nil)) do
    add(entry)
  end

  return out
end

local function side_from_hint(value, head_line, base_line)
  local normalized = type(value) == "string" and value:lower() or ""
  if normalized == "left" or normalized == "base" then
    return "base"
  end
  if normalized == "right" or normalized == "head" then
    return "head"
  end
  if head_line and not base_line then
    return "head"
  end
  if base_line and not head_line then
    return "base"
  end
  return "head"
end

local function body_preview(body)
  if type(body) ~= "string" or body == "" then
    return "(empty comment)"
  end

  local line = vim.trim((body:match("([^\r\n]+)") or ""))
  if line == "" then
    return "(empty comment)"
  end
  if #line > 90 then
    return line:sub(1, 87) .. "..."
  end
  return line
end

local function normalize_comment_time(created_at)
  if type(created_at) ~= "string" or created_at == "" then
    return "-"
  end
  return created_at:gsub("T", " "):gsub("Z", "")
end

local function sort_comments_by_time(comments)
  table.sort(comments, function(left, right)
    local left_key = normalize_comment_time(left.created_at) .. ":" .. safe_string(left.id, "")
    local right_key = normalize_comment_time(right.created_at) .. ":" .. safe_string(right.id, "")
    return left_key < right_key
  end)
end

local function normalize_thread_comment(comment, fallback_index)
  local author = "unknown"
  if type(comment.author) == "table" and type(comment.author.login) == "string" and comment.author.login ~= "" then
    author = comment.author.login
  elseif type(comment.author) == "string" and comment.author ~= "" then
    author = comment.author
  end

  return {
    id = type(comment.id) == "string" and comment.id ~= "" and comment.id or tostring(fallback_index),
    database_id = tonumber(comment.databaseId) or tonumber(comment.database_id),
    author = author,
    body = type(comment.body) == "string" and comment.body or "",
    created_at = type(comment.createdAt) == "string" and comment.createdAt
      or (type(comment.created_at) == "string" and comment.created_at or ""),
    line = first_pos(comment.line, comment.startLine, comment.start_line),
    original_line = first_pos(comment.originalLine, comment.originalStartLine, comment.original_start_line),
    url = type(comment.url) == "string" and comment.url or "",
    state = type(comment.state) == "string" and comment.state or "",
    outdated = comment.outdated == true,
    is_pending = comment.isPending == true or comment.is_pending == true,
    viewer_did_author = comment.viewerDidAuthor == true or comment.viewer_did_author == true,
    reaction_groups = vim.deepcopy(type(comment.reactionGroups) == "table" and comment.reactionGroups or (type(comment.reaction_groups) == "table" and comment.reaction_groups or {})),
  }
end

local function normalize_thread_comments(thread)
  local comments = {}
  for index, comment in ipairs(type(thread.comments) == "table" and thread.comments or {}) do
    comments[#comments + 1] = normalize_thread_comment(comment, index)
  end
  sort_comments_by_time(comments)
  return comments
end

local function thread_status(thread)
  if thread.isResolved == true or thread.is_resolved == true then
    return "RESOLVED"
  end
  if thread.isOutdated == true or thread.is_outdated == true then
    return "OUTDATED"
  end
  return "OPEN"
end

local function thread_target(session, thread, comments)
  local head_line = first_pos(thread.startLine, thread.start_line, thread.line)
  local base_line = first_pos(thread.originalStartLine, thread.original_start_line, thread.originalLine, thread.original_line)
  local side = side_from_hint(thread.diffSide or thread.diff_side, head_line, base_line)

  return {
    pr = session.pr,
    details = session.details,
    pr_number = session.pr_number,
    path = session.target_path,
    side = side,
    line = head_line or base_line,
    original_line = base_line or head_line,
    thread_id = safe_string(thread.id, "thread"),
    thread_comments = comments,
    selected_comment_id = comments[1] and comments[1].id or nil,
    thread_is_resolved = thread.isResolved == true or thread.is_resolved == true,
    thread_is_outdated = thread.isOutdated == true or thread.is_outdated == true,
  }
end

local function primary_line(target)
  if type(target) ~= "table" then
    return math.huge
  end

  if target.side == "base" then
    return first_pos(target.original_line, target.line) or math.huge
  end

  return first_pos(target.line, target.original_line) or math.huge
end

local function message_node(session, suffix, message)
  return {
    id = string.format("ghpr-diff-comments:%d:%s", tonumber(session.pr_number) or 0, suffix),
    name = message,
    type = "message",
    extra = {
      kind = "message",
      pr = session.pr,
      details = session.details,
    },
  }
end

local function root_name(session)
  local path = session.target_path ~= "" and session.target_path or "(unknown file)"
  return string.format("%s | threads: %d | comments: %d", path, session.thread_total or 0, session.comment_total or 0)
end

local function base_root(session, children)
  return {
    {
      id = string.format("ghpr-diff-comments:%d:root:%s", tonumber(session.pr_number) or 0, session.target_path or ""),
      name = root_name(session),
      type = "folder",
      extra = {
        kind = "root",
        pr = session.pr,
        details = session.details,
      },
      children = children or {},
    },
  }
end

local function loading_nodes(session)
  return base_root(session, {
    message_node(session, "loading", string.format("Loading comments for %s...", session.target_path ~= "" and session.target_path or "current file")),
  })
end

local function empty_nodes(session)
  return base_root(session, {
    message_node(session, "empty", "No comments for this file."),
  })
end

local function error_nodes(session, err)
  local children = {
    message_node(session, "error", "Unable to load comments for this file."),
  }
  if type(err) == "string" and err ~= "" then
    children[#children + 1] = message_node(session, "error-detail", err)
  end
  return base_root(session, children)
end

local function build_ready_nodes(session, threads)
  local options = panel_opts()
  local thread_entries = {}
  local thread_total = 0
  local comment_total = 0
  local target_path = normalize_path(session.target_path)

  for index, thread in ipairs(type(threads) == "table" and threads or {}) do
    local is_resolved = thread.isResolved == true or thread.is_resolved == true
    local is_outdated = thread.isOutdated == true or thread.is_outdated == true

    if normalize_path(thread.path) == target_path
      and (options.show_resolved or not is_resolved)
      and (options.show_outdated or not is_outdated) then
      local comments = normalize_thread_comments(thread)
      if #comments > 0 then
        thread_total = thread_total + 1
        comment_total = comment_total + #comments

        local target = thread_target(session, thread, comments)
        local line = primary_line(target)
        local status = thread_status(thread)
        local thread_name = string.format("Thread L%s [%s] x%d", line ~= math.huge and tostring(line) or "?", status, #comments)
        local thread_node = {
          id = string.format("ghpr-diff-comments:%d:thread:%s:%d", session.pr_number, safe_string(thread.id, "thread"), index),
          name = thread_name,
          type = "directory",
          path = target_path,
          extra = {
            kind = "thread",
            pr = session.pr,
            details = session.details,
            target = target,
          },
          children = {},
        }

        for comment_index, comment in ipairs(comments) do
          local comment_target = vim.tbl_extend("force", {}, target, {
            selected_comment_id = comment.id,
            line = first_pos(comment.line, target.line, target.original_line),
            original_line = first_pos(comment.original_line, target.original_line, target.line),
          })
          thread_node.children[#thread_node.children + 1] = {
            id = string.format("ghpr-diff-comments:%d:comment:%s:%d", session.pr_number, safe_string(comment.id, "comment"), comment_index),
            name = string.format("@%s: %s", comment.author, body_preview(comment.body)),
            type = "file",
            path = target_path,
            extra = {
              kind = "comment",
              pr = session.pr,
              details = session.details,
              target = comment_target,
              comment = comment,
            },
          }
        end

        thread_entries[#thread_entries + 1] = {
          line = line,
          node = thread_node,
        }
      end
    end
  end

  table.sort(thread_entries, function(left, right)
    if left.line ~= right.line then
      return left.line < right.line
    end
    return left.node.name < right.node.name
  end)

  local children = {}
  for _, item in ipairs(thread_entries) do
    children[#children + 1] = item.node
  end

  session.thread_total = thread_total
  session.comment_total = comment_total

  if #children == 0 then
    return empty_nodes(session)
  end

  return base_root(session, children)
end

local function file_for_path(details, path)
  local normalized_target = normalize_path(path)
  for _, file in ipairs(type(details.files) == "table" and details.files or {}) do
    for _, candidate in ipairs({ file.path, file.filename, file.previousFilename, file.previous_filename }) do
      if normalize_path(candidate) == normalized_target then
        return file
      end
    end
  end

  return {
    path = path,
    filename = path,
  }
end

local function popup_thread_from_target(target)
  local popup_comments = type(target) == "table" and target.thread_comments or nil
  if type(popup_comments) ~= "table" or vim.tbl_isempty(popup_comments) then
    return nil
  end

  return {
    thread_id = safe_string(target.thread_id, string.format("line:%s", safe_string(target.path, "unknown"))),
    path = safe_string(target.path, ""),
    side = safe_string(target.side, "head"),
    line = tonumber(target.line) or tonumber(target.original_line),
    original_line = tonumber(target.original_line) or tonumber(target.line),
    selected_comment_id = safe_string(target.selected_comment_id, ""),
    is_resolved = target.thread_is_resolved == true,
    is_outdated = target.thread_is_outdated == true,
    comments = vim.deepcopy(popup_comments),
  }
end

local function move_to_target_window(session, target)
  local tabid = session.tabid
  local source_win = valid_win(vim.api.nvim_get_current_win()) and vim.api.nvim_get_current_win() or nil
  local destination, destination_kind

  for _, item in ipairs(resolve_candidate_diff_windows(tabid, session.pr_number, session.origin)) do
    if normalize_path(item.path) == normalize_path(target.path) or item.path == "" then
      if item.kind == "unified"
        or (target.side == "base" and item.kind == "base")
        or (target.side ~= "base" and item.kind == "head") then
        destination = item.winid
        destination_kind = item.kind
        break
      end
      if not destination then
        destination = item.winid
        destination_kind = item.kind
      end
    end
  end

  if not valid_win(destination) then
    local actions = actions_module()
    if not actions or type(actions.open_diff) ~= "function" then
      return nil, nil, "Unable to load diff navigation actions"
    end
    if type(actions.set_active_pr) == "function" then
      actions.set_active_pr(session.pr, session.details)
    end

    actions.open_diff(file_for_path(session.details, target.path), { new_tab = false })

    for _, item in ipairs(resolve_candidate_diff_windows(tabid, session.pr_number, session.origin)) do
      if normalize_path(item.path) == normalize_path(target.path) or item.path == "" then
        destination = item.winid
        destination_kind = item.kind
        if destination_kind == "unified"
          or (target.side == "base" and destination_kind == "base")
          or (target.side ~= "base" and destination_kind == "head") then
          break
        end
      end
    end
  end

  if not valid_win(destination) then
    return nil, nil, "Unable to locate destination diff window"
  end

  local line = destination_kind == "base"
      and first_pos(target.original_line, target.line, 1)
    or first_pos(target.line, target.original_line, 1)
  line = int(line, 1)
  local max_line = vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(destination))
  line = math.max(1, math.min(max_line, line))

  pcall(vim.api.nvim_set_current_win, destination)
  pcall(vim.api.nvim_win_set_cursor, destination, { line, 0 })

  return destination, destination_kind, nil, source_win
end

local function open_target_popup(target, popup_mode, focus_thread_popup, current_win)
  local popup_thread = popup_thread_from_target(target)
  if not popup_thread or type(popup_thread.comments) ~= "table" or vim.tbl_isempty(popup_thread.comments) then
    return true, nil
  end

  local current_buf = vim.api.nvim_get_current_buf()
  return thread_popup.open(popup_thread, {
    mode = popup_mode == "preview" and "preview" or "open",
    origin_bufnr = current_buf,
    anchor_win = current_win,
    enter = focus_thread_popup == true,
  })
end

local function clear_source_chrome(state)
  if type(state) ~= "table" then
    return
  end

  state.enable_source_selector = false

  local winid = tonumber(state.winid)
  if not valid_win(winid) then
    return
  end

  pcall(vim.api.nvim_set_option_value, "winbar", "", { win = winid })
  pcall(vim.api.nvim_set_option_value, "statusline", "", { win = winid })
end

local function render_state(state, session)
  local renderer = renderer_module()
  if not renderer or type(renderer.show_nodes) ~= "function" then
    return false
  end

  clear_source_chrome(state)
  local ok = pcall(renderer.show_nodes, session.nodes or loading_nodes(session), state)
  if ok then
    clear_source_chrome(state)
    local _, bufnr = live_state_window_buffer(state)
    if bufnr then
      state_by_buffer[bufnr] = state
    end
  end
  return ok
end

local function render_session(session)
  if type(session) ~= "table" then
    return
  end

  for state_key, state in pairs(session.states or {}) do
    if not state_is_live(state) then
      session.states[state_key] = nil
    else
      render_state(state, session)
    end
  end
end

local function register_state(session, state)
  session.states = session.states or {}
  session.states[tostring(state)] = state
  render_state(state, session)
end

local function resolve_target(ctx, pr_number)
  ctx = type(ctx) == "table" and ctx or {}

  local path = normalize_path(ctx.file_path)
  local kind = type(ctx.file_kind) == "string" and ctx.file_kind or nil
  if path ~= "" and (kind == "base" or kind == "head" or kind == "unified") then
    return { path = path, kind = kind }
  end

  local origin_entry = build_diff_window_entry(tonumber(ctx.origin_win), tonumber(ctx.origin_buf))
  if origin_entry and origin_entry.pr_number == pr_number and origin_entry.path ~= "" then
    return {
      path = origin_entry.path,
      kind = origin_entry.kind,
    }
  end

  for _, entry in ipairs(resolve_candidate_diff_windows(vim.api.nvim_get_current_tabpage(), pr_number, ctx)) do
    if entry.path ~= "" then
      return {
        path = entry.path,
        kind = entry.kind,
      }
    end
  end

  return nil, "No active diff file found for comments tree"
end

local function ensure_session(ctx)
  local pr_number = tonumber(ctx.pr_number or (ctx.pr and ctx.pr.number) or vim.b.gh_pr_number)
  if not pr_number then
    return nil, nil, "Missing PR number for diff comments tree"
  end

  local target, target_err = resolve_target(ctx, pr_number)
  if not target then
    return nil, nil, target_err
  end

  local tabid = vim.api.nvim_get_current_tabpage()
  local session = sessions[tabid]
  if type(session) ~= "table" or session.pr_number ~= pr_number then
    session = {
      tabid = tabid,
      pr_number = pr_number,
      request_id = 0,
      states = {},
      status = "idle",
      nodes = nil,
      thread_total = 0,
      comment_total = 0,
    }
    sessions[tabid] = session
  end

  session.pr = type(ctx.pr) == "table" and ctx.pr or session.pr or {}
  session.details = type(ctx.details) == "table" and ctx.details or session.details or {}
  session.comments_ctx = type(ctx.comments_ctx) == "table" and ctx.comments_ctx or nil
  session.origin = {
    origin_win = tonumber(ctx.origin_win),
    origin_buf = tonumber(ctx.origin_buf),
  }
  session.target_path = target.path
  session.target_kind = target.kind
  session.error = nil
  session.last_follow_node_id = nil

  return session, panel_opts(), nil
end

local function fetch_threads_async(session, callback, opts)
  opts = type(opts) == "table" and opts or {}
  callback = callback or function() end

  if opts.force_fetch ~= true and type(session.comments_ctx) == "table" and type(session.comments_ctx.threads) == "table" then
    vim.schedule(function()
      callback(session.comments_ctx.threads, nil)
    end)
    return
  end

  if type(pr_service.fetch_review_threads_with_pending_async) == "function" then
    pr_service.fetch_review_threads_with_pending_async(session.pr_number, {
      threads_first = 100,
      comments_first = 100,
    }, callback)
    return
  end

  if type(pr_service.fetch_review_threads_async) == "function" then
    pr_service.fetch_review_threads_async(session.pr_number, {
      threads_first = 100,
      comments_first = 100,
    }, callback)
    return
  end

  vim.schedule(function()
    local threads, err
    if type(pr_service.fetch_review_threads_with_pending) == "function" then
      threads, err = pr_service.fetch_review_threads_with_pending(session.pr_number, {
        threads_first = 100,
        comments_first = 100,
      })
    else
      threads, err = pr_service.fetch_review_threads(session.pr_number, {
        threads_first = 100,
        comments_first = 100,
      })
    end
    callback(threads, err)
  end)
end

local function current_session_is_stale(tabid, request_id)
  local session = sessions[tabid]
  return type(session) ~= "table" or session.request_id ~= request_id
end

local function source_visible(tabid)
  local neotree = neotree_integration()
  if not neotree or type(neotree.is_source_visible) ~= "function" then
    return false
  end
  return neotree.is_source_visible(SOURCE_NAME, tabid)
end

local function open_source_window(session, opts)
  local neotree = neotree_integration()
  if not neotree or type(neotree.open_source) ~= "function" then
    return false, "Neo-tree is unavailable"
  end

  local spec = panel_window_spec(opts)

  local opened = neotree.open_source(SOURCE_NAME, SOURCE_MODULE, {
    action = "show",
    toggle = false,
    position = spec.position,
    height = spec.height,
    selector = false,
  })
  if not opened then
    return false, "Unable to open diff comments tree"
  end

  if type(session) == "table" then
    session.window_position = spec.position
    session.window_height = spec.height
  end

  return true, nil
end

local function close_source_window(tabid, session)
  local neotree = neotree_integration()
  if not neotree or type(neotree.close_source) ~= "function" then
    return false
  end

  local position = type(session) == "table" and session.window_position or nil
  local closed = neotree.close_source(SOURCE_NAME, {
    position = position,
    tabid = tabid,
  })
  if type(session) == "table" then
    session.window_position = nil
    session.window_height = nil
  end
  return closed
end

local function start_async_load(session, mode, opts)
  opts = type(opts) == "table" and opts or {}
  session.request_id = session.request_id + 1
  local request_id = session.request_id
  local tabid = session.tabid

  fetch_threads_async(session, function(threads, err)
    if current_session_is_stale(tabid, request_id) then
      return
    end

    local live_session = sessions[tabid]
    if not live_session then
      return
    end

    if err and not threads then
      if mode == "probe" then
        return
      end

      live_session.status = "error"
      live_session.error = err
      live_session.nodes = error_nodes(live_session, err)
      render_session(live_session)
      return
    end

    live_session.status = "ready"
    live_session.error = nil
    if type(threads) == "table" then
      live_session.comments_ctx = vim.tbl_deep_extend("force", {}, type(live_session.comments_ctx) == "table" and live_session.comments_ctx or {}, {
        threads = threads,
      })
    end
    live_session.nodes = build_ready_nodes(live_session, threads)

    local has_comments = (live_session.comment_total or 0) > 0
    if mode == "probe" and not has_comments then
      return
    end

    if mode == "probe" and not source_visible(tabid) then
      local opened = open_source_window(live_session, panel_opts())
      if not opened then
        return
      end
    end

    render_session(live_session)
  end, opts)
end

local function no_context_nodes()
  local tabid = vim.api.nvim_get_current_tabpage()
  return {
    {
      id = string.format("ghpr-diff-comments:no-context:%d", tabid),
      name = "No active diff comments context. Open a gh-pr diff file first.",
      type = "message",
      extra = {
        kind = "message",
      },
    },
  }
end

local function should_auto_open_now(force_open, opts, session)
  if force_open then
    return true
  end
  if source_visible(session.tabid) then
    return true
  end
  return opts.auto_open == "always"
end

function M.available()
  local neotree = neotree_integration()
  if not neotree then
    return false
  end

  local ok = pcall(require, "neo-tree")
  return ok == true
end

function M.navigate(state, path)
  local tabid = vim.api.nvim_get_current_tabpage()
  local session = sessions[tabid]
  local renderer = renderer_module()
  if not renderer or type(renderer.show_nodes) ~= "function" then
    return
  end

  state.path = path or vim.fn.getcwd()
  clear_source_chrome(state)
  if type(session) ~= "table" then
    pcall(renderer.show_nodes, no_context_nodes(), state)
    clear_source_chrome(state)
    return
  end

  register_state(session, state)
end

function M.sync_for_diff(ctx)
  if not M.available() then
    return nil, "Neo-tree is unavailable"
  end

  ctx = type(ctx) == "table" and ctx or {}
  local session, opts, err = ensure_session(ctx)
  if err then
    return nil, err
  end
  if not opts.enabled then
    M.close_current_tab()
    return false, nil
  end

  if source_visible(session.tabid) and not source_position_matches(session, opts) then
    close_source_window(session.tabid, session)
  end

  if opts.auto_open == "never" and not source_visible(session.tabid) then
    return false, nil
  end

  if should_auto_open_now(false, opts, session) then
    session.status = "loading"
    session.thread_total = 0
    session.comment_total = 0
    session.nodes = loading_nodes(session)

    if not source_visible(session.tabid) then
      local opened, open_err = open_source_window(session, opts)
      if not opened then
        return nil, open_err
      end
    end

    render_session(session)
    start_async_load(session, "open")
    return true, nil
  end

  start_async_load(session, "probe")
  return false, nil
end

function M.toggle(ctx)
  if not M.available() then
    return nil, "Neo-tree is unavailable"
  end

  local tabid = vim.api.nvim_get_current_tabpage()
  if source_visible(tabid) then
    M.close_current_tab()
    return true, nil
  end

  ctx = type(ctx) == "table" and ctx or {}
  local session, opts, err = ensure_session(ctx)
  if err then
    return nil, err
  end
  if not opts.enabled then
    return nil, "Diff comments panel is disabled by config"
  end

  session.status = "loading"
  session.thread_total = 0
  session.comment_total = 0
  session.nodes = loading_nodes(session)

  local opened, open_err = open_source_window(session, opts)
  if not opened then
    return nil, open_err
  end

  render_session(session)
  start_async_load(session, "open")
  return true, nil
end

function M.open_target(target, opts)
  opts = type(opts) == "table" and opts or {}
  if type(target) ~= "table" then
    return false
  end

  local tabid = vim.api.nvim_get_current_tabpage()
  local session = sessions[tabid]
  if type(session) ~= "table" then
    return false
  end

  local actions = actions_module()
  if not actions then
    return false
  end
  if type(actions.set_active_pr) == "function" then
    actions.set_active_pr(session.pr, session.details)
  end

  local destination, _, move_err, source_win = move_to_target_window(session, target)
  if not destination then
    if type(move_err) == "string" and move_err ~= "" then
      vim.notify(move_err, vim.log.levels.WARN)
    end
    return false
  end

  if opts.open_popup == true then
    local ok, popup_err = open_target_popup(target, opts.popup_mode, opts.focus_thread_popup, destination)
    if not ok and popup_err ~= "thread popup disabled by config" and popup_err ~= "thread has no comments" then
      vim.notify("Unable to open thread popup: " .. tostring(popup_err), vim.log.levels.WARN)
    end
  end

  if opts.keep_source_focus == true and valid_win(source_win) then
    pcall(vim.api.nvim_set_current_win, source_win)
  end

  return true
end

function M.refresh_current_tab(opts)
  opts = type(opts) == "table" and opts or {}
  local tabid = vim.api.nvim_get_current_tabpage()
  local session = sessions[tabid]
  if type(session) ~= "table" then
    return false
  end

  session.status = "loading"
  session.thread_total = 0
  session.comment_total = 0
  session.nodes = loading_nodes(session)
  render_session(session)
  start_async_load(session, "open", {
    force_fetch = opts.force_fetch == true,
  })
  return true
end

function M.is_open_current_tab()
  return source_visible(vim.api.nvim_get_current_tabpage())
end

function M.close_current_tab(opts)
  opts = type(opts) == "table" and opts or {}
  if opts.respect_close_with_dq == true and panel_opts().close_with_dq == false then
    return false
  end

  local tabid = vim.api.nvim_get_current_tabpage()
  local closed = close_source_window(tabid, sessions[tabid])
  sessions[tabid] = nil
  return closed
end

function M.close_all()
  for tabid, session in pairs(sessions) do
    close_source_window(tabid, session)
    sessions[tabid] = nil
  end
end

registry.register(SOURCE_NAME, M)

return M
