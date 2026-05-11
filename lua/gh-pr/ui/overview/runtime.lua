local utils = require("gh-pr.overview_utils")
local styles = require("gh-pr.overview_styles")
local renderer = require("gh-pr.ui.overview.render")
local layout = require("gh-pr.ui.overview.layout")
local keymaps = require("gh-pr.ui.overview.keymaps")
local comment_popup = require("gh-pr.comment_popup")

local M = {}

local namespace = vim.api.nvim_create_namespace("gh-pr-overview")
local pane_roles = { "summary", "meta" }
local pane_index = {
  summary = 1,
  meta = 2,
}

local sessions = {}
local sessions_by_pr = {}
local next_session_id = 1

local function normalize_role(role, fallback)
  if role == "activity" then
    return "summary"
  end
  if pane_index[role] then
    return role
  end
  return fallback
end

local function tabpage_valid(tabpage)
  return type(tabpage) == "number" and tabpage > 0 and vim.api.nvim_tabpage_is_valid(tabpage)
end

local function first_window_for_buffer(bufnr)
  if not utils.valid_buf(bufnr) then
    return nil
  end
  local winids = vim.fn.win_findbuf(bufnr)
  for _, winid in ipairs(type(winids) == "table" and winids or {}) do
    if utils.valid_win(winid) then
      return winid
    end
  end
  return nil
end

local function sync_session_windows(session)
  if type(session) ~= "table" then
    return
  end
  session.windows = type(session.windows) == "table" and session.windows or {}
  for _, role in ipairs(pane_roles) do
    local winid = session.windows[role]
    if not utils.valid_win(winid) then
      winid = first_window_for_buffer(session.buffers[role])
    end
    session.windows[role] = winid
  end
  local summary_win = session.windows.summary
  if utils.valid_win(summary_win) then
    session.tabpage = vim.api.nvim_win_get_tabpage(summary_win)
  elseif not tabpage_valid(session.tabpage) then
    session.tabpage = nil
  end
end

local function default_value(value, fallback)
  if value ~= nil then
    return value
  end
  return fallback
end

local function buffer_name(pr_number, role)
  return string.format("ghpr://overview/%d/%s", tonumber(pr_number) or 0, role)
end

local function create_pane_buffer(pr_number, role)
  local name = buffer_name(pr_number, role)
  local existing = utils.find_buffer_by_name(name)
  if utils.valid_buf(existing) then
    return existing
  end
  local bufnr = vim.api.nvim_create_buf(false, true)
  utils.set_buffer_name_safe(bufnr, name)
  return bufnr
end

local function all_buffers_valid(session)
  for _, role in ipairs(pane_roles) do
    if not utils.valid_buf(session.buffers[role]) then
      return false
    end
  end
  return true
end

local function clear_session_links(session)
  sessions[session.id] = nil
  if sessions_by_pr[session.pr_number] == session.id then
    sessions_by_pr[session.pr_number] = nil
  end
end

local function close_session(session)
  if type(session) ~= "table" or session.closing == true then
    return
  end
  session.closing = true
  sync_session_windows(session)

  for _, role in ipairs(pane_roles) do
    local winid = session.windows[role]
    if utils.valid_win(winid) then
      pcall(vim.api.nvim_win_close, winid, true)
    end
  end

  for _, role in ipairs(pane_roles) do
    local bufnr = session.buffers[role]
    if utils.valid_buf(bufnr) then
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end
  end

  clear_session_links(session)
  session.tabpage = nil
end

local function session_from_id(session_id)
  local id = tonumber(session_id)
  if not id then
    return nil
  end
  local session = sessions[id]
  if type(session) ~= "table" then
    return nil
  end
  sync_session_windows(session)
  if not all_buffers_valid(session) then
    close_session(session)
    return nil
  end
  return session
end

local function session_from_pr(pr_number)
  local id = sessions_by_pr[tonumber(pr_number)]
  return session_from_id(id)
end

