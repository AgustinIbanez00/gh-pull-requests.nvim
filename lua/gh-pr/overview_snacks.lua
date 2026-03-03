local M = {}

local overview_markdown = require("gh-pr.overview_markdown")
local utils = require("gh-pr.overview_utils")
local styles = require("gh-pr.overview_styles")
local renderer = require("gh-pr.overview_render")

local namespace = vim.api.nvim_create_namespace("gh-pr-overview")
local views = {}

local function tab_exists(tabs, name)
  for _, item in ipairs(tabs or {}) do
    if item == name then
      return true
    end
  end
  return false
end

local function overview_buffer_filetype(view)
  local markdown = type(view) == "table" and type(view.markdown) == "table" and view.markdown or {}
  if markdown.mode == "full" then
    return "markdown"
  end

  local provider = overview_markdown.resolve_provider(markdown)
  if provider == "render-markdown" then
    return "markdown"
  end

  return "ghpr_overview"
end

local function attach_buffer_metadata(bufnr, model, view)
  vim.b[bufnr].gh_pr_number = model.number
  vim.b[bufnr].gh_pr_repo = model.repository
  vim.b[bufnr].gh_pr_overview_ui = "snacks"
  vim.b[bufnr].gh_pr_overview_layout = "tabs"
  vim.b[bufnr].gh_pr_overview_buffer_ft = overview_buffer_filetype(view)
  vim.b[bufnr].gh_pr_overview_tab = view.current_tab
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

local function refresh_view(view)
  renderer.render(view, namespace)
  attach_buffer_metadata(view.bufnr, view.model, view)
end

local function save_cursor(view)
  local winid = utils.current_win_for_buf(view.bufnr)
  if not winid then
    return
  end
  local cursor = vim.api.nvim_win_get_cursor(winid)
  view.cursor_by_tab[view.current_tab] = cursor[1]
end

local function current_action(view, opts)
  opts = type(opts) == "table" and opts or {}
  local winid = utils.current_win_for_buf(view.bufnr)
  if not winid then
    return nil
  end
  local cursor = vim.api.nvim_win_get_cursor(winid)
  local line = cursor[1]
  local col = cursor[2]

  if opts.include_inline == true then
    local inline = type(view.inline_actions) == "table" and view.inline_actions[line] or nil
    if type(inline) == "table" and not vim.tbl_isempty(inline) then
      for _, item in ipairs(inline) do
        local start_col = tonumber(item.start_col) or -1
        local end_col = tonumber(item.end_col) or -1
        local includes_col = start_col >= 0 and col >= start_col and (end_col < 0 or col < end_col)
        if includes_col and type(item.action) == "table" then
          return item.action
        end
      end
    end
  end

  if opts.inline_only == true then
    return nil
  end

  return view.line_actions[line]
end

local function thread_fix_diff_inline_enabled(view)
  if type(view.thread_fix_diff) ~= "table" then
    return false
  end
  if view.thread_fix_diff.enabled == false then
    return false
  end
  return view.thread_fix_diff.inline ~= false
end

local function ensure_thread_fix_inline_store(view)
  view.thread_fix_inline = type(view.thread_fix_inline) == "table" and view.thread_fix_inline or {}
  return view.thread_fix_inline
end

local function thread_fix_diff_inline_request_opts(view)
  local fix_opts = type(view.thread_fix_diff) == "table" and view.thread_fix_diff or {}
  return {
    inline = true,
    context_before = tonumber(fix_opts.context_before) or 5,
    context_after = tonumber(fix_opts.context_after) or 5,
    fallback_to_buffer = fix_opts.fallback_to_buffer ~= false,
    silent = true,
  }
end

