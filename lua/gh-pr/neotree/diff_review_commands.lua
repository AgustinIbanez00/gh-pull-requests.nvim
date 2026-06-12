local cc = require("neo-tree.sources.common.commands")

local M = {}

local function get_source()
  return require("gh-pr.neotree.diff_review_source")
end

local function current_node(state)
  if not state or not state.tree then return nil end
  return state.tree:get_node()
end

local function node_kind(node)
  return node and node.extra and node.extra.kind or nil
end

M.noop = function() end

M.refresh = function(_)
  get_source().refresh_current_tab()
end

M.gh_pr_diff_review_open = function(state)
  local node = current_node(state)
  if not node then return end

  local kind = node_kind(node)

  if kind == "change" then
    local source = get_source()
    local tabid = vim.api.nvim_get_current_tabpage()
    local sessions = source._sessions
    local session = sessions and sessions[tabid]
    local hunk = node.extra and node.extra.hunk
    local pr_number = session and session.pr_number or (node.extra and node.extra.pr and node.extra.pr.number)
    local path = session and session.target_path or (node.extra and node.extra.path)
    if hunk then
      source.jump_to_hunk(hunk, pr_number, path)
    end
    return
  end

  if kind == "comment" then
    get_source().open_target(node.extra and node.extra.target, {
      keep_source_focus = false,
      open_popup = false,
    })
    return
  end

  if kind == "message" then return end

  cc.toggle_node(state)
end

M.open_comment = function(state)
  local node = current_node(state)
  if not node or node_kind(node) ~= "comment" then return end
  get_source().open_target(node.extra and node.extra.target, {
    keep_source_focus = false,
    open_popup = true,
    popup_mode = "open",
    focus_thread_popup = true,
  })
end

M.preview_comment = function(state)
  local node = current_node(state)
  if not node or node_kind(node) ~= "comment" then return end
  get_source().open_target(node.extra and node.extra.target, {
    keep_source_focus = true,
    open_popup = true,
    popup_mode = "preview",
    focus_thread_popup = false,
  })
end

cc._add_common_commands(M)

return M
