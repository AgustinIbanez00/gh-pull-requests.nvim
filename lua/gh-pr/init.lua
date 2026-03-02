local M = {}

local actions = require("gh-pr.actions")
local config = require("gh-pr.config")
local queries = require("gh-pr.queries")
local repo = require("gh-pr.repo")
local runtime_state = require("gh-pr.state")
local uv = vim.uv or vim.loop

local auto_refresh_timer = nil
local follow_current_file_seq = 0
local configured_neotree_sources = {}

local function notify_error(message)
  vim.notify(message, vim.log.levels.ERROR)
end

local function notify_info(message)
  vim.notify(message, vim.log.levels.INFO)
end

local function with_telescope(handler_name, opts)
  local ok, telescope = pcall(require, "gh-pr.telescope")
  if not ok then
    notify_error("Unable to load Telescope fallback")
    return false
  end

  local handler = telescope[handler_name]
  if type(handler) ~= "function" then
    notify_error("Telescope fallback action is not available: " .. tostring(handler_name))
    return false
  end

  handler(opts)
  return true
end

local function open_telescope_fallback()
  with_telescope("pull_requests")
end

local function ensure_neotree_source(source_name, source_module_name)
  local nt_ok, neo_tree = pcall(require, "neo-tree")
  if not nt_ok then
    return false
  end

  neo_tree.ensure_config()

  source_name = source_name or "gh_pr"
  source_module_name = source_module_name or source_name

  if type(neo_tree.config[source_name]) ~= "table" then
    neo_tree.config[source_name] = {}
  end

  neo_tree.config[source_name].name = source_name
  neo_tree.config[source_name].window = neo_tree.config[source_name].window or {}
  neo_tree.config[source_name].window.position = neo_tree.config[source_name].window.position or "left"

  local found_source = false
  for _, source in ipairs(neo_tree.config.sources or {}) do
    if source == source_name then
      found_source = true
      break
    end
  end

  if not found_source then
    table.insert(neo_tree.config.sources, source_name)
  end

  if type(neo_tree.config.source_selector) == "table" and type(neo_tree.config.source_selector.sources) == "table" then
    local selector_sources = neo_tree.config.source_selector.sources
    local has_selector_source = false
    for _, item in ipairs(selector_sources) do
      if item == source_name then
        has_selector_source = true
        break
      end
      if type(item) == "table" and item.source == source_name then
        has_selector_source = true
        break
      end
    end
    if not has_selector_source then
      local display_map = {
        gh_pr = "  PR ",
        gh_pr_comments = "  Comments ",
        gh_pr_review = "  PR Review ",
      }
      local display_name = display_map[source_name] or ("  " .. tostring(source_name) .. " ")
      table.insert(selector_sources, { source = source_name, display_name = display_name })
    end
  end

  local manager_ok, manager = pcall(require, "neo-tree.sources.manager")
  if not manager_ok then
    return false
  end

  local source_ok, source_module = pcall(require, source_module_name)
  if not source_ok then
    notify_error("Unable to load " .. source_name .. " Neo-tree source")
    return false
  end

  if configured_neotree_sources[source_name] then
    return true
  end

  local setup_ok, setup_err = pcall(manager.setup, source_name, neo_tree.config[source_name], neo_tree.config, source_module)
  if not setup_ok then
    notify_error("Failed to setup " .. source_name .. " Neo-tree source: " .. tostring(setup_err))
    return false
  end

  configured_neotree_sources[source_name] = true
  return true
end

local function open_neotree(source_name, source_module_name, opts)
  opts = opts or {}
  source_name = source_name or "gh_pr"
  source_module_name = source_module_name or source_name

  if not ensure_neotree_source(source_name, source_module_name) then
    return false
  end

  local ok, command = pcall(require, "neo-tree.command")
  if not ok then
    return false
  end

  local status, err = pcall(command.execute, {
    source = source_name,
    toggle = opts.toggle ~= false,
    reveal = false,
    position = "left",
  })

  if not status then
    notify_error("Neo-tree source failed: " .. tostring(err))
    return false
  end

  return true
end

local function open_default_view()
  if not repo.ensure_git_repo() then
    return
  end

  local options = config.get()
  if options.ui.use_neotree and open_neotree("gh_pr", "gh_pr") then
    return
  end

  if options.ui.telescope_fallback then
    open_telescope_fallback()
    return
  end

  notify_error("No UI backend available. Enable neo-tree source or Telescope fallback")
end

local function open_comments_view(number)
  if not repo.ensure_git_repo() then
    return
  end

  pcall(function()
    require("gh-pr.neotree.comments_source").invalidate_cache()
  end)

  if number ~= nil then
    local _, _, activate_err = actions.activate_review(number, { refresh = true })
    if activate_err then
      notify_error(activate_err)
      return
    end
  else
    local active_pr, active_details = runtime_state.get_active_pr()
    if active_pr and active_details then
      actions.set_active_review(active_pr, active_details)
    end
  end

  open_neotree("gh_pr_review", "gh_pr_review", { toggle = false })
end

