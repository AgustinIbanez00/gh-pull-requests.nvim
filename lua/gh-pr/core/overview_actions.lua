local M = {}

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

local function open_overview_impl(number, opts, ctx)
  opts = opts or {}

  local pr, model, err = M.build_overview_model(number, opts, ctx)
  if not pr then
    return ctx.notify_error(err)
  end

  local plugin_config = ctx.config.get() or {}
  local overview_config = plugin_config.overview or {}
  local panes_config = type(overview_config.panes) == "table" and overview_config.panes or {}
  local session_id = tonumber(opts.session_id) or nil

  require("gh-pr.ui.overview.runtime").open(model, {
    session_id = session_id,
    window = overview_config.window or {},
    layout = panes_config.layout or {},
    keymaps = panes_config.keymaps or {},
    activity = panes_config.activity or {},
    show = overview_config.show or {},
    date_format = overview_config.date_format or "%Y-%m-%d %H:%M",
    theme = overview_config.theme or {},
    markdown = overview_config.markdown or {},
    thread_snippet = overview_config.thread_snippet or {},
    actions = build_overview_callbacks(pr.number, ctx),
  })
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

  local current_tab = vim.api.nvim_get_current_tabpage()
  local refreshed = 0
  local refreshed_buffers = {}

  for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(current_tab)) do
    if ctx.is_valid_win(winid) then
      local bufnr = vim.api.nvim_win_get_buf(winid)
      local overview_ui = vim.b[bufnr].gh_pr_overview_ui
      local is_overview = overview_ui == "panes" and overview_is_primary(bufnr)
      if ctx.is_valid_buf(bufnr)
        and not refreshed_buffers[bufnr]
        and is_overview
        and tonumber(vim.b[bufnr].gh_pr_number) == pr_number then
        local limits = type(vim.b[bufnr].gh_pr_overview_limits) == "table" and vim.deepcopy(vim.b[bufnr].gh_pr_overview_limits)
          or nil

        local ok = pcall(vim.api.nvim_win_call, winid, function()
          ctx.actions.open_overview(pr_number, {
            refresh = true,
            session_id = overview_session_id(bufnr),
            overview_limits = limits,
          })
        end)

        if ok then
          refreshed = refreshed + 1
          refreshed_buffers[bufnr] = true
        end
      end
    end
  end

  return refreshed
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
    if vim.ui and type(vim.ui.open) == "function" and type(pr.url) == "string" and pr.url ~= "" then
      vim.ui.open(pr.url)
      return
    end
    return ctx.notify_error(open_err)
  end
end

return M
