local M = {}

local comment_composer = require("gh-pr.comment_composer")
local comment_popup = require("gh-pr.comment_popup")
local config = require("gh-pr.config")
local diff_actions = require("gh-pr.core.diff_actions")
local overview_actions = require("gh-pr.core.overview_actions")
local overview_edit_actions = require("gh-pr.core.overview_edit_actions")
local review_prefetch = require("gh-pr.core.review_prefetch")
local review_actions = require("gh-pr.core.review_actions")
local diff_shortcuts_config = require("gh-pr.diff_shortcuts")
local gh = require("gh-pr.gh")
local image_metadata = require("gh-pr.image_metadata")
local line_comments = require("gh-pr.line_comments")
local pr_service = require("gh-pr.pr_service")
local review_context = require("gh-pr.core.review_context")
local state = require("gh-pr.state")
local thread_popup = require("gh-pr.thread_popup")
local url_open = require("gh-pr.url_open")
local overview_edit_picker = require("gh-pr.ui.overview.edit_picker")
local codediff_integration = require("gh-pr.integrations.codediff")
local virtual_files = require("gh-pr.virtual_files")
local uv = vim.uv or vim.loop

local diff_backend_session = {
  virtual_fallback = nil,
  prompt_open = false,
}
local non_text_preview = {
  menu_state = nil,
}

local function normalize_repository(details)
  local repository = review_context.resolve_repository_full_name(details)
  if repository ~= "" then
    return repository
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

local function safe_string(value, fallback)
  if type(value) == "string" and value ~= "" then
    return value
  end
  return fallback or ""
end

local local_open_policy_values = {
  disabled = true,
  reveal_only = true,
  system = true,
}

local dangerous_local_open_extensions = {
  app = true,
  bat = true,
  cmd = true,
  com = true,
  command = true,
  cpl = true,
  desktop = true,
  exe = true,
  hta = true,
  inf = true,
  ins = true,
  isp = true,
  jar = true,
  js = true,
  jse = true,
  lnk = true,
  msc = true,
  msi = true,
  msp = true,
  mst = true,
  pif = true,
  ps1 = true,
  ps1xml = true,
  psd1 = true,
  psm1 = true,
  reg = true,
  scf = true,
  scr = true,
  sh = true,
  url = true,
  vb = true,
  vbe = true,
  vbs = true,
  wsf = true,
  wsh = true,
}

local function normalize_local_open_policy(value, fallback)
  local policy = type(value) == "string" and value:lower() or fallback or "disabled"
  if local_open_policy_values[policy] then
    return policy
  end
  return fallback or "disabled"
end

local function target_extension(target)
  local ext = type(target) == "string" and target:match("%.([^.\\/]+)$") or nil
  if type(ext) ~= "string" then
    return ""
  end
  return ext:lower()
end

local function effective_local_open_policy(policy, target)
  local normalized = normalize_local_open_policy(policy, "disabled")
  if normalized ~= "system" then
    return normalized
  end

  local ext = target_extension(target)
  if ext ~= "" and dangerous_local_open_extensions[ext] then
    return "reveal_only"
  end

  return normalized
end

local function local_open_action_label(policy, target)
  local effective = effective_local_open_policy(policy, target)
  if effective == "reveal_only" then
    return "reveal local"
  end
  return "open local"
end

local function local_open_action_phrase(policy, target)
  local effective = effective_local_open_policy(policy, target)
  if effective == "reveal_only" then
    return "reveal locally"
  end
  return "open locally"
end

local function codediff_debug_failures_enabled()
  local diff_view = ((config.get() or {}).diff_view or {})
  local debug = type(diff_view.debug) == "table" and diff_view.debug or {}
  return debug.codediff_failures == true
end

local function notify_codediff_debug(message)
  if not codediff_debug_failures_enabled() then
    return
  end

  local text = type(message) == "string" and vim.trim(message) or ""
  if text == "" then
    return
  end

  notify_warn("[gh-pr debug] " .. text)
end

local function using_virtual_diff_backend()
  return diff_backend_session.virtual_fallback == true
end

local function virtual_only_feature_message(feature)
  local label = type(feature) == "string" and vim.trim(feature) or "This action"
  if label == "" then
    label = "This action"
  end
  return string.format("%s is not available with codediff backend.", label)
end

local function require_virtual_diff_backend(feature)
  if using_virtual_diff_backend() then
    return true
  end

  notify_warn(virtual_only_feature_message(feature))
  return false
end

local function supports_interactive_select()
  return vim.ui ~= nil and type(vim.ui.select) == "function"
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

  local pending_review = nil
  local pending_err = nil
  local fetch_opts = {
    threads_first = 100,
    comments_first = 100,
  }
  local threads, thread_err

  if type(pr_service.fetch_review_threads_with_pending) == "function" then
    threads, thread_err = pr_service.fetch_review_threads_with_pending(pr_number, fetch_opts)
  else
    threads, thread_err = pr_service.fetch_review_threads(pr_number, fetch_opts)
    if threads and type(pr_service.fetch_pending_review_comments) == "function" then
      pending_review, pending_err = pr_service.fetch_pending_review_comments(pr_number)
      if pending_review and type(pr_service.merge_pending_review_comments) == "function" then
        threads = pr_service.merge_pending_review_comments(threads, pending_review)
      end
    end
  end

  if not threads then
    notify_warn("Unable to load line comments for this PR: " .. tostring(thread_err))
    return nil
  end

  if pending_err then
    notify_warn("Unable to load pending review comments for this PR: " .. tostring(pending_err))
  end

  local index = pr_service.build_line_comment_index(threads, {
    show_resolved = options.show_resolved,
    show_outdated = options.show_outdated,
  })

  return {
    index = index,
    threads = threads,
    pending_review = pending_review,
    keymap = options.keymap,
    signs = options.signs,
    max_popup_width = options.max_popup_width,
    max_popup_height = options.max_popup_height,
  }
end

local refresh_line_comments_for_pr
local remote_viewed_sync_inflight = {}

local function refresh_pr_sources_after_state_change(opts)
  opts = opts or {}
  local force = opts.force == true
  local registry = require("gh-pr.neotree.registry")

  local source = registry.get("gh_pr")
  if type(source) == "table" then
    local source_focused = type(source.is_focused) == "function" and source.is_focused() == true
    if type(source.request_refresh) == "function" then
      pcall(source.request_refresh, nil, {
        force = force,
        notify_error = false,
        refresh_context = {
          mode = source_focused and "ui-refresh" or "cache-only",
          reason = "state-change",
          notify = false,
        },
      })
    end
  end

  local review_source = registry.get("gh_pr_review")
  if type(review_source) == "table" then
    local review_focused = type(review_source.is_focused) == "function" and review_source.is_focused() == true
    if type(review_source.request_refresh) == "function" then
      pcall(review_source.request_refresh, nil, {
        force = force,
        notify_error = false,
        refresh_context = {
          mode = review_focused and "ui-refresh" or "cache-only",
          reason = "state-change",
          notify = false,
        },
      })
    end
  end
end

local function render_pr_sources_from_cache()
  local registry = require("gh-pr.neotree.registry")

  local source = registry.get("gh_pr")
  if type(source) == "table" and type(source.render_cached_states) == "function" then
    pcall(source.render_cached_states)
  end

  local review_source = registry.get("gh_pr_review")
  if type(review_source) == "table" and type(review_source.render_cached_states) == "function" then
    pcall(review_source.render_cached_states)
  end
end

local function refresh_diff_comments_panel_after_state_change()
  local ok_panel, panel = pcall(require, "gh-pr.diff_comments_panel")
  if not ok_panel or type(panel) ~= "table" then
    return
  end

  if type(panel.refresh_current_tab) == "function" then
    pcall(panel.refresh_current_tab, {
      force_fetch = true,
    })
  end
end

local function sync_remote_viewed_state_for_pr(pr_number, details, opts)
  opts = type(opts) == "table" and opts or {}
  if type(pr_service.fetch_viewed_files_async) ~= "function" then
    return false
  end

  local number = tonumber(pr_number) or tonumber(type(details) == "table" and details.number or nil)
  local repository = type(details) == "table" and normalize_repository(details) or nil
  if not number or type(repository) ~= "string" or repository == "" then
    return false
  end

  local key = string.format("%s#%d", repository, number)
  if remote_viewed_sync_inflight[key] then
    return false
  end
  remote_viewed_sync_inflight[key] = true

  pr_service.fetch_viewed_files_async(number, opts.fetch or {}, function(result, err)
    remote_viewed_sync_inflight[key] = nil
    if not result or type(result.files) ~= "table" then
      if opts.notify_error == true and type(err) == "string" and err ~= "" then
        notify_warn("Unable to sync GitHub viewed state: " .. err)
      end
      return
    end

    state.replace_remote_viewed(repository, number, result.files)
    render_pr_sources_from_cache()
  end)

  return true
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
  return review_context.normalize_path(path)
