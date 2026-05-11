local M = {}
local url_open = require("gh-pr.url_open")

local function valid_overview_sections()
  return {
    checks = true,
    commits = true,
    timeline = true,
  }
end

local function normalize_overview_limits(input, ctx)
  local overview_config = (ctx.config.get() or {}).overview or {}
  local defaults = overview_config.max_items or {}
  local positive_integer = ctx.positive_integer
  local limits = type(input) == "table" and vim.deepcopy(input) or {}

  limits.checks = positive_integer(limits.checks, positive_integer(defaults.checks, 10))
  limits.commits = positive_integer(limits.commits, positive_integer(defaults.commits, 10))
  limits.timeline = positive_integer(
    limits.timeline,
    positive_integer(defaults.timeline, math.max(positive_integer(defaults.comments, 30), positive_integer(defaults.reviews, 30)))
  )
  limits.comments = positive_integer(limits.comments, limits.timeline)
  limits.reviews = positive_integer(limits.reviews, limits.timeline)
  limits.threads = positive_integer(limits.threads, limits.timeline)
  limits.timeline = math.max(limits.timeline, limits.comments, limits.reviews, limits.threads)

  return limits
end

local function current_overview_limits(ctx)
  local bufnr = vim.api.nvim_get_current_buf()
  local stored = vim.b[bufnr].gh_pr_overview_limits
  return normalize_overview_limits(type(stored) == "table" and stored or nil, ctx)
end

local function notify_error(ctx, message, silent)
  if silent == true then
    return
  end
  return ctx.notify_error(message)
end

local function runtime_module()
  return require("gh-pr.ui.overview.runtime")
end

local function build_overview_callbacks(pr_number, ctx)
  local actions = ctx.actions
  return {
    approve = function()
      actions.review("approve")
    end,
    request_changes = function()
      actions.review("request_changes")
    end,
    comment = function()
      actions.review("comment")
    end,
    merge = function()
      actions.merge()
    end,
    checkout = function()
      actions.checkout(pr_number)
    end,
    refresh = function()
      actions.refresh_overview()
    end,
    open_url = function()
      actions.open_overview_url(pr_number)
    end,
    open_comments_tree = function()
      actions.open_comments(pr_number)
    end,
    edit_stub = function(kind, payload)
      actions.overview_edit_stub(kind, payload)
    end,
    rerequest_reviewer = function(payload)
      actions.overview_edit_stub("rerequest_reviewer", payload)
    end,
    more_section = function(section)
      actions.overview_more(section)
    end,
    open_location = function(target)
      actions.open_comment_location(target)
    end,
    open_commit_diff = function(commit)
      actions.open_commit_diff(commit)
    end,
    open_file_diff = function(file)
      actions.open_diff(file)
    end,
    open_file_original = function(file)
      actions.open_original(file)
    end,
    open_file_modified = function(file)
      actions.open_modified(file)
    end,
    open_thread_fix_diff = function(payload)
      actions.open_thread_fix_diff(payload)
    end,
    open_thread_comment_evolution_diff = function(payload)
      actions.open_thread_comment_evolution_diff(payload)
    end,
    open_thread_comment_commit_diff = function(payload)
      actions.open_thread_comment_commit_diff(payload)
    end,
    resolve_thread_fix_diff = function(payload, options)
      return actions.resolve_thread_fix_diff(payload, options)
    end,
    preview_markdown_link = function(action)
      actions.overview_preview_markdown_link(action)
    end,
    open_activity_thread_workspace = function(payload)
      actions.open_overview_thread_workspace(payload)
    end,
    toggle_review_tree = function()
      actions.toggle_review_tree()
    end,
  }
end

local function overview_session_id(bufnr)
  return tonumber(vim.b[bufnr].gh_pr_overview_session)
end

local function overview_is_primary(bufnr)
  return vim.b[bufnr].gh_pr_overview_primary == true
end

function M.build_overview_model(number, opts, ctx)
  opts = opts or {}
  local pr, details, err = ctx.resolve_active_pr(number, { refresh = opts.refresh == true })
  if not pr then
    return nil, nil, err
  end

  local limits = normalize_overview_limits(opts.overview_limits, ctx)
  local threads, thread_err = ctx.pr_service.fetch_review_threads(pr.number, {
    threads_first = limits.threads,
    comments_first = math.min(100, limits.threads * 4),
  })
  if not threads then
    threads = {}
  end

  local repository = ctx.normalize_repository(details) or ""
  local pr_change_events, pr_change_err = ctx.pr_service.fetch_pr_change_events(pr.number, {
    repository = repository,
    pr_url = type(details.url) == "string" and details.url or "",
    max_items = math.min(500, math.max(100, limits.timeline * 4)),
    max_pages = 5,
  })
  if not pr_change_events then
    pr_change_events = {}
  end

  local model = ctx.pr_service.build_overview_model(details, threads, limits, {
    repository = repository,
    thread_error = thread_err,
    pr_change_events = pr_change_events,
    pr_change_error = pr_change_err,
  })
  return pr, model, nil