local function toggle_thread_fix_diff_inline(view, action)
  local key = utils.thread_fix_action_key(action)
  if type(key) ~= "string" or key == "" then
    if type(view.callbacks.open_thread_fix_diff) == "function" then
      view.callbacks.open_thread_fix_diff(action)
    end
    return
  end

  local store = ensure_thread_fix_inline_store(view)
  local state = store[key]
  if type(state) ~= "table" then
    state = {}
    store[key] = state
  end

  if state.expanded == true then
    state.expanded = false
    refresh_view(view)
    return
  end

  state.expanded = true
  if state.status == "ready" or state.status == "error" or state.status == "fallback" then
    refresh_view(view)
    return
  end

  state.status = "loading"
  refresh_view(view)

  local resolver = type(view.callbacks.resolve_thread_fix_diff) == "function" and view.callbacks.resolve_thread_fix_diff or nil
  if not resolver then
    state.status = "error"
    state.error = "Thread fix diff resolver is unavailable"
    refresh_view(view)
    return
  end

  local payload = vim.deepcopy(action)
  if type(payload.pr_number) ~= "number" then
    payload.pr_number = tonumber(view.model and view.model.number) or nil
  end

  local result = resolver(payload, thread_fix_diff_inline_request_opts(view))
  if type(result) == "table" and result.ok == true then
    state.status = "ready"
    state.error = ""
    state.lines = type(result.lines) == "table" and result.lines or {}
    state.diff_entries = type(result.diff_entries) == "table" and result.diff_entries or nil
    state.commit_oid = utils.safe_string(result.commit_oid, "")
    state.path = utils.safe_string(result.path, utils.safe_string(action.path, ""))
    state.fallback_opened = false
  elseif type(result) == "table" and result.fallback_opened == true then
    state.status = "fallback"
    state.error = utils.safe_string(result.error, "Opened legacy diff buffer fallback")
    state.lines = {}
    state.diff_entries = nil
    state.commit_oid = utils.safe_string(result.commit_oid, "")
    state.path = utils.safe_string(result.path, utils.safe_string(action.path, ""))
    state.fallback_opened = true
  else
    state.status = "error"
    state.error = utils.safe_string(type(result) == "table" and result.error or "", "Unable to resolve thread fix diff")
    state.lines = {}
    state.diff_entries = nil
    state.commit_oid = utils.safe_string(type(result) == "table" and result.commit_oid or "", "")
    state.path = utils.safe_string(type(result) == "table" and result.path or "", utils.safe_string(action.path, ""))
    state.fallback_opened = false
  end

  refresh_view(view)
end

