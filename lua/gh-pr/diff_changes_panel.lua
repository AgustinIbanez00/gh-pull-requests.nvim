local config = require("gh-pr.config")
local diff_hunks = require("gh-pr.core.diff_hunks")

local M = {}

local sessions = {}
local suppressed_auto_open = {}
local namespace = vim.api.nvim_create_namespace("gh-pr-diff-changes-panel")

local function valid_buf(bufnr)
  return type(bufnr) == "number" and bufnr > 0 and vim.api.nvim_buf_is_valid(bufnr)
end

local function valid_win(winid)
  return type(winid) == "number" and winid > 0 and vim.api.nvim_win_is_valid(winid)
end

local function valid_tab(tabid)
  return type(tabid) == "number" and tabid > 0 and vim.api.nvim_tabpage_is_valid(tabid)
end

local function normalize_path(path)
  if type(path) ~= "string" then
    return ""
  end
  return path:gsub("\\", "/")
end

local function int(value, fallback)
  local n = tonumber(value)
  if not n then
    return fallback
  end
  n = math.floor(n)
  if n < 1 then
    return fallback
  end
  return n
end

local function panel_opts()
  local diff_view = (config.get() or {}).diff_view or {}
  local src = type(diff_view.changes_panel) == "table" and diff_view.changes_panel or {}
  local min_width = int(src.min_width, 24)
  local max_width = int(src.max_width, 50)
  if max_width < min_width then
    max_width = min_width
  end
  local width = int(src.width, 34)
  width = math.max(min_width, math.min(max_width, width))
  local position = type(src.position) == "string" and src.position:lower() or "right"
  if position ~= "left" and position ~= "right" then
    position = "right"
  end

  return {
    enabled = src.enabled ~= false,
    auto_open = src.auto_open ~= false,
    position = position,
    width = width,
    min_width = min_width,
    max_width = max_width,
  }
end

local function close_session(tabid)
  local session = sessions[tabid]
  sessions[tabid] = nil
  if not session then
    return false
  end
  if valid_win(session.winid) then
    pcall(vim.api.nvim_win_close, session.winid, true)
  end
  if valid_buf(session.bufnr) then
    pcall(vim.api.nvim_buf_delete, session.bufnr, { force = true })
  end
  return true
end

local function get_session(tabid)
  local session = sessions[tabid]
  if not session then
    return nil
  end
  if not valid_buf(session.bufnr) or not valid_win(session.winid) then
    close_session(tabid)
    return nil
  end
  return session
end

local function current_diff_entry(winid, bufnr)
  if not valid_win(winid) then
    return nil
  end
  bufnr = valid_buf(bufnr) and bufnr or vim.api.nvim_win_get_buf(winid)
  if not valid_buf(bufnr) then
    return nil
  end
  local kind = vim.b[bufnr].gh_pr_file_kind
  if kind ~= "base" and kind ~= "head" and kind ~= "unified" then
    return nil
  end
  return {
    winid = winid,
    bufnr = bufnr,
    kind = kind,
    pr_number = tonumber(vim.b[bufnr].gh_pr_number),
    path = normalize_path(vim.b[bufnr].gh_pr_file_path or vim.b[bufnr].gh_pr_path),
    non_text = vim.b[bufnr].gh_pr_is_non_text == true or vim.b[bufnr].gh_pr_is_image == true,
  }
end

