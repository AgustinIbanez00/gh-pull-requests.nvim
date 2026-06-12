local config = require("gh-pr.config")
local pr_service = require("gh-pr.pr_service")
local registry = require("gh-pr.neotree.registry")
local thread_popup = require("gh-pr.thread_popup")
local diff_hunks = require("gh-pr.core.diff_hunks")

local M = {
  name = "gh_pr_diff_review",
  display_name = "GH Diff Review",
}

local SOURCE_NAME = "gh_pr_diff_review"
local SOURCE_MODULE = "gh-pr.neotree.diff_review_source_entry"

local sessions = {}
local state_by_buffer = {}

-- ── helpers ─────────────────────────────────────────────────────────────────

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
  if type(path) ~= "string" then return "" end
  return path:gsub("\\", "/")
end

local function int(value, fallback)
  local n = tonumber(value)
  if not n then return fallback end
  n = math.floor(n)
  if n < 1 then return fallback end
  return n
end

local function first_pos(...)
  for i = 1, select("#", ...) do
    local v = select(i, ...)
    v = tonumber(v)
    if v and v > 0 then return math.floor(v) end
  end
  return nil
end

local function safe_string(value, fallback)
  if type(value) == "string" and value ~= "" then return value end
  return fallback or ""
end

-- ── config ───────────────────────────────────────────────────────────────────

local function panel_opts()
  local diff_view = (config.get() or {}).diff_view or {}
  local src = type(diff_view.review_panel) == "table" and diff_view.review_panel
    or type(diff_view.comments_panel) == "table" and diff_view.comments_panel
    or {}

  local auto_open = type(src.auto_open) == "string" and src.auto_open or "if_content"
  if auto_open == "if_comments" then auto_open = "if_content" end
  if auto_open ~= "never" and auto_open ~= "if_content" and auto_open ~= "always" then
    auto_open = "if_content"
  end

  local position = type(src.position) == "string" and src.position:lower() or "bottom"
  if position ~= "bottom" and position ~= "right" then position = "bottom" end

  local min_height = int(src.min_height, 8)
  local max_height = int(src.max_height, 18)
  if max_height < min_height then max_height = min_height end

  local height_ratio = tonumber(src.height_ratio)
  if type(height_ratio) ~= "number" or height_ratio < 0.10 or height_ratio > 0.80 then
    height_ratio = 0.28
  end

  local sections = type(src.sections) == "table" and src.sections or {}
  local ah = type(src.active_hunk_highlight) == "table" and src.active_hunk_highlight or {}

  return {
    enabled = src.enabled ~= false,
    auto_open = auto_open,
    position = position,
    height_ratio = height_ratio,
    min_height = min_height,
    max_height = max_height,
    show_resolved = src.show_resolved ~= false,
    show_outdated = src.show_outdated ~= false,
    close_with_dq = src.close_with_dq ~= false,
    sections = {
      changes = sections.changes ~= false,
      comments = sections.comments ~= false,
    },
    active_hunk_highlight = {
      enabled = ah.enabled ~= false,
      debounce_ms = int(ah.debounce_ms, 80),
    },
  }
end

local function panel_window_spec(opts)
  opts = type(opts) == "table" and opts or panel_opts()
  local position = opts.position == "right" and "right" or "bottom"
  local spec = { position = position, height = nil }
  if position == "bottom" then
    local lines = vim.api.nvim_get_option_value("lines", {}) or 40
    spec.height = math.min(opts.max_height, math.max(opts.min_height, math.floor(lines * opts.height_ratio)))
  end
  return spec
end

-- ── diff-window helpers (ported from diff_changes_panel) ─────────────────────

local function current_diff_entry(winid, bufnr)
  if not valid_win(winid) then return nil end
  bufnr = valid_buf(bufnr) and bufnr or vim.api.nvim_win_get_buf(winid)
  if not valid_buf(bufnr) then return nil end
  local kind = vim.b[bufnr].gh_pr_file_kind
  if kind ~= "base" and kind ~= "head" and kind ~= "unified" then return nil end
  return {
    winid = winid,
    bufnr = bufnr,
    kind = kind,
    pr_number = tonumber(vim.b[bufnr].gh_pr_number),
    path = normalize_path(vim.b[bufnr].gh_pr_file_path or vim.b[bufnr].gh_pr_path),
    non_text = vim.b[bufnr].gh_pr_is_non_text == true or vim.b[bufnr].gh_pr_is_image == true,
  }
