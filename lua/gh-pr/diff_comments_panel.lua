local config = require("gh-pr.config")
local diff_shortcuts = require("gh-pr.diff_shortcuts")
local pr_service = require("gh-pr.pr_service")

local M = {}

local sessions = {}
local pending_requests = {}
local request_counters = {}

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
  local n = tonumber(value)
  if not n then
    return fallback
  end
  n = math.floor(n)
  if n < 1 then
    return fallback
  end
  return n
end

local function first_pos(...)
  for i = 1, select("#", ...) do
    local value = select(i, ...)
    local n = tonumber(value)
    if n and n > 0 then
      return math.floor(n)
    end
  end
  return nil
end

local function side_from_hint(value, head_line, base_line)
  local v = type(value) == "string" and value:lower() or ""
  if v == "left" or v == "base" then
    return "base"
  end
  if v == "right" or v == "head" then
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

local function panel_opts()
  local diff_view = (config.get() or {}).diff_view or {}
  local src = type(diff_view.comments_panel) == "table" and diff_view.comments_panel or {}

  local auto_open = type(src.auto_open) == "string" and src.auto_open or "if_comments"
  if auto_open ~= "never" and auto_open ~= "if_comments" and auto_open ~= "always" then
    auto_open = "if_comments"
  end

  local min_h = int(src.min_height, 8)
  local max_h = int(src.max_height, 18)
  if max_h < min_h then
    max_h = min_h
  end

  local ratio = tonumber(src.height_ratio)
  if type(ratio) ~= "number" or ratio < 0.1 or ratio > 0.8 then
    ratio = 0.28
  end

  return {
    enabled = src.enabled ~= false,
    auto_open = auto_open,
    height_ratio = ratio,
    min_height = min_h,
    max_height = max_h,
    follow_cursor = src.follow_cursor ~= false,
    show_resolved = src.show_resolved ~= false,
    show_outdated = src.show_outdated ~= false,
    close_with_dq = src.close_with_dq ~= false,
  }
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

local function request_token(tabid)
  request_counters[tabid] = (request_counters[tabid] or 0) + 1
  return request_counters[tabid]
end

local function clear_pending_request(tabid)
  pending_requests[tabid] = nil
end

local function close_session(tabid)
  clear_pending_request(tabid)
  local session = sessions[tabid]
  if not session then
    return false
  end
  sessions[tabid] = nil
  if valid_win(session.winid) then
    pcall(vim.api.nvim_win_close, session.winid, true)
  end
  if valid_buf(session.bufnr) then
    pcall(vim.api.nvim_buf_delete, session.bufnr, { force = true })
  end
  return true
end

local function get_session(tabid)
  local session = sessions[tabid]
  if not session then
    return nil
  end
  if not valid_buf(session.bufnr) or not valid_win(session.winid) then
    close_session(tabid)
    return nil
  end
  return session
end

local function file_for_path(details, path)
  local target = normalize_path(path)
  for _, file in ipairs(type(details.files) == "table" and details.files or {}) do
    for _, candidate in ipairs({ file.path, file.filename, file.previousFilename, file.previous_filename }) do
      if normalize_path(candidate) == target then
        return file
      end
    end
  end
  return { path = path, filename = path }
end

local function preview_text(body)
  local preview = vim.trim((tostring(body or ""):match("([^\r\n]+)") or ""))
  if preview == "" then
    preview = "(empty)"
  end
  if #preview > 110 then
    preview = preview:sub(1, 107) .. "..."
  end
  return preview
end

local function primary_line(target)
  if type(target) ~= "table" then
    return nil
  end
  if target.side == "base" then
    return first_pos(target.original_line, target.line)
  end
  return first_pos(target.line, target.original_line)
end

local function format_target_label(target)
  local side = type(target) == "table" and target.side or "head"
  local line = primary_line(target)
  if not line then
    line = "?"
  end

  if side == "base" then
    return string.format("[base L%s]", tostring(line))
  end
  if side == "unified" then
    return string.format("[unified L%s]", tostring(line))
  end
  return string.format("[head L%s]", tostring(line))
end

