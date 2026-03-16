local ReviewActions = {}

local runtime = {
  normalize_path = nil,
  normalize_repository = nil,
  notify_error = nil,
  notify_info = nil,
  notify_warn = nil,
  open_review_tree_from_plugin = nil,
  render_pr_sources_from_cache = nil,
  resolve_active_pr = nil,
  resolve_canonical_file_path = nil,
  resolve_file = nil,
  sync_remote_viewed_state_for_pr = nil,
}
local pr_service = nil
local review_prefetch = nil
local state = nil

local function require_runtime(name)
  local value = runtime[name]
  if value == nil then
    error("gh-pr.actions.review missing runtime dependency: " .. name)
  end
  return value
end

local function normalize_path(...)
  return require_runtime("normalize_path")(...)
end

local function normalize_repository(...)
  return require_runtime("normalize_repository")(...)
end

local function notify_error(...)
  return require_runtime("notify_error")(...)
end

local function notify_info(...)
  return require_runtime("notify_info")(...)
end

local function notify_warn(...)
  return require_runtime("notify_warn")(...)
end

local function open_review_tree_from_plugin(...)
  return require_runtime("open_review_tree_from_plugin")(...)
end

local function render_pr_sources_from_cache(...)
  return require_runtime("render_pr_sources_from_cache")(...)
end

local function resolve_active_pr(...)
  return require_runtime("resolve_active_pr")(...)
end

local function resolve_canonical_file_path(...)
  return require_runtime("resolve_canonical_file_path")(...)
end

local function resolve_file(...)
  return require_runtime("resolve_file")(...)
end

local function sync_remote_viewed_state_for_pr(...)
  return require_runtime("sync_remote_viewed_state_for_pr")(...)
end
local function checkout(number)
  local pr, _, err = resolve_active_pr(number)
  if not pr then
    return notify_error(err)
  end

  local ok, checkout_err = pr_service.checkout(pr.number)
  if not ok then
    return notify_error(checkout_err)
  end

  notify_info(string.format("Checked out PR #%d", pr.number))
end

local function viewed_candidate_path(candidate)
  if type(candidate) == "string" then
    return candidate
  end

  if type(candidate) ~= "table" then
    return nil
  end

  if type(candidate.path) == "string" and candidate.path ~= "" then
    return candidate.path
  end

  if type(candidate.filename) == "string" and candidate.filename ~= "" then
    return candidate.filename
  end

  if type(candidate.file) == "table" then
    if type(candidate.file.path) == "string" and candidate.file.path ~= "" then
      return candidate.file.path
    end
    if type(candidate.file.filename) == "string" and candidate.file.filename ~= "" then
      return candidate.file.filename
    end
  end

  return nil
end

local function viewed_candidate_file(candidate)
  if type(candidate) ~= "table" then
    return nil
  end

  if type(candidate.file) == "table" then
    return candidate.file
  end

  if type(candidate.path) == "string" or type(candidate.filename) == "string" then
    return candidate
  end

  return nil
end

local function resolve_viewed_targets(details, files)
  local targets = {}
  local seen_paths = {}
  for _, candidate in ipairs(type(files) == "table" and files or {}) do
    local path = resolve_canonical_file_path(details, viewed_candidate_path(candidate))
    if path ~= "" and not seen_paths[path] then
      seen_paths[path] = true
      targets[#targets + 1] = {
        path = path,
        file = viewed_candidate_file(candidate),
      }
    end
  end

  return targets
end

