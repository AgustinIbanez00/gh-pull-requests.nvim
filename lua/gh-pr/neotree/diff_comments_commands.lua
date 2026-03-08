local cc = require("neo-tree.sources.common.commands")

local M = {}

local function get_source()
  return require("gh-pr.neotree.diff_comments_source")
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

M.noop = function() end

M.refresh = function(_)
  get_source().refresh_current_tab()
end

M.gh_pr_diff_comments_open = function(state)
  local node = current_node(state)
  if not node then
    return
  end

  if node_kind(node) == "comment" then
    get_source().open_target(node.extra and node.extra.target, {
      keep_source_focus = false,
      open_popup = false,
    })
    return
  end

  if node_kind(node) == "message" then
    return
  end

  cc.toggle_node(state)
end

M.open_comment = function(state)
  local node = current_node(state)
  if not node or node_kind(node) ~= "comment" then
    return
  end

  get_source().open_target(node.extra and node.extra.target, {
    keep_source_focus = false,
    open_popup = true,
    popup_mode = "open",
    focus_thread_popup = true,
  })
end

M.preview_comment = function(state)
  local node = current_node(state)
  if not node or node_kind(node) ~= "comment" then
    return
  end

  get_source().open_target(node.extra and node.extra.target, {
    keep_source_focus = true,
    open_popup = true,
    popup_mode = "preview",
    focus_thread_popup = false,
  })
end

cc._add_common_commands(M)

return M
