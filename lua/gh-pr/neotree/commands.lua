local actions = require("gh-pr.actions")
local cc = require("neo-tree.sources.common.commands")
local manager = require("neo-tree.sources.manager")

local M = {}

local function current_node(state)
  if not state or not state.tree then
    return nil
  end

  return state.tree:get_node()
end

local function apply_context(node)
  if not node or type(node.extra) ~= "table" then
    return
  end

  if node.extra.pr and node.extra.details then
    actions.set_active_pr(node.extra.pr, node.extra.details)
  end

  if node.extra.file then
    actions.set_active_file(node.extra.file)
  end
end

local function node_kind(node)
  return node and node.extra and node.extra.kind or nil
end

local function has_pr_context(node)
  return node and node.extra and node.extra.pr ~= nil
end

M.noop = function() end

M.refresh = function(state)
  manager.refresh("gh_pr", state)
end

M.gh_pr_open = function(state)
  local node = current_node(state)
  if not node then
    return
  end

  apply_context(node)

  local kind = node_kind(node)
  if kind == "file" then
    actions.open_diff(node.extra.file)
    return
  end

  if kind == "overview" then
    actions.open_overview()
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
  actions.open_diff(node.extra and node.extra.file or nil)
end

M.open_original = function(state)
  local node = current_node(state)
  if not node then
    return
  end

  apply_context(node)
  actions.open_original(node.extra and node.extra.file or nil)
end

M.open_modified = function(state)
  local node = current_node(state)
  if not node then
    return
  end

  apply_context(node)
  actions.open_modified(node.extra and node.extra.file or nil)
end

M.open_overview = function(state)
  local node = current_node(state)
  if not node then
    return
  end

  apply_context(node)
  actions.open_overview()
end

M.open_comments_tree = function(state)
  local node = current_node(state)
  if not node then
    return
  end

  apply_context(node)
  vim.cmd("GhPrComments")
end

M.checkout_pr = function(state)
  local node = current_node(state)
  if not node then
    return
  end

  apply_context(node)
  actions.checkout()
end

M.toggle_viewed = function(state)
  local node = current_node(state)
  if not node then
    return
  end

  apply_context(node)
  actions.mark_file_viewed(node.extra and node.extra.file or nil, nil)
end

M.mark_viewed = function(state)
  local node = current_node(state)
  if not node then
    return
  end

  apply_context(node)
  actions.mark_file_viewed(node.extra and node.extra.file or nil, true)
end

M.mark_unviewed = function(state)
  local node = current_node(state)
  if not node then
    return
  end

  apply_context(node)
  actions.mark_file_viewed(node.extra and node.extra.file or nil, false)
end

M.approve_review = function(state)
  local node = current_node(state)
  if not node or not has_pr_context(node) then
    return
  end

  apply_context(node)
  actions.review("approve")
end

M.request_changes_review = function(state)
  local node = current_node(state)
  if not node or not has_pr_context(node) then
    return
  end

  apply_context(node)
  actions.review("request_changes")
end

M.comment_review = function(state)
  local node = current_node(state)
  if not node or not has_pr_context(node) then
    return
  end

  apply_context(node)
  actions.review("comment")
end

M.merge_pr = function(state)
  local node = current_node(state)
  if not node or not has_pr_context(node) then
    return
  end

  apply_context(node)
  actions.merge()
end

cc._add_common_commands(M)
return M