local function capture_cursor_state(session)
  for _, role in ipairs(pane_roles) do
    local winid = session.windows[role]
    if utils.valid_win(winid) then
      local ok, cursor = pcall(vim.api.nvim_win_get_cursor, winid)
      if ok and type(cursor) == "table" and type(cursor[1]) == "number" then
        session.cursor[role] = cursor[1]
      end
    end
  end
end

local function attach_buffer_metadata(session, role)
  local model = session.model or {}
  local bufnr = session.buffers[role]
  if not utils.valid_buf(bufnr) then
    return
  end

  vim.b[bufnr].gh_pr_number = tonumber(model.number) or 0
  vim.b[bufnr].gh_pr_repo = model.repository
  vim.b[bufnr].gh_pr_overview_ui = "panes"
  vim.b[bufnr].gh_pr_overview_layout = "panes"
  vim.b[bufnr].gh_pr_overview_session = session.id
  vim.b[bufnr].gh_pr_overview_role = role
  vim.b[bufnr].gh_pr_overview_primary = role == "summary"
  vim.b[bufnr].gh_pr_overview_tabpage = session.tabpage
  vim.b[bufnr].gh_pr_overview_limits = vim.deepcopy(model.limits or {})
  vim.b[bufnr].gh_pr_overview_sections = {
    checks = model.checks and model.checks.total or 0,
    commits = model.commits and model.commits.total or 0,
    timeline = model.timeline and model.timeline.total or 0,
    comments = model.comments and model.comments.total or 0,
    reviews = model.reviews and model.reviews.total or 0,
    threads = model.threads and model.threads.total or 0,
    pr_changes = model.pr_changes and model.pr_changes.total or 0,
  }
end

local function apply_payload_to_buffer(session, role, payload)
  local bufnr = session.buffers[role]
  if not utils.valid_buf(bufnr) then
    return
  end

  payload = type(payload) == "table" and payload or {}
  local lines = type(payload.lines) == "table" and payload.lines or {}
  local highlights = type(payload.highlights) == "table" and payload.highlights or {}
  local actions = type(payload.actions) == "table" and payload.actions or {}

  if vim.tbl_isempty(lines) then
    lines = { "(empty)" }
  end

  vim.api.nvim_set_option_value("modifiable", true, { buf = bufnr })
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.api.nvim_buf_clear_namespace(bufnr, namespace, 0, -1)
  for _, item in ipairs(highlights) do
    local line = (tonumber(item.line) or 1) - 1
    if line >= 0 and line < #lines then
      pcall(
        vim.api.nvim_buf_add_highlight,
        bufnr,
        namespace,
        item.group or "Normal",
        line,
        tonumber(item.start_col) or 0,
        tonumber(item.end_col) or -1
      )
    end
  end
  vim.api.nvim_set_option_value("modifiable", false, { buf = bufnr })
  pcall(vim.api.nvim_set_option_value, "modified", false, { buf = bufnr })
  session.line_actions[role] = actions

  local winid = session.windows[role]
  if utils.valid_win(winid) then
    utils.ensure_window_options(winid)
    local line = utils.clamp_line(bufnr, default_value(session.cursor[role], 1))
    pcall(vim.api.nvim_win_set_cursor, winid, { line, 0 })
  end

  attach_buffer_metadata(session, role)
end
local execute_action, render_session

local function toggle_activity_thread(session, action)
  if type(session) ~= "table" or type(action) ~= "table" then
    return
  end

  local thread_id = utils.safe_string(action.thread_id, "")
  if thread_id == "" then
    if type(action.open_action) == "table" then
      execute_action(session, action.open_action, "diff")
    end
    return
  end

  session.activity_folds = type(session.activity_folds) == "table" and session.activity_folds or {}
  local expanded = action.default_expanded == true
  local override = session.activity_folds[thread_id]
  if type(override) == "boolean" then
    expanded = override
  end
  session.activity_folds[thread_id] = not expanded
  render_session(session)
end

