local cc = require("neo-tree.sources.common.commands")
local renderer = require("neo-tree.ui.renderer")

local M = {}

local function get_actions()
  return require("gh-pr.actions")
end

local function get_config()
  return require("gh-pr.config")
end

local function get_source()
  return require("gh-pr.neotree.review_source")
end

local function get_runtime_state()
  return require("gh-pr.state")
end

local function get_telescope()
  return require("gh-pr.integrations.telescope")
end

local function get_url_open()
  return require("gh-pr.url_open")
end

local function current_node(state)
  if not state or not state.tree then
    return nil
  end

  return state.tree:get_node()
end

local function node_kind(node)
  return node and node.extra and node.extra.kind or nil
end

local function has_pr_context(node)
  return node and node.extra and node.extra.pr ~= nil
end

local function apply_context(node)
  if not node or type(node.extra) ~= "table" then
    return
  end

  local actions = get_actions()
  if node.extra.pr then
    actions.set_active_pr(node.extra.pr, node.extra.details or node.extra.pr)
  end

  if node.extra.file then
    actions.set_active_file(node.extra.file)
  end
end

local function open_overview_from_source(node)
  local pr_number = type(node) == "table"
      and type(node.extra) == "table"
      and type(node.extra.pr) == "table"
      and node.extra.pr.number
    or nil

  get_actions().open_overview(pr_number, {
    prefer_existing = true,
    refresh_mode = "async_silent",
    silent = true,
    focus_role = "summary",
  })
end

local function open_comment_target(node)
  local target = node.extra and node.extra.target
  if type(target) ~= "table" then
    return false
  end

  get_actions().open_comment_location(target, {
    open_thread_popup = true,
    popup_mode = "open",
    focus_thread_popup = true,
  })
  return true
end

local function open_timeline_item(node)
  local item = node.extra and node.extra.timeline_item
  if type(item) ~= "table" then
    return false
  end

  get_actions().open_timeline_item(item, {
    pr = node.extra and node.extra.pr or nil,
    details = node.extra and node.extra.details or nil,
    origin_bufnr = vim.api.nvim_get_current_buf(),
  })
  return true
end

local STATUS_FILTER_CHOICES = {
  { value = "all", label = "All statuses" },
  { value = "modified", label = "Modified only" },
  { value = "added", label = "Added only" },
  { value = "deleted", label = "Deleted only" },
  { value = "renamed", label = "Renamed only" },
  { value = "copied", label = "Copied only" },
}

local function current_file_filters(state)
  local source = get_source()
  if type(source.get_file_filters) ~= "function" then
    return {
      path_query = "",
      status = "all",
      extension = "",
      no_extension = false,
      dotfiles = false,
      viewed_state = "all",
      hide_viewed = nil,
      hide_deleted = false,
    }
  end
  return source.get_file_filters(state)
end

local function update_file_filters(state, updates)
  local source = get_source()
  if type(source.update_file_filters) ~= "function" then
    vim.notify("PR Review file filters are unavailable", vim.log.levels.WARN)
    return false, nil
  end

  local ok, err, filters = source.update_file_filters(state, updates)
  if not ok then
    vim.notify(err or "Unable to update PR Review file filters", vim.log.levels.ERROR)
    return false, nil
  end

  return true, filters
end

local function reset_file_filters(state)
  local source = get_source()
  if type(source.reset_file_filters) ~= "function" then
    vim.notify("PR Review file filters are unavailable", vim.log.levels.WARN)
    return false
  end

  local ok, err = source.reset_file_filters(state)
  if not ok then
    vim.notify(err or "Unable to reset PR Review file filters", vim.log.levels.ERROR)
    return false
  end

  vim.notify("PR Review file filters reset", vim.log.levels.INFO)
  return true
end

local function node_id(node)
  if type(node) ~= "table" then
    return nil
  end

  if type(node.get_id) == "function" then
    return node:get_id()
  end

  return node.id
end

