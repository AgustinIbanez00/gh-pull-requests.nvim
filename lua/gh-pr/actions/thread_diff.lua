local ThreadDiff = {}
local repository = require("gh-pr.core.repository")

function ThreadDiff.register(M, ctx)
  local apply_codediff_open_result_context = ctx.apply_codediff_open_result_context
  local buffer_filetype = ctx.buffer_filetype
  local build_line_comment_context = ctx.build_line_comment_context
  local codediff_integration = ctx.codediff_integration
  local config = ctx.config
  local codediff_file_runtime = ctx.codediff_file_runtime
  local diff_view_shortcuts = ctx.diff_view_shortcuts
  local diff_view_runtime = ctx.diff_view_runtime
  local is_valid_buf = ctx.is_valid_buf
  local is_valid_win = ctx.is_valid_win
  local line_comments = ctx.line_comments
  local non_text_preview = ctx.non_text_preview
  local normalize_path = ctx.normalize_path
  local normalize_repository = ctx.normalize_repository
  local notify_error = ctx.notify_error
  local notify_info = ctx.notify_info
  local notify_warn = ctx.notify_warn
  local open_diff_with_forced_backend = ctx.open_diff_with_forced_backend
  local positive_integer = ctx.positive_integer
  local pr_service = ctx.pr_service
  local resolve_active_pr = ctx.resolve_active_pr
  local resolve_canonical_file_path = ctx.resolve_canonical_file_path
  local safe_string = ctx.safe_string
  local state = ctx.state
  local url_open = ctx.url_open
  local virtual_files = ctx.virtual_files
local function resolve_commit(commit)
  if type(commit) == "table" and type(commit.oid) == "string" and commit.oid ~= "" then
    return commit
  end

  local bufnr = vim.api.nvim_get_current_buf()
  if buffer_filetype(bufnr) == "neo-tree" and vim.b[bufnr].neo_tree_source == "gh_pr_review" then
    local manager_ok, manager = pcall(require, "neo-tree.sources.manager")
    if manager_ok and type(manager.get_state_for_window) == "function" then
      local winid = vim.api.nvim_get_current_win()
      local ok_state, tree_state = pcall(manager.get_state_for_window, winid)
      if ok_state and type(tree_state) == "table" and type(tree_state.tree) == "table" then
        local node = tree_state.tree:get_node()
        local extra = type(node) == "table" and type(node.extra) == "table" and node.extra or nil
        local kind = type(extra) == "table" and extra.kind or nil
        if (kind == "commit" or kind == "commit_file")
          and type(extra.commit) == "table"
          and type(extra.commit.oid) == "string"
          and extra.commit.oid ~= "" then
          return extra.commit
        end
      end
    end
  end

  local oid = vim.b[bufnr].gh_pr_commit_oid
  if type(oid) == "string" and oid ~= "" then
    return {
      oid = oid,
      url = vim.b[bufnr].gh_pr_commit_url,
    }
  end

  return nil
end

local function open_commit_url(commit)
  local url = type(commit) == "table" and type(commit.url) == "string" and commit.url or ""
  if url == "" then
    return false
  end
  local ok_open = url_open.open(url, {
    notify_error = true,
    context = "Unable to open commit URL",
  })
  return ok_open == true
end

local function fetch_commit_details_for_pr(pr, details, selected_commit)
  local repository = normalize_repository(details) or ""
  return pr_service.fetch_commit_details(pr.number, selected_commit.oid, {
    repository = repository,
  })
end

local function normalize_commit_file_for_diff(file)
  if type(file) ~= "table" then
    return nil
  end

  local path = file.path or file.filename
  if type(path) ~= "string" or path == "" then
    return nil
  end

  local previous = file.previous_filename or file.previousFilename
  if type(previous) ~= "string" then
    previous = ""
  end

  return {
    path = path,
    filename = type(file.filename) == "string" and file.filename ~= "" and file.filename or path,
    previous_filename = previous,
    previousFilename = previous,
    status = type(file.status) == "string" and file.status or "",
    additions = tonumber(file.additions) or 0,
    deletions = tonumber(file.deletions) or 0,
    patch = type(file.patch) == "string" and file.patch or "",
  }
end

local function repository_object_from_full_name(full_name)
  return repository.to_api_object(full_name)
end

local function build_commit_diff_details(details, commit_details)
  local diff_details = vim.deepcopy(type(details) == "table" and details or {})
  diff_details.baseRefName = type(commit_details.parent_oid) == "string" and commit_details.parent_oid or ""
  diff_details.headRefName = type(commit_details.oid) == "string" and commit_details.oid or ""

  local repository = repository_object_from_full_name(commit_details.repository)
  if type(diff_details.baseRepository) ~= "table" and repository then
    diff_details.baseRepository = vim.deepcopy(repository)
  end
  if type(diff_details.headRepository) ~= "table" then
    if repository then
      diff_details.headRepository = vim.deepcopy(repository)
    elseif type(diff_details.baseRepository) == "table" then
      diff_details.headRepository = vim.deepcopy(diff_details.baseRepository)
    end
  end
  if type(diff_details.baseRepository) ~= "table" and type(diff_details.headRepository) == "table" then
    diff_details.baseRepository = vim.deepcopy(diff_details.headRepository)
  end

  if (type(diff_details.url) ~= "string" or diff_details.url == "")
    and type(commit_details.url) == "string"
    and commit_details.url ~= "" then
    diff_details.url = commit_details.url
  end

  return diff_details
end

local function collect_alternate_paths(file, ...)
  local seen = {}
  local paths = {}

  local function add(path)
    local normalized = normalize_path(path)
    if normalized == "" or seen[normalized] then
      return
    end
    seen[normalized] = true
    paths[#paths + 1] = normalized
  end

  if type(file) == "table" then
    add(file.path)
    add(file.filename)
    add(file.previous_filename)
    add(file.previousFilename)
  end

  for index = 1, select("#", ...) do
    add(select(index, ...))
  end

  return paths
end

function codediff_file_runtime.current_open_result(tabpage)
  if type(tabpage) ~= "number" or tabpage < 1 or not vim.api.nvim_tabpage_is_valid(tabpage) then
    return nil
  end

  local ok_lifecycle, lifecycle = pcall(require, "codediff.ui.lifecycle")
  if not ok_lifecycle or type(lifecycle.get_session) ~= "function" then
    return nil
  end

  local session = lifecycle.get_session(tabpage)
  if type(session) ~= "table" then
    return nil
  end

  local base_buf = tonumber(session.original_bufnr)
  local head_buf = tonumber(session.modified_bufnr)
  if not is_valid_buf(base_buf) or not is_valid_buf(head_buf) then
    return nil
  end

  return {
    mode = "file",
    tabpage = tabpage,
    base_buf = base_buf,
    head_buf = head_buf,
    base_win = session.original_win,
    head_win = session.modified_win,
    layout = session.layout == "inline" and "inline" or "side-by-side",
    diff_result = type(session.stored_diff_result) == "table" and session.stored_diff_result or nil,
  }, session
end

function codediff_file_runtime.clear(tabpage)
  if type(tabpage) ~= "number" then
    return
  end
  codediff_file_runtime.by_tabpage[tabpage] = nil
end

function codediff_file_runtime.ensure_autocmds()
  if codediff_file_runtime.autocmds_attached then
    return
  end

  codediff_file_runtime.autocmds_attached = true
  local group = vim.api.nvim_create_augroup("GhPrCodediffFileRuntime", { clear = true })

  vim.api.nvim_create_autocmd({ "BufEnter", "BufWinEnter", "WinEnter", "TabEnter" }, {
    group = group,
    callback = function()
      vim.schedule(function()
        codediff_file_runtime.rehydrate(vim.api.nvim_get_current_tabpage())
      end)
    end,
  })

  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "CodeDiffClose",
    callback = function(event)
      local tabpage = type(event.data) == "table" and tonumber(event.data.tabpage) or nil
      codediff_file_runtime.clear(tabpage)
    end,
  })
end

function codediff_file_runtime.register(open_result, payload)
  local tabpage = type(open_result) == "table" and tonumber(open_result.tabpage) or nil
  if type(tabpage) ~= "number" or tabpage < 1 or not vim.api.nvim_tabpage_is_valid(tabpage) then
    return
  end

  codediff_file_runtime.ensure_autocmds()

  local existing = codediff_file_runtime.by_tabpage[tabpage]
  local version = type(existing) == "table" and (tonumber(existing.version) or 0) or 0
  codediff_file_runtime.by_tabpage[tabpage] = {
    pr = vim.deepcopy(type(payload) == "table" and payload.pr or {}),
    details = vim.deepcopy(type(payload) == "table" and payload.details or {}),
    file = vim.deepcopy(type(payload) == "table" and payload.file or {}),
    comments_ctx = vim.deepcopy(type(payload) == "table" and payload.comments_ctx or nil),
    check_annotations_ctx = vim.deepcopy(type(payload) == "table" and payload.check_annotations_ctx or nil),
    security_annotations_ctx = vim.deepcopy(type(payload) == "table" and payload.security_annotations_ctx or nil),
    file_mode = type(payload) == "table" and safe_string(payload.file_mode, "") or "",
    version = version + 1,
    applied = type(existing) == "table" and existing.applied or nil,
  }