end

local function find_file_in_details(details, path)
  return review_context.find_file(details, path)
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
  return review_context.resolve_canonical_file_path(details, path)
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

non_text_preview.action_labels = {
  metadata = "Show metadata/actions in buffer",
  open_local_current = "Open current revision locally",
  open_local_both = "Open both revisions locally",
  open_github = "Open GitHub PR file view",
}

non_text_preview.reveal_action_labels = {
  open_local_current = "Reveal current revision locally",
  open_local_both = "Reveal both revisions locally",
}

non_text_preview.action_order = {
  "open_local_current",
  "open_local_both",
  "open_github",
  "metadata",
}

function non_text_preview.is_valid_image_action(action)
  return action == "metadata" or action == "open_local_current" or action == "open_local_both" or action == "open_github"
end

function non_text_preview.normalize_image_action(action, fallback)
  local value = type(action) == "string" and action:lower() or ""
  if non_text_preview.is_valid_image_action(value) then
    return value
  end
  local default_value = type(fallback) == "string" and fallback:lower() or "metadata"
  if non_text_preview.is_valid_image_action(default_value) then
    return default_value
  end
  return "metadata"
end

function non_text_preview.action_label(action, opts)
  local normalized = non_text_preview.normalize_image_action(action, "metadata")
  if normalized == "open_local_current" or normalized == "open_local_both" then
    local policy = nil
    if type(opts) == "table" then
      policy = opts.fallback_open_local or opts.open_local
    end
    local normalized_policy = normalize_local_open_policy(policy, "disabled")
    if normalized_policy == "disabled" then
      return (non_text_preview.action_labels[normalized] or normalized) .. " (disabled)"
    end
    if normalized_policy == "reveal_only" then
      return non_text_preview.reveal_action_labels[normalized] or non_text_preview.action_labels[normalized] or normalized
    end
  end
  return non_text_preview.action_labels[normalized] or normalized
end

function non_text_preview.image_diff_options()
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
    fallback_default_action = non_text_preview.normalize_image_action(images.fallback_default_action, "metadata"),
    fallback_menu_keymap = type(images.fallback_menu_keymap) == "string" and images.fallback_menu_keymap or "gf",
    fallback_open_local = normalize_local_open_policy(images.fallback_open_local, "disabled"),
    fallback_github_target = type(images.fallback_github_target) == "string"
        and images.fallback_github_target:lower()
      or "pr_files",
    metadata_resolution_strategy = type(images.metadata_resolution_strategy) == "string"
        and images.metadata_resolution_strategy:lower()
      or "hybrid",
    metadata_external_command = external_command,
  }
end

function non_text_preview.options()
  local diff_view = (config.get() or {}).diff_view or {}
  local non_text = type(diff_view.non_text) == "table" and diff_view.non_text or {}
  return {
    enabled = non_text.enabled ~= false,
    auto_preview = non_text.auto_preview ~= false,
    show_metadata = non_text.show_metadata ~= false,
  }
end

function non_text_preview.resolve_default_action(images_cfg)
  local fallback = type(images_cfg) == "table" and images_cfg.fallback_default_action or "metadata"
  local action = non_text_preview.normalize_image_action(fallback, "metadata")
  if type(state.get_image_prefs) == "function" then
    local prefs = state.get_image_prefs()
    if type(prefs) == "table" then
      action = non_text_preview.normalize_image_action(prefs.fallback_default_action, action)
    end
  end
  if (action == "open_local_current" or action == "open_local_both")
    and normalize_local_open_policy(type(images_cfg) == "table" and images_cfg.fallback_open_local or nil, "disabled") == "disabled" then
    return "metadata"
  end
  return action
end

function non_text_preview.persist_default_action(action)
  local normalized = non_text_preview.normalize_image_action(action, "metadata")
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

function non_text_preview.classify_target(file)
  local non_text = non_text_preview.options()
  if non_text.enabled ~= true or non_text.auto_preview ~= true then
    return "text"
  end
  if type(virtual_files.classify_file) ~= "function" then
    return "text"
  end
  local kind = virtual_files.classify_file(file)
  if kind == "image" or kind == "asset" then
    return kind
  end
  return "text"
end

function non_text_preview.file_uses_non_text_preview(file)
  local kind = non_text_preview.classify_target(file)
  return kind == "image" or kind == "asset", kind
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

function non_text_preview.current_side(ctx)
  local side = type(ctx.side) == "string" and ctx.side or ""
  if side == "base" or side == "head" then
    return side
  end
  if ctx.status == "removed" then
    return "base"
  end
  return "head"
end

function non_text_preview.side_present_for_status(status, side)
  if status == "added" and side == "base" then
    return false
  end
  if status == "removed" and side == "head" then
    return false
  end
  return true
end

function non_text_preview.path_for_side(ctx, side)
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

function non_text_preview.resolve_side_repository(details, side, fallback_full_name)
  local base_repo = extract_repo_info(type(details) == "table" and details.baseRepository or nil)
  local head_repo = extract_repo_info(type(details) == "table" and details.headRepository or nil) or base_repo
  if side == "base" then
    return base_repo or head_repo or parse_repo_full_name(fallback_full_name)
  end
  return head_repo or base_repo or parse_repo_full_name(fallback_full_name)
end

local function backend_error_message(err, fallback)
  if type(err) == "table" then
    local message = type(err.message) == "string" and err.message or ""
    if message ~= "" then
      return message
    end
    local nested = type(err.error) == "string" and err.error or ""
    if nested ~= "" then
      return nested
    end
    return fallback
  end

  if type(err) == "string" and err ~= "" then
    return err
  end

  return fallback
end

local function prompt_codediff_virtual_fallback_once(reason, open_virtual)
  local message = type(reason) == "string" and reason ~= "" and reason
    or "codediff backend is unavailable"

  if diff_backend_session.virtual_fallback ~= nil then
    return false
  end

  if not supports_interactive_select() then
    diff_backend_session.virtual_fallback = false
    notify_codediff_debug("fallback prompt unavailable in this context")
    notify_error(message .. " (fallback prompt unavailable in this context)")
    return false
  end

  if diff_backend_session.prompt_open then
    notify_codediff_debug("fallback prompt already open; waiting existing decision")
    notify_warn("codediff backend decision is already pending in another prompt.")
    return true
  end

  diff_backend_session.prompt_open = true
  notify_codediff_debug("opening fallback prompt for codediff failure")
  local use_fallback_label = "Use virtual fallback this session"
  local no_fallback_label = "Do not use fallback"
  vim.ui.select({ use_fallback_label, no_fallback_label }, {
    prompt = "codediff failed to open. Choose backend for this session:",
  }, function(choice)
    diff_backend_session.prompt_open = false

    local use_fallback = choice == use_fallback_label
    diff_backend_session.virtual_fallback = use_fallback
    if use_fallback then
      notify_codediff_debug("fallback prompt accepted; using virtual fallback (prompt)")
      notify_warn("Using legacy virtual diff backend for this session.")
      local ok_virtual, virtual_err = open_virtual()
      if not ok_virtual and virtual_err ~= nil then
        notify_codediff_debug(
          "virtual fallback failed after prompt accept: "
            .. backend_error_message(virtual_err, "virtual fallback failed")
        )
      end
      if not ok_virtual and type(virtual_err) == "string" and virtual_err ~= "" then
        notify_error(virtual_err)
      end
      return
    end

    if choice == nil then
      notify_codediff_debug("fallback prompt cancelled")
      notify_error("codediff backend failed and fallback selection was cancelled.")
      return
    end

    notify_codediff_debug("fallback prompt rejected")
    notify_error(message)
  end)

  return true
end

