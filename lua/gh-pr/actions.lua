local M = {}

local comment_composer = require("gh-pr.comment_composer")
local comment_popup = require("gh-pr.comment_popup")
local config = require("gh-pr.config")
local diff_shortcuts_config = require("gh-pr.diff_shortcuts")
local gh = require("gh-pr.gh")
local image_metadata = require("gh-pr.image_metadata")
local line_comments = require("gh-pr.line_comments")
local multi_select = require("gh-pr.multi_select")
local overview = require("gh-pr.overview")
local pr_service = require("gh-pr.pr_service")
local state = require("gh-pr.state")
local thread_popup = require("gh-pr.thread_popup")
local virtual_files = require("gh-pr.virtual_files")
local uv = vim.uv or vim.loop

local function normalize_repository(details)
  local repository = details.baseRepository or details.headRepository
  if not repository then
    local resolved, _ = pr_service.resolve_repository()
    return resolved and resolved.full_name or nil
  end

  if type(repository.nameWithOwner) == "string" then
    return repository.nameWithOwner
  end

  local owner
  if type(repository.owner) == "table" then
    owner = repository.owner.login
  else
    owner = repository.owner
  end

  local name = repository.name
  if not name and type(repository.nameWithOwner) == "string" then
    local _, parsed = repository.nameWithOwner:match("^([^/]+)/(.+)$")
    name = parsed
  end

  if type(owner) == "string" and type(name) == "string" then
    return owner .. "/" .. name
  end

  local resolved, _ = pr_service.resolve_repository()
  return resolved and resolved.full_name or nil
end

local function notify_error(err)
  if err then
    vim.notify(err, vim.log.levels.ERROR)
  end
end

local function notify_info(message)
  vim.notify(message, vim.log.levels.INFO)
end

local function notify_warn(message)
  vim.notify(message, vim.log.levels.WARN)
end

local function open_review_tree_from_plugin(opts)
  local ok, gh_pr = pcall(require, "gh-pr")
  if not ok or type(gh_pr.open_review_tree) ~= "function" then
    return false, "Unable to open PR Review source (gh-pr.open_review_tree not available)"
  end

  local status, err = pcall(gh_pr.open_review_tree, opts or {})
  if not status then
    return false, tostring(err)
  end

  return err ~= false, nil
end

local function is_valid_buf(bufnr)
  return type(bufnr) == "number" and bufnr > 0 and vim.api.nvim_buf_is_valid(bufnr)
end

local function is_valid_win(winid)
  return type(winid) == "number" and winid > 0 and vim.api.nvim_win_is_valid(winid)
end

local function sanitize_modal_window(winid)
  if not is_valid_win(winid) then
    return
  end

  pcall(vim.api.nvim_set_option_value, "scrollbind", false, { win = winid })
  pcall(vim.api.nvim_set_option_value, "cursorbind", false, { win = winid })
  pcall(vim.api.nvim_set_option_value, "diff", false, { win = winid })
end

local function buffer_filetype(bufnr)
  if not is_valid_buf(bufnr) then
    return ""
  end

  local ok, filetype = pcall(vim.api.nvim_get_option_value, "filetype", { buf = bufnr })
  if ok and type(filetype) == "string" then
    return filetype
  end

  return type(vim.bo[bufnr].filetype) == "string" and vim.bo[bufnr].filetype or ""
end

local function positive_integer(value, fallback)
  local number = tonumber(value)
  if not number then
    return fallback
  end

  number = math.floor(number)
  if number < 1 then
    return fallback
  end

  return number
end

local function valid_overview_sections()
  return {
    checks = true,
    commits = true,
    timeline = true,
  }
end

local function normalize_overview_limits(input)
  local overview_config = (config.get() or {}).overview or {}
  local defaults = overview_config.max_items or {}
  local limits = type(input) == "table" and vim.deepcopy(input) or {}

  limits.checks = positive_integer(limits.checks, positive_integer(defaults.checks, 10))
  limits.commits = positive_integer(limits.commits, positive_integer(defaults.commits, 10))
  limits.timeline = positive_integer(
    limits.timeline,
    positive_integer(defaults.timeline, math.max(positive_integer(defaults.comments, 30), positive_integer(defaults.reviews, 30)))
  )
  limits.comments = positive_integer(limits.comments, limits.timeline)
  limits.reviews = positive_integer(limits.reviews, limits.timeline)
  limits.threads = positive_integer(limits.threads, limits.timeline)
  limits.timeline = math.max(limits.timeline, limits.comments, limits.reviews, limits.threads)

  return limits
end

local function current_overview_limits()
  local bufnr = vim.api.nvim_get_current_buf()
  local stored = vim.b[bufnr].gh_pr_overview_limits
  return normalize_overview_limits(type(stored) == "table" and stored or nil)
end

local function line_comment_options()
  local options = (config.get() or {}).line_comments or {}
  return {
    enabled = options.enabled ~= false,
    show_resolved = options.show_resolved ~= false,
    show_outdated = options.show_outdated ~= false,
    keymap = type(options.keymap) == "string" and options.keymap ~= "" and options.keymap or "K",
    signs = type(options.signs) == "table" and options.signs or {},
    max_popup_width = positive_integer(options.max_popup_width, 90),
    max_popup_height = positive_integer(options.max_popup_height, 18),
  }
end

local function build_line_comment_context(pr_number)
  local options = line_comment_options()
  if not options.enabled then
    return nil
  end

  local threads, thread_err = pr_service.fetch_review_threads(pr_number, {
    threads_first = 100,
    comments_first = 100,
  })

  if not threads then
    notify_warn("Unable to load line comments for this PR: " .. tostring(thread_err))
    return nil
  end

  local index = pr_service.build_line_comment_index(threads, {
    show_resolved = options.show_resolved,
    show_outdated = options.show_outdated,
  })

  return {
    index = index,
    threads = threads,
    keymap = options.keymap,
    signs = options.signs,
    max_popup_width = options.max_popup_width,
    max_popup_height = options.max_popup_height,
  }
end

local function refresh_pr_sources_after_state_change(opts)
  opts = opts or {}
  local force = opts.force == true

  local source_ok, source = pcall(require, "gh-pr.neotree.source")
  if source_ok then
    if type(source.request_refresh) == "function" then
      pcall(source.request_refresh, nil, {
        force = force,
        notify_error = false,
        refresh_context = {
          mode = "cache-only",
          reason = "state-change",
          notify = false,
        },
      })
    end
  end

  local review_ok, review_source = pcall(require, "gh-pr.neotree.review_source")
  if review_ok then
    if type(review_source.render_cached_states) == "function" then
      pcall(review_source.render_cached_states)
    end
    if type(review_source.request_refresh) == "function" then
      pcall(review_source.request_refresh, nil, {
        force = force,
        notify_error = false,
        refresh_context = {
          mode = "ui-refresh",
          reason = "state-change",
          notify = false,
        },
      })
    end
  end

  local manager_ok, manager = pcall(require, "neo-tree.sources.manager")
  if manager_ok then
    pcall(manager.refresh, "gh_pr_review")
  end
end

local function normalize_diff_view_mode(mode)
  if mode == "vertical" or mode == "horizontal" or mode == "unified" then
    return mode
  end

  return "vertical"
end

local function diff_view_shortcuts()
  local diff_view = (config.get() or {}).diff_view or {}
  local resolved = diff_shortcuts_config.resolve(diff_view.shortcuts)
  return diff_shortcuts_config.expand_localleader(resolved)
end

local function current_diff_view_preferences(overrides)
  local config_defaults = ((config.get() or {}).diff_view or {})
  local persisted = type(state.get_diff_view_prefs) == "function" and state.get_diff_view_prefs() or {}
  local prefs = vim.tbl_deep_extend("force", {
    mode = normalize_diff_view_mode(config_defaults.mode),
    ignore_whitespace = config_defaults.ignore_whitespace == true,
    render_whitespace = config_defaults.render_whitespace ~= false,
    render_endlines = config_defaults.render_endlines == true,
  }, type(persisted) == "table" and persisted or {})

  prefs.mode = normalize_diff_view_mode(prefs.mode)
  prefs.ignore_whitespace = prefs.ignore_whitespace == true
  prefs.render_whitespace = prefs.render_whitespace ~= false
  prefs.render_endlines = prefs.render_endlines == true

  if type(overrides) == "table" then
    if overrides.mode ~= nil then
      prefs.mode = normalize_diff_view_mode(overrides.mode)
    end
    if type(overrides.ignore_whitespace) == "boolean" then
      prefs.ignore_whitespace = overrides.ignore_whitespace
    end
    if type(overrides.render_whitespace) == "boolean" then
      prefs.render_whitespace = overrides.render_whitespace
    end
    if type(overrides.render_endlines) == "boolean" then
      prefs.render_endlines = overrides.render_endlines
    end
  end

  return prefs
end

local function persist_diff_view_preferences(prefs)
  local sanitized = {
    mode = normalize_diff_view_mode(prefs and prefs.mode),
    ignore_whitespace = prefs and prefs.ignore_whitespace == true,
    render_whitespace = not (prefs and prefs.render_whitespace == false),
    render_endlines = prefs and prefs.render_endlines == true,
  }
  if type(state.set_diff_view_prefs) == "function" then
    state.set_diff_view_prefs(sanitized)
  end
  return sanitized
end

local function normalize_path(path)
  if type(path) ~= "string" then
    return ""
  end

  return path:gsub("\\", "/")
end

local function find_file_in_details(details, path)
  if not details or type(details.files) ~= "table" then
    return nil
  end

  local normalized_path = normalize_path(path)
  if normalized_path == "" then
    return nil
  end

  for _, file in ipairs(details.files) do
    local candidates = {
      file.path,
      file.filename,
      file.previousFilename,
      file.previous_filename,
    }
    for _, candidate in ipairs(candidates) do
      if normalize_path(candidate) == normalized_path then
        return file
      end
    end
  end

  return nil
end

local function resolve_file_in_details(details, ...)
  local count = select("#", ...)
  for index = 1, count do
    local path = select(index, ...)
    if type(path) == "string" and path ~= "" then
      local selected = find_file_in_details(details, path)
      if selected then
        return selected
      end
    end
  end

  return nil
end

local function restore_cursor_line(winid, line)
  if not is_valid_win(winid) then
    return
  end

  local bufnr = vim.api.nvim_win_get_buf(winid)
  if not is_valid_buf(bufnr) then
    return
  end

  local max_line = vim.api.nvim_buf_line_count(bufnr)
  local target = math.max(1, math.min(max_line, tonumber(line) or 1))
  pcall(vim.api.nvim_win_set_cursor, winid, { target, 0 })
end

local function resolve_current_diff_file(details, bufnr)
  local canonical_path = vim.b[bufnr].gh_pr_file_path
  local current_path = vim.b[bufnr].gh_pr_path

  local selected = resolve_file_in_details(details, canonical_path, current_path)
  if selected then
    return selected
  end

  local active_file = state.get_active_file()
  if type(active_file) == "table" then
    selected = resolve_file_in_details(
      details,
      active_file.path,
      active_file.filename,
      active_file.previousFilename,
      active_file.previous_filename
    )
    if selected then
      return selected
    end
  end

  return nil
end

local function resolve_canonical_file_path(details, path)
  local normalized = normalize_path(path)
  if normalized == "" then
    return ""
  end

  if type(details) ~= "table" or type(details.files) ~= "table" then
    return normalized
  end

  for _, file in ipairs(details.files) do
    local canonical = normalize_path(file.path or file.filename)
    local candidates = {
      file.path,
      file.filename,
      file.previousFilename,
      file.previous_filename,
    }

    for _, candidate in ipairs(candidates) do
      if normalize_path(candidate) == normalized then
        return canonical ~= "" and canonical or normalized
      end
    end
  end

  return normalized
end

local function resolve_file(file)
  if file then
    return file
  end

  local active_file = state.get_active_file()
  if active_file then
    return active_file
  end

  local path = vim.b.gh_pr_file_path or vim.b.gh_pr_path
  if type(path) == "string" and path ~= "" then
    local _, details = state.get_active_pr()
    return find_file_in_details(details, path)
  end

  return nil
end

local function resolve_pr_number(number)
  if type(number) == "number" then
    return number
  end

  if type(number) == "string" and number ~= "" then
    local parsed = tonumber(number)
    if parsed then
      return parsed
    end
  end

  if type(vim.b.gh_pr_number) == "number" then
    return vim.b.gh_pr_number
  end

  local active_pr = state.get_active_pr()
  if active_pr and active_pr.number then
    return active_pr.number
  end

  return nil
end

local function has_full_pr_details(details)
  if type(details) ~= "table" then
    return false
  end

  if type(details.files) == "table" then
    return true
  end

  if type(details.baseRepository) == "table" or type(details.headRepository) == "table" then
    return true
  end

  if type(details.body) == "string" then
    return true
  end

  return false
end

local function resolve_active_pr(number, opts)
  opts = opts or {}
  local target = resolve_pr_number(number)
  if not target then
    return nil, nil, "No active pull request selected"
  end

  local active_pr, active_details = state.get_active_pr()
  if active_pr
    and active_pr.number == target
    and active_details
    and opts.refresh ~= true
    and has_full_pr_details(active_details) then
    return active_pr, active_details, nil
  end

  local details, err = pr_service.fetch_details(target)
  if not details then
    return nil, nil, err
  end

  state.set_active_pr(details, details)
  return details, details, nil
end

local IMAGE_FALLBACK_ACTION_LABELS = {
  metadata = "Render metadata diff in buffer",
  open_local_current = "Open current image locally",
  open_local_both = "Open base + modified images locally",
  open_github = "Open GitHub PR image comparison",
}

local IMAGE_FALLBACK_ACTION_ORDER = {
  "open_local_current",
  "open_local_both",
  "open_github",
  "metadata",
}

local image_fallback_menu_state = nil

local function is_valid_image_action(action)
  return action == "metadata" or action == "open_local_current" or action == "open_local_both" or action == "open_github"
end

local function normalize_image_action(action, fallback)
  local value = type(action) == "string" and action:lower() or ""
  if is_valid_image_action(value) then
    return value
  end
  local default_value = type(fallback) == "string" and fallback:lower() or "metadata"
  if is_valid_image_action(default_value) then
    return default_value
  end
  return "metadata"
end

local function image_action_label(action)
  local normalized = normalize_image_action(action, "metadata")
  return IMAGE_FALLBACK_ACTION_LABELS[normalized] or normalized
end

