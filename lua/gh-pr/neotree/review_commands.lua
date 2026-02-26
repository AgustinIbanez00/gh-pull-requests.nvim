local actions = require("gh-pr.actions")
local cc = require("neo-tree.sources.common.commands")
local source = require("gh-pr.neotree.review_source")
local runtime_state = require("gh-pr.state")

local renderer = require("neo-tree.ui.renderer")

local M = {}

local function current_node(state)
  if not state or not state.tree then
    return nil
  end

  return state.tree:get_node()
end

local function node_kind(node)
  return node and node.extra and node.extra.kind or nil
end

local function apply_context(node)
  if not node or type(node.extra) ~= "table" then
    return
  end

  if node.extra.pr then
    actions.set_active_pr(node.extra.pr, node.extra.details or node.extra.pr)
  end

  if node.extra.file then
    actions.set_active_file(node.extra.file)
  end
end

local function open_comment_target(node)
  local target = node.extra and node.extra.target
  if type(target) ~= "table" then
    return false
  end

  actions.open_comment_location(target, {
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

  actions.open_timeline_item(item, {
    pr = node.extra and node.extra.pr or nil,
    details = node.extra and node.extra.details or nil,
    origin_bufnr = vim.api.nvim_get_current_buf(),
  })
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

local function comments_by_file_node(state)
  local comments = comments_section_node(state)
  if not comments then
    return nil
  end
  return find_comment_subsection(state, comments, ":comments:by-file")
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

  for _, entry in ipairs(type(entries) == "table" and entries or {}) do
    if runtime_state.is_viewed(repo_name, pr_number, entry.path) ~= true then
      return true
    end
  end

  return false
end

local function confirm_directory_toggle(node, file_count, mark_viewed)
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
  local choice = vim.fn.confirm(prompt, "&Yes\n&No", 2)
  return choice == 1
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

M.noop = function() end

M.refresh = function(state)
  source.request_refresh(state, { force = true })
end

M.gh_pr_review_open = function(state)
  local node = current_node(state)
  if not node then
    return
  end

  apply_context(node)
  local kind = node_kind(node)

  if kind == "file" then
    actions.open_diff(node.extra and node.extra.file or nil)
    return
  end

  if kind == "overview" then
    actions.open_overview()
    return
  end

  if kind == "comment" or kind == "line" or kind == "comment_thread" or kind == "comment_thread_item" then
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
    actions.open_commit_diff(node.extra.commit)
    return
  end

  if kind == "check" and type(node.extra.check_url) == "string" and node.extra.check_url ~= "" then
    if vim.ui and type(vim.ui.open) == "function" then
      vim.ui.open(node.extra.check_url)
    else
      vim.notify("Check URL: " .. node.extra.check_url, vim.log.levels.INFO)
    end
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
  if node_kind(node) == "file" then
    actions.open_diff(node.extra and node.extra.file or nil)
  end
end

M.open_original = function(state)
  local node = current_node(state)
  if not node then
    return
  end

  apply_context(node)
  if node_kind(node) == "file" then
    actions.open_original(node.extra and node.extra.file or nil)
  end
end

M.open_modified = function(state)
  local node = current_node(state)
  if not node then
    return
  end

  apply_context(node)
  if node_kind(node) == "file" then
    actions.open_modified(node.extra and node.extra.file or nil)
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
    actions.mark_file_viewed(node.extra and node.extra.file or nil, nil)
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
    local confirmed = confirm_directory_toggle(node, #descendants, mark_viewed)
    if not confirmed then
      vim.notify("Folder viewed update cancelled", vim.log.levels.INFO)
      return
    end
  end

  actions.mark_files_viewed(descendants, mark_viewed)
end

M.comment_file_global = function(state)
  local node = current_node(state)
  if not node then
    return
  end

  apply_context(node)
  if node_kind(node) == "file" then
    actions.add_file_global_comment(node.extra and node.extra.file or nil)
  end
end

M.edit_labels_multi = function(state)
  local node = current_node(state)
  if node then
    apply_context(node)
  end
  actions.overview_edit_stub("edit_labels", {})
end

M.edit_reviewers_multi = function(state)
  local node = current_node(state)
  if node then
    apply_context(node)
  end
  actions.overview_edit_stub("edit_reviewers", {})
end

M.open_overview = function(state)
  local node = current_node(state)
  if not node then
    return
  end

  apply_context(node)
  actions.open_overview()
end

M.start_review = function(state)
  local node = current_node(state)
  if not node then
    return
  end

  apply_context(node)
  local pr = node.extra and node.extra.pr or nil
  actions.start_review(pr and pr.number or nil)
end

M.toggle_review_tree = function()
  actions.toggle_review_tree()
end

M.submit_pending_comment_review = function(state)
  local node = current_node(state)
  if node then
    apply_context(node)
  end
  actions.submit_pending_comment_review()
end

M.submit_pending_approve_review = function(state)
  local node = current_node(state)
  if node then
    apply_context(node)
  end
  actions.submit_pending_approve_review()
end

M.submit_pending_request_changes_review = function(state)
  local node = current_node(state)
  if node then
    apply_context(node)
  end
  actions.submit_pending_request_changes_review()
end

M.discard_pending_review = function(state)
  local node = current_node(state)
  if node then
    apply_context(node)
  end
  actions.discard_pending_review()
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

M.expand_comments_by_file = function(state)
  expand_subtree(state, comments_by_file_node(state))
end

M.collapse_comments_by_file = function(state)
  collapse_subtree(state, comments_by_file_node(state))
end

M.expand_comments_global = function(state)
  expand_subtree(state, comments_global_node(state))
end

M.collapse_comments_global = function(state)
  collapse_subtree(state, comments_global_node(state))
end

cc._add_common_commands(M)
return M
