local cache_store = require("gh-pr.cache_store")
local comments_source = require("gh-pr.neotree.comments_source")
local config = require("gh-pr.config")
local follow = require("gh-pr.neotree.follow")
local highlights = require("gh-pr.highlights")
local review_prefetch = require("gh-pr.core.review_prefetch")
local review_context = require("gh-pr.core.review_context")
local review_checks_section = require("gh-pr.neotree.review_sections.checks")
local review_comments_section = require("gh-pr.neotree.review_sections.comments")
local review_drafts_section = require("gh-pr.neotree.review_sections.drafts")
local review_files_section = require("gh-pr.neotree.review_sections.files")
local review_overview_section = require("gh-pr.neotree.review_sections.overview")
local review_reviewers_section = require("gh-pr.neotree.review_sections.reviewers")
local review_security_section = require("gh-pr.neotree.review_sections.security")
local pr_service = require("gh-pr.pr_service")
local repo = require("gh-pr.repo")
local runtime_state = require("gh-pr.state")
local virtual_files = require("gh-pr.virtual_files")

local renderer = require("neo-tree.ui.renderer")

local function create(provider)
  provider = type(provider) == "table" and provider or {}

  local source_name = type(provider.source_name) == "string" and provider.source_name ~= "" and provider.source_name
    or "gh_pr_review"
  local display_name = type(provider.display_name) == "string" and provider.display_name ~= "" and provider.display_name
    or "GH PR Review"
  local cache_key = type(provider.cache_key) == "string" and provider.cache_key ~= "" and provider.cache_key or source_name
  local state_repo_key_field = type(provider.state_repo_key_field) == "string"
      and provider.state_repo_key_field ~= ""
      and provider.state_repo_key_field
    or (source_name .. "_repo_key")
  local id_prefix = type(provider.id_prefix) == "string" and provider.id_prefix ~= "" and provider.id_prefix
    or source_name:gsub("_", "-")
  local source_label = type(provider.source_label) == "string" and provider.source_label ~= "" and provider.source_label
    or display_name
  local loading_message = type(provider.loading_message) == "string" and provider.loading_message ~= ""
      and provider.loading_message
    or "Loading PR review..."
  local stale_message = type(provider.stale_message) == "string" and provider.stale_message ~= ""
      and provider.stale_message
    or "Showing cached PR review while refreshing..."
  local no_target_message = type(provider.no_target_message) == "string" and provider.no_target_message ~= ""
      and provider.no_target_message
    or "No active review for this repository. Use 'Start Review' from PR source."
  local not_git_message = type(provider.not_git_message) == "string" and provider.not_git_message ~= ""
      and provider.not_git_message
    or "Open a git repository to use gh-pr review"
  local repo_error_prefix = type(provider.repo_error_prefix) == "string" and provider.repo_error_prefix ~= ""
      and provider.repo_error_prefix
    or "Unable to resolve repository: "
  local apply_provider_runtime_target
  local sync_runtime = type(provider.sync_runtime) == "function" and provider.sync_runtime or nil
  local apply_runtime_target = type(provider.apply_runtime_target) == "function" and provider.apply_runtime_target or nil
  local resolve_target_async = type(provider.resolve_target_async) == "function" and provider.resolve_target_async or nil
  local should_prefetch_review = type(provider.should_prefetch_review) == "function" and provider.should_prefetch_review or nil

  if type(sync_runtime) ~= "function" then
    sync_runtime = function(repo_full_name, details)
      runtime_state.set_active_pr(details, details)
      runtime_state.set_active_review(repo_full_name, details, details)
    end
  end

  if type(apply_runtime_target) ~= "function" then
    apply_runtime_target = function(_, repo_context)
      if type(repo_context) ~= "table" or type(repo_context.repository) ~= "table" then
        return nil
      end

      local pr, details = runtime_state.get_active_review(repo_context.repository.full_name)
      if type(pr) ~= "table" then
        return {
          reason = no_target_message,
        }
      end

      return {
        pr = pr,
        details = details or pr,
      }
    end
  end

  if type(resolve_target_async) ~= "function" then
    resolve_target_async = function(repo_context, session, callback)
      callback = type(callback) == "function" and callback or function() end
      apply_provider_runtime_target(session, repo_context)
      if type(session) ~= "table" or type(session.target_pr) ~= "table" then
        callback(nil, nil)
        return
      end

      callback({
        pr = session.target_pr,
        details = session.target_details or session.target_pr,
        branch = session.branch_name,
      }, nil)
    end
  end

  local M = {
    name = source_name,
    display_name = display_name,
  }

  local DEFAULT_RENDERERS = {
    folder = {
      { "indent", with_expanders = true },
      { "kind_icon" },
      { "container", width = "100%", content = { { "folder_viewed_badge", zindex = 10 }, { "name", zindex = 11 } } },
    },
    files = {
      { "indent", with_expanders = true },
      { "kind_icon" },
      { "container", width = "100%", content = { { "name", zindex = 10 } } },
    },
    overview = {
      { "indent", with_expanders = false },
      { "kind_icon" },
      { "container", width = "100%", content = { { "name", zindex = 10 } } },
    },
    directory = {
      { "indent", with_expanders = true },
      { "kind_icon" },
      { "container", width = "100%", content = { { "folder_viewed_badge", zindex = 10 }, { "name", zindex = 11 } } },
    },
    commit = {
      { "indent", with_expanders = false },
      { "kind_icon" },
      { "container", width = "100%", content = { { "name", zindex = 10 } } },
    },
    file = {
      { "indent", with_expanders = false },
      { "kind_icon" },
      {
        "container",
        width = "100%",
        content = {
          { "name", zindex = 10 },
          { "file_parent_path", zindex = 10 },
          { "file_review_badges", zindex = 20, align = "right" },
        },
      },
    },
    comment_file = {
      { "indent", with_expanders = true },
      { "kind_icon" },
      { "container", width = "100%", content = { { "name", zindex = 10 } } },
    },
    message = {
      { "indent", with_markers = false, with_expanders = false },
      { "kind_icon" },
      { "name", highlight = "NeoTreeMessage" },
    },
  }

  local runtime_cache = {
    repos = {},
    last_prune_at = 0,
  }

  local REFRESH_MODE_UI = "ui-refresh"
  local REFRESH_MODE_CACHE_ONLY = "cache-only"
  local SOURCE_NAME = source_name
  local FILE_FILTER_STATUS = {
    all = true,
    added = true,
    modified = true,
    deleted = true,
    renamed = true,
    copied = true,
  }

local function default_file_filters()
  return {
    path_query = "",
    status = "all",
    extension = "",
    no_extension = false,
    dotfiles = false,
    viewed_state = "all",
    hide_viewed = nil,
    hide_deleted = false,
  }
end

local function sanitize_file_filters(input)
  local filters = vim.tbl_extend("force", default_file_filters(), type(input) == "table" and input or {})
  filters.path_query = type(filters.path_query) == "string" and vim.trim(filters.path_query) or ""
  filters.status = type(filters.status) == "string" and filters.status:lower() or "all"
  if not FILE_FILTER_STATUS[filters.status] then
    filters.status = "all"
  end
  filters.extension = type(filters.extension) == "string" and vim.trim(filters.extension):lower() or ""
  filters.extension = filters.extension:gsub("^%.+", "")
  filters.no_extension = filters.no_extension == true
  filters.dotfiles = filters.dotfiles == true
  filters.viewed_state = type(filters.viewed_state) == "string" and filters.viewed_state:lower() or "all"
  if filters.viewed_state ~= "viewed" and filters.viewed_state ~= "unviewed" then
    filters.viewed_state = "all"
  end
  if type(filters.hide_viewed) ~= "boolean" then
    filters.hide_viewed = nil
  end
  filters.hide_deleted = filters.hide_deleted == true
  return filters
end

