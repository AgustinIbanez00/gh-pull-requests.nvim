local M = {}

local actions = require("gh-pr.actions")
local config = require("gh-pr.config")
local queries = require("gh-pr.queries")
local repo = require("gh-pr.repo")
local runtime_state = require("gh-pr.state")
local uv = vim.uv or vim.loop

local auto_refresh_timer = nil

local function notify_error(message)
  vim.notify(message, vim.log.levels.ERROR)
end

local function notify_info(message)
  vim.notify(message, vim.log.levels.INFO)
end

local function open_telescope_fallback()
  local ok, telescope = pcall(require, "gh-pr.telescope")
  if not ok then
    notify_error("Unable to load Telescope fallback")
    return
  end
  telescope.pull_requests()
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
      local display_name = source_name == "gh_pr_comments" and "  Comments " or "  PR "
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

  local setup_ok, setup_err = pcall(manager.setup, source_name, neo_tree.config[source_name], neo_tree.config, source_module)
  if not setup_ok then
    notify_error("Failed to setup " .. source_name .. " Neo-tree source: " .. tostring(setup_err))
    return false
  end

  return true
end

local function open_neotree(source_name, source_module_name)
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
    toggle = true,
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

  local _, _, activate_err = actions.activate_pr(number, number ~= nil)
  if activate_err then
    notify_error(activate_err)
    return
  end

  pcall(function()
    require("gh-pr.neotree.comments_source").invalidate_cache()
  end)

  open_neotree("gh_pr_comments", "gh_pr_comments")
end

local function refresh_views()
  local source_ok, source = pcall(require, "gh-pr.neotree.source")
  if source_ok and type(source.request_refresh) == "function" then
    pcall(source.request_refresh, nil, { force = true, notify_error = false })
  end

  local manager_ok, manager = pcall(require, "neo-tree.sources.manager")
  if manager_ok then
    pcall(manager.refresh, "gh_pr_comments")
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

  local cache_options = (((config.get() or {}).cache or {}).gh_pr or {})
  if cache_options.auto_refresh_when_focused == false then
    return
  end

  local interval = tonumber(cache_options.ttl_seconds) or 60
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
    if source_ok and type(source.refresh_if_focused) == "function" then
      source.refresh_if_focused()
    end
  end))
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
end

function M.open_pull_requests()
  open_default_view()
end

function M.open_comments(number)
  open_comments_view(number)
end

function M.refresh()
  refresh_views()
  notify_info("Refreshed gh-pr views")
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

function M.merge(method)
  actions.merge(method)
end

return M