end

local function build_overview_model_async(number, opts, ctx, callback)
  opts = type(opts) == "table" and opts or {}
  callback = callback or function() end

  if type(ctx.pr_service.fetch_details_async) ~= "function" then
    local pr, model, err = M.build_overview_model(number, opts, ctx)
    callback(pr, model, err)
    return
  end

  local current_pr, _, resolve_err = ctx.resolve_active_pr(number, { refresh = false })
  if not current_pr then
    callback(nil, nil, resolve_err)
    return
  end

  local limits = normalize_overview_limits(opts.overview_limits, ctx)
  ctx.pr_service.fetch_details_async(current_pr.number, function(details, details_err)
    if not details then
      callback(nil, nil, details_err)
      return
    end

    if type(ctx.set_active_pr) == "function" then
      ctx.set_active_pr(details, details)
    end

    local pr = {
      number = tonumber(details.number) or current_pr.number,
      url = details.url,
    }
    local repository = ctx.normalize_repository(details) or ""
    local threads = {}
    local pr_change_events = {}
    local thread_err = nil
    local pr_change_err = nil
    local pending = 2

    local function complete()
      pending = pending - 1
      if pending > 0 then
        return
      end

      local model = ctx.pr_service.build_overview_model(details, threads, limits, {
        repository = repository,
        thread_error = thread_err,
        pr_change_events = pr_change_events,
        pr_change_error = pr_change_err,
      })
      callback(pr, model, nil)
    end

    if type(ctx.pr_service.fetch_review_threads_async) == "function" then
      ctx.pr_service.fetch_review_threads_async(pr.number, {
        threads_first = limits.threads,
        comments_first = math.min(100, limits.threads * 4),
      }, function(result, err)
        threads = type(result) == "table" and result or {}
        thread_err = err
        complete()
      end)
    else
      local result, err = ctx.pr_service.fetch_review_threads(pr.number, {
        threads_first = limits.threads,
        comments_first = math.min(100, limits.threads * 4),
      })
      threads = type(result) == "table" and result or {}
      thread_err = err
      complete()
    end

    local fetch_pr_changes_async = ctx.pr_service.fetch_pr_change_events_async
    local pr_changes_opts = {
      repository = repository,
      pr_url = type(details.url) == "string" and details.url or "",
      max_items = math.min(500, math.max(100, limits.timeline * 4)),
      max_pages = 5,
    }

    if type(fetch_pr_changes_async) == "function" then
      fetch_pr_changes_async(pr.number, pr_changes_opts, function(events, err)
        pr_change_events = type(events) == "table" and events or {}
        pr_change_err = err
        complete()
      end)
      return
    end

    local events, events_err = ctx.pr_service.fetch_pr_change_events(pr.number, pr_changes_opts)
    pr_change_events = type(events) == "table" and events or {}
    pr_change_err = events_err
    complete()
  end)
end

local function runtime_open_overview(model, pr_number, opts, ctx)
  local plugin_config = ctx.config.get() or {}
  local overview_config = plugin_config.overview or {}
  local panes_config = type(overview_config.panes) == "table" and overview_config.panes or {}
  local session_id = tonumber(opts.session_id) or nil
  local window_opts = type(overview_config.window) == "table" and vim.deepcopy(overview_config.window) or {}
  if type(opts.enter) == "boolean" then
    window_opts.enter = opts.enter
  end

  return runtime_module().open(model, {
    session_id = session_id,
    focus_role = type(opts.focus_role) == "string" and opts.focus_role or nil,
    window = window_opts,
    layout = panes_config.layout or {},
    keymaps = panes_config.keymaps or {},
    activity = panes_config.activity or {},
    show = overview_config.show or {},
    date_format = overview_config.date_format or "%Y-%m-%d %H:%M",
    theme = overview_config.theme or {},
    markdown = overview_config.markdown or {},
    thread_snippet = overview_config.thread_snippet or {},
    thread_fix_diff = overview_config.thread_fix_diff or {},
    actions = build_overview_callbacks(pr_number, ctx),
  })
end

local function start_async_silent_refresh(pr_number, session_id, opts, ctx)
  local async_opts = vim.deepcopy(type(opts) == "table" and opts or {})
  async_opts.refresh = true
  async_opts.silent = true
  async_opts.enter = false
  async_opts.session_id = session_id
  async_opts.refresh_mode = "sync"
  async_opts.prefer_existing = false

  build_overview_model_async(pr_number, async_opts, ctx, function(async_pr, async_model, async_err)
    if not async_pr or not async_model then
      notify_error(ctx, async_err, true)
      return
    end
    runtime_open_overview(async_model, async_pr.number, async_opts, ctx)
  end)
end

