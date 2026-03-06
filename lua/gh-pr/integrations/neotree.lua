local M = {}

local config = require("gh-pr.config")
local registry = require("gh-pr.neotree.registry")
local repo = require("gh-pr.repo")

local configured_sources = {}
local auto_managed_sources = {}
local auto_managed_selector_sources = {}
local workspace_probe_cache = {}
local pending_open = {}

local DISPLAY_NAMES = {
  gh_pr = "  PR ",
  gh_pr_comments = "  Comments ",
  gh_pr_review = "  PR Review ",
}

local function notify_error(opts, message)
  local on_error = type(opts) == "table" and opts.on_error or nil
  if type(on_error) == "function" then
    on_error(message)
  end
end

local function source_display_name(source_name)
  return DISPLAY_NAMES[source_name] or ("  " .. tostring(source_name) .. " ")
end

local function maybe_get_neotree(load)
  if package.loaded["neo-tree"] == nil and not load then
    return nil
  end

  local ok, neo_tree = pcall(require, "neo-tree")
  if not ok then
    return nil
  end

  neo_tree.ensure_config()
  return neo_tree
end

local function read_config()
  return config.get() or {}
end

local function pr_source_settings()
  local ui = (read_config().ui or {})
  local neotree_sources = type(ui.neotree_sources) == "table" and ui.neotree_sources or {}
  local pr = type(neotree_sources.pr) == "table" and neotree_sources.pr or {}

  return {
    auto_register = pr.auto_register ~= false,
    gate = type(pr.gate) == "string" and pr.gate or "github_repo",
    workspace = type(pr.workspace) == "string" and pr.workspace or "cwd",
  }
end

local function effective_probe_gate(gate)
  if gate == "git_repo" then
    return "git_repo"
  end

  return "github_repo"
end

local function probe_cache_key(workspace_path, gate, remotes)
  local joined_remotes = table.concat(type(remotes) == "table" and remotes or {}, ",")
  return table.concat({ workspace_path or "", gate or "", joined_remotes }, "::")
end

local function valid_window(winid)
  return type(winid) == "number" and winid > 0 and vim.api.nvim_win_is_valid(winid)
end

