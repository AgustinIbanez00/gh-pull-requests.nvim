local FileDiff = {}

function FileDiff.register(M, ctx)
  local build_line_comment_context = ctx.build_line_comment_context
  local codediff_integration = ctx.codediff_integration
  local comment_popup = ctx.comment_popup
  local config = ctx.config
  local current_diff_view_preferences = ctx.current_diff_view_preferences
  local diff_actions = ctx.diff_actions
  local diff_shortcuts_config = ctx.diff_shortcuts_config
  local diff_view_core = ctx.diff_view_core
  local diff_view_runtime = ctx.diff_view_runtime
  local diff_view_shortcuts = ctx.diff_view_shortcuts
  local is_valid_buf = ctx.is_valid_buf
  local is_valid_win = ctx.is_valid_win
  local jump_to_line = ctx.jump_to_line
  local non_text_preview = ctx.non_text_preview
  local normalize_path = ctx.normalize_path
  local normalize_repository = ctx.normalize_repository
  local notify_error = ctx.notify_error
  local notify_info = ctx.notify_info
  local notify_warn = ctx.notify_warn
  local open_diff_with_forced_backend = ctx.open_diff_with_forced_backend
  local open_review_tree_from_plugin = ctx.open_review_tree_from_plugin
  local persist_diff_view_preferences = ctx.persist_diff_view_preferences
  local positive_integer = ctx.positive_integer
  local refresh_pr_sources_after_state_change = ctx.refresh_pr_sources_after_state_change
  local require_virtual_diff_backend = ctx.require_virtual_diff_backend
  local resolve_active_pr = ctx.resolve_active_pr
  local resolve_current_diff_file = ctx.resolve_current_diff_file
  local resolve_file = ctx.resolve_file
  local restore_cursor_line = ctx.restore_cursor_line
  local safe_string = ctx.safe_string
  local state = ctx.state
  local using_virtual_diff_backend = ctx.using_virtual_diff_backend
  local valid_window = ctx.valid_window
  local virtual_files = ctx.virtual_files

  local thread_diff_helpers = type(ctx.thread_diff_helpers) == "table" and ctx.thread_diff_helpers or {}
  local apply_codediff_open_result_context = thread_diff_helpers.apply_codediff_open_result_context
  local codediff_file_runtime = thread_diff_helpers.codediff_file_runtime
  local resolve_commit = thread_diff_helpers.resolve_commit
  local sync_diff_comments_panel = thread_diff_helpers.sync_diff_comments_panel

function M.open_diff(file, opts)
  opts = type(opts) == "table" and opts or {}
  local origin_win = vim.api.nvim_get_current_win()
  local pr, details, err = resolve_active_pr()
  if not pr then
    notify_error(err)
    return false
  end

  local selected_file = resolve_file(file)
  if not selected_file then
    notify_error("No file selected for diff")
    return false
  end

  state.set_active_file(selected_file)
  local selected_path = normalize_path(selected_file.path or selected_file.filename)
  local uses_non_text_preview = non_text_preview.file_uses_non_text_preview(selected_file)
  local comments_ctx = uses_non_text_preview and nil or build_line_comment_context(pr.number)

  local function open_with_codediff(diff_view)
    local opened_result, codediff_err = codediff_integration.open_pr_file_diff({
      details = details,
      file = selected_file,
      cache_scope = string.format(
        "pr-file|%d|%s|%s|%s",
        pr.number,
        safe_string(details.baseRefName),
        safe_string(details.headRefName),
        selected_path
      ),
      layout = diff_view.mode,
      ignore_trim_whitespace = diff_view.ignore_whitespace_mode == "trim",
      target_side = opts.target_side,
      target_line = opts.target_line,
      target_original_line = opts.target_original_line,
    })
    if not opened_result then
      return nil, codediff_err
    end

    apply_codediff_open_result_context(pr, details, selected_file, opened_result, {
      comments_ctx = comments_ctx,
      check_annotations_ctx = opts.check_annotations_ctx,
      security_annotations_ctx = opts.security_annotations_ctx,
    })
    sync_diff_comments_panel(pr, details, comments_ctx)
    return true, nil
  end

  local function open_with_virtual(open_opts)
    if is_valid_win(origin_win) then
      pcall(vim.api.nvim_set_current_win, origin_win)
    end
    local diff_result, diff_err = virtual_files.open_diff(details, pr, selected_file, {
      line_comments = comments_ctx,
      view_mode = open_opts.view.mode,
      ignore_whitespace_mode = open_opts.view.ignore_whitespace_mode,
      ignore_whitespace = open_opts.view.ignore_whitespace,
      render_whitespace = open_opts.view.render_whitespace,
      render_endlines = open_opts.view.render_endlines,
      new_tab = opts.new_tab,
    })
    if diff_err then
      return nil, diff_err
    end

    if type(diff_result) == "table" and diff_result.file_mode == "added_single" then
      notify_info("File is new in this PR. Opened single MODIFIED buffer (diff layouts disabled).")
    elseif type(diff_result) == "table" and diff_result.file_mode == "removed_single" then
      notify_info("File was removed in this PR. Opened single ORIGINAL buffer (diff layouts disabled).")
    end

    diff_view_runtime.focus_virtual_diff_result(diff_result, opts)

    sync_diff_comments_panel(pr, details, comments_ctx)
    return true, nil
  end

  local opened, open_err = diff_view_runtime.open_file_diff_with_backend({
    uses_non_text_preview = uses_non_text_preview,
    view_mode = opts.view_mode,
    ignore_whitespace_mode = opts.ignore_whitespace_mode,
    ignore_whitespace = opts.ignore_whitespace,
    render_whitespace = opts.render_whitespace,
    render_endlines = opts.render_endlines,
    open_codediff = open_with_codediff,
    open_virtual = function(diff_view)
      return open_with_virtual({
        view = diff_view,
      })
    end,
  })
  if opened == false then
    return false
  end
  if not opened then
    notify_error(open_err)
    return false
  end

  return true
