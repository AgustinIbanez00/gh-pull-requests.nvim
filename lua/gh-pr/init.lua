local M = {}

local config = require("gh-pr.config")
local runtime = require("gh-pr.core.runtime")

local user_config_applied = false
local skip_query_file_load = false

local function notify_error(message)
  vim.notify(message, vim.log.levels.ERROR)
end

local function notify_info(message)
  vim.notify(message, vim.log.levels.INFO)
end

local function get_actions()
  return require("gh-pr.actions")
end

local function get_commands()
  return require("gh-pr.commands")
end

local function get_mappings()
  return require("gh-pr.mappings")
end

local function get_queries()
  return require("gh-pr.queries")
end

local function get_repo()
  return require("gh-pr.repo")
end

local function get_runtime_state()
  return require("gh-pr.state")
end

local function get_neotree()
  return require("gh-pr.integrations.neotree")
end

local function get_telescope()
  return require("gh-pr.integrations.telescope")
end

local function ensure_required_dependencies()
  local ok = pcall(require, "render-markdown")
  if ok then
    return true
  end

  local message = "Missing required dependency: MeanderingProgrammer/render-markdown.nvim"
  notify_error(message)
  error("gh-pr: " .. message)
end

local function open_telescope_fallback()
  get_telescope().open_pull_requests({
    on_error = notify_error,
    load_error = "Unable to load Telescope fallback",
  })
end

local function open_neotree(source_name, source_module_name, opts)
  opts = opts or {}
  source_name = source_name or "gh_pr"
  source_module_name = source_module_name or source_name

  return get_neotree().open_source(source_name, source_module_name, vim.tbl_extend("force", {}, opts, {
    on_error = notify_error,
  }))
end

local function open_default_view()
  if not get_repo().ensure_git_repo() then
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
  if not get_repo().ensure_git_repo() then
    return
  end

  pcall(function()
    require("gh-pr.neotree.comments_source").invalidate_cache()
  end)

  if number ~= nil then
    local actions = get_actions()
    local _, _, activate_err = actions.activate_review(number, { refresh = true })
    if activate_err then
      notify_error(activate_err)
      return
    end
  else
    local runtime_state = get_runtime_state()
    local active_pr, active_details = runtime_state.get_active_pr()
    if active_pr and active_details then
      local actions = get_actions()
      actions.set_active_review(active_pr, active_details)
    end
  end

  open_neotree("gh_pr_review", "gh_pr_review", { toggle = false })
end

local function open_review_view(opts)
  opts = opts or {}
  if not get_repo().ensure_git_repo() then
    return false
  end

  return open_neotree("gh_pr_review", "gh_pr_review", {
    toggle = opts.toggle ~= false,
  })
end

local function refresh_views()
  get_neotree().refresh_sources()
end

local function query_command_context()
  return {
    get_queries = get_queries,
    notify_info = notify_info,
    notify_error = notify_error,
    refresh_views = refresh_views,
  }
end

local function run_query_command(method)
  local commands = get_commands()
  local handler = commands[method]
  if type(handler) ~= "function" then
    notify_error("Missing gh-pr command handler: " .. tostring(method))
    return
  end

  return handler(query_command_context())
end

local function ensure_configured()
  if user_config_applied then
    return
  end

  config.setup({})
  skip_query_file_load = false
  user_config_applied = true
  get_mappings().apply_global_default_mappings(config.get())
end

local function ensure_runtime_initialized()
  ensure_configured()
  return runtime.ensure_initialized({
    skip_query_file_load = skip_query_file_load,
    setup_highlights = function()
      require("gh-pr.highlights").setup()
    end,
    ensure_required_dependencies = ensure_required_dependencies,
    setup_state = function()
      get_runtime_state().setup()
    end,
    setup_queries = function(skip_load)
      get_queries().setup(skip_load)
    end,
  })
end

local function with_runtime(handler, ...)
  if type(handler) ~= "function" then
    return
  end
  if not ensure_runtime_initialized() then
    return
  end
  return handler(...)
end

local function call_actions(method, ...)
  local actions = get_actions()
  local handler = actions[method]
  if type(handler) ~= "function" then
    notify_error("Missing gh-pr action handler: " .. tostring(method))
    return
  end

  return handler(...)
end