end

function codediff_file_runtime.build_inline_comment_line_map(open_result, comments_ctx, base_path, head_path, alternates)
  if type(comments_ctx) ~= "table"
    or type(comments_ctx.index) ~= "table"
    or type(open_result) ~= "table"
    or type(open_result.diff_result) ~= "table"
    or not is_valid_buf(open_result.base_buf)
    or not is_valid_buf(open_result.head_buf) then
    return nil
  end

  local base_line_map = line_comments.build_side_line_map(comments_ctx.index, "base", base_path, alternates)
  local head_line_map = line_comments.build_side_line_map(comments_ctx.index, "head", head_path, alternates)
  local render_line_map = {}
  local base_index = 1
  local head_index = 1
  local base_count = math.max(1, vim.api.nvim_buf_line_count(open_result.base_buf))
  local head_count = math.max(1, vim.api.nvim_buf_line_count(open_result.head_buf))

  local function anchor_for_deleted(mod_start)
    local anchor_line = tonumber(mod_start) or head_index
    anchor_line = math.max(1, math.min(anchor_line, head_count))
    return anchor_line
  end

  for _, mapping in ipairs(type(open_result.diff_result.changes) == "table" and open_result.diff_result.changes or {}) do
    local original = type(mapping.original) == "table" and mapping.original or {}
    local modified = type(mapping.modified) == "table" and mapping.modified or {}
    local orig_start = math.max(base_index, tonumber(original.start_line) or base_index)
    local orig_end = math.max(orig_start, tonumber(original.end_line) or orig_start)
    local mod_start = math.max(head_index, tonumber(modified.start_line) or head_index)
    local mod_end = math.max(mod_start, tonumber(modified.end_line) or mod_start)

    while base_index < orig_start and head_index < mod_start do
      line_comments.add_render_entries(render_line_map, head_index, base_line_map[base_index], "base")
      line_comments.add_render_entries(render_line_map, head_index, head_line_map[head_index], "head")
      base_index = base_index + 1
      head_index = head_index + 1
    end

    if orig_end > orig_start then
      local anchor_line = anchor_for_deleted(mod_start)
      for original_line = orig_start, orig_end - 1 do
        line_comments.add_render_entries(render_line_map, anchor_line, base_line_map[original_line], "base")
      end
    end

    if mod_end > mod_start then
      for modified_line = mod_start, mod_end - 1 do
        line_comments.add_render_entries(render_line_map, modified_line, head_line_map[modified_line], "head")
      end
    end

    base_index = orig_end
    head_index = mod_end
  end

  while base_index <= base_count and head_index <= head_count do
    line_comments.add_render_entries(render_line_map, head_index, base_line_map[base_index], "base")
    line_comments.add_render_entries(render_line_map, head_index, head_line_map[head_index], "head")
    base_index = base_index + 1
    head_index = head_index + 1
  end

  while head_index <= head_count do
    line_comments.add_render_entries(render_line_map, head_index, head_line_map[head_index], "head")
    head_index = head_index + 1
  end

  if head_count >= 1 then
    local deleted_anchor = anchor_for_deleted(head_index)
    while base_index <= base_count do
      line_comments.add_render_entries(render_line_map, deleted_anchor, base_line_map[base_index], "base")
      base_index = base_index + 1
    end
  end

  if vim.tbl_isempty(render_line_map) then
    return nil
  end

  return render_line_map
end

local function set_codediff_buffer_keymap(bufnr, mode, lhs, rhs, desc)
  if not is_valid_buf(bufnr) then
    return
  end
  if type(lhs) ~= "string" or lhs == "" then
    return
  end

  pcall(vim.keymap.del, mode, lhs, { buffer = bufnr })
  vim.keymap.set(mode, lhs, rhs, {
    buffer = bufnr,
    silent = true,
    nowait = true,
    desc = desc,
  })
end

local function default_codediff_enter()
  local prefix = vim.v.count > 0 and tostring(vim.v.count) or ""
  local enter = vim.api.nvim_replace_termcodes("<CR>", true, false, true)
  vim.api.nvim_feedkeys(prefix .. enter, "n", false)
end

local function apply_codediff_buffer_keymaps(bufnr)
  if not is_valid_buf(bufnr) then
    return
  end

  diff_view_runtime.clear_legacy_buffer_keymaps(bufnr)
  local shortcuts = diff_view_shortcuts("codediff")

  set_codediff_buffer_keymap(bufnr, "n", shortcuts.close_quick, function()
    M.close_quick()
  end, "GH PR: quick close")
  set_codediff_buffer_keymap(
    bufnr,
    "n",
    shortcuts.close_all_open_review,
    function()
      M.close_all_and_open_review()
    end,
    "GH PR: close views and open review"
  )
  set_codediff_buffer_keymap(bufnr, "n", shortcuts.help, function()
    M.show_diff_shortcuts()
  end, "GH PR: show diff shortcuts")
  set_codediff_buffer_keymap(bufnr, "n", shortcuts.next_file, function()
    M.next_file()
  end, "GH PR: next file")
  set_codediff_buffer_keymap(bufnr, "n", shortcuts.prev_file, function()
    M.prev_file()
  end, "GH PR: previous file")
  set_codediff_buffer_keymap(bufnr, "n", shortcuts.next_reviewed_file, function()
    M.next_reviewed_file()
  end, "GH PR: next reviewed file")
  set_codediff_buffer_keymap(bufnr, "n", shortcuts.prev_reviewed_file, function()
    M.prev_reviewed_file()
  end, "GH PR: previous reviewed file")
  set_codediff_buffer_keymap(bufnr, "n", shortcuts.next_change, function()
    M.next_change()
  end, "GH PR: next change")
  set_codediff_buffer_keymap(bufnr, "n", shortcuts.prev_change, function()
    M.prev_change()
  end, "GH PR: previous change")
  set_codediff_buffer_keymap(bufnr, "n", shortcuts.toggle_whitespace, function()
    M.toggle_diff_whitespace()
  end, "GH PR: toggle whitespace diff mode")
  set_codediff_buffer_keymap(bufnr, "n", shortcuts.cycle_whitespace_mode, function()
    M.cycle_diff_whitespace_mode()
  end, "GH PR: cycle whitespace diff mode")
  set_codediff_buffer_keymap(bufnr, "n", shortcuts.cycle_mode, function()
    M.cycle_diff_view_mode()
  end, "GH PR: cycle diff layout")
  set_codediff_buffer_keymap(bufnr, "n", shortcuts.set_vertical, function()
    M.set_diff_view_mode_vertical()
  end, "GH PR: set vertical diff layout")
  set_codediff_buffer_keymap(bufnr, "n", shortcuts.set_horizontal, function()
    M.set_diff_view_mode_horizontal()
  end, "GH PR: set horizontal diff layout")
  set_codediff_buffer_keymap(bufnr, "n", shortcuts.set_unified, function()
    M.set_diff_view_mode_unified()
  end, "GH PR: set unified diff layout")
  set_codediff_buffer_keymap(bufnr, "n", shortcuts.inline_comment, function()
    M.add_inline_comment()
  end, "GH PR: add inline comment")
  set_codediff_buffer_keymap(bufnr, "x", shortcuts.inline_comment, function()
    M.add_inline_comment_visual()
  end, "GH PR: add inline comment (selection)")
  set_codediff_buffer_keymap(bufnr, "n", shortcuts.inline_suggestion, function()
    M.add_inline_suggestion()
  end, "GH PR: add inline suggestion")
  set_codediff_buffer_keymap(bufnr, "x", shortcuts.inline_suggestion, function()
    M.add_inline_suggestion_visual()
  end, "GH PR: add inline suggestion (selection)")
  set_codediff_buffer_keymap(bufnr, "n", shortcuts.line_comments_popup, function()
    line_comments.show_at_cursor(bufnr)
  end, "GH PR: show line comments")
  set_codediff_buffer_keymap(bufnr, "n", "<CR>", function()
    if not line_comments.show_at_cursor(bufnr, { notify_empty = false }) then
      default_codediff_enter()
    end
  end, "GH PR: open line comments on commented lines")
  set_codediff_buffer_keymap(bufnr, "n", shortcuts.toggle_comments_panel, function()
    M.toggle_diff_comments_panel()
  end, "GH PR: toggle comments panel")
  set_codediff_buffer_keymap(bufnr, "n", shortcuts.submit_pending_comment, function()
    M.submit_pending_comment_review()
  end, "GH PR: submit pending comment review")
  set_codediff_buffer_keymap(bufnr, "n", shortcuts.submit_pending_approve, function()
    M.submit_pending_approve_review()
  end, "GH PR: submit pending approve review")
  set_codediff_buffer_keymap(bufnr, "n", shortcuts.submit_pending_request_changes, function()
    M.submit_pending_request_changes_review()
  end, "GH PR: submit pending request changes review")
  set_codediff_buffer_keymap(bufnr, "n", shortcuts.discard_pending_review, function()
    M.discard_pending_review()
  end, "GH PR: discard pending review")
  set_codediff_buffer_keymap(bufnr, "n", shortcuts.toggle_review_tree, function()
    M.toggle_review_tree()
  end, "GH PR: toggle review tree")