local function visible_neotree_state_paths()
  local paths = {}
  if package.loaded["neo-tree"] == nil then
    return paths
  end

  local manager_ok, manager = pcall(require, "neo-tree.sources.manager")
  if not manager_ok or type(manager.get_state_for_window) ~= "function" then
    return paths
  end

  local seen = {}
  for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if valid_window(winid) then
      local bufnr = vim.api.nvim_win_get_buf(winid)
      local ok, filetype = pcall(vim.api.nvim_get_option_value, "filetype", { buf = bufnr })
      filetype = ok and filetype or vim.bo[bufnr].filetype
      if filetype == "neo-tree" then
        local ok_state, state = pcall(manager.get_state_for_window, winid)
        local path = ok_state and type(state) == "table" and state.path or nil
        if type(path) == "string" and path ~= "" and not seen[path] then
          seen[path] = true
          paths[#paths + 1] = path
        end
      end
    end
  end

  return paths
end

local function source_is_visible(source_name)
  if package.loaded["neo-tree"] == nil then
    return false
  end

  for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if valid_window(winid) then
      local bufnr = vim.api.nvim_win_get_buf(winid)
      local ok, filetype = pcall(vim.api.nvim_get_option_value, "filetype", { buf = bufnr })
      filetype = ok and filetype or vim.bo[bufnr].filetype
      if filetype == "neo-tree" and vim.b[bufnr].neo_tree_source == source_name then
        return true
      end
    end
  end

  return false
end

local function current_buffer_workspace()
  local name = vim.api.nvim_buf_get_name(0)
  if type(name) ~= "string" or name == "" then
    return nil
  end

  if name:match("^%a[%w+.-]*://") then
    return nil
  end

  local absolute = vim.fn.fnamemodify(name, ":p")
  if type(absolute) ~= "string" or absolute == "" then
    return nil
  end

  return vim.fn.fnamemodify(absolute, ":h")
end

local function resolve_workspace_path(workspace_kind)
  if workspace_kind == "buffer_repo" then
    return current_buffer_workspace() or vim.fn.getcwd()
  end

  if workspace_kind == "neotree_root" then
    local paths = visible_neotree_state_paths()
    if #paths > 0 then
      return paths[1]
    end
  end

  return vim.fn.getcwd()
end

local function find_source_entry(items, source_name)
  if type(items) ~= "table" then
    return nil, nil
  end

  for index, item in ipairs(items) do
    if item == source_name then
      return index, item
    end
    if type(item) == "table" and item.source == source_name then
      return index, item
    end
  end

  return nil, nil
end

local function ensure_source_config(neo_tree, source_name)
  if type(neo_tree.config[source_name]) ~= "table" then
    neo_tree.config[source_name] = {}
  end

  neo_tree.config[source_name].name = source_name
  neo_tree.config[source_name].window = neo_tree.config[source_name].window or {}
  neo_tree.config[source_name].window.position = neo_tree.config[source_name].window.position or "left"
  neo_tree.config.sources = type(neo_tree.config.sources) == "table" and neo_tree.config.sources or {}
end

local function ensure_source_entry(neo_tree, source_name, opts)
  opts = opts or {}
  local index = find_source_entry(neo_tree.config.sources, source_name)
  if index then
    return false
  end

  table.insert(neo_tree.config.sources, source_name)
  if opts.auto_managed then
    auto_managed_sources[source_name] = true
  end
  return true
end

local function ensure_selector_entry(neo_tree, source_name, opts)
  opts = opts or {}
  if type(neo_tree.config.source_selector) ~= "table" or type(neo_tree.config.source_selector.sources) ~= "table" then
    return false
  end

  local selector_sources = neo_tree.config.source_selector.sources
  local index = find_source_entry(selector_sources, source_name)
  if index then
    return false
  end

  table.insert(selector_sources, {
    source = source_name,
    display_name = source_display_name(source_name),
  })
  if opts.auto_managed then
    auto_managed_selector_sources[source_name] = true
  end
  return true
end

local function remove_auto_managed_entries(neo_tree, source_name)
  local changed = false

  if auto_managed_sources[source_name] and type(neo_tree.config.sources) == "table" then
    local index = find_source_entry(neo_tree.config.sources, source_name)
    if index then
      table.remove(neo_tree.config.sources, index)
      changed = true
    end
    auto_managed_sources[source_name] = nil
  end

  if auto_managed_selector_sources[source_name]
    and type(neo_tree.config.source_selector) == "table"
    and type(neo_tree.config.source_selector.sources) == "table" then
    local selector_sources = neo_tree.config.source_selector.sources
    local index = find_source_entry(selector_sources, source_name)
    if index then
      table.remove(selector_sources, index)
      changed = true
    end
    auto_managed_selector_sources[source_name] = nil
  end

  return changed
end

local function redraw_visible_neotree_windows()
  if package.loaded["neo-tree"] == nil then
    return
  end

  local manager_ok, manager = pcall(require, "neo-tree.sources.manager")
  if not manager_ok or type(manager.get_state_for_window) ~= "function" then
    return
  end

  local renderer_ok, renderer = pcall(require, "neo-tree.ui.renderer")
  if not renderer_ok or type(renderer.redraw) ~= "function" then
    return
  end

  local seen = {}
  for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if valid_window(winid) then
      local ok_state, state = pcall(manager.get_state_for_window, winid)
      if ok_state and type(state) == "table" and not seen[tostring(state)] then
        seen[tostring(state)] = true
        pcall(renderer.redraw, state)
      end
    end
  end
end

local function close_source_if_visible(source_name)
  if package.loaded["neo-tree"] == nil then
    return
  end

  local ok, command = pcall(require, "neo-tree.command")
  if not ok or type(command.execute) ~= "function" then
    return
  end

  pcall(command.execute, {
    action = "close",
    source = source_name,
    position = "left",
  })
end

local function execute_source(source_name, opts)
  opts = opts or {}
  local ok, command = pcall(require, "neo-tree.command")
  if not ok then
    return false
  end

  local action = type(opts.action) == "string" and opts.action or "focus"
  if action ~= "focus" and action ~= "show" then
    action = "focus"
  end

  local status, err = pcall(command.execute, {
    action = action,
    source = source_name,
    toggle = opts.toggle == true,
    reveal = false,
    position = "left",
  })

  if not status then
    notify_error(opts, "Neo-tree source failed: " .. tostring(err))
    return false
  end

  return true
end

function M.ensure_source(source_name, source_module_name, opts)
  opts = opts or {}
  source_name = source_name or "gh_pr"
  source_module_name = source_module_name or source_name

  local neo_tree = maybe_get_neotree(true)
  if not neo_tree then
    return false
  end

  ensure_source_config(neo_tree, source_name)
  ensure_source_entry(neo_tree, source_name, { auto_managed = opts.auto_managed == true })
  ensure_selector_entry(neo_tree, source_name, { auto_managed = opts.auto_managed == true })

  if configured_sources[source_name] then
    return true
  end

  local manager_ok, manager = pcall(require, "neo-tree.sources.manager")
  if not manager_ok then
    return false
  end

  local source_ok, source_module = pcall(require, source_module_name)
  if not source_ok then
    notify_error(opts, "Unable to load " .. source_name .. " Neo-tree source")
    return false
  end

  local setup_ok, setup_err = pcall(manager.setup, source_name, neo_tree.config[source_name], neo_tree.config, source_module)
  if not setup_ok then
    notify_error(opts, "Failed to setup " .. source_name .. " Neo-tree source: " .. tostring(setup_err))
    return false
  end

  configured_sources[source_name] = true
  return true
end

local function handle_pr_probe_result(probe_key, source_name, source_module_name, opts, result)
  local pending = pending_open[source_name]

  if result.eligible == true then
    if not M.ensure_source(source_name, source_module_name, {
      auto_managed = opts.auto_managed == true,
      on_error = opts.on_error,
    }) then
      pending_open[source_name] = nil
      return
    end

    redraw_visible_neotree_windows()

    local execute_opts = nil
    if pending and pending.probe_key == probe_key then
      pending_open[source_name] = nil
      execute_opts = pending.opts
    elseif opts.pending_open == true then
      execute_opts = opts
    end

    if execute_opts ~= nil then
      execute_source(source_name, execute_opts)
    end
    return
  end

  if opts.auto_managed == true then
    local neo_tree = maybe_get_neotree(false)
    if neo_tree and remove_auto_managed_entries(neo_tree, source_name) then
      close_source_if_visible(source_name)
      redraw_visible_neotree_windows()
    end
  end

  if pending and pending.probe_key == probe_key then
    pending_open[source_name] = nil
    local message = result.status == "not_git"
        and "gh-pr requires a git repository"
      or result.status == "no_github_remote"
        and "gh-pr requires a GitHub repository remote"
      or "Unable to resolve repository for gh-pr"
    notify_error(pending.opts, message)
  end
end

local function request_pr_probe(source_name, source_module_name, opts)
  opts = opts or {}
  local settings = pr_source_settings()
  local workspace_path = resolve_workspace_path(settings.workspace)
  local probe_gate = effective_probe_gate(settings.gate)
  local remotes = read_config().remotes or { "origin", "upstream" }
  local key = probe_cache_key(workspace_path, probe_gate, remotes)
  local cached = workspace_probe_cache[key]

  if cached and cached.status == "resolved" and opts.force ~= true then
    handle_pr_probe_result(key, source_name, source_module_name, opts, cached.result)
    return true
  end

  if cached and cached.status == "inflight" then
    if opts.pending_open == true then
      pending_open[source_name] = {
        probe_key = key,
        opts = opts,
      }
    end
    return true
  end

  workspace_probe_cache[key] = {
    status = "inflight",
  }

  if opts.pending_open == true then
    pending_open[source_name] = {
      probe_key = key,
      opts = opts,
    }
  end

  repo.probe_workspace_async({
    cwd = workspace_path,
    gate = probe_gate,
    remotes = remotes,
  }, function(result)
    workspace_probe_cache[key] = {
      status = "resolved",
      result = result,
    }
    handle_pr_probe_result(key, source_name, source_module_name, opts, result)
  end)

  return true
end

function M.open_source(source_name, source_module_name, opts)
  opts = opts or {}
  source_name = source_name or "gh_pr"
  source_module_name = source_module_name or source_name

  if source_name == "gh_pr" then
    local neo_tree = maybe_get_neotree(true)
    if not neo_tree then
      return false
    end

    local settings = pr_source_settings()
    return request_pr_probe(source_name, source_module_name, {
      action = type(opts.action) == "string" and opts.action or (source_is_visible(source_name) and "focus" or "show"),
      toggle = false,
      position = "left",
      on_error = opts.on_error,
      auto_managed = settings.gate ~= "manual" and settings.auto_register == true,
      pending_open = true,
    })
  end

  if not M.ensure_source(source_name, source_module_name, opts) then
    return false
  end

  return execute_source(source_name, opts)
end

function M.refresh_sources()
  local source = registry.get("gh_pr")
  if type(source) == "table" and type(source.request_refresh) == "function" then
    pcall(source.request_refresh, nil, { force = true, notify_error = false })
  end

  local review_source = registry.get("gh_pr_review")
  if type(review_source) == "table" and type(review_source.request_refresh) == "function" then
    pcall(review_source.request_refresh, nil, { force = true, notify_error = false })
  end
end

function M.refresh_pr_source_availability(opts)
  opts = opts or {}
  local settings = pr_source_settings()
  if settings.gate == "manual" or settings.auto_register == false then
    return false
  end

  if not maybe_get_neotree(false) then
    return false
  end

  return request_pr_probe("gh_pr", "gh_pr", {
    force = opts.force == true,
    auto_managed = true,
    pending_open = false,
  })
end

function M.handle_neotree_filetype(_)
  if not maybe_get_neotree(false) then
    return
  end

  M.refresh_pr_source_availability()
end

function M.handle_dir_changed(_)
  if not maybe_get_neotree(false) then
    return
  end

  M.refresh_pr_source_availability({ force = true })
end

return M
