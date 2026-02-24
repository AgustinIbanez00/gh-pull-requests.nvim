local M = {}

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

local function attach_buffer_metadata(bufnr, model, view)
  vim.b[bufnr].gh_pr_number = model.number
  vim.b[bufnr].gh_pr_repo = model.repository
  vim.b[bufnr].gh_pr_overview_ui = "snacks"
  vim.b[bufnr].gh_pr_overview_layout = "tabs"
  vim.b[bufnr].gh_pr_overview_tab = view.current_tab
  vim.b[bufnr].gh_pr_overview_limits = vim.deepcopy(model.limits or {})
  vim.b[bufnr].gh_pr_overview_sections = {
    checks = model.checks and model.checks.total or 0,
    commits = model.commits and model.commits.total or 0,
    timeline = model.timeline and model.timeline.total or 0,
    comments = model.comments and model.comments.total or 0,
    reviews = model.reviews and model.reviews.total or 0,
    threads = model.threads and model.threads.total or 0,
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

local function current_action(view)
  local winid = utils.current_win_for_buf(view.bufnr)
  if not winid then
    return nil
  end
  local line = vim.api.nvim_win_get_cursor(winid)[1]
  return view.line_actions[line]
end

local function execute_action(view, action, variant)
  if type(action) ~= "table" then
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
  if not tab_def or not tab_def.section then
    return
  end

  if type(view.callbacks.more_section) == "function" then
    view.callbacks.more_section(tab_def.section)
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

  map(bufnr, "o", function()
    if type(view.callbacks.open_url) == "function" then
      view.callbacks.open_url()
    end
  end, "GH PR Overview: open PR URL")

  map(bufnr, "C", function()
    if type(view.callbacks.open_comments_tree) == "function" then
      view.callbacks.open_comments_tree()
    end
  end, "GH PR Overview: open comments tree")

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
  utils.ensure_buffer_options(view.bufnr)

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
      filetype = "ghpr_overview",
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
    line_actions = {},
    keymaps_set = false,
    cleanup_registered = false,
  }

  view.bufnr = bufnr
  view.tabs = tabs
  view.current_tab = renderer.TAB_ALIASES[view.current_tab] or view.current_tab
  if not renderer.TAB_DEFS[view.current_tab] or not tab_exists(tabs, view.current_tab) then
    view.current_tab = tabs[1]
  end
  view.model = model
  view.callbacks = callbacks
  view.date_format = utils.safe_string(opts.date_format, "%Y-%m-%d %H:%M")
  view.window = utils.sanitize_window_opts(opts.window)
  view.theme = utils.sanitize_theme_opts(opts.theme)
  view.markdown = utils.sanitize_markdown_opts(opts.markdown)

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
