local M = {}

local comment_composer = require("gh-pr.comment_composer")
local comment_popup = require("gh-pr.comment_popup")
local navigation_actions = require("gh-pr.actions.navigation")
local config = require("gh-pr.config")
local coerce = require("gh-pr.core.coerce")
local diff_view_core = require("gh-pr.core.diff_view")
local diff_actions = require("gh-pr.core.diff_actions")
local notify = require("gh-pr.core.notify")
local overview_actions = require("gh-pr.core.overview_actions")
local overview_edit_actions = require("gh-pr.core.overview_edit_actions")
local repository = require("gh-pr.core.repository")
local review_module = require("gh-pr.actions.review")
local review_prefetch = require("gh-pr.core.review_prefetch")
local review_actions = require("gh-pr.core.review_actions")
local thread_diff_module = require("gh-pr.actions.thread_diff")
local file_diff_module = require("gh-pr.actions.file_diff")
local diff_shortcuts_config = require("gh-pr.diff_shortcuts")
local gh = require("gh-pr.gh")
local image_metadata = require("gh-pr.image_metadata")
local line_comments = require("gh-pr.line_comments")
local pr_service = require("gh-pr.pr_service")
local repo = require("gh-pr.repo")
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
local non_text_preview = require("gh-pr.actions.non_text_preview")
local diff_view_runtime = {}
local codediff_file_runtime = {
  by_tabpage = {},
  autocmds_attached = false,
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
    notify.error(err)
  end
end

local function notify_info(message)
  notify.info(message)
end

local function notify_warn(message)
  notify.warn(message)
end

local safe_string = coerce.safe_string

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

function diff_view_runtime.current_diff_backend(bufnr)
  bufnr = type(bufnr) == "number" and bufnr or vim.api.nvim_get_current_buf()
  if type(bufnr) == "number" and bufnr > 0 and vim.api.nvim_buf_is_valid(bufnr) then
    local backend = vim.b[bufnr].gh_pr_diff_backend
    if backend == "virtual" or backend == "codediff" then
      return backend
    end
  end
  return diff_backend_session.virtual_fallback == true and "virtual" or "codediff"
end

function diff_view_runtime.current_codediff_layout(bufnr)
  bufnr = type(bufnr) == "number" and bufnr or vim.api.nvim_get_current_buf()
  if diff_view_runtime.current_diff_backend(bufnr) ~= "codediff"
    or type(bufnr) ~= "number"
    or bufnr < 1
    or not vim.api.nvim_buf_is_valid(bufnr) then
    return nil
  end

  local layout = vim.b[bufnr].gh_pr_codediff_layout
  if layout == "inline" or layout == "side-by-side" then
    return layout
  end
  return nil
end

local function using_virtual_diff_backend(bufnr)
  return diff_view_runtime.current_diff_backend(bufnr) == "virtual"
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

local positive_integer = coerce.positive_integer

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
  return diff_view_core.normalize_mode(mode, "vertical")
end

function diff_view_runtime.normalize_diff_whitespace_mode(mode, legacy_ignore_whitespace, fallback)
  return diff_view_core.resolve_whitespace_mode(mode, legacy_ignore_whitespace, fallback or "none")
end

function diff_view_runtime.display_keybinding(key)
  if type(key) ~= "string" or key == "" then
    return ""
  end

  local leader = type(vim.g.mapleader) == "string" and vim.g.mapleader or "\\"
  if leader == "" then
    leader = "\\"
  end

  local localleader = type(vim.g.maplocalleader) == "string" and vim.g.maplocalleader or ","
  if localleader == "" then
    localleader = ","
  end

  local expanded = key
    :gsub("<[Ll]eader>", leader)
    :gsub("<[Ll]ocal[Ll]eader>", localleader)
  return vim.fn.keytrans(vim.api.nvim_replace_termcodes(expanded, true, true, true))
end

local function diff_view_shortcuts(backend)
  local diff_view = (config.get() or {}).diff_view or {}
  local resolved, diagnostics = diff_shortcuts_config.resolve_effective(diff_view.shortcuts, {
    backend = backend or "virtual",
  })
  diff_shortcuts_config.notify_resolution_issues(diagnostics, {
    prefix = backend == "codediff" and "gh-pr codediff shortcuts" or "gh-pr diff shortcuts",
  })
  return resolved, diagnostics
end

function diff_view_runtime.clear_legacy_buffer_keymaps(bufnr)
  if type(bufnr) ~= "number" or bufnr < 1 or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  for _, lhs in ipairs(diff_shortcuts_config.legacy_buffer_shortcuts()) do
    pcall(vim.keymap.del, "n", lhs, { buffer = bufnr })
  end

  local legacy = diff_shortcuts_config.expand_localleader(diff_shortcuts_config.legacy_defaults)
  for _, lhs in ipairs({
    legacy.inline_comment,
    legacy.inline_suggestion,
  }) do
    if type(lhs) == "string" and lhs ~= "" then
      pcall(vim.keymap.del, "x", lhs, { buffer = bufnr })
    end
  end
end

local function current_diff_view_preferences(overrides)
  local config_defaults = ((config.get() or {}).diff_view or {})
  local persisted = type(state.get_persisted_diff_view_prefs) == "function" and state.get_persisted_diff_view_prefs() or nil
  -- Lua config defines the default diff experience; persisted state only overrides it when the
  -- user has changed diff prefs at runtime and `state.json` actually contains a diff_view payload.
  local default_whitespace_mode = diff_view_runtime.normalize_diff_whitespace_mode(
    config_defaults.ignore_whitespace_mode,
    config_defaults.ignore_whitespace,
    "none"
  )
  local prefs = vim.tbl_deep_extend("force", {
    mode = normalize_diff_view_mode(config_defaults.mode),
    ignore_whitespace_mode = default_whitespace_mode,
    ignore_whitespace = diff_view_core.legacy_ignore_whitespace(default_whitespace_mode),
    render_whitespace = config_defaults.render_whitespace ~= false,
    render_endlines = config_defaults.render_endlines == true,
  }, persisted or {})

  prefs.mode = normalize_diff_view_mode(prefs.mode)
  prefs.ignore_whitespace_mode = diff_view_runtime.normalize_diff_whitespace_mode(
    prefs.ignore_whitespace_mode,
    prefs.ignore_whitespace,
    default_whitespace_mode
  )
  prefs.ignore_whitespace = diff_view_core.legacy_ignore_whitespace(prefs.ignore_whitespace_mode)
  prefs.render_whitespace = prefs.render_whitespace ~= false
  prefs.render_endlines = prefs.render_endlines == true

  if type(overrides) == "table" then
    if overrides.mode ~= nil then
      prefs.mode = normalize_diff_view_mode(overrides.mode)
    end
    if overrides.ignore_whitespace_mode ~= nil then
      prefs.ignore_whitespace_mode = diff_view_runtime.normalize_diff_whitespace_mode(
        overrides.ignore_whitespace_mode,
        nil,
        prefs.ignore_whitespace_mode
      )
    elseif type(overrides.ignore_whitespace) == "boolean" then
      prefs.ignore_whitespace_mode = diff_view_runtime.normalize_diff_whitespace_mode(
        nil,
        overrides.ignore_whitespace,
        prefs.ignore_whitespace_mode
      )
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

  prefs.ignore_whitespace_mode = diff_view_runtime.normalize_diff_whitespace_mode(
    prefs.ignore_whitespace_mode,
    prefs.ignore_whitespace,
    default_whitespace_mode
  )
  prefs.ignore_whitespace = diff_view_core.legacy_ignore_whitespace(prefs.ignore_whitespace_mode)

  return prefs
end

local function persist_diff_view_preferences(prefs)
  local ignore_whitespace_mode = diff_view_runtime.normalize_diff_whitespace_mode(
    prefs and prefs.ignore_whitespace_mode,
    prefs and prefs.ignore_whitespace,
    "none"
  )
  local sanitized = {
    mode = normalize_diff_view_mode(prefs and prefs.mode),
    ignore_whitespace_mode = ignore_whitespace_mode,
    ignore_whitespace = diff_view_core.legacy_ignore_whitespace(ignore_whitespace_mode),
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

function diff_view_runtime.resolve_requested_file_diff_backend(diff_view, uses_non_text_preview)
  if uses_non_text_preview then
    return "virtual"
  end
  if diff_view_core.supports_codediff_text_backend(diff_view) then
    return "codediff"
  end
  return "virtual"
end

function diff_view_runtime.open_file_diff_with_backend(opts)
  opts = type(opts) == "table" and opts or {}
  local diff_view = current_diff_view_preferences({
    mode = opts.view_mode,
    ignore_whitespace_mode = opts.ignore_whitespace_mode,
    ignore_whitespace = opts.ignore_whitespace,
    render_whitespace = opts.render_whitespace,
    render_endlines = opts.render_endlines,
  })

  local preferred_backend = diff_view_runtime.resolve_requested_file_diff_backend(diff_view, opts.uses_non_text_preview)
  local open_virtual = function()
    return opts.open_virtual(diff_view)
  end

  if preferred_backend == "virtual" then
    return open_virtual()
  end

  return open_diff_with_forced_backend({
    open_primary = function()
      return opts.open_codediff(diff_view)
    end,
    open_virtual = open_virtual,
  })
end

function diff_view_runtime.focus_virtual_diff_result(diff_result, opts)
  if type(diff_result) ~= "table" then
    return
  end

  local target_side = type(opts.target_side) == "string" and opts.target_side:lower() or "head"
  if target_side ~= "base" then
    target_side = "head"
  end
  local target_line = target_side == "base"
      and positive_integer(opts.target_original_line, positive_integer(opts.target_line, nil))
    or positive_integer(opts.target_line, positive_integer(opts.target_original_line, nil))
  if type(target_line) ~= "number" or target_line < 1 then
    return
  end

  local target_buf = nil
  if target_side == "base" then
    target_buf = tonumber(diff_result.base_buf) or tonumber(diff_result.single_buf) or tonumber(diff_result.unified_buf)
  else
    target_buf = tonumber(diff_result.head_buf) or tonumber(diff_result.single_buf) or tonumber(diff_result.unified_buf)
  end
  if not target_buf then
    target_buf = tonumber(diff_result.head_buf) or tonumber(diff_result.base_buf)
  end

  if type(target_buf) ~= "number" or target_buf < 1 or not is_valid_buf(target_buf) then
    return
  end

  local winid = vim.fn.bufwinid(target_buf)
  if type(winid) == "number" and winid > 0 and is_valid_win(winid) then
    pcall(vim.api.nvim_set_current_win, winid)
    restore_cursor_line(winid, target_line)
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

local function valid_window(winid)
  return type(winid) == "number" and winid > 0 and vim.api.nvim_win_is_valid(winid)
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
  return coerce.normalize_line_number(value)
end

local function normalize_line_range(start_line, line)
  return coerce.normalize_line_range(start_line, line)
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
  local bufnr = vim.api.nvim_get_current_buf()
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
    if diff_view_runtime.current_diff_backend(bufnr) == "codediff"
      and diff_view_runtime.current_codediff_layout(bufnr) == "inline" then
      local file_mode = type(vim.b.gh_pr_file_mode) == "string" and vim.b.gh_pr_file_mode or ""
      if file_mode == "added_single" then
        return validate_added_inline_target(path, start_line, line)
      end
      return validate_head_inline_target(pr.number, selected_file, path, start_line, line)
    end
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

  for tabpage, entry in pairs(codediff_file_runtime.by_tabpage) do
    if type(entry) == "table" and tonumber(((entry.pr or {}).number)) == pr_number then
      entry.comments_ctx = vim.deepcopy(context)
      entry.version = (tonumber(entry.version) or 0) + 1
      codediff_file_runtime.rehydrate(tabpage)
    end
  end

  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_is_loaded(bufnr) then
      local buffer_pr = vim.b[bufnr].gh_pr_number
      local kind = vim.b[bufnr].gh_pr_file_kind
      local file_path = vim.b[bufnr].gh_pr_path
      local backend = vim.b[bufnr].gh_pr_diff_backend

      if buffer_pr == pr_number
        and backend ~= "codediff"
        and (kind == "base" or kind == "head" or kind == "unified")
        and type(file_path) == "string"
        and file_path ~= "" then
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

thread_diff_module.register(M, {
  apply_codediff_open_result_context = thread_diff_module.apply_codediff_open_result_context,
  buffer_filetype = buffer_filetype,
  build_line_comment_context = build_line_comment_context,
  codediff_integration = codediff_integration,
  codediff_file_runtime = codediff_file_runtime,
  config = config,
  diff_view_shortcuts = diff_view_shortcuts,
  diff_view_runtime = diff_view_runtime,
  is_valid_buf = is_valid_buf,
  is_valid_win = is_valid_win,
  line_comments = line_comments,
  non_text_preview = non_text_preview,
  normalize_path = normalize_path,
  normalize_repository = normalize_repository,
  notify_error = notify_error,
  notify_info = notify_info,
  notify_warn = notify_warn,
  open_diff_with_forced_backend = open_diff_with_forced_backend,
  positive_integer = positive_integer,
  pr_service = pr_service,
  resolve_active_pr = resolve_active_pr,
  resolve_canonical_file_path = resolve_canonical_file_path,
  safe_string = safe_string,
  state = state,
  url_open = url_open,
  virtual_files = virtual_files,
})

file_diff_module.register(M, {
  build_line_comment_context = build_line_comment_context,
  codediff_integration = codediff_integration,
  comment_popup = comment_popup,
  config = config,
  current_diff_view_preferences = current_diff_view_preferences,
  diff_actions = diff_actions,
  diff_shortcuts_config = diff_shortcuts_config,
  diff_view_core = diff_view_core,
  diff_view_runtime = diff_view_runtime,
  diff_view_shortcuts = diff_view_shortcuts,
  is_valid_buf = is_valid_buf,
  is_valid_win = is_valid_win,
  jump_to_line = jump_to_line,
  non_text_preview = non_text_preview,
  normalize_path = normalize_path,
  normalize_repository = normalize_repository,
  notify_error = notify_error,
  notify_info = notify_info,
  notify_warn = notify_warn,
  open_diff_with_forced_backend = open_diff_with_forced_backend,
  open_review_tree_from_plugin = open_review_tree_from_plugin,
  persist_diff_view_preferences = persist_diff_view_preferences,
  positive_integer = positive_integer,
  pr_service = pr_service,
  repo = repo,
  refresh_pr_sources_after_state_change = refresh_pr_sources_after_state_change,
  require_virtual_diff_backend = require_virtual_diff_backend,
  resolve_active_pr = resolve_active_pr,
  resolve_current_diff_file = resolve_current_diff_file,
  resolve_file = resolve_file,
  restore_cursor_line = restore_cursor_line,
  safe_string = safe_string,
  state = state,
  thread_diff_helpers = thread_diff_module,
  using_virtual_diff_backend = using_virtual_diff_backend,
  valid_window = valid_window,
  virtual_files = virtual_files,
})

review_module.register(M, {
  normalize_path = normalize_path,
  normalize_repository = normalize_repository,
  notify_error = notify_error,
  notify_info = notify_info,
  notify_warn = notify_warn,
  open_review_tree_from_plugin = open_review_tree_from_plugin,
  pr_service = pr_service,
  render_pr_sources_from_cache = render_pr_sources_from_cache,
  resolve_active_pr = resolve_active_pr,
  resolve_canonical_file_path = resolve_canonical_file_path,
  resolve_file = resolve_file,
  review_prefetch = review_prefetch,
  state = state,
  sync_remote_viewed_state_for_pr = sync_remote_viewed_state_for_pr,
})

non_text_preview.register(M, {
  diff_view_shortcuts = diff_view_shortcuts,
  resolve_active_pr = resolve_active_pr,
})

navigation_actions.register(M, {
  comment_popup = comment_popup,
  config = config,
  find_file_in_details = find_file_in_details,
  has_full_pr_details = has_full_pr_details,
  is_valid_buf = is_valid_buf,
  normalize_path = normalize_path,
  notify_error = notify_error,
  notify_warn = notify_warn,
  positive_integer = positive_integer,
  refresh_diff_comments_panel_after_state_change = refresh_diff_comments_panel_after_state_change,
  refresh_line_comments_for_pr = refresh_line_comments_for_pr,
  refresh_pr_sources_after_state_change = refresh_pr_sources_after_state_change,
  resolve_active_pr = resolve_active_pr,
  resolve_file_in_details = resolve_file_in_details,
  safe_string = safe_string,
  state = state,
  thread_popup = thread_popup,
  url_open = url_open,
  valid_window = valid_window,
})

M._open_target_helpers = {
  dangerous_local_open_extensions = vim.deepcopy(non_text_preview.dangerous_local_open_extensions),
  effective_local_open_policy = non_text_preview.effective_local_open_policy,
  normalize_local_open_policy = non_text_preview.normalize_local_open_policy,
  resolve_attachment_filename = non_text_preview.resolve_attachment_filename,
}

M._diff_view_helpers = {
  current_diff_view_preferences = current_diff_view_preferences,
  resolve_requested_file_diff_backend = diff_view_runtime.resolve_requested_file_diff_backend,
  diff_shortcut_lines = file_diff_module.diff_shortcut_lines,
  diff_view_shortcuts = diff_view_shortcuts,
  apply_codediff_buffer_keymaps = thread_diff_module.apply_codediff_buffer_keymaps,
  apply_codediff_open_result_context = thread_diff_module.apply_codediff_open_result_context,
  build_codediff_inline_comment_line_map = thread_diff_module.codediff_file_runtime.build_inline_comment_line_map,
  rehydrate_codediff_file_runtime = thread_diff_module.codediff_file_runtime.rehydrate,
}

return M