end

local function apply_codediff_buffer_metadata(bufnr, pr, details, path, side, file_mode, opts)
  if not is_valid_buf(bufnr) then
    return
  end
  opts = type(opts) == "table" and opts or {}

  local normalized_path = normalize_path(path)
  local canonical_path = resolve_canonical_file_path(details, normalized_path)
  local repository = normalize_repository(details) or ""
  local file_kind = type(opts.file_kind) == "string" and opts.file_kind or side
  local comment_side = type(opts.comment_side) == "string" and opts.comment_side or side
  local layout = type(opts.layout) == "string" and opts.layout or "side-by-side"

  vim.b[bufnr].gh_pr_repo = repository ~= "" and repository or nil
  vim.b[bufnr].gh_pr_number = tonumber(pr.number)
  vim.b[bufnr].gh_pr_path = normalized_path
  vim.b[bufnr].gh_pr_file_path = canonical_path ~= "" and canonical_path or nil
  vim.b[bufnr].gh_pr_file_kind = file_kind
  vim.b[bufnr].gh_pr_file_mode = type(file_mode) == "string" and file_mode ~= "" and file_mode or nil
  vim.b[bufnr].gh_pr_diff_backend = "codediff"
  vim.b[bufnr].gh_pr_codediff_layout = layout
  vim.b[bufnr].gh_pr_is_image = false
  vim.b[bufnr].gh_pr_is_non_text = false
  vim.b[bufnr].gh_pr_asset_kind = nil
  vim.b[bufnr].gh_pr_asset_side = nil
  vim.b[bufnr].gh_pr_asset_status = nil
  vim.b[bufnr].gh_pr_asset_actions = nil
  vim.b[bufnr].gh_pr_asset_preview = nil
  vim.b[bufnr].gh_pr_image_side = nil
  vim.b[bufnr].gh_pr_image_status = nil
  vim.b[bufnr].gh_pr_image_reason = nil
  vim.b[bufnr].gh_pr_image_cache_path = nil
  vim.b[bufnr].gh_pr_unified_line_map = nil
  vim.b[bufnr].gh_pr_endline_map = nil
  vim.b[bufnr].gh_pr_comment_side = comment_side
  vim.b[bufnr].gh_pr_security_alerts = {}
  vim.b[bufnr].gh_pr_active_security_alert_key = nil
  pcall(vim.api.nvim_set_option_value, "spell", false, { buf = bufnr })

  apply_codediff_buffer_keymaps(bufnr)
end

local function resolve_codediff_window(winid, bufnr)
  local candidate = tonumber(winid)
  if is_valid_win(candidate) then
    return candidate
  end

  if is_valid_buf(bufnr) then
    local buffer_win = vim.fn.bufwinid(bufnr)
    if is_valid_win(buffer_win) then
      return buffer_win
    end
  end

  return nil
end

local function apply_codediff_window_number_options(winid)
  if not is_valid_win(winid) then
    return
  end

  pcall(vim.api.nvim_set_option_value, "number", true, { win = winid })
  pcall(vim.api.nvim_set_option_value, "relativenumber", true, { win = winid })
end

local function apply_codediff_open_result_context(pr, details, file, open_result, opts)
  opts = type(opts) == "table" and opts or {}
  open_result = type(open_result) == "table" and open_result or {}

  if open_result.mode ~= "file" then
    return
  end

  local file_mode = type(open_result.file_mode) == "string" and open_result.file_mode or ""
  local base_path = normalize_path(open_result.base_path)
  local head_path = normalize_path(open_result.head_path)
  if base_path == "" and type(file) == "table" then
    base_path = normalize_path(file.previous_filename or file.previousFilename or file.path or file.filename)
  end
  if head_path == "" and type(file) == "table" then
    head_path = normalize_path(file.path or file.filename)
  end

  local alternates = collect_alternate_paths(file, base_path, head_path)
  local comments_ctx = type(opts.comments_ctx) == "table" and opts.comments_ctx or nil
  local check_annotations_ctx = type(opts.check_annotations_ctx) == "table" and opts.check_annotations_ctx or nil
  local security_annotations_ctx = type(opts.security_annotations_ctx) == "table" and opts.security_annotations_ctx or nil
  local annotation_renderer = require("gh-pr.check_annotations")
  local security_annotation_renderer = require("gh-pr.security_annotations")
  local base_buf = tonumber(open_result.base_buf)
  local head_buf = tonumber(open_result.head_buf)
  local layout = open_result.layout == "inline" and "inline" or "side-by-side"
  local inline_comment_line_map = nil

  if layout == "inline" and comments_ctx then
    inline_comment_line_map = codediff_file_runtime.build_inline_comment_line_map(
      open_result,
      comments_ctx,
      base_path,
      head_path,
      alternates
    )
  end

  if is_valid_buf(base_buf) then
    apply_codediff_buffer_metadata(base_buf, pr, details, base_path, "base", file_mode, {
      file_kind = "base",
      comment_side = "base",
      layout = layout,
    })
    local base_win = resolve_codediff_window(open_result.base_win, base_buf)
    if base_win then
      apply_codediff_window_number_options(base_win)
    end
    if comments_ctx and layout ~= "inline" then
      line_comments.attach_to_buffer(base_buf, {
        index = comments_ctx.index,
        side = "base",
        file_path = base_path,
        alternate_paths = alternates,
        keymap = comments_ctx.keymap,
        signs = comments_ctx.signs,
        max_popup_width = comments_ctx.max_popup_width,
        max_popup_height = comments_ctx.max_popup_height,
      })
    else
      line_comments.clear_buffer(base_buf)
    end
    annotation_renderer.clear_buffer(base_buf)
    security_annotation_renderer.clear_buffer(base_buf)
  end

  if is_valid_buf(head_buf) then
    apply_codediff_buffer_metadata(head_buf, pr, details, head_path, "head", file_mode, {
      file_kind = layout == "inline" and "unified" or "head",
      comment_side = "head",
      layout = layout,
    })
    local head_win = resolve_codediff_window(open_result.head_win, head_buf)
    if head_win then
      apply_codediff_window_number_options(head_win)
    end
    if comments_ctx then
      if layout == "inline" and inline_comment_line_map then
        line_comments.attach_to_buffer(head_buf, {
          side = "head",
          render_line_map = inline_comment_line_map,
          keymap = comments_ctx.keymap,
          signs = comments_ctx.signs,
          max_popup_width = comments_ctx.max_popup_width,
          max_popup_height = comments_ctx.max_popup_height,
        })
      else
        line_comments.attach_to_buffer(head_buf, {
          index = comments_ctx.index,
          side = "head",
          file_path = head_path,
          alternate_paths = alternates,
          keymap = comments_ctx.keymap,
          signs = comments_ctx.signs,
          max_popup_width = comments_ctx.max_popup_width,
          max_popup_height = comments_ctx.max_popup_height,
        })
      end
    else
      line_comments.clear_buffer(head_buf)
    end
    if check_annotations_ctx then
      annotation_renderer.attach_to_buffer(head_buf, {
        annotations = check_annotations_ctx.annotations,
        check_key = check_annotations_ctx.check_key,
        side = "head",
        file_path = head_path,
        alternate_paths = alternates,
      })
    else
      annotation_renderer.clear_buffer(head_buf)
    end
    if security_annotations_ctx then
      security_annotation_renderer.attach_to_buffer(head_buf, {
        alerts = security_annotations_ctx.alerts,
        alert_key = security_annotations_ctx.alert_key,
        side = "head",
        file_path = head_path,
        alternate_paths = alternates,
      })
    else
      security_annotation_renderer.clear_buffer(head_buf)
    end
  end

  if opts.register_runtime ~= false then
    codediff_file_runtime.register(open_result, {
      pr = pr,
      details = details,
      file = file,
      comments_ctx = comments_ctx,
      check_annotations_ctx = check_annotations_ctx,
      security_annotations_ctx = security_annotations_ctx,
      file_mode = file_mode,
    })
  end
end

function codediff_file_runtime.rehydrate(tabpage)
  local entry = codediff_file_runtime.by_tabpage[tabpage]
  if type(entry) ~= "table" then
    return
  end

  local open_result = codediff_file_runtime.current_open_result(tabpage)
  if type(open_result) ~= "table" then
    if type(tabpage) ~= "number" or not vim.api.nvim_tabpage_is_valid(tabpage) then
      codediff_file_runtime.clear(tabpage)
    end
    return
  end

  local fingerprint = {
    version = tonumber(entry.version) or 0,
    layout = safe_string(open_result.layout, ""),
    base_buf = tonumber(open_result.base_buf) or 0,
    head_buf = tonumber(open_result.head_buf) or 0,
  }
  local applied = type(entry.applied) == "table" and entry.applied or {}
  if applied.version == fingerprint.version
    and applied.layout == fingerprint.layout
    and applied.base_buf == fingerprint.base_buf
    and applied.head_buf == fingerprint.head_buf then
    return
  end

  open_result.file_mode = safe_string(entry.file_mode, "")
  apply_codediff_open_result_context(entry.pr, entry.details, entry.file, open_result, {
    comments_ctx = entry.comments_ctx,
    check_annotations_ctx = entry.check_annotations_ctx,
    security_annotations_ctx = entry.security_annotations_ctx,
    register_runtime = false,
  })

  entry.applied = fingerprint