end

function M.open_original(file, opts)
  opts = type(opts) == "table" and opts or {}
  local origin_win = vim.api.nvim_get_current_win()
  local pr, details, err = resolve_active_pr()
  if not pr then
    notify_error(err)
    return false
  end

  local selected_file = resolve_file(file)
  if not selected_file then
    notify_error("No file selected")
    return false
  end

  state.set_active_file(selected_file)
  local selected_path = normalize_path(selected_file.path or selected_file.filename)
  local target_line = positive_integer(opts.target_original_line, positive_integer(opts.target_line, nil))
  local uses_non_text_preview = non_text_preview.file_uses_non_text_preview(selected_file)
  local comments_ctx = uses_non_text_preview and nil or build_line_comment_context(pr.number)

  local function open_with_codediff()
    local opened_result, codediff_err = codediff_integration.open_pr_file_diff({
      details = details,
      file = selected_file,
      cache_scope = string.format(
        "pr-original|%d|%s|%s|%s",
        pr.number,
        safe_string(details.baseRefName),
        safe_string(details.headRefName),
        selected_path
      ),
      target_side = "base",
      target_original_line = target_line,
      target_line = target_line,
    })
    if not opened_result then
      return nil, codediff_err
    end

    apply_codediff_open_result_context(pr, details, selected_file, opened_result, {
      comments_ctx = comments_ctx,
      check_annotations_ctx = opts.check_annotations_ctx,
      security_annotations_ctx = opts.security_annotations_ctx,
    })
    sync_diff_comments_panel(pr, details, comments_ctx)
    return true, nil
  end

  local function open_with_virtual()
    if is_valid_win(origin_win) then
      pcall(vim.api.nvim_set_current_win, origin_win)
    end
    local _, open_err = virtual_files.open_original(details, pr, selected_file, {
      line_comments = comments_ctx,
    })
    if open_err then
      return nil, open_err
    end
    if type(target_line) == "number" then
      jump_to_line(target_line)
    end
    return true, nil
  end

  local opened, open_err
  if uses_non_text_preview then
    opened, open_err = open_with_virtual()
  else
    opened, open_err = open_diff_with_forced_backend({
      open_primary = open_with_codediff,
      open_virtual = open_with_virtual,
    })
  end
  if opened == false then
    return false
  end
  if not opened then
    notify_error(open_err)
    return false
  end
  return true
end

function M.open_modified(file, opts)
  opts = type(opts) == "table" and opts or {}
  local origin_win = vim.api.nvim_get_current_win()
  local pr, details, err = resolve_active_pr()
  if not pr then
    notify_error(err)
    return false
  end

  local selected_file = resolve_file(file)
  if not selected_file then
    notify_error("No file selected")
    return false
  end

  state.set_active_file(selected_file)
  local selected_path = normalize_path(selected_file.path or selected_file.filename)
  local target_line = positive_integer(opts.target_line, positive_integer(opts.target_original_line, nil))
  local uses_non_text_preview = non_text_preview.file_uses_non_text_preview(selected_file)
  local comments_ctx = uses_non_text_preview and nil or build_line_comment_context(pr.number)

  local function open_with_codediff()
    local opened_result, codediff_err = codediff_integration.open_pr_file_diff({
      details = details,
      file = selected_file,
      cache_scope = string.format(
        "pr-modified|%d|%s|%s|%s",
        pr.number,
        safe_string(details.baseRefName),
        safe_string(details.headRefName),
        selected_path
      ),
      target_side = "head",
      target_line = target_line,
      target_original_line = target_line,
    })
    if not opened_result then
      return nil, codediff_err
    end

    apply_codediff_open_result_context(pr, details, selected_file, opened_result, {
      comments_ctx = comments_ctx,
      check_annotations_ctx = opts.check_annotations_ctx,
      security_annotations_ctx = opts.security_annotations_ctx,
    })
    sync_diff_comments_panel(pr, details, comments_ctx)
    return true, nil
  end

  local function open_with_virtual()
    if is_valid_win(origin_win) then
      pcall(vim.api.nvim_set_current_win, origin_win)
    end
    local _, open_err = virtual_files.open_modified(details, pr, selected_file, {
      line_comments = comments_ctx,
    })
    if open_err then
      return nil, open_err
    end
    if type(target_line) == "number" then
      jump_to_line(target_line)
    end
    return true, nil
  end

  local opened, open_err
  if uses_non_text_preview then
    opened, open_err = open_with_virtual()
  else
    opened, open_err = open_diff_with_forced_backend({
      open_primary = open_with_codediff,
      open_virtual = open_with_virtual,
    })
  end
  if opened == false then
    return false
  end
  if not opened then
    notify_error(open_err)
    return false
  end
  return true