local function image_diff_options()
  local diff_view = (config.get() or {}).diff_view or {}
  local images = type(diff_view.images) == "table" and diff_view.images or {}
  local external_command = {}
  for _, token in ipairs(type(images.metadata_external_command) == "table" and images.metadata_external_command or {}) do
    if type(token) == "string" and token ~= "" then
      external_command[#external_command + 1] = token
    end
  end
  if vim.tbl_isempty(external_command) then
    external_command = { "magick", "identify", "-format", "%w %h", "{file}" }
  end

  return {
    fallback_mode = type(images.fallback_mode) == "string" and images.fallback_mode:lower() or "menu",
    fallback_default_action = normalize_image_action(images.fallback_default_action, "metadata"),
    fallback_menu_keymap = type(images.fallback_menu_keymap) == "string" and images.fallback_menu_keymap or "gf",
    fallback_open_local = type(images.fallback_open_local) == "string" and images.fallback_open_local:lower() or "system",
    fallback_github_target = type(images.fallback_github_target) == "string"
        and images.fallback_github_target:lower()
      or "pr_files",
    metadata_resolution_strategy = type(images.metadata_resolution_strategy) == "string"
        and images.metadata_resolution_strategy:lower()
      or "hybrid",
    metadata_external_command = external_command,
  }
end

local function resolve_image_default_action(images_cfg)
  local fallback = type(images_cfg) == "table" and images_cfg.fallback_default_action or "metadata"
  local action = normalize_image_action(fallback, "metadata")
  if type(state.get_image_prefs) == "function" then
    local prefs = state.get_image_prefs()
    if type(prefs) == "table" then
      action = normalize_image_action(prefs.fallback_default_action, action)
    end
  end
  return action
end

local function persist_image_default_action(action)
  local normalized = normalize_image_action(action, "metadata")
  if type(state.update_image_pref) == "function" then
    state.update_image_pref("fallback_default_action", normalized)
    return true
  end
  if type(state.set_image_prefs) == "function" then
    local current = type(state.get_image_prefs) == "function" and state.get_image_prefs() or {}
    current.fallback_default_action = normalized
    state.set_image_prefs(current)
    return true
  end
  return false
end

local function file_readable(path)
  return type(path) == "string" and path ~= "" and vim.fn.filereadable(path) == 1
end

local function trim_trailing_slash(url)
  if type(url) ~= "string" then
    return ""
  end
  return url:gsub("/+$", "")
end

local function current_image_side(ctx)
  local side = type(ctx.side) == "string" and ctx.side or ""
  if side == "base" or side == "head" then
    return side
  end
  if ctx.status == "removed" then
    return "base"
  end
  return "head"
end

local function side_present_for_status(status, side)
  if status == "added" and side == "base" then
    return false
  end
  if status == "removed" and side == "head" then
    return false
  end
  return true
end

local function image_path_for_side(ctx, side)
  local side_path = ""
  if side == "base" then
    side_path = normalize_path(ctx.base_path or "")
  elseif side == "head" then
    side_path = normalize_path(ctx.head_path or "")
  end
  if side_path ~= "" then
    return side_path
  end
  return normalize_path(ctx.file_path or ctx.path or "")
end

local function parse_repo_full_name(full_name)
  if type(full_name) ~= "string" or full_name == "" then
    return nil
  end
  local owner, name = full_name:match("^([^/]+)/(.+)$")
  if type(owner) ~= "string" or owner == "" or type(name) ~= "string" or name == "" then
    return nil
  end
  return {
    owner = owner,
    name = name,
    full_name = owner .. "/" .. name,
  }
end

local function extract_repo_info(repo)
  if type(repo) ~= "table" then
    return nil
  end

  local parsed_owner, parsed_name
  if type(repo.nameWithOwner) == "string" then
    parsed_owner, parsed_name = repo.nameWithOwner:match("^([^/]+)/(.+)$")
  end

  local owner
  if type(repo.owner) == "table" then
    owner = repo.owner.login or repo.owner.name
  else
    owner = repo.owner
  end
  owner = owner or parsed_owner
  local name = repo.name or parsed_name
  if type(owner) ~= "string" or owner == "" or type(name) ~= "string" or name == "" then
    return nil
  end

  return {
    owner = owner,
    name = name,
    full_name = repo.nameWithOwner or (owner .. "/" .. name),
  }
end

local function resolve_side_repository(details, side, fallback_full_name)
  local base_repo = extract_repo_info(type(details) == "table" and details.baseRepository or nil)
  local head_repo = extract_repo_info(type(details) == "table" and details.headRepository or nil) or base_repo
  if side == "base" then
    return base_repo or head_repo or parse_repo_full_name(fallback_full_name)
  end
  return head_repo or base_repo or parse_repo_full_name(fallback_full_name)
end

local function resolve_image_buffer_context(bufnr)
  bufnr = type(bufnr) == "number" and bufnr or vim.api.nvim_get_current_buf()
  if not is_valid_buf(bufnr) then
    return nil, "Invalid buffer"
  end
  if vim.b[bufnr].gh_pr_is_image ~= true then
    return nil, "Current buffer is not an image diff buffer"
  end

  local number = tonumber(vim.b[bufnr].gh_pr_number)
  if not number then
    return nil, "Unable to resolve pull request number for image buffer"
  end

  return {
    bufnr = bufnr,
    number = number,
    repo = type(vim.b[bufnr].gh_pr_repo) == "string" and vim.b[bufnr].gh_pr_repo or "",
    kind = type(vim.b[bufnr].gh_pr_file_kind) == "string" and vim.b[bufnr].gh_pr_file_kind or "",
    file_path = normalize_path(vim.b[bufnr].gh_pr_file_path or ""),
    path = normalize_path(vim.b[bufnr].gh_pr_path or ""),
    side = type(vim.b[bufnr].gh_pr_image_side) == "string" and vim.b[bufnr].gh_pr_image_side or "",
    status = type(vim.b[bufnr].gh_pr_image_status) == "string" and vim.b[bufnr].gh_pr_image_status:lower() or "",
    reason = type(vim.b[bufnr].gh_pr_image_reason) == "string" and vim.b[bufnr].gh_pr_image_reason or "",
    pr_url = trim_trailing_slash(vim.b[bufnr].gh_pr_pr_url),
    pr_files_url = trim_trailing_slash(vim.b[bufnr].gh_pr_pr_files_url),
    base_path = normalize_path(vim.b[bufnr].gh_pr_image_base_path or ""),
    head_path = normalize_path(vim.b[bufnr].gh_pr_image_head_path or ""),
    cache_path = type(vim.b[bufnr].gh_pr_image_cache_path) == "string" and vim.b[bufnr].gh_pr_image_cache_path or "",
    size = tonumber(vim.b[bufnr].gh_pr_image_size) or 0,
    sha = type(vim.b[bufnr].gh_pr_image_sha) == "string" and vim.b[bufnr].gh_pr_image_sha or "",
    ext = type(vim.b[bufnr].gh_pr_image_ext) == "string" and vim.b[bufnr].gh_pr_image_ext:lower() or "",
  }, nil
end

local function find_cached_image_asset(ctx, side)
  if side == ctx.side and file_readable(ctx.cache_path) then
    return {
      side = side,
      path = image_path_for_side(ctx, side),
      cache_path = ctx.cache_path,
      size = ctx.size,
      sha = ctx.sha,
      ext = ctx.ext,
    }
  end

  local target_path = normalize_path(ctx.file_path ~= "" and ctx.file_path or ctx.path)
  for _, candidate in ipairs(vim.api.nvim_list_bufs()) do
    if candidate ~= ctx.bufnr and is_valid_buf(candidate) and vim.b[candidate].gh_pr_is_image == true then
      local candidate_number = tonumber(vim.b[candidate].gh_pr_number)
      local candidate_side = type(vim.b[candidate].gh_pr_image_side) == "string"
          and vim.b[candidate].gh_pr_image_side
        or (type(vim.b[candidate].gh_pr_file_kind) == "string" and vim.b[candidate].gh_pr_file_kind or "")
      local candidate_path = normalize_path(vim.b[candidate].gh_pr_file_path or vim.b[candidate].gh_pr_path or "")
      local same_number = candidate_number == ctx.number
      local same_path = target_path == "" or candidate_path == "" or candidate_path == target_path
      local cache_path = type(vim.b[candidate].gh_pr_image_cache_path) == "string" and vim.b[candidate].gh_pr_image_cache_path or ""
      if same_number and same_path and candidate_side == side and file_readable(cache_path) then
        return {
          side = side,
          path = normalize_path(side == "base" and (vim.b[candidate].gh_pr_image_base_path or vim.b[candidate].gh_pr_path or "")
            or (vim.b[candidate].gh_pr_image_head_path or vim.b[candidate].gh_pr_path or "")),
          cache_path = cache_path,
          size = tonumber(vim.b[candidate].gh_pr_image_size) or 0,
          sha = type(vim.b[candidate].gh_pr_image_sha) == "string" and vim.b[candidate].gh_pr_image_sha or "",
          ext = type(vim.b[candidate].gh_pr_image_ext) == "string" and vim.b[candidate].gh_pr_image_ext:lower() or "",
        }
      end
    end
  end

  return nil
end

local function fetch_and_cache_image_asset(details, ctx, side, images_cfg)
  local side_path = image_path_for_side(ctx, side)
  if side_path == "" then
    return nil, string.format("Missing %s image path", side)
  end

  local side_ref = side == "base" and details.baseRefName or details.headRefName
  if type(side_ref) ~= "string" or side_ref == "" then
    return nil, string.format("Missing %s ref for pull request", side)
  end

  local repository = resolve_side_repository(details, side, ctx.repo)
  if not repository then
    return nil, string.format("Unable to resolve %s repository", side)
  end

  local api = string.format(
    "repos/%s/%s/contents/%s?ref=%s",
    repository.owner,
    repository.name,
    encode_path(side_path),
    url_encode(side_ref)
  )
  local payload, payload_err = gh.run_json({ "api", api })
  if not payload then
    return nil, payload_err
  end

  local encoding = type(payload.encoding) == "string" and payload.encoding or ""
  local content = type(payload.content) == "string" and payload.content or ""
  if encoding ~= "base64" or content == "" then
    return nil, string.format("Unable to decode %s image bytes from GitHub contents API", side)
  end

  local bytes = decode_base64(content)
  if bytes == "" then
    return nil, string.format("Unable to decode %s image bytes from base64 payload", side)
  end

  local size = tonumber(payload.size) or #bytes
  local sha = type(payload.sha) == "string" and payload.sha or ""
  local ext = normalize_path(side_path):match("%.([^.]+)$")
  ext = type(ext) == "string" and ext:lower() or ""

  local cache_path, cache_err = image_renderer.ensure_cache({
    repository = repository.full_name,
    pr_number = ctx.number,
    side = side,
    path = side_path,
    sha = sha,
    size = size,
    bytes = bytes,
    images = images_cfg,
  })
  if not cache_path then
    return nil, cache_err
  end

  return {
    side = side,
    path = side_path,
    cache_path = cache_path,
    size = size,
    sha = sha,
    ext = ext,
  }, nil
end

local function ensure_image_side_asset(ctx, side, images_cfg)
  if not side_present_for_status(ctx.status, side) then
    return {
      side = side,
      present = false,
      path = image_path_for_side(ctx, side),
    }, nil
  end

  local cached = find_cached_image_asset(ctx, side)
  if cached then
    cached.present = true
    return cached, nil
  end

  local _, details, details_err = resolve_active_pr(ctx.number, { refresh = false })
  if not details then
    return nil, details_err
  end

  local fetched, fetch_err = fetch_and_cache_image_asset(details, ctx, side, images_cfg)
  if not fetched then
    return nil, fetch_err
  end

  fetched.present = true
  if side == ctx.side and is_valid_buf(ctx.bufnr) then
    vim.b[ctx.bufnr].gh_pr_image_cache_path = fetched.cache_path
    vim.b[ctx.bufnr].gh_pr_image_size = tonumber(fetched.size) or 0
    vim.b[ctx.bufnr].gh_pr_image_sha = fetched.sha
    vim.b[ctx.bufnr].gh_pr_image_ext = fetched.ext
  end
  return fetched, nil
end

local function ensure_open_target(target, label)
  if type(target) ~= "string" or target == "" then
    return false, string.format("Missing %s target", label)
  end

  local is_url = target:match("^https?://") ~= nil
  local gh_err = nil
  if is_url and type(pr_service.open_url_in_browser) == "function" then
    local ok_gh, browser_err = pr_service.open_url_in_browser(target)
    if ok_gh then
      return true, nil
    end
    gh_err = browser_err
  end

  local ui_err = nil
  if vim.ui and type(vim.ui.open) == "function" then
    local ok, open_result, open_err = pcall(vim.ui.open, target)
    if ok then
      if open_result ~= false and not (open_result == nil and type(open_err) == "string" and open_err ~= "") then
        return true, nil
      end
      ui_err = type(open_err) == "string" and open_err ~= "" and open_err or "vim.ui.open returned without opening target"
    else
      ui_err = tostring(open_result)
    end
  else
    ui_err = "vim.ui.open is unavailable in this Neovim build"
  end

  local is_windows = vim.fn.has("win32") == 1 or vim.fn.has("win64") == 1
  local is_mac = vim.fn.has("mac") == 1 or vim.fn.has("macunix") == 1
  local commands = {}
  if is_windows then
    local escaped_target = target:gsub('"', '""')
    local quoted_target = '"' .. escaped_target .. '"'
    commands = {
      { "cmd.exe", "/c", "start", "", quoted_target },
      { "rundll32", "url.dll,FileProtocolHandler", target },
      { "explorer.exe", target },
    }
  elseif is_mac then
    commands = {
      { "open", target },
    }
  else
    commands = {
      { "xdg-open", target },
    }
  end

  for _, command in ipairs(commands) do
    local executable = command[1]
    if type(executable) == "string" and executable ~= "" and vim.fn.executable(executable) == 1 then
      local ok_job, jobid = pcall(vim.fn.jobstart, command, {
        detach = true,
      })
      if ok_job and type(jobid) == "number" and jobid > 0 then
        return true, nil
      end
    end
  end

  local errors = {}
  if type(gh_err) == "string" and gh_err ~= "" then
    errors[#errors + 1] = "gh browse failed: " .. gh_err
  end
  if type(ui_err) == "string" and ui_err ~= "" then
    errors[#errors + 1] = "vim.ui.open failed: " .. ui_err
  end
  if vim.tbl_isempty(errors) then
    return false, "Unable to open target using system opener"
  end
  return false, table.concat(errors, " | ")
end

local function joinpath(...)
  if vim.fs and vim.fs.joinpath then
    return vim.fs.joinpath(...)
  end
  local separator = package.config:sub(1, 1)
  return table.concat({ ... }, separator)
end

local function url_decode(value)
  if type(value) ~= "string" then
    return ""
  end
  return (value:gsub("%%(%x%x)", function(hex)
    return string.char(tonumber(hex, 16))
  end))
end

local function sanitize_filename(value)
  local name = type(value) == "string" and value or ""
  name = url_decode(name)
  name = name:gsub("[<>:\"/\\|%?%*]", "_")
  name = name:gsub("[%c]", "_")
  name = name:gsub("^%s+", "")
  name = name:gsub("%s+$", "")
  if name == "" then
    name = "attachment"
  end
  if #name > 120 then
    local ext = name:match("(%.[^.]+)$")
    if type(ext) == "string" and ext ~= "" and #ext < 40 then
      local head = name:sub(1, 120 - #ext)
      name = head .. ext
    else
      name = name:sub(1, 120)
    end
  end
  return name
end

local function extension_from_name(name)
  local ext = type(name) == "string" and name:match("%.([^.]+)$") or nil
  if type(ext) ~= "string" then
    return ""
  end
  return ext:lower()
end

local function filename_from_url(url)
  if type(url) ~= "string" then
    return ""
  end
  local path = url:match("^https?://[^/]+(/[^?#]*)") or ""
  local name = path:match("([^/]+)$") or ""
  return sanitize_filename(name)
end

local function list_to_set(list)
  local set = {}
  for _, value in ipairs(type(list) == "table" and list or {}) do
    if type(value) == "string" and value ~= "" then
      set[value] = true
    end
  end
  return set
end

local function normalize_extension_list(values, fallback)
  local source = type(values) == "table" and values or fallback
  local normalized = {}
  local seen = {}
  for _, value in ipairs(source) do
    if type(value) == "string" and value ~= "" then
      local ext = value:lower():gsub("^%.+", "")
      if ext ~= "" and not seen[ext] then
        seen[ext] = true
        normalized[#normalized + 1] = ext
      end
    end
  end
  if vim.tbl_isempty(normalized) then
    return vim.deepcopy(fallback)
  end
  return normalized
end

local function overview_markdown_link_preview_options()
  local markdown = (((config.get() or {}).overview or {}).markdown or {})
  local renderable = normalize_extension_list(
    markdown.link_preview_renderable_extensions,
    { "txt", "md", "markdown", "json", "yaml", "yml", "csv", "log" }
  )
  local disallowed = normalize_extension_list(markdown.link_preview_disallowed_extensions, { "zip" })

  local max_bytes = positive_integer(markdown.link_preview_max_bytes, 10485760)
  if max_bytes < 1024 then
    max_bytes = 10485760
  end

  return {
    keymap = type(markdown.link_preview_keymap) == "string" and markdown.link_preview_keymap or "gp",
    max_bytes = max_bytes,
    open_local = markdown.link_preview_open_local == "system" and "system" or "system",
    renderable_extensions = renderable,
    disallowed_extensions = disallowed,
    renderable_set = list_to_set(renderable),
    disallowed_set = list_to_set(disallowed),
  }
end

local function build_overview_link_temp_path(filename)
  local root = joinpath(vim.fn.stdpath("cache"), "gh-pr", "overview-links")
  local created = vim.fn.mkdir(root, "p")
  if created == 0 and vim.fn.isdirectory(root) ~= 1 then
    return nil, "Unable to prepare overview link preview cache directory"
  end

  local suffix = string.format("%d-%d", os.time(), math.floor((uv.hrtime and uv.hrtime() or 0) % 100000))
  return joinpath(root, suffix .. "-" .. sanitize_filename(filename)), nil
end

local function read_file_bytes(path)
  local fd, open_err = uv.fs_open(path, "r", 438)
  if not fd then
    return nil, tostring(open_err or "Unable to open downloaded file")
  end

  local stat, stat_err = uv.fs_fstat(fd)
  if not stat then
    uv.fs_close(fd)
    return nil, tostring(stat_err or "Unable to inspect downloaded file")
  end

  local size = tonumber(stat.size) or 0
  local data = size > 0 and uv.fs_read(fd, size, 0) or ""
  uv.fs_close(fd)
  if type(data) ~= "string" then
    return nil, "Unable to read downloaded file bytes"
  end

  return data, nil
end

local function is_probably_binary(content)
  if type(content) ~= "string" or content == "" then
    return false
  end
  if content:find("\0", 1, true) then
    return true
  end

  local sample = content:sub(1, 4096)
  local invalid = 0
  for index = 1, #sample do
    local byte = sample:byte(index)
    if byte < 9 or (byte > 13 and byte < 32) then
      invalid = invalid + 1
    end
  end

  return invalid > 0 and (invalid / #sample) > 0.12
end

local function filetype_for_extension(ext)
  if ext == "md" or ext == "markdown" then
    return "markdown"
  end
  if ext == "json" then
    return "json"
  end
  if ext == "yaml" or ext == "yml" then
    return "yaml"
  end
  if ext == "csv" then
    return "csv"
  end
  if ext == "log" or ext == "txt" then
    return "text"
  end
  return "text"
end

local function looks_like_json(content)
  if type(content) ~= "string" then
    return false
  end
  local trimmed = vim.trim(content)
  if trimmed == "" then
    return false
  end

  local first = trimmed:sub(1, 1)
  local last = trimmed:sub(-1)
  if not ((first == "{" and last == "}") or (first == "[" and last == "]")) then
    return false
  end

  local ok, _ = pcall(vim.json.decode, trimmed)
  return ok
end

local function detect_preview_filetype(filename, content)
  if vim.filetype and type(vim.filetype.match) == "function" then
    local ok, detected = pcall(vim.filetype.match, {
      filename = filename,
    })
    if ok and type(detected) == "string" and detected ~= "" then
      return detected
    end
  end

  local ext = extension_from_name(filename)
  local fallback = filetype_for_extension(ext)
  if fallback == "text" and looks_like_json(content) then
    return "json"
  end
  return fallback
end

local function open_overview_link_preview_window(opts)
  local filename = sanitize_filename(type(opts.filename) == "string" and opts.filename or "attachment")
  local content = type(opts.content) == "string" and opts.content or ""
  content = content:gsub("\r\n", "\n"):gsub("\r", "\n")
  local preview_filetype = detect_preview_filetype(filename, content)
  local lines = vim.split(content, "\n", { plain = true })
  if vim.tbl_isempty(lines) then
    lines = { "" }
  end

  local bufnr = vim.api.nvim_create_buf(false, true)
  local name = string.format("ghpr://overview/link-preview/%d/%s", tonumber(os.time()) or 0, filename)
  pcall(vim.api.nvim_buf_set_name, bufnr, name)
  vim.api.nvim_set_option_value("buftype", "nofile", { buf = bufnr })
  vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = bufnr })
  vim.api.nvim_set_option_value("swapfile", false, { buf = bufnr })
  vim.api.nvim_set_option_value("modifiable", true, { buf = bufnr })
  vim.api.nvim_set_option_value("readonly", false, { buf = bufnr })
  vim.bo[bufnr].filetype = preview_filetype
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.api.nvim_set_option_value("modifiable", false, { buf = bufnr })
  vim.api.nvim_set_option_value("readonly", true, { buf = bufnr })

  local max_width = math.max(20, vim.o.columns - 2)
  local max_height = math.max(6, vim.o.lines - vim.o.cmdheight - 2)
  local width = math.min(math.max(60, vim.o.columns - 4), max_width)
  local height = math.min(math.max(10, vim.o.lines - vim.o.cmdheight - 4), max_height)
  local row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1)
  local col = math.max(0, math.floor((vim.o.columns - width) / 2))

  local ok_win, winid = pcall(vim.api.nvim_open_win, bufnr, true, {
    relative = "editor",
    row = row,
    col = col,
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    title = "PR Link Preview",
    title_pos = "center",
    noautocmd = true,
  })
  if not ok_win or not is_valid_win(winid) then
    return false, "Unable to open preview window"
  end

  sanitize_modal_window(winid)
  vim.api.nvim_set_option_value("number", true, { win = winid })
  vim.api.nvim_set_option_value("relativenumber", false, { win = winid })
  vim.api.nvim_set_option_value("signcolumn", "no", { win = winid })
  vim.api.nvim_set_option_value("wrap", true, { win = winid })
  vim.api.nvim_set_option_value("linebreak", true, { win = winid })
  vim.api.nvim_set_option_value("cursorline", true, { win = winid })
  if type(preview_filetype) == "string" and preview_filetype ~= "" and preview_filetype ~= "text" then
    pcall(vim.api.nvim_set_option_value, "syntax", preview_filetype, { win = winid })
  end

  local key_opts = { buffer = bufnr, silent = true, nowait = true }
  vim.keymap.set("n", "q", function()
    if is_valid_win(winid) then
      pcall(vim.api.nvim_win_close, winid, true)
    end
  end, vim.tbl_extend("force", key_opts, { desc = "Close PR link preview" }))
  vim.keymap.set("n", "<Esc>", function()
    if is_valid_win(winid) then
      pcall(vim.api.nvim_win_close, winid, true)
    end
  end, vim.tbl_extend("force", key_opts, { desc = "Close PR link preview" }))

  return true, nil
end

local function select_open_local(prompt, callback, confirm_item)
  local function normalize_confirm_label(value)
    if type(value) ~= "string" then
      return ""
    end
    return vim.trim(value):lower()
  end

  local function did_confirm_select_choice(choice, confirm_label)
    local normalized_confirm = normalize_confirm_label(confirm_label)
    if normalized_confirm == "" then
      return false
    end

    if type(choice) == "string" then
      return normalize_confirm_label(choice) == normalized_confirm
    end

    if type(choice) == "number" then
      return choice == 1
    end

    if type(choice) == "table" then
      local candidate_keys = { "value", "text", "label", "name", "id", 1 }
      for _, key in ipairs(candidate_keys) do
        local value = choice[key]
        if type(value) == "string" and normalize_confirm_label(value) == normalized_confirm then
          return true
        end
      end

      local index = tonumber(choice.idx) or tonumber(choice.index)
      if index == 1 then
        return true
      end
    end

    return false
  end

  callback = callback or function() end
  local confirm_label = type(confirm_item) == "string" and confirm_item ~= "" and confirm_item or "open local"
  if vim.ui and type(vim.ui.select) == "function" then
    vim.ui.select({ confirm_label, "cancel" }, {
      prompt = prompt,
      format_item = function(item)
        return item
      end,
    }, function(choice)
      vim.schedule(function()
        callback(did_confirm_select_choice(choice, confirm_label))
      end)
    end)
    return
  end

  local choice = vim.fn.confirm(prompt, "&" .. confirm_label .. "\n&Cancel", 2)
  callback(choice == 1)
end

local gh_auth_token_cache = {
  attempted = false,
  token = nil,
}

local function url_host(url)
  if type(url) ~= "string" then
    return ""
  end
  local host = url:match("^https?://([^/%?#]+)") or ""
  return host:lower()
end

local function is_github_attachment_url(url)
  local host = url_host(url)
  local path = type(url) == "string" and (url:match("^https?://[^/]+(/[^?#]*)") or "") or ""

  if host == "github.com" then
    return path:match("^/user%-attachments/files/") ~= nil
      or path:match("^/user%-attachments/assets/") ~= nil
  end

  if host == "objects.githubusercontent.com" then
    return true
  end

  if host == "user-images.githubusercontent.com" or host == "private-user-images.githubusercontent.com" then
    return true
  end

  if host:match("%.githubusercontent%.com$") ~= nil then
    return path:match("/user%-attachments/") ~= nil
      or path:match("github%-production%-user%-asset") ~= nil
      or path:match("github%-production%-release%-asset") ~= nil
  end

  return false
end

local function resolve_gh_auth_token()
  if gh_auth_token_cache.attempted then
    return gh_auth_token_cache.token
  end

  gh_auth_token_cache.attempted = true
  local output, err = gh.run_command({ "gh", "auth", "token" })
  if not output then
    notify_warn("Unable to resolve gh auth token for link download: " .. tostring(err))
    gh_auth_token_cache.token = nil
    return nil
  end

  local token = vim.trim(output)
  if token == "" then
    gh_auth_token_cache.token = nil
    return nil
  end

  gh_auth_token_cache.token = token
  return token
end

local function downloader_command(url, output_path)
  local auth_token = nil
  if is_github_attachment_url(url) then
    auth_token = resolve_gh_auth_token()
  end

  if vim.fn.executable("curl") == 1 then
    local command = {
      "curl",
      "-L",
      "--fail",
      "--silent",
      "--show-error",
    }
    if type(auth_token) == "string" and auth_token ~= "" then
      command[#command + 1] = "--header"
      command[#command + 1] = "Authorization: Bearer " .. auth_token
      command[#command + 1] = "--header"
      command[#command + 1] = "Accept: application/octet-stream"
    end
    command[#command + 1] = "--output"
    command[#command + 1] = output_path
    command[#command + 1] = url
    return command, nil
  end

  if vim.fn.executable("wget") == 1 then
    local command = { "wget", "-q" }
    if type(auth_token) == "string" and auth_token ~= "" then
      command[#command + 1] = "--header=Authorization: Bearer " .. auth_token
      command[#command + 1] = "--header=Accept: application/octet-stream"
    end
    command[#command + 1] = "-O"
    command[#command + 1] = output_path
    command[#command + 1] = url
    return command, nil
  end

  local is_windows = vim.fn.has("win32") == 1 or vim.fn.has("win64") == 1
  if is_windows and vim.fn.executable("pwsh") == 1 then
    return {
      "pwsh",
      "-NoProfile",
      "-NonInteractive",
      "-Command",
      "$ProgressPreference='SilentlyContinue'; "
          .. "$headers=@{}; "
          .. "if ($args.Count -ge 3 -and $args[2] -ne '') { "
          .. "$headers['Authorization']='Bearer ' + $args[2]; "
          .. "$headers['Accept']='application/octet-stream' "
          .. "}; "
          .. "Invoke-WebRequest -UseBasicParsing -Headers $headers -Uri $args[0] -OutFile $args[1]",
      url,
      output_path,
      type(auth_token) == "string" and auth_token or "",
    }, nil
  end
  if is_windows and vim.fn.executable("powershell") == 1 then
    return {
      "powershell",
      "-NoProfile",
      "-NonInteractive",
      "-Command",
      "$ProgressPreference='SilentlyContinue'; "
          .. "$headers=@{}; "
          .. "if ($args.Count -ge 3 -and $args[2] -ne '') { "
          .. "$headers['Authorization']='Bearer ' + $args[2]; "
          .. "$headers['Accept']='application/octet-stream' "
          .. "}; "
          .. "Invoke-WebRequest -UseBasicParsing -Headers $headers -Uri $args[0] -OutFile $args[1]",
      url,
      output_path,
      type(auth_token) == "string" and auth_token or "",
    }, nil
  end

  return nil, "No supported downloader found (curl/wget/powershell)"
end

local function download_link_to_path_async(url, output_path, callback)
  callback = callback or function() end
  local command, cmd_err = downloader_command(url, output_path)
  if not command then
    callback(nil, cmd_err)
    return
  end

  gh.run_command_async(command, nil, function(_, run_err)
    if run_err then
      callback(nil, run_err)
      return
    end

    if vim.fn.filereadable(output_path) ~= 1 then
      callback(nil, "Downloaded file is unavailable on disk")
      return
    end

    callback(output_path, nil)
  end)
end

local function prompt_open_downloaded_file(path, filename, reason)
  local prompt = string.format(
    "Preview unavailable for '%s' (%s). Open downloaded file locally?",
    filename,
    reason
  )
  select_open_local(prompt, function(should_open)
    if not should_open then
      return
    end
    local ok_open, open_err = ensure_open_target(path, "downloaded file")
    if not ok_open then
      notify_error("Unable to open downloaded file: " .. tostring(open_err))
    end
  end)
end

local function prompt_download_and_open_local(url, filename, reason)
  local prompt = string.format(
    "Cannot preview '%s' (%s). Download and open locally?",
    filename,
    reason
  )
  select_open_local(prompt, function(should_open)
    if not should_open then
      return
    end

    local target_path, target_err = build_overview_link_temp_path(filename)
    if not target_path then
      notify_error(target_err)
      return
    end

    notify_info("Downloading link attachment to open locally...")
    download_link_to_path_async(url, target_path, function(downloaded_path, download_err)
      if not downloaded_path then
        notify_error("Unable to download link: " .. tostring(download_err))
        return
      end
      local ok_open, open_err = ensure_open_target(downloaded_path, "downloaded file")
      if not ok_open then
        notify_error("Unable to open downloaded file: " .. tostring(open_err))
      end
    end)
  end)
end

function M.overview_preview_markdown_link(action)
  local url = type(action) == "table" and type(action.url) == "string" and vim.trim(action.url) or ""
  if url == "" then
    return notify_error("Missing markdown link URL")
  end
  if not url:match("^https?://") then
    return notify_warn("Only http/https links can be previewed")
  end
  if not is_github_attachment_url(url) then
    local prompt = string.format(
      "This markdown link is not a GitHub attachment.\nOpen in browser?\n%s",
      url
    )
    select_open_local(prompt, function(should_open)
      if not should_open then
        return
      end

      local ok_open, open_err = ensure_open_target(url, "URL")
      if not ok_open then
        notify_error("Unable to open URL: " .. tostring(open_err))
      end
    end, "open link")
    return
  end

  local options = overview_markdown_link_preview_options()
  local action_label = type(action) == "table" and type(action.label) == "string" and action.label or ""
  local filename = filename_from_url(url)
  if filename == "" and action_label ~= "" then
    filename = sanitize_filename(action_label)
  end
  if filename == "" then
    filename = "attachment"
  end

  local extension = extension_from_name(filename)
  if extension ~= "" and options.disallowed_set[extension] then
    prompt_download_and_open_local(url, filename, "extension ." .. extension .. " is not previewable")
    return
  end
  if extension ~= "" and not options.renderable_set[extension] then
    prompt_download_and_open_local(url, filename, "extension ." .. extension .. " is not configured as renderable")
    return
  end

  local target_path, target_err = build_overview_link_temp_path(filename)
  if not target_path then
    return notify_error(target_err)
  end

  notify_info("Downloading GitHub attachment for preview...")
  download_link_to_path_async(url, target_path, function(downloaded_path, download_err)
    if not downloaded_path then
      notify_error("Unable to download link: " .. tostring(download_err))
      return
    end

    local stat = uv.fs_stat(downloaded_path)
    local size = tonumber(stat and stat.size) or 0
    if size > options.max_bytes then
      prompt_open_downloaded_file(
        downloaded_path,
        filename,
        string.format("file exceeds preview limit (%d > %d bytes)", size, options.max_bytes)
      )
      return
    end

    local bytes, read_err = read_file_bytes(downloaded_path)
    if not bytes then
      notify_error("Unable to inspect downloaded file: " .. tostring(read_err))
      return
    end

    if is_probably_binary(bytes) then
      prompt_open_downloaded_file(downloaded_path, filename, "binary content is not renderable")
      return
    end

    local ok_preview, preview_err = open_overview_link_preview_window({
      filename = filename,
      content = bytes,
    })
    if not ok_preview then
      notify_error("Unable to render link preview: " .. tostring(preview_err))
    end
  end)
end

local function resolve_image_compare_url(ctx, images_cfg)
  local pr_url = trim_trailing_slash(ctx.pr_url)
  local pr_files_url = trim_trailing_slash(ctx.pr_files_url)
  if pr_url == "" and type(ctx.repo) == "string" and ctx.repo ~= "" then
    pr_url = string.format("https://github.com/%s/pull/%d", ctx.repo, ctx.number)
  end
  if pr_files_url == "" and pr_url ~= "" then
    pr_files_url = pr_url:find("/files$", 1, true) and pr_url or (pr_url .. "/files")
  end

  if (type(images_cfg) == "table" and images_cfg.fallback_github_target == "pr") or pr_files_url == "" then
    return pr_url
  end

  local base = pr_files_url
  local anchor_path = normalize_path(ctx.file_path ~= "" and ctx.file_path or ctx.path)
  if anchor_path ~= "" and vim.fn.exists("*sha256") == 1 then
    local ok_hash, hash = pcall(vim.fn.sha256, anchor_path)
    if ok_hash and type(hash) == "string" and hash ~= "" then
      return base .. "#diff-" .. hash
    end
  end
  return base
end

local function write_readonly_buffer_lines(bufnr, lines, filetype)
  if not is_valid_buf(bufnr) then
    return false, "Invalid buffer"
  end

  local content = type(lines) == "table" and lines or { tostring(lines or "") }
  local view = vim.fn.winsaveview()
  pcall(vim.api.nvim_set_option_value, "readonly", false, { buf = bufnr })
  pcall(vim.api.nvim_set_option_value, "modifiable", true, { buf = bufnr })
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, content)
  if type(filetype) == "string" and filetype ~= "" then
    pcall(vim.api.nvim_set_option_value, "filetype", filetype, { buf = bufnr })
  end
  pcall(vim.api.nvim_set_option_value, "modifiable", false, { buf = bufnr })
  pcall(vim.api.nvim_set_option_value, "readonly", true, { buf = bufnr })
  pcall(vim.fn.winrestview, view)
  return true, nil
end

local function collect_image_metadata_for_side(ctx, side, images_cfg)
  local asset, asset_err = ensure_image_side_asset(ctx, side, images_cfg)
  if not asset then
    return {
      side = side,
      present = side_present_for_status(ctx.status, side),
      path = image_path_for_side(ctx, side),
      error = tostring(asset_err or "Unable to load image asset"),
    }
  end
  if asset.present == false then
    return {
      side = side,
      present = false,
      path = asset.path,
    }
  end
  if not file_readable(asset.cache_path) then
    return {
      side = side,
      present = true,
      path = asset.path,
      error = "Cached image file is unavailable locally",
    }
  end

  local metadata = image_metadata.collect({
    path = asset.cache_path,
    ext = asset.ext,
    sha = asset.sha,
    size_bytes = asset.size,
    strategy = images_cfg.metadata_resolution_strategy,
    external_command = images_cfg.metadata_external_command,
  })
  metadata.side = side
  metadata.present = true
  metadata.path = asset.path
  metadata.local_path = asset.cache_path
  metadata.sha = type(metadata.sha) == "string" and metadata.sha or (asset.sha or "")
  metadata.size_bytes = tonumber(metadata.size_bytes) or tonumber(asset.size) or 0
  metadata.size_human = type(metadata.size_human) == "string" and metadata.size_human ~= ""
      and metadata.size_human
    or image_metadata.format_bytes(metadata.size_bytes)
  return metadata
end

local function append_side_metadata_lines(lines, prefix, label, entry)
  if not entry.present then
    lines[#lines + 1] = string.format("%s %s: (not present in this revision)", prefix, label)
    return
  end
  if type(entry.error) == "string" and entry.error ~= "" then
    lines[#lines + 1] = string.format("%s %s error: %s", prefix, label, entry.error)
    return
  end

  local sha = type(entry.sha) == "string" and entry.sha ~= "" and entry.sha:sub(1, 12) or "-"
  local bytes = tonumber(entry.size_bytes) or 0
  local size = type(entry.size_human) == "string" and entry.size_human ~= ""
      and entry.size_human
    or image_metadata.format_bytes(bytes)
  local resolution = type(entry.resolution) == "string" and entry.resolution ~= "" and entry.resolution or "unknown"
  local path = type(entry.path) == "string" and entry.path ~= "" and entry.path or "(unknown)"
  lines[#lines + 1] = string.format("%s %s path: %s", prefix, label, path)
  lines[#lines + 1] = string.format("%s %s resolution: %s", prefix, label, resolution)
  lines[#lines + 1] = string.format("%s %s size: %s (%d bytes)", prefix, label, size, bytes)
  lines[#lines + 1] = string.format("%s %s sha: %s", prefix, label, sha)
end

local function render_image_metadata_diff(bufnr, reason_override)
  local ctx, ctx_err = resolve_image_buffer_context(bufnr)
  if not ctx then
    return false, ctx_err
  end

  local images_cfg = image_diff_options()
  local diff_shortcuts = diff_view_shortcuts()
  local default_action = resolve_image_default_action(images_cfg)
  local compare_url = resolve_image_compare_url(ctx, images_cfg)
  local reason = type(reason_override) == "string" and reason_override ~= "" and reason_override or ctx.reason
  local default_key = type(diff_shortcuts.image_default_action) == "string" and diff_shortcuts.image_default_action or "<localleader>io"
  local fallback_key = type(diff_shortcuts.image_fallback_menu) == "string" and diff_shortcuts.image_fallback_menu
    or "<localleader>im"
  local base_meta = collect_image_metadata_for_side(ctx, "base", images_cfg)
  local head_meta = collect_image_metadata_for_side(ctx, "head", images_cfg)
  local display_path = ctx.file_path ~= "" and ctx.file_path or ctx.path

  local lines = {
    "gh-pr image metadata diff",
    "",
    string.format("path: %s", display_path ~= "" and display_path or "(unknown)"),
    string.format("status: %s", ctx.status ~= "" and ctx.status or "unknown"),
    string.format("default action (%s): %s", default_key ~= "" and default_key or "<localleader>io", image_action_label(default_action)),
    string.format("fallback menu (%s): image actions", fallback_key ~= "" and fallback_key or "<localleader>im"),
  }
  if reason ~= "" then
    lines[#lines + 1] = string.format("render fallback reason: %s", reason)
  end
  if compare_url ~= "" then
    lines[#lines + 1] = string.format("github compare: %s", compare_url)
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "Image metadata"
  append_side_metadata_lines(lines, "-", "base", base_meta)
  append_side_metadata_lines(lines, "+", "head", head_meta)
  lines[#lines + 1] = ""
  lines[#lines + 1] = string.format(
    "Tip: use %s for default action or %s for fallback menu actions.",
    default_key ~= "" and default_key or "<localleader>io",
    fallback_key ~= "" and fallback_key or "<localleader>im"
  )

  image_renderer.clear(bufnr)
  local ok_write, write_err = write_readonly_buffer_lines(bufnr, lines, "diff")
  if not ok_write then
    return false, write_err
  end

  vim.b[bufnr].gh_pr_image_fallback = true
  if reason ~= "" then
    vim.b[bufnr].gh_pr_image_reason = reason
  end
  return true, nil
end

local function run_image_fallback_action(action, bufnr, opts)
  opts = type(opts) == "table" and opts or {}
  local ctx, ctx_err = resolve_image_buffer_context(bufnr)
  if not ctx then
    return false, ctx_err
  end

  local images_cfg = image_diff_options()
  local requested = normalize_image_action(action, resolve_image_default_action(images_cfg))
  local reason = type(opts.reason) == "string" and opts.reason ~= "" and opts.reason or ctx.reason

  if requested == "metadata" then
    return render_image_metadata_diff(ctx.bufnr, reason)
  end

  if requested == "open_local_current" then
    local side = current_image_side(ctx)
    local asset, asset_err = ensure_image_side_asset(ctx, side, images_cfg)
    if not asset then
      return false, asset_err
    end
    if asset.present == false then
      return false, string.format("No %s image exists for this pull request file state", side)
    end
    if not file_readable(asset.cache_path) then
      return false, "Unable to resolve a local image file to open"
    end
    return ensure_open_target(asset.cache_path, "local image")
  end

  if requested == "open_local_both" then
    local opened_paths = {}
    local opened_count = 0
    local errors = {}
    for _, side in ipairs({ "base", "head" }) do
      local asset, asset_err = ensure_image_side_asset(ctx, side, images_cfg)
      if not asset then
        errors[#errors + 1] = string.format("%s: %s", side, tostring(asset_err))
      elseif asset.present and file_readable(asset.cache_path) then
        if not opened_paths[asset.cache_path] then
          local ok_open, open_err = ensure_open_target(asset.cache_path, side .. " image")
          if ok_open then
            opened_paths[asset.cache_path] = true
            opened_count = opened_count + 1
          else
            errors[#errors + 1] = string.format("%s: %s", side, tostring(open_err))
          end
        end
      elseif asset.present then
        errors[#errors + 1] = string.format("%s: local cached file unavailable", side)
      end
    end

    if opened_count > 0 then
      return true, nil
    end
    if #errors > 0 then
      return false, table.concat(errors, " | ")
    end
    return false, "No local images available to open"
  end

  if requested == "open_github" then
    local url = resolve_image_compare_url(ctx, images_cfg)
    if url == "" then
      return false, "Unable to resolve GitHub comparison URL for this image"
    end
    return ensure_open_target(url, "GitHub comparison URL")
  end

  return false, "Unsupported image fallback action: " .. tostring(requested)
end

local function execute_image_fallback_action(action, bufnr, opts)
  opts = type(opts) == "table" and opts or {}
  local requested = normalize_image_action(action, "metadata")
  local ok_action, action_err = run_image_fallback_action(requested, bufnr, opts)
  if ok_action then
    return true, nil
  end

  local should_fallback_to_metadata = opts.fallback_to_metadata ~= false and requested ~= "metadata"
  if should_fallback_to_metadata then
    local ok_metadata, metadata_err = run_image_fallback_action("metadata", bufnr, {
      reason = type(opts.reason) == "string" and opts.reason ~= "" and opts.reason or tostring(action_err or ""),
    })
    if ok_metadata then
      notify_warn(string.format(
        "Image fallback action '%s' failed (%s). Rendered metadata diff instead.",
        requested,
        tostring(action_err)
      ))
      return true, nil
    end
    return false, tostring(action_err) .. " | metadata: " .. tostring(metadata_err)
  end

  return false, action_err
end

local function close_image_fallback_menu()
  if type(image_fallback_menu_state) ~= "table" then
    image_fallback_menu_state = nil
    return
  end

  local winid = image_fallback_menu_state.winid
  image_fallback_menu_state = nil
  if is_valid_win(winid) then
    pcall(vim.api.nvim_win_close, winid, true)
  end
end

local function current_menu_action(state_value)
  if type(state_value) ~= "table" or not is_valid_win(state_value.winid) then
    return nil
  end
  local cursor = vim.api.nvim_win_get_cursor(state_value.winid)
  return state_value.line_actions[cursor[1]]
end

local function run_menu_action(state_value, action, set_default)
  local action_id = normalize_image_action(action, resolve_image_default_action(image_diff_options()))
  if set_default == true then
    persist_image_default_action(action_id)
    notify_info("Image fallback default action set to: " .. image_action_label(action_id))
  end

  local origin_winid = state_value.origin_winid
  local origin_bufnr = state_value.origin_bufnr
  close_image_fallback_menu()

  if is_valid_win(origin_winid) then
    pcall(vim.api.nvim_set_current_win, origin_winid)
  end
  local ok_action, action_err = execute_image_fallback_action(action_id, origin_bufnr, {
    fallback_to_metadata = true,
  })
  if not ok_action then
    notify_error(action_err)
  end
end

function M.open_image_fallback_menu()
  local origin_bufnr = vim.api.nvim_get_current_buf()
  local ctx, ctx_err = resolve_image_buffer_context(origin_bufnr)
  if not ctx then
    return notify_error(ctx_err)
  end

  local origin_winid = vim.api.nvim_get_current_win()
  close_image_fallback_menu()

  local images_cfg = image_diff_options()
  local diff_shortcuts = diff_view_shortcuts()
  local default_action = resolve_image_default_action(images_cfg)
  local default_key = type(diff_shortcuts.image_default_action) == "string" and diff_shortcuts.image_default_action or "<localleader>io"
  local fallback_key = type(diff_shortcuts.image_fallback_menu) == "string" and diff_shortcuts.image_fallback_menu
    or "<localleader>im"
  local reason = type(vim.b[origin_bufnr].gh_pr_image_reason) == "string" and vim.b[origin_bufnr].gh_pr_image_reason or ""

  local lines = {
    "gh-pr image fallback actions",
    "Enter/1..4: run action | d: set default | s: set default + run | q: close",
    string.rep("=", 74),
    string.format("file: %s", ctx.file_path ~= "" and ctx.file_path or ctx.path),
    string.format("status: %s", ctx.status ~= "" and ctx.status or "unknown"),
    string.format("default (%s): %s", default_key ~= "" and default_key or "<localleader>io", image_action_label(default_action)),
    string.format("menu keymap: %s", fallback_key ~= "" and fallback_key or "<localleader>im"),
  }
  if reason ~= "" then
    lines[#lines + 1] = "reason: " .. reason
  end
  lines[#lines + 1] = ""

  local line_actions = {}
  for index, action in ipairs(IMAGE_FALLBACK_ACTION_ORDER) do
    local marker = action == default_action and "*" or " "
    lines[#lines + 1] = string.format("%d. [%s] %s", index, marker, image_action_label(action))
    line_actions[#lines] = action
  end

  local width = 72
  for _, line in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(line) + 2)
  end
  width = math.min(width, math.max(56, vim.o.columns - 6))
  local height = math.min(#lines + 1, math.max(10, vim.o.lines - vim.o.cmdheight - 4))
  local row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1)
  local col = math.max(0, math.floor((vim.o.columns - width) / 2))

  local menu_buf = vim.api.nvim_create_buf(false, true)
  local menu_win = vim.api.nvim_open_win(menu_buf, true, {
    relative = "editor",
    row = row,
    col = col,
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    title = "Image Fallback",
    title_pos = "center",
    noautocmd = true,
  })

  sanitize_modal_window(menu_win)
  vim.api.nvim_buf_set_option(menu_buf, "buftype", "nofile")
  vim.api.nvim_buf_set_option(menu_buf, "bufhidden", "wipe")
  vim.api.nvim_buf_set_option(menu_buf, "swapfile", false)
  vim.api.nvim_buf_set_option(menu_buf, "modifiable", true)
  vim.api.nvim_buf_set_option(menu_buf, "filetype", "markdown")
  vim.api.nvim_buf_set_lines(menu_buf, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(menu_buf, "modifiable", false)

  vim.api.nvim_win_set_option(menu_win, "number", false)
  vim.api.nvim_win_set_option(menu_win, "relativenumber", false)
  vim.api.nvim_win_set_option(menu_win, "cursorline", true)
  vim.api.nvim_win_set_option(menu_win, "wrap", false)
  vim.api.nvim_win_set_option(menu_win, "signcolumn", "no")
  vim.api.nvim_win_set_option(menu_win, "winhl", "NormalFloat:NormalFloat,FloatBorder:FloatBorder")

  image_fallback_menu_state = {
    bufnr = menu_buf,
    winid = menu_win,
    origin_winid = origin_winid,
    origin_bufnr = origin_bufnr,
    line_actions = line_actions,
    first_action_line = #lines - #IMAGE_FALLBACK_ACTION_ORDER + 1,
  }

  local keymap_opts = {
    buffer = menu_buf,
    silent = true,
    nowait = true,
  }

  vim.keymap.set("n", "q", close_image_fallback_menu, vim.tbl_extend("force", keymap_opts, { desc = "Close image fallback menu" }))
  vim.keymap.set("n", "<Esc>", close_image_fallback_menu, vim.tbl_extend("force", keymap_opts, { desc = "Close image fallback menu" }))
  vim.keymap.set("n", "<CR>", function()
    local active = image_fallback_menu_state
    local action = current_menu_action(active)
    if action then
      run_menu_action(active, action, false)
    end
  end, vim.tbl_extend("force", keymap_opts, { desc = "Run selected image fallback action" }))
  vim.keymap.set("n", "d", function()
    local active = image_fallback_menu_state
    local action = current_menu_action(active)
    if action then
      persist_image_default_action(action)
      notify_info("Image fallback default action set to: " .. image_action_label(action))
      local origin_winid = active.origin_winid
      close_image_fallback_menu()
      if is_valid_win(origin_winid) then
        pcall(vim.api.nvim_set_current_win, origin_winid)
      end
      M.open_image_fallback_menu()
    end
  end, vim.tbl_extend("force", keymap_opts, { desc = "Set selected action as default" }))
  vim.keymap.set("n", "s", function()
    local active = image_fallback_menu_state
    local action = current_menu_action(active)
    if action then
      run_menu_action(active, action, true)
    end
  end, vim.tbl_extend("force", keymap_opts, { desc = "Set selected action as default and run it" }))

  for index, action in ipairs(IMAGE_FALLBACK_ACTION_ORDER) do
    local action_id = action
    vim.keymap.set("n", tostring(index), function()
      local active = image_fallback_menu_state
      if active then
        run_menu_action(active, action_id, false)
      end
    end, vim.tbl_extend("force", keymap_opts, { desc = "Run image fallback action " .. tostring(index) }))
  end

  vim.api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(menu_win),
    once = true,
    callback = function()
      image_fallback_menu_state = nil
    end,
  })

  pcall(vim.api.nvim_win_set_cursor, menu_win, { image_fallback_menu_state.first_action_line, 0 })
end

function M.run_image_fallback_default_action()
  local bufnr = vim.api.nvim_get_current_buf()
  local _, ctx_err = resolve_image_buffer_context(bufnr)
  if ctx_err then
    return notify_error(ctx_err)
  end

  local images_cfg = image_diff_options()
  local action = resolve_image_default_action(images_cfg)
  local ok_action, action_err = execute_image_fallback_action(action, bufnr, {
    fallback_to_metadata = true,
  })
  if not ok_action then
    notify_error(action_err)
  end
end

function M.on_image_render_fallback(bufnr, reason)
  local ctx, ctx_err = resolve_image_buffer_context(bufnr)
  if not ctx then
    return notify_warn(ctx_err)
  end

  local images_cfg = image_diff_options()
  local mode = images_cfg.fallback_mode
  if mode ~= "menu" and mode ~= "metadata_only" and mode ~= "auto_local" and mode ~= "auto_github" then
    mode = "menu"
  end

  if type(reason) == "string" and reason ~= "" then
    vim.b[ctx.bufnr].gh_pr_image_reason = reason
  end

  if mode == "metadata_only" then
    local ok_action, action_err = execute_image_fallback_action("metadata", bufnr, {
      fallback_to_metadata = false,
      reason = reason,
    })
    if not ok_action then
      notify_warn("Unable to render image metadata fallback: " .. tostring(action_err))
    end
    return
  end

  if mode == "auto_local" then
    local preferred = resolve_image_default_action(images_cfg)
    if preferred ~= "open_local_current" and preferred ~= "open_local_both" then
      preferred = "open_local_current"
    end
    local ok_action, action_err = execute_image_fallback_action(preferred, bufnr, {
      fallback_to_metadata = true,
      reason = reason,
    })
    if not ok_action then
      notify_warn("Image fallback auto-local failed: " .. tostring(action_err))
    end
    return
  end

  if mode == "auto_github" then
    local ok_action, action_err = execute_image_fallback_action("open_github", bufnr, {
      fallback_to_metadata = true,
      reason = reason,
    })
    if not ok_action then
      notify_warn("Image fallback auto-github failed: " .. tostring(action_err))
    end
    return
  end

  local diff_shortcuts = diff_view_shortcuts()
  local default_action = resolve_image_default_action(images_cfg)
  local default_key = type(diff_shortcuts.image_default_action) == "string" and diff_shortcuts.image_default_action or "<localleader>io"
  local fallback_key = type(diff_shortcuts.image_fallback_menu) == "string" and diff_shortcuts.image_fallback_menu
    or "<localleader>im"
  if vim.api.nvim_get_current_buf() == bufnr then
    notify_warn(string.format(
      "Image render fallback: %s. Press %s for '%s' or %s for the fallback menu.",
      type(reason) == "string" and reason ~= "" and reason or "preview unavailable",
      default_key ~= "" and default_key or "<localleader>io",
      default_action,
      fallback_key ~= "" and fallback_key or "<localleader>im"
    ))
    M.open_image_fallback_menu()
  end
end

local function jump_to_line(line)
  local target = tonumber(line)
  if not target or target < 1 then
    return
  end

  local bufnr = vim.api.nvim_get_current_buf()
  local last = vim.api.nvim_buf_line_count(bufnr)
  local clamped = math.max(1, math.min(last, math.floor(target)))
  pcall(vim.api.nvim_win_set_cursor, 0, { clamped, 0 })
end

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

local function valid_window(winid)
  return type(winid) == "number" and winid > 0 and vim.api.nvim_win_is_valid(winid)
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
        }
      end
    end
  end

  return file, side, line, popup_thread, nil
end

local function open_target_file(file, side, line)
  if side == "base" then
    M.open_original(file)
  else
    M.open_modified(file)
  end
  jump_to_line(line)
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
  open_target_file(file, side, line)

  if open_thread_popup and popup_thread and type(popup_thread.comments) == "table" and not vim.tbl_isempty(popup_thread.comments) then
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

  open_target_file(file, side, line)
  local popup_focused = false

  if open_thread_popup and popup_thread and type(popup_thread.comments) == "table" and not vim.tbl_isempty(popup_thread.comments) then
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
    local state = type(item.state) == "string" and item.state:upper() or "COMMENTED"
    return "REVIEW " .. state
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

local function build_overview_callbacks(pr_number, mode)
  mode = mode == "v2" and "v2" or "v1"
  return {
    approve = function()
      M.review("approve")
    end,
    request_changes = function()
      M.review("request_changes")
    end,
    comment = function()
      M.review("comment")
    end,
    merge = function()
      M.merge()
    end,
    checkout = function()
      M.checkout(pr_number)
    end,
    refresh = function()
      if mode == "v2" then
        M.refresh_overview_v2()
      else
        M.refresh_overview()
      end
    end,
    open_url = function()
      M.open_overview_url(pr_number)
    end,
    open_comments_tree = function()
      M.open_comments(pr_number)
    end,
    edit_stub = function(kind, payload)
      M.overview_edit_stub(kind, payload)
    end,
    more_section = function(section)
      M.overview_more(section)
    end,
    open_location = function(target)
      M.open_comment_location(target)
    end,
    open_commit_diff = function(commit)
      M.open_commit_diff(commit)
    end,
    open_file_diff = function(file)
      M.open_diff(file)
    end,
    open_file_original = function(file)
      M.open_original(file)
    end,
    open_file_modified = function(file)
      M.open_modified(file)
    end,
    open_thread_fix_diff = function(payload)
      M.open_thread_fix_diff(payload)
    end,
    open_thread_comment_evolution_diff = function(payload)
      M.open_thread_comment_evolution_diff(payload)
    end,
    open_thread_comment_commit_diff = function(payload)
      M.open_thread_comment_commit_diff(payload)
    end,
    resolve_thread_fix_diff = function(payload, options)
      return M.resolve_thread_fix_diff(payload, options)
    end,
    preview_markdown_link = function(action)
      M.overview_preview_markdown_link(action)
    end,
    toggle_review_tree = function()
      M.toggle_review_tree()
    end,
  }
end

function M.build_overview_model_for_overview(number, opts)
  opts = opts or {}
  local pr, details, err = resolve_active_pr(number, { refresh = opts.refresh == true })
  if not pr then
    return nil, nil, err
  end

  local limits = normalize_overview_limits(opts.overview_limits)
  local threads, thread_err = pr_service.fetch_review_threads(pr.number, {
    threads_first = limits.threads,
    comments_first = math.min(100, limits.threads * 4),
  })

  if not threads then
    threads = {}
  end

  local repository = normalize_repository(details) or ""
  local pr_change_events, pr_change_err = pr_service.fetch_pr_change_events(pr.number, {
    repository = repository,
    pr_url = type(details.url) == "string" and details.url or "",
    max_items = math.min(500, math.max(100, limits.timeline * 4)),
    max_pages = 5,
  })
  if not pr_change_events then
    pr_change_events = {}
  end

  local model = pr_service.build_overview_model(details, threads, limits, {
    repository = repository,
    thread_error = thread_err,
    pr_change_events = pr_change_events,
    pr_change_error = pr_change_err,
  })

  return pr, model, nil
end

function M.open_overview(number, opts)
  opts = opts or {}

  local plugin_config = config.get() or {}
  local overview_v2_config = plugin_config.overview_v2 or {}
  if overview_v2_config.enabled == true and opts.force_v1 ~= true then
    return M.open_overview_v2(number, opts)
  end

  local pr, model, err = M.build_overview_model_for_overview(number, opts)
  if not pr then
    return notify_error(err)
  end

  local overview_config = plugin_config.overview or {}

  local target_bufnr = nil
  if is_valid_buf(opts.bufnr) then
    target_bufnr = opts.bufnr
  elseif opts.reuse_buffer then
    local current = vim.api.nvim_get_current_buf()
    if is_valid_buf(current) then
      target_bufnr = current
    end
  end

  overview.open(model, {
    bufnr = target_bufnr,
    cursor_line = opts.cursor_line,
    ui = overview_config.ui or "snacks",
    layout = overview_config.layout or "tabs",
    window = overview_config.window or {},
    theme = overview_config.theme or {},
    markdown = overview_config.markdown or {},
    thread_snippet = overview_config.thread_snippet or {},
    thread_fix_diff = overview_config.thread_fix_diff or {},
    tabs = overview_config.tabs,
    show = overview_config.show or {},
    date_format = overview_config.date_format or "%Y-%m-%d %H:%M",
    actions = build_overview_callbacks(pr.number, "v1"),
  })
end

function M.open_overview_v2(number, opts)
  opts = opts or {}

  local pr, model, err = M.build_overview_model_for_overview(number, opts)
  if not pr then
    return notify_error(err)
  end

  local plugin_config = config.get() or {}
  local overview_config = plugin_config.overview or {}
  local overview_v2_config = plugin_config.overview_v2 or {}
  local session_id = tonumber(opts.session_id) or nil

  require("gh-pr.overview_v2").open(model, {
    session_id = session_id,
    window = overview_v2_config.window or overview_config.window or {},
    layout = overview_v2_config.layout or {},
    keymaps = overview_v2_config.keymaps or {},
    activity = overview_v2_config.activity or {},
    show = overview_v2_config.show or overview_config.show or {},
    date_format = overview_v2_config.date_format or overview_config.date_format or "%Y-%m-%d %H:%M",
    theme = overview_config.theme or {},
    markdown = overview_config.markdown or {},
    thread_snippet = overview_config.thread_snippet or {},
    actions = build_overview_callbacks(pr.number, "v2"),
  })
end

function M.refresh_overview()
  local bufnr = vim.api.nvim_get_current_buf()
  local number = vim.b[bufnr].gh_pr_number
  if type(number) ~= "number" then
    return notify_error("Current buffer is not a gh-pr overview")
  end

  if vim.b[bufnr].gh_pr_overview_ui == "v2" then
    return M.refresh_overview_v2()
  end

  local cursor = vim.api.nvim_win_get_cursor(0)
  M.open_overview(number, {
    refresh = true,
    reuse_buffer = true,
    cursor_line = cursor[1],
    overview_limits = current_overview_limits(),
    force_v1 = true,
  })
end

function M.refresh_overview_v2()
  local bufnr = vim.api.nvim_get_current_buf()
  local number = vim.b[bufnr].gh_pr_number
  if type(number) ~= "number" then
    return notify_error("Current buffer is not a gh-pr overview")
  end

  M.open_overview_v2(number, {
    refresh = true,
    session_id = vim.b[bufnr].gh_pr_overview_v2_session,
    overview_limits = current_overview_limits(),
  })
end

function M.refresh_visible_overview_for_pr(number)
  local pr_number = tonumber(number)
  if not pr_number then
    return 0
  end

  local current_tab = vim.api.nvim_get_current_tabpage()
  local refreshed = 0
  local refreshed_buffers = {}

  for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(current_tab)) do
    if is_valid_win(winid) then
      local bufnr = vim.api.nvim_win_get_buf(winid)
      local overview_ui = vim.b[bufnr].gh_pr_overview_ui
      local is_v1 = overview_ui == "snacks" or buffer_filetype(bufnr) == "ghpr_overview"
      local is_v2 = overview_ui == "v2" and vim.b[bufnr].gh_pr_overview_v2_primary == true
      if is_valid_buf(bufnr)
        and not refreshed_buffers[bufnr]
        and (is_v1 or is_v2)
        and tonumber(vim.b[bufnr].gh_pr_number) == pr_number then
        local cursor = vim.api.nvim_win_get_cursor(winid)
        local cursor_line = type(cursor) == "table" and tonumber(cursor[1]) or nil
        local limits = type(vim.b[bufnr].gh_pr_overview_limits) == "table" and vim.deepcopy(vim.b[bufnr].gh_pr_overview_limits)
          or nil

        local ok = pcall(vim.api.nvim_win_call, winid, function()
          if is_v2 then
            M.open_overview_v2(pr_number, {
              refresh = true,
              session_id = vim.b[bufnr].gh_pr_overview_v2_session,
              overview_limits = limits,
            })
          else
            M.open_overview(pr_number, {
              refresh = true,
            reuse_buffer = true,
            bufnr = bufnr,
            cursor_line = cursor_line,
            overview_limits = limits,
            force_v1 = true,
          })
          end
        end)

        if ok then
          refreshed = refreshed + 1
          refreshed_buffers[bufnr] = true
        end
      end
    end
  end

  return refreshed
end

function M.overview_more(section, count)
  section = type(section) == "string" and section:lower() or ""
  if section == "comments" or section == "reviews" or section == "threads" then
    section = "timeline"
  end
  if not valid_overview_sections()[section] then
    return notify_error("Section must be one of: checks, commits, timeline")
  end

  local bufnr = vim.api.nvim_get_current_buf()
  local number = vim.b[bufnr].gh_pr_number
  if type(number) ~= "number" then
    return notify_error("Current buffer is not a gh-pr overview")
  end
  local overview_ui = vim.b[bufnr].gh_pr_overview_ui

  local overview_config = (config.get() or {}).overview or {}
  local step = positive_integer(count, positive_integer(overview_config.expand_step, 20))
  local limits = current_overview_limits()
  if section == "timeline" then
    limits.timeline = positive_integer(limits.timeline, step) + step
    limits.comments = limits.timeline
    limits.reviews = limits.timeline
    limits.threads = limits.timeline
  else
    limits[section] = positive_integer(limits[section], step) + step
  end

  if overview_ui == "v2" then
    M.open_overview_v2(number, {
      refresh = true,
      session_id = vim.b[bufnr].gh_pr_overview_v2_session,
      overview_limits = limits,
    })
    return
  end

  local cursor = vim.api.nvim_win_get_cursor(0)
  M.open_overview(number, {
    refresh = true,
    reuse_buffer = true,
    cursor_line = cursor[1],
    overview_limits = limits,
    force_v1 = true,
  })
end

function M.open_overview_url(number)
  local pr, _, err = resolve_active_pr(number)
  if not pr then
    return notify_error(err)
  end

  local ok, open_err = pr_service.open_in_browser(pr.number)
  if not ok then
    if vim.ui and type(vim.ui.open) == "function" and type(pr.url) == "string" and pr.url ~= "" then
      vim.ui.open(pr.url)
      return
    end
    return notify_error(open_err)
  end
end

function M.open_comments(number)
  local pr, _, err = resolve_active_pr(number)
  if not pr then
    return notify_error(err)
  end

  local command = string.format("GhPrComments %d", pr.number)
  local ok, run_err = pcall(vim.cmd, command)
  if not ok then
    return notify_error("Unable to open Comments PR view: " .. tostring(run_err))
  end
end

local overview_edit_labels = {
  edit_title = "Edit title",
  edit_body = "Edit description",
  edit_labels = "Edit labels",
  edit_reviewers = "Edit reviewers",
  edit_assignees = "Edit assignees",
  edit_milestone = "Edit milestone",
  change_state = "Change state",
  change_draft = "Change draft status",
}

local function normalize_string(value)
  if type(value) ~= "string" then
    return ""
  end
  return vim.trim(value)
end

local function normalize_key(value)
  return normalize_string(value):lower()
end

local function parse_csv_items(value)
  if type(value) ~= "string" then
    return {}
  end

  local items = {}
  local seen = {}
  for _, raw in ipairs(vim.split(value, ",", { plain = true })) do
    local item = normalize_string(raw)
    if item ~= "" then
      local key = normalize_key(item)
      if key ~= "" and not seen[key] then
        seen[key] = true
        items[#items + 1] = item
      end
    end
  end

  return items
end

local function summarize_list(items, empty_label)
  items = type(items) == "table" and items or {}
  if vim.tbl_isempty(items) then
    return empty_label or "(none)"
  end

  if #items <= 5 then
    return table.concat(items, ", ")
  end

  local preview = {}
  for index = 1, 4 do
    preview[#preview + 1] = items[index]
  end
  preview[#preview + 1] = string.format("+%d more", #items - 4)
  return table.concat(preview, ", ")
end

local function summarize_text(value, max_length)
  local text = normalize_string(value)
  if text == "" then
    return "(empty)"
  end

  text = text:gsub("\n", " ")
  local limit = positive_integer(max_length, 80)
  if #text > limit then
    return text:sub(1, limit - 3) .. "..."
  end
  return text
end

local function extract_name(item)
  if type(item) == "string" then
    return normalize_string(item)
  end

  if type(item) ~= "table" then
    return ""
  end

  if type(item.login) == "string" and item.login ~= "" then
    return normalize_string(item.login)
  end

  if type(item.slug) == "string" and item.slug ~= "" then
    if type(item.organization) == "table" and type(item.organization.login) == "string" and item.organization.login ~= "" then
      return normalize_string(item.organization.login .. "/" .. item.slug)
    end
    return normalize_string(item.slug)
  end

  if type(item.name) == "string" and item.name ~= "" then
    return normalize_string(item.name)
  end

  if type(item.requestedReviewer) == "table" then
    return extract_name(item.requestedReviewer)
  end

  if type(item.user) == "table" then
    return extract_name(item.user)
  end

  if type(item.team) == "table" then
    return extract_name(item.team)
  end

  return ""
end

local function normalize_items(items)
  local result = {}
  local seen = {}

  for _, item in ipairs(type(items) == "table" and items or {}) do
    local name = extract_name(item)
    if name ~= "" then
      local key = normalize_key(name)
      if key ~= "" and not seen[key] then
        seen[key] = true
        result[#result + 1] = name
      end
    end
  end

  return result
end

local function compute_replacement_diff(current_items, desired_items)
  local current = {}
  local desired = {}
  local add = {}
  local remove = {}

  for _, item in ipairs(current_items) do
    local key = normalize_key(item)
    if key ~= "" then
      current[key] = item
    end
  end

  for _, item in ipairs(desired_items) do
    local key = normalize_key(item)
    if key ~= "" and not desired[key] then
      desired[key] = item
      if not current[key] then
        add[#add + 1] = item
      end
    end
  end

  for _, item in ipairs(current_items) do
    local key = normalize_key(item)
    if key ~= "" and not desired[key] then
      remove[#remove + 1] = item
    end
  end

  return add, remove
end

local function current_milestone(details)
  if type(details.milestone) == "table" and type(details.milestone.title) == "string" then
    return normalize_string(details.milestone.title)
  end
  return ""
end

local function current_labels(details)
  return normalize_items(details.labels)
end

local function current_reviewers(details)
  return normalize_items(details.reviewRequests)
end

local function current_assignees(details)
  return normalize_items(details.assignees)
end

local function normalize_values_list(values)
  local result = {}
  local seen = {}
  for _, value in ipairs(type(values) == "table" and values or {}) do
    local text = normalize_string(value)
    local key = normalize_key(text)
    if text ~= "" and key ~= "" and not seen[key] then
      seen[key] = true
      result[#result + 1] = text
    end
  end
  return result
end

local function normalize_reviewer_identity(value)
  local text = normalize_string(value)
  if text == "" then
    return ""
  end

  text = text:gsub("^%s+", ""):gsub("%s+$", "")
  text = text:gsub("^@", "")
  text = text:gsub("%s+%([Tt][Ee][Aa][Mm]%)$", "")
  text = text:gsub("^%s+", ""):gsub("%s+$", "")
  return text
end

local function normalize_reviewer_values(values)
  local result = {}
  local seen = {}
  for _, value in ipairs(type(values) == "table" and values or {}) do
    local normalized = normalize_reviewer_identity(value)
    local key = normalize_key(normalized)
    if normalized ~= "" and key ~= "" and not seen[key] then
      seen[key] = true
      result[#result + 1] = normalized
    end
  end
  return result
end

local function confirm_overview_edit(pr_number, action_label, summary, callback)
  local prompt = string.format(
    "Apply %s on PR #%d? %s",
    action_label,
    pr_number,
    summary
  )

  vim.ui.select({ "confirm", "cancel" }, {
    prompt = prompt,
  }, function(choice)
    callback(choice == "confirm")
  end)
end

local function build_title_edit(choice, details)
  local next_title = normalize_string(choice)
  local current_title = normalize_string(details.title)
  if next_title == "" then
    return nil, "Title cannot be empty", false
  end
  if next_title == current_title then
    return nil, "No changes detected for title", true
  end

  return {
    summary = string.format("title: %s", summarize_text(next_title, 80)),
    success = "Title updated",
    run = function(pr_number)
      return pr_service.edit(pr_number, { title = next_title })
    end,
  }, nil, false
end

local function build_body_edit(choice, details)
  local next_body = type(choice) == "string" and choice or ""
  local current_body = type(details.body) == "string" and details.body or ""
  if next_body == current_body then
    return nil, "No changes detected for description", true
  end

  local summary
  if normalize_string(next_body) == "" then
    summary = "description: clear"
  else
    summary = string.format("description: %s", summarize_text(next_body, 80))
  end

  return {
    summary = summary,
    success = "Description updated",
    run = function(pr_number)
      return pr_service.edit(pr_number, { body = next_body })
    end,
  }, nil, false
end

local function build_milestone_edit(choice, details)
  local next_milestone = normalize_string(choice)
  local current_value = current_milestone(details)
  if next_milestone == current_value then
    return nil, "No changes detected for milestone", true
  end

  if next_milestone == "" then
    if current_value == "" then
      return nil, "No changes detected for milestone", true
    end

    return {
      summary = "milestone: remove",
      success = "Milestone removed",
      run = function(pr_number)
        return pr_service.edit(pr_number, { remove_milestone = true })
      end,
    }, nil, false
  end

  return {
    summary = string.format("milestone: %s", summarize_text(next_milestone, 60)),
    success = "Milestone updated",
    run = function(pr_number)
      return pr_service.edit(pr_number, { milestone = next_milestone })
    end,
  }, nil, false
end

local function build_list_edit_from_values(kind, desired_values, current_values)
  local desired = normalize_values_list(desired_values)
  local current = normalize_values_list(current_values)
  if kind == "edit_reviewers" then
    desired = normalize_reviewer_values(desired)
    current = normalize_reviewer_values(current)
  end

  local add, remove = compute_replacement_diff(current, desired)

  if vim.tbl_isempty(add) and vim.tbl_isempty(remove) then
    return nil, "No changes detected", true
  end

  local summary = string.format(
    "final: [%s] | add: [%s] | remove: [%s]",
    summarize_list(desired),
    summarize_list(add),
    summarize_list(remove)
  )

  local operations = {}
  local success

  if kind == "edit_labels" then
    operations.add_labels = add
    operations.remove_labels = remove
    success = "Labels updated"
  elseif kind == "edit_reviewers" then
    operations.add_reviewers = add
    operations.remove_reviewers = remove
    success = "Reviewers updated"
  elseif kind == "edit_assignees" then
    operations.add_assignees = add
    operations.remove_assignees = remove
    success = "Assignees updated"
  else
    return nil, "Unsupported list edit action", false
  end

  return {
    summary = summary,
    success = success,
    run = function(pr_number)
      return pr_service.edit(pr_number, operations)
    end,
  }, nil, false
end

local function build_list_edit(kind, choice, current_values)
  local desired = parse_csv_items(type(choice) == "string" and choice or "")
  return build_list_edit_from_values(kind, desired, current_values)
end

local selector_cache = {
  labels = {},
  reviewers = {},
}

local function cache_now()
  return os.time()
end

local function cache_key_for_repo(details)
  local repository = normalize_repository(details)
  return type(repository) == "string" and repository ~= "" and repository or "__unknown__"
end

local function cache_get(bucket, key, ttl_seconds)
  local entry = selector_cache[bucket] and selector_cache[bucket][key] or nil
  if type(entry) ~= "table" then
    return nil
  end
  local age = cache_now() - (tonumber(entry.timestamp) or 0)
  if age > ttl_seconds then
    selector_cache[bucket][key] = nil
    return nil
  end
  return vim.deepcopy(entry.value)
end

local function cache_put(bucket, key, value)
  selector_cache[bucket] = selector_cache[bucket] or {}
  selector_cache[bucket][key] = {
    timestamp = cache_now(),
    value = vim.deepcopy(value),
  }
end

local function load_label_candidates(details)
  local key = cache_key_for_repo(details)
  local cached = cache_get("labels", key, 120)
  if cached then
    return cached, nil
  end

  local labels, labels_err = pr_service.fetch_repo_labels({
    repository = key ~= "__unknown__" and key or nil,
    per_page = 100,
    max_pages = 20,
  })
  if not labels then
    return nil, labels_err
  end

  cache_put("labels", key, labels)
  return labels, nil
end

local function load_reviewer_candidates(details)
  local key = cache_key_for_repo(details)
  local cached = cache_get("reviewers", key, 120)
  if cached then
    return cached, nil
  end

  local candidates, candidates_err = pr_service.fetch_reviewer_candidates({
    repository = key ~= "__unknown__" and key or nil,
    per_page = 100,
    max_pages = 20,
  })
  if not candidates then
    return nil, candidates_err
  end

  cache_put("reviewers", key, candidates)
  return candidates, nil
end

local function open_label_multi_select(pr, details, callback)
  local labels, labels_err = load_label_candidates(details)
  if not labels then
    notify_error("Unable to load repository labels: " .. tostring(labels_err))
    callback(false)
    return
  end

  local current = current_labels(details)
  local selected = {}
  for _, value in ipairs(current) do
    selected[normalize_key(value)] = true
  end

  local items = {}
  local seen = {}
  for _, label in ipairs(labels) do
    local name = normalize_string(label.name)
    local key = normalize_key(name)
    if name ~= "" and key ~= "" and not seen[key] then
      seen[key] = true
      items[#items + 1] = {
        id = name,
        value = name,
        label = name,
        description = normalize_string(label.description),
        color = normalize_string(label.color),
        kind = "label",
        selected = selected[key] == true,
      }
    end
  end

  for _, current_name in ipairs(current) do
    local key = normalize_key(current_name)
    if key ~= "" and not seen[key] then
      seen[key] = true
      items[#items + 1] = {
        id = current_name,
        value = current_name,
        label = current_name,
        description = "",
        color = "",
        kind = "label",
        selected = true,
      }
    end
  end

  table.sort(items, function(left, right)
    return normalize_key(left.label) < normalize_key(right.label)
  end)

  multi_select.open({
    title = string.format("PR #%d - Edit labels", pr.number),
    items = items,
    on_confirm = function(values)
      callback(values)
    end,
    on_cancel = function()
      callback(nil)
    end,
  })
end

local function open_reviewer_multi_select(pr, details, callback)
  local candidates, candidates_err = load_reviewer_candidates(details)
  if not candidates then
    notify_error("Unable to load reviewer candidates: " .. tostring(candidates_err))
    callback(false)
    return
  end

  for _, warning in ipairs(type(candidates.warnings) == "table" and candidates.warnings or {}) do
    notify_warn(warning)
  end

  local current = current_reviewers(details)
  local selected = {}
  for _, value in ipairs(current) do
    selected[normalize_key(value)] = true
  end

  local items = {}
  local seen = {}
  for _, candidate in ipairs(type(candidates.merged) == "table" and candidates.merged or {}) do
    local value = normalize_string(candidate.value)
    local key = normalize_key(value)
    if value ~= "" and key ~= "" and not seen[key] then
      seen[key] = true
      items[#items + 1] = {
        id = value,
        value = value,
        label = normalize_string(candidate.display) ~= "" and normalize_string(candidate.display) or value,
        description = "",
        kind = normalize_string(candidate.kind) == "team" and "team" or "user",
        selected = selected[key] == true,
      }
    end
  end

  for _, current_value in ipairs(current) do
    local key = normalize_key(current_value)
    if key ~= "" and not seen[key] then
      seen[key] = true
      local is_team = current_value:find("/", 1, true) ~= nil
      items[#items + 1] = {
        id = current_value,
        value = current_value,
        label = "@" .. current_value,
        description = "",
        kind = is_team and "team" or "user",
        selected = true,
      }
    end
  end

  table.sort(items, function(left, right)
    if left.kind ~= right.kind then
      local left_order = left.kind == "user" and 1 or 2
      local right_order = right.kind == "user" and 1 or 2
      return left_order < right_order
    end
    return normalize_key(left.value) < normalize_key(right.value)
  end)

  multi_select.open({
    title = string.format("PR #%d - Edit reviewers", pr.number),
    items = items,
    on_confirm = function(values)
      callback(values)
    end,
    on_cancel = function()
      callback(nil)
    end,
  })
end

local function build_state_change(choice, details)
  local target = normalize_key(choice)
  if target ~= "open" and target ~= "closed" then
    return nil, "Invalid state selection", false
  end

  local current = normalize_key(details.state)
  if current == target then
    return nil, "No changes detected for PR state", true
  end

  local before_state = (current ~= "" and current or "unknown"):upper()
  local after_state = target:upper()
  return {
    summary = string.format("state: %s -> %s", before_state, after_state),
    success = string.format("PR state changed to %s", after_state),
    run = function(pr_number)
      return pr_service.change_state(pr_number, target)
    end,
  }, nil, false
end

local function build_draft_change(choice, details)
  local target = normalize_key(choice)
  if target ~= "ready" and target ~= "draft" then
    return nil, "Invalid draft status selection", false
  end

  local current = details.isDraft == true and "draft" or "ready"
  if current == target then
    return nil, "No changes detected for draft status", true
  end

  return {
    summary = string.format("draft status: %s -> %s", current:upper(), target:upper()),
    success = string.format("Draft status changed to %s", target:upper()),
    run = function(pr_number)
      return pr_service.change_draft(pr_number, target)
    end,
  }, nil, false
end

local function build_overview_edit_operation(kind, choice, details)
  if kind == "edit_title" then
    return build_title_edit(choice, details)
  end
  if kind == "edit_body" then
    return build_body_edit(choice, details)
  end
  if kind == "edit_milestone" then
    return build_milestone_edit(choice, details)
  end
  if kind == "edit_labels" then
    if type(choice) == "table" then
      return build_list_edit_from_values(kind, choice, current_labels(details))
    end
    return build_list_edit(kind, choice, current_labels(details))
  end
  if kind == "edit_reviewers" then
    if type(choice) == "table" then
      return build_list_edit_from_values(kind, choice, current_reviewers(details))
    end
    return build_list_edit(kind, choice, current_reviewers(details))
  end
  if kind == "edit_assignees" then
    return build_list_edit(kind, choice, current_assignees(details))
  end
  if kind == "change_state" then
    return build_state_change(choice, details)
  end
  if kind == "change_draft" then
    return build_draft_change(choice, details)
  end

  return nil, "Unsupported overview edit action", false
end

local function capture_overview_context()
  local bufnr = vim.api.nvim_get_current_buf()
  if not is_valid_buf(bufnr) then
    return nil
  end

  local number = vim.b[bufnr].gh_pr_number
  if type(number) ~= "number" then
    return nil
  end

  local context = {
    bufnr = bufnr,
    pr_number = number,
    overview_ui = vim.b[bufnr].gh_pr_overview_ui,
    overview_v2_session = tonumber(vim.b[bufnr].gh_pr_overview_v2_session),
  }

  local winid = vim.fn.bufwinid(bufnr)
  if is_valid_win(winid) then
    context.winid = winid
    local ok, cursor = pcall(vim.api.nvim_win_get_cursor, winid)
    if ok and type(cursor) == "table" and type(cursor[1]) == "number" then
      context.cursor_line = math.max(1, math.floor(cursor[1]))
    end
  end

  local limits = vim.b[bufnr].gh_pr_overview_limits
  if type(limits) == "table" then
    context.overview_limits = vim.deepcopy(limits)
  end

  return context
end

local function refresh_overview_after_edit(pr_number, context)
  local options = {
    refresh = true,
  }
  local opener = M.open_overview

  if type(pr_number) ~= "number" then
    return
  end

  local is_v2 = type(context) == "table" and context.overview_ui == "v2"
  if is_v2 then
    opener = M.open_overview_v2
    options.session_id = type(context) == "table" and context.overview_v2_session or nil
  elseif type(context) == "table" and is_valid_buf(context.bufnr) then
    options.reuse_buffer = true
    options.bufnr = context.bufnr
    if type(context.cursor_line) == "number" then
      options.cursor_line = context.cursor_line
    end
    options.force_v1 = true
  end

  if type(context) == "table" and type(context.overview_limits) == "table" then
    options.overview_limits = context.overview_limits
  end

  local ok, err = pcall(opener, pr_number, options)
  if not ok then
    notify_warn("Overview updated remotely, but local refresh failed: " .. tostring(err))
  end
end

local function overview_edit_picker(kind, payload, pr, details, callback)
  payload = type(payload) == "table" and payload or {}

  if kind == "edit_labels" then
    return open_label_multi_select(pr, details, callback)
  end

  if kind == "edit_reviewers" then
    return open_reviewer_multi_select(pr, details, callback)
  end

  if kind == "change_state" then
    vim.ui.select({ "open", "closed" }, {
      prompt = "Target state:",
    }, function(choice)
      callback(choice)
    end)
    return
  end

  if kind == "change_draft" then
    vim.ui.select({ "ready", "draft" }, {
      prompt = "Target draft status:",
    }, function(choice)
      callback(choice)
    end)
    return
  end

  local default_value = payload.current
  if type(default_value) ~= "string" then
    default_value = ""
  end

  local prompt = string.format("%s: ", overview_edit_labels[kind] or "Edit")
  vim.ui.input({
    prompt = prompt,
    default = default_value,
  }, function(input)
    callback(input)
  end)
end

function M.overview_edit_stub(kind, payload)
  local label = overview_edit_labels[kind]
  if not label then
    return notify_warn("Unsupported overview edit action")
  end

  local overview_context = capture_overview_context()
  local target_number = overview_context and overview_context.pr_number or nil
  local pr, details, err = resolve_active_pr(target_number)
  if not pr then
    return notify_error(err)
  end

  overview_edit_picker(kind, payload, pr, details, function(choice)
    if choice == false then
      return
    end

    if choice == nil then
      notify_info(label .. " cancelled")
      return
    end

    local operation, build_err, noop = build_overview_edit_operation(kind, choice, details)
    if noop then
      notify_info(build_err or "No changes detected")
      return
    end
    if not operation then
      notify_error(build_err)
      return
    end

    confirm_overview_edit(pr.number, label, operation.summary or "", function(confirmed)
      if not confirmed then
        notify_info(label .. " cancelled")
        return
      end

      local ok, op_err = operation.run(pr.number)
      if not ok then
        notify_error(op_err)
        return
      end

      notify_info(operation.success or (label .. " completed"))
      refresh_overview_after_edit(pr.number, overview_context)
      refresh_pr_sources_after_state_change({ force = true })
    end)
  end)
end

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
  if type(commit) == "table"
    and type(commit.url) == "string"
    and commit.url ~= ""
    and vim.ui
    and type(vim.ui.open) == "function" then
    vim.ui.open(commit.url)
    return true
  end
  return false
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
  local parsed = parse_repo_full_name(full_name)
  if not parsed then
    return nil
  end

  return {
    owner = {
      login = parsed.owner,
    },
    name = parsed.name,
    nameWithOwner = parsed.full_name,
  }
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

function M.open_commit_diff(commit)
  local pr, details, err = resolve_active_pr()
  if not pr then
    return notify_error(err)
  end

  local selected_commit = resolve_commit(commit)
  if not selected_commit then
    return notify_error("No commit selected")
  end

  local commit_details, commit_err = fetch_commit_details_for_pr(pr, details, selected_commit)
  if not commit_details then
    if open_commit_url(selected_commit) then
      return
    end
    return notify_error(commit_err)
  end

  local _, open_err = virtual_files.open_commit_patch(details, pr, commit_details)
  if open_err then
    if open_commit_url(commit_details) then
      return
    end
    return notify_error(open_err)
  end
end

function M.open_commit_file_diff(commit, file, opts)
  opts = opts or {}
  local pr, details, err = resolve_active_pr()
  if not pr then
    return notify_error(err)
  end

  local selected_commit = resolve_commit(commit)
  if not selected_commit then
    return notify_error("No commit selected")
  end

  local selected_file = normalize_commit_file_for_diff(file)
  if not selected_file then
    return notify_error("No commit file selected for diff")
  end

  local commit_details = selected_commit
  if type(commit_details.parent_oid) ~= "string" or commit_details.parent_oid == "" then
    local fetched_commit, fetch_err = fetch_commit_details_for_pr(pr, details, selected_commit)
    if not fetched_commit then
      if open_commit_url(selected_commit) then
        return
      end
      return notify_error(fetch_err)
    end
    commit_details = fetched_commit
  end

  if type(commit_details.parent_oid) ~= "string" or commit_details.parent_oid == "" then
    return notify_error("Selected commit has no parent commit to diff against")
  end

  local commit_diff_details = build_commit_diff_details(details, commit_details)
  if type(commit_diff_details.baseRefName) ~= "string" or commit_diff_details.baseRefName == "" then
    return notify_error("Unable to resolve base ref for selected commit diff")
  end
  if type(commit_diff_details.headRefName) ~= "string" or commit_diff_details.headRefName == "" then
    return notify_error("Unable to resolve head ref for selected commit diff")
  end

  state.set_active_file(selected_file)
  local diff_view = current_diff_view_preferences({
    mode = opts.view_mode,
    ignore_whitespace = opts.ignore_whitespace,
    render_whitespace = opts.render_whitespace,
    render_endlines = opts.render_endlines,
  })

  local diff_result, diff_err = virtual_files.open_diff(commit_diff_details, pr, selected_file, {
    line_comments = nil,
    view_mode = diff_view.mode,
    ignore_whitespace = diff_view.ignore_whitespace,
    render_whitespace = diff_view.render_whitespace,
    render_endlines = diff_view.render_endlines,
    new_tab = opts.new_tab,
  })
  if diff_err then
    return notify_error(diff_err)
  end

  if type(diff_result) == "table" and diff_result.file_mode == "added_single" then
    notify_info("File is new in selected commit. Opened single MODIFIED buffer (diff layouts disabled).")
  elseif type(diff_result) == "table" and diff_result.file_mode == "removed_single" then
    notify_info("File was removed in selected commit. Opened single ORIGINAL buffer (diff layouts disabled).")
  end

  local target_side = type(opts.target_side) == "string" and opts.target_side:lower() or "head"
  if target_side ~= "base" then
    target_side = "head"
  end
  local target_line = target_side == "base"
      and positive_integer(opts.target_original_line, positive_integer(opts.target_line, nil))
    or positive_integer(opts.target_line, positive_integer(opts.target_original_line, nil))
  if type(target_line) == "number" and target_line > 0 and type(diff_result) == "table" then
    local target_buf = nil
    if target_side == "base" then
      target_buf = tonumber(diff_result.base_buf) or tonumber(diff_result.single_buf) or tonumber(diff_result.unified_buf)
    else
      target_buf = tonumber(diff_result.head_buf) or tonumber(diff_result.single_buf) or tonumber(diff_result.unified_buf)
    end
    if not target_buf then
      target_buf = tonumber(diff_result.head_buf) or tonumber(diff_result.base_buf)
    end

    if type(target_buf) == "number" and target_buf > 0 and is_valid_buf(target_buf) then
      local winid = vim.fn.bufwinid(target_buf)
      if type(winid) == "number" and winid > 0 and is_valid_win(winid) then
        pcall(vim.api.nvim_set_current_win, winid)
        restore_cursor_line(winid, target_line)
      end
    end
  end

  do
    local ok_panel, panel = pcall(require, "gh-pr.diff_comments_panel")
    if ok_panel and type(panel.sync_for_diff) == "function" then
      pcall(panel.sync_for_diff, {
        pr = pr,
        details = details,
        comments_ctx = nil,
        pr_number = pr.number,
      })
    end
  end
end

function M.open_thread_comment_evolution_diff(payload, opts)
  payload = type(payload) == "table" and payload or {}
  opts = type(opts) == "table" and opts or {}

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
  local diff_view = current_diff_view_preferences({
    mode = opts.view_mode,
    ignore_whitespace = opts.ignore_whitespace,
    render_whitespace = opts.render_whitespace,
    render_endlines = opts.render_endlines,
  })

  local diff_result, diff_err = virtual_files.open_diff(compare_details, pr, compare_file, {
    line_comments = nil,
    view_mode = diff_view.mode,
    ignore_whitespace = diff_view.ignore_whitespace,
    render_whitespace = diff_view.render_whitespace,
    render_endlines = diff_view.render_endlines,
    new_tab = opts.new_tab,
  })
  if diff_err then
    return open_fallback(diff_err)
  end

  if type(diff_result) == "table" and diff_result.file_mode == "added_single" then
    notify_info("File is new in compared commit range. Opened single MODIFIED buffer (diff layouts disabled).")
  elseif type(diff_result) == "table" and diff_result.file_mode == "removed_single" then
    notify_info("File was removed in compared commit range. Opened single ORIGINAL buffer (diff layouts disabled).")
  end

  local focus_side = target_side == "base" and "base" or "head"
  local focus_line = focus_side == "base" and target_original_line or target_line
  if type(focus_line) == "number" and focus_line > 0 and type(diff_result) == "table" then
    local target_buf = nil
    if focus_side == "base" then
      target_buf = tonumber(diff_result.base_buf) or tonumber(diff_result.single_buf) or tonumber(diff_result.unified_buf)
    else
      target_buf = tonumber(diff_result.head_buf) or tonumber(diff_result.single_buf) or tonumber(diff_result.unified_buf)
    end
    if not target_buf then
      target_buf = tonumber(diff_result.head_buf) or tonumber(diff_result.base_buf)
    end
    if type(target_buf) == "number" and target_buf > 0 and is_valid_buf(target_buf) then
      local winid = vim.fn.bufwinid(target_buf)
      if type(winid) == "number" and winid > 0 and is_valid_win(winid) then
        pcall(vim.api.nvim_set_current_win, winid)
        restore_cursor_line(winid, focus_line)
      end
    end
  end

  do
    local ok_panel, panel = pcall(require, "gh-pr.diff_comments_panel")
    if ok_panel and type(panel.sync_for_diff) == "function" then
      pcall(panel.sync_for_diff, {
        pr = pr,
        details = details,
        comments_ctx = nil,
        pr_number = pr.number,
      })
    end
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

function M.open_diff(file, opts)
  opts = opts or {}
  local pr, details, err = resolve_active_pr()
  if not pr then
    return notify_error(err)
  end

  local selected_file = resolve_file(file)
  if not selected_file then
    return notify_error("No file selected for diff")
  end

  state.set_active_file(selected_file)
  local comments_ctx = build_line_comment_context(pr.number)
  local diff_view = current_diff_view_preferences({
    mode = opts.view_mode,
    ignore_whitespace = opts.ignore_whitespace,
    render_whitespace = opts.render_whitespace,
    render_endlines = opts.render_endlines,
  })

  local diff_result, diff_err = virtual_files.open_diff(details, pr, selected_file, {
    line_comments = comments_ctx,
    view_mode = diff_view.mode,
    ignore_whitespace = diff_view.ignore_whitespace,
    render_whitespace = diff_view.render_whitespace,
    render_endlines = diff_view.render_endlines,
    new_tab = opts.new_tab,
  })
  if diff_err then
    return notify_error(diff_err)
  end

  if type(diff_result) == "table" and diff_result.file_mode == "added_single" then
    notify_info("File is new in this PR. Opened single MODIFIED buffer (diff layouts disabled).")
  elseif type(diff_result) == "table" and diff_result.file_mode == "removed_single" then
    notify_info("File was removed in this PR. Opened single ORIGINAL buffer (diff layouts disabled).")
  end

  do
    local ok_panel, panel = pcall(require, "gh-pr.diff_comments_panel")
    if ok_panel and type(panel.sync_for_diff) == "function" then
      pcall(panel.sync_for_diff, {
        pr = pr,
        details = details,
        comments_ctx = comments_ctx,
        pr_number = pr.number,
      })
    end
  end
end

function M.open_original(file)
  local pr, details, err = resolve_active_pr()
  if not pr then
    return notify_error(err)
  end

  local selected_file = resolve_file(file)
  if not selected_file then
    return notify_error("No file selected")
  end

  state.set_active_file(selected_file)
  local comments_ctx = build_line_comment_context(pr.number)

  local _, open_err = virtual_files.open_original(details, pr, selected_file, {
    line_comments = comments_ctx,
  })
  if open_err then
    return notify_error(open_err)
  end
end

function M.open_modified(file)
  local pr, details, err = resolve_active_pr()
  if not pr then
    return notify_error(err)
  end

  local selected_file = resolve_file(file)
  if not selected_file then
    return notify_error("No file selected")
  end

  state.set_active_file(selected_file)
  local comments_ctx = build_line_comment_context(pr.number)

  local _, open_err = virtual_files.open_modified(details, pr, selected_file, {
    line_comments = comments_ctx,
  })
  if open_err then
    return notify_error(open_err)
  end
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
  local comments_ctx = build_line_comment_context(pr.number)
  local diff_view = current_diff_view_preferences({
    mode = opts.view_mode,
    ignore_whitespace = opts.ignore_whitespace,
    render_whitespace = opts.render_whitespace,
    render_endlines = opts.render_endlines,
  })

  local _, open_err = virtual_files.open_diff(details, pr, selected_file, {
    line_comments = comments_ctx,
    view_mode = diff_view.mode,
    ignore_whitespace = diff_view.ignore_whitespace,
    render_whitespace = diff_view.render_whitespace,
    render_endlines = diff_view.render_endlines,
    new_tab = opts.new_tab,
  })
  if open_err then
    return false, open_err
  end

  do
    local ok_panel, panel = pcall(require, "gh-pr.diff_comments_panel")
    if ok_panel and type(panel.sync_for_diff) == "function" then
      pcall(panel.sync_for_diff, {
        pr = pr,
        details = details,
        comments_ctx = comments_ctx,
        pr_number = pr.number,
      })
    end
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

local function file_path(file)
  if type(file) ~= "table" then
    return nil
  end

  local path = file.path or file.filename
  if type(path) ~= "string" or path == "" then
    return nil
  end

  return path
end

local function current_file_path()
  if type(vim.b.gh_pr_path) == "string" and vim.b.gh_pr_path ~= "" then
    return vim.b.gh_pr_path
  end

  return file_path(state.get_active_file())
end

local function ordered_pr_files(details)
  local entries = {}
  for _, file in ipairs(type(details.files) == "table" and details.files or {}) do
    local path = file_path(file)
    if path then
      entries[#entries + 1] = {
        file = file,
        path = path,
      }
    end
  end
  return entries
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
      if kind == "base" or kind == "head" then
        local number = vim.b[bufnr].gh_pr_number
        local path = normalize_path(vim.b[bufnr].gh_pr_file_path or vim.b[bufnr].gh_pr_path)
        local same_number = type(current_number) ~= "number" or number == current_number
        local same_path = current_path == "" or path == "" or path == current_path

        if same_number and same_path then
          if kind == "base" and not base_win then
            base_win = winid
          elseif kind == "head" and not head_win then
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

local function file_matches_filter(entry, repository, pr_number, reviewed_only)
  if not reviewed_only then
    return true
  end

  if type(repository) ~= "string" or repository == "" then
    return false
  end

  return state.is_viewed(repository, pr_number, entry.path)
end

local function pick_next_file(details, pr, step, reviewed_only)
  local entries = ordered_pr_files(details)
  if #entries == 0 then
    return nil, "Current PR has no files"
  end

  local repository = reviewed_only and normalize_repository(details) or nil
  if reviewed_only and not repository then
    return nil, "Unable to resolve repository for reviewed files"
  end

  local current_path = current_file_path()
  local current_index = nil
  if current_path then
    for index, entry in ipairs(entries) do
      if entry.path == current_path then
        current_index = index
        break
      end
    end
  end

  if current_index == nil then
    current_index = step > 0 and 0 or 1
  end

  local total = #entries
  for offset = 1, total do
    local index = ((current_index - 1) + (offset * step)) % total + 1
    local entry = entries[index]
    if file_matches_filter(entry, repository, pr.number, reviewed_only) then
      return entry.file, nil
    end
  end

  if reviewed_only then
    return nil, "No reviewed files found in this PR"
  end

  return nil, "Unable to resolve next file in PR"
end

local function open_file_for_navigation(file)
  local diff_view = current_diff_view_preferences()
  M.open_diff(file, {
    new_tab = false,
    view_mode = diff_view.mode,
    ignore_whitespace = diff_view.ignore_whitespace,
    render_whitespace = diff_view.render_whitespace,
    render_endlines = diff_view.render_endlines,
  })
end

local function navigate_files(step, reviewed_only)
  local pr, details, err = resolve_active_pr()
  if not pr then
    return notify_error(err)
  end

  local target, target_err = pick_next_file(details, pr, step, reviewed_only)
  if not target then
    return notify_error(target_err)
  end

  open_file_for_navigation(target)
end

function M.next_file()
  navigate_files(1, false)
end

function M.prev_file()
  navigate_files(-1, false)
end

function M.next_reviewed_file()
  navigate_files(1, true)
end

function M.prev_reviewed_file()
  navigate_files(-1, true)
end

function M.checkout(number)
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

function M.mark_files_viewed(files, viewed, opts)
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

  for _, target in ipairs(targets) do
    if state.is_viewed(repository, pr.number, target.path) == viewed then
      unchanged_count = unchanged_count + 1
    else
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
    refresh_pr_sources_after_state_change()
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

function M.mark_file_viewed(file, viewed)
  local selected_file = resolve_file(file)
  if not selected_file then
    return notify_error("No file selected")
  end

  M.mark_files_viewed({ selected_file }, viewed)
end

function M.toggle_viewed()
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

    local viewed = state.toggle_viewed(repository, number, path)
    notify_info(string.format("Marked %s as %s", path, viewed and "viewed" or "unviewed"))
    refresh_pr_sources_after_state_change()
    return
  end

  M.mark_file_viewed(nil, nil)
end

function M.set_active_review(pr, details)
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

function M.activate_review(number, opts)
  opts = opts or {}
  local pr, details, err = resolve_active_pr(number, { refresh = opts.refresh == true })
  if not pr then
    return nil, nil, err
  end

  local ok, review_err = M.set_active_review(pr, details)
  if not ok then
    return nil, nil, review_err
  end

  return pr, details, nil
end

function M.toggle_review_tree()
  local ok, err = open_review_tree_from_plugin({ toggle = true })
  if not ok and err then
    notify_error(err)
  end
end

function M.toggle_diff_comments_panel()
  local kind = vim.b.gh_pr_file_kind
  if kind ~= "base" and kind ~= "head" and kind ~= "unified" then
    return notify_error("Current buffer is not a gh-pr diff buffer")
  end

  local pr, details, err = resolve_active_pr(vim.b.gh_pr_number, { refresh = false })
  if not pr then
    return notify_error(err)
  end

  local comments_ctx = build_line_comment_context(pr.number)
  local ok_panel, panel = pcall(require, "gh-pr.diff_comments_panel")
  if ok_panel and type(panel.toggle) == "function" then
    pcall(panel.toggle, {
      pr = pr,
      details = details,
      comments_ctx = comments_ctx,
      pr_number = pr.number,
    })
  end
end

function M.start_review(number)
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
    local stored, store_err = M.set_active_review(pr, details)
    if not stored then
      notify_error(store_err)
      return
    end

    state.set_active_pr(pr, details)
    local opened, open_err = open_review_tree_from_plugin({ toggle = false })
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

local function add_unique_path(target, seen, path)
  if type(path) ~= "string" or path == "" then
    return
  end
  if seen[path] then
    return
  end
  seen[path] = true
  target[#target + 1] = path
end

local function resolve_comment_path(file)
  if type(file) ~= "table" then
    return nil
  end

  local path = file.path or file.filename
  if type(path) ~= "string" or path == "" then
    return nil
  end

  return path
end

local function confirm_file_global_comment(pr_number, path, body, callback)
  local summary = "(empty message)"
  if type(body) == "string" and body ~= "" then
    local first_line = vim.split(body, "\n", { plain = true })[1] or ""
    first_line = vim.trim(first_line)
    if first_line ~= "" then
      summary = #first_line > 70 and (first_line:sub(1, 67) .. "...") or first_line
    end
  end
  vim.ui.select({ "confirm", "cancel" }, {
    prompt = string.format("Add pending file comment on PR #%d (%s)? Message: %s", pr_number, path, summary),
  }, function(choice)
    callback(choice == "confirm")
  end)
end

local function alternate_paths_for_file(file, fallback_path)
  local paths = {}
  local seen = {}
  add_unique_path(paths, seen, fallback_path)

  if type(file) == "table" then
    add_unique_path(paths, seen, file.path)
    add_unique_path(paths, seen, file.filename)
    add_unique_path(paths, seen, file.previousFilename)
    add_unique_path(paths, seen, file.previous_filename)
  end

  return paths
end

function M.add_file_global_comment(file)
  local pr, _, err = resolve_active_pr()
  if not pr then
    return notify_error(err)
  end

  local selected_file = resolve_file(file)
  local path = resolve_comment_path(selected_file)
  if type(path) ~= "string" or path == "" then
    return notify_error("No file selected for global comment")
  end

  comment_composer.open({
    title = string.format("PR #%d file comment (%s)", pr.number, path),
    filetype = "markdown",
    border = "rounded",
    initial_lines = { "" },
    enter = true,
    on_cancel = function()
      notify_info("Pending file comment cancelled")
    end,
    on_submit = function(text)
      local trimmed = vim.trim(type(text) == "string" and text or "")
      if trimmed == "" then
        notify_info("Pending file comment cancelled (empty message)")
        return
      end

      confirm_file_global_comment(pr.number, path, trimmed, function(confirmed)
        if not confirmed then
          notify_info("Pending file comment cancelled")
          return
        end

        local payload = string.format("File `%s`\n\n%s", path, trimmed)
        local ok, comment_err = pr_service.add_pending_review_comment(pr.number, payload, {
          append = true,
          separator = "\n\n---\n\n",
        })
        if not ok then
          notify_error(comment_err)
          return
        end

        notify_info(string.format("Pending file comment added for %s", path))
        refresh_pr_sources_after_state_change({ force = true })
      end)
    end,
  })
end

local function normalize_line_number(value)
  local number = tonumber(value)
  if not number then
    return nil
  end

  number = math.floor(number)
  if number < 1 then
    return nil
  end

  return number
end

local function normalize_line_range(start_line, line)
  local start_value = normalize_line_number(start_line)
  local line_value = normalize_line_number(line)
  if not line_value then
    return nil, nil
  end

  if start_value and start_value > line_value then
    start_value, line_value = line_value, start_value
  end

  if start_value == line_value then
    start_value = nil
  end

  return start_value, line_value
end

local function parse_patch_head_line_map(patch)
  if type(patch) ~= "string" or patch == "" then
    return nil
  end

  local line_map = {}
  local old_line = nil
  local new_line = nil
  local has_hunks = false

  for _, raw in ipairs(vim.split(patch, "\n", { plain = true, trimempty = false })) do
    local old_start, new_start = raw:match("^@@%s+%-(%d+),?%d*%s+%+(%d+),?%d*%s+@@")
    if old_start and new_start then
      old_line = tonumber(old_start)
      new_line = tonumber(new_start)
      has_hunks = true
      goto continue
    end

    if old_line and new_line then
      local prefix = raw:sub(1, 1)
      if prefix == " " then
        line_map[new_line] = line_map[new_line] or { kind = "context" }
        old_line = old_line + 1
        new_line = new_line + 1
      elseif prefix == "+" then
        line_map[new_line] = { kind = "add" }
        new_line = new_line + 1
      elseif prefix == "-" then
        old_line = old_line + 1
      elseif prefix == "\\" then
        -- "\ No newline at end of file"
      end
    end

    ::continue::
  end

  if not has_hunks then
    return nil
  end

  return line_map
end

local function resolve_inline_patch(pr_number, file, path)
  local patch = type(file) == "table" and type(file.patch) == "string" and file.patch or ""
  if patch ~= "" then
    return patch, nil
  end

  local fetched, patch_err = pr_service.fetch_patch_for_file(pr_number, path)
  if fetched and fetched ~= "" then
    return fetched, nil
  end

  return nil, patch_err or "No textual patch available"
end

local function resolve_inline_comment_path(details, selected_file)
  local path = resolve_comment_path(selected_file) or vim.b.gh_pr_file_path or vim.b.gh_pr_path
  if type(path) ~= "string" or path == "" then
    return nil
  end

  local canonical = resolve_canonical_file_path(details, path)
  if canonical == "" then
    return path
  end

  return canonical
end

local function resolve_requested_inline_range(opts)
  local start_line, line = normalize_line_range(opts.start_line, opts.line)
  if not line then
    line = normalize_line_number(vim.api.nvim_win_get_cursor(0)[1])
  end
  if not line then
    return nil, nil
  end

  return normalize_line_range(start_line, line)
end

local function validate_head_inline_target(pr_number, selected_file, path, start_line, line)
  local patch, patch_err = resolve_inline_patch(pr_number, selected_file, path)
  if not patch then
    local reason = patch_err and tostring(patch_err) or "No textual patch available"
    return nil, "No se puede comentar esta ubicación: " .. reason
  end

  local head_line_map = parse_patch_head_line_map(patch)
  if type(head_line_map) ~= "table" or vim.tbl_isempty(head_line_map) then
    return nil, "No se puede comentar esta ubicación: el archivo no tiene hunks válidos en el diff."
  end

  local first = start_line or line
  for current = first, line do
    if not head_line_map[current] then
      return nil, "No se puede comentar fuera del alcance de los cambios del archivo en el diff."
    end
  end

  return {
    path = path,
    start_line = start_line,
    line = line,
    side = "RIGHT",
    start_side = "RIGHT",
  }, nil
end

local function validate_added_inline_target(path, start_line, line)
  local bufnr = vim.api.nvim_get_current_buf()
  local max_line = vim.api.nvim_buf_line_count(bufnr)
  if type(max_line) ~= "number" or max_line < 1 then
    return nil, "No se pudo resolver el archivo para comentar."
  end

  local first = start_line or line
  if first < 1 or line < 1 or first > max_line or line > max_line then
    return nil, "El rango seleccionado está fuera del archivo."
  end

  return {
    path = path,
    start_line = start_line,
    line = line,
    side = "RIGHT",
    start_side = "RIGHT",
  }, nil
end

local function validate_unified_inline_target(path, start_render_line, end_render_line)
  local unified_map = vim.b.gh_pr_unified_line_map
  if type(unified_map) ~= "table" or vim.tbl_isempty(unified_map) then
    return nil, "No se pudo validar la selección en modo unified. Refrescá el diff con R."
  end

  local first = start_render_line or end_render_line
  local mapped_start = nil
  local mapped_end = nil
  local previous_head_line = nil

  for render_line = first, end_render_line do
    local entry = unified_map[render_line]
    if type(entry) ~= "table" then
      return nil, "No se puede comentar fuera del alcance de los cambios del archivo en el diff."
    end

    if entry.kind ~= "add" then
      return nil, "En modo unified solo se puede comentar sobre líneas agregadas (+) del diff."
    end

    local head_line = normalize_line_number(entry.head_line)
    if not head_line then
      return nil, "No se pudo resolver la línea destino del comentario en el diff."
    end

    if previous_head_line and head_line ~= (previous_head_line + 1) then
      return nil, "El rango seleccionado no es continuo en líneas agregadas (+) del diff."
    end

    previous_head_line = head_line
    mapped_start = mapped_start or head_line
    mapped_end = head_line
  end

  local start_line, line = normalize_line_range(mapped_start, mapped_end)
  if not line then
    return nil, "No se pudo resolver la línea destino del comentario en el diff."
  end

  return {
    path = path,
    start_line = start_line,
    line = line,
    side = "RIGHT",
    start_side = "RIGHT",
  }, nil
end

local function resolve_inline_comment_target(pr, details, selected_file, opts)
  local kind = type(vim.b.gh_pr_file_kind) == "string" and vim.b.gh_pr_file_kind or ""
  if kind ~= "head" and kind ~= "unified" then
    return nil, "Inline comments solo están disponibles en MODIFIED (head) o unified."
  end

  local path = resolve_inline_comment_path(details, selected_file)
  if type(path) ~= "string" or path == "" then
    return nil, "Unable to resolve file path for inline comment"
  end

  local start_line, line = resolve_requested_inline_range(opts or {})
  if not line then
    return nil, "Unable to resolve target line for inline comment"
  end

  if kind == "unified" then
    return validate_unified_inline_target(path, start_line, line)
  end

  local file_mode = type(vim.b.gh_pr_file_mode) == "string" and vim.b.gh_pr_file_mode or ""
  if file_mode == "added_single" then
    return validate_added_inline_target(path, start_line, line)
  end

  return validate_head_inline_target(pr.number, selected_file, path, start_line, line)
end

local function visual_line_range()
  local start_pos = vim.fn.getpos("'<")
  local end_pos = vim.fn.getpos("'>")
  local start_line = normalize_line_number(start_pos[2])
  local end_line = normalize_line_number(end_pos[2])
  if not start_line or not end_line then
    return nil, nil
  end
  return normalize_line_range(start_line, end_line)
end

local function leave_visual_mode()
  local esc = vim.api.nvim_replace_termcodes("<Esc>", true, false, true)
  vim.api.nvim_feedkeys(esc, "nx", false)
end

local function refresh_line_comments_for_pr(pr_number, details)
  local context = build_line_comment_context(pr_number)
  if not context then
    return
  end

  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_is_loaded(bufnr) then
      local buffer_pr = vim.b[bufnr].gh_pr_number
      local kind = vim.b[bufnr].gh_pr_file_kind
      local file_path = vim.b[bufnr].gh_pr_path

      if buffer_pr == pr_number and (kind == "base" or kind == "head") and type(file_path) == "string" and file_path ~= "" then
        local side = kind == "base" and "base" or "head"
        local file = find_file_in_details(details, file_path)
        line_comments.attach_to_buffer(bufnr, {
          index = context.index,
          side = side,
          file_path = file_path,
          alternate_paths = alternate_paths_for_file(file, file_path),
          keymap = context.keymap,
          signs = context.signs,
          max_popup_width = context.max_popup_width,
          max_popup_height = context.max_popup_height,
        })
      end
    end
  end
end

local function summarize_review_body(body)
  local raw = type(body) == "string" and body or ""
  if raw == "" then
    return "(empty message)"
  end

  local first_line = vim.split(raw, "\n", { plain = true })[1] or ""
  first_line = vim.trim(first_line)
  if first_line == "" then
    return "(empty message)"
  end
  if #first_line > 70 then
    return first_line:sub(1, 67) .. "..."
  end
  return first_line
end

local function confirm_inline_comment(pr_number, path, start_line, line, body, callback, opts)
  opts = type(opts) == "table" and opts or {}
  local location
  if start_line then
    location = string.format("%s:%d-%d", path, start_line, line)
  else
    location = string.format("%s:%d", path, line)
  end

  local action_label = type(opts.action_label) == "string" and vim.trim(opts.action_label) or ""
  if action_label == "" then
    action_label = "Create inline comment"
  end

  local prompt = string.format(
    "%s on PR #%d at %s? Message: %s",
    action_label,
    pr_number,
    location,
    summarize_review_body(body)
  )

  vim.ui.select({ "confirm", "cancel" }, {
    prompt = prompt,
  }, function(choice)
    callback(choice == "confirm")
  end)
end

function M._open_inline_comment_composer(pr, details, target, opts)
  opts = type(opts) == "table" and opts or {}
  local title = type(opts.title) == "string" and opts.title ~= ""
      and opts.title
    or string.format("PR #%d inline comment", pr.number)
  local initial_lines = type(opts.initial_lines) == "table" and opts.initial_lines or { "" }
  local cancel_message = type(opts.cancel_message) == "string" and opts.cancel_message ~= ""
      and opts.cancel_message
    or "Inline comment cancelled"
  local empty_cancel_message = type(opts.empty_cancel_message) == "string" and opts.empty_cancel_message ~= ""
      and opts.empty_cancel_message
    or "Inline comment cancelled (empty message)"
  local success_message = type(opts.success_message) == "string" and opts.success_message ~= ""
      and opts.success_message
    or string.format("Inline comment added to pending review on %s", target.path)
  local confirm_action_label = type(opts.confirm_action_label) == "string" and opts.confirm_action_label ~= ""
      and opts.confirm_action_label
    or "Create inline comment"
  local composer_filetype = type(opts.filetype) == "string" and opts.filetype ~= "" and opts.filetype or "markdown"

  comment_composer.open({
    title = title,
    filetype = composer_filetype,
    border = "rounded",
    initial_lines = initial_lines,
    enter = true,
    on_cancel = function()
      notify_info(cancel_message)
    end,
    on_submit = function(text)
      if vim.trim(text) == "" then
        notify_info(empty_cancel_message)
        return
      end

      confirm_inline_comment(pr.number, target.path, target.start_line, target.line, text, function(confirmed)
        if not confirmed then
          notify_info(cancel_message)
          return
        end

        local ok, comment_err = pr_service.add_pending_inline_comment(pr.number, {
          path = target.path,
          body = text,
          line = target.line,
          start_line = target.start_line,
          side = target.side,
          start_side = target.start_side,
        })
        if not ok then
          notify_error(comment_err)
          return
        end

        notify_info(success_message)
        refresh_line_comments_for_pr(pr.number, details)
      end, {
        action_label = confirm_action_label,
      })
    end,
  })
end

function M.add_inline_comment(opts)
  opts = type(opts) == "table" and opts or {}

  local pr, details, err = resolve_active_pr()
  if not pr then
    return notify_error(err)
  end

  local selected_file = resolve_file(opts.file)
  local target, target_err = resolve_inline_comment_target(pr, details, selected_file, opts)
  if not target then
    return notify_error(target_err)
  end

  M._open_inline_comment_composer(pr, details, target, {
    title = string.format("PR #%d inline comment", pr.number),
  })
end

function M.add_inline_comment_visual()
  local start_line, line = visual_line_range()
  leave_visual_mode()
  if not line then
    return notify_error("Unable to resolve selected range for inline comment")
  end

  M.add_inline_comment({
    start_line = start_line,
    line = line,
  })
end

function M._resolve_inline_selection_lines(opts)
  opts = type(opts) == "table" and opts or {}
  local start_line, line = resolve_requested_inline_range(opts)
  if not line then
    return nil, "Unable to resolve selected range for inline suggestion"
  end

  local first = start_line or line
  local last = line
  if first > last then
    first, last = last, first
  end

  local bufnr = vim.api.nvim_get_current_buf()
  local max_line = vim.api.nvim_buf_line_count(bufnr)
  if first < 1 or last < 1 or first > max_line or last > max_line then
    return nil, "Selected range for inline suggestion is outside this buffer"
  end

  local lines = vim.api.nvim_buf_get_lines(bufnr, first - 1, last, false)
  local kind = type(vim.b.gh_pr_file_kind) == "string" and vim.b.gh_pr_file_kind or ""
  for index, raw in ipairs(lines) do
    local text = type(raw) == "string" and raw:gsub("\r$", "") or ""
    if kind == "unified" then
      if vim.startswith(text, "+ ") then
        text = text:sub(3)
      elseif vim.startswith(text, "  ") or vim.startswith(text, "- ") then
        text = text:sub(3)
      end
    end
    lines[index] = text
  end

  if vim.tbl_isempty(lines) then
    lines = { "" }
  end

  return lines, nil
end

function M._build_suggestion_initial_lines(selected_lines)
  local body = type(selected_lines) == "table" and selected_lines or { "" }
  if vim.tbl_isempty(body) then
    body = { "" }
  end

  local initial = { "```suggestion" }
  for _, line in ipairs(body) do
    initial[#initial + 1] = type(line) == "string" and line or ""
  end
  initial[#initial + 1] = "```"
  return initial
end

function M.add_inline_suggestion(opts)
  opts = type(opts) == "table" and opts or {}

  local pr, details, err = resolve_active_pr()
  if not pr then
    return notify_error(err)
  end

  local selected_lines, selection_err = M._resolve_inline_selection_lines(opts)
  if not selected_lines then
    return notify_error(selection_err)
  end

  local selected_file = resolve_file(opts.file)
  local target, target_err = resolve_inline_comment_target(pr, details, selected_file, opts)
  if not target then
    return notify_error(target_err)
  end

  M._open_inline_comment_composer(pr, details, target, {
    title = string.format("PR #%d inline suggestion", pr.number),
    filetype = "text",
    initial_lines = M._build_suggestion_initial_lines(selected_lines),
    cancel_message = "Inline suggestion cancelled",
    empty_cancel_message = "Inline suggestion cancelled (empty message)",
    success_message = string.format("Inline suggestion added to pending review on %s", target.path),
    confirm_action_label = "Create inline suggestion",
  })
end

function M.add_inline_suggestion_visual()
  local start_line, line = visual_line_range()
  leave_visual_mode()
  if not line then
    return notify_error("Unable to resolve selected range for inline suggestion")
  end

  M.add_inline_suggestion({
    start_line = start_line,
    line = line,
  })
end

local function prompt_review_body(default_body, callback)
  vim.ui.input({
    prompt = "Review message: ",
    default = default_body,
  }, function(input)
    if input == nil then
      callback("", true)
      return
    end
    callback(input, false)
  end)
end

local function review_event_label(event)
  local labels = {
    approve = "approve",
    request_changes = "request changes",
    comment = "comment",
  }

  return labels[event]
end

local function confirm_review_submission(event, pr_number, body, callback)
  local label = review_event_label(event) or event
  local prompt = string.format(
    "Submit %s review for PR #%d? Message: %s",
    label,
    pr_number,
    summarize_review_body(body)
  )

  vim.ui.select({ "confirm", "cancel" }, {
    prompt = prompt,
  }, function(choice)
    callback(choice == "confirm")
  end)
end

function M.review(event)
  local pr, _, err = resolve_active_pr()
  if not pr then
    return notify_error(err)
  end

  local label = review_event_label(event)
  if not label then
    return notify_error("Unsupported review event")
  end

  local defaults = {
    approve = "",
    request_changes = "Requested changes from Neovim",
    comment = "Comment from Neovim",
  }

  prompt_review_body(defaults[event] or "", function(body, input_cancelled)
    if input_cancelled then
      notify_info("Review submission cancelled")
      return
    end

    confirm_review_submission(event, pr.number, body, function(confirmed)
      if not confirmed then
        notify_info("Review submission cancelled")
        return
      end

      local ok, review_err = pr_service.review(pr.number, event, body)
      if not ok then
        notify_error(review_err)
        return
      end

      notify_info(string.format("%s review submitted for PR #%d", label:gsub("^%l", string.upper), pr.number))
    end)
  end)
end

function M.comment_pr()
  local pr, _, err = resolve_active_pr()
  if not pr then
    return notify_error(err)
  end

  comment_composer.open({
    title = string.format("PR #%d comment", pr.number),
    filetype = "markdown",
    border = "rounded",
    initial_lines = { "" },
    enter = true,
    on_cancel = function()
      notify_info("PR comment cancelled")
    end,
    on_submit = function(text)
      local message = vim.trim(type(text) == "string" and text or "")
      if message == "" then
        notify_info("PR comment cancelled (empty message)")
        return
      end

      local prompt = string.format("Publish PR comment on #%d? Message: %s", pr.number, summarize_review_body(message))
      vim.ui.select({ "confirm", "cancel" }, {
        prompt = prompt,
      }, function(choice)
        if choice ~= "confirm" then
          notify_info("PR comment cancelled")
          return
        end

        local ok, comment_err = pr_service.comment(pr.number, message)
        if not ok then
          notify_error(comment_err)
          return
        end

        notify_info(string.format("PR comment published on #%d", pr.number))
        refresh_pr_sources_after_state_change({ force = true })
      end)
    end,
  })
end

function M.submit_pending_review(event)
  local pr, details, err = resolve_active_pr()
  if not pr then
    return notify_error(err)
  end

  local label = review_event_label(event)
  if not label then
    return notify_error("Unsupported review event")
  end

  local defaults = {
    approve = "",
    request_changes = "Requested changes from Neovim",
    comment = "",
  }

  prompt_review_body(defaults[event] or "", function(body, input_cancelled)
    if input_cancelled then
      notify_info("Pending review submission cancelled")
      return
    end

    confirm_review_submission(event, pr.number, body, function(confirmed)
      if not confirmed then
        notify_info("Pending review submission cancelled")
        return
      end

      local ok, review_err = pr_service.submit_pending_review(pr.number, event, body)
      if not ok then
        notify_error(review_err)
        return
      end

      notify_info(string.format("Pending %s review submitted for PR #%d", label, pr.number))
      refresh_line_comments_for_pr(pr.number, details)
    end)
  end)
end

function M.submit_pending_comment_review()
  M.submit_pending_review("comment")
end

function M.submit_pending_approve_review()
  M.submit_pending_review("approve")
end

function M.submit_pending_request_changes_review()
  M.submit_pending_review("request_changes")
end

function M.discard_pending_review()
  local pr, _, err = resolve_active_pr()
  if not pr then
    return notify_error(err)
  end

  vim.ui.select({ "confirm", "cancel" }, {
    prompt = string.format("Discard pending review for PR #%d?", pr.number),
  }, function(choice)
    if choice ~= "confirm" then
      notify_info("Discard pending review cancelled")
      return
    end

    local ok, discard_err = pr_service.discard_pending_review(pr.number)
    if not ok then
      notify_error(discard_err)
      return
    end

    notify_info(string.format("Pending review discarded for PR #%d", pr.number))
  end)
end

function M.merge(method)
  local pr, _, err = resolve_active_pr()
  if not pr then
    return notify_error(err)
  end

  method = method or "merge"

  vim.ui.select({ "no", "yes" }, {
    prompt = "Delete branch after merge?",
  }, function(delete_choice)
    if not delete_choice then
      return
    end

    local ok, merge_err = pr_service.merge(pr.number, method, delete_choice == "yes")
    if not ok then
      notify_error(merge_err)
      return
    end

    notify_info(string.format("Merge requested for PR #%d", pr.number))
  end)
end

function M.next_change()
  if vim.wo.diff then
    vim.cmd("normal! ]c")
    return
  end

  if vim.b.gh_pr_file_kind ~= "unified" then
    return
  end

  local bufnr = vim.api.nvim_get_current_buf()
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  local cursor = vim.api.nvim_win_get_cursor(0)
  for line = cursor[1] + 1, line_count do
    local text = (vim.api.nvim_buf_get_lines(bufnr, line - 1, line, false)[1] or "")
    if vim.startswith(text, "+ ") or vim.startswith(text, "- ") then
      vim.api.nvim_win_set_cursor(0, { line, 0 })
      return
    end
  end
end

function M.prev_change()
  if vim.wo.diff then
    vim.cmd("normal! [c")
    return
  end

  if vim.b.gh_pr_file_kind ~= "unified" then
    return
  end

  local bufnr = vim.api.nvim_get_current_buf()
  local cursor = vim.api.nvim_win_get_cursor(0)
  for line = cursor[1] - 1, 1, -1 do
    local text = (vim.api.nvim_buf_get_lines(bufnr, line - 1, line, false)[1] or "")
    if vim.startswith(text, "+ ") or vim.startswith(text, "- ") then
      vim.api.nvim_win_set_cursor(0, { line, 0 })
      return
    end
  end
end

function M.toggle_diff_whitespace()
  local prefs = current_diff_view_preferences()
  prefs.ignore_whitespace = not prefs.ignore_whitespace
  prefs = persist_diff_view_preferences(prefs)

  local reopened = M.reopen_current_diff_with_preferences({
    new_tab = false,
  })
  if not reopened then
    return
  end
  notify_info(string.format("Diff whitespace: %s", prefs.ignore_whitespace and "ignored" or "strict"))
end

function M.toggle_diff_render_whitespace()
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

local function diff_shortcut_lines(bufnr)
  local kind = type(vim.b[bufnr].gh_pr_file_kind) == "string" and vim.b[bufnr].gh_pr_file_kind or "head"
  local file_mode = type(vim.b[bufnr].gh_pr_file_mode) == "string" and vim.b[bufnr].gh_pr_file_mode or ""
  local is_image = vim.b[bufnr].gh_pr_is_image == true
  local prefs = current_diff_view_preferences()
  local shortcuts = diff_view_shortcuts()
  local image_opts = image_diff_options()
  local image_default_action = resolve_image_default_action(image_opts)
  local configured_diff = (config.get() or {}).diff_view or {}
  local configured_whitespace = type(configured_diff.whitespace) == "table" and configured_diff.whitespace or {}
  local whitespace_tab = type(configured_whitespace.tab) == "string" and configured_whitespace.tab ~= ""
      and configured_whitespace.tab
    or ">-"
  local whitespace_space = type(configured_whitespace.space) == "string" and configured_whitespace.space ~= ""
      and configured_whitespace.space
    or "."

  local mode_label = prefs.mode
  if file_mode == "added_single" then
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
  if is_image then
    mode_label = mode_label .. " (image)"
  end

  local function add_shortcut(lines, key, description)
    if type(key) == "string" and key ~= "" then
      lines[#lines + 1] = shortcut_line(key, description)
    end
  end

  local lines = {
    "gh-pr diff shortcuts",
    "",
    "Diff render state",
    shortcut_line("mode", mode_label),
    shortcut_line("spaces", is_image and "n/a (image)" or (prefs.ignore_whitespace and "ignored" or "strict")),
    shortcut_line("render", is_image and "n/a (image)" or (prefs.render_whitespace and "visible" or "hidden")),
    shortcut_line("endline", is_image and "n/a (image)" or (prefs.render_endlines and "visible" or "hidden")),
    shortcut_line("tab", is_image and "n/a" or whitespace_tab),
    shortcut_line("space", is_image and "n/a" or whitespace_space),
    "",
    "General",
  }
  if is_image then
    lines[#lines + 1] = shortcut_line("-", "Line comments popup not available for image files")
  else
    add_shortcut(lines, shortcuts.line_comments_popup, kind == "unified" and "Not available in unified mode" or "Show line comments popup")
  end
  add_shortcut(lines, shortcuts.help, "Show this help")
  add_shortcut(lines, shortcuts.refresh, "Refresh current diff from GitHub")
  add_shortcut(lines, shortcuts.close_quick, "Quick close (or close head in 2-way diff)")
  add_shortcut(lines, shortcuts.close_all_open_review, "Close view(s) and open PR Review")
  add_shortcut(lines, shortcuts.toggle_comments_panel, "Toggle diff comments panel")

  if not is_image then
    add_shortcut(lines, shortcuts.toggle_render_whitespace, "Toggle leading/trailing space/tab symbols")
    add_shortcut(lines, shortcuts.toggle_render_endlines, "Toggle LF/CRLF endline markers")
  end

  if is_image then
    lines[#lines + 1] = shortcut_line("-", "Whitespace and diff layout toggles disabled for image files")
  elseif file_mode ~= "added_single" and file_mode ~= "removed_single" then
    add_shortcut(lines, shortcuts.toggle_whitespace, "Toggle whitespace changes")
    add_shortcut(lines, shortcuts.cycle_mode, "Cycle diff mode")
    add_shortcut(lines, shortcuts.set_vertical, "Set vertical split")
    add_shortcut(lines, shortcuts.set_horizontal, "Set horizontal split")
    add_shortcut(lines, shortcuts.set_unified, "Set unified mode")
  else
    lines[#lines + 1] = shortcut_line("-", "Diff layout toggles disabled for single-file mode")
  end

  if is_image then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Image fallback"
    add_shortcut(lines, shortcuts.image_default_action, string.format("Run default fallback action (%s)", image_action_label(image_default_action)))
    add_shortcut(lines, shortcuts.image_fallback_menu, "Open fallback actions menu")
    lines[#lines + 1] = shortcut_line("-", "Menu allows setting default action (`d`/`s`)")
  end

  lines[#lines + 1] = ""
  lines[#lines + 1] = "Navigation"
  if is_image then
    lines[#lines + 1] = shortcut_line("-", "Change navigation disabled for image files")
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

  if is_image then
    lines[#lines + 1] = shortcut_line(shortcuts.inline_comment, "Not available for image files")
    lines[#lines + 1] = shortcut_line(shortcuts.inline_suggestion, "Not available for image files")
  elseif kind == "head" and file_mode == "added_single" then
    lines[#lines + 1] = shortcut_line(shortcuts.inline_comment, "Create inline comment at cursor (any line)")
    lines[#lines + 1] = shortcut_line("Visual + " .. shortcuts.inline_comment, "Create inline comment on selected range")
    lines[#lines + 1] = shortcut_line(shortcuts.inline_suggestion, "Create inline suggestion at cursor (any line)")
    lines[#lines + 1] = shortcut_line("Visual + " .. shortcuts.inline_suggestion, "Create inline suggestion on selected range")
  elseif kind == "head" then
    lines[#lines + 1] = shortcut_line(shortcuts.inline_comment, "Create inline comment at cursor")
    lines[#lines + 1] = shortcut_line("Visual + " .. shortcuts.inline_comment, "Create inline comment on selected range")
    lines[#lines + 1] = shortcut_line(shortcuts.inline_suggestion, "Create inline suggestion at cursor")
    lines[#lines + 1] = shortcut_line("Visual + " .. shortcuts.inline_suggestion, "Create inline suggestion on selected range")
  elseif kind == "unified" then
    lines[#lines + 1] = shortcut_line(shortcuts.inline_comment, "Create inline comment on added (+) line")
    lines[#lines + 1] = shortcut_line("Visual + " .. shortcuts.inline_comment, "Create inline comment on added (+) range")
    lines[#lines + 1] = shortcut_line(shortcuts.inline_suggestion, "Create inline suggestion on added (+) line")
    lines[#lines + 1] = shortcut_line("Visual + " .. shortcuts.inline_suggestion, "Create inline suggestion on added (+) range")
  else
    lines[#lines + 1] = shortcut_line(shortcuts.inline_comment, "Only available on MODIFIED (head) or unified")
    lines[#lines + 1] = shortcut_line(shortcuts.inline_suggestion, "Only available on MODIFIED (head) or unified")
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

function M.current_viewed_state()
  if vim.b.gh_pr_file_kind == "patch" then
    return false
  end

  local path = vim.b.gh_pr_file_path or vim.b.gh_pr_path
  local number = vim.b.gh_pr_number
  local repository = vim.b.gh_pr_repo

  if type(path) == "string" and type(number) == "number" and type(repository) == "string" then
    local _, details = state.get_active_pr()
    if type(details) == "table" and tonumber(details.number) == number then
      path = resolve_canonical_file_path(details, path)
    else
      path = normalize_path(path)
    end

    return state.is_viewed(repository, number, path)
  end

  return false
end

return M

