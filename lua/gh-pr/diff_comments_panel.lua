local config = require("gh-pr.config")
local diff_shortcuts = require("gh-pr.diff_shortcuts")
local pr_service = require("gh-pr.pr_service")

local M = {}

local sessions = {}

local function valid_buf(bufnr)
  return type(bufnr) == "number" and bufnr > 0 and vim.api.nvim_buf_is_valid(bufnr)
end

local function valid_win(winid)
  return type(winid) == "number" and winid > 0 and vim.api.nvim_win_is_valid(winid)
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
    local n = tonumber(select(i, ...))
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

local function diff_windows(tabid, pr_number)
  local out = {}
  for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(tabid)) do
    if valid_win(winid) then
      local bufnr = vim.api.nvim_win_get_buf(winid)
      local kind = vim.b[bufnr].gh_pr_file_kind
      if kind == "base" or kind == "head" or kind == "unified" then
        local number = tonumber(vim.b[bufnr].gh_pr_number)
        if not pr_number or number == pr_number then
          out[#out + 1] = {
            winid = winid,
            bufnr = bufnr,
            kind = kind,
            path = normalize_path(vim.b[bufnr].gh_pr_file_path or vim.b[bufnr].gh_pr_path),
          }
        end
      end
    end
  end
  return out
end

local function close_session(tabid)
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

