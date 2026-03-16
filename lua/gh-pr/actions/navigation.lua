local Navigation = {}

function Navigation.register(M, ctx)
  local comment_popup = ctx.comment_popup
  local config = ctx.config
  local find_file_in_details = ctx.find_file_in_details
  local has_full_pr_details = ctx.has_full_pr_details
  local is_valid_buf = ctx.is_valid_buf
  local normalize_path = ctx.normalize_path
  local notify_error = ctx.notify_error
  local notify_warn = ctx.notify_warn
  local positive_integer = ctx.positive_integer
  local refresh_diff_comments_panel_after_state_change = ctx.refresh_diff_comments_panel_after_state_change
  local refresh_line_comments_for_pr = ctx.refresh_line_comments_for_pr
  local refresh_pr_sources_after_state_change = ctx.refresh_pr_sources_after_state_change
  local resolve_active_pr = ctx.resolve_active_pr
  local resolve_file_in_details = ctx.resolve_file_in_details
  local safe_string = ctx.safe_string
  local state = ctx.state
  local thread_popup = ctx.thread_popup
  local url_open = ctx.url_open
  local valid_window = ctx.valid_window

  local function window_filetype(winid)
    if not winid or not vim.api.nvim_win_is_valid(winid) then
      return nil
    end

    local bufnr = vim.api.nvim_win_get_buf(winid)
    return vim.api.nvim_get_option_value("filetype", { buf = bufnr })
  end

  local function is_navigation_window(winid)
    return window_filetype(winid) ~= "neo-tree"
  end

  local function ensure_navigation_window()
    local current = vim.api.nvim_get_current_win()
    if is_navigation_window(current) then
      return current
    end

    local alternate = vim.fn.win_getid(vim.fn.winnr("#"))
    if type(alternate) == "number" and alternate > 0 and vim.api.nvim_win_is_valid(alternate) and is_navigation_window(alternate) then
      pcall(vim.api.nvim_set_current_win, alternate)
      return alternate
    end

    for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if winid ~= current and is_navigation_window(winid) then
        pcall(vim.api.nvim_set_current_win, winid)
        return winid
      end
    end

    vim.cmd("vsplit")
    return vim.api.nvim_get_current_win()
  end

  local preview_window = {
    tabid = nil,
    winid = nil,
  }

  local function preview_options()
    local options = (((config.get() or {}).line_comments or {}).comments_tree or {}).preview or {}
    return {
      keymap = type(options.keymap) == "string" and options.keymap ~= "" and options.keymap or "p",
      position = options.position == "right" and options.position or "right",
      keep_focus = options.keep_focus ~= false,
    }
  end

  local function is_marked_preview_window(winid)
    if not valid_window(winid) or window_filetype(winid) == "neo-tree" then
      return false
    end

    local ok, value = pcall(vim.api.nvim_win_get_var, winid, "gh_pr_comments_preview")
    return ok and value == true
  end

  local function mark_preview_window(winid)
    if valid_window(winid) then
      pcall(vim.api.nvim_win_set_var, winid, "gh_pr_comments_preview", true)
    end
  end

  local function ensure_preview_window(position)
    local current_tab = vim.api.nvim_get_current_tabpage()
    if preview_window.tabid == current_tab and valid_window(preview_window.winid) and window_filetype(preview_window.winid) ~= "neo-tree" then
      return preview_window.winid
    end

    for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(current_tab)) do
      if is_marked_preview_window(winid) then
        preview_window.tabid = current_tab
        preview_window.winid = winid
        return winid
      end
    end

    if position == "right" then
      vim.cmd("botright vsplit")
    else
      vim.cmd("vsplit")
    end

    local created = vim.api.nvim_get_current_win()
    mark_preview_window(created)
    preview_window.tabid = current_tab
    preview_window.winid = created
    return created
  end

  local function resolve_comment_target(target)
    if type(target) ~= "table" then
      return nil, nil, nil, nil, "Invalid comment target"
    end

    local pr = target.pr
    local details = target.details
    if type(pr) ~= "table" or type(details) ~= "table" then
      local resolved_pr, resolved_details, err = resolve_active_pr(target.pr_number or target.number, { refresh = false })
      if not resolved_pr then
        return nil, nil, nil, nil, err
      end
      pr = resolved_pr
      details = resolved_details
    end

    state.set_active_pr(pr, details)

    local path = target.path
    if type(path) ~= "string" or path == "" then
      return nil, nil, nil, nil, "Missing comment path"
    end

    local file = find_file_in_details(details, path) or {
      path = path,
      filename = path,
    }
    state.set_active_file(file)

    local side = type(target.side) == "string" and target.side or "head"
    local line = side == "base" and (target.original_line or target.line) or (target.line or target.original_line)
    local popup_comments = nil
    if type(target.thread_comments) == "table" and not vim.tbl_isempty(target.thread_comments) then
      popup_comments = target.thread_comments
    elseif type(target.line_comments) == "table" and not vim.tbl_isempty(target.line_comments) then
      popup_comments = target.line_comments
    end

    local popup_thread = nil
    if type(popup_comments) == "table" then
      popup_thread = {
        pr_number = tonumber(pr.number),
        details = details,
        thread_id = type(target.thread_id) == "string" and target.thread_id ~= ""
            and target.thread_id
          or string.format("line:%s:%s:%s", path, side, tostring(line or 0)),
        path = path,
        side = side,
        line = tonumber(target.line) or tonumber(line) or tonumber(target.original_line),
        original_line = tonumber(target.original_line) or tonumber(line) or tonumber(target.line),
        selected_comment_id = type(target.selected_comment_id) == "string" and target.selected_comment_id or "",
        is_resolved = target.thread_is_resolved == true,
        is_outdated = target.thread_is_outdated == true,
        comments = {},
      }

      for index, item in ipairs(popup_comments) do
        if type(item) == "table" then
          popup_thread.comments[#popup_thread.comments + 1] = {
            id = type(item.id) == "string" and item.id ~= "" and item.id or tostring(index),
            author = type(item.author) == "string" and item.author ~= "" and item.author or "unknown",
            created_at = type(item.created_at) == "string" and item.created_at or "",
            body = type(item.body) == "string" and item.body or "",
            url = type(item.url) == "string" and item.url or "",
            state = type(item.state) == "string" and item.state or "",
            outdated = item.outdated == true,
            is_pending = item.is_pending == true,
            viewer_did_author = item.viewer_did_author == true,
            reaction_groups = type(item.reaction_groups) == "table" and vim.deepcopy(item.reaction_groups) or {},
            path = type(item.path) == "string" and item.path ~= "" and item.path or path,
            line = tonumber(item.line) or tonumber(target.line) or tonumber(line),
            original_line = tonumber(item.original_line) or tonumber(target.original_line) or tonumber(line),
          }
        end
      end
    end

    return file, side, line, popup_thread, nil
  end

  local function open_target_file(file, side, line)
    local target_line = positive_integer(line, nil)
    if side == "base" then
      return M.open_original(file, {
        target_side = "base",
        target_original_line = target_line,
        target_line = target_line,
      })
    end

    return M.open_modified(file, {
      target_side = "head",
      target_line = target_line,
      target_original_line = target_line,
    })
  end

  function M.set_active_pr(pr, details)
    state.set_active_pr(pr, details)
  end

  function M.set_active_file(file)
    state.set_active_file(file)
  end

  function M.activate_pr(number, refresh)
    local pr, details, err = resolve_active_pr(number, { refresh = refresh == true })
    if not pr then
      return nil, nil, err
    end
    return pr, details, nil
  end

  function M.refresh_after_thread_popup_mutation(pr_number, details, opts)
    opts = type(opts) == "table" and opts or {}
    local number = tonumber(pr_number or vim.b.gh_pr_number)
    local resolved_details = type(details) == "table" and details or nil

    if number and not resolved_details then
      local _, fresh_details = resolve_active_pr(number, { refresh = false })
      resolved_details = type(fresh_details) == "table" and fresh_details or nil
    end

    if number and resolved_details then
      refresh_line_comments_for_pr(number, resolved_details)
    end

    refresh_pr_sources_after_state_change({
      force = opts.force ~= false,
    })
    refresh_diff_comments_panel_after_state_change()
  end

  function M.open_comment_location(target, opts)
    opts = opts or {}
    local file, side, line, popup_thread, err = resolve_comment_target(target)
    if not file then
      return notify_error(err)
    end

    local comments_tree_options = (((config.get() or {}).line_comments or {}).comments_tree or {})
    local open_thread_popup = comments_tree_options.auto_open_thread_popup ~= false
    if type(opts.open_thread_popup) == "boolean" then
      open_thread_popup = opts.open_thread_popup
    end

    ensure_navigation_window()
    local opened = open_target_file(file, side, line)

    if opened ~= false and open_thread_popup and popup_thread and type(popup_thread.comments) == "table"
        and not vim.tbl_isempty(popup_thread.comments) then
      local current_buf = vim.api.nvim_get_current_buf()
      local current_win = vim.api.nvim_get_current_win()
      local ok, popup_err = thread_popup.open(popup_thread, {
        mode = opts.popup_mode == "preview" and "preview" or "open",
        origin_bufnr = current_buf,
        anchor_win = current_win,
        enter = opts.focus_thread_popup,
      })
      if not ok and popup_err ~= "thread popup disabled by config" and popup_err ~= "thread has no comments" then
        notify_warn("Unable to open thread popup: " .. tostring(popup_err))
      end
    end
  end

  function M.preview_comment_location(target, opts)
    opts = opts or {}
    local file, side, line, popup_thread, err = resolve_comment_target(target)
    if not file then
      return notify_error(err)
    end

    local comments_tree_options = (((config.get() or {}).line_comments or {}).comments_tree or {})
    local open_thread_popup = comments_tree_options.auto_open_thread_popup ~= false
    if type(opts.open_thread_popup) == "boolean" then
      open_thread_popup = opts.open_thread_popup
    end

    local preview_opts = preview_options()
    local origin_window = vim.api.nvim_get_current_win()
    local preview_win = ensure_preview_window(preview_opts.position)
    if not valid_window(preview_win) then
      return notify_error("Unable to open preview window")
    end

    local switched, switch_err = pcall(vim.api.nvim_set_current_win, preview_win)
    if not switched then
      return notify_error("Unable to focus preview window: " .. tostring(switch_err))
    end

    local opened = open_target_file(file, side, line)
    local popup_focused = false

    if opened ~= false and open_thread_popup and popup_thread and type(popup_thread.comments) == "table"
        and not vim.tbl_isempty(popup_thread.comments) then
      local preview_buf = vim.api.nvim_get_current_buf()
      local ok, popup_err = thread_popup.open(popup_thread, {
        mode = opts.popup_mode == "open" and "open" or "preview",
        origin_bufnr = preview_buf,
        anchor_win = preview_win,
        enter = opts.focus_thread_popup,
      })
      if ok then
        popup_focused = vim.api.nvim_get_current_win() ~= preview_win
      end
      if not ok and popup_err ~= "thread popup disabled by config" and popup_err ~= "thread has no comments" then
        notify_warn("Unable to open thread popup: " .. tostring(popup_err))
      end
    end

    if preview_opts.keep_focus and valid_window(origin_window) and not popup_focused then
      pcall(vim.api.nvim_set_current_win, origin_window)
    end
  end

  function M.open_check_annotation_location(target, opts)
    opts = type(opts) == "table" and opts or {}
    local payload = type(target) == "table" and target or {}
    local pr = type(payload.pr) == "table" and payload.pr or nil
    local details = type(payload.details) == "table" and payload.details or nil
    local annotation = type(payload.annotation) == "table" and payload.annotation or payload
    local path = normalize_path(payload.target_path or annotation.path)
    local line = positive_integer(payload.target_line, positive_integer(annotation.start_line, nil))
    local check_url = safe_string(payload.check_url, safe_string(annotation.blob_href, ""))

    if pr and details then
      state.set_active_pr(pr, details)
    elseif pr and not details then
      state.set_active_pr(pr, pr)
    end

    if not details or not has_full_pr_details(details) then
      local active_pr, active_details = state.get_active_pr()
      if type(active_details) == "table" and has_full_pr_details(active_details) then
        pr = type(active_pr) == "table" and active_pr or pr
        details = active_details
      end
    end

    local selected_file = resolve_file_in_details(details, path)
    if not selected_file then
      if check_url ~= "" then
        url_open.open(check_url, {
          notify_error = true,
          context = "Unable to open check details",
        })
        return true
      end
      notify_error("Unable to resolve PR file for selected annotation")
      return false
    end

    local context = nil
    local annotations = type(payload.annotations) == "table" and payload.annotations or nil
    if type(annotations) == "table" and not vim.tbl_isempty(annotations) then
      context = {
        check_key = safe_string(payload.check_key or annotation.check_key, ""),
        check_name = safe_string(payload.check_name or annotation.check_name, ""),
        annotations = vim.deepcopy(annotations),
      }
    end
    if not context then
      notify_warn("Selected check has no annotations to display on this diff")
    end

    return M.open_diff(selected_file, {
      target_side = "head",
      target_line = line,
      target_original_line = line,
      check_annotations_ctx = context,
    })
  end

  function M.open_security_alert_location(target, opts)
    opts = type(opts) == "table" and opts or {}
    local payload = type(target) == "table" and target or {}
    local pr = type(payload.pr) == "table" and payload.pr or nil
    local details = type(payload.details) == "table" and payload.details or nil
    local alert = type(payload.alert) == "table" and payload.alert or payload
    local path = normalize_path(payload.target_path or alert.path)
    local line = positive_integer(payload.target_line, positive_integer(alert.start_line, nil))
    local alert_url = safe_string(payload.alert_url or alert.html_url, "")

    if pr and details then
      state.set_active_pr(pr, details)
    elseif pr and not details then
      state.set_active_pr(pr, pr)
    end

    if not details or not has_full_pr_details(details) then
      local active_pr, active_details = state.get_active_pr()
      if type(active_details) == "table" and has_full_pr_details(active_details) then
        pr = type(active_pr) == "table" and active_pr or pr
        details = active_details
      end
    end

    local selected_file = resolve_file_in_details(details, path)
    if not selected_file then
      if alert_url ~= "" then
        url_open.open(alert_url, {
          notify_error = true,
          context = "Unable to open code scanning alert",
        })
        return true
      end
      notify_error("Unable to resolve PR file for selected security alert")
      return false
    end

    local context = nil
    local alerts = type(payload.alerts) == "table" and payload.alerts or nil
    if type(alerts) == "table" and not vim.tbl_isempty(alerts) then
      context = {
        alert_key = safe_string(payload.alert_key or alert.id or alert.number, ""),
        alerts = vim.deepcopy(alerts),
      }
    end

    return M.open_diff(selected_file, {
      target_side = "head",
      target_line = line,
      target_original_line = line,
      security_annotations_ctx = context,
    })
  end

  local function timeline_kind_label(item)
    if type(item) ~= "table" then
      return "COMMENT"
    end

    if item.kind == "commit" then
      return "COMMIT"
    end
    if item.kind == "pr_change" then
      return "PR CHANGE"
    end
    if item.kind == "thread_comment" then
      return "THREAD COMMENT"
    end
    if item.kind == "review" then
      local review_state = type(item.state) == "string" and item.state:upper() or "COMMENTED"
      return "REVIEW " .. review_state
    end

    return "COMMENT"
  end

  local function timeline_item_location(item)
    local path = type(item.path) == "string" and item.path or ""
    if path == "" then
      return ""
    end

    local line = tonumber(item.line) or tonumber(item.original_line)
    if line and line > 0 then
      return string.format("%s:%d", path, line)
    end
    return path
  end

  local function timeline_item_lines(item)
    local author = type(item.author) == "string" and item.author ~= "" and item.author or "unknown"
    local created_at = type(item.created_at) == "string" and item.created_at or ""
    local url = type(item.url) == "string" and item.url or ""
    local body = type(item.body) == "string" and item.body or ""
    local kind = type(item.kind) == "string" and item.kind or "comment"
    if kind == "commit" and body == "" then
      local headline = type(item.headline) == "string" and item.headline or "(no commit headline)"
      body = headline
    end
    if kind == "pr_change" and body == "" then
      local summary = type(item.change_summary) == "string" and item.change_summary or "(pull request updated)"
      local details = type(item.change_details) == "string" and item.change_details or ""
      body = summary
      if details ~= "" then
        body = body .. "\n" .. details
      end
    end
    local lines = {
      string.format("Type: %s", timeline_kind_label(item)),
      string.format("Author: @%s", author),
    }

    if kind == "commit" then
      local oid = type(item.oid_short) == "string" and item.oid_short or ""
      if oid == "" and type(item.oid) == "string" and item.oid ~= "" then
        oid = item.oid:sub(1, 8)
      end
      if oid ~= "" then
        lines[#lines + 1] = "Commit: " .. oid
      end
    end

    if created_at ~= "" then
      lines[#lines + 1] = "Date: " .. created_at:gsub("T", " "):gsub("Z", "")
    end

    local location = timeline_item_location(item)
    if location ~= "" then
      lines[#lines + 1] = "Location: " .. location
    end

    lines[#lines + 1] = string.rep("-", 60)

    local body_lines = vim.split(body, "\n", { plain = true })
    if vim.tbl_isempty(body_lines) then
      body_lines = { "(no details)" }
    end
    for _, body_line in ipairs(body_lines) do
      lines[#lines + 1] = body_line
    end

    if url ~= "" then
      lines[#lines + 1] = ""
      lines[#lines + 1] = url
    end

    return lines
  end

  function M.open_timeline_item(item, opts)
    if type(item) ~= "table" then
      return
    end

    opts = opts or {}

    local pr = type(opts.pr) == "table" and opts.pr or nil
    local details = type(opts.details) == "table" and opts.details or nil
    if pr and details then
      state.set_active_pr(pr, details)
    end

    local origin_bufnr = is_valid_buf(opts.origin_bufnr) and opts.origin_bufnr or vim.api.nvim_get_current_buf()
    local ok, popup_err = comment_popup.open({
      origin_bufnr = origin_bufnr,
      tag = "timeline",
      title = "PR timeline",
      location = timeline_item_location(item),
      lines = timeline_item_lines(item),
      mode = "open",
      enter = true,
      position = "editor",
      border = "rounded",
      wrap = true,
      min_width = 68,
      min_height = 12,
      max_width = 150,
      max_height = 48,
      close_on_origin_move = false,
      filetype = "markdown",
    })

    if not ok and popup_err then
      notify_warn("Unable to open timeline item: " .. tostring(popup_err))
    end
  end
end

return Navigation