local function valid_window(winid)
  return type(winid) == "number" and winid > 0 and vim.api.nvim_win_is_valid(winid)
end

local function valid_buffer(bufnr)
  return type(bufnr) == "number" and bufnr > 0 and vim.api.nvim_buf_is_valid(bufnr)
end

local function source_buffer(bufnr)
  if not valid_buffer(bufnr) then
    return false
  end

  local ok, filetype = pcall(vim.api.nvim_get_option_value, "filetype", { buf = bufnr })
  if not ok then
    filetype = vim.bo[bufnr].filetype
  end
  if filetype ~= "neo-tree" then
    return false
  end

  return vim.b[bufnr].neo_tree_source == SOURCE_NAME
end

local function live_state_window_buffer(state)
  if type(state) ~= "table" then
    return nil, nil
  end

  local winid = tonumber(state.winid)
  if not valid_window(winid) then
    return nil, nil
  end

  local win_buf = vim.api.nvim_win_get_buf(winid)
  if not valid_buffer(win_buf) then
    return nil, nil
  end

  return winid, win_buf
end

local function state_is_live(state)
  local _, bufnr = live_state_window_buffer(state)
  if not bufnr then
    return false
  end
  return source_buffer(bufnr)
end

local function state_can_render(state, opts)
  opts = opts or {}
  if type(state) ~= "table" then
    return false
  end

  if state_is_live(state) then
    return true
  end

  if opts.allow_unattached ~= true then
    return false
  end

  return state.disposed ~= true
end

local function resolve_current_live_state()
  local winid = vim.api.nvim_get_current_win()
  if not valid_window(winid) then
    return false, nil
  end

  local bufnr = vim.api.nvim_win_get_buf(winid)
  if not source_buffer(bufnr) then
    return false, nil
  end

  local state = nil
  local manager_ok, manager = pcall(require, "neo-tree.sources.manager")
  if manager_ok and type(manager.get_state_for_window) == "function" then
    local ok, resolved_state = pcall(manager.get_state_for_window, winid)
    if ok and state_is_live(resolved_state) then
      state = resolved_state
    end
  end

  return true, state
end

local function now_seconds()
  return os.time()
end

local function normalize_refresh_context(context)
  local source = type(context) == "table" and context or {}
  local mode = source.mode == REFRESH_MODE_CACHE_ONLY and REFRESH_MODE_CACHE_ONLY or REFRESH_MODE_UI
  local reason = type(source.reason) == "string" and source.reason ~= "" and source.reason or "manual"
  local notify
  if type(source.notify) == "boolean" then
    notify = source.notify
  else
    notify = mode == REFRESH_MODE_UI and reason == "timer"
  end

  return {
    mode = mode,
    reason = reason,
    notify = notify,
  }
end

local function merge_refresh_context(current, incoming)
  local left = normalize_refresh_context(current)
  local right = normalize_refresh_context(incoming)
  return {
    mode = (left.mode == REFRESH_MODE_UI or right.mode == REFRESH_MODE_UI) and REFRESH_MODE_UI
      or REFRESH_MODE_CACHE_ONLY,
    reason = right.reason ~= "" and right.reason or left.reason,
    notify = left.notify == true or right.notify == true,
  }
end

local function should_update_ui(refresh_context)
  return type(refresh_context) == "table" and refresh_context.mode == REFRESH_MODE_UI
end

local function should_notify_manual_refresh(refresh_context)
  return should_update_ui(refresh_context) and refresh_context.reason == "manual" and refresh_context.notify == true
end

local function queue_pending_refresh(session, opts)
  local pending = type(session.pending_refresh) == "table" and session.pending_refresh or {
    force = false,
    refresh_context = normalize_refresh_context(nil),
  }

  pending.force = pending.force == true or opts.force == true
  pending.refresh_context = merge_refresh_context(pending.refresh_context, opts.refresh_context)
  session.pending_refresh = pending
end

local function consume_pending_refresh(session)
  local pending = type(session.pending_refresh) == "table" and session.pending_refresh or nil
  session.pending_refresh = nil
  if type(pending) ~= "table" then
    return nil
  end

  pending.force = pending.force == true
  pending.refresh_context = normalize_refresh_context(pending.refresh_context)
  return pending
end

local function has_full_details(details)
  return type(details) == "table" and type(details.files) == "table"
end

local function cache_options()
  local options = (config.get() or {}).cache or {}
  local review_options = type(options[cache_key]) == "table" and options[cache_key] or {}
  return review_options
end

local function cache_enabled()
  return cache_options().enabled ~= false
end

local function make_repo_key(repository, git_root)
  if type(repository) ~= "table" or type(repository.full_name) ~= "string" then
    return nil
  end

  local root = type(git_root) == "string" and git_root or ""
  return repository.full_name .. "::" .. root
end

local function persisted_cache_key(repo_key)
  return tostring(repo_key) .. "::" .. cache_key
end

local function resolve_repo_context()
  local repository, repository_err = pr_service.resolve_repository()
  if not repository then
    return nil, repository_err
  end

  local git_root, git_root_err = repo.git_root()
  if not git_root then
    git_root = vim.fn.getcwd()
    if git_root_err then
      vim.schedule(function()
        vim.notify("gh-pr cache root fallback: " .. tostring(git_root_err), vim.log.levels.DEBUG)
      end)
    end
  end

  local key = make_repo_key(repository, git_root)
  if not key then
    return nil, "Unable to build cache key for repository"
  end

  return {
    key = key,
    repository = repository,
    git_root = git_root,
  }, nil
end

local function session_is_stale(session)
  local options = cache_options()
  local max_cache_age = tonumber(options.max_cache_age_seconds) or 0
  local updated_at = tonumber(session.updated_at) or 0

  if session.last_error and has_full_details(session.details) then
    return true
  end

  if updated_at <= 0 then
    return has_full_details(session.details)
  end

  if max_cache_age > 0 and (now_seconds() - updated_at) > max_cache_age then
    return true
  end

  return false
end

local function maybe_prune_persisted_cache()
  if not cache_enabled() then
    return
  end

  local options = cache_options()
  local max_age = tonumber(options.max_cache_age_seconds) or 0
  if max_age < 1 then
    return
  end

  local now = now_seconds()
  if runtime_cache.last_prune_at > 0 and (now - runtime_cache.last_prune_at) < 60 then
    return
  end

  runtime_cache.last_prune_at = now
  cache_store.prune(max_age, now)
end