local function open_review_view(opts)
  opts = opts or {}
  if not repo.ensure_git_repo() then
    return false
  end

  return open_neotree("gh_pr_review", "gh_pr_review", {
    toggle = opts.toggle ~= false,
  })
end

local function refresh_views()
  local source_ok, source = pcall(require, "gh-pr.neotree.source")
  if source_ok and type(source.request_refresh) == "function" then
    pcall(source.request_refresh, nil, { force = true, notify_error = false })
  end

  local manager_ok, manager = pcall(require, "neo-tree.sources.manager")
  if manager_ok then
    pcall(manager.refresh, "gh_pr_review")
  end

  local review_ok, review_source = pcall(require, "gh-pr.neotree.review_source")
  if review_ok and type(review_source.request_refresh) == "function" then
    pcall(review_source.request_refresh, nil, { force = true, notify_error = false })
  end
end

local function stop_auto_refresh_timer()
  if auto_refresh_timer then
    auto_refresh_timer:stop()
    auto_refresh_timer:close()
    auto_refresh_timer = nil
  end
end

local function start_auto_refresh_timer()
  stop_auto_refresh_timer()

  local cache_config = ((config.get() or {}).cache or {})
  local gh_pr_cache_options = type(cache_config.gh_pr) == "table" and cache_config.gh_pr or {}
  local gh_pr_review_cache_options = type(cache_config.gh_pr_review) == "table" and cache_config.gh_pr_review or {}

  local gh_pr_enabled = gh_pr_cache_options.auto_refresh_when_focused ~= false
  local gh_pr_review_enabled = gh_pr_review_cache_options.auto_refresh_when_focused ~= false
  if not gh_pr_enabled and not gh_pr_review_enabled then
    return
  end

  local intervals = {}
  if gh_pr_enabled then
    intervals[#intervals + 1] = tonumber(gh_pr_cache_options.ttl_seconds) or 60
  end
  if gh_pr_review_enabled then
    intervals[#intervals + 1] = tonumber(gh_pr_review_cache_options.ttl_seconds) or 60
  end

  local interval = intervals[1] or 60
  for index = 2, #intervals do
    interval = math.min(interval, intervals[index])
  end
  interval = math.max(1, math.floor(interval))

  if not uv or type(uv.new_timer) ~= "function" then
    return
  end

  auto_refresh_timer = uv.new_timer()
  if not auto_refresh_timer then
    return
  end

  local interval_ms = interval * 1000
  auto_refresh_timer:start(interval_ms, interval_ms, vim.schedule_wrap(function()
    local source_ok, source = pcall(require, "gh-pr.neotree.source")
    if gh_pr_enabled and source_ok and type(source.request_refresh) == "function" then
      local focused = type(source.is_focused) == "function" and source.is_focused() == true
      pcall(source.request_refresh, nil, {
        force = false,
        notify_error = false,
        refresh_context = {
          mode = focused and "ui-refresh" or "cache-only",
          reason = "timer",
          notify = focused,
        },
      })
    end

    local review_ok, review_source = pcall(require, "gh-pr.neotree.review_source")
    if gh_pr_review_enabled and review_ok and type(review_source.request_refresh) == "function" then
      local focused = type(review_source.is_focused) == "function" and review_source.is_focused() == true
      pcall(review_source.request_refresh, nil, {
        force = false,
        notify_error = false,
        refresh_context = {
          mode = focused and "ui-refresh" or "cache-only",
          reason = "timer",
          notify = focused,
        },
      })
    end
  end))
end

local function follow_current_file_options()
  local options = (config.get() or {}).follow_current_file or {}
  local sources = type(options.sources) == "table" and options.sources or {}
  local debounce_ms = tonumber(options.debounce_ms)
  if type(debounce_ms) ~= "number" then
    debounce_ms = 60
  end
  debounce_ms = math.max(0, math.floor(debounce_ms))

  return {
    enabled = options.enabled ~= false,
    debounce_ms = debounce_ms,
    source_pr = sources.pr ~= false,
    source_pr_review = sources.pr_review ~= false,
  }
end

local function schedule_follow_current_file()
  local options = follow_current_file_options()
  if not options.enabled then
    return
  end

  follow_current_file_seq = follow_current_file_seq + 1
  local token = follow_current_file_seq
  vim.defer_fn(function()
    if token ~= follow_current_file_seq then
      return
    end

    local review_visible = false
    if options.source_pr_review then
      local review_ok, review_source = pcall(require, "gh-pr.neotree.review_source")
      if review_ok and type(review_source.follow_current_file_if_visible) == "function" then
        local ok, visible = pcall(review_source.follow_current_file_if_visible, { reason = "autocmd" })
        review_visible = ok and visible == true
      end
    end

    if not review_visible and options.source_pr then
      local source_ok, source = pcall(require, "gh-pr.neotree.source")
      if source_ok and type(source.follow_current_file_if_visible) == "function" then
        pcall(source.follow_current_file_if_visible, { reason = "autocmd" })
      end
    end
  end, options.debounce_ms)
end

local function prompt(text, default)
  return vim.fn.input(text, default or "")
end

local function add_query()
  local folder = prompt("Folder: ", "General")
  if folder == "" then
    return
  end

  local label = prompt("Label: ", "New Query")
  if label == "" then
    return
  end

  local query = prompt("Query: ", "is:open")
  if query == "" then
    return
  end

  queries.add({ folder = folder, label = label, query = query })
  notify_info("Query added")
  refresh_views()
end

local function select_query(callback)
  local current = queries.list()
  if vim.tbl_isempty(current) then
    notify_error("No queries configured")
    return
  end

  vim.ui.select(current, {
    prompt = "Select query",
    format_item = function(item)
      return string.format("%s / %s", item.folder, item.label)
    end,
  }, function(selected)
    if not selected then
      return
    end

    callback(selected)
  end)
end

local function edit_query()
  select_query(function(selected)
    local folder = prompt("Folder: ", selected.folder)
    if folder == "" then
      return
    end

    local label = prompt("Label: ", selected.label)
    if label == "" then
      return
    end

    local query = prompt("Query: ", selected.query)
    if query == "" then
      return
    end

    queries.update(selected.id, {
      folder = folder,
      label = label,
      query = query,
    })

    notify_info("Query updated")
    refresh_views()
  end)
end

local function delete_query()
  select_query(function(selected)
    local ok = queries.delete(selected.id)
    if ok then
      notify_info("Query deleted")
      refresh_views()
    end
  end)
end

function M.setup(opts)
  config.setup(opts or {})
  runtime_state.setup()
  queries.setup((opts or {}).queries ~= nil)
  start_auto_refresh_timer()

  local group = vim.api.nvim_create_augroup("GhPrAutoRefresh", { clear = true })
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = stop_auto_refresh_timer,
  })
  vim.api.nvim_create_autocmd({ "BufEnter", "WinEnter" }, {
    group = group,
    callback = schedule_follow_current_file,
  })