local function open_diff_with_forced_backend(opts)
  opts = type(opts) == "table" and opts or {}
  local open_primary = type(opts.open_primary) == "function" and opts.open_primary
    or (type(opts.open_codediff) == "function" and opts.open_codediff or nil)
    or function()
      return nil, "Missing codediff opener"
    end
  local open_virtual = type(opts.open_virtual) == "function" and opts.open_virtual or function()
    return nil, "Missing virtual fallback opener"
  end

  if using_virtual_diff_backend() then
    return open_virtual()
  end

  local ok_primary, primary_err = open_primary()
  if ok_primary then
    return true, nil
  end

  local primary_message = backend_error_message(primary_err, "codediff backend failed")

  if type(primary_err) == "table" and primary_err.requires_virtual == true then
    notify_codediff_debug("codediff failed: " .. primary_message)
    notify_codediff_debug("using virtual fallback (auto)")
    local ok_virtual, virtual_err = open_virtual()
    if not ok_virtual then
      notify_codediff_debug(
        "virtual fallback failed after auto-fallback: "
          .. backend_error_message(virtual_err, "virtual fallback failed")
      )
    end
    return ok_virtual, virtual_err
  end

  notify_codediff_debug("codediff failed: " .. primary_message)

  if diff_backend_session.virtual_fallback == false then
    notify_codediff_debug("fallback disabled for this session")
    return nil, primary_message
  end

  local prompted = prompt_codediff_virtual_fallback_once(primary_message, open_virtual)
  if prompted then
    return false, "pending"
  end

  if using_virtual_diff_backend() then
    notify_codediff_debug("using virtual fallback (session)")
    local ok_virtual, virtual_err = open_virtual()
    if not ok_virtual then
      notify_codediff_debug(
        "virtual fallback failed after session decision: "
          .. backend_error_message(virtual_err, "virtual fallback failed")
      )
    end
    return ok_virtual, virtual_err
  end

  notify_codediff_debug("codediff failure ended without fallback")
  return nil, primary_message
end

function non_text_preview.resolve_buffer_context(bufnr)
  bufnr = type(bufnr) == "number" and bufnr or vim.api.nvim_get_current_buf()
  if not is_valid_buf(bufnr) then
    return nil, "Invalid buffer"
  end
  local is_image = vim.b[bufnr].gh_pr_is_image == true
  local is_non_text = vim.b[bufnr].gh_pr_is_non_text == true or is_image
  if not is_non_text then
    return nil, "Current buffer is not a non-text diff buffer"
  end

  local number = tonumber(vim.b[bufnr].gh_pr_number)
  if not number then
    return nil, "Unable to resolve pull request number for non-text buffer"
  end

  local preview = type(vim.b[bufnr].gh_pr_asset_preview) == "table" and vim.deepcopy(vim.b[bufnr].gh_pr_asset_preview) or {}
  local asset_kind = type(preview.asset_kind) == "string" and preview.asset_kind
    or (type(vim.b[bufnr].gh_pr_asset_kind) == "string" and vim.b[bufnr].gh_pr_asset_kind or (is_image and "image" or "binary"))
  if asset_kind ~= "image" and asset_kind ~= "binary" then
    asset_kind = is_image and "image" or "binary"
  end

  local status = type(vim.b[bufnr].gh_pr_asset_status) == "string"
      and vim.b[bufnr].gh_pr_asset_status:lower()
    or (type(vim.b[bufnr].gh_pr_image_status) == "string" and vim.b[bufnr].gh_pr_image_status:lower() or "")
  local current_side = type(vim.b[bufnr].gh_pr_asset_side) == "string" and vim.b[bufnr].gh_pr_asset_side
    or (type(vim.b[bufnr].gh_pr_image_side) == "string" and vim.b[bufnr].gh_pr_image_side or "")

  local function ensure_preview_side(side)
    local entry = type(preview[side]) == "table" and preview[side] or {}
    local image_path = side == "base" and vim.b[bufnr].gh_pr_image_base_path or vim.b[bufnr].gh_pr_image_head_path
    local default_path = normalize_path(type(entry.path) == "string" and entry.path ~= "" and entry.path or image_path or "")
    local present = entry.present
    if type(present) ~= "boolean" then
      present = non_text_preview.side_present_for_status(status, side)
    end
    entry.side = side
    entry.present = present
    entry.path = default_path
    entry.size = tonumber(entry.size) or ((side == current_side) and (tonumber(vim.b[bufnr].gh_pr_image_size) or 0) or 0)
    entry.sha = type(entry.sha) == "string" and entry.sha or ((side == current_side) and safe_string(vim.b[bufnr].gh_pr_image_sha) or "")
    entry.ext = type(entry.ext) == "string" and entry.ext or ((side == current_side) and safe_string(vim.b[bufnr].gh_pr_image_ext):lower() or "")
    entry.cache_path = type(entry.cache_path) == "string" and entry.cache_path or ((side == current_side) and safe_string(vim.b[bufnr].gh_pr_image_cache_path) or "")
    preview[side] = entry
    return entry
  end

  local base_entry = ensure_preview_side("base")
  local head_entry = ensure_preview_side("head")

  return {
    bufnr = bufnr,
    number = number,
    asset_kind = asset_kind,
    is_image = asset_kind == "image",
    is_non_text = true,
    repo = type(vim.b[bufnr].gh_pr_repo) == "string" and vim.b[bufnr].gh_pr_repo or "",
    kind = type(vim.b[bufnr].gh_pr_file_kind) == "string" and vim.b[bufnr].gh_pr_file_kind or "",
    file_path = normalize_path(vim.b[bufnr].gh_pr_file_path or ""),
    path = normalize_path(vim.b[bufnr].gh_pr_path or ""),
    side = current_side,
    status = status,
    reason = type(vim.b[bufnr].gh_pr_image_reason) == "string" and vim.b[bufnr].gh_pr_image_reason
      or (type(preview.reason) == "string" and preview.reason or ""),
    pr_url = trim_trailing_slash(vim.b[bufnr].gh_pr_pr_url),
    pr_files_url = trim_trailing_slash(vim.b[bufnr].gh_pr_pr_files_url),
    base_path = base_entry.path,
    head_path = head_entry.path,
    cache_path = type(vim.b[bufnr].gh_pr_image_cache_path) == "string" and vim.b[bufnr].gh_pr_image_cache_path or "",
    size = tonumber(vim.b[bufnr].gh_pr_image_size) or 0,
    sha = type(vim.b[bufnr].gh_pr_image_sha) == "string" and vim.b[bufnr].gh_pr_image_sha or "",
    ext = type(vim.b[bufnr].gh_pr_image_ext) == "string" and vim.b[bufnr].gh_pr_image_ext:lower() or "",
    preview = preview,
  }, nil
end

function non_text_preview.resolve_image_buffer_context(bufnr)
  local ctx, err = non_text_preview.resolve_buffer_context(bufnr)
  if not ctx then
    return nil, err
  end
  if ctx.asset_kind ~= "image" then
    return nil, "Current buffer is not an image diff buffer"
  end
  return ctx, nil
end