local function build_comment_model(raw_threads, opts, pr_number, target_path, target_kind)
  local normalized_target = normalize_path(target_path)
  local model = {
    path = normalized_target,
    target_kind = target_kind,
    entries = {},
    thread_total = 0,
    comment_total = 0,
  }

  if normalized_target == "" then
    return model
  end

  for i, thread in ipairs(type(raw_threads) == "table" and raw_threads or {}) do
    local is_resolved = thread.isResolved == true or thread.is_resolved == true
    local is_outdated = thread.isOutdated == true or thread.is_outdated == true
    local thread_path = normalize_path(thread.path)

    if thread_path == normalized_target and (opts.show_resolved or not is_resolved) and (opts.show_outdated or not is_outdated) then
      local thread_comments = {}
      for j, comment in ipairs(type(thread.comments) == "table" and thread.comments or {}) do
        local head_line = first_pos(thread.startLine, thread.start_line, comment.line, thread.line)
        local base_line = first_pos(
          thread.originalStartLine,
          thread.original_start_line,
          comment.originalLine,
          comment.original_line,
          thread.originalLine,
          thread.original_line
        )
        local side = side_from_hint(comment.diffSide or comment.diff_side or thread.diffSide or thread.diff_side, head_line, base_line)
        if target_kind == "unified" then
          side = "unified"
        end

        local target = {
          path = normalized_target,
          side = side,
          line = head_line or base_line,
          original_line = base_line or head_line,
          thread_id = thread.id or ("thread-" .. tostring(i)),
          selected_comment_id = comment.id or tostring(j),
          thread_is_resolved = is_resolved,
          thread_is_outdated = is_outdated,
          pr_number = pr_number,
        }

        thread_comments[#thread_comments + 1] = {
          id = comment.id or tostring(j),
          database_id = tonumber(comment.databaseId) or tonumber(comment.database_id),
          author = (type(comment.author) == "table" and comment.author.login) or comment.author or "unknown",
          body = comment.body or "",
          created_at = comment.createdAt or comment.created_at or "",
          target = target,
          thread_status = is_resolved and "RESOLVED" or (is_outdated and "OUTDATED" or "OPEN"),
          order = j,
        }
      end

      if #thread_comments > 0 then
        model.thread_total = model.thread_total + 1
        model.comment_total = model.comment_total + #thread_comments
        vim.list_extend(model.entries, thread_comments)
      end
    end
  end

  table.sort(model.entries, function(a, b)
    local a_line = primary_line(a.target) or math.huge
    local b_line = primary_line(b.target) or math.huge
    if a_line ~= b_line then
      return a_line < b_line
    end

    local a_side = type(a.target.side) == "string" and a.target.side or ""
    local b_side = type(b.target.side) == "string" and b.target.side or ""
    if a_side ~= b_side then
      return a_side < b_side
    end

    local a_date = type(a.created_at) == "string" and a.created_at or ""
    local b_date = type(b.created_at) == "string" and b.created_at or ""
    if a_date ~= b_date then
      return a_date < b_date
    end

    return (a.order or 0) < (b.order or 0)
  end)

  return model
end

