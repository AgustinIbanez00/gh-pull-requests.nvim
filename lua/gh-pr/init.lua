local M = {}

local unpack_fn = table.unpack or unpack

local config = require("gh-pr.config")
local runtime = require("gh-pr.core.runtime")
local notify = require("gh-pr.core.notify")

local user_config_applied = false
local pending_lua_queries = nil

local function notify_error(message)
  notify.error(message)
end

local function notify_info(message)
  notify.info(message)
end

local function notify_warn(message)
  notify.warn(message)
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

local with_runtime
local call_actions

-- Persist uncaught Lua errors (with traceback) to the `lua` log channel so
-- failures that surface as a single notification can be reproduced afterwards.
local function log_lua_error(label, message, traceback)
  local ok, logger = pcall(require, "gh-pr.core.logger")
  if ok then
    logger.error("lua", string.format("%s: %s", label, tostring(message)), { traceback = traceback })
  end
end

local function run_protected(label, handler, ...)
  local n = select("#", ...)
  local args = { ... }
  local results
  local ok, tb = xpcall(function()
    results = { handler(unpack_fn(args, 1, n)) }
  end, debug.traceback)

  if not ok then
    local first = tostring(tb):match("^[^\n]*") or tostring(tb)
    log_lua_error(label, first, tb)
    notify_error(string.format("gh-pr error in %s (see :GhPrLogOpen lua)", label))
    return
  end

  if results then
    return unpack_fn(results, 1, #results)
  end
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
  local options = config.get()
  if options.ui.use_neotree and open_neotree("gh_pr", "gh_pr", { toggle = false }) then
    return
  end

  if not get_repo().ensure_git_repo() then
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

  local comments_source = require("gh-pr.neotree.registry").get("gh_pr_comments")
  if type(comments_source) == "table" and type(comments_source.invalidate_cache) == "function" then
    pcall(comments_source.invalidate_cache)
  end

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

local function open_my_pr_view(opts)
  opts = opts or {}
  if not get_repo().ensure_git_repo() then
    return false
  end

  return open_neotree("gh_my_pr", "gh_my_pr", {
    toggle = opts.toggle ~= false,
  })
end

local function refresh_views()
  get_neotree().refresh_sources()
end

local function open_create_pull_request_wizard()
  local pr_service = require("gh-pr.pr_service")
  return require("gh-pr.ui.create_pull_request").open({
    gh = require("gh-pr.gh"),
    repo = get_repo(),
    pr_service = pr_service,
    notify_error = notify_error,
    notify_info = notify_info,
    notify_warn = notify_warn,
    refresh_sources = function()
      pcall(refresh_views)
    end,
    open_overview = function(number)
      return with_runtime(function()
        call_actions("open_overview", number, { refresh = true })
      end)
    end,
  })
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
  user_config_applied = true
  get_mappings().apply_global_default_mappings(config.get())
end

local function ensure_runtime_initialized()
  ensure_configured()
  return runtime.ensure_initialized({
    setup_highlights = function()
      require("gh-pr.highlights").setup()
    end,
    ensure_required_dependencies = ensure_required_dependencies,
    setup_state = function()
      get_runtime_state().setup()
    end,
    setup_queries = function()
      get_queries().setup({ lua_queries = pending_lua_queries })
    end,
  })
end

function with_runtime(handler, ...)
  if type(handler) ~= "function" then
    return
  end
  if not ensure_runtime_initialized() then
    return
  end
  return run_protected("command", handler, ...)
end

function call_actions(method, ...)
  local actions = get_actions()
  local handler = actions[method]
  if type(handler) ~= "function" then
    notify_error("Missing gh-pr action handler: " .. tostring(method))
    return
  end

  return run_protected("action:" .. tostring(method), handler, ...)
end

function M.setup(opts)
  opts = opts or {}
  config.setup(opts)
  pending_lua_queries = opts.queries
  user_config_applied = true
  pcall(function()
    require("gh-pr.core.logger").setup(config.get().log)
  end)
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

function M.create_pull_request()
  ensure_configured()
  if not get_repo().ensure_git_repo() then
    return
  end
  return open_create_pull_request_wizard()
end

M.new_pull_request = M.create_pull_request

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

function M.open_my_pr_tree(opts)
  opts = opts or {}
  return with_runtime(function()
    return open_my_pr_view(opts)
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
    local review_source = require("gh-pr.neotree.registry").get("gh_pr_review")
    if type(review_source) ~= "table" or type(review_source.request_refresh) ~= "function" then
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

function M.refresh_overview()
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

function M.toggle_review_panel()
  return with_runtime(function()
    call_actions("toggle_diff_review_panel")
  end)
end

M.toggle_changes_panel = M.toggle_review_panel

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

function M.log_open(channel)
  ensure_configured()
  local logger = require("gh-pr.core.logger")
  local ok, err = logger.open(channel ~= "" and channel or nil)
  if not ok and err then
    notify_error(err)
  end
end

function M.log_clear(channel)
  ensure_configured()
  local logger = require("gh-pr.core.logger")
  local ok, err = logger.clear(channel ~= "" and channel or nil)
  if not ok then
    notify_error(err or "Unable to clear gh-pr logs")
    return
  end
  notify_info(channel and channel ~= "" and ("Cleared gh-pr log: " .. channel) or "Cleared all gh-pr logs")
end

function M.log_level(level)
  ensure_configured()
  local logger = require("gh-pr.core.logger")
  if level == nil or level == "" then
    notify_info("gh-pr log level: " .. logger.get_level())
    return
  end

  local ok, err = logger.set_level(level)
  if not ok then
    notify_error(err or "Invalid log level")
    return
  end
  notify_info("gh-pr log level set to: " .. logger.get_level())
end

function M.queries_prompt_reset()
  return with_runtime(function()
    get_queries().reset_prompt_choice()
  end)
end

function M.queries_reload_lua()
  return with_runtime(function()
    get_queries().reload_from_lua()
    refresh_views()
  end)
end

return M