end

local function diff_windows(tabid, pr_number, path)
  local out = {}
  if not valid_tab(tabid) then return out end
  local normalized = normalize_path(path)
  for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(tabid)) do
    local entry = current_diff_entry(winid)
    if entry
      and (not pr_number or entry.pr_number == pr_number)
      and (normalized == "" or entry.path == "" or entry.path == normalized) then
      out[#out + 1] = entry
    end
  end
  return out
end

local function resolve_diff_target(ctx)
  ctx = type(ctx) == "table" and ctx or {}
  local origin_win = tonumber(ctx.origin_win)
  local origin_buf = tonumber(ctx.origin_buf)
  local origin = current_diff_entry(origin_win, origin_buf)
  if origin then return origin end

  local current = current_diff_entry(vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf())
  if current then return current end

  local path = normalize_path(ctx.file_path)
  local pr_number = tonumber(ctx.pr_number or (ctx.pr and ctx.pr.number) or vim.b.gh_pr_number)
  for _, entry in ipairs(diff_windows(vim.api.nvim_get_current_tabpage(), pr_number, path)) do
    return entry
  end

  if pr_number or path ~= "" then
    return {
      winid = origin_win,
      bufnr = origin_buf,
      kind = type(ctx.file_kind) == "string" and ctx.file_kind or "head",
      pr_number = pr_number,
      path = path,
      non_text = ctx.non_text == true,
    }
  end
  return nil
end

local function hunks_from_visible_buffers(tabid, pr_number, path)
  local windows = diff_windows(tabid, pr_number, path)
  local base_buf, head_buf, unified_buf, single_buf, file_mode
  for _, entry in ipairs(windows) do
    local mode = vim.b[entry.bufnr].gh_pr_file_mode
    if entry.kind == "base" then base_buf = entry.bufnr
    elseif entry.kind == "head" then head_buf = entry.bufnr
    elseif entry.kind == "unified" then unified_buf = entry.bufnr end
    if mode == "added_single" or mode == "removed_single" then
      single_buf = entry.bufnr
      file_mode = mode
    end
  end
  if valid_buf(unified_buf) then
    return diff_hunks.from_unified_line_map(vim.b[unified_buf].gh_pr_unified_line_map)
  end
  if valid_buf(single_buf) then return diff_hunks.from_single_buffer(single_buf, file_mode) end
  if valid_buf(base_buf) and valid_buf(head_buf) then return diff_hunks.from_buffers(base_buf, head_buf) end
  return {}
end

local function build_hunks(ctx, tabid, target)
  ctx = type(ctx) == "table" and ctx or {}
  if type(ctx.hunks) == "table" then return vim.deepcopy(ctx.hunks) end
  if type(ctx.open_result) == "table" then
    local h = diff_hunks.from_codediff_open_result(ctx.open_result)
    if #h > 0 then return h end
  end
  if type(ctx.diff_result) == "table" then
    local h = diff_hunks.from_virtual_result(ctx.diff_result)
    if #h > 0 then return h end
  end
  return hunks_from_visible_buffers(tabid, target and target.pr_number or nil, target and target.path or nil)
end

-- ── jump to hunk ─────────────────────────────────────────────────────────────

function M.jump_to_hunk(hunk, pr_number, path)
  if type(hunk) ~= "table" then return false end
  local tabid = vim.api.nvim_get_current_tabpage()
  local destination
  for _, entry in ipairs(diff_windows(tabid, pr_number, path)) do
    if hunk.target_side == "unified" and entry.kind == "unified" then
      destination = entry.winid; break
    elseif hunk.target_side == "base" and entry.kind == "base" then
      destination = entry.winid; break
    elseif hunk.target_side ~= "base" and entry.kind == "head" then
      destination = entry.winid; break
    elseif not destination then
      destination = entry.winid
    end
  end
  if not valid_win(destination) then return false end
  local bufnr = vim.api.nvim_win_get_buf(destination)
  local max_line = math.max(1, vim.api.nvim_buf_line_count(bufnr))
  local line = math.max(1, math.min(max_line, int(hunk.target_line, 1)))
  pcall(vim.api.nvim_set_current_win, destination)
  pcall(vim.api.nvim_win_set_cursor, destination, { line, 0 })
  return true
end

-- ── comment helpers (ported from diff_comments_source) ───────────────────────

local function side_from_hint(value, head_line, base_line)
  local normalized = type(value) == "string" and value:lower() or ""
  if normalized == "left" or normalized == "base" then return "base" end
  if normalized == "right" or normalized == "head" then return "head" end
  if head_line and not base_line then return "head" end
  if base_line and not head_line then return "base" end
  return "head"
end

local function body_preview(body)
  if type(body) ~= "string" or body == "" then return "(empty comment)" end
  local line = vim.trim((body:match("([^\r\n]+)") or ""))
  if line == "" then return "(empty comment)" end
  if #line > 90 then return line:sub(1, 87) .. "..." end
  return line
end

local function normalize_comment_time(created_at)
  if type(created_at) ~= "string" or created_at == "" then return "-" end
  return created_at:gsub("T", " "):gsub("Z", "")
end

local function sort_comments_by_time(comments)
  table.sort(comments, function(l, r)
    local lk = normalize_comment_time(l.created_at) .. ":" .. safe_string(l.id, "")
    local rk = normalize_comment_time(r.created_at) .. ":" .. safe_string(r.id, "")
    return lk < rk
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
    reaction_groups = vim.deepcopy(
      type(comment.reactionGroups) == "table" and comment.reactionGroups
      or (type(comment.reaction_groups) == "table" and comment.reaction_groups or {})
    ),
  }
end

local function normalize_thread_comments(thread)
  local comments = {}
  for i, c in ipairs(type(thread.comments) == "table" and thread.comments or {}) do
    comments[#comments + 1] = normalize_thread_comment(c, i)
  end
  sort_comments_by_time(comments)
  return comments
end

local function thread_status(thread)
  if thread.isResolved == true or thread.is_resolved == true then return "RESOLVED" end
  if thread.isOutdated == true or thread.is_outdated == true then return "OUTDATED" end
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
  if type(target) ~= "table" then return math.huge end
  if target.side == "base" then return first_pos(target.original_line, target.line) or math.huge end
  return first_pos(target.line, target.original_line) or math.huge
end

-- ── node builders ─────────────────────────────────────────────────────────────

local KIND_ICONS = { add = "[+]", modify = "[~]", delete = "[-]", change = "[Δ]" }
local KIND_HL = {
  add = "GhPrDiffReviewChangeAdd",
  modify = "GhPrDiffReviewChangeMod",
  delete = "GhPrDiffReviewChangeDel",
  change = "GhPrDiffReviewChangeMod",
}

local function message_node(session, suffix, message)
  return {
    id = string.format("ghpr-diff-review:%d:%s", tonumber(session.pr_number) or 0, suffix),
    name = message,
    type = "message",
    extra = { kind = "message", pr = session.pr, details = session.details },
  }
end

local function build_changes_folder(session, hunks, opts)
  opts = type(opts) == "table" and opts or {}
  local added_total, deleted_total = 0, 0
  for _, h in ipairs(hunks) do
    added_total = added_total + (h.added or 0)
    deleted_total = deleted_total + (h.deleted or 0)
  end

  local children = {}
  if #hunks == 0 then
    children[#children + 1] = message_node(session, "changes:empty", "No navigable hunks for this file.")
  else
    for _, hunk in ipairs(hunks) do
      local end_line = hunk.target_side == "base"
        and (hunk.base_end or hunk.base_start)
        or (hunk.head_end or hunk.head_start)
      children[#children + 1] = {
        id = string.format("ghpr-diff-review:%d:hunk:%d", session.pr_number, hunk.index),
        name = string.format("%s L%d-%d  +%d -%d",
          KIND_ICONS[hunk.kind] or "[?]",
          hunk.target_line or 1, end_line or hunk.target_line or 1,
          hunk.added or 0, hunk.deleted or 0),
        type = "file",
        path = session.target_path,
        extra = {
          kind = "change",
          hunk = hunk,
          pr = session.pr,
          details = session.details,
          highlight = KIND_HL[hunk.kind],
        },
      }
    end
  end

  return {
    id = string.format("ghpr-diff-review:%d:changes:%s", session.pr_number, session.target_path or ""),
    name = string.format("Changes (%d hunks: +%d -%d)", #hunks, added_total, deleted_total),
    type = "folder",
    extra = { kind = "changes_section" },
    children = children,
  }
end

local function build_comments_folder(session, threads, opts)
  opts = type(opts) == "table" and opts or panel_opts()
  local thread_entries = {}
  local thread_total = 0
  local comment_total = 0
  local target_path = normalize_path(session.target_path)

  for idx, thread in ipairs(type(threads) == "table" and threads or {}) do
    local is_resolved = thread.isResolved == true or thread.is_resolved == true
    local is_outdated = thread.isOutdated == true or thread.is_outdated == true

    if normalize_path(thread.path) == target_path
      and (opts.show_resolved or not is_resolved)
      and (opts.show_outdated or not is_outdated) then
      local comments = normalize_thread_comments(thread)
      if #comments > 0 then
        thread_total = thread_total + 1
        comment_total = comment_total + #comments

        local target = thread_target(session, thread, comments)
        local line = primary_line(target)
        local status = thread_status(thread)
        local thread_name = string.format("Thread L%s [%s] x%d",
          line ~= math.huge and tostring(line) or "?", status, #comments)
        local thread_node = {
          id = string.format("ghpr-diff-review:%d:thread:%s:%d", session.pr_number, safe_string(thread.id, "thread"), idx),
          name = thread_name,
          type = "directory",
          path = target_path,
          extra = { kind = "thread", pr = session.pr, details = session.details, target = target },
          children = {},
        }

        for ci, comment in ipairs(comments) do
          local comment_target = vim.tbl_extend("force", {}, target, {
            selected_comment_id = comment.id,
            line = first_pos(comment.line, target.line, target.original_line),
            original_line = first_pos(comment.original_line, target.original_line, target.line),
          })
          thread_node.children[#thread_node.children + 1] = {
            id = string.format("ghpr-diff-review:%d:comment:%s:%d", session.pr_number, safe_string(comment.id, "comment"), ci),
            name = string.format("@%s: %s", comment.author, body_preview(comment.body)),
            type = "file",
            path = target_path,
            extra = { kind = "comment", pr = session.pr, details = session.details, target = comment_target, comment = comment },
          }
        end

        thread_entries[#thread_entries + 1] = { line = line, node = thread_node }
      end
    end
  end

  table.sort(thread_entries, function(a, b)
    if a.line ~= b.line then return a.line < b.line end
    return a.node.name < b.node.name
  end)

  session.thread_total = thread_total
  session.comment_total = comment_total

  local children = {}
  if #thread_entries == 0 then
    children[#children + 1] = message_node(session, "comments:empty", "No comments for this file.")
  else
    for _, item in ipairs(thread_entries) do
      children[#children + 1] = item.node
    end
  end

  return {
    id = string.format("ghpr-diff-review:%d:comments:%s", session.pr_number, session.target_path or ""),
    name = string.format("Comments (%d threads, %d comments)", thread_total, comment_total),
    type = "folder",
    extra = { kind = "comments_section" },
    children = children,
  }
end

local function build_root_nodes(session, hunks, threads, comments_status, opts)
  opts = type(opts) == "table" and opts or panel_opts()
  local path = session.target_path ~= "" and session.target_path or "(unknown file)"

  local root_children = {}

  if opts.sections.changes then
    root_children[#root_children + 1] = build_changes_folder(session, hunks or {}, opts)
  end

  if opts.sections.comments then
    if comments_status == "loading" then
      root_children[#root_children + 1] = {
        id = string.format("ghpr-diff-review:%d:comments-loading", session.pr_number),
        name = "Comments (loading...)",
        type = "folder",
        extra = { kind = "comments_section" },
        children = {
          message_node(session, "comments:loading", string.format("Loading comments for %s...", path)),
        },
      }
    elseif comments_status == "error" then
      root_children[#root_children + 1] = {
        id = string.format("ghpr-diff-review:%d:comments-error", session.pr_number),
        name = "Comments (error)",
        type = "folder",
        extra = { kind = "comments_section" },
        children = {
          message_node(session, "comments:error", "Unable to load comments."),
        },
      }
    else
      root_children[#root_children + 1] = build_comments_folder(session, threads, opts)
    end
  end

  return {
    {
      id = string.format("ghpr-diff-review:%d:root:%s", tonumber(session.pr_number) or 0, session.target_path or ""),
      name = path,
      type = "folder",
      extra = { kind = "root", pr = session.pr, details = session.details },
      children = root_children,
    },
  }
end

-- ── neo-tree integration ──────────────────────────────────────────────────────

local function buffer_filetype(bufnr)
  if not valid_buf(bufnr) then return "" end
  local ok, filetype = pcall(vim.api.nvim_get_option_value, "filetype", { buf = bufnr })
  if ok and type(filetype) == "string" then return filetype end
  return type(vim.bo[bufnr].filetype) == "string" and vim.bo[bufnr].filetype or ""
end

local function source_buffer(bufnr)
  return buffer_filetype(bufnr) == "neo-tree" and vim.b[bufnr].neo_tree_source == SOURCE_NAME
end

local function live_state_window_buffer(state)
  if type(state) ~= "table" then return nil, nil end
  local winid = tonumber(state.winid)
  if not valid_win(winid) then return nil, nil end
  local bufnr = vim.api.nvim_win_get_buf(winid)
  if not valid_buf(bufnr) then return nil, nil end
  return winid, bufnr
end

local function state_is_live(state)
  local _, bufnr = live_state_window_buffer(state)
  if not bufnr then return false end
  return source_buffer(bufnr)
end

local function renderer_module()
  local ok, renderer = pcall(require, "neo-tree.ui.renderer")
  if ok then return renderer end
  return nil
end

local function neotree_integration()
  local ok, neotree = pcall(require, "gh-pr.integrations.neotree")
  if ok then return neotree end
  return nil
end

local function actions_module()
  local ok, actions = pcall(require, "gh-pr.actions")
  if ok then return actions end
  return nil
end

local function clear_source_chrome(state)
  if type(state) ~= "table" then return end
  state.enable_source_selector = false
  local winid = tonumber(state.winid)
  if not valid_win(winid) then return end
  pcall(vim.api.nvim_set_option_value, "winbar", "", { win = winid })
  pcall(vim.api.nvim_set_option_value, "statusline", "", { win = winid })
end

local function render_state(state, session)
  local renderer = renderer_module()
  if not renderer or type(renderer.show_nodes) ~= "function" then return false end
  clear_source_chrome(state)
  local ok = pcall(renderer.show_nodes, session.nodes or {}, state)
  if ok then
    clear_source_chrome(state)
    local _, bufnr = live_state_window_buffer(state)
    if bufnr then state_by_buffer[bufnr] = state end
  end
  return ok
end

local function render_session(session)
  if type(session) ~= "table" then return end
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

local function source_visible(tabid)
  local neotree = neotree_integration()
  if not neotree or type(neotree.is_source_visible) ~= "function" then return false end
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
  if not opened then return false, "Unable to open diff review panel" end
  if type(session) == "table" then
    session.window_position = spec.position
    session.window_height = spec.height
  end
  return true, nil
end

local function close_source_window(tabid, session)
  local neotree = neotree_integration()
  if not neotree or type(neotree.close_source) ~= "function" then return false end
  local position = type(session) == "table" and session.window_position or nil
  local closed = neotree.close_source(SOURCE_NAME, { position = position, tabid = tabid })
  if type(session) == "table" then
    session.window_position = nil
    session.window_height = nil
  end
  return closed
end

local function source_position_matches(session, opts)
  if type(session) ~= "table" then return true end
  return session.window_position == panel_window_spec(opts).position
end

-- ── session management ───────────────────────────────────────────────────────

local function resolve_comments_target(ctx, pr_number)
  ctx = type(ctx) == "table" and ctx or {}
  local path = normalize_path(ctx.file_path)
  local kind = type(ctx.file_kind) == "string" and ctx.file_kind or nil
  if path ~= "" and (kind == "base" or kind == "head" or kind == "unified") then
    return { path = path, kind = kind }
  end

  local tabid = vim.api.nvim_get_current_tabpage()
  local origin_win = tonumber(ctx.origin_win)
  local origin_buf = tonumber(ctx.origin_buf)

  if valid_win(origin_win) then
    local buf = valid_buf(origin_buf) and origin_buf or vim.api.nvim_win_get_buf(origin_win)
    local entry = current_diff_entry(origin_win, buf)
    if entry and entry.pr_number == pr_number and entry.path ~= "" then
      return { path = entry.path, kind = entry.kind }
    end
  end

  for _, entry in ipairs(diff_windows(tabid, pr_number, nil)) do
    if entry.path ~= "" then return { path = entry.path, kind = entry.kind } end
  end

  return nil, "No active diff file found for review panel"
end

local function ensure_session(ctx)
  ctx = type(ctx) == "table" and ctx or {}
  local pr_number = tonumber(ctx.pr_number or (ctx.pr and ctx.pr.number) or vim.b.gh_pr_number)
  if not pr_number then return nil, nil, "Missing PR number for diff review panel" end

  local target, target_err = resolve_comments_target(ctx, pr_number)
  if not target then return nil, nil, target_err end

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
      hunks = {},
    }
    sessions[tabid] = session
  end

  session.pr = type(ctx.pr) == "table" and ctx.pr or session.pr or {}
  session.details = type(ctx.details) == "table" and ctx.details or session.details or {}
  session.comments_ctx = type(ctx.comments_ctx) == "table" and ctx.comments_ctx or nil
  session.origin = { origin_win = tonumber(ctx.origin_win), origin_buf = tonumber(ctx.origin_buf) }
  session.target_path = target.path
  session.target_kind = target.kind
  session.error = nil

  return session, panel_opts(), nil
end

-- ── async fetch ──────────────────────────────────────────────────────────────

local function fetch_threads_async(session, callback, opts)
  opts = type(opts) == "table" and opts or {}
  callback = callback or function() end

  if opts.force_fetch ~= true and type(session.comments_ctx) == "table" and type(session.comments_ctx.threads) == "table" then
    vim.schedule(function() callback(session.comments_ctx.threads, nil) end)
    return
  end

  if type(pr_service.fetch_review_threads_with_pending_async) == "function" then
    pr_service.fetch_review_threads_with_pending_async(session.pr_number, { threads_first = 100, comments_first = 100 }, callback)
    return
  end

  if type(pr_service.fetch_review_threads_async) == "function" then
    pr_service.fetch_review_threads_async(session.pr_number, { threads_first = 100, comments_first = 100 }, callback)
    return
  end

  vim.schedule(function()
    local threads, err
    if type(pr_service.fetch_review_threads_with_pending) == "function" then
      threads, err = pr_service.fetch_review_threads_with_pending(session.pr_number, { threads_first = 100, comments_first = 100 })
    else
      threads, err = pr_service.fetch_review_threads(session.pr_number, { threads_first = 100, comments_first = 100 })
    end
    callback(threads, err)
  end)
end

local function current_session_is_stale(tabid, request_id)
  local session = sessions[tabid]
  return type(session) ~= "table" or session.request_id ~= request_id
end

local function start_async_load(session, mode, opts)
  opts = type(opts) == "table" and opts or {}
  session.request_id = session.request_id + 1
  local request_id = session.request_id
  local tabid = session.tabid
  local hunks = session.hunks or {}

  fetch_threads_async(session, function(threads, err)
    if current_session_is_stale(tabid, request_id) then return end
    local live_session = sessions[tabid]
    if not live_session then return end

    if err and not threads then
      if mode == "probe" then return end
      live_session.status = "error"
      live_session.error = err
      local p_opts = panel_opts()
      live_session.nodes = build_root_nodes(live_session, hunks, nil, "error", p_opts)
      render_session(live_session)
      return
    end

    live_session.status = "ready"
    live_session.error = nil
    if type(threads) == "table" then
      live_session.comments_ctx = vim.tbl_deep_extend("force", {},
        type(live_session.comments_ctx) == "table" and live_session.comments_ctx or {},
        { threads = threads })
    end

    local p_opts = panel_opts()
    live_session.nodes = build_root_nodes(live_session, hunks, threads, "ready", p_opts)

    local has_content = (#hunks > 0) or ((live_session.comment_total or 0) > 0)
    if mode == "probe" and not has_content then return end

    if mode == "probe" and not source_visible(tabid) then
      if p_opts.auto_open == "if_content" and not has_content then return end
      local opened = open_source_window(live_session, p_opts)
      if not opened then return end
    end

    render_session(live_session)
  end, opts)
end

-- ── public API ───────────────────────────────────────────────────────────────

function M.available()
  local neotree = neotree_integration()
  if not neotree then return false end
  local ok = pcall(require, "neo-tree")
  return ok == true
end

function M.navigate(state, path)
  local tabid = vim.api.nvim_get_current_tabpage()
  local session = sessions[tabid]
  local renderer = renderer_module()
  if not renderer or type(renderer.show_nodes) ~= "function" then return end

  state.path = path or vim.fn.getcwd()
  clear_source_chrome(state)

  if type(session) ~= "table" then
    pcall(renderer.show_nodes, {
      {
        id = string.format("ghpr-diff-review:no-context:%d", tabid),
        name = "No active diff context. Open a gh-pr diff file first.",
        type = "message",
        extra = { kind = "message" },
      },
    }, state)
    clear_source_chrome(state)
    return
  end

  register_state(session, state)
end

function M.sync_for_diff(ctx)
  if not M.available() then return nil, "Neo-tree is unavailable" end

  ctx = type(ctx) == "table" and ctx or {}
  local session, opts, err = ensure_session(ctx)
  if err then return nil, err end
  if not opts.enabled then
    M.close_current_tab()
    return false, nil
  end

  if vim.b[tonumber(ctx.origin_buf) or 0] == nil then end
  local origin_buf = tonumber(ctx.origin_buf) or vim.api.nvim_get_current_buf()
  if vim.b[origin_buf].gh_pr_is_non_text == true then return false, nil end

  if source_visible(session.tabid) and not source_position_matches(session, opts) then
    close_source_window(session.tabid, session)
  end

  if opts.auto_open == "never" and not source_visible(session.tabid) then return false, nil end

  local tabid = session.tabid
  local target = resolve_diff_target(ctx)
  local hunks = build_hunks(ctx, tabid, target)
  session.hunks = hunks

  local origin_win = vim.api.nvim_get_current_win()

  local has_hunks = #hunks > 0
  local should_open = opts.auto_open == "always"
    or source_visible(tabid)
    or (opts.auto_open == "if_content" and has_hunks)

  if should_open then
    session.status = "loading"
    session.thread_total = 0
    session.comment_total = 0
    session.nodes = build_root_nodes(session, hunks, nil, "loading", opts)

    if not source_visible(tabid) then
      local opened, open_err = open_source_window(session, opts)
      if not opened then return nil, open_err end
    end

    render_session(session)

    -- Restore focus to origin window (do not steal focus)
    if valid_win(origin_win) and origin_win ~= vim.api.nvim_get_current_win() then
      pcall(vim.api.nvim_set_current_win, origin_win)
    end

    start_async_load(session, "open")
    return true, nil
  end

  -- Not yet open: probe for comments to decide if we should auto-open
  start_async_load(session, "probe")
  return false, nil
end

function M.toggle(ctx)
  if not M.available() then return nil, "Neo-tree is unavailable" end

  local tabid = vim.api.nvim_get_current_tabpage()
  if source_visible(tabid) then
    M.close_current_tab()
    return true, nil
  end

  ctx = type(ctx) == "table" and ctx or {}
  local session, opts, err = ensure_session(ctx)
  if err then return nil, err end
  if not opts.enabled then return nil, "Diff review panel is disabled by config" end

  local target = resolve_diff_target(ctx)
  local hunks = build_hunks(ctx, tabid, target)
  session.hunks = hunks

  session.status = "loading"
  session.thread_total = 0
  session.comment_total = 0
  session.nodes = build_root_nodes(session, hunks, nil, "loading", opts)

  local opened, open_err = open_source_window(session, opts)
  if not opened then return nil, open_err end

  render_session(session)
  start_async_load(session, "open")
  return true, nil
end

local function resolve_candidate_diff_windows(tabid, pr_number, origin)
  local candidates = diff_windows(tabid, pr_number, nil)
  if #candidates > 0 then return candidates end

  local out = {}
  local seen = {}
  local function add(entry)
    if not entry or seen[entry.winid] then return end
    seen[entry.winid] = true
    out[#out + 1] = entry
  end

  origin = type(origin) == "table" and origin or {}
  local origin_win = tonumber(origin.origin_win)
  if valid_win(origin_win) and vim.api.nvim_win_get_tabpage(origin_win) == tabid then
    add(current_diff_entry(origin_win, origin.origin_buf))
  end

  local current_win = vim.api.nvim_get_current_win()
  if valid_win(current_win) and vim.api.nvim_win_get_tabpage(current_win) == tabid then
    add(current_diff_entry(current_win))
  end

  if #out > 0 then return out end

  for _, entry in ipairs(diff_windows(tabid, nil, nil)) do add(entry) end
  return out
end

local function file_for_path(details, path)
  local normalized_target = normalize_path(path)
  for _, file in ipairs(type(details.files) == "table" and details.files or {}) do
    for _, candidate in ipairs({ file.path, file.filename, file.previousFilename, file.previous_filename }) do
      if normalize_path(candidate) == normalized_target then return file end
    end
  end
  return { path = path, filename = path }
end

local function popup_thread_from_target(target)
  local popup_comments = type(target) == "table" and target.thread_comments or nil
  if type(popup_comments) ~= "table" or vim.tbl_isempty(popup_comments) then return nil end
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

function M.open_target(target, opts)
  opts = type(opts) == "table" and opts or {}
  if type(target) ~= "table" then return false end

  local tabid = vim.api.nvim_get_current_tabpage()
  local session = sessions[tabid]
  if type(session) ~= "table" then return false end

  local actions = actions_module()
  if not actions then return false end
  if type(actions.set_active_pr) == "function" then
    actions.set_active_pr(session.pr, session.details)
  end

  -- Navigate to target in diff window
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
    if type(actions.open_diff) ~= "function" then return false end
    actions.open_diff(file_for_path(session.details, target.path), { new_tab = false })
    for _, item in ipairs(resolve_candidate_diff_windows(tabid, session.pr_number, session.origin)) do
      if normalize_path(item.path) == normalize_path(target.path) or item.path == "" then
        destination = item.winid
        destination_kind = item.kind
        if destination_kind == "unified"
          or (target.side == "base" and destination_kind == "base")
          or (target.side ~= "base" and destination_kind == "head") then break end
      end
    end
  end

  if not valid_win(destination) then return false end

  local line = destination_kind == "base"
    and first_pos(target.original_line, target.line, 1)
    or first_pos(target.line, target.original_line, 1)
  line = int(line, 1)
  local max_line = vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(destination))
  line = math.max(1, math.min(max_line, line))
  pcall(vim.api.nvim_set_current_win, destination)
  pcall(vim.api.nvim_win_set_cursor, destination, { line, 0 })

  if opts.open_popup == true then
    local popup_thread = popup_thread_from_target(target)
    if popup_thread and type(popup_thread.comments) == "table" and not vim.tbl_isempty(popup_thread.comments) then
      local current_buf = vim.api.nvim_get_current_buf()
      local ok, popup_err = thread_popup.open(popup_thread, {
        mode = opts.popup_mode == "preview" and "preview" or "open",
        origin_bufnr = current_buf,
        anchor_win = destination,
        enter = opts.focus_thread_popup == true,
      })
      if not ok and popup_err ~= "thread popup disabled by config" and popup_err ~= "thread has no comments" then
        vim.notify("Unable to open thread popup: " .. tostring(popup_err), vim.log.levels.WARN)
      end
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
  if type(session) ~= "table" then return false end

  local p_opts = panel_opts()
  local hunks = session.hunks or {}
  session.status = "loading"
  session.thread_total = 0
  session.comment_total = 0
  session.nodes = build_root_nodes(session, hunks, nil, "loading", p_opts)
  render_session(session)
  start_async_load(session, "open", { force_fetch = opts.force_fetch == true })
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

-- Return the active hunk namespace for the highlight module
M._namespace = vim.api.nvim_create_namespace("gh-pr-diff-review-active-hunk")
M._sessions = sessions
M._state_by_buffer = state_by_buffer

registry.register(SOURCE_NAME, M)

return M