local function diff_windows(tabid, pr_number, path)
  local out = {}
  if not valid_tab(tabid) then
    return out
  end
  local normalized = normalize_path(path)
  for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(tabid)) do
    local entry = current_diff_entry(winid)
    if entry
      and (not pr_number or entry.pr_number == pr_number)
      and (normalized == "" or entry.path == "" or entry.path == normalized) then
      out[#out + 1] = entry
    end
  end
  return out
end

local function resolve_target(ctx)
  ctx = type(ctx) == "table" and ctx or {}
  local origin_win = tonumber(ctx.origin_win)
  local origin_buf = tonumber(ctx.origin_buf)
  local origin = current_diff_entry(origin_win, origin_buf)
  if origin then
    return origin
  end

  local current = current_diff_entry(vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf())
  if current then
    return current
  end

  local path = normalize_path(ctx.file_path)
  local pr_number = tonumber(ctx.pr_number or (ctx.pr and ctx.pr.number) or vim.b.gh_pr_number)
  for _, entry in ipairs(diff_windows(vim.api.nvim_get_current_tabpage(), pr_number, path)) do
    return entry
  end

  if pr_number or path ~= "" then
    return {
      winid = origin_win,
      bufnr = origin_buf,
      kind = type(ctx.file_kind) == "string" and ctx.file_kind or "head",
      pr_number = pr_number,
      path = path,
      non_text = ctx.non_text == true,
    }
  end
  return nil
end

local function hunks_from_visible_buffers(tabid, pr_number, path)
  local windows = diff_windows(tabid, pr_number, path)
  local base_buf, head_buf, unified_buf, single_buf, file_mode
  for _, entry in ipairs(windows) do
    local mode = vim.b[entry.bufnr].gh_pr_file_mode
    if entry.kind == "base" then
      base_buf = entry.bufnr
    elseif entry.kind == "head" then
      head_buf = entry.bufnr
    elseif entry.kind == "unified" then
      unified_buf = entry.bufnr
    end
    if mode == "added_single" or mode == "removed_single" then
      single_buf = entry.bufnr
      file_mode = mode
    end
  end
  if valid_buf(unified_buf) then
    return diff_hunks.from_unified_line_map(vim.b[unified_buf].gh_pr_unified_line_map)
  end
  if valid_buf(single_buf) then
    return diff_hunks.from_single_buffer(single_buf, file_mode)
  end
  if valid_buf(base_buf) and valid_buf(head_buf) then
    return diff_hunks.from_buffers(base_buf, head_buf)
  end
  return {}
end

local function build_hunks(ctx, tabid, target)
  ctx = type(ctx) == "table" and ctx or {}
  if type(ctx.hunks) == "table" then
    return vim.deepcopy(ctx.hunks)
  end
  if type(ctx.open_result) == "table" then
    local hunks = diff_hunks.from_codediff_open_result(ctx.open_result)
    if #hunks > 0 then
      return hunks
    end
  end
  if type(ctx.diff_result) == "table" then
    local hunks = diff_hunks.from_virtual_result(ctx.diff_result)
    if #hunks > 0 then
      return hunks
    end
  end
  return hunks_from_visible_buffers(tabid, target and target.pr_number or nil, target and target.path or nil)
end

local function create_session(tabid)
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].readonly = true
  vim.bo[bufnr].filetype = "gh_pr_diff_changes"
  vim.api.nvim_buf_set_name(bufnr, "gh-pr://diff-changes/" .. tostring(tabid))

  local session = {
    tabid = tabid,
    bufnr = bufnr,
    winid = nil,
    actions = {},
    hunks = {},
    pr_number = nil,
    path = "",
    target = nil,
  }
  sessions[tabid] = session
  return session
end

local function apply_highlights(session, highlights)
  if not valid_buf(session.bufnr) then
    return
  end
  vim.api.nvim_buf_clear_namespace(session.bufnr, namespace, 0, -1)
  for _, item in ipairs(highlights or {}) do
    local line = tonumber(item.line)
    if line and line > 0 then
      local text = vim.api.nvim_buf_get_lines(session.bufnr, line - 1, line, false)[1] or ""
      vim.api.nvim_buf_set_extmark(session.bufnr, namespace, line - 1, 0, {
        end_col = #text,
        hl_group = item.group,
      })
    end
  end
end