local function mark_files_viewed(files, viewed, opts)
  opts = opts or {}
  local pr, details, err = resolve_active_pr()
  if not pr then
    return notify_error(err)
  end

  local repository = normalize_repository(details)
  if not repository then
    return notify_error("Unable to resolve repository for viewed state")
  end

  local targets = resolve_viewed_targets(details, files)
  if vim.tbl_isempty(targets) then
    return notify_error("No files selected")
  end

  if viewed == nil then
    local has_unviewed = false
    for _, target in ipairs(targets) do
      if state.is_viewed(repository, pr.number, target.path) ~= true then
        has_unviewed = true
        break
      end
    end
    viewed = has_unviewed
  end

  local updated_count = 0
  local unchanged_count = 0
  local failed_count = 0
  local pending_targets = {}
  local remote_cache_loaded = type(state.has_remote_viewed_state) == "function"
      and state.has_remote_viewed_state(repository, pr.number)
    or false

  for _, target in ipairs(targets) do
    if state.is_viewed(repository, pr.number, target.path) == viewed then
      unchanged_count = unchanged_count + 1
    else
      pending_targets[#pending_targets + 1] = target
    end
  end

  local remote_result = nil
  local remote_err = nil
  if not vim.tbl_isempty(pending_targets) and opts.local_only ~= true and type(pr_service.set_files_viewed) == "function" then
    local paths = {}
    for _, target in ipairs(pending_targets) do
      paths[#paths + 1] = target.path
    end
    remote_result, remote_err = pr_service.set_files_viewed(pr.number, paths, viewed, opts.remote or {})
  end

  if remote_result then
    local succeeded = {}
    for _, path in ipairs(type(remote_result.updated_paths) == "table" and remote_result.updated_paths or {}) do
      succeeded[path] = true
    end

    for _, target in ipairs(pending_targets) do
      if succeeded[target.path] then
        local ok_remote = true
        if remote_cache_loaded and type(state.set_remote_viewed) == "function" then
          ok_remote = state.set_remote_viewed(repository, pr.number, target.path, viewed)
        end
        local ok_local = state.set_viewed(repository, pr.number, target.path, viewed)
        if ok_remote and ok_local then
          updated_count = updated_count + 1
        else
          failed_count = failed_count + 1
        end
      else
        failed_count = failed_count + 1
      end
    end
  else
    for _, target in ipairs(pending_targets) do
      local ok = state.set_viewed(repository, pr.number, target.path, viewed)
      if ok then
        updated_count = updated_count + 1
      else
        failed_count = failed_count + 1
      end
    end
  end

  local first_file = targets[1] and targets[1].file or nil
  if type(first_file) == "table" then
    state.set_active_file(first_file)
  end

  if updated_count > 0 then
    render_pr_sources_from_cache()
  end

  if remote_result == nil and type(remote_err) == "string" and remote_err ~= "" and opts.notify ~= false then
    notify_warn("Unable to sync viewed state with GitHub, using local fallback: " .. remote_err)
  end

  if opts.notify ~= false then
    local viewed_label = viewed and "viewed" or "unviewed"
    local total = #targets
    if total == 1 then
      if failed_count > 0 then
        notify_error(string.format("Unable to mark %s as %s", targets[1].path, viewed_label))
      elseif updated_count > 0 then
        notify_info(string.format("Marked %s as %s", targets[1].path, viewed_label))
      else
        notify_info(string.format("%s is already %s", targets[1].path, viewed_label))
      end
    else
      if failed_count > 0 then
        notify_warn(string.format(
          "Applied %s to %d/%d files (%d unchanged, %d failed)",
          viewed_label,
          updated_count,
          total,
          unchanged_count,
          failed_count
        ))
      elseif updated_count == total then
        notify_info(string.format("Marked %d files as %s", total, viewed_label))
      elseif updated_count == 0 then
        notify_info(string.format("All %d files are already %s", total, viewed_label))
      else
        notify_info(string.format(
          "Marked %d/%d files as %s (%d already %s)",
          updated_count,
          total,
          viewed_label,
          unchanged_count,
          viewed_label
        ))
      end
    end
  end

  return {
    viewed = viewed,
    total = #targets,
    updated_count = updated_count,
    unchanged_count = unchanged_count,
    failed_count = failed_count,
  }
end

local function mark_file_viewed(file, viewed)
  local selected_file = resolve_file(file)
  if not selected_file then
    return notify_error("No file selected")
  end

  mark_files_viewed({ selected_file }, viewed)
end

local function toggle_viewed()
  local kind = vim.b.gh_pr_file_kind
  local path = vim.b.gh_pr_file_path or vim.b.gh_pr_path
  local number = vim.b.gh_pr_number
  local repository = vim.b.gh_pr_repo

  if kind == "patch" then
    return notify_error("Viewed state is only available for file buffers")
  end

  if type(path) == "string" and type(number) == "number" and type(repository) == "string" then
    local _, details = state.get_active_pr()
    if type(details) == "table" and tonumber(details.number) == number then
      path = resolve_canonical_file_path(details, path)
    else
      path = normalize_path(path)
    end

    if path == "" then
      return notify_error("Unable to resolve file path")
    end

    return mark_files_viewed({
      {
        path = path,
        filename = path,
      },
    }, nil)
  end

  mark_file_viewed(nil, nil)
end

local function sync_remote_viewed_state(pr_number, details, opts)
  return sync_remote_viewed_state_for_pr(pr_number, details, opts)
end

local function set_active_review(pr, details)
  details = details or pr
  local repository = normalize_repository(details)
  if not repository then
    return false, "Unable to resolve repository for active review"
  end

  local stored = state.set_active_review(repository, pr, details)
  if not stored then
    return false, "Unable to store active review state"
  end

  return true, nil
end

local function activate_review(number, opts)
  opts = opts or {}
  local pr, details, err = resolve_active_pr(number, { refresh = opts.refresh == true })
  if not pr then
    return nil, nil, err
  end

  local ok, review_err = set_active_review(pr, details)
  if not ok then
    return nil, nil, review_err
  end

  return pr, details, nil
end

local function toggle_review_tree()
  local ok, err = open_review_tree_from_plugin({ toggle = true })
  if not ok and err then
    notify_error(err)
  end
end

local function toggle_diff_comments_panel()
  local kind = vim.b.gh_pr_file_kind
  if kind ~= "base" and kind ~= "head" and kind ~= "unified" then
    return notify_error("Current buffer is not a gh-pr diff buffer")
  end
  if vim.b.gh_pr_is_non_text == true then
    return notify_warn("Diff comments panel is not available for non-text previews.")
  end

  local pr, details, err = resolve_active_pr(vim.b.gh_pr_number, { refresh = false })
  if not pr then
    return notify_error(err)
  end

  local ok_panel, panel = pcall(require, "gh-pr.diff_comments_panel")
  if not ok_panel then
    return notify_error("Unable to load diff comments panel: " .. tostring(panel))
  end
  if type(panel.toggle) ~= "function" then
    return notify_error("Diff comments panel toggle is unavailable")
  end

  local ok_toggle, toggled, toggle_err = pcall(panel.toggle, {
    pr = pr,
    details = details,
    pr_number = pr.number,
    origin_win = vim.api.nvim_get_current_win(),
    origin_buf = vim.api.nvim_get_current_buf(),
    file_path = normalize_path(vim.b.gh_pr_file_path or vim.b.gh_pr_path),
    file_kind = vim.b.gh_pr_file_kind,
  })
  if not ok_toggle then
    return notify_error("Unable to toggle diff comments panel: " .. tostring(toggled))
  end
  if toggled ~= true and type(toggle_err) == "string" and toggle_err ~= "" then
    return notify_error(toggle_err)
  end
end

local function start_review(number)
  local pr, details, err = resolve_active_pr(number, { refresh = number ~= nil })
  if not pr then
    return notify_error(err)
  end

  local repository = normalize_repository(details)
  if not repository then
    return notify_error("Unable to resolve repository for PR review")
  end

  local current_pr = state.get_active_review(repository)

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

    if type(entity.requestedReviewer) == "table"
      and type(entity.requestedReviewer.login) == "string"
      and entity.requestedReviewer.login ~= "" then
      return entity.requestedReviewer.login
    end

    if type(entity.user) == "table" and type(entity.user.login) == "string" and entity.user.login ~= "" then
      return entity.user.login
    end

    return nil
  end

  local function active_review_matches_pr()
    local current_number = tonumber(type(current_pr) == "table" and current_pr.number or nil)
    local target_number = tonumber(type(pr) == "table" and pr.number or nil)
    return current_number ~= nil and target_number ~= nil and current_number == target_number
  end

  local function resolve_pr_author_login()
    local author_login = extract_login(type(details) == "table" and details.author or nil)
    if author_login then
      return author_login
    end
    return extract_login(type(pr) == "table" and pr.author or nil)
  end

  local function is_user_requested_reviewer(login)
    if type(login) ~= "string" or login == "" then
      return false
    end

    for _, reviewer in ipairs(type(details) == "table" and type(details.reviewRequests) == "table" and details.reviewRequests or {}) do
      if extract_login(reviewer) == login then
        return true
      end
    end

    return false
  end

  local function should_prompt_start_review()
    if active_review_matches_pr() then
      return false, nil
    end

    if type(pr_service.get_current_user_login) ~= "function" then
      return true, "Unable to verify current GitHub user. Showing confirmation dialog."
    end

    local login, login_err = pr_service.get_current_user_login()
    if type(login) ~= "string" or login == "" then
      return true, "Unable to resolve current GitHub user (" .. tostring(login_err) .. "). Showing confirmation dialog."
    end

    local author_login = resolve_pr_author_login()
    if type(author_login) == "string" and author_login ~= "" and author_login == login then
      return false, nil
    end

    if not is_user_requested_reviewer(login) then
      return false, nil
    end

    local pending_review, pending_err = pr_service.find_pending_review(pr.number)
    if pending_err then
      return true, "Unable to verify pending review (" .. tostring(pending_err) .. "). Showing confirmation dialog."
    end

    if type(pending_review) == "table" and type(pending_review.id) == "string" and pending_review.id ~= "" then
      return false, nil
    end

    return true, nil
  end

  local function finalize_start()
    local stored, store_err = set_active_review(pr, details)
    if not stored then
      notify_error(store_err)
      return
    end

    state.set_active_pr(pr, details)
    local opened, open_err = open_review_tree_from_plugin({ toggle = false })
    sync_remote_viewed_state_for_pr(pr.number, details, {
      notify_error = false,
    })
    review_prefetch.prefetch_review(pr, details, {
      source = "start_review",
    })
    if not opened and open_err then
      notify_warn("Review started but PR Review source could not be opened: " .. tostring(open_err))
      return
    end
    notify_info(string.format("Started review for PR #%d", pr.number))
  end

  local function prompt_remote_review()
    vim.ui.select({ "yes", "no", "cancel" }, {
      prompt = string.format("Notify GitHub that review started for PR #%d?", pr.number),
    }, function(choice)
      if choice == nil or choice == "cancel" then
        notify_info("Start review cancelled")
        return
      end

      if choice == "yes" then
        local pending_ok, pending_err = pr_service.ensure_pending_review(pr.number)
        if not pending_ok then
          notify_error(pending_err)
          return
        end
      end

      finalize_start()
    end)
  end

  local function continue_start_flow()
    local should_prompt, warning_message = should_prompt_start_review()
    if warning_message then
      notify_warn(warning_message)
    end

    if should_prompt then
      prompt_remote_review()
      return
    end

    finalize_start()
  end

  if current_pr and tonumber(current_pr.number) and tonumber(current_pr.number) ~= tonumber(pr.number) then
    vim.ui.select({ "replace", "cancel" }, {
      prompt = string.format(
        "Replace active review PR #%d with PR #%d for %s?",
        tonumber(current_pr.number),
        tonumber(pr.number),
        repository
      ),
    }, function(choice)
      if choice ~= "replace" then
        notify_info("Start review cancelled")
        return
      end
      continue_start_flow()
    end)
    return
  end

  continue_start_flow()
end

function ReviewActions.register(M, ctx)
  runtime.normalize_path = type(ctx) == "table" and ctx.normalize_path or nil
  runtime.normalize_repository = type(ctx) == "table" and ctx.normalize_repository or nil
  runtime.notify_error = type(ctx) == "table" and ctx.notify_error or nil
  runtime.notify_info = type(ctx) == "table" and ctx.notify_info or nil
  runtime.notify_warn = type(ctx) == "table" and ctx.notify_warn or nil
  runtime.open_review_tree_from_plugin = type(ctx) == "table" and ctx.open_review_tree_from_plugin or nil
  runtime.render_pr_sources_from_cache = type(ctx) == "table" and ctx.render_pr_sources_from_cache or nil
  runtime.resolve_active_pr = type(ctx) == "table" and ctx.resolve_active_pr or nil
  runtime.resolve_canonical_file_path = type(ctx) == "table" and ctx.resolve_canonical_file_path or nil
  runtime.resolve_file = type(ctx) == "table" and ctx.resolve_file or nil
  runtime.sync_remote_viewed_state_for_pr = type(ctx) == "table" and ctx.sync_remote_viewed_state_for_pr or nil
  pr_service = type(ctx) == "table" and ctx.pr_service or nil
  review_prefetch = type(ctx) == "table" and ctx.review_prefetch or nil
  state = type(ctx) == "table" and ctx.state or nil

  M.checkout = checkout
  M.mark_files_viewed = mark_files_viewed
  M.mark_file_viewed = mark_file_viewed
  M.toggle_viewed = toggle_viewed
  M.sync_remote_viewed_state = sync_remote_viewed_state
  M.set_active_review = set_active_review
  M.activate_review = activate_review
  M.toggle_review_tree = toggle_review_tree
  M.toggle_diff_comments_panel = toggle_diff_comments_panel
  M.start_review = start_review
end

return ReviewActions