function non_text_preview.find_cached_image_asset(ctx, side)
  if side == ctx.side and file_readable(ctx.cache_path) then
    return {
      side = side,
      path = non_text_preview.path_for_side(ctx, side),
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

function non_text_preview.fetch_and_cache_image_asset(details, ctx, side, images_cfg)
  local side_path = non_text_preview.path_for_side(ctx, side)
  if side_path == "" then
    return nil, string.format("Missing %s image path", side)
  end

  local side_ref = side == "base" and details.baseRefName or details.headRefName
  if type(side_ref) ~= "string" or side_ref == "" then
    return nil, string.format("Missing %s ref for pull request", side)
  end

  local repository = non_text_preview.resolve_side_repository(details, side, ctx.repo)
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

function non_text_preview.ensure_image_side_asset(ctx, side, images_cfg)
  if not non_text_preview.side_present_for_status(ctx.status, side) then
    return {
      side = side,
      present = false,
      path = non_text_preview.path_for_side(ctx, side),
    }, nil
  end

  local cached = non_text_preview.find_cached_image_asset(ctx, side)
  if cached then
    cached.present = true
    return cached, nil
  end

  local _, details, details_err = resolve_active_pr(ctx.number, { refresh = false })
  if not details then
    return nil, details_err
  end

  local fetched, fetch_err = non_text_preview.fetch_and_cache_image_asset(details, ctx, side, images_cfg)
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

function non_text_preview.cached_binary_side_asset(ctx, side)
  local entry = type(ctx.preview) == "table" and type(ctx.preview[side]) == "table" and ctx.preview[side] or nil
  if entry and file_readable(entry.cache_path) then
    return {
      side = side,
      present = entry.present ~= false,
      path = entry.path,
      cache_path = entry.cache_path,
      size = tonumber(entry.size) or 0,
      sha = type(entry.sha) == "string" and entry.sha or "",
      ext = type(entry.ext) == "string" and entry.ext or "",
    }
  end

  local target_path = normalize_path(ctx.file_path ~= "" and ctx.file_path or ctx.path)
  for _, candidate in ipairs(vim.api.nvim_list_bufs()) do
    if candidate ~= ctx.bufnr
      and is_valid_buf(candidate)
      and vim.b[candidate].gh_pr_is_non_text == true
      and vim.b[candidate].gh_pr_asset_kind == "binary" then
      local candidate_number = tonumber(vim.b[candidate].gh_pr_number)
      local candidate_path = normalize_path(vim.b[candidate].gh_pr_file_path or vim.b[candidate].gh_pr_path or "")
      if candidate_number == ctx.number and (candidate_path == "" or target_path == "" or candidate_path == target_path) then
        local preview = type(vim.b[candidate].gh_pr_asset_preview) == "table" and vim.b[candidate].gh_pr_asset_preview or {}
        local side_entry = type(preview[side]) == "table" and preview[side] or nil
        if side_entry and file_readable(side_entry.cache_path) then
          return {
            side = side,
            present = side_entry.present ~= false,
            path = normalize_path(side_entry.path),
            cache_path = side_entry.cache_path,
            size = tonumber(side_entry.size) or 0,
            sha = type(side_entry.sha) == "string" and side_entry.sha or "",
            ext = type(side_entry.ext) == "string" and side_entry.ext or "",
          }
        end
      end
    end
  end

  return nil
end

function non_text_preview.binary_asset_cache_path(ctx, side, path, sha)
  local repo_slug = sanitize_filename(ctx.repo ~= "" and ctx.repo or ("pr-" .. tostring(ctx.number)))
  local filename = sanitize_filename((path:match("([^/]+)$") or (side .. "-asset")))
  local cache_root = joinpath(vim.fn.stdpath("cache"), "gh-pr", "assets", repo_slug, tostring(ctx.number))
  if not non_text_preview.ensure_dir(cache_root) then
    return nil, "Unable to prepare binary asset cache directory"
  end
  local hash = type(sha) == "string" and sha ~= "" and sha:sub(1, 12) or "unknown"
  return joinpath(cache_root, string.format("%s-%s-%s", side, hash, filename)), nil
end

function non_text_preview.fetch_and_cache_binary_asset(details, ctx, side)
  local side_path = non_text_preview.path_for_side(ctx, side)
  if side_path == "" then
    return nil, string.format("Missing %s asset path", side)
  end

  local side_ref = side == "base" and details.baseRefName or details.headRefName
  if type(side_ref) ~= "string" or side_ref == "" then
    return nil, string.format("Missing %s ref for pull request", side)
  end

  local repository = non_text_preview.resolve_side_repository(details, side, ctx.repo)
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
    return nil, string.format("Unable to decode %s asset bytes from GitHub contents API", side)
  end

  local bytes = non_text_preview.decode_base64(content)
  if bytes == "" then
    return nil, string.format("Unable to decode %s asset bytes from base64 payload", side)
  end

  local size = tonumber(payload.size) or #bytes
  local sha = type(payload.sha) == "string" and payload.sha or ""
  local ext = normalize_path(side_path):match("%.([^.]+)$")
  ext = type(ext) == "string" and ext:lower() or ""
  local cache_path, cache_err = non_text_preview.binary_asset_cache_path(ctx, side, side_path, sha)
  if not cache_path then
    return nil, cache_err
  end
  local ok_write, write_err = non_text_preview.write_binary_file(cache_path, bytes)
  if not ok_write then
    return nil, write_err
  end
  return {
    side = side,
    present = true,
    path = side_path,
    cache_path = cache_path,
    size = size,
    sha = sha,
    ext = ext,
  }, nil
end

function non_text_preview.ensure_binary_side_asset(ctx, side)
  if not non_text_preview.side_present_for_status(ctx.status, side) then
    return {
      side = side,
      present = false,
      path = non_text_preview.path_for_side(ctx, side),
    }, nil
  end

  local cached = non_text_preview.cached_binary_side_asset(ctx, side)
  if cached then
    return cached, nil
  end

  local _, details, details_err = resolve_active_pr(ctx.number, { refresh = false })
  if not details then
    return nil, details_err
  end

  local fetched, fetch_err = non_text_preview.fetch_and_cache_binary_asset(details, ctx, side)
  if not fetched then
    return nil, fetch_err
  end

  if is_valid_buf(ctx.bufnr) then
    local preview = type(vim.b[ctx.bufnr].gh_pr_asset_preview) == "table" and vim.deepcopy(vim.b[ctx.bufnr].gh_pr_asset_preview) or {}
    local entry = type(preview[side]) == "table" and preview[side] or {}
    entry.present = true
    entry.path = fetched.path
    entry.cache_path = fetched.cache_path
    entry.size = fetched.size
    entry.sha = fetched.sha
    entry.ext = fetched.ext
    preview[side] = entry
    vim.b[ctx.bufnr].gh_pr_asset_preview = preview
  end
  return fetched, nil
end

function non_text_preview.ensure_side_asset(ctx, side, images_cfg)
  if ctx.asset_kind == "image" then
    return non_text_preview.ensure_image_side_asset(ctx, side, images_cfg)
  end
  return non_text_preview.ensure_binary_side_asset(ctx, side)
end

local function try_detached_command(command)
  local executable = type(command) == "table" and command[1] or nil
  if type(executable) ~= "string" or executable == "" then
    return false, "invalid command"
  end
  if vim.fn.executable(executable) ~= 1 then
    return false, executable .. " is unavailable"
  end

  local ok_job, jobid = pcall(vim.fn.jobstart, command, { detach = true })
  if ok_job and type(jobid) == "number" and jobid > 0 then
    return true, nil
  end
  return false, executable .. " failed to start"
end

local function local_target_directory(target)
  if type(target) ~= "string" or target == "" then
    return ""
  end
  if vim.fn.isdirectory(target) == 1 then
    return target
  end
  if vim.fs and type(vim.fs.dirname) == "function" then
    return vim.fs.dirname(target) or ""
  end
  return target:match("^(.*)[/\\][^/\\]+$") or ""
end

local function try_local_system_open(target)
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
    commands = {
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

  local errors = {}
  for _, command in ipairs(commands) do
    local ok_open, open_err = try_detached_command(command)
    if ok_open then
      return true, nil
    end
    if type(open_err) == "string" and open_err ~= "" then
      errors[#errors + 1] = open_err
    end
  end

  if type(ui_err) == "string" and ui_err ~= "" then
    table.insert(errors, 1, "vim.ui.open failed: " .. ui_err)
  end
  if vim.tbl_isempty(errors) then
    return false, "Unable to open target using system opener"
  end
  return false, table.concat(errors, " | ")
end

local function try_reveal_local_target(target)
  local is_windows = vim.fn.has("win32") == 1 or vim.fn.has("win64") == 1
  local is_mac = vim.fn.has("mac") == 1 or vim.fn.has("macunix") == 1
  local directory = local_target_directory(target)
  local commands = {}

  if is_windows then
    commands = {
      { "explorer.exe", "/select," .. target },
    }
    if directory ~= "" and directory ~= target then
      commands[#commands + 1] = { "explorer.exe", directory }
    end
  elseif is_mac then
    commands = {
      { "open", "-R", target },
    }
    if directory ~= "" and directory ~= target then
      commands[#commands + 1] = { "open", directory }
    end
  elseif directory ~= "" then
    commands = {
      { "xdg-open", directory },
    }
  else
    commands = {
      { "xdg-open", target },
    }
  end

  local errors = {}
  for _, command in ipairs(commands) do
    local ok_reveal, reveal_err = try_detached_command(command)
    if ok_reveal then
      return true, nil
    end
    if type(reveal_err) == "string" and reveal_err ~= "" then
      errors[#errors + 1] = reveal_err
    end
  end

  if vim.tbl_isempty(errors) then
    return false, "Unable to reveal local target"
  end
  return false, table.concat(errors, " | ")
end

local function ensure_open_target(target, label, opts)
  opts = type(opts) == "table" and opts or {}
  if type(target) ~= "string" or target == "" then
    return false, string.format("Missing %s target", label)
  end

  local is_url = target:match("^https?://") ~= nil
  if is_url then
    return url_open.open(target, {
      notify_error = false,
    })
  end

  local policy = normalize_local_open_policy(opts.open_local, "disabled")
  local effective_policy = effective_local_open_policy(policy, target)
  local policy_key = safe_string(opts.open_local_key, "local opener policy")
  if effective_policy == "disabled" then
    return false, string.format("Opening local targets is disabled by `%s`", policy_key)
  end
  if effective_policy == "reveal_only" then
    return try_reveal_local_target(target)
  end
  return try_local_system_open(target)
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

non_text_preview.base64_chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

function non_text_preview.decode_base64_fallback(data)
  data = (data or ""):gsub("[^" .. non_text_preview.base64_chars .. "=]", "")
  return (data:gsub(".", function(char)
    if char == "=" then
      return ""
    end
    local index = non_text_preview.base64_chars:find(char, 1, true)
    if not index then
      return ""
    end
    local bits = ""
    local value = index - 1
    for bit = 6, 1, -1 do
      if value % (2 ^ bit) - value % (2 ^ (bit - 1)) > 0 then
        bits = bits .. "1"
      else
        bits = bits .. "0"
      end
    end
    return bits
  end):gsub("%d%d%d?%d?%d?%d?%d?%d?", function(byte)
    if #byte ~= 8 then
      return ""
    end
    local value = 0
    for bit = 1, 8 do
      if byte:sub(bit, bit) == "1" then
        value = value + 2 ^ (8 - bit)
      end
    end
    return string.char(value)
  end))
end

function non_text_preview.decode_base64(data)
  local normalized = type(data) == "string" and data:gsub("\n", "") or ""
  if normalized == "" then
    return ""
  end
  if vim.base64 and type(vim.base64.decode) == "function" then
    local ok, decoded = pcall(vim.base64.decode, normalized)
    if ok and type(decoded) == "string" then
      return decoded
    end
  end
  return non_text_preview.decode_base64_fallback(normalized)
end

function non_text_preview.ensure_dir(path)
  if type(path) ~= "string" or path == "" then
    return false
  end
  vim.fn.mkdir(path, "p")
  return vim.fn.isdirectory(path) == 1
end

function non_text_preview.write_binary_file(path, bytes)
  if type(path) ~= "string" or path == "" then
    return false, "Missing cache path"
  end
  local parent = path:match("^(.*)[/\\][^/\\]+$") or ""
  if parent ~= "" and not non_text_preview.ensure_dir(parent) then
    return false, "Unable to prepare asset cache directory"
  end
  local fd, open_err = uv.fs_open(path, "w", 438)
  if not fd then
    return false, tostring(open_err or "Unable to open asset cache file")
  end
  local ok_write, write_err = uv.fs_write(fd, bytes or "", 0)
  uv.fs_close(fd)
  if not ok_write then
    return false, tostring(write_err or "Unable to write asset cache file")
  end
  return true, nil
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
  if name == "" then
    return ""
  end
  return sanitize_filename(name)
end

local function resolve_attachment_filename(url, label, allowed_fallback_extensions)
  local filename = filename_from_url(url)
  if filename ~= "" then
    return filename
  end

  local fallback = sanitize_filename(type(label) == "string" and label or "")
  if fallback == "" then
    return "attachment.bin"
  end

  local ext = extension_from_name(fallback)
  if ext ~= "" and type(allowed_fallback_extensions) == "table" and allowed_fallback_extensions[ext] then
    return fallback
  end

  return "attachment.bin"
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
    open_local = normalize_local_open_policy(markdown.link_preview_open_local, "disabled"),
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
  pcall(vim.api.nvim_set_option_value, "modified", false, { buf = bufnr })

  local ok_tab, tab_err = pcall(vim.cmd, "tabnew")
  if not ok_tab then
    return false, "Unable to open preview tab: " .. tostring(tab_err)
  end

  local tabpage = vim.api.nvim_get_current_tabpage()
  local winid = vim.api.nvim_get_current_win()
  if not is_valid_win(winid) then
    return false, "Unable to resolve preview window"
  end

  pcall(vim.api.nvim_win_set_buf, winid, bufnr)
  sanitize_modal_window(winid)
  vim.api.nvim_set_option_value("number", true, { win = winid })
  vim.api.nvim_set_option_value("relativenumber", false, { win = winid })
  vim.api.nvim_set_option_value("signcolumn", "no", { win = winid })
  vim.api.nvim_set_option_value("wrap", true, { win = winid })
  vim.api.nvim_set_option_value("linebreak", true, { win = winid })
  vim.api.nvim_set_option_value("cursorline", true, { win = winid })
  vim.api.nvim_set_option_value("spell", false, { win = winid })
  if type(preview_filetype) == "string" and preview_filetype ~= "" and preview_filetype ~= "text" then
    pcall(vim.api.nvim_set_option_value, "syntax", preview_filetype, { win = winid })
  end

  local function close_preview_tab()
    if vim.api.nvim_get_current_tabpage() ~= tabpage and vim.api.nvim_tabpage_is_valid(tabpage) then
      pcall(vim.api.nvim_set_current_tabpage, tabpage)
    end
    if vim.api.nvim_tabpage_is_valid(tabpage) then
      pcall(vim.cmd, "tabclose")
    elseif is_valid_buf(bufnr) then
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end
  end

  local key_opts = { buffer = bufnr, silent = true, nowait = true }
  vim.keymap.set("n", "q", close_preview_tab, vim.tbl_extend("force", key_opts, { desc = "Close PR link preview" }))
  vim.keymap.set("n", "<Esc>", close_preview_tab, vim.tbl_extend("force", key_opts, { desc = "Close PR link preview" }))
  pcall(vim.api.nvim_win_set_cursor, winid, { 1, 0 })

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

local function notify_local_open_unavailable(filename, reason, config_key, path)
  local location = type(path) == "string" and path ~= "" and ("\nCached at: " .. path) or ""
  notify_warn(string.format(
    "Preview unavailable for '%s' (%s). Local open is disabled by `%s`.%s",
    filename,
    reason,
    config_key,
    location
  ))
end

local function prompt_open_downloaded_file(path, filename, reason, open_local, open_local_key)
  local confirm_label = local_open_action_label(open_local, path)
  local prompt = string.format(
    "Preview unavailable for '%s' (%s). %s downloaded file locally?",
    filename,
    reason,
    confirm_label:gsub("^%l", string.upper)
  )
  select_open_local(prompt, function(should_open)
    if not should_open then
      return
    end
    local ok_open, open_err = ensure_open_target(path, "downloaded file", {
      open_local = open_local,
      open_local_key = open_local_key,
    })
    if not ok_open then
      notify_error("Unable to open downloaded file: " .. tostring(open_err))
    end
  end, confirm_label)
end

local function prompt_download_and_open_local(url, filename, reason, open_local, open_local_key)
  local confirm_label = local_open_action_label(open_local, filename)
  local prompt = string.format(
    "Cannot preview '%s' (%s). Download and %s?",
    filename,
    reason,
    local_open_action_phrase(open_local, filename)
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

    notify_info("Downloading link attachment for local access...")
    download_link_to_path_async(url, target_path, function(downloaded_path, download_err)
      if not downloaded_path then
        notify_error("Unable to download link: " .. tostring(download_err))
        return
      end
      local ok_open, open_err = ensure_open_target(downloaded_path, "downloaded file", {
        open_local = open_local,
        open_local_key = open_local_key,
      })
      if not ok_open then
        notify_error("Unable to open downloaded file: " .. tostring(open_err))
      end
    end)
  end, confirm_label)
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
  local filename = resolve_attachment_filename(url, action_label, options.renderable_set)

  local extension = extension_from_name(filename)
  if extension ~= "" and options.disallowed_set[extension] then
    if options.open_local == "disabled" then
      notify_local_open_unavailable(
        filename,
        "extension ." .. extension .. " is not previewable",
        "overview.markdown.link_preview_open_local"
      )
      return
    end
    prompt_download_and_open_local(
      url,
      filename,
      "extension ." .. extension .. " is not previewable",
      options.open_local,
      "overview.markdown.link_preview_open_local"
    )
    return
  end
  if extension ~= "" and not options.renderable_set[extension] then
    if options.open_local == "disabled" then
      notify_local_open_unavailable(
        filename,
        "extension ." .. extension .. " is not configured as renderable",
        "overview.markdown.link_preview_open_local"
      )
      return
    end
    prompt_download_and_open_local(
      url,
      filename,
      "extension ." .. extension .. " is not configured as renderable",
      options.open_local,
      "overview.markdown.link_preview_open_local"
    )
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
      if options.open_local == "disabled" then
        notify_local_open_unavailable(
          filename,
          string.format("file exceeds preview limit (%d > %d bytes)", size, options.max_bytes),
          "overview.markdown.link_preview_open_local",
          downloaded_path
        )
        return
      end
      prompt_open_downloaded_file(
        downloaded_path,
        filename,
        string.format("file exceeds preview limit (%d > %d bytes)", size, options.max_bytes),
        options.open_local,
        "overview.markdown.link_preview_open_local"
      )
      return
    end

    local bytes, read_err = read_file_bytes(downloaded_path)
    if not bytes then
      notify_error("Unable to inspect downloaded file: " .. tostring(read_err))
      return
    end

    if is_probably_binary(bytes) then
      if options.open_local == "disabled" then
        notify_local_open_unavailable(
          filename,
          "binary content is not renderable",
          "overview.markdown.link_preview_open_local",
          downloaded_path
        )
        return
      end
      prompt_open_downloaded_file(
        downloaded_path,
        filename,
        "binary content is not renderable",
        options.open_local,
        "overview.markdown.link_preview_open_local"
      )
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
  pcall(vim.api.nvim_set_option_value, "modified", false, { buf = bufnr })
  pcall(vim.fn.winrestview, view)
  return true, nil
end

local function collect_image_metadata_for_side(ctx, side, images_cfg)
  local asset, asset_err = non_text_preview.ensure_image_side_asset(ctx, side, images_cfg)
  if not asset then
    return {
      side = side,
      present = non_text_preview.side_present_for_status(ctx.status, side),
      path = non_text_preview.path_for_side(ctx, side),
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
  local ctx, ctx_err = non_text_preview.resolve_buffer_context(bufnr)
  if not ctx then
    return false, ctx_err
  end
  if ctx.asset_kind ~= "image" then
    return true, nil
  end

  local images_cfg = non_text_preview.image_diff_options()
  local diff_shortcuts = diff_view_shortcuts()
  local default_action = non_text_preview.resolve_default_action(images_cfg)
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
    string.format(
      "default action (%s): %s",
      default_key ~= "" and default_key or "<localleader>io",
      non_text_preview.action_label(default_action, images_cfg)
    ),
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
  local ctx, ctx_err = non_text_preview.resolve_buffer_context(bufnr)
  if not ctx then
    return false, ctx_err
  end

  local images_cfg = non_text_preview.image_diff_options()
  local requested = non_text_preview.normalize_image_action(action, non_text_preview.resolve_default_action(images_cfg))
  local reason = type(opts.reason) == "string" and opts.reason ~= "" and opts.reason or ctx.reason

  if requested == "metadata" then
    if ctx.asset_kind ~= "image" then
      return true, nil
    end
    return render_image_metadata_diff(ctx.bufnr, reason)
  end

  if requested == "open_local_current" then
    local side = non_text_preview.current_side(ctx)
    local asset, asset_err = non_text_preview.ensure_side_asset(ctx, side, images_cfg)
    if not asset then
      return false, asset_err
    end
    if asset.present == false then
      return false, string.format("No %s revision exists for this pull request file state", side)
    end
    if not file_readable(asset.cache_path) then
      return false, "Unable to resolve a local asset file to open"
    end
    return ensure_open_target(asset.cache_path, "local asset", {
      open_local = images_cfg.fallback_open_local,
      open_local_key = "diff_view.images.fallback_open_local",
    })
  end

  if requested == "open_local_both" then
    local opened_paths = {}
    local opened_count = 0
    local errors = {}
    for _, side in ipairs({ "base", "head" }) do
      local asset, asset_err = non_text_preview.ensure_side_asset(ctx, side, images_cfg)
      if not asset then
        errors[#errors + 1] = string.format("%s: %s", side, tostring(asset_err))
      elseif asset.present and file_readable(asset.cache_path) then
        if not opened_paths[asset.cache_path] then
          local ok_open, open_err = ensure_open_target(asset.cache_path, side .. " asset", {
            open_local = images_cfg.fallback_open_local,
            open_local_key = "diff_view.images.fallback_open_local",
          })
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
    return false, "No local revisions available to open"
  end

  if requested == "open_github" then
    local url = resolve_image_compare_url(ctx, images_cfg)
    if url == "" then
      return false, "Unable to resolve GitHub URL for this file"
    end
    return ensure_open_target(url, "GitHub file URL")
  end

  return false, "Unsupported non-text preview action: " .. tostring(requested)
end

local function execute_image_fallback_action(action, bufnr, opts)
  opts = type(opts) == "table" and opts or {}
  local requested = non_text_preview.normalize_image_action(action, "metadata")
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
        "Non-text preview action '%s' failed (%s). Rendered metadata preview instead.",
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
  if type(non_text_preview.menu_state) ~= "table" then
    non_text_preview.menu_state = nil
    return
  end

  local winid = non_text_preview.menu_state.winid
  non_text_preview.menu_state = nil
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
  local action_id = non_text_preview.normalize_image_action(action, non_text_preview.resolve_default_action(non_text_preview.image_diff_options()))
  if set_default == true then
    non_text_preview.persist_default_action(action_id)
    notify_info("Non-text preview default action set to: " .. non_text_preview.action_label(action_id, non_text_preview.image_diff_options()))
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
  local ctx, ctx_err = non_text_preview.resolve_buffer_context(origin_bufnr)
  if not ctx then
    return notify_error(ctx_err)
  end

  local origin_winid = vim.api.nvim_get_current_win()
  close_image_fallback_menu()

  local images_cfg = non_text_preview.image_diff_options()
  local diff_shortcuts = diff_view_shortcuts()
  local default_action = non_text_preview.resolve_default_action(images_cfg)
  local default_key = type(diff_shortcuts.image_default_action) == "string" and diff_shortcuts.image_default_action or "<localleader>io"
  local fallback_key = type(diff_shortcuts.image_fallback_menu) == "string" and diff_shortcuts.image_fallback_menu
    or "<localleader>im"
  local reason = type(vim.b[origin_bufnr].gh_pr_image_reason) == "string" and vim.b[origin_bufnr].gh_pr_image_reason or ""
  local asset_label = ctx.asset_kind == "image" and "image" or "non-text"

  local lines = {
    string.format("gh-pr %s preview actions", asset_label),
    "Enter/1..4: run action | d: set default | s: set default + run | q: close",
    string.rep("=", 74),
    string.format("file: %s", ctx.file_path ~= "" and ctx.file_path or ctx.path),
    string.format("status: %s", ctx.status ~= "" and ctx.status or "unknown"),
    string.format(
      "default (%s): %s",
      default_key ~= "" and default_key or "<localleader>io",
      non_text_preview.action_label(default_action, images_cfg)
    ),
    string.format("menu keymap: %s", fallback_key ~= "" and fallback_key or "<localleader>im"),
  }
  if reason ~= "" then
    lines[#lines + 1] = "reason: " .. reason
  end
  lines[#lines + 1] = ""

  local line_actions = {}
  for index, action in ipairs(non_text_preview.action_order) do
    local marker = action == default_action and "*" or " "
    lines[#lines + 1] = string.format("%d. [%s] %s", index, marker, non_text_preview.action_label(action, images_cfg))
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
    title = asset_label == "image" and "Image Preview" or "Non-Text Preview",
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
  pcall(vim.api.nvim_set_option_value, "modified", false, { buf = menu_buf })

  vim.api.nvim_win_set_option(menu_win, "number", false)
  vim.api.nvim_win_set_option(menu_win, "relativenumber", false)
  vim.api.nvim_win_set_option(menu_win, "cursorline", true)
  vim.api.nvim_win_set_option(menu_win, "wrap", false)
  vim.api.nvim_win_set_option(menu_win, "signcolumn", "no")
  vim.api.nvim_win_set_option(menu_win, "winhl", "NormalFloat:NormalFloat,FloatBorder:FloatBorder")

  non_text_preview.menu_state = {
    bufnr = menu_buf,
    winid = menu_win,
    origin_winid = origin_winid,
    origin_bufnr = origin_bufnr,
    line_actions = line_actions,
    first_action_line = #lines - #non_text_preview.action_order + 1,
  }

  local keymap_opts = {
    buffer = menu_buf,
    silent = true,
    nowait = true,
  }

  vim.keymap.set("n", "q", close_image_fallback_menu, vim.tbl_extend("force", keymap_opts, { desc = "Close image fallback menu" }))
  vim.keymap.set("n", "<Esc>", close_image_fallback_menu, vim.tbl_extend("force", keymap_opts, { desc = "Close image fallback menu" }))
  vim.keymap.set("n", "<CR>", function()
    local active = non_text_preview.menu_state
    local action = current_menu_action(active)
    if action then
      run_menu_action(active, action, false)
    end
  end, vim.tbl_extend("force", keymap_opts, { desc = "Run selected image fallback action" }))
  vim.keymap.set("n", "d", function()
    local active = non_text_preview.menu_state
    local action = current_menu_action(active)
    if action then
      non_text_preview.persist_default_action(action)
      notify_info("Non-text preview default action set to: " .. non_text_preview.action_label(action, non_text_preview.image_diff_options()))
      local origin_winid = active.origin_winid
      close_image_fallback_menu()
      if is_valid_win(origin_winid) then
        pcall(vim.api.nvim_set_current_win, origin_winid)
      end
      M.open_image_fallback_menu()
    end
  end, vim.tbl_extend("force", keymap_opts, { desc = "Set selected action as default" }))
  vim.keymap.set("n", "s", function()
    local active = non_text_preview.menu_state
    local action = current_menu_action(active)
    if action then
      run_menu_action(active, action, true)
    end
  end, vim.tbl_extend("force", keymap_opts, { desc = "Set selected action as default and run it" }))

  for index, action in ipairs(non_text_preview.action_order) do
    local action_id = action
    vim.keymap.set("n", tostring(index), function()
      local active = non_text_preview.menu_state
      if active then
        run_menu_action(active, action_id, false)
      end
    end, vim.tbl_extend("force", keymap_opts, { desc = "Run image fallback action " .. tostring(index) }))
  end

  vim.api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(menu_win),
    once = true,
    callback = function()
      non_text_preview.menu_state = nil
    end,
  })

  pcall(vim.api.nvim_win_set_cursor, menu_win, { non_text_preview.menu_state.first_action_line, 0 })
end

function M.run_image_fallback_default_action()
  local bufnr = vim.api.nvim_get_current_buf()
  local _, ctx_err = non_text_preview.resolve_buffer_context(bufnr)
  if ctx_err then
    return notify_error(ctx_err)
  end

  local images_cfg = non_text_preview.image_diff_options()
  local action = non_text_preview.resolve_default_action(images_cfg)
  local ok_action, action_err = execute_image_fallback_action(action, bufnr, {
    fallback_to_metadata = true,
  })
  if not ok_action then
    notify_error(action_err)
  end
end

function M.run_non_text_default_action()
  return M.run_image_fallback_default_action()
end

function M.open_non_text_actions_menu()
  return M.open_image_fallback_menu()
end

function M.run_non_text_action_at_cursor()
  local bufnr = vim.api.nvim_get_current_buf()
  local ctx, ctx_err = non_text_preview.resolve_buffer_context(bufnr)
  if not ctx then
    return notify_error(ctx_err)
  end

  local line = vim.api.nvim_win_get_cursor(0)[1]
  local actions = type(vim.b[bufnr].gh_pr_asset_actions) == "table" and vim.b[bufnr].gh_pr_asset_actions or {}
  local action = actions[line]
  if type(action) ~= "string" or action == "" then
    return
  end

  local ok_action, action_err = execute_image_fallback_action(action, bufnr, {
    fallback_to_metadata = ctx.asset_kind == "image",
  })
  if not ok_action then
    notify_error(action_err)
  end
end

function M.on_image_render_fallback(bufnr, reason)
  local ctx, ctx_err = non_text_preview.resolve_image_buffer_context(bufnr)
  if not ctx then
    return notify_warn(ctx_err)
  end

  local images_cfg = non_text_preview.image_diff_options()
  local mode = images_cfg.fallback_mode
  if mode ~= "menu" and mode ~= "metadata_only" and mode ~= "auto_local" and mode ~= "auto_github" then
    mode = "menu"
  end
  if mode == "auto_local" and normalize_local_open_policy(images_cfg.fallback_open_local, "disabled") == "disabled" then
    mode = "metadata_only"
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
    local preferred = non_text_preview.resolve_default_action(images_cfg)
    if preferred ~= "open_local_current" and preferred ~= "open_local_both" then
      preferred = "open_local_current"
    end
    local ok_action, action_err = execute_image_fallback_action(preferred, bufnr, {
      fallback_to_metadata = true,
      reason = reason,
    })
    if not ok_action then
        notify_warn("Non-text preview auto-local failed: " .. tostring(action_err))
    end
    return
  end

  if mode == "auto_github" then
    local ok_action, action_err = execute_image_fallback_action("open_github", bufnr, {
      fallback_to_metadata = true,
      reason = reason,
    })
    if not ok_action then
        notify_warn("Non-text preview auto-github failed: " .. tostring(action_err))
    end
    return
  end

  local diff_shortcuts = diff_view_shortcuts()
  local default_action = non_text_preview.resolve_default_action(images_cfg)
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
  else
    return M.open_modified(file, {
      target_side = "head",
      target_line = target_line,
      target_original_line = target_line,
    })
  end
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

local function overview_actions_context()
  return {
    actions = {
      checkout = M.checkout,
      merge = M.merge,
      open_comment_location = M.open_comment_location,
      open_comments = M.open_comments,
      open_commit_diff = M.open_commit_diff,
      open_diff = M.open_diff,
      open_modified = M.open_modified,
      open_original = M.open_original,
      open_overview = M.open_overview,
      open_overview_url = M.open_overview_url,
      open_overview_thread_workspace = M.open_overview_thread_workspace,
      open_thread_comment_commit_diff = M.open_thread_comment_commit_diff,
      open_thread_comment_evolution_diff = M.open_thread_comment_evolution_diff,
      open_thread_fix_diff = M.open_thread_fix_diff,
      overview_edit_stub = M.overview_edit_stub,
      overview_more = M.overview_more,
      overview_preview_markdown_link = M.overview_preview_markdown_link,
      refresh_overview = M.refresh_overview,
      resolve_thread_fix_diff = M.resolve_thread_fix_diff,
      review = M.review,
      toggle_review_tree = M.toggle_review_tree,
    },
    buffer_filetype = buffer_filetype,
    config = config,
    is_valid_buf = is_valid_buf,
    is_valid_win = is_valid_win,
    normalize_repository = normalize_repository,
    notify_error = notify_error,
    positive_integer = positive_integer,
    pr_service = pr_service,
    resolve_active_pr = resolve_active_pr,
    set_active_pr = M.set_active_pr,
  }
end

function M.build_overview_model_for_overview(number, opts)
  return overview_actions.build_overview_model(number, opts, overview_actions_context())
end

function M.open_overview(number, opts)
  return overview_actions.open_overview(number, opts, overview_actions_context())
end

function M.refresh_overview()
  return overview_actions.refresh_overview(overview_actions_context())
end

function M.refresh_visible_overview_for_pr(number)
  return overview_actions.refresh_visible_overview_for_pr(number, overview_actions_context())
end

function M.overview_more(section, count)
  return overview_actions.overview_more(section, count, overview_actions_context())
end

function M.open_overview_url(number)
  return overview_actions.open_overview_url(number, overview_actions_context())
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

local function overview_edit_picker_context()
  return {
    normalize_repository = normalize_repository,
    notify_error = notify_error,
    notify_warn = notify_warn,
    pr_service = pr_service,
    open_multiline_editor = function(opts)
      return comment_composer.open(opts)
    end,
  }
end

local function overview_edit_actions_context()
  local picker_ctx = overview_edit_picker_context()
  return {
    is_valid_buf = is_valid_buf,
    is_valid_win = is_valid_win,
    notify_error = notify_error,
    notify_info = notify_info,
    notify_warn = notify_warn,
    open_overview = M.open_overview,
    pr_service = pr_service,
    refresh_pr_sources_after_state_change = refresh_pr_sources_after_state_change,
    resolve_active_pr = resolve_active_pr,
    ui = {
      confirm = overview_edit_picker.confirm,
      pick = function(kind, payload, pr, details, label, callback)
        overview_edit_picker.pick(kind, payload, pr, details, label, picker_ctx, callback)
      end,
    },
  }
end

function M.overview_edit_stub(kind, payload)
  return overview_edit_actions.run(kind, payload, overview_edit_actions_context())
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

  local shortcuts = diff_view_shortcuts()

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

local function apply_codediff_buffer_metadata(bufnr, pr, details, path, side, file_mode)
  if not is_valid_buf(bufnr) then
    return
  end

  local normalized_path = normalize_path(path)
  local canonical_path = resolve_canonical_file_path(details, normalized_path)
  local repository = normalize_repository(details) or ""

  vim.b[bufnr].gh_pr_repo = repository ~= "" and repository or nil
  vim.b[bufnr].gh_pr_number = tonumber(pr.number)
  vim.b[bufnr].gh_pr_path = normalized_path
  vim.b[bufnr].gh_pr_file_path = canonical_path ~= "" and canonical_path or nil
  vim.b[bufnr].gh_pr_file_kind = side
  vim.b[bufnr].gh_pr_file_mode = type(file_mode) == "string" and file_mode ~= "" and file_mode or nil
  vim.b[bufnr].gh_pr_diff_backend = "codediff"
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
  vim.b[bufnr].gh_pr_comment_side = side
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

  if is_valid_buf(base_buf) then
    apply_codediff_buffer_metadata(base_buf, pr, details, base_path, "base", file_mode)
    local base_win = resolve_codediff_window(open_result.base_win, base_buf)
    if base_win then
      apply_codediff_window_number_options(base_win)
    end
    if comments_ctx then
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
    end
    annotation_renderer.clear_buffer(base_buf)
    security_annotation_renderer.clear_buffer(base_buf)
  end

  if is_valid_buf(head_buf) then
    apply_codediff_buffer_metadata(head_buf, pr, details, head_path, "head", file_mode)
    local head_win = resolve_codediff_window(open_result.head_win, head_buf)
    if head_win then
      apply_codediff_window_number_options(head_win)
    end
    if comments_ctx then
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
  local function open_with_codediff()
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

  local function open_with_virtual()
    if is_valid_win(origin_win) then
      pcall(vim.api.nvim_set_current_win, origin_win)
    end
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
      return nil, diff_err
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

    sync_diff_comments_panel(pr, details, nil)
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
  local function open_with_codediff()
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

  local function open_with_virtual()
    if is_valid_win(origin_win) then
      pcall(vim.api.nvim_set_current_win, origin_win)
    end
    local diff_view = current_diff_view_preferences({
      mode = opts.view_mode,
      ignore_whitespace = opts.ignore_whitespace,
      render_whitespace = opts.render_whitespace,
      render_endlines = opts.render_endlines,
    })

    local diff_result, diff_err = virtual_files.open_diff(compare_details, pr, compare_file, {
      line_comments = comments_ctx,
      view_mode = diff_view.mode,
      ignore_whitespace = diff_view.ignore_whitespace,
      render_whitespace = diff_view.render_whitespace,
      render_endlines = diff_view.render_endlines,
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

    sync_diff_comments_panel(pr, compare_details, comments_ctx)
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

  local function open_with_codediff()
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

  local function open_with_virtual()
    if is_valid_win(origin_win) then
      pcall(vim.api.nvim_set_current_win, origin_win)
    end
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
      return nil, diff_err
    end

    if type(diff_result) == "table" and diff_result.file_mode == "added_single" then
      notify_info("File is new in this PR. Opened single MODIFIED buffer (diff layouts disabled).")
    elseif type(diff_result) == "table" and diff_result.file_mode == "removed_single" then
      notify_info("File was removed in this PR. Opened single ORIGINAL buffer (diff layouts disabled).")
    end

    sync_diff_comments_panel(pr, details, comments_ctx)
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
  if not using_virtual_diff_backend() then
    return false, virtual_only_feature_message("Diff render/layout toggles")
  end

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

    return M.mark_files_viewed({
      {
        path = path,
        filename = path,
      },
    }, nil)
  end

  M.mark_file_viewed(nil, nil)
end

function M.sync_remote_viewed_state(pr_number, details, opts)
  return sync_remote_viewed_state_for_pr(pr_number, details, opts)
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

refresh_line_comments_for_pr = function(pr_number, details)
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

local function review_actions_context()
  return {
    confirm_review_submission = confirm_review_submission,
    notify_error = notify_error,
    notify_info = notify_info,
    pr_service = pr_service,
    prompt_review_body = prompt_review_body,
    refresh_line_comments_for_pr = refresh_line_comments_for_pr,
    resolve_active_pr = resolve_active_pr,
    review_event_label = review_event_label,
  }
end

function M.submit_pending_review(event)
  review_actions.submit_pending_review(event, review_actions_context())
end

function M.submit_pending_comment_review()
  review_actions.submit_pending_comment_review(review_actions_context())
end

function M.submit_pending_approve_review()
  review_actions.submit_pending_approve_review(review_actions_context())
end

function M.submit_pending_request_changes_review()
  review_actions.submit_pending_request_changes_review(review_actions_context())
end

function M.discard_pending_review()
  review_actions.discard_pending_review(review_actions_context())
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
  diff_actions.next_change()
end

function M.prev_change()
  diff_actions.prev_change()
end

function M.toggle_diff_whitespace()
  if not require_virtual_diff_backend("Whitespace diff toggle") then
    return
  end

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
  if not require_virtual_diff_backend("Diff layout toggle") then
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
  if not require_virtual_diff_backend("Diff layout selection") then
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

local function diff_shortcut_lines(bufnr)
  local kind = type(vim.b[bufnr].gh_pr_file_kind) == "string" and vim.b[bufnr].gh_pr_file_kind or "head"
  local file_mode = type(vim.b[bufnr].gh_pr_file_mode) == "string" and vim.b[bufnr].gh_pr_file_mode or ""
  local is_image = vim.b[bufnr].gh_pr_is_image == true
  local is_non_text = vim.b[bufnr].gh_pr_is_non_text == true or is_image
  local asset_label = is_image and "image" or "non-text"
  local backend = type(vim.b[bufnr].gh_pr_diff_backend) == "string"
      and vim.b[bufnr].gh_pr_diff_backend
    or (using_virtual_diff_backend() and "virtual" or "codediff")
  local prefs = current_diff_view_preferences()
  local shortcuts = diff_view_shortcuts()
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

  local mode_label = prefs.mode
  if backend == "codediff" then
    mode_label = "side-by-side"
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
    if type(key) == "string" and key ~= "" then
      lines[#lines + 1] = shortcut_line(key, description)
    end
  end

  local lines = {
    "gh-pr diff shortcuts",
    "",
    "Diff render state",
    shortcut_line("backend", backend),
    shortcut_line("mode", mode_label),
  }
  if backend ~= "codediff" then
    lines[#lines + 1] = shortcut_line("spaces", is_non_text and string.format("n/a (%s)", asset_label) or (prefs.ignore_whitespace and "ignored" or "strict"))
    lines[#lines + 1] = shortcut_line("render", is_non_text and string.format("n/a (%s)", asset_label) or (prefs.render_whitespace and "visible" or "hidden"))
    lines[#lines + 1] = shortcut_line("endline", is_non_text and string.format("n/a (%s)", asset_label) or (prefs.render_endlines and "visible" or "hidden"))
    lines[#lines + 1] = shortcut_line("tab", is_non_text and "n/a" or whitespace_tab)
    lines[#lines + 1] = shortcut_line("space", is_non_text and "n/a" or whitespace_space)
  else
    lines[#lines + 1] = shortcut_line("render", "managed by codediff.nvim")
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "General"

  if is_non_text then
    lines[#lines + 1] = shortcut_line("-", string.format("Line comments popup not available for %s files", asset_label))
  else
    add_shortcut(lines, shortcuts.line_comments_popup, kind == "unified" and "Not available in unified mode" or "Show line comments popup")
    if backend == "codediff" then
      lines[#lines + 1] = shortcut_line("<CR>", "Open line comments popup on commented lines")
    end
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
  elseif backend == "codediff" then
    lines[#lines + 1] = shortcut_line("-", "Layout/render toggles are not available in codediff backend")
  elseif file_mode ~= "added_single" and file_mode ~= "removed_single" then
    add_shortcut(lines, shortcuts.toggle_whitespace, "Toggle whitespace changes")
    add_shortcut(lines, shortcuts.cycle_mode, "Cycle diff mode")
    add_shortcut(lines, shortcuts.set_vertical, "Set vertical split")
    add_shortcut(lines, shortcuts.set_horizontal, "Set horizontal split")
    add_shortcut(lines, shortcuts.set_unified, "Set unified mode")
  else
    lines[#lines + 1] = shortcut_line("-", "Diff layout toggles disabled for single-file mode")
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
    lines[#lines + 1] = shortcut_line(shortcuts.inline_comment, string.format("Not available for %s files", asset_label))
    lines[#lines + 1] = shortcut_line(shortcuts.inline_suggestion, string.format("Not available for %s files", asset_label))
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

M._open_target_helpers = {
  dangerous_local_open_extensions = vim.deepcopy(dangerous_local_open_extensions),
  effective_local_open_policy = effective_local_open_policy,
  normalize_local_open_policy = normalize_local_open_policy,
  resolve_attachment_filename = resolve_attachment_filename,
}

return M