local function open_action_menu(session, action, variant, fallback_title)
  local options = {}
  for _, item in ipairs(type(action.options) == "table" and action.options or {}) do
    if type(item) == "table" and type(item.label) == "string" and item.label ~= "" and type(item.action) == "table" then
      options[#options + 1] = item
    end
  end

  if vim.tbl_isempty(options) then
    return
  end

  vim.ui.select(options, {
    prompt = utils.safe_string(action.title, fallback_title or "Choose action"),
    format_item = function(item)
      return utils.safe_string(type(item) == "table" and item.label or "", "(unknown action)")
    end,
  }, function(selected)
    if type(selected) == "table" and type(selected.action) == "table" then
      execute_action(session, selected.action, variant)
    end
  end)
end

execute_action = function(session, action, variant)
  if type(action) ~= "table" then
    return
  end

  if action.kind == "toggle_activity_thread" then
    if variant == "diff" and type(action.open_action) == "table" then
      execute_action(session, action.open_action, variant)
      return
    end
    toggle_activity_thread(session, action)
    return
  end

  if action.kind == "open_activity_thread_workspace" then
    if type(session.callbacks.open_activity_thread_workspace) == "function"
      and type(action.payload) == "table" then
      session.callbacks.open_activity_thread_workspace(action.payload)
    end
    return
  end

  if action.kind == "thread_comment_menu" then
    if variant == "diff" and type(action.default_action) == "table" then
      execute_action(session, action.default_action, variant)
      return
    end
    open_action_menu(session, action, variant, "Thread comment action")
    return
  end

  if action.kind == "action_menu" then
    open_action_menu(session, action, variant, "Select action")
    return
  end

  if action.kind == "preview_markdown_link" then
    if type(session.callbacks.preview_markdown_link) == "function" then
      session.callbacks.preview_markdown_link(action)
      return
    end
    if type(action.url) == "string" and action.url ~= "" then
      utils.open_url(action.url)
    end
    return
  end

  if action.kind == "url" then
    utils.open_url(action.url)
    return
  end

  if action.kind == "location" then
    if type(session.callbacks.open_location) == "function" and type(action.target) == "table" then
      session.callbacks.open_location(action.target)
      return
    end
    utils.open_url(action.fallback_url)
    return
  end

  if action.kind == "thread_fix_diff" and type(action.payload) == "table" then
    if type(session.callbacks.open_thread_fix_diff) == "function" then
      session.callbacks.open_thread_fix_diff(action.payload)
      return
    end

    local fallback = type(action.payload.fallback_target) == "table" and action.payload.fallback_target or nil
    if fallback and type(session.callbacks.open_location) == "function" then
      session.callbacks.open_location(fallback)
      return
    end

    utils.open_url(action.fallback_url)
    return
  end

  if (action.kind == "thread_comment_evolution_diff" or action.kind == "thread_comment_commit_diff")
    and type(action.payload) == "table" then
    if type(session.callbacks.open_thread_comment_evolution_diff) == "function" then
      session.callbacks.open_thread_comment_evolution_diff(action.payload)
      return
    end
    if type(session.callbacks.open_thread_comment_commit_diff) == "function" then
      session.callbacks.open_thread_comment_commit_diff(action.payload)
      return
    end

    local fallback = type(action.payload.fallback_target) == "table" and action.payload.fallback_target or nil
    if fallback and type(session.callbacks.open_location) == "function" then
      session.callbacks.open_location(fallback)
      return
    end

    utils.open_url(action.fallback_url)
    return
  end

  if action.kind == "commit" and type(action.commit) == "table" then
    if type(session.callbacks.open_commit_diff) == "function" then
      session.callbacks.open_commit_diff(action.commit)
      return
    end
    utils.open_url(action.commit.url)
    return
  end

  if action.kind == "file" and type(action.file) == "table" then
    if variant == "original" and type(session.callbacks.open_file_original) == "function" then
      session.callbacks.open_file_original(action.file)
      return
    end
    if variant == "modified" and type(session.callbacks.open_file_modified) == "function" then
      session.callbacks.open_file_modified(action.file)
      return
    end
    if type(session.callbacks.open_file_diff) == "function" then
      session.callbacks.open_file_diff(action.file)
    end
    return
  end

  if action.kind == "open_url" and type(session.callbacks.open_url) == "function" then
    session.callbacks.open_url()
    return
  end

  if action.kind == "open_comments_tree" and type(session.callbacks.open_comments_tree) == "function" then
    session.callbacks.open_comments_tree()
    return
  end

  if action.kind == "refresh" and type(session.callbacks.refresh) == "function" then
    session.callbacks.refresh()
    return
  end

  if action.kind == "more_section"
    and type(action.section) == "string"
    and type(session.callbacks.more_section) == "function" then
    session.callbacks.more_section(action.section)
    return
  end

  if action.kind == "edit_stub"
    and type(action.edit_kind) == "string"
    and type(session.callbacks.edit_stub) == "function" then
    session.callbacks.edit_stub(action.edit_kind, type(action.payload) == "table" and action.payload or {})
    return
  end

  if action.kind == "rerequest_reviewer"
    and type(action.payload) == "table"
    and type(session.callbacks.rerequest_reviewer) == "function" then
    session.callbacks.rerequest_reviewer(action.payload)
    return
  end
end
render_session = function(session)
  capture_cursor_state(session)
  local payloads = renderer.render(session)
  for _, role in ipairs(pane_roles) do
    apply_payload_to_buffer(session, role, payloads[role])
  end
end

local function ensure_windows(session, focus_role)
  sync_session_windows(session)
  focus_role = normalize_role(focus_role, nil)
  if not layout.windows_valid(session.windows) then
    local windows, tabpage = layout.open_windows(session.buffers, session.window, session.layout, focus_role)
    session.windows = windows
    session.tabpage = tabpage
  elseif type(focus_role) == "string" and focus_role ~= "" then
    local winid = session.windows[focus_role]
    if utils.valid_win(winid) then
      local tabpage = vim.api.nvim_win_get_tabpage(winid)
      if tabpage_valid(tabpage) and vim.api.nvim_get_current_tabpage() ~= tabpage then
        pcall(vim.api.nvim_set_current_tabpage, tabpage)
      end
      pcall(vim.api.nvim_set_current_win, winid)
    end
  end

  for _, role in ipairs(pane_roles) do
    local winid = session.windows[role]
    if utils.valid_win(winid) then
      utils.ensure_window_options(winid)
    end
  end
end
local function ensure_buffer_options(session)
  for _, role in ipairs(pane_roles) do
    local bufnr = session.buffers[role]
    if utils.valid_buf(bufnr) then
      utils.ensure_buffer_options(bufnr, { filetype = "markdown" })
    end
  end
end

local function focus_pane(session, role)
  sync_session_windows(session)
  role = normalize_role(role, "summary")
  local winid = session.windows[role]
  if not utils.valid_win(winid) then
    winid = session.windows.summary
  end
  if utils.valid_win(winid) then
    local tabpage = vim.api.nvim_win_get_tabpage(winid)
    if tabpage_valid(tabpage) and vim.api.nvim_get_current_tabpage() ~= tabpage then
      pcall(vim.api.nvim_set_current_tabpage, tabpage)
    end
    pcall(vim.api.nvim_set_current_win, winid)
  end
end

local function role_from_current_window(session)
  sync_session_windows(session)
  local current = vim.api.nvim_get_current_win()
  for _, role in ipairs(pane_roles) do
    if session.windows[role] == current then
      return role
    end
  end
  return nil
end

local function cycle_pane(session, step)
  local current_role = normalize_role(role_from_current_window(session), "summary")
  local index = pane_index[current_role] or 1
  local direction = tonumber(step) or 1
  if direction == 0 then
    direction = 1
  end
  local next_index = ((index - 1 + direction) % #pane_roles) + 1
  focus_pane(session, pane_roles[next_index])
end

local function key_display(value, fallback)
  local text = utils.safe_string(value, "")
  if text == "" then
    return fallback
  end
  return text
end

local function help_lines(session)
  local km = type(session.keymaps) == "table" and session.keymaps or {}
  local cycle_next = key_display(km.cycle_next, "<Tab>")
  local cycle_prev = key_display(km.cycle_prev, "<S-Tab>")
  local focus_summary = key_display(km.focus_summary, "g1")
  local focus_meta = key_display(km.focus_meta, "g3")

  return {
    "gh-pr overview shortcuts",
    "",
    "Navigation",
    string.format("%-10s Focus summary pane", focus_summary),
    string.format("%-10s Focus collaboration pane", focus_meta),
    string.format("%-10s Next pane", cycle_next),
    string.format("%-10s Previous pane", cycle_prev),
    string.format("%-10s Next pane (alias)", "<C-w>w"),
    string.format("%-10s Previous pane (alias)", "<C-w>W"),
    string.format("%-10s/%-4s Focus summary/collab", "<C-w>h", "<C-w>l"),
    "",
    "Actions",
    "<CR>       Open selected item or toggle thread fold",
    "D          Open diff / secondary action for selected item",
    "O / M      Open original / modified file for selected diff file",
    "gr         Load more activity",
    "R          Refresh overview",
    "b          Open pull request in browser",
    "C          Open comments tree",
    "q          Close overview",
    "",
    "Review",
    "a / d / c  Approve / Request changes / Comment review",
    "m / k      Merge / Checkout",
    "",
    "Close help: q or <Esc>",
  }
end

local function open_help_popup(session, role)
  local bufnr = session.buffers[role]
  if not utils.valid_buf(bufnr) then
    bufnr = vim.api.nvim_get_current_buf()
  end

  local ok, popup_err = comment_popup.open({
    origin_bufnr = bufnr,
    tag = "shortcuts",
    title = string.format("PR #%d overview shortcuts", tonumber(session.pr_number) or 0),
    location = role,
    lines = help_lines(session),
    mode = "open",
    enter = true,
    position = "editor",
    border = "rounded",
    wrap = false,
    min_width = 56,
    min_height = 18,
    max_width = 120,
    max_height = 42,
    close_on_origin_move = false,
    filetype = "markdown",
  })

  if not ok and popup_err then
    vim.notify("Unable to open overview shortcuts: " .. tostring(popup_err), vim.log.levels.WARN)
  end
end

local function ensure_keymaps(session)
  session.keymaps_set = type(session.keymaps_set) == "table" and session.keymaps_set or {}
  for _, role in ipairs(pane_roles) do
    if not session.keymaps_set[role] then
      keymaps.attach(session, role, {
        callback = function(name)
          local fn = session.callbacks[name]
          if type(fn) == "function" then
            fn()
          end
        end,
        execute = function(target_role, variant)
          local winid = session.windows[target_role]
          if not utils.valid_win(winid) then
            return
          end
          local cursor = vim.api.nvim_win_get_cursor(winid)
          local line = tonumber(cursor[1]) or 1
          local action = type(session.line_actions[target_role]) == "table" and session.line_actions[target_role][line] or nil
          execute_action(session, action, variant)
        end,
        focus = function(target_role)
          focus_pane(session, target_role)
        end,
        cycle = function(step)
          cycle_pane(session, step)
        end,
        help = function(target_role)
          open_help_popup(session, target_role)
        end,
        close = function()
          close_session(session)
        end,
        refresh = function()
          if type(session.callbacks.refresh) == "function" then
            session.callbacks.refresh()
          end
        end,
        more = function()
          if type(session.callbacks.more_section) == "function" then
            session.callbacks.more_section("timeline")
          end
        end,
      })
      session.keymaps_set[role] = true
    end
  end
end

local function register_cleanup_autocmds(session)
  if session.cleanup_registered == true then
    return
  end
  session.cleanup_registered = true
  for _, role in ipairs(pane_roles) do
    local bufnr = session.buffers[role]
    if utils.valid_buf(bufnr) then
      vim.api.nvim_create_autocmd({ "BufWipeout", "BufUnload", "BufDelete" }, {
        buffer = bufnr,
        once = true,
        callback = function()
          local current = sessions[session.id]
          if current and current.closing ~= true then
            close_session(current)
          end
        end,
      })
    end
  end
end

function M.open(model, opts)
  opts = type(opts) == "table" and opts or {}
  model = type(model) == "table" and model or {}

  styles.ensure_base_highlights()

  local target_number = tonumber(model.number) or 0
  local session = session_from_id(opts.session_id) or session_from_pr(target_number)
  if not session then
    session = {
      id = next_session_id,
      pr_number = target_number,
      buffers = {},
      windows = {},
      line_actions = {},
      cursor = {},
      activity_folds = {},
      cleanup_registered = false,
      keymaps_set = {},
      tabpage = nil,
      closing = false,
    }
    next_session_id = next_session_id + 1
    for _, role in ipairs(pane_roles) do
      session.buffers[role] = create_pane_buffer(target_number, role)
    end

    sessions[session.id] = session
    sessions_by_pr[target_number] = session.id
  elseif session.pr_number ~= target_number then
    sessions_by_pr[session.pr_number] = nil
    session.pr_number = target_number
    sessions_by_pr[target_number] = session.id
  end

  session.model = model
  session.callbacks = type(opts.actions) == "table" and opts.actions or {}
  session.show = type(opts.show) == "table" and vim.deepcopy(opts.show) or {}
  session.date_format = utils.safe_string(opts.date_format, "%Y-%m-%d %H:%M")
  session.window = utils.sanitize_window_opts(opts.window)
  session.layout = layout.sanitize_layout_opts(opts.layout)
  session.activity = renderer.sanitize_activity_opts(opts.activity)
  session.theme = utils.sanitize_theme_opts(opts.theme)
  session.markdown = utils.sanitize_markdown_opts(opts.markdown)
  session.thread_snippet = utils.sanitize_thread_snippet_opts(opts.thread_snippet)
  session.thread_fix_diff = utils.sanitize_thread_fix_diff_opts(opts.thread_fix_diff)
  session.keymaps = keymaps.sanitize(opts.keymaps)

  ensure_buffer_options(session)

  local focus_role = nil
  if session.window.enter ~= false then
    focus_role = normalize_role(opts.focus_role, "summary")
  end
  ensure_windows(session, focus_role)
  ensure_keymaps(session)
  render_session(session)
  register_cleanup_autocmds(session)

  return session.id
end

function M.close(session_id)
  local session = session_from_id(session_id)
  if session then
    close_session(session)
  end
end

function M.session_id_for_buf(bufnr)
  if not utils.valid_buf(bufnr) then
    return nil
  end
  local value = vim.b[bufnr].gh_pr_overview_session
  local id = tonumber(value)
  if not id then
    return nil
  end
  if not sessions[id] then
    return nil
  end
  return id
end

function M.session_id_for_pr(pr_number)
  local session = session_from_pr(pr_number)
  if not session then
    return nil
  end
  return session.id
end

function M.focus_for_pr(pr_number, role)
  local session = session_from_pr(pr_number)
  if not session then
    return nil
  end
  ensure_windows(session, normalize_role(role, "summary"))
  return session.id
end

function M.overview_limits_for_session(session_id)
  local session = session_from_id(session_id)
  if not session then
    return nil
  end
  local limits = type(session.model) == "table" and type(session.model.limits) == "table" and session.model.limits or nil
  if type(limits) == "table" then
    return vim.deepcopy(limits)
  end
  local summary_buf = session.buffers.summary
  if utils.valid_buf(summary_buf) and type(vim.b[summary_buf].gh_pr_overview_limits) == "table" then
    return vim.deepcopy(vim.b[summary_buf].gh_pr_overview_limits)
  end
  return nil
end

function M.overview_limits_for_pr(pr_number)
  local session = session_from_pr(pr_number)
  if not session then
    return nil
  end
  return M.overview_limits_for_session(session.id)
end

return M