local function list_children(state, node)
  if type(state) ~= "table" or type(state.tree) ~= "table" or type(node) ~= "table" then
    return {}
  end

  local ids = type(node.get_child_ids) == "function" and node:get_child_ids() or {}
  local children = {}
  for _, child_id in ipairs(type(ids) == "table" and ids or {}) do
    local child = state.tree:get_node(child_id)
    if child then
      children[#children + 1] = child
    end
  end

  return children
end

local function find_root_node(state)
  if type(state) ~= "table" or type(state.tree) ~= "table" then
    return nil
  end

  for _, candidate in ipairs(state.tree:get_nodes() or {}) do
    if node_kind(candidate) == "root" then
      return candidate
    end
  end

  return nil
end

local function find_child_by_kind(state, parent, kind)
  if type(kind) ~= "string" or kind == "" then
    return nil
  end

  for _, child in ipairs(list_children(state, parent)) do
    if node_kind(child) == kind then
      return child
    end
  end
  return nil
end

local function ends_with(value, suffix)
  if type(value) ~= "string" or type(suffix) ~= "string" then
    return false
  end
  if #suffix == 0 then
    return true
  end
  if #value < #suffix then
    return false
  end
  return value:sub(-#suffix) == suffix
end

local function find_comment_subsection(state, comments_node, suffix)
  for _, child in ipairs(list_children(state, comments_node)) do
    if ends_with(node_id(child), suffix) then
      return child
    end
  end
  return nil
end

local function files_section_node(state)
  local root = find_root_node(state)
  if not root then
    return nil
  end
  return find_child_by_kind(state, root, "files")
end

local function comments_section_node(state)
  local root = find_root_node(state)
  if not root then
    return nil
  end
  return find_child_by_kind(state, root, "comments")
end

local function comments_global_node(state)
  local comments = comments_section_node(state)
  if not comments then
    return nil
  end
  return find_comment_subsection(state, comments, ":comments:global")
end

local function expand_subtree(state, node)
  if type(state) ~= "table" or type(state.tree) ~= "table" or type(node) ~= "table" then
    return false
  end
  local ok = pcall(cc.expand_all_nodes, state, node)
  return ok
end

local function collapse_subtree(state, node)
  if type(state) ~= "table" or type(state.tree) ~= "table" or type(node) ~= "table" then
    return false
  end
  local id = node_id(node)
  if type(id) ~= "string" or id == "" then
    return false
  end

  local ok = pcall(function()
    renderer.collapse_all_nodes(state.tree, id)
    renderer.redraw(state)
  end)
  return ok
end

local function collect_viewed_file_nodes(state)
  if type(state) ~= "table" or type(state.tree) ~= "table" then
    return {}
  end

  local runtime_state = get_runtime_state()
  local ok, nodes = pcall(renderer.select_nodes, state.tree, function(candidate)
    if type(candidate) ~= "table" then
      return false
    end

    local extra = candidate.extra
    if type(extra) ~= "table" or extra.kind ~= "file" then
      return false
    end

    local pr = type(extra.pr) == "table" and tonumber(extra.pr.number) or nil
    local repo_name = type(extra.repo) == "string" and extra.repo or nil
    local file = type(extra.file) == "table" and extra.file or nil
    local path = type(file) == "table" and (file.path or file.filename) or candidate.path

    return pr ~= nil
      and type(repo_name) == "string"
      and repo_name ~= ""
      and type(path) == "string"
      and path ~= ""
      and runtime_state.is_viewed(repo_name, pr, path) == true
  end, 2147483647)

  if not ok or type(nodes) ~= "table" then
    return {}
  end

  return nodes
end

local function normalize_tree_path(path)
  if type(path) ~= "string" then
    return ""
  end

  local normalized = path:gsub("\\", "/")
  normalized = normalized:gsub("^%./", "")
  normalized = normalized:gsub("/+", "/")
  normalized = normalized:gsub("^/+", "")
  normalized = normalized:gsub("/+$", "")
  return normalized
end

local function directory_path_from_node(node)
  if type(node) ~= "table" then
    return ""
  end

  local extra = node.extra
  if type(extra) == "table" and type(extra.path) == "string" and extra.path ~= "" then
    return normalize_tree_path(extra.path)
  end

  local id = node_id(node)
  if type(id) == "string" and id ~= "" then
    local parsed = id:match(":file%-dir:(.+)$")
    if type(parsed) == "string" and parsed ~= "" then
      return normalize_tree_path(parsed)
    end
  end

  return ""
end

local function collect_directory_descendant_files(node)
  local extra = type(node) == "table" and node.extra or nil
  local details = type(extra) == "table" and extra.details or nil
  local directory_path = directory_path_from_node(node)
  local descendants = {}
  local seen_paths = {}
  local has_nested_directories = false
  local files = type(details) == "table" and details.files or nil

  if directory_path == "" or type(files) ~= "table" then
    return descendants, {
      has_nested_directories = false,
      repo = type(extra) == "table" and extra.repo or nil,
      pr_number = type(extra) == "table" and type(extra.pr) == "table" and tonumber(extra.pr.number) or nil,
    }
  end

  local prefix = directory_path .. "/"
  for _, file in ipairs(files) do
    local normalized_path = normalize_tree_path(type(file) == "table" and (file.path or file.filename) or nil)
    if normalized_path ~= "" and normalized_path:sub(1, #prefix) == prefix and not seen_paths[normalized_path] then
      seen_paths[normalized_path] = true
      descendants[#descendants + 1] = {
        file = file,
        path = normalized_path,
      }

      local relative_path = normalized_path:sub(#prefix + 1)
      if relative_path:find("/", 1, true) then
        has_nested_directories = true
      end
    end
  end

  return descendants, {
    has_nested_directories = has_nested_directories,
    repo = type(extra) == "table" and extra.repo or nil,
    pr_number = type(extra) == "table" and type(extra.pr) == "table" and tonumber(extra.pr.number) or nil,
  }
end

local function resolve_folder_toggle_target_viewed(entries, repo_name, pr_number)
  if type(repo_name) ~= "string" or repo_name == "" or type(pr_number) ~= "number" then
    return nil
  end

  local runtime_state = get_runtime_state()
  for _, entry in ipairs(type(entries) == "table" and entries or {}) do
    if runtime_state.is_viewed(repo_name, pr_number, entry.path) ~= true then
      return true
    end
  end

  return false
end

local function on_main_loop(callback, value)
  if vim.in_fast_event() then
    vim.schedule(function()
      callback(value)
    end)
    return
  end
  callback(value)
end

local function confirm_directory_toggle(node, file_count, mark_viewed, callback)
  callback = type(callback) == "function" and callback or function() end

  local folder_name = type(node) == "table" and type(node.name) == "string" and node.name or ""
  if folder_name == "" then
    folder_name = directory_path_from_node(node)
  end
  if folder_name == "" then
    folder_name = "folder"
  end

  local action_line
  if mark_viewed == nil then
    action_line = "toggle viewed state"
  else
    action_line = mark_viewed and "mark as viewed" or "mark as unviewed"
  end

  local prompt = string.format(
    "Folder '%s' contains nested folders.\nDo you want to %s for %d files?",
    folder_name,
    action_line,
    tonumber(file_count) or 0
  )

  if vim.ui and type(vim.ui.select) == "function" then
    vim.ui.select({ "yes", "no" }, {
      prompt = prompt,
      format_item = function(item)
        return item
      end,
    }, function(choice)
      on_main_loop(callback, choice == "yes")
    end)
    return
  end

  local choice = vim.fn.confirm(prompt, "&Yes\n&No", 2)
  callback(choice == 1)
end

local function collapse_ancestors_for_nodes(state, nodes, stop_id)
  if type(state) ~= "table" or type(state.tree) ~= "table" then
    return false
  end

  local to_collapse = {}
  for _, file_node in ipairs(type(nodes) == "table" and nodes or {}) do
    local parent_id = type(file_node.get_parent_id) == "function" and file_node:get_parent_id() or nil
    while type(parent_id) == "string" and parent_id ~= "" do
      if parent_id == stop_id then
        break
      end

      local parent = state.tree:get_node(parent_id)
      if not parent then
        break
      end

      to_collapse[parent_id] = parent
      local next_parent = type(parent.get_parent_id) == "function" and parent:get_parent_id() or nil
      if next_parent == parent_id then
        break
      end
      parent_id = next_parent
    end
  end

  for _, parent in pairs(to_collapse) do
    if type(parent.collapse) == "function" then
      pcall(parent.collapse, parent)
    end
  end

  pcall(renderer.redraw, state)
  return true
end

local function configured_review_files_flat_mode()
  local options = get_config().get() or {}
  local pr_review = type(options.pr_review) == "table" and options.pr_review or {}
  local files = type(pr_review.files) == "table" and pr_review.files or {}
  return files.flat == true
end

local function effective_review_files_flat_mode()
  local runtime_state = get_runtime_state()
  local persisted = type(runtime_state.get_pr_review_files_flat_pref) == "function"
      and runtime_state.get_pr_review_files_flat_pref()
    or nil
  if type(persisted) == "boolean" then
    return persisted
  end
  return configured_review_files_flat_mode()
end

M.noop = function() end

M.refresh = function(state)
  get_source().request_refresh(state, {
    force = true,
    refresh_context = {
      mode = "ui-refresh",
      reason = "manual",
      notify = false,
    },
  })
end

M.gh_pr_review_open = function(state)
  local node = current_node(state)
  if not node then
    return
  end

  apply_context(node)
  local kind = node_kind(node)

  if kind == "file" then
    get_actions().open_diff(node.extra and node.extra.file or nil)
    return
  end

  if kind == "overview" then
    open_overview_from_source(node)
    return
  end

  if kind == "comment" or kind == "line" or kind == "comment_thread" or kind == "comment_thread_item" or kind == "draft_comment" then
    if not open_comment_target(node) then
      open_timeline_item(node)
    end
    return
  end

  if kind == "timeline_item"
    or kind == "comment_event_review"
    or kind == "comment_event_global"
    or kind == "comment_event_thread"
    or kind == "comment_event_thread_item" then
    open_timeline_item(node)
    return
  end

  if kind == "commit" and type(node.extra.commit) == "table" then
    get_actions().open_commit_diff(node.extra.commit)
    return
  end

  if kind == "commit_file" and type(node.extra.commit) == "table" and type(node.extra.file) == "table" then
    get_actions().open_commit_file_diff(node.extra.commit, node.extra.file)
    return
  end

  if kind == "check" then
    local loaded, load_err = get_source().request_check_annotations(state, node)
    if not loaded then
      vim.notify(load_err or "Unable to load check annotations", vim.log.levels.ERROR)
      return
    end

    cc.toggle_node(state)
    return
  end

  if kind == "check_annotation" then
    get_actions().open_check_annotation_location(node.extra)
    return
  end

  if kind == "security_code_scanning" then
    local loaded, load_err = get_source().request_security_code_scanning(state, node)
    if not loaded then
      vim.notify(load_err or "Unable to load code scanning findings", vim.log.levels.ERROR)
      return
    end

    cc.toggle_node(state)
    return
  end

  if kind == "security_dependency_review" then
    local loaded, load_err = get_source().request_security_dependency_review(state, node)
    if not loaded then
      vim.notify(load_err or "Unable to load dependency review findings", vim.log.levels.ERROR)
      return
    end

    cc.toggle_node(state)
    return
  end

  if kind == "security_code_scanning_alert" then
    get_actions().open_security_alert_location(node.extra)
    return
  end

  if kind == "security_dependency_package" then
    if node.extra and node.extra.has_vulnerabilities == true then
      cc.toggle_node(state)
      return
    end
    if node.extra and node.extra.file then
      get_actions().open_diff(node.extra.file)
    else
      vim.notify("Unable to resolve manifest diff for selected dependency", vim.log.levels.WARN)
    end
    return
  end

  if kind == "security_dependency_vulnerability" then
    local advisory_url = type(node.extra) == "table" and node.extra.advisory_url or nil
    if type(advisory_url) == "string" and advisory_url ~= "" then
      get_url_open().open(advisory_url, {
        notify_error = true,
        context = "Unable to open dependency advisory",
      })
    end
    return
  end

  if kind == "check_details_link" and type(node.extra.check_url) == "string" and node.extra.check_url ~= "" then
    get_url_open().open(node.extra.check_url, {
      notify_error = true,
      context = "Unable to open check URL",
    })
    return
  end

  if kind == "message" then
    return
  end

  cc.toggle_node(state)
end

M.open_diff = function(state)
  local node = current_node(state)
  if not node then
    return
  end

  apply_context(node)
  local kind = node_kind(node)
  if kind == "file" then
    get_actions().open_diff(node.extra and node.extra.file or nil)
  elseif kind == "commit" then
    get_actions().open_commit_diff(node.extra and node.extra.commit or nil)
  elseif kind == "commit_file" then
    get_actions().open_commit_file_diff(node.extra and node.extra.commit or nil, node.extra and node.extra.file or nil)
  end
end

M.open_original = function(state)
  local node = current_node(state)
  if not node then
    return
  end

  apply_context(node)
  if node_kind(node) == "file" then
    get_actions().open_original(node.extra and node.extra.file or nil)
  end
end

M.open_modified = function(state)
  local node = current_node(state)
  if not node then
    return
  end

  apply_context(node)
  if node_kind(node) == "file" then
    get_actions().open_modified(node.extra and node.extra.file or nil)
  end
end

M.toggle_viewed = function(state)
  local node = current_node(state)
  if not node then
    return
  end

  apply_context(node)
  local kind = node_kind(node)
  if kind == "file" then
    get_actions().mark_file_viewed(node.extra and node.extra.file or nil, nil)
    return
  end

  if kind ~= "directory" then
    return
  end

  local descendants, metadata = collect_directory_descendant_files(node)
  if vim.tbl_isempty(descendants) then
    vim.notify("No files found under this folder", vim.log.levels.INFO)
    return
  end

  local mark_viewed = resolve_folder_toggle_target_viewed(descendants, metadata.repo, metadata.pr_number)
  if metadata.has_nested_directories then
    confirm_directory_toggle(node, #descendants, mark_viewed, function(confirmed)
      if not confirmed then
        vim.notify("Folder viewed update cancelled", vim.log.levels.INFO)
        return
      end

      get_actions().mark_files_viewed(descendants, mark_viewed)
    end)
    return
  end

  get_actions().mark_files_viewed(descendants, mark_viewed)
end

M.comment_file_global = function(state)
  local node = current_node(state)
  if not node then
    return
  end

  apply_context(node)
  if node_kind(node) == "file" then
    get_actions().add_file_global_comment(node.extra and node.extra.file or nil)
  end
end

M.comment_pr = function(state)
  local node = current_node(state)
  if node then
    apply_context(node)
  end
  get_actions().comment_pr()
end

M.edit_labels_multi = function(state)
  local node = current_node(state)
  if node then
    apply_context(node)
  end
  get_actions().overview_edit_stub("edit_labels", {})
end

M.edit_assignees_multi = function(state)
  local node = current_node(state)
  if node then
    apply_context(node)
  end
  get_actions().overview_edit_stub("edit_assignees", {})
end

M.edit_reviewers_multi = function(state)
  local node = current_node(state)
  if node then
    apply_context(node)
  end
  get_actions().overview_edit_stub("edit_reviewers", {})
end

M.open_overview = function(state)
  local node = current_node(state)
  if not node then
    return
  end

  apply_context(node)
  open_overview_from_source(node)
end

M.open_pr_browser = function(state)
  local node = current_node(state)
  if not node or not has_pr_context(node) then
    vim.notify("Selected node has no pull request context", vim.log.levels.INFO)
    return
  end

  apply_context(node)
  local extra = type(node.extra) == "table" and node.extra or {}
  local contextual_url = nil
  if type(extra.alert_url) == "string" and extra.alert_url ~= "" then
    contextual_url = extra.alert_url
  elseif type(extra.advisory_url) == "string" and extra.advisory_url ~= "" then
    contextual_url = extra.advisory_url
  elseif type(extra.check_url) == "string" and extra.check_url ~= "" then
    contextual_url = extra.check_url
  end
  if type(contextual_url) == "string" and contextual_url ~= "" then
    get_url_open().open(contextual_url, {
      notify_error = true,
      context = "Unable to open URL",
    })
    return
  end
  local pr = node.extra and node.extra.pr or nil
  get_actions().open_overview_url(pr and pr.number or nil)
end

M.open_telescope_actions = function(state)
  local node = current_node(state)
  if node then
    apply_context(node)
  end

  get_telescope().open_review_actions(nil, {
    load_error = "Unable to load Telescope review actions",
  })
end

M.start_review = function(state)
  local node = current_node(state)
  if not node then
    return
  end

  apply_context(node)
  local pr = node.extra and node.extra.pr or nil
  get_actions().start_review(pr and pr.number or nil)
end

M.toggle_review_tree = function()
  get_actions().toggle_review_tree()
end

M.submit_pending_comment_review = function(state)
  local node = current_node(state)
  if node then
    apply_context(node)
  end
  get_actions().submit_pending_comment_review()
end

M.submit_pending_approve_review = function(state)
  local node = current_node(state)
  if node then
    apply_context(node)
  end
  get_actions().submit_pending_approve_review()
end

M.submit_pending_request_changes_review = function(state)
  local node = current_node(state)
  if node then
    apply_context(node)
  end
  get_actions().submit_pending_request_changes_review()
end

M.discard_pending_review = function(state)
  local node = current_node(state)
  if node then
    apply_context(node)
  end
  get_actions().discard_pending_review()
end

M.expand_all_review_nodes = function(state)
  pcall(cc.expand_all_nodes, state)
end

M.collapse_all_review_nodes = function(state)
  pcall(cc.close_all_nodes, state)
end

M.expand_files_nodes = function(state)
  expand_subtree(state, files_section_node(state))
end

M.collapse_files_nodes = function(state)
  collapse_subtree(state, files_section_node(state))
end

M.expand_viewed_file_paths = function(state)
  local viewed_nodes = collect_viewed_file_nodes(state)
  if vim.tbl_isempty(viewed_nodes) then
    vim.notify("No viewed files found in this PR", vim.log.levels.INFO)
    return
  end

  for _, viewed_node in ipairs(viewed_nodes) do
    pcall(renderer.expand_to_node, state, viewed_node)
  end
  pcall(renderer.redraw, state)
end

M.collapse_viewed_file_paths = function(state)
  local viewed_nodes = collect_viewed_file_nodes(state)
  if vim.tbl_isempty(viewed_nodes) then
    vim.notify("No viewed files found in this PR", vim.log.levels.INFO)
    return
  end

  local files_node = files_section_node(state)
  local files_node_id = node_id(files_node)
  collapse_ancestors_for_nodes(state, viewed_nodes, files_node_id)
end

M.expand_comments_global = function(state)
  expand_subtree(state, comments_global_node(state))
end

M.collapse_comments_global = function(state)
  collapse_subtree(state, comments_global_node(state))
end

M.filter_files_by_path = function(state)
  local filters = current_file_filters(state)
  vim.ui.input({
    prompt = "Filter PR files by path substring:",
    default = type(filters.path_query) == "string" and filters.path_query or "",
  }, function(input)
    if input == nil then
      return
    end

    local query = vim.trim(type(input) == "string" and input or "")
    local ok = select(1, update_file_filters(state, {
      path_query = query,
    }))
    if ok then
      if query == "" then
        vim.notify("PR Review file path filter cleared", vim.log.levels.INFO)
      else
        vim.notify("PR Review file path filter: " .. query, vim.log.levels.INFO)
      end
    end
  end)
end

M.clear_file_path_filter = function(state)
  local ok = select(1, update_file_filters(state, {
    path_query = "",
  }))
  if ok then
    vim.notify("PR Review file path filter cleared", vim.log.levels.INFO)
  end
end

M.select_file_status_filter = function(state)
  local filters = current_file_filters(state)
  vim.ui.select(STATUS_FILTER_CHOICES, {
    prompt = "PR Review file status filter:",
    format_item = function(item)
      local label = type(item) == "table" and item.label or tostring(item)
      local value = type(item) == "table" and item.value or ""
      if value ~= "" and value == filters.status then
        return label .. " (current)"
      end
      return label
    end,
  }, function(choice)
    if type(choice) ~= "table" then
      return
    end

    local ok, next_filters = update_file_filters(state, {
      status = choice.value,
    })
    if ok then
      vim.notify("PR Review file status filter: " .. (next_filters.status or "all"), vim.log.levels.INFO)
    end
  end)
end

M.filter_files_by_extension = function(state)
  local filters = current_file_filters(state)
  vim.ui.input({
    prompt = "Filter PR files by extension:",
    default = type(filters.extension) == "string" and filters.extension or "",
  }, function(input)
    if input == nil then
      return
    end

    local extension = vim.trim(type(input) == "string" and input or ""):lower():gsub("^%.+", "")
    local ok = select(1, update_file_filters(state, {
      extension = extension,
    }))
    if ok then
      if extension == "" then
        vim.notify("PR Review file extension filter cleared", vim.log.levels.INFO)
      else
        vim.notify("PR Review file extension filter: " .. extension, vim.log.levels.INFO)
      end
    end
  end)
end

M.toggle_no_extension_filter = function(state)
  local filters = current_file_filters(state)
  local ok, next_filters = update_file_filters(state, {
    no_extension = not (filters.no_extension == true),
  })
  if ok then
    vim.notify("PR Review no-extension filter: " .. ((next_filters.no_extension == true) and "on" or "off"), vim.log.levels.INFO)
  end
end

M.toggle_dotfiles_filter = function(state)
  local filters = current_file_filters(state)
  local ok, next_filters = update_file_filters(state, {
    dotfiles = not (filters.dotfiles == true),
  })
  if ok then
    vim.notify("PR Review dotfiles filter: " .. ((next_filters.dotfiles == true) and "on" or "off"), vim.log.levels.INFO)
  end
end

M.toggle_unviewed_only_filter = function(state)
  local filters = current_file_filters(state)
  local next_value = filters.viewed_state == "unviewed" and "all" or "unviewed"
  local ok, next_filters = update_file_filters(state, {
    viewed_state = next_value,
  })
  if ok then
    vim.notify("PR Review viewed filter: " .. (next_filters.viewed_state or "all"), vim.log.levels.INFO)
  end
end

M.toggle_viewed_only_filter = function(state)
  local filters = current_file_filters(state)
  local next_value = filters.viewed_state == "viewed" and "all" or "viewed"
  local ok, next_filters = update_file_filters(state, {
    viewed_state = next_value,
  })
  if ok then
    vim.notify("PR Review viewed filter: " .. (next_filters.viewed_state or "all"), vim.log.levels.INFO)
  end
end

M.toggle_hide_viewed_filter = function(state)
  local filters = current_file_filters(state)
  local configured_hide_viewed = ((get_config().get() or {}).hide_viewed_files == true)
  local effective_hide_viewed = type(filters.hide_viewed) == "boolean" and filters.hide_viewed or configured_hide_viewed
  local ok, next_filters = update_file_filters(state, {
    hide_viewed = not effective_hide_viewed,
  })
  if ok then
    vim.notify(
      "PR Review hide viewed: " .. ((next_filters.hide_viewed == true) and "on" or "off"),
      vim.log.levels.INFO
    )
  end
end

M.toggle_hide_deleted_filter = function(state)
  local filters = current_file_filters(state)
  local ok, next_filters = update_file_filters(state, {
    hide_deleted = not (filters.hide_deleted == true),
  })
  if ok then
    vim.notify(
      "PR Review hide deleted: " .. ((next_filters.hide_deleted == true) and "on" or "off"),
      vim.log.levels.INFO
    )
  end
end

M.reset_file_filters = function(state)
  reset_file_filters(state)
end

M.toggle_files_flat_mode = function()
  local next_mode = not effective_review_files_flat_mode()
  local runtime_state = get_runtime_state()
  if type(runtime_state.set_pr_review_files_flat_pref) == "function" then
    runtime_state.set_pr_review_files_flat_pref(next_mode)
  end

  local label = next_mode and "list" or "tree"
  vim.notify("PR Review Files mode: " .. label, vim.log.levels.INFO)
  get_source().render_cached_states()
end

cc._add_common_commands(M)
return M