end

local function reopen_current_diff_with_preferences_impl(opts)
  opts = opts or {}

  local bufnr = vim.api.nvim_get_current_buf()
  local kind = vim.b[bufnr].gh_pr_file_kind
  if kind ~= "base" and kind ~= "head" and kind ~= "unified" then
    return false, "Current buffer is not a gh-pr file diff buffer"
  end

  local number = vim.b[bufnr].gh_pr_number
  if type(number) ~= "number" then
    return false, "Unable to resolve pull request number for current buffer"
  end

  local current_win = vim.api.nvim_get_current_win()
  local cursor = vim.api.nvim_win_get_cursor(current_win)

  local pr, details, err = resolve_active_pr(number, { refresh = opts.refresh == true })
  if not pr then
    return false, err
  end

  local selected_file = resolve_current_diff_file(details, bufnr)
  if not selected_file then
    return false, "Current file is no longer available in this pull request"
  end

  state.set_active_file(selected_file)
  local uses_non_text_preview = non_text_preview.file_uses_non_text_preview(selected_file)
  local comments_ctx = uses_non_text_preview and nil or build_line_comment_context(pr.number)
  local function open_with_codediff(diff_view)
    local opened_result, codediff_err = codediff_integration.open_pr_file_diff({
      details = details,
      file = selected_file,
      cache_scope = string.format(
        "pr-file|%d|%s|%s|%s",
        pr.number,
        safe_string(details.baseRefName),
        safe_string(details.headRefName),
        normalize_path(selected_file.path or selected_file.filename)
      ),
      layout = diff_view.mode,
      ignore_trim_whitespace = diff_view.ignore_whitespace_mode == "trim",
      target_side = kind == "base" and "base" or "head",
      target_line = cursor[1],
      target_original_line = cursor[1],
    })
    if not opened_result then
      return nil, codediff_err
    end

    apply_codediff_open_result_context(pr, details, selected_file, opened_result, {
      comments_ctx = comments_ctx,
    })
    sync_diff_comments_panel(pr, details, comments_ctx)
    return true, nil
  end

  local function open_with_virtual(open_opts)
    local diff_result, open_err = virtual_files.open_diff(details, pr, selected_file, {
      line_comments = comments_ctx,
      view_mode = open_opts.view.mode,
      ignore_whitespace_mode = open_opts.view.ignore_whitespace_mode,
      ignore_whitespace = open_opts.view.ignore_whitespace,
      render_whitespace = open_opts.view.render_whitespace,
      render_endlines = open_opts.view.render_endlines,
      new_tab = opts.new_tab,
    })
    if open_err then
      return nil, open_err
    end
    diff_view_runtime.focus_virtual_diff_result(diff_result, {
      target_side = kind == "base" and "base" or "head",
      target_line = cursor[1],
      target_original_line = cursor[1],
    })
    sync_diff_comments_panel(pr, details, comments_ctx)
    return true, nil
  end

  local ok_open, open_err = diff_view_runtime.open_file_diff_with_backend({
    uses_non_text_preview = uses_non_text_preview,
    view_mode = opts.view_mode,
    ignore_whitespace_mode = opts.ignore_whitespace_mode,
    ignore_whitespace = opts.ignore_whitespace,
    render_whitespace = opts.render_whitespace,
    render_endlines = opts.render_endlines,
    open_codediff = open_with_codediff,
    open_virtual = function(diff_view)
      return open_with_virtual({
        view = diff_view,
      })
    end,
  })
  if ok_open ~= true then
    return ok_open, open_err
  end

  local active_win = vim.api.nvim_get_current_win()
  if is_valid_win(current_win) then
    pcall(vim.api.nvim_set_current_win, current_win)
    restore_cursor_line(current_win, cursor[1])
  else
    restore_cursor_line(active_win, cursor[1])
  end

  return true, nil
end

function M.reopen_current_diff_with_preferences(opts)
  local ok, err = reopen_current_diff_with_preferences_impl(opts or {})
  if not ok then
    notify_error(err)
    return false
  end
  return true
end