end

local function sync_diff_comments_panel(pr, details, comments_ctx)
  local ok_panel, panel = pcall(require, "gh-pr.diff_comments_panel")
  if ok_panel and type(panel.sync_for_diff) == "function" then
    local origin_win = vim.api.nvim_get_current_win()
    local origin_buf = vim.api.nvim_get_current_buf()
    if vim.b[origin_buf].gh_pr_is_non_text == true then
      return
    end
    pcall(panel.sync_for_diff, {
      pr = pr,
      details = details,
      comments_ctx = comments_ctx,
      pr_number = pr.number,
      origin_win = origin_win,
      origin_buf = origin_buf,
      file_path = normalize_path(vim.b[origin_buf].gh_pr_file_path or vim.b[origin_buf].gh_pr_path),
      file_kind = vim.b[origin_buf].gh_pr_file_kind,
    })
  end
end

local function valid_tabpage(tabpage)
  return type(tabpage) == "number" and tabpage > 0 and vim.api.nvim_tabpage_is_valid(tabpage)
end

local function normalized_thread_side(side)
  local value = type(side) == "string" and side:lower() or "head"
  if value == "base" or value == "left" then
    return "base"
  end
  return "head"
end

local function preferred_thread_line(side, line, original_line)
  if side == "base" then
    return positive_integer(original_line, positive_integer(line, nil))
  end
  return positive_integer(line, positive_integer(original_line, nil))
end

local function overview_thread_date_format()
  local overview = ((config.get() or {}).overview or {})
  local date_format = type(overview.date_format) == "string" and overview.date_format or ""
  if date_format == "" then
    return "%Y-%m-%d %H:%M"
  end
  return date_format
end

local function format_overview_thread_timestamp(value, date_format)
  local text = safe_string(value)
  if text == "" then
    return "-"
  end

  local seconds = vim.fn.strptime("%Y-%m-%dT%H:%M:%SZ", text)
  if type(seconds) == "number" and seconds > 0 then
    return vim.fn.strftime(date_format, seconds)
  end

  return text:gsub("T", " "):gsub("Z", "")
end