local function apply_render(session)
  local path = session.path ~= "" and session.path or "(unknown file)"
  local lines = {
    string.format("PR #%d changes", tonumber(session.pr_number) or 0),
    path,
    "Enter: jump | q: close",
    "",
  }
  local actions = {}
  local highlights = {
    { line = 1, group = "GhPrDiffChangesHeader" },
    { line = 2, group = "GhPrDiffChangesMuted" },
    { line = 3, group = "GhPrDiffChangesMuted" },
  }

  if #session.hunks == 0 then
    lines[#lines + 1] = "No navigable hunks for this file."
    highlights[#highlights + 1] = { line = #lines, group = "GhPrDiffChangesMuted" }
  else
    for _, hunk in ipairs(session.hunks) do
      local target = hunk.target_side == "base" and "base" or (hunk.target_side == "unified" and "diff" or "head")
      local line = string.format(
        "%2d. L%-5d %-4s +%-3d -%-3d",
        hunk.index or (#actions + 1),
        tonumber(hunk.target_line) or 1,
        target,
        tonumber(hunk.added) or 0,
        tonumber(hunk.deleted) or 0
      )
      lines[#lines + 1] = line
      actions[#lines] = { hunk = hunk }
      highlights[#highlights + 1] = { line = #lines, group = "GhPrDiffChangesLine" }
    end
  end

  session.actions = actions
  vim.bo[session.bufnr].modifiable = true
  vim.bo[session.bufnr].readonly = false
  vim.api.nvim_buf_set_lines(session.bufnr, 0, -1, false, lines)
  vim.bo[session.bufnr].readonly = true
  vim.bo[session.bufnr].modifiable = false
  pcall(vim.api.nvim_set_option_value, "modified", false, { buf = session.bufnr })
  apply_highlights(session, highlights)
end

local function apply_keymaps(session)
  if session.keymaps then
    return
  end
  session.keymaps = true

  local function map(lhs, rhs, desc)
    vim.keymap.set("n", lhs, rhs, { buffer = session.bufnr, silent = true, nowait = true, desc = desc })
  end

  map("<CR>", function()
    if not valid_win(session.winid) then
      return
    end
    local line = vim.api.nvim_win_get_cursor(session.winid)[1]
    M.jump(session.actions[line])
  end, "GH PR diff changes: jump to hunk")
  map("q", function()
    M.close_current_tab({ suppress_auto_open = true })
  end, "GH PR diff changes: close panel")
  map("<Esc>", function()
    M.close_current_tab({ suppress_auto_open = true })
  end, "GH PR diff changes: close panel")
end

local function ensure_window(session, opts, enter)
  if valid_win(session.winid) then
    if vim.api.nvim_win_get_buf(session.winid) ~= session.bufnr then
      vim.api.nvim_win_set_buf(session.winid, session.bufnr)
    end
    pcall(vim.api.nvim_win_set_width, session.winid, opts.width)
    pcall(vim.api.nvim_set_option_value, "winfixwidth", true, { win = session.winid })
    if enter == true then
      pcall(vim.api.nvim_set_current_win, session.winid)
    end
    return true
  end

  local origin = vim.api.nvim_get_current_win()
  local anchor = valid_win(session.target and session.target.winid) and session.target.winid or origin
  pcall(vim.api.nvim_set_current_win, anchor)
  if opts.position == "left" then
    vim.cmd("topleft vertical " .. tostring(opts.width) .. "split")
  else
    vim.cmd("botright vertical " .. tostring(opts.width) .. "split")
  end
  session.winid = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(session.winid, session.bufnr)
  pcall(vim.api.nvim_win_set_width, session.winid, opts.width)
  pcall(vim.api.nvim_set_option_value, "winfixwidth", true, { win = session.winid })
  if not enter and valid_win(origin) and origin ~= session.winid then
    pcall(vim.api.nvim_set_current_win, origin)
  end
  return true
end

local function open_or_refresh(ctx, force_open)
  local opts = panel_opts()
  local tabid = vim.api.nvim_get_current_tabpage()
  if not opts.enabled then
    close_session(tabid)
    if force_open then
      return nil, "Diff changes panel is disabled by config"
    end
    return false, nil
  end

  local target = resolve_target(ctx)
  if not target then
    if force_open then
      return nil, "Current buffer is not a gh-pr diff buffer"
    end
    return false, nil
  end

  if target.non_text then
    close_session(tabid)
    if force_open then
      return nil, "No hunk navigation is available for non-text previews"
    end
    return false, nil
  end

  local hunks = build_hunks(ctx, tabid, target)
  if #hunks == 0 and not force_open then
    close_session(tabid)
    return false, nil
  end

  local existing = get_session(tabid)
  local should_open = force_open or existing ~= nil or (opts.auto_open and not suppressed_auto_open[tabid])
  if not should_open then
    return false, nil
  end

  local session = existing or create_session(tabid)
  session.pr = type(ctx) == "table" and ctx.pr or session.pr
  session.details = type(ctx) == "table" and ctx.details or session.details
  session.pr_number = target.pr_number or tonumber(ctx.pr_number or (ctx.pr and ctx.pr.number)) or session.pr_number
  session.path = target.path
  session.target = target
  session.hunks = hunks
  apply_keymaps(session)
  apply_render(session)
  ensure_window(session, opts, force_open == true)
  return true, nil
end

function M.sync_for_diff(ctx)
  return open_or_refresh(type(ctx) == "table" and ctx or {}, false)
end

function M.toggle(ctx)
  local tabid = vim.api.nvim_get_current_tabpage()
  if get_session(tabid) then
    suppressed_auto_open[tabid] = true
    return close_session(tabid), nil
  end
  suppressed_auto_open[tabid] = nil
  return open_or_refresh(type(ctx) == "table" and ctx or {}, true)
end

function M.jump(action)
  if type(action) ~= "table" or type(action.hunk) ~= "table" then
    return false
  end
  local hunk = action.hunk
  local tabid = vim.api.nvim_get_current_tabpage()
  local session = get_session(tabid)
  if not session then
    return false
  end

  local destination
  for _, entry in ipairs(diff_windows(tabid, session.pr_number, session.path)) do
    if hunk.target_side == "unified" and entry.kind == "unified" then
      destination = entry.winid
      break
    elseif hunk.target_side == "base" and entry.kind == "base" then
      destination = entry.winid
      break
    elseif hunk.target_side ~= "base" and entry.kind == "head" then
      destination = entry.winid
      break
    elseif not destination then
      destination = entry.winid
    end
  end

  if not valid_win(destination) then
    return false
  end

  local bufnr = vim.api.nvim_win_get_buf(destination)
  local max_line = math.max(1, vim.api.nvim_buf_line_count(bufnr))
  local line = math.max(1, math.min(max_line, int(hunk.target_line, 1)))
  pcall(vim.api.nvim_set_current_win, destination)
  pcall(vim.api.nvim_win_set_cursor, destination, { line, 0 })
  return true
end

function M.is_open_current_tab()
  return get_session(vim.api.nvim_get_current_tabpage()) ~= nil
end

function M.close_current_tab(opts)
  opts = type(opts) == "table" and opts or {}
  local tabid = vim.api.nvim_get_current_tabpage()
  if opts.suppress_auto_open == true then
    suppressed_auto_open[tabid] = true
  end
  return close_session(tabid)
end

function M.close_all()
  for _, tabid in ipairs(vim.tbl_keys(sessions)) do
    close_session(tabid)
  end
end

M._private = {
  build_hunks = build_hunks,
  panel_opts = panel_opts,
}

return M