function M.setup(opts)
  opts = opts or {}
  config.setup(opts)
  skip_query_file_load = opts.queries ~= nil
  user_config_applied = true
  get_mappings().apply_global_default_mappings(config.get())

  if runtime.is_initialized() then
    runtime.restart_auto_refresh_timer()
  end
end

function M.open_pull_requests()
  return with_runtime(open_default_view)
end

function M.list_pull_requests()
  return with_runtime(open_telescope_fallback)
end

function M.open_telescope()
  return with_runtime(open_telescope_fallback)
end

function M.open_telescope_actions(opts)
  return with_runtime(function()
    get_telescope().open_context_actions(opts or {}, {
      on_error = notify_error,
      load_error = "Unable to load Telescope fallback",
    })
  end)
end

function M.open_telescope_review_actions(opts)
  return with_runtime(function()
    get_telescope().open_review_actions(opts or {}, {
      on_error = notify_error,
      load_error = "Unable to load Telescope fallback",
    })
  end)
end

function M.open_comments(number)
  return with_runtime(function()
    open_comments_view(number)
  end)
end

function M.open_review_tree(opts)
  opts = opts or {}
  return with_runtime(function()
    return open_review_view(opts)
  end)
end

function M.start_review(number)
  return with_runtime(function()
    call_actions("start_review", number)
  end)
end

function M.refresh()
  return with_runtime(function()
    refresh_views()
    notify_info("Refreshed gh-pr views")
  end)
end

function M.refresh_review()
  return with_runtime(function()
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

    local review_pr = get_runtime_state().get_active_review(repo_name)
    if type(review_pr) ~= "table" or type(review_pr.number) ~= "number" then
      notify_error("Unable to refresh PR Review: no active review for current repository")
      return
    end

    notify_info("PR Review refresh is already in progress")
  end)
end

function M.add_query()
  return with_runtime(function()
    run_query_command("add_query")
  end)
end

function M.edit_query()
  return with_runtime(function()
    run_query_command("edit_query")
  end)
end

function M.delete_query()
  return with_runtime(function()
    run_query_command("delete_query")
  end)
end

function M.open_overview()
  return with_runtime(function()
    call_actions("open_overview")
  end)
end

function M.open_overview_v2()
  return with_runtime(function()
    call_actions("open_overview")
  end)
end

function M.refresh_overview()
  return with_runtime(function()
    call_actions("refresh_overview")
  end)
end

function M.refresh_overview_v2()
  return with_runtime(function()
    call_actions("refresh_overview")
  end)
end

function M.overview_more(section, count)
  return with_runtime(function()
    call_actions("overview_more", section, count)
  end)
end

function M.checkout(number)
  return with_runtime(function()
    call_actions("checkout", number)
  end)
end

function M.open_diff()
  return with_runtime(function()
    call_actions("open_diff")
  end)
end

function M.open_original()
  return with_runtime(function()
    call_actions("open_original")
  end)
end

function M.open_modified()
  return with_runtime(function()
    call_actions("open_modified")
  end)
end

function M.open_commit_patch()
  return with_runtime(function()
    call_actions("open_commit_diff")
  end)
end

function M.toggle_reviewed()
  return with_runtime(function()
    call_actions("toggle_viewed")
  end)
end

function M.next_change()
  return with_runtime(function()
    call_actions("next_change")
  end)
end

function M.prev_change()
  return with_runtime(function()
    call_actions("prev_change")
  end)
end

function M.approve()
  return with_runtime(function()
    call_actions("review", "approve")
  end)
end

function M.request_changes()
  return with_runtime(function()
    call_actions("review", "request_changes")
  end)
end

function M.comment()
  return with_runtime(function()
    call_actions("review", "comment")
  end)
end

function M.review_submit_pending()
  return with_runtime(function()
    call_actions("submit_pending_comment_review")
  end)
end

function M.review_approve_pending()
  return with_runtime(function()
    call_actions("submit_pending_approve_review")
  end)
end

function M.review_request_changes_pending()
  return with_runtime(function()
    call_actions("submit_pending_request_changes_review")
  end)
end

function M.review_discard_pending()
  return with_runtime(function()
    call_actions("discard_pending_review")
  end)
end

function M.add_inline_comment()
  return with_runtime(function()
    call_actions("add_inline_comment")
  end)
end

function M.add_inline_comment_visual()
  return with_runtime(function()
    call_actions("add_inline_comment_visual")
  end)
end

function M.merge(method)
  return with_runtime(function()
    call_actions("merge", method)
  end)
end

return M