local function build_overview_thread_workspace_lines(payload)
  payload = type(payload) == "table" and payload or {}
  local path = safe_string(payload.path)
  if path == "" then
    path = "(unknown path)"
  end

  local side = normalized_thread_side(payload.side)
  local head_line = positive_integer(payload.line, nil)
  local base_line = positive_integer(payload.original_line, nil)
  local line_text = "-"
  if side == "base" and base_line then
    line_text = tostring(base_line)
  elseif side == "head" and head_line then
    line_text = tostring(head_line)
  elseif head_line or base_line then
    line_text = tostring(head_line or base_line)
  end

  local status = "open"
  if payload.is_resolved == true then
    status = "resolved"
  end
  if payload.is_outdated == true then
    status = status .. " + outdated"
  end

  local comments = type(payload.comments) == "table" and payload.comments or {}
  local date_format = overview_thread_date_format()
  local lines = {
    "# Thread Workspace",
    "",
    string.format("- Path: `%s`", path),
    string.format("- Focus: `%s:%s`", side, line_text),
    string.format("- Status: `%s`", status),
    string.format("- Comments: `%d`", #comments),
    "",
  }

  if vim.tbl_isempty(comments) then
    lines[#lines + 1] = "_No comments available for this thread._"
    return lines
  end

  for index, comment in ipairs(comments) do
    local author = safe_string(comment.author, "unknown")
    local created_at = format_overview_thread_timestamp(comment.created_at, date_format)
    local state = safe_string(comment.state)
    local raw_comment_side = safe_string(comment.side, side)
    if raw_comment_side == "" then
      raw_comment_side = side
    end
    local comment_side = normalized_thread_side(raw_comment_side)
    local comment_line = preferred_thread_line(comment_side, comment.line, comment.original_line)

    lines[#lines + 1] = string.format("## %d. @%s", index, author)
    lines[#lines + 1] = string.format("- Date: %s", created_at)
    lines[#lines + 1] = string.format("- State: `%s`", state ~= "" and state or "COMMENTED")
    if comment_line then
      lines[#lines + 1] = string.format("- Location: `%s:%d`", comment_side, comment_line)
    else
      lines[#lines + 1] = string.format("- Location: `%s`", comment_side)
    end

    local url = safe_string(comment.url)
    if url ~= "" then
      lines[#lines + 1] = string.format("- URL: %s", url)
    end

    lines[#lines + 1] = ""

    local body = type(comment.body) == "string" and comment.body:gsub("\r\n", "\n"):gsub("\r", "\n") or ""
    local body_lines = vim.split(body, "\n", { plain = true })
    if vim.tbl_isempty(body_lines) or (#body_lines == 1 and body_lines[1] == "") then
      lines[#lines + 1] = "_(no body)_"
    else
      for _, body_line in ipairs(body_lines) do
        lines[#lines + 1] = body_line
      end
    end

    if index < #comments then
      lines[#lines + 1] = ""
      lines[#lines + 1] = "---"
      lines[#lines + 1] = ""
    end
  end

  return lines
end

local function set_readonly_markdown_buffer(bufnr, lines, name)
  if not is_valid_buf(bufnr) then
    return
  end

  if type(name) == "string" and name ~= "" then
    pcall(vim.api.nvim_buf_set_name, bufnr, name)
  end

  pcall(vim.api.nvim_set_option_value, "buftype", "nofile", { buf = bufnr })
  pcall(vim.api.nvim_set_option_value, "bufhidden", "wipe", { buf = bufnr })
  pcall(vim.api.nvim_set_option_value, "swapfile", false, { buf = bufnr })
  pcall(vim.api.nvim_set_option_value, "modifiable", true, { buf = bufnr })
  pcall(vim.api.nvim_set_option_value, "readonly", false, { buf = bufnr })
  pcall(vim.api.nvim_set_option_value, "filetype", "markdown", { buf = bufnr })
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  pcall(vim.api.nvim_set_option_value, "spell", false, { buf = bufnr })
  pcall(vim.api.nvim_set_option_value, "modifiable", false, { buf = bufnr })
  pcall(vim.api.nvim_set_option_value, "readonly", true, { buf = bufnr })
  pcall(vim.api.nvim_set_option_value, "modified", false, { buf = bufnr })
end

local function apply_workspace_markdown_window_options(winid)
  if not is_valid_win(winid) then
    return
  end

  pcall(vim.api.nvim_set_option_value, "number", false, { win = winid })
  pcall(vim.api.nvim_set_option_value, "relativenumber", false, { win = winid })
  pcall(vim.api.nvim_set_option_value, "signcolumn", "no", { win = winid })
  pcall(vim.api.nvim_set_option_value, "wrap", true, { win = winid })
  pcall(vim.api.nvim_set_option_value, "linebreak", true, { win = winid })
  pcall(vim.api.nvim_set_option_value, "breakindent", true, { win = winid })
  pcall(vim.api.nvim_set_option_value, "cursorline", true, { win = winid })
  pcall(vim.api.nvim_set_option_value, "spell", false, { win = winid })
end

local function workspace_close_tab(tabpage)
  if not valid_tabpage(tabpage) then
    return
  end

  local current = vim.api.nvim_get_current_tabpage()
  if current ~= tabpage and valid_tabpage(tabpage) then
    pcall(vim.api.nvim_set_current_tabpage, tabpage)
  end

  if valid_tabpage(tabpage) then
    pcall(vim.cmd, "tabclose")
  end
end

local function attach_workspace_close_keymaps(tabpage, bufnr)
  if not is_valid_buf(bufnr) then
    return
  end

  local opts = { buffer = bufnr, silent = true, nowait = true }
  vim.keymap.set("n", "q", function()
    workspace_close_tab(tabpage)
  end, vim.tbl_extend("force", opts, { desc = "GH PR: close thread workspace" }))
  vim.keymap.set("n", "<Esc>", function()
    workspace_close_tab(tabpage)
  end, vim.tbl_extend("force", opts, { desc = "GH PR: close thread workspace" }))
end

local function open_overview_thread_workspace_panel(tabpage, code_win, payload, pr_number)
  if not valid_tabpage(tabpage) then
    return nil, nil, "Unable to resolve workspace tab"
  end

  if not is_valid_win(code_win) then
    local wins = vim.api.nvim_tabpage_list_wins(tabpage)
    code_win = wins[1]
  end
  if not is_valid_win(code_win) then
    return nil, nil, "Unable to resolve workspace code window"
  end

  local previous_tab = vim.api.nvim_get_current_tabpage()
  if previous_tab ~= tabpage then
    pcall(vim.api.nvim_set_current_tabpage, tabpage)
  end
  pcall(vim.api.nvim_set_current_win, code_win)
  local ok_split, split_err = pcall(vim.cmd, "vsplit")
  if not ok_split then
    return nil, nil, "Unable to open workspace markdown panel: " .. tostring(split_err)
  end

  local markdown_win = vim.api.nvim_get_current_win()
  if not is_valid_win(markdown_win) then
    return nil, nil, "Unable to resolve workspace markdown window"
  end

  local thread_id = safe_string(payload.thread_id)
  if thread_id == "" then
    thread_id = tostring(os.time())
  end
  local markdown_buf = vim.api.nvim_create_buf(false, true)
  local name = string.format("ghpr://overview/thread-workspace/%d/%s", tonumber(pr_number) or 0, thread_id)
  local lines = build_overview_thread_workspace_lines(payload)
  set_readonly_markdown_buffer(markdown_buf, lines, name)
  pcall(vim.api.nvim_win_set_buf, markdown_win, markdown_buf)
  apply_workspace_markdown_window_options(markdown_win)
  pcall(vim.api.nvim_win_set_cursor, markdown_win, { 1, 0 })
  pcall(vim.api.nvim_set_current_win, code_win)

  return markdown_buf, markdown_win, nil
end

local function resolve_workspace_code_window(tabpage, open_result, focus_side)
  local side = focus_side == "base" and "base" or "head"
  local preferred_win = side == "base" and tonumber(open_result.base_win) or tonumber(open_result.head_win)
  if is_valid_win(preferred_win) and vim.api.nvim_win_get_tabpage(preferred_win) == tabpage then
    return preferred_win
  end

  local preferred_buf = side == "base" and tonumber(open_result.base_buf) or tonumber(open_result.head_buf)
  if is_valid_buf(preferred_buf) then
    local candidate = vim.fn.bufwinid(preferred_buf)
    if is_valid_win(candidate) and vim.api.nvim_win_get_tabpage(candidate) == tabpage then
      return candidate
    end
  end

  for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(tabpage)) do
    if is_valid_win(winid) then
      return winid
    end
  end

  return nil
end

function M.open_overview_thread_workspace(payload, opts)
  return M.open_thread_comment_evolution_diff(payload, opts)
end

function M.open_commit_diff(commit, opts)
  opts = type(opts) == "table" and opts or {}
  local origin_win = vim.api.nvim_get_current_win()
  local pr, details, err = resolve_active_pr()
  if not pr then
    notify_error(err)
    return false
  end

  local selected_commit = resolve_commit(commit)
  if not selected_commit then
    notify_error("No commit selected")
    return false
  end

  local commit_details, commit_err = fetch_commit_details_for_pr(pr, details, selected_commit)
  if not commit_details then
    if open_commit_url(selected_commit) then
      return true
    end
    notify_error(commit_err)
    return false
  end

  local commit_diff_details = build_commit_diff_details(details, commit_details)
  if type(commit_diff_details.baseRefName) ~= "string" or commit_diff_details.baseRefName == "" then
    notify_error("Unable to resolve base ref for selected commit diff")
    return false
  end
  if type(commit_diff_details.headRefName) ~= "string" or commit_diff_details.headRefName == "" then
    notify_error("Unable to resolve head ref for selected commit diff")
    return false
  end

  local function open_with_codediff()
    local target_path = normalize_path(opts.path)
    local target_file = nil
    if target_path ~= "" then
      for _, raw in ipairs(type(commit_details.files) == "table" and commit_details.files or {}) do
        local candidate = normalize_commit_file_for_diff(raw)
        if candidate then
          for _, path_candidate in ipairs({
            candidate.path,
            candidate.filename,
            candidate.previous_filename,
            candidate.previousFilename,
          }) do
            if normalize_path(path_candidate) == target_path then
              target_file = candidate
              break
            end
          end
        end
        if target_file then
          break
        end
      end

      if not target_file then
        return nil, "Unable to resolve selected path for commit diff"
      end
    end

    local opened_result, codediff_err = codediff_integration.open_commit_diff({
      details = commit_diff_details,
      file = target_file,
      files = target_file and nil or commit_details.files,
      cache_scope = string.format(
        "commit|%d|%s|%s",
        pr.number,
        safe_string(commit_diff_details.baseRefName),
        safe_string(commit_diff_details.headRefName)
      ),
      target_side = opts.target_side,
      target_line = opts.target_line,
      target_original_line = opts.target_original_line,
    })
    if not opened_result then
      return nil, codediff_err
    end

    if target_file then
      apply_codediff_open_result_context(pr, commit_diff_details, target_file, opened_result, {})
    end

    return true, nil
  end

  local function open_with_virtual()
    if is_valid_win(origin_win) then
      pcall(vim.api.nvim_set_current_win, origin_win)
    end
    local _, open_err = virtual_files.open_commit_patch(details, pr, commit_details)
    if open_err then
      if open_commit_url(commit_details) then
        return true, nil
      end
      return nil, open_err
    end
    return true, nil
  end

  local opened, open_err = open_diff_with_forced_backend({
    open_primary = open_with_codediff,
    open_virtual = open_with_virtual,
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

function M.open_commit_file_diff(commit, file, opts)
  opts = opts or {}
  local origin_win = vim.api.nvim_get_current_win()
  local pr, details, err = resolve_active_pr()
  if not pr then
    notify_error(err)
    return false
  end

  local selected_commit = resolve_commit(commit)
  if not selected_commit then
    notify_error("No commit selected")
    return false
  end

  local selected_file = normalize_commit_file_for_diff(file)
  if not selected_file then
    notify_error("No commit file selected for diff")
    return false
  end

  local commit_details = selected_commit
  if type(commit_details.parent_oid) ~= "string" or commit_details.parent_oid == "" then
    local fetched_commit, fetch_err = fetch_commit_details_for_pr(pr, details, selected_commit)
    if not fetched_commit then
      if open_commit_url(selected_commit) then
        return true
      end
      notify_error(fetch_err)
      return false
    end
    commit_details = fetched_commit
  end

  if type(commit_details.parent_oid) ~= "string" or commit_details.parent_oid == "" then
    notify_error("Selected commit has no parent commit to diff against")
    return false
  end

  local commit_diff_details = build_commit_diff_details(details, commit_details)
  if type(commit_diff_details.baseRefName) ~= "string" or commit_diff_details.baseRefName == "" then
    notify_error("Unable to resolve base ref for selected commit diff")
    return false
  end
  if type(commit_diff_details.headRefName) ~= "string" or commit_diff_details.headRefName == "" then
    notify_error("Unable to resolve head ref for selected commit diff")
    return false
  end

  state.set_active_file(selected_file)
  local uses_non_text_preview = non_text_preview.file_uses_non_text_preview(selected_file)
  local function open_with_codediff(diff_view)
    local opened_result, codediff_err = codediff_integration.open_commit_diff({
      details = commit_diff_details,
      file = selected_file,
      cache_scope = string.format(
        "commit-file|%d|%s|%s|%s",
        pr.number,
        safe_string(commit_diff_details.baseRefName),
        safe_string(commit_diff_details.headRefName),
        safe_string(selected_file.path)
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

    apply_codediff_open_result_context(pr, commit_diff_details, selected_file, opened_result, {})
    return true, nil
  end

  local function open_with_virtual(open_opts)
    if is_valid_win(origin_win) then
      pcall(vim.api.nvim_set_current_win, origin_win)
    end
    local diff_result, diff_err = virtual_files.open_diff(commit_diff_details, pr, selected_file, {
      line_comments = nil,
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
      notify_info("File is new in selected commit. Opened single MODIFIED buffer (diff layouts disabled).")
    elseif type(diff_result) == "table" and diff_result.file_mode == "removed_single" then
      notify_info("File was removed in selected commit. Opened single ORIGINAL buffer (diff layouts disabled).")
    end

    diff_view_runtime.focus_virtual_diff_result(diff_result, open_opts)

    sync_diff_comments_panel(pr, details, nil)
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
      return open_with_virtual(vim.tbl_extend("force", {}, opts, { view = diff_view }))
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

function M.open_thread_comment_evolution_diff(payload, opts)
  payload = type(payload) == "table" and payload or {}
  opts = type(opts) == "table" and opts or {}
  local origin_win = vim.api.nvim_get_current_win()

  local function thread_comment_side_from_payload_local()
    if type(M._thread_fix_helpers) == "table" and type(M._thread_fix_helpers.normalize_target_side) == "function" then
      return M._thread_fix_helpers.normalize_target_side(payload.side)
    end

    local value = type(payload.side) == "string" and payload.side:lower() or "head"
    if value == "left" or value == "base" then
      return "base"
    end
    return "head"
  end

  local function build_fallback_target(target_path, target_side, target_line, target_original_line)
    local fallback = type(payload.fallback_target) == "table" and vim.deepcopy(payload.fallback_target) or {}
    fallback.path = type(fallback.path) == "string" and fallback.path ~= "" and fallback.path or target_path
    fallback.side = type(fallback.side) == "string" and fallback.side ~= "" and fallback.side or target_side
    fallback.line = tonumber(fallback.line) or target_line
    fallback.original_line = tonumber(fallback.original_line) or target_original_line
    return fallback
  end

  local function oid_candidates(target_side)
    local first = ""
    local second = ""
    if target_side == "base" then
      first = type(payload.comment_original_commit_oid) == "string" and payload.comment_original_commit_oid or ""
      second = type(payload.comment_commit_oid) == "string" and payload.comment_commit_oid or ""
    else
      first = type(payload.comment_commit_oid) == "string" and payload.comment_commit_oid or ""
      second = type(payload.comment_original_commit_oid) == "string" and payload.comment_original_commit_oid or ""
    end
    return first, second
  end

  local function fetch_comment_commit(pr, details, oid)
    local target_oid = type(oid) == "string" and oid or ""
    if target_oid == "" then
      return nil, "Missing thread comment commit oid"
    end

    local repository = normalize_repository(details) or ""
    return pr_service.fetch_commit_details(pr.number, target_oid, {
      repository = repository,
    })
  end

  local function find_commit_file_for_paths_local(commit_details, paths)
    if type(commit_details) ~= "table" then
      return nil
    end
    if type(paths) ~= "table" or vim.tbl_isempty(paths) then
      return nil
    end
    if type(M._thread_fix_helpers) ~= "table" or type(M._thread_fix_helpers.find_file_in_commit) ~= "function" then
      return nil
    end

    local seen = {}
    for _, raw_path in ipairs(paths) do
      local candidate = normalize_path(raw_path)
      if candidate ~= "" and not seen[candidate] then
        seen[candidate] = true
        local file = M._thread_fix_helpers.find_file_in_commit(commit_details, candidate)
        if file then
          return file
        end
      end
    end

    return nil
  end

  local function build_compare_file(target_path, comment_file, latest_file)
    local normalized_target = normalize_path(target_path)
    local comment_current = normalize_path(type(comment_file) == "table" and (comment_file.path or comment_file.filename) or "")
    local comment_previous = normalize_path(
      type(comment_file) == "table" and (comment_file.previous_filename or comment_file.previousFilename) or ""
    )
    local latest_current = normalize_path(type(latest_file) == "table" and (latest_file.path or latest_file.filename) or "")
    local latest_previous = normalize_path(
      type(latest_file) == "table" and (latest_file.previous_filename or latest_file.previousFilename) or ""
    )

    local base_path = comment_current
    if base_path == "" then
      base_path = comment_previous
    end
    if base_path == "" then
      base_path = normalized_target
    end

    local head_path = latest_current
    if head_path == "" then
      head_path = latest_previous
    end
    if head_path == "" then
      head_path = normalized_target
    end

    local status = "modified"
    local previous_filename = ""
    if base_path == "" and head_path ~= "" then
      status = "added"
    elseif base_path ~= "" and head_path == "" then
      status = "removed"
      head_path = base_path
    elseif base_path ~= "" and head_path ~= "" and base_path ~= head_path then
      status = "renamed"
      previous_filename = base_path
    end

    local path = head_path ~= "" and head_path or base_path
    if status == "removed" then
      path = base_path
    end
    if path == "" then
      path = normalized_target
    end

    return {
      path = path,
      filename = path,
      previous_filename = previous_filename,
      previousFilename = previous_filename,
      status = status,
      additions = tonumber(type(latest_file) == "table" and latest_file.additions or nil) or 0,
      deletions = tonumber(type(latest_file) == "table" and latest_file.deletions or nil) or 0,
    }
  end

  local function build_compare_details(details, base_commit, head_commit)
    local diff_details = vim.deepcopy(type(details) == "table" and details or {})
    diff_details.baseRefName = type(base_commit) == "table" and type(base_commit.oid) == "string" and base_commit.oid or ""
    diff_details.headRefName = type(head_commit) == "table" and type(head_commit.oid) == "string" and head_commit.oid or ""

    local base_repository = type(base_commit) == "table" and repository_object_from_full_name(base_commit.repository) or nil
    local head_repository = type(head_commit) == "table" and repository_object_from_full_name(head_commit.repository) or nil

    if type(base_repository) == "table" then
      diff_details.baseRepository = vim.deepcopy(base_repository)
    end
    if type(head_repository) == "table" then
      diff_details.headRepository = vim.deepcopy(head_repository)
    end

    if type(diff_details.baseRepository) ~= "table" and type(diff_details.headRepository) == "table" then
      diff_details.baseRepository = vim.deepcopy(diff_details.headRepository)
    end
    if type(diff_details.headRepository) ~= "table" and type(diff_details.baseRepository) == "table" then
      diff_details.headRepository = vim.deepcopy(diff_details.baseRepository)
    end

    if (type(diff_details.url) ~= "string" or diff_details.url == "")
      and type(head_commit) == "table"
      and type(head_commit.url) == "string"
      and head_commit.url ~= "" then
      diff_details.url = head_commit.url
    end

    return diff_details
  end

  local function open_fallback(reason)
    local fallback_target = type(payload._resolved_fallback_target) == "table" and payload._resolved_fallback_target
      or (type(payload.fallback_target) == "table" and payload.fallback_target or nil)
    if fallback_target then
      M.open_comment_location(fallback_target)
      if type(reason) == "string" and reason ~= "" then
        notify_warn(reason)
      end
      return {
        ok = false,
        fallback = "location",
        reason = reason,
      }
    end
    if type(reason) == "string" and reason ~= "" then
      notify_warn(reason)
    end
    return {
      ok = false,
      reason = reason,
    }
  end

  local number = tonumber(payload.pr_number) or tonumber(vim.b.gh_pr_number)
  local pr, details, err = resolve_active_pr(number)
  if not pr then
    return open_fallback(err)
  end

  local comments_ctx = build_line_comment_context(pr.number)

  local target_path = normalize_path(payload.path)
  if target_path == "" then
    return open_fallback("Unable to open thread comment diff: missing file path")
  end

  local target_side = thread_comment_side_from_payload_local()
  local target_line = positive_integer(payload.line, positive_integer(payload.original_line, nil))
  local target_original_line = positive_integer(payload.original_line, positive_integer(payload.line, nil))
  payload._resolved_fallback_target = build_fallback_target(
    target_path,
    target_side,
    target_line,
    target_original_line
  )

  local primary_oid, secondary_oid = oid_candidates(target_side)
  local comment_commit_oid = primary_oid ~= "" and primary_oid or secondary_oid
  if comment_commit_oid == "" then
    return open_fallback("Unable to resolve commit oid for selected thread comment")
  end

  local comment_commit, comment_err = fetch_comment_commit(pr, details, comment_commit_oid)
  if not comment_commit then
    return open_fallback("Unable to resolve comment commit details: " .. tostring(comment_err))
  end

  if type(M._thread_fix_helpers) ~= "table" or type(M._thread_fix_helpers.resolve_target) ~= "function" then
    return open_fallback("Unable to resolve latest file commit for selected thread comment")
  end

  local resolved, resolve_err = M._thread_fix_helpers.resolve_target(pr, details, {
    path = target_path,
    side = target_side,
    line = target_line,
    original_line = target_original_line,
    comment_commit_oid = comment_commit_oid,
  })
  if not resolved or type(resolved.commit) ~= "table" or type(resolved.file) ~= "table" then
    return open_fallback("Unable to resolve latest commit for commented file: " .. tostring(resolve_err))
  end

  local latest_commit = resolved.commit
  local latest_file = resolved.file
  local latest_commit_oid = type(latest_commit.oid) == "string" and latest_commit.oid or ""
  local selected_comment_commit = comment_commit
  local selected_comment_commit_oid = type(comment_commit.oid) == "string" and comment_commit.oid or comment_commit_oid
  local compare_path_candidates = {
    target_path,
    latest_file.path,
    latest_file.filename,
    latest_file.previous_filename,
    latest_file.previousFilename,
  }
  local comment_file = find_commit_file_for_paths_local(selected_comment_commit, compare_path_candidates)

  if latest_commit_oid ~= "" and selected_comment_commit_oid ~= "" and selected_comment_commit_oid == latest_commit_oid then
    local tried_oids = {}
    local alternate_oids = {
      type(payload.comment_original_commit_oid) == "string" and payload.comment_original_commit_oid or "",
      secondary_oid,
      type(payload.comment_commit_oid) == "string" and payload.comment_commit_oid or "",
      primary_oid,
    }

    for _, candidate_oid in ipairs(alternate_oids) do
      local normalized_candidate = type(candidate_oid) == "string" and candidate_oid or ""
      if normalized_candidate ~= ""
        and normalized_candidate ~= latest_commit_oid
        and not tried_oids[normalized_candidate] then
        tried_oids[normalized_candidate] = true
        local candidate_commit, candidate_err = fetch_comment_commit(pr, details, normalized_candidate)
        if candidate_commit then
          local candidate_file = find_commit_file_for_paths_local(candidate_commit, compare_path_candidates)
          if candidate_file then
            selected_comment_commit = candidate_commit
            selected_comment_commit_oid = type(candidate_commit.oid) == "string"
                and candidate_commit.oid ~= "" and candidate_commit.oid
              or normalized_candidate
            comment_file = candidate_file
            break
          end
        elseif type(candidate_err) == "string" and candidate_err ~= "" then
          -- keep trying alternate candidates
        end
      end
    end
  end

  if latest_commit_oid ~= ""
    and selected_comment_commit_oid ~= ""
    and selected_comment_commit_oid == latest_commit_oid then
    return open_fallback("No evolution diff available: selected comment already points to latest commit for this file.")
  end

  if not comment_file then
    return open_fallback("Unable to find the commented file in the comment commit")
  end

  local compare_details = build_compare_details(details, selected_comment_commit, latest_commit)
  if type(compare_details.baseRefName) ~= "string" or compare_details.baseRefName == "" then
    return open_fallback("Unable to resolve base ref for thread comment evolution diff")
  end
  if type(compare_details.headRefName) ~= "string" or compare_details.headRefName == "" then
    return open_fallback("Unable to resolve head ref for thread comment evolution diff")
  end

  local compare_file = build_compare_file(target_path, comment_file, latest_file)
  if type(compare_file) ~= "table" or type(compare_file.path) ~= "string" or compare_file.path == "" then
    return open_fallback("Unable to build compared file for thread comment evolution diff")
  end

  state.set_active_file(compare_file)
  local uses_non_text_preview = non_text_preview.file_uses_non_text_preview(compare_file)
  if uses_non_text_preview then
    comments_ctx = nil
  end
  local focus_side = target_side == "base" and "base" or "head"
  local focus_line = focus_side == "base" and target_original_line or target_line
  local function open_with_codediff(diff_view)
    local opened_result, codediff_err = codediff_integration.open_compare_diff({
      details = compare_details,
      file = compare_file,
      cache_scope = string.format(
        "compare|%d|%s|%s|%s",
        pr.number,
        safe_string(compare_details.baseRefName),
        safe_string(compare_details.headRefName),
        safe_string(compare_file.path)
      ),
      layout = diff_view.mode,
      ignore_trim_whitespace = diff_view.ignore_whitespace_mode == "trim",
      target_side = focus_side,
      target_line = focus_line,
      target_original_line = focus_side == "base" and focus_line or target_original_line,
    })
    if not opened_result then
      return nil, codediff_err
    end

    apply_codediff_open_result_context(pr, compare_details, compare_file, opened_result, {
      comments_ctx = comments_ctx,
    })
    sync_diff_comments_panel(pr, compare_details, comments_ctx)
    return true, nil
  end

  local function open_with_virtual(open_opts)
    if is_valid_win(origin_win) then
      pcall(vim.api.nvim_set_current_win, origin_win)
    end
    local diff_result, diff_err = virtual_files.open_diff(compare_details, pr, compare_file, {
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
      notify_info("File is new in compared commit range. Opened single MODIFIED buffer (diff layouts disabled).")
    elseif type(diff_result) == "table" and diff_result.file_mode == "removed_single" then
      notify_info("File was removed in compared commit range. Opened single ORIGINAL buffer (diff layouts disabled).")
    end

    diff_view_runtime.focus_virtual_diff_result(diff_result, {
      target_side = focus_side,
      target_line = focus_line,
      target_original_line = focus_side == "base" and focus_line or target_original_line,
    })

    sync_diff_comments_panel(pr, compare_details, comments_ctx)
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
    return {
      ok = false,
      pending = true,
      reason = "Diff backend decision pending",
    }
  end
  if not opened then
    notify_error(open_err)
    return {
      ok = false,
      reason = open_err,
    }
  end

  return {
    ok = true,
    base_commit_oid = selected_comment_commit_oid,
    head_commit_oid = type(latest_commit.oid) == "string" and latest_commit.oid or "",
    path = target_path,
  }
end

function M.open_thread_comment_commit_diff(payload, opts)
  -- Backward-compatible alias; behavior is evolution diff (comment commit -> latest file commit).
  return M.open_thread_comment_evolution_diff(payload, opts)
end

M._thread_fix_helpers = type(M._thread_fix_helpers) == "table" and M._thread_fix_helpers or {}

function M._thread_fix_helpers.non_negative_integer(value, fallback)
  local number = tonumber(value)
  if not number then
    return fallback
  end

  number = math.floor(number)
  if number < 0 then
    return fallback
  end

  return number
end

function M._thread_fix_helpers.normalize_target_side(side)
  local value = type(side) == "string" and side:lower() or "head"
  if value == "left" or value == "base" then
    return "base"
  end
  return "head"
end

function M._thread_fix_helpers.cache(pr, details)
  local repository = normalize_repository(details) or ""
  local cache_key = tostring(pr.number) .. "|" .. repository
  M._overview_thread_fix_cache = type(M._overview_thread_fix_cache) == "table" and M._overview_thread_fix_cache or {}
  local cache = M._overview_thread_fix_cache[cache_key]
  if type(cache) ~= "table" then
    cache = {
      commit_details = {},
    }
    M._overview_thread_fix_cache[cache_key] = cache
  end

  cache.repository = repository
  return cache
end

function M._thread_fix_helpers.fetch_commit(pr, cache, oid)
  local commit_oid = type(oid) == "string" and oid or ""
  if commit_oid == "" then
    return nil, "Missing commit oid"
  end
  if type(cache.commit_details[commit_oid]) == "table" then
    return cache.commit_details[commit_oid], nil
  end

  local commit_details, fetch_err = pr_service.fetch_commit_details(pr.number, commit_oid, {
    repository = cache.repository or "",
  })
  if not commit_details then
    return nil, fetch_err
  end

  cache.commit_details[commit_oid] = commit_details
  return commit_details, nil
end

function M._thread_fix_helpers.find_file_in_commit(commit_details, target_path)
  for _, item in ipairs(type(commit_details.files) == "table" and commit_details.files or {}) do
    local item_path = normalize_path(item.path or item.filename)
    local previous_path = normalize_path(item.previous_filename or item.previousFilename)
    if item_path == target_path or previous_path == target_path then
      return normalize_commit_file_for_diff(item)
    end
  end
  return nil
end

function M._thread_fix_helpers.sorted_commit_candidates(details)
  local commit_candidates = {}
  for _, item in ipairs(type(details.commits) == "table" and details.commits or {}) do
    local oid = type(item.oid) == "string" and item.oid or ""
    if oid ~= "" then
      commit_candidates[#commit_candidates + 1] = {
        oid = oid,
        committed_at = type(item.committedDate) == "string" and item.committedDate or "",
      }
    end
  end

  table.sort(commit_candidates, function(left, right)
    local left_key = type(left.committed_at) == "string" and left.committed_at or ""
    local right_key = type(right.committed_at) == "string" and right.committed_at or ""
    if left_key == right_key then
      return left.oid > right.oid
    end
    return left_key > right_key
  end)

  return commit_candidates
end

function M._thread_fix_helpers.resolve_target(pr, details, payload)
  local target_path = normalize_path(payload.path)
  if target_path == "" then
    return nil, "Thread comment has no file path"
  end

  local cache = M._thread_fix_helpers.cache(pr, details)
  local selected_commit = nil
  local selected_file = nil
  local last_fetch_err = nil

  for _, candidate in ipairs(M._thread_fix_helpers.sorted_commit_candidates(details)) do
    local commit_details, fetch_err = M._thread_fix_helpers.fetch_commit(pr, cache, candidate.oid)
    if not commit_details then
      last_fetch_err = fetch_err
    else
      local file = M._thread_fix_helpers.find_file_in_commit(commit_details, target_path)
      if file then
        selected_commit = commit_details
        selected_file = file
        break
      end
    end
  end

  if not selected_commit then
    local fallback_oid = type(payload.comment_commit_oid) == "string" and payload.comment_commit_oid or ""
    if fallback_oid ~= "" then
      local commit_details, fetch_err = M._thread_fix_helpers.fetch_commit(pr, cache, fallback_oid)
      if commit_details then
        local file = M._thread_fix_helpers.find_file_in_commit(commit_details, target_path)
        if file then
          selected_commit = commit_details
          selected_file = file
        end
      else
        last_fetch_err = fetch_err
      end
    end
  end

  if not selected_commit or not selected_file then
    if type(last_fetch_err) == "string" and last_fetch_err ~= "" then
      return nil, "Unable to resolve fix diff commit: " .. last_fetch_err
    end
    return nil, "Unable to find a commit in this PR that modifies " .. target_path
  end

  local target_side = M._thread_fix_helpers.normalize_target_side(payload.side)
  local target_line = positive_integer(payload.line, 0) or 0
  local target_original_line = positive_integer(payload.original_line, 0) or 0

  return {
    commit = selected_commit,
    file = selected_file,
    path = target_path,
    target_side = target_side,
    target_line = target_line,
    target_original_line = target_original_line,
  }, nil
end

function M._thread_fix_helpers.parse_patch_hunk_header(line)
  if type(line) ~= "string" then
    return nil, nil
  end

  local old_start, _, new_start = line:match("^@@%s*%-(%d+),?(%d*)%s+%+(%d+),?(%d*)%s*@@")
  if not old_start or not new_start then
    return nil, nil
  end
  return tonumber(old_start), tonumber(new_start)
end

function M._thread_fix_helpers.parse_patch_lines(lines)
  local parsed = {}
  local old_line = nil
  local new_line = nil

  for index, line in ipairs(lines) do
    local old_start, new_start = M._thread_fix_helpers.parse_patch_hunk_header(line)
    if old_start and new_start then
      old_line = old_start
      new_line = new_start
      parsed[#parsed + 1] = {
        index = index,
        is_header = true,
      }
    else
      local item = {
        index = index,
        is_header = false,
      }
      local prefix = type(line) == "string" and line:sub(1, 1) or ""
      if type(old_line) == "number" and type(new_line) == "number" then
        if prefix == "-" and line:sub(1, 3) ~= "---" then
          item.old_line = old_line
          old_line = old_line + 1
        elseif prefix == "+" and line:sub(1, 3) ~= "+++" then
          item.new_line = new_line
          new_line = new_line + 1
        else
          item.old_line = old_line
          item.new_line = new_line
          old_line = old_line + 1
          new_line = new_line + 1
        end
      end

      parsed[#parsed + 1] = item
    end
  end

  return parsed
end

function M._thread_fix_helpers.best_patch_focus_index(parsed, side, line_number)
  if type(line_number) ~= "number" or line_number < 1 then
    return nil
  end

  local best_index = nil
  local best_distance = nil
  for _, item in ipairs(parsed) do
    if item.is_header ~= true then
      local candidate_line = side == "base" and item.old_line or item.new_line
      if type(candidate_line) == "number" then
        local distance = math.abs(candidate_line - line_number)
        if best_distance == nil or distance < best_distance then
          best_distance = distance
          best_index = item.index
          if distance == 0 then
            break
          end
        end
      end
    end
  end

  return best_index
end

function M._thread_fix_helpers.first_patch_hunk_index(parsed)
  for _, item in ipairs(parsed) do
    if item.is_header == true then
      return item.index
    end
  end
  return nil
end

function M._thread_fix_helpers.trim_patch_snippet(patch, target_side, target_line, target_original_line, context_before, context_after)
  local lines = vim.split(patch, "\n", { plain = true, trimempty = false })
  if vim.tbl_isempty(lines) then
    return nil, "No textual patch available for selected commit file"
  end

  local parsed = M._thread_fix_helpers.parse_patch_lines(lines)
  if vim.tbl_isempty(parsed) then
    return nil, "No textual patch available for selected commit file"
  end

  local focus_index = nil
  if target_side == "base" then
    focus_index = M._thread_fix_helpers.best_patch_focus_index(parsed, "base", target_original_line)
    if not focus_index then
      focus_index = M._thread_fix_helpers.best_patch_focus_index(parsed, "head", target_line)
    end
  else
    focus_index = M._thread_fix_helpers.best_patch_focus_index(parsed, "head", target_line)
    if not focus_index then
      focus_index = M._thread_fix_helpers.best_patch_focus_index(parsed, "base", target_original_line)
    end
  end

  if not focus_index then
    focus_index = M._thread_fix_helpers.first_patch_hunk_index(parsed)
  end
  if not focus_index then
    focus_index = 1
  end

  local start_index = math.max(1, focus_index - context_before)
  local end_index = math.min(#lines, focus_index + context_after)
  local snippet_lines = {}
  local snippet_entries = {}

  if start_index > 1 then
    local trimmed = string.format("... (%d lines trimmed above)", start_index - 1)
    snippet_lines[#snippet_lines + 1] = trimmed
    snippet_entries[#snippet_entries + 1] = {
      text = trimmed,
    }
  end
  for index = start_index, end_index do
    local text = lines[index]
    local parsed_item = parsed[index] or {}
    snippet_lines[#snippet_lines + 1] = text
    snippet_entries[#snippet_entries + 1] = {
      text = text,
      old_line = parsed_item.old_line,
      new_line = parsed_item.new_line,
      is_header = parsed_item.is_header == true,
    }
  end
  if end_index < #lines then
    local trimmed = string.format("... (%d lines trimmed below)", #lines - end_index)
    snippet_lines[#snippet_lines + 1] = trimmed
    snippet_entries[#snippet_entries + 1] = {
      text = trimmed,
    }
  end

  return snippet_lines, nil, snippet_entries
end

function M._thread_fix_helpers.open_resolved_diff(resolved)
  M.open_commit_file_diff(resolved.commit, resolved.file, {
    target_side = resolved.target_side,
    target_line = resolved.target_line,
    target_original_line = resolved.target_original_line,
  })
end

function M.resolve_thread_fix_diff(payload, opts)
  payload = type(payload) == "table" and payload or {}
  opts = type(opts) == "table" and opts or {}

  local number = tonumber(payload.pr_number) or tonumber(vim.b.gh_pr_number)
  local pr, details, err = resolve_active_pr(number)
  if not pr then
    return {
      ok = false,
      error = err,
    }
  end

  local resolved, resolve_err = M._thread_fix_helpers.resolve_target(pr, details, payload)
  if not resolved then
    return {
      ok = false,
      error = resolve_err,
    }
  end

  resolved.pr = pr
  resolved.details = details

  if opts.inline ~= true then
    return {
      ok = true,
      commit = resolved.commit,
      file = resolved.file,
      path = resolved.path,
      target_side = resolved.target_side,
      target_line = resolved.target_line,
      target_original_line = resolved.target_original_line,
    }
  end

  local patch = type(resolved.file.patch) == "string" and resolved.file.patch or ""
  if patch == "" then
    local fallback_enabled = opts.fallback_to_buffer ~= false
    if fallback_enabled then
      M._thread_fix_helpers.open_resolved_diff(resolved)
    end
    return {
      ok = false,
      error = "No textual patch available for latest commit file",
      fallback_opened = fallback_enabled,
      commit_oid = type(resolved.commit.oid) == "string" and resolved.commit.oid or "",
      path = resolved.path,
    }
  end

  local context_before = M._thread_fix_helpers.non_negative_integer(opts.context_before, 5)
  local context_after = M._thread_fix_helpers.non_negative_integer(opts.context_after, 5)
  if type(context_before) ~= "number" then
    context_before = 5
  end
  if type(context_after) ~= "number" then
    context_after = 5
  end
  context_before = math.min(context_before, 200)
  context_after = math.min(context_after, 200)

  local snippet_lines, snippet_err, snippet_entries = M._thread_fix_helpers.trim_patch_snippet(
    patch,
    resolved.target_side,
    resolved.target_line,
    resolved.target_original_line,
    context_before,
    context_after
  )
  if not snippet_lines or vim.tbl_isempty(snippet_lines) then
    local fallback_enabled = opts.fallback_to_buffer ~= false
    if fallback_enabled then
      M._thread_fix_helpers.open_resolved_diff(resolved)
    end
    return {
      ok = false,
      error = snippet_err or "Unable to build thread fix diff snippet",
      fallback_opened = fallback_enabled,
      commit_oid = type(resolved.commit.oid) == "string" and resolved.commit.oid or "",
      path = resolved.path,
    }
  end

  return {
    ok = true,
    commit = resolved.commit,
    file = resolved.file,
    path = resolved.path,
    target_side = resolved.target_side,
    target_line = resolved.target_line,
    target_original_line = resolved.target_original_line,
    commit_oid = type(resolved.commit.oid) == "string" and resolved.commit.oid or "",
    lines = snippet_lines,
    diff_entries = type(snippet_entries) == "table" and snippet_entries or nil,
  }
end

function M.open_thread_fix_diff(payload, opts)
  opts = type(opts) == "table" and opts or {}
  local result = M.resolve_thread_fix_diff(payload, opts)
  if opts.inline == true then
    return result
  end

  if type(result) ~= "table" or result.ok ~= true then
    if type(result) == "table" and result.fallback_opened == true then
      return result
    end
    notify_warn(type(result) == "table" and result.error or "Unable to resolve thread fix diff")
    return result
  end

  M._thread_fix_helpers.open_resolved_diff(result)
  return result
end

  ThreadDiff.resolve_commit = resolve_commit
  ThreadDiff.apply_codediff_buffer_keymaps = apply_codediff_buffer_keymaps
  ThreadDiff.apply_codediff_buffer_metadata = apply_codediff_buffer_metadata
  ThreadDiff.resolve_codediff_window = resolve_codediff_window
  ThreadDiff.apply_codediff_open_result_context = apply_codediff_open_result_context
  ThreadDiff.sync_diff_comments_panel = sync_diff_comments_panel
  ThreadDiff.codediff_file_runtime = codediff_file_runtime

end

return ThreadDiff