local function parse_threads(raw_threads, opts, pr_number)
  local model = { files = {}, thread_total = 0, comment_total = 0 }
  local file_buckets = {}

  for i, thread in ipairs(type(raw_threads) == "table" and raw_threads or {}) do
    local is_resolved = thread.isResolved == true or thread.is_resolved == true
    local is_outdated = thread.isOutdated == true or thread.is_outdated == true
    if (opts.show_resolved or not is_resolved) and (opts.show_outdated or not is_outdated) then
      local path = normalize_path(thread.path)
      if path == "" then
        path = "(no file)"
      end

      local comments = {}
      for j, comment in ipairs(type(thread.comments) == "table" and thread.comments or {}) do
        local head_line = first_pos(comment.line, thread.line, thread.startLine, thread.start_line)
        local base_line = first_pos(comment.originalLine, comment.original_line, thread.originalLine, thread.originalStartLine, thread.original_line)
        local side = side_from_hint(comment.diffSide or comment.diff_side or thread.diffSide or thread.diff_side, head_line, base_line)
        local target = {
          path = path,
          side = side,
          line = head_line or base_line,
          original_line = base_line or head_line,
          thread_id = thread.id or ("thread-" .. tostring(i)),
          selected_comment_id = comment.id or tostring(j),
          thread_is_resolved = is_resolved,
          thread_is_outdated = is_outdated,
          pr_number = pr_number,
        }

        comments[#comments + 1] = {
          id = comment.id or tostring(j),
          author = (type(comment.author) == "table" and comment.author.login) or comment.author or "unknown",
          body = comment.body or "",
          created_at = comment.createdAt or comment.created_at or "",
          target = target,
        }
      end

      if #comments > 0 then
        model.thread_total = model.thread_total + 1
        model.comment_total = model.comment_total + #comments
        file_buckets[path] = file_buckets[path] or { path = path, threads = {} }
        file_buckets[path].threads[#file_buckets[path].threads + 1] = {
          id = thread.id or ("thread-" .. tostring(i)),
          is_resolved = is_resolved,
          is_outdated = is_outdated,
          target = vim.deepcopy(comments[1].target),
          comments = comments,
        }
      end
    end
  end

  local paths = vim.tbl_keys(file_buckets)
  table.sort(paths)
  for _, path in ipairs(paths) do
    model.files[#model.files + 1] = file_buckets[path]
  end
  return model
end

local function render(session, model)
  local lines = {
    string.format("PR #%d comments | threads: %d | comments: %d", session.pr_number, model.thread_total, model.comment_total),
    "Enter: open location | q: close panel",
    "",
  }
  local actions = {}

  if vim.tbl_isempty(model.files) then
    lines[#lines + 1] = "No file comments found for this PR."
  else
    for _, bucket in ipairs(model.files) do
      lines[#lines + 1] = string.format("FILE %s", bucket.path)
      for _, thread in ipairs(bucket.threads) do
        local status = thread.is_resolved and "RESOLVED" or (thread.is_outdated and "OUTDATED" or "OPEN")
        lines[#lines + 1] = string.format("  THREAD [%s]", status)
        if bucket.path ~= "(no file)" and (thread.target.line or thread.target.original_line) then
          actions[#lines] = { target = thread.target }
        end
        for _, comment in ipairs(thread.comments) do
          local preview = vim.trim((comment.body:match("([^\r\n]+)") or ""))
          if preview == "" then
            preview = "(empty)"
          end
          if #preview > 100 then
            preview = preview:sub(1, 97) .. "..."
          end
          lines[#lines + 1] = string.format("    @%s %s", comment.author, preview)
          if bucket.path ~= "(no file)" and (comment.target.line or comment.target.original_line) then
            actions[#lines] = { target = comment.target }
          end
        end
      end
      lines[#lines + 1] = ""
    end
  end

  session.actions = actions
  vim.bo[session.bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(session.bufnr, 0, -1, false, lines)
  vim.bo[session.bufnr].modifiable = false
end

local function jump(session, action, keep_panel_focus)
  if type(action) ~= "table" or type(action.target) ~= "table" then
    return false
  end

  local target = action.target
  local tabid = session.tabid
  local panel_win = session.winid
  local destination, destination_kind
  for _, item in ipairs(diff_windows(tabid, session.pr_number)) do
    if normalize_path(item.path) == normalize_path(target.path) or item.path == "" or target.path == "(no file)" then
      if item.kind == "unified" or (target.side == "base" and item.kind == "base") or (target.side ~= "base" and item.kind == "head") then
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
    for _, item in ipairs(diff_windows(tabid, session.pr_number)) do
      if normalize_path(item.path) == normalize_path(target.path) or item.path == "" then
        destination, destination_kind = item.winid, item.kind
        if destination_kind == "unified" or (target.side == "base" and destination_kind == "base") or (target.side ~= "base" and destination_kind == "head") then
          break
        end
      end
    end
  end

  if not valid_win(destination) then
    return false
  end

  local line = destination_kind == "base" and first_pos(target.original_line, target.line, 1) or first_pos(target.line, target.original_line, 1)
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
      if vim.api.nvim_get_current_win() ~= session.winid then
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

local function fetch_threads(pr_number, comments_ctx)
  if type(comments_ctx) == "table" and type(comments_ctx.threads) == "table" then
    return comments_ctx.threads, nil
  end
  return pr_service.fetch_review_threads(pr_number, {
    threads_first = 100,
    comments_first = 100,
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

  local wins = diff_windows(session.tabid, session.pr_number)
  if #wins == 0 then
    return false
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

local function open_or_refresh(ctx, force_open)
  local pr_number = tonumber(ctx.pr_number or (ctx.pr and ctx.pr.number) or vim.b.gh_pr_number)
  if not pr_number then
    return false
  end

  local opts = panel_opts()
  if not opts.enabled then
    M.close_current_tab()
    return false
  end

  local tabid = vim.api.nvim_get_current_tabpage()
  local session = get_session(tabid)
  if session and session.pr_number ~= pr_number then
    close_session(tabid)
    session = nil
  end

  if opts.auto_open == "never" and not force_open and not session then
    return false
  end

  local threads, err = fetch_threads(pr_number, ctx.comments_ctx)
  if not threads then
    vim.notify("Unable to load review threads for diff comments panel: " .. tostring(err), vim.log.levels.WARN)
    return false
  end

  local model = parse_threads(threads, opts, pr_number)
  if opts.auto_open == "if_comments" and not force_open and model.comment_total == 0 then
    if session then
      close_session(tabid)
    end
    return false
  end
  if not session then
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.bo[bufnr].buftype = "nofile"
    vim.bo[bufnr].bufhidden = "wipe"
    vim.bo[bufnr].swapfile = false
    vim.bo[bufnr].filetype = "gh_pr_diff_comments"
    session = {
      tabid = tabid,
      winid = nil,
      bufnr = bufnr,
      pr_number = pr_number,
      pr = type(ctx.pr) == "table" and ctx.pr or {},
      details = type(ctx.details) == "table" and ctx.details or {},
      actions = {},
      suspend_follow = false,
      last_line = nil,
    }
    sessions[tabid] = session
    apply_keymaps(session)
  else
    session.pr = type(ctx.pr) == "table" and ctx.pr or session.pr
    session.details = type(ctx.details) == "table" and ctx.details or session.details
  end

  if not ensure_window(session, opts) then
    close_session(tabid)
    return false
  end

  render(session, model)
  return true
end

function M.sync_for_diff(ctx)
  open_or_refresh(type(ctx) == "table" and ctx or {}, false)
end

function M.toggle(ctx)
  local tabid = vim.api.nvim_get_current_tabpage()
  if get_session(tabid) then
    close_session(tabid)
    return false
  end
  return open_or_refresh(type(ctx) == "table" and ctx or {}, true)
end

function M.is_open_current_tab()
  return get_session(vim.api.nvim_get_current_tabpage()) ~= nil
end

function M.close_current_tab(opts)
  opts = type(opts) == "table" and opts or {}
  if opts.respect_close_with_dq == true and panel_opts().close_with_dq == false then
    return false
  end
  return close_session(vim.api.nvim_get_current_tabpage())
end

function M.close_all()
  for _, tabid in ipairs(vim.tbl_keys(sessions)) do
    close_session(tabid)
  end
end

return M
