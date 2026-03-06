local cc = require("neo-tree.sources.common.commands")
local manager = require("neo-tree.sources.manager")

local M = {}

local function get_actions()
  return require("gh-pr.actions")
end

local function get_comments_source()
  return require("gh-pr.neotree.comments_source")
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

local function apply_context(node)
  if not node or type(node.extra) ~= "table" then
    return
  end

  if node.extra.pr and node.extra.details then
    get_actions().set_active_pr(node.extra.pr, node.extra.details)
  end
end

local function open_target_from_node(node)
  if not node then
    return
  end

  local target = node.extra and node.extra.target
  if type(target) == "table" then
    get_actions().open_comment_location(target, {
      open_thread_popup = true,
      popup_mode = "open",
      focus_thread_popup = true,
    })
  end
end

local function preview_target_from_node(node)
  if not node then
    return
  end

  local target = node.extra and node.extra.target
  if type(target) == "table" then
    get_actions().preview_comment_location(target, {
      open_thread_popup = true,
      popup_mode = "preview",
      focus_thread_popup = true,
    })
  end
end

M.noop = function() end

M.refresh = function(state)
  get_comments_source().invalidate_cache()
  manager.refresh("gh_pr_comments", state)
end

M.gh_pr_comments_open = function(state)
  local node = current_node(state)
  if not node then
    return
  end

  apply_context(node)
  local kind = node_kind(node)
  if kind == "comment" or kind == "line" then
    open_target_from_node(node)
    return
  end

  if kind == "message" then
    return
  end

  cc.toggle_node(state)
end

M.open_comment = function(state)
  local node = current_node(state)
  if not node then
    return
  end

  apply_context(node)
  open_target_from_node(node)
end

M.preview_comment = function(state)
  local node = current_node(state)
  if not node then
    return
  end

  apply_context(node)
  local kind = node_kind(node)
  if kind == "comment" or kind == "line" then
    preview_target_from_node(node)
  end
end

cc._add_common_commands(M)
return M