local function dedupe_details_files(details)
  if type(details) ~= "table" then
    return details
  end

  local files = type(details.files) == "table" and details.files or nil
  if not files then
    return details
  end

  local deduped = {}
  local seen = {}
  for _, file in ipairs(files) do
    local path = type(file) == "table" and (file.path or file.filename) or nil
    if type(path) == "string" and path ~= "" and not seen[path] then
      seen[path] = true
      deduped[#deduped + 1] = file
    end
  end
  details.files = deduped
  return details
end

local function new_repo_session(repo_context)
  return {
    key = repo_context.key,
    repository = repo_context.repository,
    git_root = repo_context.git_root,
    states = {},
    target_pr = nil,
    target_details = nil,
    target_reason = nil,
    branch_name = nil,
    pr_number = nil,
    details = nil,
    updated_at = 0,
    loading = false,
    inflight = false,
    pending_refresh = nil,
    last_error = nil,
    stale = false,
    follow = {},
    file_filters = default_file_filters(),
    check_annotations_by_key = {},
    check_annotations_generation = 0,
    security_cache = {
      code_scanning = nil,
      dependency_review = nil,
      generation = 0,
    },
    loaded_from_disk = false,
  }
end

local function extract_persisted_details(persisted)
  local details_by_pr = type(persisted) == "table" and persisted.details_by_pr or nil
  if type(details_by_pr) ~= "table" then
    return nil, nil
  end

  for number, details in pairs(details_by_pr) do
    local parsed_number = tonumber(number)
    if parsed_number and type(details) == "table" then
      return parsed_number, details
    end
  end

  return nil, nil
end

local function ensure_repo_session(repo_context)
  runtime_cache.repos[repo_context.key] = runtime_cache.repos[repo_context.key] or new_repo_session(repo_context)
  local session = runtime_cache.repos[repo_context.key]

  session.repository = repo_context.repository
  session.git_root = repo_context.git_root
  session.file_filters = sanitize_file_filters(session.file_filters)

  if cache_enabled() and not session.loaded_from_disk then
    maybe_prune_persisted_cache()
    local persisted = cache_store.get_repo(persisted_cache_key(repo_context.key))
    if type(persisted) == "table" then
      local persisted_pr_number, persisted_details = extract_persisted_details(persisted)
      if persisted_pr_number and type(persisted_details) == "table" then
        session.pr_number = persisted_pr_number
        session.details = dedupe_details_files(persisted_details)
      end
      session.updated_at = tonumber(persisted.updated_at) or 0
      session.stale = session_is_stale(session)
    end
    session.loaded_from_disk = true
  end

  return session
end

local function persist_session(repo_context, session)
  if not cache_enabled() then
    return
  end

  local cache_key = persisted_cache_key(repo_context.key)
  if not has_full_details(session.details) or type(session.pr_number) ~= "number" then
    cache_store.delete_repo(cache_key)
    return
  end

  cache_store.set_repo(cache_key, {
    repository_full_name = repo_context.repository.full_name,
    git_root = repo_context.git_root,
    updated_at = session.updated_at,
    query_results = {},
    details_by_pr = {
      [tostring(session.pr_number)] = session.details,
    },
  })
end

local function register_state(session, state)
  if type(state) ~= "table" then
    return
  end

  local key = tostring(state)
  session.states[key] = state
  state[state_repo_key_field] = session.key
end

local function ensure_follow_state(session)
  if type(session.follow) ~= "table" then
    session.follow = {}
  end
  return session.follow
end

local function ensure_check_annotation_cache(session)
  if type(session) ~= "table" then
    return {}
  end

  if type(session.check_annotations_by_key) ~= "table" then
    session.check_annotations_by_key = {}
  end

  if type(session.check_annotations_generation) ~= "number" then
    session.check_annotations_generation = 0
  end

  return session.check_annotations_by_key
end

local function invalidate_check_annotation_cache(session)
  if type(session) ~= "table" then
    return
  end

  session.check_annotations_by_key = {}
  session.check_annotations_generation = math.max(0, math.floor(tonumber(session.check_annotations_generation) or 0)) + 1
end

local function ensure_security_cache(session)
  if type(session) ~= "table" then
    return {
      code_scanning = nil,
      dependency_review = nil,
      generation = 0,
    }
  end

  if type(session.security_cache) ~= "table" then
    session.security_cache = {
      code_scanning = nil,
      dependency_review = nil,
      generation = 0,
    }
  end

  if type(session.security_cache.generation) ~= "number" then
    session.security_cache.generation = 0
  end

  return session.security_cache
end

local function invalidate_security_cache(session)
  if type(session) ~= "table" then
    return
  end

  session.security_cache = {
    code_scanning = nil,
    dependency_review = nil,
    generation = math.max(0, math.floor(tonumber(type(session.security_cache) == "table" and session.security_cache.generation or 0) or 0))
      + 1,
  }
end

local function remember_revealed_node(session, node_id, context)
  local follow_state = ensure_follow_state(session)
  if type(node_id) == "string" and node_id ~= "" then
    follow_state.last_node_id = node_id
  end

  if type(context) == "table" then
    local pr_number = tonumber(context.pr_number)
    if pr_number then
      follow_state.last_pr = pr_number
    end

    local path = follow.normalize_path(context.path)
    if path ~= "" then
      follow_state.last_path = path
    end
  end
end

local function repository_full_name(details)
  return review_context.resolve_repository_full_name(details)
end

local function build_file_nodes(pr, details, repo_full_name, session)
  local resolved_repo_full_name = review_context.resolve_repository_full_name(details, repo_full_name)
  return review_files_section.build_nodes(pr, details, resolved_repo_full_name, {
    filters = type(session) == "table" and session.file_filters or nil,
  })
end

local function build_reviewer_nodes(pr, details)
  return review_reviewers_section.build_nodes(pr, details)
end

local function short_sha(value)
  if type(value) ~= "string" then
    return ""
  end
  if #value < 8 then
    return value
  end
  return value:sub(1, 8)
end

local function sanitize_node_id_component(value)
  local raw = type(value) == "string" and value or tostring(value or "")
  raw = raw:gsub("[^%w%-%._]", "_")
  if raw == "" then
    return "item"
  end
  return raw
end

local function build_commit_nodes(pr, details)
  local nodes = {}
  local seen_commit_ids = {}
  for _, commit in ipairs(type(details.commits) == "table" and details.commits or {}) do
    local oid = type(commit.oid) == "string" and commit.oid or ""
    local headline = type(commit.messageHeadline) == "string" and commit.messageHeadline or "(no commit headline)"
    local commit_key = oid ~= "" and oid or (headline .. ":" .. tostring(type(commit.url) == "string" and commit.url or ""))
    if not seen_commit_ids[commit_key] then
      seen_commit_ids[commit_key] = true
      nodes[#nodes + 1] = {
        id = string.format("%s:%d:commit:%s", id_prefix, pr.number, oid ~= "" and oid or tostring(#nodes + 1)),
        name = string.format("%s %s", short_sha(oid), headline),
        type = "commit",
        extra = {
          kind = "commit",
          commit = {
            oid = oid,
            parent_oid = type(commit.parent_oid) == "string" and commit.parent_oid or "",
            headline = headline,
            body = type(commit.messageBody) == "string" and commit.messageBody or "",
            url = type(commit.url) == "string" and commit.url or "",
            author = type(commit.author) == "table" and commit.author.login
              or (type(commit.author) == "string" and commit.author or nil),
          },
          pr = pr,
          details = details,
        },
      }
    end
  end

  if vim.tbl_isempty(nodes) then
    return {
      {
        id = string.format("%s:%d:commits-empty", id_prefix, pr.number),
        name = "No commits found",
        type = "message",
        extra = {
          kind = "message",
          pr = pr,
          details = details,
        },
      },
    }
  end

  return nodes
end

local function build_check_nodes(pr, details, session)
  return review_checks_section.build_nodes(pr, details, {
    session = session,
  })
end

local function collect_commit_signature(details)
  local commits = type(details.commits) == "table" and details.commits or {}
  local ids = {}
  local set = {}
  local latest_oid = ""

  for _, commit in ipairs(commits) do
    local oid = type(commit) == "table" and type(commit.oid) == "string" and commit.oid or ""
    if oid ~= "" then
      if latest_oid == "" then
        latest_oid = oid
      end
      ids[#ids + 1] = oid
      set[oid] = true
    end
  end

  return {
    count = #ids,
    ids = ids,
    set = set,
    latest_oid = latest_oid,
    signature = table.concat(ids, "|"),
  }
end

local function collect_check_signature(details)
  return review_checks_section.collect_signature(details)
end

local function build_review_snapshot(pr_number, details)
  if type(details) ~= "table" then
    return nil
  end

  local commits = collect_commit_signature(details)
  local checks = collect_check_signature(details)
  local files_changed = tonumber(details.changedFiles)
  if type(files_changed) ~= "number" then
    files_changed = #(type(details.files) == "table" and details.files or {})
  end

  return {
    pr_number = tonumber(pr_number) or tonumber(details.number),
    state = type(details.state) == "string" and details.state:upper() or "",
    is_draft = details.isDraft == true,
    review_decision = type(details.reviewDecision) == "string" and details.reviewDecision:upper() or "",
    merge_state = type(details.mergeStateStatus) == "string" and details.mergeStateStatus:upper() or "",
    mergeable = tostring(details.mergeable or ""),
    updated_at = type(details.updatedAt) == "string" and details.updatedAt or "",
    files_changed = files_changed,
    commits = commits,
    checks = checks,
  }
end

local function summarize_review_changes(previous_snapshot, current_snapshot)
  if type(previous_snapshot) ~= "table" or type(current_snapshot) ~= "table" then
    return nil
  end

  local summary = {
    pr_number = current_snapshot.pr_number,
    pr_switched = previous_snapshot.pr_number ~= current_snapshot.pr_number,
    state_changes = 0,
    commit_changes = 0,
    new_commits = 0,
    check_changes = 0,
    file_changes = 0,
    metadata_changes = 0,
  }

  if previous_snapshot.state ~= current_snapshot.state
    or previous_snapshot.is_draft ~= current_snapshot.is_draft
    or previous_snapshot.review_decision ~= current_snapshot.review_decision
    or previous_snapshot.merge_state ~= current_snapshot.merge_state
    or previous_snapshot.mergeable ~= current_snapshot.mergeable then
    summary.state_changes = 1
  end

  if previous_snapshot.commits.signature ~= current_snapshot.commits.signature then
    summary.commit_changes = 1
    local new_commit_count = 0
    for oid, _ in pairs(current_snapshot.commits.set or {}) do
      if not previous_snapshot.commits.set[oid] then
        new_commit_count = new_commit_count + 1
      end
    end
    if new_commit_count == 0 and current_snapshot.commits.count > previous_snapshot.commits.count then
      new_commit_count = current_snapshot.commits.count - previous_snapshot.commits.count
    end
    summary.new_commits = math.max(0, new_commit_count)
  end

  if previous_snapshot.checks.signature ~= current_snapshot.checks.signature then
    summary.check_changes = 1
  end

  if previous_snapshot.files_changed ~= current_snapshot.files_changed then
    summary.file_changes = 1
  end

  if summary.state_changes == 0
    and summary.commit_changes == 0
    and summary.check_changes == 0
    and summary.file_changes == 0
    and previous_snapshot.updated_at ~= current_snapshot.updated_at then
    summary.metadata_changes = 1
  end

  if summary.pr_switched
    or summary.state_changes > 0
    or summary.commit_changes > 0
    or summary.check_changes > 0
    or summary.file_changes > 0
    or summary.metadata_changes > 0 then
    return summary
  end

  return nil
end

local function summarize_review_change_message(summary)
  if type(summary) ~= "table" then
    return nil
  end

  local details = {}
  if summary.pr_switched then
    details[#details + 1] = "active review changed"
  end
  if summary.new_commits > 0 then
    details[#details + 1] = string.format("commits:+%d", summary.new_commits)
  elseif summary.commit_changes > 0 then
    details[#details + 1] = "commits updated"
  end
  if summary.state_changes > 0 then
    details[#details + 1] = "state updated"
  end
  if summary.check_changes > 0 then
    details[#details + 1] = "checks updated"
  end
  if summary.file_changes > 0 then
    details[#details + 1] = "files changed"
  end
  if summary.metadata_changes > 0 then
    details[#details + 1] = "metadata updated"
  end

  if vim.tbl_isempty(details) then
    return nil
  end

  local pr_number = tonumber(summary.pr_number)
  if pr_number then
    return string.format("PR #%d updated (%s)", pr_number, table.concat(details, ", "))
  end

  return "PR review updated (" .. table.concat(details, ", ") .. ")"
end

local function refresh_visible_overview_if_needed(pr_number)
  local actions_ok, actions = pcall(require, "gh-pr.actions")
  if not actions_ok or type(actions.refresh_visible_overview_for_pr) ~= "function" then
    return 0
  end

  local ok, refreshed = pcall(actions.refresh_visible_overview_for_pr, pr_number)
  if not ok or type(refreshed) ~= "number" then
    return 0
  end

  return refreshed
end

local function normalize_label_color(value)
  if type(value) ~= "string" then
    return ""
  end
  local cleaned = value:gsub("#", "")
  if cleaned:match("^[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]$") then
    return "#" .. cleaned:upper()
  end
  return ""
end

local function build_label_nodes(pr, details)
  local nodes = {}
  for index, label in ipairs(type(details.labels) == "table" and details.labels or {}) do
    local name = type(label.name) == "string" and label.name or ""
    if name ~= "" then
      nodes[#nodes + 1] = {
        id = string.format("%s:%d:label:%s:%d", id_prefix, pr.number, sanitize_node_id_component(name), index),
        name = name,
        type = "file",
        extra = {
          kind = "label",
          label_name = name,
          label_color = normalize_label_color(label.color),
          label_description = type(label.description) == "string" and label.description or "",
          pr = pr,
          details = details,
        },
      }
    end
  end

  table.sort(nodes, function(left, right)
    return left.name:lower() < right.name:lower()
  end)

  if vim.tbl_isempty(nodes) then
    return {
      {
        id = string.format("%s:%d:labels-empty", id_prefix, pr.number),
        name = "No labels",
        type = "message",
        extra = {
          kind = "message",
          pr = pr,
          details = details,
        },
      },
    }
  end

  return nodes
end

local function build_comment_nodes(pr, details)
  return review_comments_section.build_nodes(pr, details, {
    repository = repository_full_name(details),
  })
end

local function build_draft_nodes(pr, details)
  return review_drafts_section.build_nodes(pr, details)
end

local function build_security_nodes(pr, details, session)
  return review_security_section.build_nodes(pr, details, session)
end

local function build_root_nodes(pr, details, repo_full_name, session)
  local files_children, viewed_files, total_files, files_meta = build_file_nodes(pr, details, repo_full_name, session)
  local labels_children = build_label_nodes(pr, details)
  local reviewers_children = build_reviewer_nodes(pr, details)
  local commits_children = build_commit_nodes(pr, details)
  local checks_children = build_check_nodes(pr, details, session)
  local security_children = build_security_nodes(pr, details, session)
  local comments_children = build_comment_nodes(pr, details)
  local drafts_children = build_draft_nodes(pr, details)
  local reviewer_states, _ = review_reviewers_section.count_states(reviewers_children)
  local commits_total = review_overview_section.count_commit_entries(commits_children)
  local check_states, _ = review_checks_section.count_states(checks_children)

  return review_overview_section.build_root_nodes(pr, details, {
    labels = labels_children,
    files = {
      title = review_overview_section.files_title(viewed_files, total_files, files_meta),
      children = files_children,
    },
    reviewers = {
      title = review_overview_section.reviewers_title(reviewer_states),
      children = reviewers_children,
    },
    commits = {
      title = review_overview_section.commits_title(commits_total),
      children = commits_children,
    },
    checks = {
      title = review_overview_section.checks_title(check_states),
      children = checks_children,
    },
    security = {
      title = review_overview_section.security_title(review_security_section.build_section_title(session)),
      children = security_children,
    },
    comments = {
      title = review_comments_section.build_section_title(details),
      children = comments_children,
    },
    drafts = {
      title = review_drafts_section.build_section_title(details),
      children = drafts_children,
    },
  })
end

local function append_nodes(target, items)
  for _, item in ipairs(type(items) == "table" and items or {}) do
    target[#target + 1] = item
  end
end

local function message_node(id, text)
  return {
    id = id,
    name = text,
    type = "message",
    extra = { kind = "message" },
  }
end

apply_provider_runtime_target = function(session, repo_context)
  if type(apply_runtime_target) ~= "function" or type(session) ~= "table" then
    return
  end

  local target = apply_runtime_target(session, repo_context)
  if type(target) ~= "table" then
    session.target_pr = nil
    session.target_details = nil
    session.target_reason = nil
    return
  end

  session.target_pr = type(target.pr) == "table" and target.pr or target.details
  session.target_details = type(target.details) == "table" and target.details or session.target_pr
  session.target_reason = type(target.reason) == "string" and target.reason or nil
  session.branch_name = type(target.branch) == "string" and target.branch or session.branch_name
end

local function active_target_for_repo(repo_context, session)
  apply_provider_runtime_target(session, repo_context)
  return session.target_pr, session.target_details
end

local function matching_details(session, review_pr)
  local review_number = type(review_pr) == "table" and tonumber(review_pr.number) or nil
  if not review_number then
    return nil
  end

  if tonumber(session.pr_number) ~= review_number then
    return nil
  end

  if not has_full_details(session.details) then
    return nil
  end

  return session.details
end

local function build_nodes(session, repo_context)
  local nodes = {}
  local show_stale_badge = cache_options().show_stale_badge ~= false
  local review_pr, _ = active_target_for_repo(repo_context, session)
  local details = matching_details(session, review_pr)

  if session.last_error then
    nodes[#nodes + 1] = message_node(
      id_prefix .. ":refresh-error:" .. repo_context.key,
      "Refresh error: " .. tostring(session.last_error)
    )
  end

  if not review_pr then
    nodes[#nodes + 1] = message_node(
      id_prefix .. ":no-active:" .. repo_context.key,
      session.target_reason or no_target_message
    )
    return nodes
  end

  if session.loading and not details then
    nodes[#nodes + 1] = message_node(id_prefix .. ":loading:" .. repo_context.key, loading_message)
    return nodes
  end

  if not details then
    nodes[#nodes + 1] = message_node(id_prefix .. ":empty:" .. repo_context.key, loading_message)
    return nodes
  end

  if show_stale_badge and session.stale then
    nodes[#nodes + 1] = message_node(
      id_prefix .. ":stale:" .. repo_context.key,
      stale_message
    )
  end

  append_nodes(nodes, build_root_nodes(details, details, repo_context.repository.full_name, session))
  return nodes
end

local function render_state(state, session, repo_context, opts)
  opts = type(opts) == "table" and opts or {}
  if not state_can_render(state, opts) then
    return false
  end

  local details = matching_details(session, active_target_for_repo(repo_context, session))
  if details and opts.sync_runtime ~= false and type(sync_runtime) == "function" then
    sync_runtime(repo_context.repository.full_name, details)
  end

  local ok = pcall(renderer.show_nodes, build_nodes(session, repo_context), state)
  return ok
end

local function visible_repo_states(repo_key)
  local visible = {}
  for _, state in ipairs(follow.visible_source_states(SOURCE_NAME)) do
    if type(state) == "table" and state[state_repo_key_field] == repo_key then
      visible[#visible + 1] = state
    end
  end
  return visible
end

local function current_repo_state_is_focused(repo_key)
  local focused, state = resolve_current_live_state()
  if not focused or type(state) ~= "table" then
    return false
  end
  return state[state_repo_key_field] == repo_key
end

local function render_repo_states(repo_key)
  local session = runtime_cache.repos[repo_key]
  if type(session) ~= "table" then
    return
  end

  local repo_context = {
    key = repo_key,
    repository = session.repository,
    git_root = session.git_root,
  }

  for state_key, state in pairs(session.states) do
    if type(state) ~= "table" or state[state_repo_key_field] ~= repo_key or not state_is_live(state) then
      session.states[state_key] = nil
      goto continue
    end

    local ok = render_state(state, session, repo_context)
    if not ok then
      session.states[state_key] = nil
    end
    ::continue::
  end
end

local function render_visible_repo_states(repo_key, opts)
  local session = runtime_cache.repos[repo_key]
  if type(session) ~= "table" then
    return false
  end

  local repo_context = {
    key = repo_key,
    repository = session.repository,
    git_root = session.git_root,
  }

  local render_opts = type(opts) == "table" and vim.deepcopy(opts) or {}
  if render_opts.sync_runtime == nil then
    render_opts.sync_runtime = false
  end

  local rendered = false
  for _, state in ipairs(visible_repo_states(repo_key)) do
    register_state(session, state)
    local ok = render_state(state, session, repo_context, render_opts)
    if ok then
      rendered = true
    else
      session.states[tostring(state)] = nil
    end
  end

  return rendered
end

local function resolve_repo_context_for_state(state)
  local repo_key = type(state) == "table" and type(state[state_repo_key_field]) == "string" and state[state_repo_key_field]
    or nil
  local session = type(repo_key) == "string" and runtime_cache.repos[repo_key] or nil
  if type(session) == "table" and type(session.repository) == "table" then
    return {
      key = repo_key,
      repository = session.repository,
      git_root = session.git_root,
    }, session
  end

  local repo_context, context_err = resolve_repo_context()
  if not repo_context then
    return nil, nil, context_err
  end

  return repo_context, ensure_repo_session(repo_context), nil
end

local function rerender_repo_context(repo_context)
  if type(repo_context) ~= "table" or type(repo_context.key) ~= "string" then
    return false
  end

  if current_repo_state_is_focused(repo_context.key) then
    render_repo_states(repo_context.key)
    return true
  end

  return render_visible_repo_states(repo_context.key, {
    sync_runtime = false,
  })
end

local function rerender_repo_states_for_async(repo_key)
  if type(repo_key) ~= "string" or repo_key == "" then
    return false
  end

  if current_repo_state_is_focused(repo_key) then
    render_repo_states(repo_key)
    return true
  end

  return render_visible_repo_states(repo_key, {
    sync_runtime = false,
  })
end

function M.get_file_filters(state)
  local repo_context, session = resolve_repo_context_for_state(state)
  if not repo_context or type(session) ~= "table" then
    return sanitize_file_filters(nil)
  end

  session.file_filters = sanitize_file_filters(session.file_filters)
  return vim.deepcopy(session.file_filters)
end

function M.update_file_filters(state, updates)
  local repo_context, session, err = resolve_repo_context_for_state(state)
  if not repo_context or type(session) ~= "table" then
    return false, err or ("Unable to resolve " .. source_label .. " session")
  end

  session.file_filters = sanitize_file_filters(vim.tbl_extend("force", session.file_filters or {}, type(updates) == "table" and updates or {}))
  rerender_repo_context(repo_context)
  return true, nil, vim.deepcopy(session.file_filters)
end

function M.reset_file_filters(state)
  local repo_context, session, err = resolve_repo_context_for_state(state)
  if not repo_context or type(session) ~= "table" then
    return false, err or ("Unable to resolve " .. source_label .. " session")
  end

  session.file_filters = default_file_filters()
  rerender_repo_context(repo_context)
  return true, nil, vim.deepcopy(session.file_filters)
end

local function apply_runtime_cache(session)
  apply_provider_runtime_target(session, {
    repository = session.repository,
    git_root = session.git_root,
    key = session.key,
  })

  local review_pr = session.target_pr
  local review_details = session.target_details
  local review_number = type(review_pr) == "table" and tonumber(review_pr.number) or nil
  if not review_number or not has_full_details(review_details) then
    return
  end

  if tonumber(session.pr_number) == review_number and has_full_details(session.details) then
    return
  end

  if tonumber(session.pr_number) ~= review_number then
    invalidate_check_annotation_cache(session)
    invalidate_security_cache(session)
  end
  session.pr_number = review_number
  session.details = review_details
end

local function reveal_context_in_state(state, session, context)
  if type(state) ~= "table" or type(session) ~= "table" or type(context) ~= "table" then
    return false
  end

  local session_repo = type(session.repository) == "table" and session.repository.full_name or nil
  if type(context.repo) == "string" and context.repo ~= "" and type(session_repo) == "string" and context.repo ~= session_repo then
    return false
  end

  local pr_number = tonumber(context.pr_number)
  local target_path = follow.normalize_path(context.path)
  if not pr_number or target_path == "" then
    return false
  end

  local node = follow.find_file_node(state, function(entry)
    if entry.pr_number ~= pr_number then
      return false
    end
    if entry.path == target_path then
      return true
    end
    return entry.previous_path ~= "" and entry.previous_path == target_path
  end)
  if not node then
    return false
  end

  local focused, node_id = follow.focus_node_without_steal(state, node)
  if focused then
    remember_revealed_node(session, node_id, {
      pr_number = pr_number,
      path = target_path,
    })
  end

  return focused
end

local function reveal_last_node_in_state(state, session)
  if type(state) ~= "table" or type(session) ~= "table" then
    return false
  end

  local follow_state = ensure_follow_state(session)
  if type(follow_state.last_node_id) == "string" and follow_state.last_node_id ~= "" then
    local focused = select(1, follow.focus_node_without_steal(state, follow_state.last_node_id))
    if focused then
      return true
    end
  end

  local fallback_context = {
    pr_number = tonumber(follow_state.last_pr),
    path = follow_state.last_path,
    repo = type(session.repository) == "table" and session.repository.full_name or nil,
  }

  if fallback_context.pr_number and type(fallback_context.path) == "string" and fallback_context.path ~= "" then
    return reveal_context_in_state(state, session, fallback_context)
  end

  return false
end

local function follow_current_file_if_visible(_)
  local states = follow.visible_source_states(SOURCE_NAME)
  if vim.tbl_isempty(states) then
    return false
  end

  local context = follow.resolve_buffer_context()
  for _, state in ipairs(states) do
    local repo_key = type(state) == "table" and state[state_repo_key_field] or nil
    local session = type(repo_key) == "string" and runtime_cache.repos[repo_key] or nil
    if session then
      local revealed = false
      if context then
        revealed = reveal_context_in_state(state, session, context)
      end
      if not revealed then
        reveal_last_node_in_state(state, session)
      end
    end
  end

  return true
end

local start_background_refresh

local function provider_prefetch_allowed(repo_context, session)
  if type(should_prefetch_review) ~= "function" then
    return true
  end

  return should_prefetch_review(repo_context, session) == true
end

local function finish_refresh(repo_context, payload)
  payload = type(payload) == "table" and payload or {}
  local refresh_context = normalize_refresh_context(payload.refresh_context)
  local session = ensure_repo_session(repo_context)
  local ui_refresh = should_update_ui(refresh_context) and not vim.tbl_isempty(visible_repo_states(repo_context.key))
  session.inflight = false
  session.loading = false

  if payload.error then
    session.last_error = payload.error
    session.stale = session_is_stale(session)
    if ui_refresh then
      if current_repo_state_is_focused(repo_context.key) then
        render_repo_states(repo_context.key)
      else
        render_visible_repo_states(repo_context.key, {
          sync_runtime = false,
        })
      end
    end

    local pending = consume_pending_refresh(session)
    if pending then
      start_background_refresh(repo_context, pending)
    end
    return
  end

  if payload.no_target == true then
    session.last_error = nil
    session.target_pr = nil
    session.target_details = nil
    session.target_reason = type(payload.reason) == "string" and payload.reason or no_target_message
    session.branch_name = type(payload.branch) == "string" and payload.branch or session.branch_name
    session.loading = false
    session.inflight = false
    session.stale = false
    if ui_refresh then
      if current_repo_state_is_focused(repo_context.key) then
        render_repo_states(repo_context.key)
      else
        render_visible_repo_states(repo_context.key, {
          sync_runtime = false,
        })
      end
    end

    local pending = consume_pending_refresh(session)
    if pending then
      start_background_refresh(repo_context, pending)
    end
    return
  end

  local previous_snapshot = build_review_snapshot(session.pr_number, session.details)

  session.last_error = nil
  session.target_pr = type(payload.pr) == "table" and payload.pr or payload.details
  session.target_details = type(payload.details) == "table" and payload.details or payload.pr
  session.target_reason = nil
  session.branch_name = type(payload.branch) == "string" and payload.branch or session.branch_name
  session.pr_number = payload.pr_number
  session.details = dedupe_details_files(payload.details)
  invalidate_check_annotation_cache(session)
  invalidate_security_cache(session)
  session.updated_at = now_seconds()
  session.stale = session_is_stale(session)

  local current_snapshot = build_review_snapshot(session.pr_number, session.details)
  local change_summary = summarize_review_changes(previous_snapshot, current_snapshot)

  comments_source.invalidate_cache()
  persist_session(repo_context, session)

  if type(session.target_pr) == "table"
    and tonumber(session.target_pr.number) == tonumber(session.pr_number)
    and provider_prefetch_allowed(repo_context, session) then
    review_prefetch.prefetch_review(session.target_pr, session.details, {
      source = "review_refresh",
    })
  end

  local actions_ok, actions = pcall(require, "gh-pr.actions")
  if actions_ok and type(actions.sync_remote_viewed_state) == "function" then
    pcall(actions.sync_remote_viewed_state, session.pr_number, session.details, {
      notify_error = false,
    })
  end

  if ui_refresh then
    if current_repo_state_is_focused(repo_context.key) then
      render_repo_states(repo_context.key)
    else
      render_visible_repo_states(repo_context.key, {
        sync_runtime = false,
      })
    end
    follow_current_file_if_visible({ reason = "refresh" })

    if cache_options().sync_visible_buffers ~= false then
      virtual_files.sync_visible_pr_buffers({
        [tostring(session.pr_number)] = session.details,
      }, {
        repository = repo_context.repository.full_name,
      })
    end

    if change_summary then
      refresh_visible_overview_if_needed(session.pr_number)
    end

    if refresh_context.reason == "timer" and refresh_context.notify and change_summary then
      local change_message = summarize_review_change_message(change_summary)
      if type(change_message) == "string" and change_message ~= "" then
        vim.notify(change_message, vim.log.levels.INFO)
      end
    end
  end

  local pending = consume_pending_refresh(session)
  if pending then
    start_background_refresh(repo_context, pending)
  end
end

start_background_refresh = function(repo_context, opts)
  opts = opts or {}
  opts.refresh_context = normalize_refresh_context(opts.refresh_context)
  local session = ensure_repo_session(repo_context)
  local ui_refresh = should_update_ui(opts.refresh_context) and not vim.tbl_isempty(visible_repo_states(repo_context.key))
  apply_provider_runtime_target(session, repo_context)

  if session.inflight then
    queue_pending_refresh(session, {
      force = true,
      refresh_context = opts.refresh_context,
    })
    if should_notify_manual_refresh(opts.refresh_context) then
      vim.notify(source_label .. " refresh already in progress; queued latest request.", vim.log.levels.INFO)
    end
    return false
  end

  session.inflight = true
  session.loading = true
  session.stale = session_is_stale(session)
  if ui_refresh then
    if should_notify_manual_refresh(opts.refresh_context) then
      vim.notify("Refreshing " .. source_label .. " from GitHub...", vim.log.levels.INFO)
    elseif opts.refresh_context.reason == "timer" and opts.refresh_context.notify then
      vim.notify("Updating PR...", vim.log.levels.INFO)
    end
    if current_repo_state_is_focused(repo_context.key) then
      render_repo_states(repo_context.key)
    else
      render_visible_repo_states(repo_context.key, {
        sync_runtime = false,
      })
    end
  end

  resolve_target_async(repo_context, session, function(target, target_err)
    if not target then
      finish_refresh(repo_context, {
        no_target = target_err == nil,
        error = target_err,
        reason = session.target_reason,
        branch = session.branch_name,
        refresh_context = opts.refresh_context,
      })
      return
    end

    local review_pr = type(target.pr) == "table" and target.pr or target.details
    local review_number = tonumber(type(review_pr) == "table" and review_pr.number or target.pr_number)
    if not review_number then
      finish_refresh(repo_context, {
        error = "Unable to resolve pull request number for source refresh",
        refresh_context = opts.refresh_context,
      })
      return
    end

    session.target_pr = review_pr
    session.target_details = type(target.details) == "table" and target.details or review_pr
    session.target_reason = nil
    session.branch_name = type(target.branch) == "string" and target.branch or session.branch_name

    local ttl = tonumber(cache_options().ttl_seconds) or 60
    local age = now_seconds() - (tonumber(session.updated_at) or 0)
    local has_matching = has_full_details(session.details) and tonumber(session.pr_number) == review_number
    if not opts.force and has_matching and session.updated_at > 0 and age < ttl and not session_is_stale(session) then
      finish_refresh(repo_context, {
        pr = review_pr,
        pr_number = review_number,
        details = session.details,
        branch = session.branch_name,
        refresh_context = opts.refresh_context,
      })
      return
    end

    pr_service.fetch_details_async(review_number, function(details, details_err)
      if not details then
        finish_refresh(repo_context, {
          error = details_err or "Unable to fetch PR details",
          refresh_context = opts.refresh_context,
        })
        return
      end

    local pending_requests = 2
    local function complete_refresh()
      pending_requests = pending_requests - 1
      if pending_requests > 0 then
        return
      end

      finish_refresh(repo_context, {
        pr = review_pr,
        pr_number = review_number,
        details = details,
        branch = session.branch_name,
        refresh_context = opts.refresh_context,
      })
    end

    pr_service.fetch_review_threads_async(review_number, {
      threads_first = 100,
      comments_first = 100,
    }, function(threads, threads_err)
      if threads then
        details.review_threads = threads
        details.review_threads_error = nil
      else
        details.review_threads = type(details.review_threads) == "table" and details.review_threads or {}
        details.review_threads_error = threads_err or "Unable to load review threads"
      end
      complete_refresh()
    end)

    if type(pr_service.fetch_pending_review_comments_async) == "function" then
      pr_service.fetch_pending_review_comments_async(review_number, function(pending_review, pending_err)
        if pending_review then
          details.pending_review = type(pending_review.review) == "table" and pending_review.review or nil
          details.pending_review_comments = type(pending_review.comments) == "table" and pending_review.comments or {}
          details.pending_review_error = nil
        else
          details.pending_review = nil
          details.pending_review_comments = {}
          details.pending_review_error = pending_err or "Unable to load pending review comments"
        end
        details.pending_review_loaded = true
        complete_refresh()
      end)
    else
      details.pending_review = nil
      details.pending_review_comments = {}
      details.pending_review_error = nil
      details.pending_review_loaded = true
      complete_refresh()
    end
    end)
  end)

  return true
end

function M.request_check_annotations(state, node)
  if type(state) ~= "table" then
    return false, "Unable to resolve " .. source_label .. " state"
  end

  local check_node = type(node) == "table" and node or (type(state.tree) == "table" and state.tree:get_node() or nil)
  local extra = type(check_node) == "table" and type(check_node.extra) == "table" and check_node.extra or nil
  if type(extra) ~= "table" or extra.kind ~= "check" then
    return false, "Selected node is not a check"
  end

  local check = type(extra.check) == "table" and extra.check or nil
  local check_key = type(extra.check_key) == "string" and extra.check_key or nil
  local pr = type(extra.pr) == "table" and extra.pr or nil
  local details = type(extra.details) == "table" and extra.details or nil
  local pr_number = tonumber(type(pr) == "table" and pr.number or nil) or tonumber(type(details) == "table" and details.number or nil)
  if not check or type(check_key) ~= "string" or check_key == "" or not pr_number then
    return false, "Selected check is missing required metadata"
  end

  local repo_key = type(state[state_repo_key_field]) == "string" and state[state_repo_key_field] or nil
  local session = type(repo_key) == "string" and runtime_cache.repos[repo_key] or nil
  if not session then
    local repo_context, context_err = resolve_repo_context()
    if not repo_context then
      return false, "Unable to resolve repository context: " .. tostring(context_err)
    end
    session = ensure_repo_session(repo_context)
    repo_key = repo_context.key
  end

  local cache = ensure_check_annotation_cache(session)
  local cached = type(cache[check_key]) == "table" and cache[check_key] or nil
  if cached and (cached.loading == true or cached.loaded == true) then
    return true, nil
  end

  local details_for_request = type(details) == "table" and details or session.details
  local repository = repository_full_name(details_for_request)
  if repository == "" and type(session.repository) == "table" and type(session.repository.full_name) == "string" then
    repository = session.repository.full_name
  end

  local head_repository = nil
  if type(details_for_request) == "table" and type(details_for_request.headRepository) == "table"
    and type(details_for_request.headRepository.nameWithOwner) == "string"
    and details_for_request.headRepository.nameWithOwner ~= "" then
    head_repository = details_for_request.headRepository.nameWithOwner
  end

  local generation = tonumber(session.check_annotations_generation) or 0
  cache[check_key] = {
    loading = true,
    loaded = false,
    annotations = {},
    error = nil,
  }
  rerender_repo_states_for_async(repo_key)

  pr_service.fetch_check_annotations_async(pr_number, check, {
    repository = repository ~= "" and repository or nil,
    head_repository = head_repository,
    details = details_for_request,
  }, function(payload, err)
    if type(repo_key) ~= "string" or not runtime_cache.repos[repo_key] then
      return
    end

    local active_session = runtime_cache.repos[repo_key]
    if (tonumber(active_session.check_annotations_generation) or 0) ~= generation then
      return
    end

    local active_cache = ensure_check_annotation_cache(active_session)
    if payload then
      active_cache[check_key] = {
        loading = false,
        loaded = true,
        annotations = type(payload.annotations) == "table" and payload.annotations or {},
        error = nil,
        check_run_id = tonumber(payload.check_run_id),
      }
    else
      active_cache[check_key] = {
        loading = false,
        loaded = false,
        annotations = {},
        error = err or "Unable to load annotations",
      }
    end

    rerender_repo_states_for_async(repo_key)
  end)

  return true, nil
end

local function request_security_payload(state, node, request_kind)
  if type(state) ~= "table" then
    return false, "Unable to resolve " .. source_label .. " state"
  end

  local security_node = type(node) == "table" and node or (type(state.tree) == "table" and state.tree:get_node() or nil)
  local extra = type(security_node) == "table" and type(security_node.extra) == "table" and security_node.extra or nil
  if type(extra) ~= "table" or extra.kind ~= request_kind then
    return false, "Selected node is not a security section"
  end

  local cache_key = request_kind == "security_code_scanning" and "code_scanning" or "dependency_review"
  local pr = type(extra.pr) == "table" and extra.pr or nil
  local details = type(extra.details) == "table" and extra.details or nil
  local pr_number = tonumber(type(pr) == "table" and pr.number or nil) or tonumber(type(details) == "table" and details.number or nil)
  if not pr_number then
    return false, "Selected security section is missing pull request metadata"
  end

  local repo_key = type(state[state_repo_key_field]) == "string" and state[state_repo_key_field] or nil
  local session = type(repo_key) == "string" and runtime_cache.repos[repo_key] or nil
  if not session then
    local repo_context, context_err = resolve_repo_context()
    if not repo_context then
      return false, "Unable to resolve repository context: " .. tostring(context_err)
    end
    session = ensure_repo_session(repo_context)
    repo_key = repo_context.key
  end

  local cache = ensure_security_cache(session)
  local cached = type(cache[cache_key]) == "table" and cache[cache_key] or nil
  if cached and (cached.loading == true or cached.loaded == true) then
    return true, nil
  end

  local details_for_request = type(details) == "table" and details or session.details
  local repository = repository_full_name(details_for_request)
  if repository == "" and type(session.repository) == "table" and type(session.repository.full_name) == "string" then
    repository = session.repository.full_name
  end

  local head_repository = nil
  if type(details_for_request) == "table" and type(details_for_request.headRepository) == "table"
    and type(details_for_request.headRepository.nameWithOwner) == "string"
    and details_for_request.headRepository.nameWithOwner ~= "" then
    head_repository = details_for_request.headRepository.nameWithOwner
  end

  local generation = tonumber(cache.generation) or 0
  cache[cache_key] = {
    loading = true,
    loaded = false,
    unavailable = false,
    message = nil,
    error = nil,
    alerts = {},
    changes = {},
    vulnerable_count = 0,
  }
  rerender_repo_states_for_async(repo_key)

  local request_opts = {
    repository = repository ~= "" and repository or nil,
    head_repository = head_repository,
    details = details_for_request,
  }

  local function assign_payload(payload, err)
    if type(repo_key) ~= "string" or not runtime_cache.repos[repo_key] then
      return
    end

    local active_session = runtime_cache.repos[repo_key]
    local active_cache = ensure_security_cache(active_session)
    if (tonumber(active_cache.generation) or 0) ~= generation then
      return
    end

    if payload then
      local next_entry = {
        loading = false,
        loaded = true,
        unavailable = payload.unavailable == true,
        message = payload.message,
        error = nil,
      }
      if cache_key == "code_scanning" then
        next_entry.alerts = type(payload.alerts) == "table" and payload.alerts or {}
      else
        next_entry.changes = type(payload.changes) == "table" and payload.changes or {}
        next_entry.vulnerable_count = tonumber(payload.vulnerable_count) or 0
      end
      active_cache[cache_key] = next_entry
    else
      active_cache[cache_key] = {
        loading = false,
        loaded = false,
        unavailable = false,
        message = nil,
        error = err or "Unable to load security findings",
        alerts = {},
        changes = {},
        vulnerable_count = 0,
      }
    end

    rerender_repo_states_for_async(repo_key)
  end

  if cache_key == "code_scanning" then
    pr_service.fetch_code_scanning_alerts_async(pr_number, request_opts, assign_payload)
  else
    pr_service.fetch_dependency_review_async(pr_number, request_opts, assign_payload)
  end

  return true, nil
end

function M.request_security_code_scanning(state, node)
  return request_security_payload(state, node, "security_code_scanning")
end

function M.request_security_dependency_review(state, node)
  return request_security_payload(state, node, "security_dependency_review")
end

local function show_message(state, id, message)
  renderer.show_nodes({
    message_node(id, message),
  }, state)
end

M.navigate = function(state, path)
  if not repo.ensure_git_repo() then
    show_message(state, id_prefix .. ":not-git", not_git_message)
    return
  end

  local repo_context, context_err = resolve_repo_context()
  if not repo_context then
    show_message(state, id_prefix .. ":repo-error", repo_error_prefix .. tostring(context_err))
    return
  end

  state.path = path or vim.fn.getcwd()
  local session = ensure_repo_session(repo_context)
  register_state(session, state)
  apply_runtime_cache(session)
  session.stale = session_is_stale(session)

  start_background_refresh(repo_context, { force = false })
  render_state(state, session, repo_context, {
    allow_unattached = true,
  })
  follow_current_file_if_visible({ reason = "navigate" })
end

function M.request_refresh(state, opts)
  opts = opts or {}
  if not repo.in_git_repo() then
    return false
  end

  local repo_context, context_err = resolve_repo_context()
  if not repo_context then
    if opts.notify_error ~= false then
      vim.notify("Unable to resolve repository: " .. tostring(context_err), vim.log.levels.ERROR)
    end
    return false
  end

  local session = ensure_repo_session(repo_context)
  if state then
    register_state(session, state)
  end

  return start_background_refresh(repo_context, {
    force = opts.force == true,
    refresh_context = normalize_refresh_context(opts.refresh_context),
  })
end

function M.render_cached_states()
  for repo_key, _ in pairs(runtime_cache.repos) do
    render_repo_states(repo_key)
  end
end

local function resolve_current_focused_state()
  return resolve_current_live_state()
end

function M.is_focused()
  return select(1, resolve_current_focused_state())
end

function M.refresh_if_focused()
  local options = cache_options()
  if options.auto_refresh_when_focused == false then
    return
  end

  local focused, state = resolve_current_focused_state()
  if not focused then
    return
  end

  M.request_refresh(state, {
    force = false,
    notify_error = false,
    refresh_context = {
      mode = REFRESH_MODE_UI,
      reason = "timer",
      notify = true,
    },
  })
  follow_current_file_if_visible({ reason = "focused" })
end

function M.follow_current_file_if_visible(opts)
  return follow_current_file_if_visible(opts)
end

M.setup = function(source_config, _)
  highlights.ensure_baseline_links()

  local commands = require("gh-pr.neotree.review_commands")
  local components = require("gh-pr.neotree.components")

  source_config.commands = vim.tbl_deep_extend("force", source_config.commands or {}, commands)
  source_config.components = source_config.components or components
  source_config.renderers = vim.tbl_deep_extend("force", source_config.renderers or {}, DEFAULT_RENDERERS)

  source_config.window = source_config.window or {}
  source_config.window.mappings = source_config.window.mappings or {}

  local default_mappings = {
    ["<CR>"] = "gh_pr_review_open",
    ["R"] = "refresh",
    ["o"] = "open_overview",
    ["b"] = "open_pr_browser",
    ["T"] = "open_telescope_actions",
    ["d"] = "open_diff",
    ["O"] = "open_original",
    ["M"] = "open_modified",
    ["v"] = "toggle_viewed",
    ["a"] = "edit_assignees_multi",
    ["l"] = "edit_labels_multi",
    ["u"] = "edit_reviewers_multi",
    ["g"] = "comment_file_global",
    ["c"] = "comment_pr",
    ["r"] = "start_review",
    ["ra"] = "submit_pending_approve_review",
    ["rc"] = "submit_pending_comment_review",
    ["rr"] = "submit_pending_request_changes_review",
    ["rd"] = "discard_pending_review",
    ["zA"] = "expand_all_review_nodes",
    ["za"] = "collapse_all_review_nodes",
    ["zF"] = "expand_files_nodes",
    ["zf"] = "collapse_files_nodes",
    ["zt"] = "toggle_files_flat_mode",
    ["zV"] = "expand_viewed_file_paths",
    ["zv"] = "collapse_viewed_file_paths",
    ["/"] = "filter_files_by_path",
    ["z/"] = "clear_file_path_filter",
    ["zs"] = "select_file_status_filter",
    ["ze"] = "filter_files_by_extension",
    ["zn"] = "toggle_no_extension_filter",
    ["z."] = "toggle_dotfiles_filter",
    ["zu"] = "toggle_unviewed_only_filter",
    ["zw"] = "toggle_viewed_only_filter",
    ["zh"] = "toggle_hide_viewed_filter",
    ["zd"] = "toggle_hide_deleted_filter",
    ["zr"] = "reset_file_filters",
    ["zG"] = "expand_comments_global",
    ["zg"] = "collapse_comments_global",
    ["x"] = "toggle_review_tree",
    ["e"] = "toggle_auto_expand_width",
    ["q"] = "close_window",
    ["?"] = "show_help",
    ["<"] = "prev_source",
    [">"] = "next_source",
    ["y"] = "noop",
    ["<C-r>"] = "noop",
    ["t"] = "noop",
    ["w"] = "noop",
  }

  source_config.window.mappings = vim.tbl_deep_extend("force", source_config.window.mappings, default_mappings)
end

  M.source_label = function()
    return source_label
  end

  require("gh-pr.neotree.registry").register(SOURCE_NAME, M)

  return M
end

local default_instance = create()
default_instance._create = create

return default_instance