local function apply_render(session, lines, actions)
  if not valid_buf(session.bufnr) then
    return
  end
  session.actions = actions or {}
  vim.bo[session.bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(session.bufnr, 0, -1, false, lines)
  vim.bo[session.bufnr].modifiable = false
  pcall(vim.api.nvim_set_option_value, "modified", false, { buf = session.bufnr })
end

local function header_lines(session)
  local target_path = type(session.target_path) == "string" and session.target_path or ""
  if target_path == "" then
    target_path = "(unknown file)"
  end

  return {
    string.format("PR #%d comments | %s", session.pr_number, target_path),
    "Enter: open location | q: close panel",
    "",
  }
end

local function render_loading(session)
  local lines = header_lines(session)
  lines[#lines + 1] = string.format("Loading comments for %s...", session.target_path ~= "" and session.target_path or "current file")
  apply_render(session, lines, {})
end

local function render_error(session, err)
  local lines = header_lines(session)
  lines[#lines + 1] = "Unable to load comments for this file."
  if type(err) == "string" and err ~= "" then
    lines[#lines + 1] = err
  end
  apply_render(session, lines, {})
end

local function render_empty(session)
  local lines = header_lines(session)
  lines[#lines + 1] = "No comments for this file."
  apply_render(session, lines, {})
end

local function render_ready(session, model)
  local lines = {
    string.format(
      "PR #%d comments | %s | threads: %d | comments: %d",
      session.pr_number,
      model.path ~= "" and model.path or "(unknown file)",
      model.thread_total,
      model.comment_total
    ),
    "Enter: open location | q: close panel",
    "",
  }
  local actions = {}

  if #model.entries == 0 then
    lines[#lines + 1] = "No comments for this file."
  else
    for _, entry in ipairs(model.entries) do
      lines[#lines + 1] = string.format(
        "%s @%s [%s] %s",
        format_target_label(entry.target),
        entry.author,
        entry.thread_status,
        preview_text(entry.body)
      )
      actions[#lines] = { target = entry.target }
    end
  end

  apply_render(session, lines, actions)
end

local function jump(session, action, keep_panel_focus)
  if type(action) ~= "table" or type(action.target) ~= "table" then
    return false
  end

  local target = action.target
  local tabid = session.tabid
  local panel_win = session.winid
  local destination, destination_kind
  for _, item in ipairs(resolve_candidate_diff_windows(tabid, session.pr_number)) do
    if normalize_path(item.path) == normalize_path(target.path) or item.path == "" then
      if item.kind == "unified"
          or (target.side == "base" and item.kind == "base")
          or ((target.side == "head" or target.side == "unified") and item.kind == "head") then
        destination, destination_kind = item.winid, item.kind
        break
      end
      if not destination then
        destination, destination_kind = item.winid, item.kind
      end
    end
  end

  if not valid_win(destination) then
    local ok_actions, actions = pcall(require, "gh-pr.actions")
    if not ok_actions or type(actions.open_diff) ~= "function" then
      return false
    end
    if type(actions.set_active_pr) == "function" then
      actions.set_active_pr(session.pr, session.details)
    end
    actions.open_diff(file_for_path(session.details, target.path), { new_tab = false })
    for _, item in ipairs(resolve_candidate_diff_windows(tabid, session.pr_number)) do
      if normalize_path(item.path) == normalize_path(target.path) or item.path == "" then
        destination, destination_kind = item.winid, item.kind
        if destination_kind == "unified"
            or (target.side == "base" and destination_kind == "base")
            or ((target.side == "head" or target.side == "unified") and destination_kind == "head") then
          break
        end
      end
    end
  end

  if not valid_win(destination) then
    return false
  end

  local line = destination_kind == "base" and first_pos(target.original_line, target.line, 1)
    or first_pos(target.line, target.original_line, 1)
  line = int(line, 1)
  local max_line = vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(destination))
  line = math.max(1, math.min(max_line, line))
  pcall(vim.api.nvim_set_current_win, destination)
  pcall(vim.api.nvim_win_set_cursor, destination, { line, 0 })

  if keep_panel_focus and valid_win(panel_win) then
    pcall(vim.api.nvim_set_current_win, panel_win)
  end
  return true
end

local function apply_keymaps(session)
  if session.keymaps then
    return
  end
  session.keymaps = true

  local configured = ((config.get() or {}).diff_view or {}).shortcuts or {}
  configured = diff_shortcuts.resolve(configured)
  configured = diff_shortcuts.expand_localleader(configured)
  local close_all = type(configured.close_all_open_review) == "string" and configured.close_all_open_review or ",dQ"
  local toggle = type(configured.toggle_comments_panel) == "string" and configured.toggle_comments_panel or ",dc"

  local function map(lhs, rhs, desc)
    if type(lhs) ~= "string" or lhs == "" then
      return
    end
    vim.keymap.set("n", lhs, rhs, { buffer = session.bufnr, silent = true, nowait = true, desc = desc })
  end

  map("<CR>", function()
    if not valid_win(session.winid) then
      return
    end
    local line = vim.api.nvim_win_get_cursor(session.winid)[1]
    jump(session, session.actions[line], false)
  end, "GH PR diff comments: open target")
  map("q", function()
    M.close_current_tab()
  end, "GH PR diff comments: close panel")
  map(toggle, function()
    M.close_current_tab()
  end, "GH PR diff comments: toggle panel")
  map(close_all, function()
    local ok_actions, actions = pcall(require, "gh-pr.actions")
    if ok_actions and type(actions.close_all_and_open_review) == "function" then
      actions.close_all_and_open_review()
    end
  end, "GH PR diff comments: close all/open review")

  vim.api.nvim_create_autocmd("CursorMoved", {
    buffer = session.bufnr,
    callback = function()
      if not panel_opts().follow_cursor or session.suspend_follow then
        return
      end
      if not valid_win(session.winid) or vim.api.nvim_get_current_win() ~= session.winid then
        return
      end
      local line = vim.api.nvim_win_get_cursor(session.winid)[1]
      if line == session.last_line then
        return
      end
      session.last_line = line
      session.suspend_follow = true
      jump(session, session.actions[line], true)
      session.suspend_follow = false
    end,
  })
end

local function ensure_window(session, opts)
  if valid_win(session.winid) then
    local lines = vim.api.nvim_get_option_value("lines", {}) or 40
    local height = math.min(opts.max_height, math.max(opts.min_height, math.floor(lines * opts.height_ratio)))
    if vim.api.nvim_win_get_buf(session.winid) ~= session.bufnr then
      vim.api.nvim_win_set_buf(session.winid, session.bufnr)
    end
    pcall(vim.api.nvim_win_set_height, session.winid, height)
    pcall(vim.api.nvim_set_option_value, "winfixheight", true, { win = session.winid })
    return true
  end

  local wins = resolve_candidate_diff_windows(session.tabid, session.pr_number, session.origin)
  if #wins == 0 then
    return nil, string.format("No diff windows available in current tab for PR #%d", tonumber(session.pr_number) or 0)
  end

  local origin = vim.api.nvim_get_current_win()
  pcall(vim.api.nvim_set_current_win, wins[1].winid)
  vim.cmd("botright split")
  session.winid = vim.api.nvim_get_current_win()
  vim.cmd("wincmd J")
  vim.api.nvim_win_set_buf(session.winid, session.bufnr)
  if valid_win(origin) and origin ~= session.winid then
    pcall(vim.api.nvim_set_current_win, origin)
  end
  return ensure_window(session, opts)
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

  return nil, "No active diff file found for diff comments panel"
end

local function create_session(tabid, pr_number, ctx)
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].filetype = "gh_pr_diff_comments"

  local session = {
    tabid = tabid,
    winid = nil,
    origin = {
      origin_win = tonumber(ctx.origin_win),
      origin_buf = tonumber(ctx.origin_buf),
    },
    bufnr = bufnr,
    pr_number = pr_number,
    pr = type(ctx.pr) == "table" and ctx.pr or {},
    details = type(ctx.details) == "table" and ctx.details or {},
    comments_ctx = type(ctx.comments_ctx) == "table" and ctx.comments_ctx or nil,
    actions = {},
    suspend_follow = false,
    last_line = nil,
    target_path = normalize_path(ctx.file_path),
    target_kind = type(ctx.file_kind) == "string" and ctx.file_kind or "head",
  }
  sessions[tabid] = session
  apply_keymaps(session)
  return session
end

local function prepare_session(ctx, force_open)
  local pr_number = tonumber(ctx.pr_number or (ctx.pr and ctx.pr.number) or vim.b.gh_pr_number)
  if not pr_number then
    return nil, nil, "Missing PR number for diff comments panel"
  end

  local opts = panel_opts()
  if not opts.enabled then
    M.close_current_tab()
    if force_open then
      return nil, nil, "Diff comments panel is disabled by config"
    end
    return false, opts, nil
  end

  local target, target_err = resolve_target(ctx, pr_number)
  if not target then
    return nil, nil, target_err
  end

  local tabid = vim.api.nvim_get_current_tabpage()
  local session = get_session(tabid)
  if session and session.pr_number ~= pr_number then
    close_session(tabid)
    session = nil
  end

  ctx.file_path = target.path
  ctx.file_kind = target.kind

  if opts.auto_open == "never" and not force_open and not session then
    return false, opts, nil
  end

  return {
    tabid = tabid,
    pr_number = pr_number,
    session = session,
    target = target,
  }, opts, nil
end

local function ensure_session_window(runtime, opts, ctx)
  local session = runtime.session
  if not session then
    session = create_session(runtime.tabid, runtime.pr_number, ctx)
    runtime.session = session
  else
    session.pr = type(ctx.pr) == "table" and ctx.pr or session.pr
    session.details = type(ctx.details) == "table" and ctx.details or session.details
    session.comments_ctx = type(ctx.comments_ctx) == "table" and ctx.comments_ctx or session.comments_ctx
    session.origin = {
      origin_win = tonumber(ctx.origin_win),
      origin_buf = tonumber(ctx.origin_buf),
    }
  end

  session.target_path = runtime.target.path
  session.target_kind = runtime.target.kind

  local ok_window, window_err = ensure_window(session, opts)
  if not ok_window then
    close_session(runtime.tabid)
    return nil, window_err or "Unable to open diff comments panel window"
  end

  return session, nil
end

local function fetch_threads_async(pr_number, comments_ctx, callback, opts)
  opts = type(opts) == "table" and opts or {}
  callback = callback or function() end

  if opts.force_fetch ~= true and type(comments_ctx) == "table" and type(comments_ctx.threads) == "table" then
    vim.schedule(function()
      callback(comments_ctx.threads, nil)
    end)
    return
  end

  if type(pr_service.fetch_review_threads_with_pending_async) == "function" then
    pr_service.fetch_review_threads_with_pending_async(pr_number, {
      threads_first = 100,
      comments_first = 100,
    }, callback)
    return
  end

  if type(pr_service.fetch_review_threads_async) == "function" then
    pr_service.fetch_review_threads_async(pr_number, {
      threads_first = 100,
      comments_first = 100,
    }, callback)
    return
  end

  vim.schedule(function()
    local threads, err
    if type(pr_service.fetch_review_threads_with_pending) == "function" then
      threads, err = pr_service.fetch_review_threads_with_pending(pr_number, {
        threads_first = 100,
        comments_first = 100,
      })
    else
      threads, err = pr_service.fetch_review_threads(pr_number, {
        threads_first = 100,
        comments_first = 100,
      })
    end
    callback(threads, err)
  end)
end

local function request_still_current(tabid, request_id, pr_number, target_path)
  local pending = pending_requests[tabid]
  return type(pending) == "table"
    and pending.id == request_id
    and pending.pr_number == pr_number
    and pending.target_path == target_path
end

local function start_async_load(runtime, opts, ctx, mode, request_opts)
  request_opts = type(request_opts) == "table" and request_opts or {}
  local target_path = runtime.target.path
  local request_id = request_token(runtime.tabid)
  pending_requests[runtime.tabid] = {
    id = request_id,
    pr_number = runtime.pr_number,
    target_path = target_path,
  }

  fetch_threads_async(runtime.pr_number, ctx.comments_ctx, function(threads, err)
    if not request_still_current(runtime.tabid, request_id, runtime.pr_number, target_path) then
      return
    end

    local live_session = get_session(runtime.tabid)
    local model
    if threads then
      if live_session then
        live_session.comments_ctx = vim.tbl_deep_extend("force", {}, type(live_session.comments_ctx) == "table" and live_session.comments_ctx or {}, {
          threads = threads,
        })
      end
      model = build_comment_model(threads, opts, runtime.pr_number, target_path, runtime.target.kind)
    end

    clear_pending_request(runtime.tabid)

    if err and not threads then
      if mode == "probe" then
        return
      end
      if live_session then
        render_error(live_session, err)
      end
      return
    end

    if mode == "probe" and (not model or model.comment_total == 0) then
      return
    end

    if not live_session then
      local ensured_session, ensure_err = ensure_session_window(runtime, opts, ctx)
      if not ensured_session then
        return nil, ensure_err
      end
      live_session = ensured_session
    else
      live_session.target_path = target_path
      live_session.target_kind = runtime.target.kind
    end

    if not model or model.comment_total == 0 then
      render_empty(live_session)
      return
    end

    render_ready(live_session, model)
  end, request_opts)
end

local function open_or_refresh(ctx, force_open)
  local normalized_ctx = type(ctx) == "table" and ctx or {}
  local runtime, opts, prep_err = prepare_session(normalized_ctx, force_open)
  if prep_err then
    return nil, prep_err
  end
  if runtime == false then
    return false, nil
  end

  local session = runtime.session
  local should_open_now = force_open or session ~= nil or opts.auto_open == "always"
  if should_open_now then
    session, prep_err = ensure_session_window(runtime, opts, normalized_ctx)
    if not session then
      return nil, prep_err
    end
    render_loading(session)
    start_async_load(runtime, opts, normalized_ctx, "open")
    return true, nil
  end

  start_async_load(runtime, opts, normalized_ctx, "probe")
  return false, nil
end

local function tree_backend()
  local ok, source = pcall(require, "gh-pr.neotree.diff_comments_source")
  if not ok or type(source) ~= "table" or type(source.available) ~= "function" then
    return nil
  end

  if source.available() ~= true then
    return nil
  end

  return source
end

function M.sync_for_diff(ctx)
  local tree = tree_backend()
  if tree and type(tree.sync_for_diff) == "function" then
    return tree.sync_for_diff(ctx)
  end
  return open_or_refresh(type(ctx) == "table" and ctx or {}, false)
end

function M.toggle(ctx)
  local tree = tree_backend()
  if tree and type(tree.toggle) == "function" then
    return tree.toggle(ctx)
  end
  local tabid = vim.api.nvim_get_current_tabpage()
  if get_session(tabid) then
    close_session(tabid)
    return true, nil
  end
  return open_or_refresh(type(ctx) == "table" and ctx or {}, true)
end

function M.is_open_current_tab()
  local tree = tree_backend()
  if tree and type(tree.is_open_current_tab) == "function" and tree.is_open_current_tab() then
    return true
  end
  return get_session(vim.api.nvim_get_current_tabpage()) ~= nil
end

function M.refresh_current_tab(opts)
  opts = type(opts) == "table" and opts or {}
  local tree = tree_backend()
  if tree and type(tree.refresh_current_tab) == "function" then
    return tree.refresh_current_tab(opts)
  end

  local tabid = vim.api.nvim_get_current_tabpage()
  local session = get_session(tabid)
  if not session then
    return false
  end

  local runtime = {
    tabid = tabid,
    pr_number = session.pr_number,
    session = session,
    target = {
      path = session.target_path,
      kind = session.target_kind,
    },
  }
  local opts_panel = panel_opts()
  local ctx = {
    pr_number = session.pr_number,
    pr = session.pr,
    details = session.details,
    comments_ctx = opts.force_fetch == true and nil or session.comments_ctx,
    origin_win = session.origin and session.origin.origin_win or nil,
    origin_buf = session.origin and session.origin.origin_buf or nil,
    file_path = session.target_path,
    file_kind = session.target_kind,
  }

  render_loading(session)
  start_async_load(runtime, opts_panel, ctx, "open", {
    force_fetch = opts.force_fetch == true,
  })
  return true
end

function M.close_current_tab(opts)
  opts = type(opts) == "table" and opts or {}
  local tree = tree_backend()
  if tree and type(tree.close_current_tab) == "function" then
    local closed = tree.close_current_tab(opts)
    if closed == true then
      return true
    end
  end
  if opts.respect_close_with_dq == true and panel_opts().close_with_dq == false then
    return false
  end
  return close_session(vim.api.nvim_get_current_tabpage())
end

function M.close_all()
  local tree = tree_backend()
  if tree and type(tree.close_all) == "function" then
    tree.close_all()
  end
  for _, tabid in ipairs(vim.tbl_keys(sessions)) do
    close_session(tabid)
  end
end

return M