end

function M.open_pull_requests()
  open_default_view()
end

function M.open_telescope()
  open_telescope_fallback()
end

function M.open_telescope_actions(opts)
  with_telescope("open_context_actions", opts or {})
end

function M.open_telescope_review_actions(opts)
  with_telescope("open_review_actions", opts or {})
end

function M.open_comments(number)
  open_comments_view(number)
end

function M.open_review_tree(opts)
  opts = opts or {}
  return open_review_view(opts)
end

function M.start_review(number)
  actions.start_review(number)
end

function M.refresh()
  refresh_views()
  notify_info("Refreshed gh-pr views")
end

function M.refresh_review()
  local ok_source, review_source = pcall(require, "gh-pr.neotree.review_source")
  if not ok_source or type(review_source.request_refresh) ~= "function" then
    notify_error("Unable to load PR Review source refresh handler")
    return
  end

  local started = review_source.request_refresh(nil, {
    force = true,
    notify_error = true,
    refresh_context = {
      mode = "ui-refresh",
      reason = "manual",
      notify = false,
    },
  })

  if started then
    notify_info("Refreshing PR Review in background...")
    return
  end

  local repo_ok, pr_service = pcall(require, "gh-pr.pr_service")
  if not repo_ok or type(pr_service.resolve_repository) ~= "function" then
    notify_error("Unable to refresh PR Review: no active review for current repository")
    return
  end

  local repository = pr_service.resolve_repository()
  local repo_name = type(repository) == "table" and type(repository.full_name) == "string" and repository.full_name or nil
  if not repo_name or repo_name == "" then
    notify_error("Unable to refresh PR Review: no active review for current repository")
    return
  end

  local review_pr = runtime_state.get_active_review(repo_name)
  if type(review_pr) ~= "table" or type(review_pr.number) ~= "number" then
    notify_error("Unable to refresh PR Review: no active review for current repository")
    return
  end

  notify_info("PR Review refresh is already in progress")
end

function M.add_query()
  add_query()
end

function M.edit_query()
  edit_query()
end

function M.delete_query()
  delete_query()
end

function M.open_overview()
  actions.open_overview()
end

function M.refresh_overview()
  actions.refresh_overview()
end

function M.overview_more(section, count)
  actions.overview_more(section, count)
end

function M.checkout(number)
  actions.checkout(number)
end

function M.open_diff()
  actions.open_diff()
end

function M.open_original()
  actions.open_original()
end

function M.open_modified()
  actions.open_modified()
end

function M.open_commit_patch()
  actions.open_commit_diff()
end

function M.toggle_reviewed()
  actions.toggle_viewed()
end

function M.next_change()
  actions.next_change()
end

function M.prev_change()
  actions.prev_change()
end

function M.approve()
  actions.review("approve")
end

function M.request_changes()
  actions.review("request_changes")
end

function M.comment()
  actions.review("comment")
end

function M.review_submit_pending()
  actions.submit_pending_comment_review()
end

function M.review_approve_pending()
  actions.submit_pending_approve_review()
end

function M.review_request_changes_pending()
  actions.submit_pending_request_changes_review()
end

function M.review_discard_pending()
  actions.discard_pending_review()
end

function M.add_inline_comment()
  actions.add_inline_comment()
end

function M.add_inline_comment_visual()
  actions.add_inline_comment_visual()
end

function M.merge(method)
  actions.merge(method)
end

return M