local function execute_action(view, action, variant)
  if type(action) ~= "table" then
    return
  end

  if action.kind == "open_thread_fix_diff" then
    if thread_fix_diff_inline_enabled(view) then
      toggle_thread_fix_diff_inline(view, action)
      return
    end
    if type(view.callbacks.open_thread_fix_diff) == "function" then
      view.callbacks.open_thread_fix_diff(action)
    end
    return
  end

  if action.kind == "open_thread_comment_evolution_diff" then
    if type(view.callbacks.open_thread_comment_evolution_diff) == "function" then
      view.callbacks.open_thread_comment_evolution_diff(action)
      return
    end
    if type(view.callbacks.open_thread_comment_commit_diff) == "function" then
      view.callbacks.open_thread_comment_commit_diff(action)
      return
    end
    if type(action.fallback_target) == "table" and type(view.callbacks.open_location) == "function" then
      view.callbacks.open_location(action.fallback_target)
      return
    end
    utils.open_url(action.fallback_url)
    return
  end

  if action.kind == "toggle_activity_thread" then
    local thread_id = type(action.thread_id) == "string" and action.thread_id or ""
    if thread_id == "" then
      return
    end
    view.activity_folds = type(view.activity_folds) == "table" and view.activity_folds or {}
    local winid = utils.current_win_for_buf(view.bufnr)
    if winid then
      local cursor = vim.api.nvim_win_get_cursor(winid)
      view.cursor_by_tab[view.current_tab] = cursor[1]
    end
    local current_expanded = action.expanded == true
    local next_expanded = not current_expanded
    local default_expanded = action.default_expanded == true

    if next_expanded == default_expanded then
      view.activity_folds[thread_id] = nil
    else
      view.activity_folds[thread_id] = next_expanded
    end
    refresh_view(view)
    return
  end

  if action.kind == "url" then
    utils.open_url(action.url)
    return
  end

  if action.kind == "location" then
    if type(view.callbacks.open_location) == "function" and type(action.target) == "table" then
      view.callbacks.open_location(action.target)
      return
    end
    utils.open_url(action.fallback_url)
    return
  end

  if action.kind == "markdown_link" then
    if type(view.callbacks.preview_markdown_link) == "function" then
      view.callbacks.preview_markdown_link(action)
      return
    end
    utils.open_url(action.url)
    return
  end

  if action.kind == "open_comments_tree" then
    if type(view.callbacks.open_comments_tree) == "function" then
      view.callbacks.open_comments_tree()
    end
    return
  end

  if action.kind == "edit_stub" then
    if type(view.callbacks.edit_stub) == "function" then
      view.callbacks.edit_stub(action.edit_kind, action.payload or {})
    end
    return
  end

  if action.kind == "more_section" and type(action.section) == "string" then
    if type(view.callbacks.more_section) == "function" then
      view.callbacks.more_section(action.section)
    end
    return
  end

  if action.kind == "commit" and type(action.commit) == "table" then
    if type(view.callbacks.open_commit_diff) == "function" then
      view.callbacks.open_commit_diff(action.commit)
      return
    end
    utils.open_url(action.commit.url)
    return
  end

  if action.kind == "file" and type(action.file) == "table" then
    if variant == "original" and type(view.callbacks.open_file_original) == "function" then
      view.callbacks.open_file_original(action.file)
      return
    end
    if variant == "modified" and type(view.callbacks.open_file_modified) == "function" then
      view.callbacks.open_file_modified(action.file)
      return
    end
    if type(view.callbacks.open_file_diff) == "function" then
      view.callbacks.open_file_diff(action.file)
      return
    end
  end
end

local function resolve_thread_fix_action(view)
  local action = current_action(view)
  if type(action) == "table" then
    if action.kind == "open_thread_fix_diff" then
      return action
    end
    if type(action.thread_fix_action) == "table" and action.thread_fix_action.kind == "open_thread_fix_diff" then
      return action.thread_fix_action
    end
  end

  local winid = utils.current_win_for_buf(view.bufnr)
  if not winid then
    return nil
  end
  local cursor = vim.api.nvim_win_get_cursor(winid)
  local line = tonumber(cursor[1]) or 1
  local nearby = {
    type(view.line_actions) == "table" and view.line_actions[line - 1] or nil,
    type(view.line_actions) == "table" and view.line_actions[line + 1] or nil,
  }
  for _, candidate in ipairs(nearby) do
    if type(candidate) == "table" and candidate.kind == "open_thread_fix_diff" then
      return candidate
    end
  end

  local search_start = math.max(1, line - 4)
  local search_lines = vim.api.nvim_buf_get_lines(view.bufnr, search_start - 1, line, false)
  for index = #search_lines, 1, -1 do
    local text = vim.trim(utils.safe_string(search_lines[index], ""))
    local path, line_str = text:match("^(.+):(%d+)%s*%[")
    if not path then
      path, line_str = text:match("^(.+):(%d+)$")
    end
    if type(path) == "string" and path ~= "" and path:find("[/\\]") and type(line_str) == "string" then
      local resolved_line = tonumber(line_str) or 0
      if resolved_line > 0 then
        return {
          kind = "open_thread_fix_diff",
          path = path,
          line = resolved_line,
          original_line = resolved_line,
          side = "head",
        }
      end
    end
  end

  return nil
end

local function switch_tab(view, index)
  if index < 1 or index > #view.tabs then
    return
  end
  local next_tab = view.tabs[index]
  if next_tab == view.current_tab then
    return
  end

  save_cursor(view)
  view.current_tab = next_tab
  refresh_view(view)
end