function M.refresh_current_diff_buffer()
  if not using_virtual_diff_backend() then
    return notify_warn(virtual_only_feature_message("Diff buffer refresh"))
  end

  local bufnr = vim.api.nvim_get_current_buf()
  local kind = vim.b[bufnr].gh_pr_file_kind
  if kind ~= "base" and kind ~= "head" and kind ~= "unified" and kind ~= "patch" then
    return notify_error("Current buffer is not a gh-pr diff buffer")
  end

  local display_path = vim.b[bufnr].gh_pr_file_path or vim.b[bufnr].gh_pr_path or "(unknown file)"

  local number = vim.b[bufnr].gh_pr_number
  if type(number) ~= "number" then
    return notify_error("Unable to resolve pull request number for current buffer")
  end

  if kind == "patch" then
    local current_win = vim.api.nvim_get_current_win()
    local cursor = vim.api.nvim_win_get_cursor(current_win)
    local commit = resolve_commit()
    if commit then
      M.open_commit_diff(commit)
      local active_win = vim.api.nvim_get_current_win()
      restore_cursor_line(active_win, cursor[1])
      refresh_pr_sources_after_state_change({ force = true })
      return
    end
    return notify_error("Patch buffer can only be refreshed for commit diffs")
  end

  local ok, reopen_err = reopen_current_diff_with_preferences_impl({
    refresh = true,
    new_tab = false,
  })
  if not ok then
    refresh_pr_sources_after_state_change({ force = true })
    return notify_error(reopen_err)
  end

  refresh_pr_sources_after_state_change({ force = true })
  notify_info(string.format("Refreshed %s from GitHub", display_path))
end

-- Forward declarations used by quick-close actions defined below.
local find_diff_pair_windows_for_current_file
local close_current_diff_view
local open_review_tree_after_close
local close_window_if_valid
local delete_buffer_if_valid

function M.close_quick()
  local kind = vim.b.gh_pr_file_kind
  if kind ~= "base" and kind ~= "head" and kind ~= "unified" and kind ~= "patch" then
    return notify_error("Current buffer is not a gh-pr diff buffer")
  end

  local base_win, head_win = find_diff_pair_windows_for_current_file()
  if valid_window(base_win) and valid_window(head_win) then
    local head_buf = vim.api.nvim_win_get_buf(head_win)
    close_window_if_valid(head_win)
    delete_buffer_if_valid(head_buf)
    if valid_window(base_win) then
      pcall(vim.api.nvim_set_current_win, base_win)
    end
    return
  end

  close_current_diff_view()
  local ok_panel, panel = pcall(require, "gh-pr.diff_comments_panel")
  if ok_panel and type(panel.close_current_tab) == "function" then
    pcall(panel.close_current_tab)
  end
  open_review_tree_after_close()
end

function M.close_all_and_open_review()
  local ok_panel, panel = pcall(require, "gh-pr.diff_comments_panel")
  if ok_panel and type(panel.close_current_tab) == "function" then
    pcall(panel.close_current_tab, { respect_close_with_dq = true })
  end

  local kind = vim.b.gh_pr_file_kind
  if kind ~= "base" and kind ~= "head" and kind ~= "unified" and kind ~= "patch" then
    local current_tab = vim.api.nvim_get_current_tabpage()
    for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(current_tab)) do
      if valid_window(winid) then
        local bufnr = vim.api.nvim_win_get_buf(winid)
        local candidate_kind = vim.b[bufnr].gh_pr_file_kind
        if candidate_kind == "base" or candidate_kind == "head" or candidate_kind == "unified" or candidate_kind == "patch" then
          pcall(vim.api.nvim_set_current_win, winid)
          kind = candidate_kind
          break
        end
      end
    end
  end

  if kind ~= "base" and kind ~= "head" and kind ~= "unified" and kind ~= "patch" then
    open_review_tree_after_close()
    return
  end

  local base_win, head_win = find_diff_pair_windows_for_current_file()
  if valid_window(base_win) and valid_window(head_win) then
    local base_buf = vim.api.nvim_win_get_buf(base_win)
    local head_buf = vim.api.nvim_win_get_buf(head_win)

    close_window_if_valid(head_win)
    close_window_if_valid(base_win)
    delete_buffer_if_valid(head_buf)
    delete_buffer_if_valid(base_buf)
  else
    close_current_diff_view()
  end

  open_review_tree_after_close()
end

find_diff_pair_windows_for_current_file = function()
  local tab = vim.api.nvim_get_current_tabpage()
  local base_win, head_win
  local current_number = vim.b.gh_pr_number
  local current_path = normalize_path(vim.b.gh_pr_file_path or vim.b.gh_pr_path)

  for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
    if valid_window(winid) then
      local bufnr = vim.api.nvim_win_get_buf(winid)
      local kind = vim.b[bufnr].gh_pr_file_kind
      if kind == "base" or kind == "head" or kind == "unified" then
        local number = vim.b[bufnr].gh_pr_number
        local path = normalize_path(vim.b[bufnr].gh_pr_file_path or vim.b[bufnr].gh_pr_path)
        local same_number = type(current_number) ~= "number" or number == current_number
        local same_path = current_path == "" or path == "" or path == current_path

        if same_number and same_path then
          if kind == "base" and not base_win then
            base_win = winid
          elseif (kind == "head" or kind == "unified") and not head_win then
            head_win = winid
          end
        end
      end
    end
  end

  return base_win, head_win
end

close_window_if_valid = function(winid)
  if not valid_window(winid) then
    return false
  end

  return pcall(vim.api.nvim_win_close, winid, true)
end

delete_buffer_if_valid = function(bufnr)
  if not is_valid_buf(bufnr) then
    return false
  end

  return pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
end

