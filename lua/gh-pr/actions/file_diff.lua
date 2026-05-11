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
  local pr_service = ctx.pr_service
  local repo = ctx.repo
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

  local function pr_explorer_enabled()
    local plugin_config = type(config.get()) == "table" and config.get() or {}
    local diff_view = type(plugin_config.diff_view) == "table" and plugin_config.diff_view or {}
    local pr_explorer = type(diff_view.pr_explorer) == "table" and diff_view.pr_explorer or {}
    return pr_explorer.enabled ~= false
  end

  local function joinpath(...)
    if vim.fs and type(vim.fs.joinpath) == "function" then
      return vim.fs.joinpath(...)
    end
    return table.concat({ ... }, "/")
  end

  local function current_source_name()
    local bufnr = vim.api.nvim_get_current_buf()
    local ok_filetype, filetype = pcall(vim.api.nvim_get_option_value, "filetype", { buf = bufnr })
    filetype = ok_filetype and filetype or vim.bo[bufnr].filetype
    if filetype == "neo-tree" then
      local source_name = vim.b[bufnr].neo_tree_source
      if type(source_name) == "string" and source_name ~= "" then
        return source_name
      end
    end

    local stored_source_name = vim.b[bufnr].gh_pr_source_name
    if type(stored_source_name) == "string" and stored_source_name ~= "" then
      return stored_source_name
    end

    return nil
  end

  local function resolve_source_git_root(source_name)
    source_name = type(source_name) == "string" and source_name or current_source_name()
    if source_name ~= "gh_my_pr" and source_name ~= "gh_pr_review" then
      return nil
    end

    local manager_ok, manager = pcall(require, "neo-tree.sources.manager")
    if manager_ok and type(manager.get_state_for_window) == "function" then
      local winid = vim.api.nvim_get_current_win()
      local ok_state, tree_state = pcall(manager.get_state_for_window, winid)
      local tree_path = ok_state and type(tree_state) == "table" and tree_state.path or nil
      if type(tree_path) == "string" and tree_path ~= "" then
        if type(repo) == "table" and type(repo.git_root) == "function" then
          local git_root = select(1, repo.git_root({ cwd = tree_path }))
          if type(git_root) == "string" and git_root ~= "" then
            return git_root
          end
        end
      end
    end

    if type(repo) == "table" and type(repo.git_root) == "function" then
      return select(1, repo.git_root())
    end

    return nil
  end

  local function extract_login(entity)
    if type(entity) == "string" and entity ~= "" then
      return entity
    end

    if type(entity) ~= "table" then
      return nil
    end

    if type(entity.login) == "string" and entity.login ~= "" then
      return entity.login
    end

    if type(entity.author) == "table" and type(entity.author.login) == "string" and entity.author.login ~= "" then
      return entity.author.login
    end

    return nil
  end

  local function repository_name_with_owner(repository)
    if type(repository) ~= "table" then
      return ""
    end

    if type(repository.nameWithOwner) == "string" and repository.nameWithOwner ~= "" then
      return repository.nameWithOwner
    end

    local owner = type(repository.owner) == "table" and (repository.owner.login or repository.owner.name) or repository.owner
    local name = repository.name
    if type(owner) == "string" and owner ~= "" and type(name) == "string" and name ~= "" then
      return owner .. "/" .. name
    end

    return ""
  end

  local function review_pr_matches_local_branch(pr, details, git_root)
    if type(pr_service) ~= "table" or type(pr_service.get_current_user_login) ~= "function" then
      return false
    end

    local login = select(1, pr_service.get_current_user_login())
    if type(login) ~= "string" or login == "" then
      return false
    end

    local author_login = extract_login(type(details) == "table" and details.author or nil)
      or extract_login(type(pr) == "table" and pr.author or nil)
    if author_login ~= login then
      return false
    end

    if type(repo) ~= "table" then
      return false
    end

    local branch = type(repo.current_branch) == "function" and select(1, repo.current_branch({ cwd = git_root })) or nil
    if type(branch) ~= "string" or vim.trim(branch) == "" then
      return false
    end

    local head_ref = safe_string(
      type(details) == "table" and details.headRefName or (type(pr) == "table" and pr.headRefName or "")
    )
    if vim.trim(branch) ~= head_ref then
      return false
    end

    local head_repository = repository_name_with_owner(type(details) == "table" and details.headRepository or nil)
    if head_repository == "" and type(details) == "table" and details.isCrossRepository == false then
      head_repository = repository_name_with_owner(details.baseRepository)
    end
    if head_repository == "" and type(pr) == "table" then
      head_repository = repository_name_with_owner(pr.headRepository)
    end
    if head_repository == "" then
      return false
    end

    local local_repository = nil
    if type(repo.resolve_repository) == "function" then
      local plugin_config = type(config.get()) == "table" and config.get() or {}
      local remotes = type(plugin_config.remotes) == "table" and plugin_config.remotes or nil
      local_repository = select(1, repo.resolve_repository(remotes, { cwd = git_root }))
    end

    return type(local_repository) == "table" and local_repository.full_name == head_repository
  end

  local function local_head_path_available(path)
    if type(path) ~= "string" or path == "" then
      return false
    end

    local absolute = vim.fn.fnamemodify(path, ":p")
    return vim.fn.filereadable(absolute) == 1 or vim.fn.bufexists(absolute) == 1
  end

  local function resolve_local_editable_head_context(file, pr, details)
    local source_name = current_source_name()
    if source_name == "gh_my_pr" or source_name == "gh_pr_review" then
      local status = safe_string(type(file) == "table" and file.status or ""):lower()
      if status == "removed" then
        return nil, source_name
      end

      local git_root = resolve_source_git_root(source_name)
      local relative_path = normalize_path(type(file) == "table" and (file.path or file.filename) or nil)
      if type(git_root) ~= "string" or git_root == "" or relative_path == "" then
        return nil, source_name
      end
      if source_name == "gh_pr_review" and not review_pr_matches_local_branch(pr, details, git_root) then
        return nil, source_name
      end

      local local_head_path = joinpath(git_root, relative_path)
      if local_head_path_available(local_head_path) then
        return local_head_path, source_name
      end

      return nil, source_name
    end

    local bufnr = vim.api.nvim_get_current_buf()
    local stored_source_name = vim.b[bufnr].gh_pr_source_name
    local stored_local_head_path = vim.b[bufnr].gh_pr_local_head_path
    if (stored_source_name == "gh_my_pr" or stored_source_name == "gh_pr_review")
      and type(stored_local_head_path) == "string"
      and stored_local_head_path ~= ""
      and local_head_path_available(stored_local_head_path) then
      return stored_local_head_path, stored_source_name
    end

    return nil, source_name
  end

  local function build_codediff_selection_handler(pr, details, comments_ctx, extra_ctx)
    extra_ctx = type(extra_ctx) == "table" and extra_ctx or {}
    return function(active_file, open_result)
      if type(active_file) == "table" then
        state.set_active_file(active_file)
      end

      apply_codediff_open_result_context(pr, details, active_file, open_result, {
        comments_ctx = comments_ctx,
        check_annotations_ctx = extra_ctx.check_annotations_ctx,
        security_annotations_ctx = extra_ctx.security_annotations_ctx,
        source_name = extra_ctx.source_name,
        local_head_path = extra_ctx.local_head_path,
      })
      sync_diff_comments_panel(pr, details, comments_ctx)
      local ok_changes, changes_panel = pcall(require, "gh-pr.diff_changes_panel")
      if ok_changes and type(changes_panel.sync_for_diff) == "function" then
        local origin_win = vim.api.nvim_get_current_win()
        local origin_buf = vim.api.nvim_get_current_buf()
        pcall(changes_panel.sync_for_diff, {
          pr = pr,
          details = details,
          pr_number = pr.number,
          origin_win = origin_win,
          origin_buf = origin_buf,
          file_path = normalize_path(vim.b[origin_buf].gh_pr_file_path or vim.b[origin_buf].gh_pr_path),
          file_kind = vim.b[origin_buf].gh_pr_file_kind,
          open_result = open_result,
        })
      end
    end
  end

  local function open_pr_text_diff_with_codediff(pr, details, selected_file, open_opts)
    open_opts = type(open_opts) == "table" and open_opts or {}
    local selected_path = normalize_path(selected_file.path or selected_file.filename)
    local on_selection = build_codediff_selection_handler(pr, details, open_opts.comments_ctx, {
      check_annotations_ctx = open_opts.check_annotations_ctx,
      security_annotations_ctx = open_opts.security_annotations_ctx,
      source_name = open_opts.source_name,
      local_head_path = open_opts.local_head_path,
    })

    local explorer_err = nil
    if pr_explorer_enabled() and not (type(open_opts.local_head_path) == "string" and open_opts.local_head_path ~= "") then
      local opened_explorer, open_explorer_err = codediff_integration.open_pr_explorer_diff({
        pr_number = pr.number,
        details = details,
        files = details.files,
        file = selected_file,
        layout = open_opts.layout,
        ignore_trim_whitespace = open_opts.ignore_trim_whitespace,
        target_side = open_opts.target_side,
        target_line = open_opts.target_line,
        target_original_line = open_opts.target_original_line,
        on_selection = on_selection,
        reuse = open_opts.new_tab ~= true,
        force = open_opts.force ~= false,
        only_if_cached = true,
      })
      if opened_explorer then
        return true, nil
      end
      explorer_err = open_explorer_err
    end

    local file_open_opts = {
      details = details,
      file = selected_file,
      cache_scope = string.format(
        "%s|%d|%s|%s|%s",
        open_opts.cache_scope_prefix or "pr-file",
        pr.number,
        safe_string(details.baseRefName),
        safe_string(details.headRefName),
        selected_path
      ),
      layout = open_opts.layout,
      ignore_trim_whitespace = open_opts.ignore_trim_whitespace == true,
      target_side = open_opts.target_side,
      target_line = open_opts.target_line,
      target_original_line = open_opts.target_original_line,
      local_head_path = open_opts.local_head_path,
      source_name = open_opts.source_name,
    }

    local explorer_cache_cold = explorer_err == "codediff PR explorer snapshot is not ready yet"
    if explorer_cache_cold
      and not (type(open_opts.local_head_path) == "string" and open_opts.local_head_path ~= "")
      and type(codediff_integration.open_pr_file_diff_async) == "function" then
      codediff_integration.open_pr_file_diff_async(file_open_opts, function(opened_result, codediff_err)
        if not opened_result then
          notify_error(codediff_err or explorer_err or "Unable to open codediff file diff")
          return
        end
        on_selection(selected_file, opened_result)
      end)

      if type(codediff_integration.prefetch_pr_explorer_snapshot) == "function" then
        codediff_integration.prefetch_pr_explorer_snapshot({
          pr_number = pr.number,
          details = details,
          files = details.files,
          file = selected_file,
        }, function(_, snapshot_err)
          if snapshot_err then
            notify_warn("Unable to prepare codediff PR explorer in background: " .. tostring(snapshot_err))
          end
        end)
      end

      return true, nil
    end

    local opened_result, codediff_err = codediff_integration.open_pr_file_diff(file_open_opts)
    if not opened_result then
      return nil, codediff_err or explorer_err
    end

    on_selection(selected_file, opened_result)
    return true, nil
  end

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
  local local_head_path, source_name = resolve_local_editable_head_context(selected_file, pr, details)
  local uses_non_text_preview = non_text_preview.file_uses_non_text_preview(selected_file)
  local comments_ctx = uses_non_text_preview and nil or build_line_comment_context(pr.number)

  local function open_with_codediff(diff_view)
    return open_pr_text_diff_with_codediff(pr, details, selected_file, {
      cache_scope_prefix = "pr-file",
      layout = diff_view.mode,
      ignore_trim_whitespace = diff_view.ignore_whitespace_mode == "trim",
      comments_ctx = comments_ctx,
      new_tab = opts.new_tab,
      target_side = opts.target_side,
      target_line = opts.target_line,
      target_original_line = opts.target_original_line,
      check_annotations_ctx = opts.check_annotations_ctx,
      security_annotations_ctx = opts.security_annotations_ctx,
      local_head_path = local_head_path,
      source_name = source_name,
    })
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
    local ok_changes, changes_panel = pcall(require, "gh-pr.diff_changes_panel")
    if ok_changes and type(changes_panel.sync_for_diff) == "function" then
      local origin_buf = vim.api.nvim_get_current_buf()
      if vim.b[origin_buf].gh_pr_is_non_text ~= true then
        pcall(changes_panel.sync_for_diff, {
          pr = pr,
          details = details,
          pr_number = pr.number,
          origin_win = vim.api.nvim_get_current_win(),
          origin_buf = origin_buf,
          file_path = normalize_path(vim.b[origin_buf].gh_pr_file_path or vim.b[origin_buf].gh_pr_path),
          file_kind = vim.b[origin_buf].gh_pr_file_kind,
          diff_result = diff_result,
        })
      end
    end
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
  local local_head_path, source_name = resolve_local_editable_head_context(selected_file, pr, details)
  local target_line = positive_integer(opts.target_original_line, positive_integer(opts.target_line, nil))
  local uses_non_text_preview = non_text_preview.file_uses_non_text_preview(selected_file)
  local comments_ctx = uses_non_text_preview and nil or build_line_comment_context(pr.number)

  local function open_with_codediff()
    return open_pr_text_diff_with_codediff(pr, details, selected_file, {
      cache_scope_prefix = "pr-original",
      comments_ctx = comments_ctx,
      target_side = "base",
      target_original_line = target_line,
      target_line = target_line,
      check_annotations_ctx = opts.check_annotations_ctx,
      security_annotations_ctx = opts.security_annotations_ctx,
      local_head_path = local_head_path,
      source_name = source_name,
    })
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
  local local_head_path, source_name = resolve_local_editable_head_context(selected_file, pr, details)
  local target_line = positive_integer(opts.target_line, positive_integer(opts.target_original_line, nil))
  local uses_non_text_preview = non_text_preview.file_uses_non_text_preview(selected_file)
  local comments_ctx = uses_non_text_preview and nil or build_line_comment_context(pr.number)

  local function open_with_codediff()
    return open_pr_text_diff_with_codediff(pr, details, selected_file, {
      cache_scope_prefix = "pr-modified",
      comments_ctx = comments_ctx,
      target_side = "head",
      target_line = target_line,
      target_original_line = target_line,
      check_annotations_ctx = opts.check_annotations_ctx,
      security_annotations_ctx = opts.security_annotations_ctx,
      local_head_path = local_head_path,
      source_name = source_name,
    })
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
  local local_head_path, source_name = resolve_local_editable_head_context(selected_file, pr, details)
  local uses_non_text_preview = non_text_preview.file_uses_non_text_preview(selected_file)
  local comments_ctx = uses_non_text_preview and nil or build_line_comment_context(pr.number)
  local function open_with_codediff(diff_view)
    return open_pr_text_diff_with_codediff(pr, details, selected_file, {
      cache_scope_prefix = "pr-file",
      layout = diff_view.mode,
      ignore_trim_whitespace = diff_view.ignore_whitespace_mode == "trim",
      comments_ctx = comments_ctx,
      new_tab = opts.new_tab,
      target_side = kind == "base" and "base" or "head",
      target_line = cursor[1],
      target_original_line = cursor[1],
      force = true,
      local_head_path = local_head_path,
      source_name = source_name,
    })
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
    local ok_changes, changes_panel = pcall(require, "gh-pr.diff_changes_panel")
    if ok_changes and type(changes_panel.sync_for_diff) == "function" then
      local origin_buf = vim.api.nvim_get_current_buf()
      if vim.b[origin_buf].gh_pr_is_non_text ~= true then
        pcall(changes_panel.sync_for_diff, {
          pr = pr,
          details = details,
          pr_number = pr.number,
          origin_win = vim.api.nvim_get_current_win(),
          origin_buf = origin_buf,
          file_path = normalize_path(vim.b[origin_buf].gh_pr_file_path or vim.b[origin_buf].gh_pr_path),
          file_kind = vim.b[origin_buf].gh_pr_file_kind,
          diff_result = diff_result,
        })
      end
    end
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
    local ok_changes, changes_panel = pcall(require, "gh-pr.diff_changes_panel")
    if ok_changes and type(changes_panel.close_current_tab) == "function" then
      pcall(changes_panel.close_current_tab, { suppress_auto_open = true })
    end
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
  local ok_changes, changes_panel = pcall(require, "gh-pr.diff_changes_panel")
  if ok_changes and type(changes_panel.close_current_tab) == "function" then
    pcall(changes_panel.close_current_tab, { suppress_auto_open = true })
  end
  open_review_tree_after_close()
end

function M.close_all_and_open_review()
  local ok_changes, changes_panel = pcall(require, "gh-pr.diff_changes_panel")
  if ok_changes and type(changes_panel.close_current_tab) == "function" then
    pcall(changes_panel.close_current_tab, { suppress_auto_open = true })
  end

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
  add_shortcut(lines, shortcuts.toggle_changes_panel, "Toggle diff changes panel")

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