local function shift_tab(view, step)
  local current = renderer.tab_index(view, view.current_tab)
  local next_index = ((current - 1 + step) % #view.tabs) + 1
  switch_tab(view, next_index)
end

local function run_more_current(view)
  local tab_def = renderer.TAB_DEFS[view.current_tab]
  if tab_def and tab_def.section then
    if type(view.callbacks.more_section) == "function" then
      view.callbacks.more_section(tab_def.section)
    end
    return
  end

  if view.current_tab == "summary" and type(view.callbacks.more_section) == "function" then
    local show = type(view.show) == "table" and view.show or {}
    if show.timeline == false then
      return
    end
    if show.comments == false
      and show.reviews == false
      and show.threads == false
      and show.commits == false
      and show.pr_changes == false then
      return
    end
    view.callbacks.more_section("timeline")
  end
end

local function trigger_edit(view, edit_kind, payload)
  if type(view.callbacks.edit_stub) ~= "function" then
    return
  end
  view.callbacks.edit_stub(edit_kind, payload or {})
end

local function map(bufnr, lhs, rhs, desc)
  vim.keymap.set("n", lhs, rhs, {
    buffer = bufnr,
    silent = true,
    desc = desc,
  })
end

local function ensure_keymaps(view)
  if view.keymaps_set then
    return
  end
  view.keymaps_set = true

  local bufnr = view.bufnr
  local function with_view(fn)
    return function()
      local current = views[bufnr]
      if current then
        fn(current)
      end
    end
  end

  map(bufnr, "a", function()
    if type(view.callbacks.approve) == "function" then
      view.callbacks.approve()
    end
  end, "GH PR Overview: approve")

  map(bufnr, "d", function()
    if type(view.callbacks.request_changes) == "function" then
      view.callbacks.request_changes()
    end
  end, "GH PR Overview: request changes")

  map(bufnr, "c", function()
    if type(view.callbacks.comment) == "function" then
      view.callbacks.comment()
    end
  end, "GH PR Overview: comment")

  map(bufnr, "m", function()
    if type(view.callbacks.merge) == "function" then
      view.callbacks.merge()
    end
  end, "GH PR Overview: merge")

  map(bufnr, "k", function()
    if type(view.callbacks.checkout) == "function" then
      view.callbacks.checkout()
    end
  end, "GH PR Overview: checkout")

  map(bufnr, "R", function()
    if type(view.callbacks.refresh) == "function" then
      view.callbacks.refresh()
    end
  end, "GH PR Overview: refresh")

  map(bufnr, "b", function()
    if type(view.callbacks.open_url) == "function" then
      view.callbacks.open_url()
    end
  end, "GH PR Overview: open PR in browser")

  map(bufnr, "C", function()
    if type(view.callbacks.open_comments_tree) == "function" then
      view.callbacks.open_comments_tree()
    end
  end, "GH PR Overview: open comments tree")

  map(bufnr, ",x", function()
    if type(view.callbacks.toggle_review_tree) == "function" then
      view.callbacks.toggle_review_tree()
    end
  end, "GH PR Overview: toggle PR Review source")

  map(bufnr, "q", with_view(function(current)
    if type(current.callbacks.close) == "function" then
      current.callbacks.close()
      return
    end
    if utils.valid_win(current.winid) then
      pcall(vim.api.nvim_win_close, current.winid, true)
    end
    if utils.valid_buf(current.bufnr) then
      pcall(vim.api.nvim_buf_delete, current.bufnr, { force = false })
    end
  end), "GH PR Overview: close")

  map(bufnr, "H", with_view(function(current)
    shift_tab(current, -1)
  end), "GH PR Overview: previous tab")

  map(bufnr, "L", with_view(function(current)
    shift_tab(current, 1)
  end), "GH PR Overview: next tab")

  map(bufnr, "<CR>", with_view(function(current)
    execute_action(current, current_action(current), "default")
  end), "GH PR Overview: open selection")

  map(bufnr, "D", with_view(function(current)
    execute_action(current, current_action(current), "default")
  end), "GH PR Overview: open diff for selection")

  map(bufnr, "O", with_view(function(current)
    execute_action(current, current_action(current), "original")
  end), "GH PR Overview: open original file")

  map(bufnr, "M", with_view(function(current)
    execute_action(current, current_action(current), "modified")
  end), "GH PR Overview: open modified file")

  local preview_key = type(view.markdown.link_preview_keymap) == "string" and view.markdown.link_preview_keymap or "gp"
  if preview_key ~= "" then
    map(bufnr, preview_key, with_view(function(current)
      local action = current_action(current, { include_inline = true, inline_only = true })
      if type(action) ~= "table" or action.kind ~= "markdown_link" then
        vim.notify("No markdown link found under cursor", vim.log.levels.WARN)
        return
      end
      execute_action(current, action, "default")
    end), "GH PR Overview: preview markdown link")
  end

  local fix_diff_key = ""
  if type(view.thread_fix_diff) == "table" and view.thread_fix_diff.enabled ~= false then
    fix_diff_key = type(view.thread_fix_diff.keymap) == "string" and view.thread_fix_diff.keymap or "gf"
  end
  if fix_diff_key ~= "" then
    map(bufnr, fix_diff_key, with_view(function(current)
      local action = resolve_thread_fix_action(current)
      if type(action) ~= "table" or action.kind ~= "open_thread_fix_diff" then
        vim.notify("No thread fix diff action available under cursor", vim.log.levels.WARN)
        return
      end
      execute_action(current, action, "default")
    end), "GH PR Overview: open thread fix diff")
  end

  map(bufnr, "gr", with_view(function(current)
    run_more_current(current)
  end), "GH PR Overview: load more")

  map(bufnr, "et", with_view(function(current)
    trigger_edit(current, "edit_title", { current = current.model.title })
  end), "GH PR Overview: edit title")

  map(bufnr, "eb", with_view(function(current)
    trigger_edit(current, "edit_body", { current = current.model.description })
  end), "GH PR Overview: edit description")

  map(bufnr, "el", with_view(function(current)
    trigger_edit(current, "edit_labels", {})
  end), "GH PR Overview: edit labels")

  map(bufnr, "er", with_view(function(current)
    trigger_edit(current, "edit_reviewers", {})
  end), "GH PR Overview: edit reviewers")

  map(bufnr, "ea", with_view(function(current)
    trigger_edit(current, "edit_assignees", {})
  end), "GH PR Overview: edit assignees")

  map(bufnr, "em", with_view(function(current)
    trigger_edit(current, "edit_milestone", {
      current = utils.safe_string(current.model.summary and current.model.summary.milestone, ""),
    })
  end), "GH PR Overview: edit milestone")

  map(bufnr, "es", with_view(function(current)
    trigger_edit(current, "change_state", {
      current = utils.safe_string(current.model.summary and current.model.summary.state, ""),
    })
  end), "GH PR Overview: change state")

  map(bufnr, "ed", with_view(function(current)
    trigger_edit(current, "change_draft", {
      current = current.model.summary and current.model.summary.is_draft and "draft" or "ready",
    })
  end), "GH PR Overview: toggle draft status")

  for index = 1, 9 do
    local target_index = index
    map(bufnr, tostring(index), with_view(function(current)
      switch_tab(current, target_index)
    end), "GH PR Overview: go to tab " .. tostring(target_index))
  end
end

local function open_window(Snacks, view)
  local overview_ft = overview_buffer_filetype(view)
  utils.ensure_buffer_options(view.bufnr, { filetype = overview_ft })

  local spec = {
    show = true,
    buf = view.bufnr,
    enter = view.window.enter,
    fixbuf = true,
    keys = { q = false },
    bo = {
      buftype = "nofile",
      bufhidden = "wipe",
      swapfile = false,
      modifiable = false,
      filetype = overview_ft,
    },
    wo = {
      number = false,
      relativenumber = false,
      signcolumn = "no",
      wrap = true,
      linebreak = true,
      breakindent = true,
      cursorline = true,
      foldcolumn = "0",
      spell = false,
    },
  }

  if view.window.enabled then
    local width, height = utils.resolve_float_size(view.window)
    spec.position = "float"
    spec.width = width
    spec.height = height
    spec.border = view.window.border == "none" and "none" or view.window.border
    spec.backdrop = view.window.backdrop
  else
    utils.ensure_navigation_window()
    spec.position = "current"
  end

  local ok, win = pcall(Snacks.win, spec)
  if not ok then
    vim.notify("gh-pr overview: unable to open snacks window, using current window", vim.log.levels.WARN)
    utils.ensure_navigation_window()
    pcall(vim.api.nvim_set_current_buf, view.bufnr)
    local fallback = vim.api.nvim_get_current_win()
    utils.ensure_window_options(fallback)
    view.winid = fallback
    return
  end

  local winid
  if type(win) == "table" then
    winid = tonumber(win.win) or tonumber(win.winid)
  elseif type(win) == "number" then
    winid = win
  end
  if not utils.valid_win(winid) then
    winid = utils.current_win_for_buf(view.bufnr)
  end
  utils.ensure_window_options(winid)
  view.winid = winid
end

function M.open(model, opts)
  opts = opts or {}
  model = type(model) == "table" and model or {}

  styles.ensure_base_highlights()

  local Snacks = require("snacks")
  local bufnr = utils.ensure_overview_buffer(model.number, opts.bufnr)
  if not utils.valid_buf(bufnr) then
    bufnr = utils.ensure_overview_buffer(model.number, nil)
  end
  if not utils.valid_buf(bufnr) then
    error("Unable to create gh-pr overview buffer")
  end

  local tabs = renderer.sanitize_tabs(opts.tabs, opts.show)
  local callbacks = type(opts.actions) == "table" and opts.actions or {}

  local view = views[bufnr] or {
    bufnr = bufnr,
    tabs = tabs,
    current_tab = tabs[1],
    cursor_by_tab = {},
    activity_folds = {},
    thread_fix_inline = {},
    line_actions = {},
    inline_actions = {},
    keymaps_set = false,
    cleanup_registered = false,
  }

  view.bufnr = bufnr
  view.tabs = tabs
  view.activity_folds = type(view.activity_folds) == "table" and view.activity_folds or {}
  view.thread_fix_inline = type(view.thread_fix_inline) == "table" and view.thread_fix_inline or {}
  view.current_tab = renderer.TAB_ALIASES[view.current_tab] or view.current_tab
  if not renderer.TAB_DEFS[view.current_tab] or not tab_exists(tabs, view.current_tab) then
    view.current_tab = tabs[1]
  end
  view.model = model
  view.callbacks = callbacks
  view.show = type(opts.show) == "table" and vim.deepcopy(opts.show) or {}
  view.date_format = utils.safe_string(opts.date_format, "%Y-%m-%d %H:%M")
  view.window = utils.sanitize_window_opts(opts.window)
  view.theme = utils.sanitize_theme_opts(opts.theme)
  view.markdown = utils.sanitize_markdown_opts(opts.markdown)
  view.thread_snippet = utils.sanitize_thread_snippet_opts(opts.thread_snippet)
  view.thread_fix_diff = utils.sanitize_thread_fix_diff_opts(opts.thread_fix_diff)

  if type(opts.cursor_line) == "number" then
    view.cursor_by_tab[view.current_tab] = math.max(1, math.floor(opts.cursor_line))
  end

  callbacks.close = callbacks.close or function()
    local current = views[bufnr]
    if current and utils.valid_win(current.winid) then
      pcall(vim.api.nvim_win_close, current.winid, true)
    end
    if utils.valid_buf(bufnr) then
      pcall(vim.api.nvim_buf_delete, bufnr, { force = false })
    end
  end

  views[bufnr] = view

  open_window(Snacks, view)
  ensure_keymaps(view)
  refresh_view(view)

  if not view.cleanup_registered then
    view.cleanup_registered = true
    vim.api.nvim_create_autocmd({ "BufWipeout", "BufDelete" }, {
      buffer = bufnr,
      once = true,
      callback = function()
        views[bufnr] = nil
      end,
    })
  end
end

return M