close_current_diff_view = function()
  local winid = vim.api.nvim_get_current_win()
  local bufnr = vim.api.nvim_get_current_buf()
  local tab_wins = vim.api.nvim_tabpage_list_wins(vim.api.nvim_get_current_tabpage())

  if #tab_wins > 1 then
    if close_window_if_valid(winid) then
      delete_buffer_if_valid(bufnr)
      return
    end
  end

  delete_buffer_if_valid(bufnr)
end

open_review_tree_after_close = function()
  local opened, open_err = open_review_tree_from_plugin({ toggle = false })
  if not opened and open_err then
    notify_warn("Closed diff view but could not open PR Review: " .. tostring(open_err))
  end
end

local function diff_actions_context()
  return {
    current_diff_view_preferences = current_diff_view_preferences,
    normalize_repository = normalize_repository,
    notify_error = notify_error,
    open_diff = M.open_diff,
    resolve_active_pr = resolve_active_pr,
    state = state,
  }
end

function M.next_file()
  diff_actions.next_file(diff_actions_context())
end

function M.prev_file()
  diff_actions.prev_file(diff_actions_context())
end

function M.next_reviewed_file()
  diff_actions.next_reviewed_file(diff_actions_context())
end

function M.prev_reviewed_file()
  diff_actions.prev_reviewed_file(diff_actions_context())
end

function M.next_change()
  diff_actions.next_change()
end

function M.prev_change()
  diff_actions.prev_change()
end

function diff_view_runtime.ensure_current_diff_compare_toggle(feature)
  local bufnr = vim.api.nvim_get_current_buf()
  local kind = vim.b[bufnr].gh_pr_file_kind
  if kind ~= "base" and kind ~= "head" and kind ~= "unified" then
    notify_warn("Current buffer is not a gh-pr file diff buffer")
    return false
  end

  if vim.b[bufnr].gh_pr_is_non_text == true or vim.b[bufnr].gh_pr_is_image == true then
    notify_warn(string.format("%s is not available for non-text diff buffers.", feature))
    return false
  end

  return true
end

function M.toggle_diff_whitespace()
  if not diff_view_runtime.ensure_current_diff_compare_toggle("Whitespace diff toggle") then
    return
  end

  local prefs = current_diff_view_preferences()
  prefs.ignore_whitespace_mode = prefs.ignore_whitespace_mode == "none" and "trim" or "none"
  prefs = persist_diff_view_preferences(prefs)

  local reopened = M.reopen_current_diff_with_preferences({
    ignore_whitespace_mode = prefs.ignore_whitespace_mode,
    new_tab = false,
  })
  if not reopened then
    return
  end
  notify_info(string.format("Diff whitespace mode: %s", diff_view_core.whitespace_mode_label(prefs.ignore_whitespace_mode)))
end

function M.cycle_diff_whitespace_mode()
  if not diff_view_runtime.ensure_current_diff_compare_toggle("Whitespace diff mode cycle") then
    return
  end

  local prefs = current_diff_view_preferences()
  prefs.ignore_whitespace_mode = diff_view_core.cycle_whitespace_mode(prefs.ignore_whitespace_mode)
  prefs = persist_diff_view_preferences(prefs)

  local reopened = M.reopen_current_diff_with_preferences({
    ignore_whitespace_mode = prefs.ignore_whitespace_mode,
    new_tab = false,
  })
  if not reopened then
    return
  end

  notify_info(string.format("Diff whitespace mode: %s", diff_view_core.whitespace_mode_label(prefs.ignore_whitespace_mode)))
end

function M.toggle_diff_render_whitespace()
  if not require_virtual_diff_backend("Whitespace rendering toggle") then
    return
  end

  local prefs = current_diff_view_preferences()
  prefs.render_whitespace = not prefs.render_whitespace
  prefs = persist_diff_view_preferences(prefs)

  local reopened = M.reopen_current_diff_with_preferences({
    new_tab = false,
  })
  if not reopened then
    return
  end

  notify_info(string.format("Whitespace/tab rendering: %s", prefs.render_whitespace and "enabled" or "disabled"))
end

function M.toggle_diff_render_endlines()
  if not require_virtual_diff_backend("Endline rendering toggle") then
    return
  end

  local prefs = current_diff_view_preferences()
  prefs.render_endlines = not prefs.render_endlines
  prefs = persist_diff_view_preferences(prefs)

  local reopened = M.reopen_current_diff_with_preferences({
    new_tab = false,
  })
  if not reopened then
    return
  end

  notify_info(string.format("Endline rendering: %s", prefs.render_endlines and "enabled" or "disabled"))
end

