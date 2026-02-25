local M = {}

local function normalize_path(path)
  if type(path) ~= "string" then
    return ""
  end

  return (path:gsub("\\", "/"))
end

M.normalize_path = normalize_path

local function buffer_filetype(bufnr)
  if type(bufnr) ~= "number" or bufnr < 1 or not vim.api.nvim_buf_is_valid(bufnr) then
    return nil
  end

  local ok, filetype = pcall(vim.api.nvim_get_option_value, "filetype", { buf = bufnr })
  if ok then
    return filetype
  end

  return vim.bo[bufnr].filetype
end

local function is_pr_diff_kind(kind)
  return kind == "base" or kind == "head" or kind == "unified"
end

function M.is_pr_diff_buffer(bufnr)
  if type(bufnr) ~= "number" or bufnr < 1 or not vim.api.nvim_buf_is_valid(bufnr) then
    return false
  end

  local kind = vim.b[bufnr].gh_pr_file_kind
  return is_pr_diff_kind(kind)
end

local function context_from_buffer(bufnr)
  if not M.is_pr_diff_buffer(bufnr) then
    return nil
  end

  local pr_number = tonumber(vim.b[bufnr].gh_pr_number)
  local path = normalize_path(vim.b[bufnr].gh_pr_file_path or vim.b[bufnr].gh_pr_path)
  if not pr_number or path == "" then
    return nil
  end

  return {
    bufnr = bufnr,
    pr_number = pr_number,
    path = path,
    repo = type(vim.b[bufnr].gh_pr_repo) == "string" and vim.b[bufnr].gh_pr_repo or nil,
  }
end

function M.resolve_buffer_context()
  local current_buf = vim.api.nvim_get_current_buf()
  local current = context_from_buffer(current_buf)
  if current then
    return current
  end

  local alternate_nr = tonumber(vim.fn.winnr("#")) or 0
  if alternate_nr > 0 then
    local alternate_win = vim.fn.win_getid(alternate_nr)
    if type(alternate_win) == "number" and alternate_win > 0 and vim.api.nvim_win_is_valid(alternate_win) then
      local alternate_buf = vim.api.nvim_win_get_buf(alternate_win)
      local alternate = context_from_buffer(alternate_buf)
      if alternate then
        return alternate
      end
    end
  end

  return nil
end

function M.visible_source_states(source_name)
  local states = {}
  local manager_ok, manager = pcall(require, "neo-tree.sources.manager")
  if not manager_ok or type(manager.get_state_for_window) ~= "function" then
    return states
  end

  local seen = {}
  for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_is_valid(winid) then
      local bufnr = vim.api.nvim_win_get_buf(winid)
      if buffer_filetype(bufnr) == "neo-tree" and vim.b[bufnr].neo_tree_source == source_name then
        local ok, state = pcall(manager.get_state_for_window, winid)
        if ok and type(state) == "table" and not seen[tostring(state)] then
          states[#states + 1] = state
          seen[tostring(state)] = true
        end
      end
    end
  end

  return states
end

function M.find_file_node(state, matcher)
  if type(state) ~= "table" or type(state.tree) ~= "table" or type(matcher) ~= "function" then
    return nil
  end

  local renderer_ok, renderer = pcall(require, "neo-tree.ui.renderer")
  if not renderer_ok or type(renderer.select_nodes) ~= "function" then
    return nil
  end

  local ok, nodes = pcall(renderer.select_nodes, state.tree, function(node)
    if type(node) ~= "table" then
      return false
    end

    local extra = node.extra
    if type(extra) ~= "table" or extra.kind ~= "file" then
      return false
    end

    local file = type(extra.file) == "table" and extra.file or {}
    local entry = {
      node = node,
      pr_number = tonumber(extra.pr and extra.pr.number),
      path = normalize_path(file.path or file.filename or node.path),
      previous_path = normalize_path(file.previousFilename or file.previous_filename),
      repo = type(extra.repo) == "string" and extra.repo or nil,
    }

    return matcher(entry) == true
  end, 1)

  if not ok or type(nodes) ~= "table" then
    return nil
  end

  return nodes[1]
end

function M.focus_node_without_steal(state, node_or_id)
  local renderer_ok, renderer = pcall(require, "neo-tree.ui.renderer")
  if not renderer_ok then
    return false, nil
  end

  local node = node_or_id
  if type(node_or_id) == "string" and type(state) == "table" and type(state.tree) == "table" then
    local ok, resolved = pcall(state.tree.get_node, state.tree, node_or_id)
    if ok then
      node = resolved
    end
  end

  if type(node) ~= "table" then
    return false, nil
  end

  local node_id = type(node.get_id) == "function" and node:get_id() or node.id
  if type(node_id) ~= "string" or node_id == "" then
    return false, nil
  end

  if type(renderer.expand_to_node) == "function" then
    pcall(renderer.expand_to_node, state, node)
  end

  local ok, focused = pcall(renderer.focus_node, state, node_id, true)
  if not ok or focused ~= true then
    return false, node_id
  end

  return true, node_id
end

return M
