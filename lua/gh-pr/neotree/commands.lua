local cc = require("neo-tree.sources.common.commands")

local M = {}

local function get_actions()
  return require("gh-pr.actions")
end

local function get_source()
  return require("gh-pr.neotree.source")
end

local function get_telescope()
  return require("gh-pr.integrations.telescope")
end

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

  local actions = get_actions()
  if node.extra.pr then
    actions.set_active_pr(node.extra.pr, node.extra.details or node.extra.pr)
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

M.noop = function() end

M.refresh = function(state)
  get_source().request_refresh(state, { force = true })
end

M.gh_pr_open = function(state)
  local node = current_node(state)
  if not node then
    return
  end

  apply_context(node)

  local kind = node_kind(node)
  if kind == "file" then
    get_actions().open_diff(node.extra.file)
    return
  end

  if kind == "overview" then
    open_overview_from_source(node)
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
  get_actions().open_diff(node.extra and node.extra.file or nil)
end

M.open_original = function(state)
  local node = current_node(state)
  if not node then
    return
  end

  apply_context(node)
  get_actions().open_original(node.extra and node.extra.file or nil)
end

M.open_modified = function(state)
  local node = current_node(state)
  if not node then
    return
  end

  apply_context(node)
  get_actions().open_modified(node.extra and node.extra.file or nil)
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
  local pr = node.extra and node.extra.pr or nil
  get_actions().open_overview_url(pr and pr.number or nil)
end

M.open_comments_tree = function(state)
  local node = current_node(state)
  if not node then
    return
  end

  apply_context(node)
  vim.cmd("GhPrComments")
end

M.open_telescope_actions = function(state)
  local node = current_node(state)
  if node then
    apply_context(node)
  end

  get_telescope().open_context_actions(nil, {
    load_error = "Unable to load Telescope fallback actions",
  })
end

M.checkout_pr = function(state)
  local node = current_node(state)
  if not node then
    return
  end

  apply_context(node)
  get_actions().checkout()
end

M.toggle_viewed = function(state)
  local node = current_node(state)
  if not node then
    return
  end

  apply_context(node)
  get_actions().mark_file_viewed(node.extra and node.extra.file or nil, nil)
end

M.mark_viewed = function(state)
  local node = current_node(state)
  if not node then
    return
  end

  apply_context(node)
  get_actions().mark_file_viewed(node.extra and node.extra.file or nil, true)
end

M.mark_unviewed = function(state)
  local node = current_node(state)
  if not node then
    return
  end

  apply_context(node)
  get_actions().mark_file_viewed(node.extra and node.extra.file or nil, false)
end

M.approve_review = function(state)
  local node = current_node(state)
  if not node or not has_pr_context(node) then
    return
  end

  apply_context(node)
  get_actions().review("approve")
end

M.request_changes_review = function(state)
  local node = current_node(state)
  if not node or not has_pr_context(node) then
    return
  end

  apply_context(node)
  get_actions().review("request_changes")
end

M.comment_review = function(state)
  local node = current_node(state)
  if not node or not has_pr_context(node) then
    return
  end

  apply_context(node)
  get_actions().review("comment")
end

M.discard_pending_review = function(state)
  local node = current_node(state)
  if node then
    apply_context(node)
  end

  get_actions().discard_pending_review()
end

M.merge_pr = function(state)
  local node = current_node(state)
  if not node or not has_pr_context(node) then
    return
  end

  apply_context(node)
  get_actions().merge()
end

M.start_review = function(state)
  local node = current_node(state)
  if not node or not has_pr_context(node) then
    return
  end

  apply_context(node)
  local pr = node.extra and node.extra.pr or nil
  get_actions().start_review(pr and pr.number or nil)
end

cc._add_common_commands(M)
return M