function M.cycle_diff_view_mode()
  if not diff_view_runtime.ensure_current_diff_compare_toggle("Diff layout toggle") then
    return
  end

  local order = { "vertical", "horizontal", "unified" }
  local prefs = current_diff_view_preferences()
  local index = 1
  for i, mode in ipairs(order) do
    if mode == prefs.mode then
      index = i
      break
    end
  end

  prefs.mode = order[(index % #order) + 1]
  prefs = persist_diff_view_preferences(prefs)

  local reopened = M.reopen_current_diff_with_preferences({
    view_mode = prefs.mode,
    new_tab = false,
  })
  if not reopened then
    return
  end
  notify_info(string.format("Diff mode: %s", prefs.mode))
end

function M.set_diff_view_mode(mode)
  if not diff_view_runtime.ensure_current_diff_compare_toggle("Diff layout selection") then
    return
  end

  local prefs = current_diff_view_preferences({
    mode = mode,
  })
  prefs = persist_diff_view_preferences(prefs)

  local reopened = M.reopen_current_diff_with_preferences({
    view_mode = prefs.mode,
    new_tab = false,
  })
  if not reopened then
    return
  end
  notify_info(string.format("Diff mode: %s", prefs.mode))
end

function M.set_diff_view_mode_vertical()
  M.set_diff_view_mode("vertical")
end

function M.set_diff_view_mode_horizontal()
  M.set_diff_view_mode("horizontal")
end

function M.set_diff_view_mode_unified()
  M.set_diff_view_mode("unified")
end

local function shortcut_line(label, value)
  return string.format("%-7s %s", label, value)
end

diff_view_runtime.codediff_help_defaults = {
  quit = "q",
  show_help = "g?",
  toggle_layout = "t",
  next_hunk = "]c",
  prev_hunk = "[c",
  diff_get = "do",
  diff_put = "dp",
  open_in_prev_tab = "gf",
  align_move = "gm",
}

function diff_view_runtime.codediff_help_keymaps()
  local keymaps = vim.deepcopy(diff_view_runtime.codediff_help_defaults)
  local compute_moves = false
  local ok, codediff_config = pcall(require, "codediff.config")

  if ok and type(codediff_config) == "table" then
    local options = type(codediff_config.options) == "table" and codediff_config.options or {}
    local view = type(options.keymaps) == "table" and type(options.keymaps.view) == "table" and options.keymaps.view or {}
    local diff = type(options.diff) == "table" and options.diff or {}

    for name, fallback in pairs(keymaps) do
      if type(view[name]) == "string" and view[name] ~= "" then
        keymaps[name] = view[name]
      else
        keymaps[name] = fallback
      end
    end

    compute_moves = diff.compute_moves == true
  end

  return keymaps, compute_moves
end

local function diff_shortcut_lines(bufnr)
  local kind = type(vim.b[bufnr].gh_pr_file_kind) == "string" and vim.b[bufnr].gh_pr_file_kind or "head"
  local file_mode = type(vim.b[bufnr].gh_pr_file_mode) == "string" and vim.b[bufnr].gh_pr_file_mode or ""
  local is_image = vim.b[bufnr].gh_pr_is_image == true
  local is_non_text = vim.b[bufnr].gh_pr_is_non_text == true or is_image
  local asset_label = is_image and "image" or "non-text"
  local backend = diff_view_runtime.current_diff_backend(bufnr)
  local codediff_layout = diff_view_runtime.current_codediff_layout(bufnr)
  local codediff_inline = backend == "codediff" and codediff_layout == "inline"
  local virtual_unified = backend ~= "codediff" and kind == "unified"
  local prefs = current_diff_view_preferences()
  local shortcuts = diff_view_shortcuts(backend)
  local image_opts = non_text_preview.image_diff_options()
  local image_default_action = non_text_preview.resolve_default_action(image_opts)
  local configured_diff = (config.get() or {}).diff_view or {}
  local configured_whitespace = type(configured_diff.whitespace) == "table" and configured_diff.whitespace or {}
  local whitespace_tab = type(configured_whitespace.tab) == "string" and configured_whitespace.tab ~= ""
      and configured_whitespace.tab
    or ">-"
  local whitespace_space = type(configured_whitespace.space) == "string" and configured_whitespace.space ~= ""
      and configured_whitespace.space
    or "."
  local whitespace_mode_label = diff_view_core.whitespace_mode_label(prefs.ignore_whitespace_mode)

  local mode_label = prefs.mode
  if backend == "codediff" then
    mode_label = codediff_inline and "unified" or "side-by-side"
  elseif file_mode == "added_single" then
    mode_label = "single (added file)"
  elseif file_mode == "removed_single" then
    mode_label = "single (removed file)"
  elseif mode_label == "vertical" then
    mode_label = "vertical split"
  elseif mode_label == "horizontal" then
    mode_label = "horizontal split"
  else
    mode_label = "unified"
  end
  if is_non_text then
    mode_label = mode_label .. string.format(" (%s)", asset_label)
  end

  local function add_shortcut(lines, key, description)
    local label = diff_view_runtime.display_keybinding(key)
    if label ~= "" then
      lines[#lines + 1] = shortcut_line(label, description)
    end
  end

  local function add_visual_shortcut(lines, key, description)
    local label = diff_view_runtime.display_keybinding(key)
    if label ~= "" then
      lines[#lines + 1] = shortcut_line("Visual + " .. label, description)
    end
  end

  local lines = {
    "gh-pr diff shortcuts",
    "",
    "Diff render state",
    shortcut_line("backend", backend),
    shortcut_line("mode", mode_label),
    shortcut_line("spaces", is_non_text and string.format("n/a (%s)", asset_label) or whitespace_mode_label),
  }
  if backend ~= "codediff" then
    lines[#lines + 1] = shortcut_line("render", is_non_text and string.format("n/a (%s)", asset_label) or (prefs.render_whitespace and "visible" or "hidden"))
    lines[#lines + 1] = shortcut_line("endline", is_non_text and string.format("n/a (%s)", asset_label) or (prefs.render_endlines and "visible" or "hidden"))
    lines[#lines + 1] = shortcut_line("tab", is_non_text and "n/a" or whitespace_tab)
    lines[#lines + 1] = shortcut_line("space", is_non_text and "n/a" or whitespace_space)
  else
    lines[#lines + 1] = shortcut_line("render", "virtual-only markers unavailable in codediff")
    lines[#lines + 1] = shortcut_line("endline", "virtual-only markers unavailable in codediff")
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "General"

  if is_non_text then
    lines[#lines + 1] = shortcut_line("-", string.format("Line comments popup not available for %s files", asset_label))
  else
    add_shortcut(lines, shortcuts.line_comments_popup, "Show line comments popup")
    lines[#lines + 1] = shortcut_line("<CR>", "Open line comments popup on commented lines")
    lines[#lines + 1] = shortcut_line("popup r / R / x", "Reply, quote-reply, or resolve/unresolve the selected thread")
  end
  add_shortcut(lines, shortcuts.help, "Show this help")
  if backend ~= "codediff" then
    add_shortcut(lines, shortcuts.refresh, "Refresh current diff from GitHub")
  end
  add_shortcut(lines, shortcuts.close_quick, "Quick close (or close head in 2-way diff)")
  add_shortcut(lines, shortcuts.close_all_open_review, "Close view(s) and open PR Review")
  add_shortcut(lines, shortcuts.toggle_comments_panel, "Toggle diff comments panel")

  if backend ~= "codediff" and not is_non_text then
    add_shortcut(lines, shortcuts.toggle_render_whitespace, "Toggle leading/trailing space/tab symbols")
    add_shortcut(lines, shortcuts.toggle_render_endlines, "Toggle LF/CRLF endline markers")
  end

  if is_non_text then
    lines[#lines + 1] = shortcut_line("-", string.format("Whitespace and diff layout toggles disabled for %s files", asset_label))
  else
    add_shortcut(lines, shortcuts.toggle_whitespace, "Toggle whitespace mode (strict/trim)")
    add_shortcut(lines, shortcuts.cycle_whitespace_mode, "Cycle whitespace mode")
    add_shortcut(lines, shortcuts.cycle_mode, "Cycle diff mode")
    add_shortcut(lines, shortcuts.set_vertical, "Set vertical split")
    add_shortcut(lines, shortcuts.set_horizontal, "Set horizontal split")
    add_shortcut(lines, shortcuts.set_unified, "Set unified mode")
    if backend == "codediff" then
      lines[#lines + 1] = shortcut_line("-", "Layout changes reopen this file with the hybrid diff backend")
    elseif file_mode == "added_single" or file_mode == "removed_single" then
      lines[#lines + 1] = shortcut_line("-", "Single-file diffs may reopen in codediff for compatible layouts")
    end
  end

  if backend == "codediff" then
    local codediff_keys, codediff_moves = diff_view_runtime.codediff_help_keymaps()

    lines[#lines + 1] = ""
    lines[#lines + 1] = "codediff native"
    add_shortcut(lines, codediff_keys.quit, "Close codediff tab (native)")
    add_shortcut(lines, codediff_keys.show_help, "Show codediff keymap help (native)")
    add_shortcut(lines, codediff_keys.toggle_layout, "Toggle codediff layout (side-by-side <-> inline)")
    add_shortcut(lines, codediff_keys.next_hunk, "Next codediff hunk")
    add_shortcut(lines, codediff_keys.prev_hunk, "Previous codediff hunk")
    add_shortcut(lines, codediff_keys.diff_get, codediff_inline and "Revert hunk to original (codediff)" or "Get change from other buffer (codediff)")
    add_shortcut(lines, codediff_keys.diff_put, codediff_inline and "Accept change (no-op in inline codediff)" or "Put change to other buffer (codediff)")
    add_shortcut(lines, codediff_keys.open_in_prev_tab, "Open current file in previous tab (codediff)")
    if codediff_moves and not codediff_inline then
      add_shortcut(lines, codediff_keys.align_move, "Align moved code block (codediff)")
    end
    lines[#lines + 1] = shortcut_line("-", "Horizontal split remains available only in the gh-pr virtual backend")
  end

  if is_non_text then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Non-text preview"
    add_shortcut(
      lines,
      shortcuts.image_default_action,
      string.format("Run default preview action (%s)", non_text_preview.action_label(image_default_action, image_opts))
    )
    add_shortcut(lines, shortcuts.image_fallback_menu, "Open preview actions menu")
    lines[#lines + 1] = shortcut_line("<CR>", "Run action under cursor when focused on an action row")
    lines[#lines + 1] = shortcut_line("-", "Menu allows setting default action (`d`/`s`)")
  end

  lines[#lines + 1] = ""
  lines[#lines + 1] = "Navigation"
  if is_non_text then
    lines[#lines + 1] = shortcut_line("-", string.format("Change navigation disabled for %s files", asset_label))
  else
    add_shortcut(lines, shortcuts.next_change, "Next change")
    add_shortcut(lines, shortcuts.prev_change, "Previous change")
  end
  add_shortcut(lines, shortcuts.next_file, "Next file in PR")
  add_shortcut(lines, shortcuts.prev_file, "Previous file in PR")
  add_shortcut(lines, shortcuts.next_reviewed_file, "Next reviewed file")
  add_shortcut(lines, shortcuts.prev_reviewed_file, "Previous reviewed file")
  lines[#lines + 1] = ""
  lines[#lines + 1] = "Pending review"
  add_shortcut(lines, shortcuts.submit_pending_comment, "Submit pending review as comment")
  add_shortcut(lines, shortcuts.submit_pending_approve, "Submit pending review as approve")
  add_shortcut(lines, shortcuts.submit_pending_request_changes, "Submit pending review as request changes")
  add_shortcut(lines, shortcuts.discard_pending_review, "Discard pending review")
  add_shortcut(lines, shortcuts.toggle_review_tree, "Toggle PR Review source")

  lines[#lines + 1] = ""
  lines[#lines + 1] = "Inline comments"

  if is_non_text then
    add_shortcut(lines, shortcuts.inline_comment, string.format("Not available for %s files", asset_label))
    add_shortcut(lines, shortcuts.inline_suggestion, string.format("Not available for %s files", asset_label))
  elseif kind == "head" and file_mode == "added_single" then
    add_shortcut(lines, shortcuts.inline_comment, "Create inline comment at cursor (any line)")
    add_visual_shortcut(lines, shortcuts.inline_comment, "Create inline comment on selected range")
    add_shortcut(lines, shortcuts.inline_suggestion, "Create inline suggestion at cursor (any line)")
    add_visual_shortcut(lines, shortcuts.inline_suggestion, "Create inline suggestion on selected range")
  elseif kind == "head" then
    add_shortcut(lines, shortcuts.inline_comment, "Create inline comment at cursor")
    add_visual_shortcut(lines, shortcuts.inline_comment, "Create inline comment on selected range")
    add_shortcut(lines, shortcuts.inline_suggestion, "Create inline suggestion at cursor")
    add_visual_shortcut(lines, shortcuts.inline_suggestion, "Create inline suggestion on selected range")
  elseif virtual_unified then
    add_shortcut(lines, shortcuts.inline_comment, "Create inline comment on added (+) line")
    add_visual_shortcut(lines, shortcuts.inline_comment, "Create inline comment on added (+) range")
    add_shortcut(lines, shortcuts.inline_suggestion, "Create inline suggestion on added (+) line")
    add_visual_shortcut(lines, shortcuts.inline_suggestion, "Create inline suggestion on added (+) range")
  elseif codediff_inline then
    add_shortcut(lines, shortcuts.inline_comment, "Create inline comment at cursor")
    add_visual_shortcut(lines, shortcuts.inline_comment, "Create inline comment on selected range")
    add_shortcut(lines, shortcuts.inline_suggestion, "Create inline suggestion at cursor")
    add_visual_shortcut(lines, shortcuts.inline_suggestion, "Create inline suggestion on selected range")
  else
    add_shortcut(lines, shortcuts.inline_comment, "Only available on MODIFIED (head) or unified")
    add_shortcut(lines, shortcuts.inline_suggestion, "Only available on MODIFIED (head) or unified")
  end

  lines[#lines + 1] = ""
  lines[#lines + 1] = "Close help: q or <Esc>"
  return lines
end

function M.show_diff_shortcuts()
  local bufnr = vim.api.nvim_get_current_buf()
  local kind = type(vim.b[bufnr].gh_pr_file_kind) == "string" and vim.b[bufnr].gh_pr_file_kind or "unknown"
  local pr_number = type(vim.b[bufnr].gh_pr_number) == "number" and vim.b[bufnr].gh_pr_number or nil
  local path = type(vim.b[bufnr].gh_pr_path) == "string" and vim.b[bufnr].gh_pr_path or "?"

  local title = "PR diff shortcuts"
  if pr_number then
    title = string.format("PR #%d diff shortcuts", pr_number)
  end

  local ok, popup_err = comment_popup.open({
    origin_bufnr = bufnr,
    tag = "shortcuts",
    title = title,
    location = string.format("%s (%s)", path, kind),
    lines = diff_shortcut_lines(bufnr),
    mode = "open",
    enter = true,
    position = "editor",
    border = "rounded",
    wrap = false,
    min_width = 56,
    min_height = 18,
    max_width = 120,
    max_height = 40,
    close_on_origin_move = false,
    filetype = "markdown",
  })

  if not ok and popup_err then
    notify_warn("Unable to open shortcuts help: " .. tostring(popup_err))
  end
end

  FileDiff.diff_shortcut_lines = diff_shortcut_lines
  FileDiff.codediff_file_runtime = codediff_file_runtime
end

return FileDiff
