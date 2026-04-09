local M = {}

local config = require("gh-pr.config")
local fast_event_patch = require("gh-pr.integrations.neotree_fast_event")
local registry = require("gh-pr.neotree.registry")
local pr_service = require("gh-pr.pr_service")
local repo = require("gh-pr.repo")

local configured_sources = {}
local auto_managed_sources = {}
local auto_managed_selector_sources = {}
local workspace_probe_cache = {}
local pending_open = {}

local DISPLAY_NAMES = {
  gh_pr = "  PR ",
  gh_pr_comments = "  Comments ",
  gh_pr_diff_comments = "  Diff Comments ",
  gh_pr_review = "  PR Review ",
  gh_my_pr = "  My PR ",
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
  fast_event_patch.apply()
  return neo_tree
end

local function read_config()
  return config.get() or {}
end

local function source_settings(source_key)
  local ui = (read_config().ui or {})
  local neotree_sources = type(ui.neotree_sources) == "table" and ui.neotree_sources or {}
  local key = source_key == "my_pr" and "my_pr" or "pr"
  local source = type(neotree_sources[key]) == "table" and neotree_sources[key] or {}

  return {
    auto_register = source.auto_register ~= false,
    gate = type(source.gate) == "string" and source.gate or "github_repo",
    workspace = type(source.workspace) == "string" and source.workspace or "cwd",
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

local function valid_tabpage(tabid)
  return type(tabid) == "number" and tabid > 0 and vim.api.nvim_tabpage_is_valid(tabid)
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

local function source_is_visible(source_name, tabid)
  if package.loaded["neo-tree"] == nil then
    return false
  end

  local target_tab = valid_tabpage(tabid) and tabid or vim.api.nvim_get_current_tabpage()
  for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(target_tab)) do
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

local function ensure_source_config(neo_tree, source_name, opts)
  opts = opts or {}
  if type(neo_tree.config[source_name]) ~= "table" then
    neo_tree.config[source_name] = {}
  end

  neo_tree.config[source_name].name = source_name
  neo_tree.config[source_name].window = neo_tree.config[source_name].window or {}
  neo_tree.config[source_name].window.position = type(opts.position) == "string"
      and opts.position
    or neo_tree.config[source_name].window.position
    or "left"
  local height = tonumber(opts.height)
  if height and height > 0 then
    neo_tree.config[source_name].window.height = math.floor(height)
  else
    neo_tree.config[source_name].window.height = nil
  end
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

local function close_source_if_visible(source_name, opts)
  opts = opts or {}
  if package.loaded["neo-tree"] == nil then
    return false
  end

  local ok, command = pcall(require, "neo-tree.command")
  if not ok or type(command.execute) ~= "function" then
    return false
  end

  return pcall(command.execute, {
    action = "close",
    source = source_name,
    position = type(opts.position) == "string" and opts.position or "left",
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
    position = type(opts.position) == "string" and opts.position or "left",
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

  ensure_source_config(neo_tree, source_name, opts)
  ensure_source_entry(neo_tree, source_name, { auto_managed = opts.auto_managed == true })
  if opts.selector ~= false then
    ensure_selector_entry(neo_tree, source_name, { auto_managed = opts.auto_managed == true })
  end

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

function M.is_source_visible(source_name, tabid)
  return source_is_visible(source_name, tabid)
end

function M.close_source(source_name, opts)
  opts = opts or {}
  if package.loaded["neo-tree"] == nil then
    return false
  end

  local neo_tree = maybe_get_neotree(false)

  local target_tab = valid_tabpage(tonumber(opts.tabid)) and tonumber(opts.tabid) or vim.api.nvim_get_current_tabpage()
  local previous_tab = vim.api.nvim_get_current_tabpage()
  if target_tab ~= previous_tab then
    pcall(vim.api.nvim_set_current_tabpage, target_tab)
  end

  local closed = false
  if source_is_visible(source_name, target_tab) then
    local positions = {}
    local seen = {}
    local function add_position(position)
      if type(position) ~= "string" or position == "" or seen[position] then
        return
      end
      seen[position] = true
      positions[#positions + 1] = position
    end

    add_position(opts.position)
    local configured_position = neo_tree
        and neo_tree.config
        and neo_tree.config[source_name]
        and neo_tree.config[source_name].window
        and neo_tree.config[source_name].window.position
      or nil
    add_position(configured_position)
    add_position("bottom")
    add_position("right")
    add_position("left")

    for _, position in ipairs(positions) do
      close_source_if_visible(source_name, {
        position = position,
      })
      if not source_is_visible(source_name, target_tab) then
        closed = true
        break
      end
    end
  end

  if valid_tabpage(previous_tab) and previous_tab ~= target_tab then
    pcall(vim.api.nvim_set_current_tabpage, previous_tab)
  end

  return closed
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
    local status_messages = type(opts.status_messages) == "table" and opts.status_messages or {}
    local message = status_messages[result.status]
      or (result.status == "not_git" and "gh-pr requires a git repository")
      or (result.status == "no_github_remote" and "gh-pr requires a GitHub repository remote")
      or (result.status == "no_branch" and "gh-pr requires a local branch for My PR")
      or (result.status == "no_matching_pr" and "No pull request matches the current branch in this repository")
      or "Unable to resolve repository for gh-pr"
    notify_error(pending.opts, message)
  end
end

local function request_pr_probe(source_name, source_module_name, opts)
  opts = opts or {}
  local settings = source_settings("pr")
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

local function request_my_pr_probe(source_name, source_module_name, opts)
  opts = opts or {}
  local settings = source_settings("my_pr")
  local workspace_path = resolve_workspace_path(settings.workspace)
  local probe_gate = effective_probe_gate(settings.gate)
  local remotes = read_config().remotes or { "origin", "upstream" }
  local branch, _ = repo.current_branch({ cwd = workspace_path })
  local branch_key = type(branch) == "string" and vim.trim(branch) or ""
  if branch_key == "" then
    branch_key = "__no_branch__"
  end

  local key = probe_cache_key(workspace_path, probe_gate, remotes) .. "::gh_my_pr::" .. branch_key
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
    if type(result) ~= "table" then
      result = {
        eligible = false,
        status = "error",
      }
    end

    if result.eligible ~= true then
      workspace_probe_cache[key] = {
        status = "resolved",
        result = result,
      }
      handle_pr_probe_result(key, source_name, source_module_name, opts, result)
      return
    end

    if type(result.repository) ~= "table" then
      local no_repo_result = vim.tbl_extend("force", result, {
        eligible = false,
        status = "no_github_remote",
      })
      workspace_probe_cache[key] = {
        status = "resolved",
        result = no_repo_result,
      }
      handle_pr_probe_result(key, source_name, source_module_name, opts, no_repo_result)
      return
    end

    local git_root = type(result.git_root) == "string" and result.git_root ~= "" and result.git_root or workspace_path
    repo.current_branch_async({ cwd = git_root }, function(resolved_branch, branch_err)
      resolved_branch = type(resolved_branch) == "string" and vim.trim(resolved_branch) or ""
      if resolved_branch == "" then
        local no_branch_result = vim.tbl_extend("force", result, {
          eligible = false,
          status = "no_branch",
          branch = nil,
          error = branch_err,
        })
        workspace_probe_cache[key] = {
          status = "resolved",
          result = no_branch_result,
        }
        handle_pr_probe_result(key, source_name, source_module_name, opts, no_branch_result)
        return
      end

      pr_service.find_pr_for_branch_async(resolved_branch, {
        repository = result.repository,
      }, function(pr, pr_err)
        local final_result = nil
        if not pr then
          final_result = vim.tbl_extend("force", result, {
            eligible = false,
            status = "no_matching_pr",
            branch = resolved_branch,
            error = pr_err,
          })
        else
          final_result = vim.tbl_extend("force", result, {
            eligible = true,
            status = "eligible",
            branch = resolved_branch,
            pr = pr,
          })
        end

        workspace_probe_cache[key] = {
          status = "resolved",
          result = final_result,
        }
        handle_pr_probe_result(key, source_name, source_module_name, opts, final_result)
      end)
    end)
  end)

  return true
end

function M.open_source(source_name, source_module_name, opts)
  opts = opts or {}
  source_name = source_name or "gh_pr"
  source_module_name = source_module_name or source_name

  if source_name == "gh_pr" or source_name == "gh_my_pr" then
    local neo_tree = maybe_get_neotree(true)
    if not neo_tree then
      return false
    end

    local source_key = source_name == "gh_my_pr" and "my_pr" or "pr"
    local settings = source_settings(source_key)
    local request_probe = source_name == "gh_my_pr" and request_my_pr_probe or request_pr_probe
    return request_probe(source_name, source_module_name, {
      action = type(opts.action) == "string" and opts.action or (source_is_visible(source_name) and "focus" or "show"),
      toggle = false,
      position = type(opts.position) == "string" and opts.position or "left",
      on_error = opts.on_error,
      auto_managed = settings.gate ~= "manual" and settings.auto_register == true,
      pending_open = true,
      status_messages = source_name == "gh_my_pr" and {
        no_branch = "My PR requires a local branch in the current repository",
        no_matching_pr = "No pull request matches the current branch in this repository",
      } or nil,
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

  local my_pr_source = registry.get("gh_my_pr")
  if type(my_pr_source) == "table" and type(my_pr_source.request_refresh) == "function" then
    pcall(my_pr_source.request_refresh, nil, { force = true, notify_error = false })
  end
end

function M.refresh_source_availability(source_key, opts)
  opts = opts or {}
  source_key = source_key == "my_pr" and "my_pr" or "pr"
  local settings = source_settings(source_key)
  if settings.gate == "manual" or settings.auto_register == false then
    return false
  end

  if not maybe_get_neotree(false) then
    return false
  end

  local source_name = source_key == "my_pr" and "gh_my_pr" or "gh_pr"
  local request_probe = source_key == "my_pr" and request_my_pr_probe or request_pr_probe
  return request_probe(source_name, source_name, {
    force = opts.force == true,
    auto_managed = true,
    pending_open = false,
    status_messages = source_key == "my_pr" and {
      no_branch = "My PR requires a local branch in the current repository",
      no_matching_pr = "No pull request matches the current branch in this repository",
    } or nil,
  })
end

function M.refresh_pr_source_availability(opts)
  return M.refresh_source_availability("pr", opts)
end

function M.refresh_my_pr_source_availability(opts)
  return M.refresh_source_availability("my_pr", opts)
end

function M.handle_neotree_filetype(_)
  if not maybe_get_neotree(false) then
    return
  end

  M.refresh_pr_source_availability()
  M.refresh_my_pr_source_availability()
end

function M.handle_dir_changed(_)
  if not maybe_get_neotree(false) then
    return
  end

  M.refresh_pr_source_availability({ force = true })
  M.refresh_my_pr_source_availability({ force = true })
end

function M.handle_focus_event(_)
  if not maybe_get_neotree(false) then
    return
  end

  M.refresh_pr_source_availability()
  M.refresh_my_pr_source_availability()
end

return M
