local actions = require("gh-pr.actions")
local cc = require("neo-tree.sources.common.commands")
local source = require("gh-pr.neotree.review_source")

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
  if node_kind(node) == "file" then
    actions.mark_file_viewed(node.extra and node.extra.file or nil, nil)
  end
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

cc._add_common_commands(M)
return M