local function open_overview_impl(number, opts, ctx)
  opts = type(opts) == "table" and opts or {}
  local silent = opts.silent == true
  local prefer_existing = opts.prefer_existing == true
  local refresh_mode = type(opts.refresh_mode) == "string" and opts.refresh_mode or "sync"
  local runtime = runtime_module()

  local pr, _, resolve_err = ctx.resolve_active_pr(number, { refresh = false })
  if not pr then
    return notify_error(ctx, resolve_err, silent)
  end

  local existing_session_id = runtime.session_id_for_pr(pr.number)
  if not opts.overview_limits and existing_session_id then
    opts.overview_limits = runtime.overview_limits_for_session(existing_session_id)
  end

  if prefer_existing and existing_session_id then
    runtime.focus_for_pr(pr.number, opts.focus_role or "summary")
    if refresh_mode == "async_silent" then
      start_async_silent_refresh(pr.number, existing_session_id, opts, ctx)
    end
    return existing_session_id
  end

  local model_pr, model, build_err = M.build_overview_model(pr.number, opts, ctx)
  if not model_pr then
    return notify_error(ctx, build_err, silent)
  end

  local opened_session_id = runtime_open_overview(model, model_pr.number, opts, ctx)
  if refresh_mode == "async_silent" then
    start_async_silent_refresh(model_pr.number, opened_session_id, opts, ctx)
  end
  return opened_session_id
end

function M.open_overview(number, opts, ctx)
  return open_overview_impl(number, opts, ctx)
end

function M.refresh_overview(ctx)
  local bufnr = vim.api.nvim_get_current_buf()
  local number = vim.b[bufnr].gh_pr_number
  if type(number) ~= "number" then
    return ctx.notify_error("Current buffer is not a gh-pr overview")
  end

  ctx.actions.open_overview(number, {
    refresh = true,
    session_id = overview_session_id(bufnr),
    overview_limits = current_overview_limits(ctx),
  })
end

function M.refresh_visible_overview_for_pr(number, ctx)
  local pr_number = tonumber(number)
  if not pr_number then
    return 0
  end

  local session_id = nil
  local limits = nil

  for _, tabpage in ipairs(vim.api.nvim_list_tabpages()) do
    for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(tabpage)) do
      if ctx.is_valid_win(winid) then
        local bufnr = vim.api.nvim_win_get_buf(winid)
        local overview_ui = vim.b[bufnr].gh_pr_overview_ui
        local is_overview = overview_ui == "panes" and overview_is_primary(bufnr)
        if ctx.is_valid_buf(bufnr) and is_overview and tonumber(vim.b[bufnr].gh_pr_number) == pr_number then
          session_id = overview_session_id(bufnr)
          limits = type(vim.b[bufnr].gh_pr_overview_limits) == "table"
              and vim.deepcopy(vim.b[bufnr].gh_pr_overview_limits)
            or nil
          break
        end
      end
    end
    if session_id then
      break
    end
  end

  if not session_id then
    return 0
  end

  start_async_silent_refresh(pr_number, session_id, {
    session_id = session_id,
    overview_limits = limits,
    enter = false,
  }, ctx)
  return 1
end

function M.overview_more(section, count, ctx)
  section = type(section) == "string" and section:lower() or ""
  if section == "comments" or section == "reviews" or section == "threads" then
    section = "timeline"
  end
  if not valid_overview_sections()[section] then
    return ctx.notify_error("Section must be one of: checks, commits, timeline")
  end

  local bufnr = vim.api.nvim_get_current_buf()
  local number = vim.b[bufnr].gh_pr_number
  if type(number) ~= "number" then
    return ctx.notify_error("Current buffer is not a gh-pr overview")
  end

  local overview_config = (ctx.config.get() or {}).overview or {}
  local positive_integer = ctx.positive_integer
  local step = positive_integer(count, positive_integer(overview_config.expand_step, 20))
  local limits = current_overview_limits(ctx)
  if section == "timeline" then
    limits.timeline = positive_integer(limits.timeline, step) + step
    limits.comments = limits.timeline
    limits.reviews = limits.timeline
    limits.threads = limits.timeline
  else
    limits[section] = positive_integer(limits[section], step) + step
  end

  ctx.actions.open_overview(number, {
    refresh = true,
    session_id = overview_session_id(bufnr),
    overview_limits = limits,
  })
end

function M.open_overview_url(number, ctx)
  local pr, _, err = ctx.resolve_active_pr(number)
  if not pr then
    return ctx.notify_error(err)
  end

  local ok, open_err = ctx.pr_service.open_in_browser(pr.number)
  if not ok then
    if type(pr.url) == "string" and pr.url ~= "" then
      local opened, url_err = url_open.open(pr.url, {
        notify_error = false,
      })
      if opened then
        return
      end
      return ctx.notify_error(string.format(
        "%s | URL open failed: %s",
        tostring(open_err or "Unable to open PR URL"),
        tostring(url_err or "unknown error")
      ))
    end
    return ctx.notify_error(open_err)
  end
end

return M
