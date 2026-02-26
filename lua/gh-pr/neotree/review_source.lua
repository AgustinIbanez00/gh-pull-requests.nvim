local M = {
  name = "gh_pr_review",
  display_name = "GH PR Review",
}

local cache_store = require("gh-pr.cache_store")
local comments_source = require("gh-pr.neotree.comments_source")
local config = require("gh-pr.config")
local follow = require("gh-pr.neotree.follow")
local path_tree = require("gh-pr.path_tree")
local pr_service = require("gh-pr.pr_service")
local repo = require("gh-pr.repo")
local runtime_state = require("gh-pr.state")
local virtual_files = require("gh-pr.virtual_files")

local renderer = require("neo-tree.ui.renderer")

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
  file = {
    { "indent", with_expanders = false },
    { "kind_icon" },
    { "container", width = "100%", content = { { "name", zindex = 10 }, { "viewed_badge", zindex = 11 } } },
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
  local review_options = type(options.gh_pr_review) == "table" and options.gh_pr_review or {}
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
  return tostring(repo_key) .. "::gh_pr_review"
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
    pr_number = nil,
    details = nil,
    updated_at = 0,
    loading = false,
    inflight = false,
    pending_refresh = nil,
    last_error = nil,
    stale = false,
    follow = {},
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
  state.gh_pr_review_repo_key = session.key
end

local function ensure_follow_state(session)
  if type(session.follow) ~= "table" then
    session.follow = {}
  end
  return session.follow
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
  local repository = type(details) == "table" and (details.baseRepository or details.headRepository) or nil
  if type(repository) ~= "table" then
    return ""
  end

  if type(repository.nameWithOwner) == "string" and repository.nameWithOwner ~= "" then
    return repository.nameWithOwner
  end

  local owner
  if type(repository.owner) == "table" then
    owner = repository.owner.login
  else
    owner = repository.owner
  end

  local name = repository.name
  if type(owner) ~= "string" or owner == "" or type(name) ~= "string" or name == "" then
    return ""
  end

  return owner .. "/" .. name
end

local function status_prefix(status)
  local normalized = (status or ""):lower()
  if normalized == "added" then
    return "+"
  end
  if normalized == "removed" then
    return "-"
  end
  if normalized == "renamed" then
    return "R"
  end
  if normalized == "copied" then
    return "C"
  end
  return "M"
end

local function file_display_name(path, file, options)
  local base_name = path:match("[^/\\]+$") or path
  local include_status = options.show_status_prefix ~= false
  if include_status then
    return string.format("[%s] %s", status_prefix(file.status), base_name)
  end
  return base_name
end

local function normalize_tree_path(path)
  if type(path) ~= "string" then
    return ""
  end

  local normalized = path:gsub("\\", "/"):gsub("/+", "/")
  normalized = normalized:gsub("^/", ""):gsub("/$", "")
  return normalized
end

local function directory_path_of_file(path)
  local normalized = normalize_tree_path(path)
  if normalized == "" then
    return ""
  end

  local directory = normalized:match("^(.*)/[^/]+$")
  return type(directory) == "string" and directory or ""
end

local function add_directory_count(counts, directory_path, viewed)
  if type(counts) ~= "table" or type(directory_path) ~= "string" or directory_path == "" then
    return
  end

  local current = ""
  for segment in directory_path:gmatch("[^/]+") do
    current = current == "" and segment or (current .. "/" .. segment)
    local bucket = counts[current]
    if type(bucket) ~= "table" then
      bucket = { viewed = 0, total = 0 }
      counts[current] = bucket
    end
    bucket.total = (tonumber(bucket.total) or 0) + 1
    if viewed then
      bucket.viewed = (tonumber(bucket.viewed) or 0) + 1
    end
  end
end

local function build_file_nodes(pr, details, repo_full_name)
  local render_options = config.get_path_render("gh_pr")
  local hide_viewed = (config.get() or {}).hide_viewed_files == true
  local entries = {}
  local seen_paths = {}
  local directory_counts = {}
  local total_files = 0
  local viewed_files = 0

  for _, file in ipairs(type(details.files) == "table" and details.files or {}) do
    local path = file.path or file.filename
    if type(path) == "string" and path ~= "" then
      local normalized_path = normalize_tree_path(path)
      if normalized_path == "" or seen_paths[normalized_path] then
        goto continue
      end
      seen_paths[path] = true
      seen_paths[normalized_path] = true
      local viewed = runtime_state.is_viewed(repo_full_name, pr.number, normalized_path)
      add_directory_count(directory_counts, directory_path_of_file(normalized_path), viewed)
      total_files = total_files + 1
      if viewed then
        viewed_files = viewed_files + 1
      end
      if not (hide_viewed and viewed) then
        entries[#entries + 1] = {
          path = normalized_path,
          payload = file,
        }
      end
    end
    ::continue::
  end

  if vim.tbl_isempty(entries) then
    return {
      {
        id = string.format("ghpr-review:%d:files-empty", pr.number),
        name = "No files",
        type = "message",
        extra = {
          kind = "message",
          pr = pr,
          details = details,
        },
      },
    }, viewed_files, total_files
  end

  local nodes = path_tree.build_nodes(entries, {
    mode = render_options.mode,
    separator = render_options.separator,
    create_directory_node = function(display_name, full_path)
      local normalized_full_path = normalize_tree_path(full_path)
      local counts = directory_counts[normalized_full_path]
      local viewed = type(counts) == "table" and tonumber(counts.viewed) or nil
      local total = type(counts) == "table" and tonumber(counts.total) or nil
      return {
        id = string.format("ghpr-review:%d:file-dir:%s", pr.number, full_path),
        name = display_name,
        type = "directory",
        children = {},
        extra = {
          kind = "directory",
          path = normalized_full_path,
          pr = pr,
          details = details,
          repo = repo_full_name,
          viewed_counts = (viewed and total) and { viewed = viewed, total = total } or nil,
          show_viewed_prefix = viewed ~= nil and total ~= nil and total > 0 and viewed > 0,
        },
      }
    end,
    create_file_node = function(file_item)
      local path = file_item.path
      local file = file_item.payload
      return {
        id = string.format("ghpr-review:%d:file:%s", pr.number, path),
        name = file_display_name(path, file, render_options),
        type = "file",
        path = path,
        extra = {
          kind = "file",
          file = file,
          pr = pr,
          details = details,
          repo = repo_full_name,
        },
      }
    end,
  })

  return nodes, viewed_files, total_files
end

local function normalize_login(entry)
  if type(entry) == "table" then
    if type(entry.login) == "string" and entry.login ~= "" then
      return entry.login
    end
    if type(entry.author) == "table" and type(entry.author.login) == "string" and entry.author.login ~= "" then
      return entry.author.login
    end
    if type(entry.requestedReviewer) == "table" and type(entry.requestedReviewer.login) == "string"
      and entry.requestedReviewer.login ~= "" then
      return entry.requestedReviewer.login
    end
    if type(entry.user) == "table" and type(entry.user.login) == "string" and entry.user.login ~= "" then
      return entry.user.login
    end
  elseif type(entry) == "string" and entry ~= "" then
    return entry
  end
  return nil
end

local function reviewer_state_priority(state)
  local value = type(state) == "string" and state:upper() or ""
  if value == "CHANGES_REQUESTED" then
    return 4
  end
  if value == "APPROVED" then
    return 3
  end
  if value == "PENDING" then
    return 2
  end
  if value == "COMMENTED" then
    return 1
  end
  return 0
end

local function normalize_reviewer_state(state)
  local value = type(state) == "string" and state:upper() or ""
  if value == "CHANGES_REQUESTED" then
    return "CHANGES_REQUESTED"
  end
  if value == "APPROVED" then
    return "APPROVED"
  end
  if value == "PENDING" then
    return "PENDING"
  end
  if value == "COMMENTED" then
    return "COMMENTED"
  end
  return "PENDING"
end

local function build_reviewer_nodes(pr, details)
  local map = {}

  local function upsert(login, state_value)
    if type(login) ~= "string" or login == "" then
      return
    end

    local incoming = normalize_reviewer_state(state_value)
    local incoming_priority = reviewer_state_priority(incoming)
    local current = map[login]
    if not current or incoming_priority >= reviewer_state_priority(current.state) then
      map[login] = {
        login = login,
        state = incoming,
      }
    end
  end

  for _, reviewer in ipairs(type(details.reviewRequests) == "table" and details.reviewRequests or {}) do
    upsert(normalize_login(reviewer), "PENDING")
  end

  for _, review in ipairs(type(details.latestReviews) == "table" and details.latestReviews or {}) do
    upsert(normalize_login(review.author), review.state)
  end

  for _, review in ipairs(type(details.reviews) == "table" and details.reviews or {}) do
    upsert(normalize_login(review.author), review.state)
  end

  local nodes = {}
  for _, item in pairs(map) do
    nodes[#nodes + 1] = {
      id = string.format("ghpr-review:%d:reviewer:%s", pr.number, item.login),
      name = string.format("@%s [%s]", item.login, item.state),
      type = "file",
      extra = {
        kind = "reviewer",
        reviewer_state = item.state,
        pr = pr,
        details = details,
      },
    }
  end

  table.sort(nodes, function(left, right)
    return left.name < right.name
  end)

  if vim.tbl_isempty(nodes) then
    return {
      {
        id = string.format("ghpr-review:%d:reviewers-empty", pr.number),
        name = "No reviewers found",
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
        id = string.format("ghpr-review:%d:commit:%s", pr.number, oid ~= "" and oid or tostring(#nodes + 1)),
        name = string.format("%s %s", short_sha(oid), headline),
        type = "file",
        extra = {
          kind = "commit",
          commit = {
            oid = oid,
            headline = headline,
            body = type(commit.messageBody) == "string" and commit.messageBody or "",
            url = type(commit.url) == "string" and commit.url or "",
            author = type(commit.author) == "table" and commit.author.login or nil,
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
        id = string.format("ghpr-review:%d:commits-empty", pr.number),
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

local function normalize_check_result(check)
  local status = type(check.status) == "string" and check.status:upper() or (type(check.state) == "string" and check.state:upper() or "")
  local conclusion = type(check.conclusion) == "string" and check.conclusion:upper() or ""

  if conclusion == "SUCCESS" then
    return "PASS"
  end
  if conclusion == "FAILURE" or conclusion == "TIMED_OUT" or conclusion == "CANCELLED" or conclusion == "ACTION_REQUIRED" then
    return "FAIL"
  end
  if status == "QUEUED" or status == "IN_PROGRESS" or status == "PENDING" or status == "EXPECTED" then
    return "PENDING"
  end
  if conclusion ~= "" then
    return conclusion
  end
  if status ~= "" then
    return status
  end
  return "UNKNOWN"
end

local function normalize_check_name(check)
  if type(check.name) == "string" and check.name ~= "" then
    return check.name
  end
  if type(check.context) == "string" and check.context ~= "" then
    return check.context
  end
  if type(check.workflowRun) == "table" and type(check.workflowRun.workflow) == "table"
    and type(check.workflowRun.workflow.name) == "string" and check.workflowRun.workflow.name ~= "" then
    return check.workflowRun.workflow.name
  end
  return "check"
end

local function normalize_check_url(check)
  if type(check.detailsUrl) == "string" and check.detailsUrl ~= "" then
    return check.detailsUrl
  end
  if type(check.targetUrl) == "string" and check.targetUrl ~= "" then
    return check.targetUrl
  end
  if type(check.url) == "string" and check.url ~= "" then
    return check.url
  end
  return ""
end

local function build_check_nodes(pr, details)
  local nodes = {}
  local seen = {}
  for _, check in ipairs(type(details.statusCheckRollup) == "table" and details.statusCheckRollup or {}) do
    local name = normalize_check_name(check)
    local state = normalize_check_result(check)
    local url = normalize_check_url(check)
    local key = sanitize_node_id_component(name) .. ":" .. sanitize_node_id_component(url)
    local order = (seen[key] or 0) + 1
    seen[key] = order
    nodes[#nodes + 1] = {
      id = string.format("ghpr-review:%d:check:%s:%d", pr.number, key, order),
      name = string.format("[%s] %s", state, name),
      type = "file",
      extra = {
        kind = "check",
        check_state = state,
        check_url = url,
        pr = pr,
        details = details,
      },
    }
  end

  if vim.tbl_isempty(nodes) then
    return {
      {
        id = string.format("ghpr-review:%d:checks-empty", pr.number),
        name = "No checks found",
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
  local checks = type(details.statusCheckRollup) == "table" and details.statusCheckRollup or {}
  local entries = {}

  for _, check in ipairs(checks) do
    local name = normalize_check_name(check)
    local state = normalize_check_result(check)
    entries[#entries + 1] = string.format("%s=%s", sanitize_node_id_component(name), sanitize_node_id_component(state))
  end

  table.sort(entries)
  return {
    total = #entries,
    signature = table.concat(entries, "|"),
  }
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
        id = string.format("ghpr-review:%d:label:%s:%d", pr.number, sanitize_node_id_component(name), index),
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
        id = string.format("ghpr-review:%d:labels-empty", pr.number),
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

local function first_positive_line(...)
  for index = 1, select("#", ...) do
    local value = tonumber((select(index, ...)))
    if value and value > 0 then
      return math.floor(value)
    end
  end
  return nil
end

local function normalize_event_time(value)
  if type(value) ~= "string" or value == "" then
    return ""
  end
  return value
end

local function display_event_time(value)
  local normalized = normalize_event_time(value)
  if normalized == "" then
    return "-"
  end
  return normalized:gsub("T", " "):gsub("Z", "")
end

local function event_sort_key(created_at, id)
  local timestamp = normalize_event_time(created_at)
  if timestamp == "" then
    timestamp = "~~~~-~~-~~T~~:~~:~~Z"
  end
  local event_id = type(id) == "string" and id ~= "" and id or "event"
  return timestamp .. ":" .. event_id
end

local function normalize_diff_side(value)
  local side = type(value) == "string" and value:upper() or ""
  if side == "LEFT" or side == "RIGHT" then
    return side
  end
  return ""
end

local function side_from_diff_hint(diff_side, head_line, base_line)
  local side = normalize_diff_side(diff_side)
  if side == "LEFT" then
    return "base"
  end
  if side == "RIGHT" then
    return "head"
  end
  if head_line then
    return "head"
  end
  if base_line then
    return "base"
  end
  return "head"
end

local function normalize_actor_login(author)
  if type(author) == "table" and type(author.login) == "string" and author.login ~= "" then
    return author.login
  end
  if type(author) == "string" and author ~= "" then
    return author
  end
  return "unknown"
end

local function normalize_thread_comment(raw_comment, index, fallback)
  fallback = type(fallback) == "table" and fallback or {}
  local id = type(raw_comment.id) == "string" and raw_comment.id ~= "" and raw_comment.id or tostring(index)
  local created_at = type(raw_comment.createdAt) == "string" and raw_comment.createdAt
    or (type(raw_comment.created_at) == "string" and raw_comment.created_at or "")
  local body = type(raw_comment.body) == "string" and raw_comment.body or ""
  local url = type(raw_comment.url) == "string" and raw_comment.url or ""
  local state = type(raw_comment.state) == "string" and raw_comment.state or ""
  local path = type(raw_comment.path) == "string" and raw_comment.path ~= "" and raw_comment.path or (fallback.path or "")
  local line = first_positive_line(raw_comment.line)
  local original_line = first_positive_line(raw_comment.originalLine, raw_comment.original_line)
  local diff_side = normalize_diff_side(raw_comment.diffSide or raw_comment.diff_side or fallback.diff_side)

  return {
    id = id,
    author = normalize_actor_login(raw_comment.author),
    created_at = created_at,
    body = body,
    url = url,
    state = state,
    outdated = raw_comment.outdated == true,
    path = path,
    line = line,
    original_line = original_line,
    diff_side = diff_side,
  }
end

local function normalize_thread_comments(raw_thread)
  local fallback = {
    path = type(raw_thread.path) == "string" and raw_thread.path or "",
    diff_side = raw_thread.diffSide or raw_thread.diff_side or "",
  }

  local comments = {}
  for index, raw_comment in ipairs(type(raw_thread.comments) == "table" and raw_thread.comments or {}) do
    comments[#comments + 1] = normalize_thread_comment(raw_comment, index, fallback)
  end

  table.sort(comments, function(left, right)
    return event_sort_key(left.created_at, left.id) < event_sort_key(right.created_at, right.id)
  end)

  return comments
end

local function normalize_thread_status(raw_thread)
  local is_resolved = raw_thread.isResolved == true or raw_thread.is_resolved == true
  local is_outdated = raw_thread.isOutdated == true or raw_thread.is_outdated == true
  if is_outdated then
    return "CLOSED", is_resolved, is_outdated
  end
  if is_resolved then
    return "RESOLVED", is_resolved, is_outdated
  end
  return "UNRESOLVED", is_resolved, is_outdated
end

local function timeline_item_for_thread_comment(thread, comment)
  return {
    kind = "thread_comment",
    author = comment.author,
    body = comment.body,
    state = comment.state,
    created_at = comment.created_at,
    url = comment.url,
    path = thread.path,
    line = thread.line,
    original_line = thread.original_line,
    side = thread.side,
    thread_id = thread.id,
    is_resolved = thread.is_resolved,
    is_outdated = thread.is_outdated,
  }
end

local function timeline_item_for_thread(thread)
  local chunks = {}
  for _, comment in ipairs(thread.comments) do
    local body = vim.trim(type(comment.body) == "string" and comment.body or "")
    if body ~= "" then
      chunks[#chunks + 1] = string.format("@%s\n%s", comment.author or "unknown", body)
    else
      chunks[#chunks + 1] = string.format("@%s", comment.author or "unknown")
    end
  end

  return {
    kind = "thread_comment",
    author = thread.author,
    body = table.concat(chunks, "\n\n"),
    state = thread.status,
    created_at = thread.created_at,
    path = thread.path,
    line = thread.line,
    original_line = thread.original_line,
    side = thread.side,
    thread_id = thread.id,
    is_resolved = thread.is_resolved,
    is_outdated = thread.is_outdated,
  }
end

local function resolve_thread_path(raw_thread, comments)
  local path = type(raw_thread.path) == "string" and raw_thread.path or ""
  if path ~= "" then
    return path
  end

  for _, comment in ipairs(comments) do
    if type(comment.path) == "string" and comment.path ~= "" then
      return comment.path
    end
  end

  return ""
end

local function normalize_thread_entry(raw_thread, index, pr, details)
  local comments = normalize_thread_comments(raw_thread)
  local status, is_resolved, is_outdated = normalize_thread_status(raw_thread)
  local path = resolve_thread_path(raw_thread, comments)
  local author = comments[1] and comments[1].author or "unknown"
  local created_at = comments[1] and comments[1].created_at or ""
  local id = type(raw_thread.id) == "string" and raw_thread.id ~= "" and raw_thread.id or ("thread-" .. tostring(index))
  local thread_head_line = first_positive_line(raw_thread.line, raw_thread.startLine, raw_thread.start_line)
  local thread_base_line = first_positive_line(raw_thread.originalLine, raw_thread.originalStartLine, raw_thread.original_line, raw_thread.original_start_line)
  local side = side_from_diff_hint(raw_thread.diffSide or raw_thread.diff_side, thread_head_line, thread_base_line)
  local resolved_head = thread_head_line
  local resolved_base = thread_base_line

  for _, comment in ipairs(comments) do
    local comment_head = first_positive_line(comment.line, thread_head_line)
    local comment_base = first_positive_line(comment.original_line, thread_base_line)
    if comment_head or comment_base then
      side = side_from_diff_hint(comment.diff_side, comment_head, comment_base)
      resolved_head = comment_head or resolved_head
      resolved_base = comment_base or resolved_base
      break
    end
  end

  if not resolved_head and resolved_base then
    resolved_head = resolved_base
  end
  if not resolved_base and resolved_head then
    resolved_base = resolved_head
  end

  local line = side == "base" and (resolved_base or resolved_head) or (resolved_head or resolved_base)
  local original_line = resolved_base or resolved_head

  local popup_comments = {}
  for _, comment in ipairs(comments) do
    popup_comments[#popup_comments + 1] = {
      id = comment.id,
      author = comment.author,
      created_at = comment.created_at,
      body = comment.body,
      url = comment.url,
      state = comment.state,
      outdated = comment.outdated,
    }
  end

  local target = nil
  if path ~= "" and line and line > 0 and original_line and original_line > 0 then
    target = {
      pr = pr,
      details = details,
      path = path,
      side = side,
      line = line,
      original_line = original_line,
      thread_id = id,
      thread_comments = popup_comments,
      selected_comment_id = popup_comments[1] and popup_comments[1].id or nil,
      thread_is_resolved = is_resolved,
      thread_is_outdated = is_outdated,
    }
  end

  return {
    id = id,
    path = path,
    status = status,
    is_resolved = is_resolved,
    is_outdated = is_outdated,
    author = author,
    created_at = created_at,
    comments = comments,
    side = side,
    line = line,
    original_line = original_line,
    target = target,
  }
end

local function thread_node_name(thread)
  local location = thread.line and thread.line > 0 and (" L" .. tostring(thread.line)) or ""
  return string.format("Thread @%s [%s] [%s]%s", thread.author, thread.status, display_event_time(thread.created_at), location)
end

local function thread_comment_node_name(comment)
  local state = type(comment.state) == "string" and comment.state ~= "" and comment.state:upper() or "COMMENTED"
  return string.format("@%s [%s] [%s]", comment.author, state, display_event_time(comment.created_at))
end

local function clone_target_with_comment(target, comment_id)
  if type(target) ~= "table" then
    return nil
  end
  local copy = vim.deepcopy(target)
  copy.selected_comment_id = comment_id
  return copy
end

local function build_thread_comment_nodes(pr, details, thread)
  local nodes = {}
  for index, comment in ipairs(thread.comments) do
    local target = clone_target_with_comment(thread.target, comment.id)
    local timeline_item = timeline_item_for_thread_comment(thread, comment)
    nodes[#nodes + 1] = {
      id = string.format(
        "ghpr-review:%d:comments:thread-item:%s:%s:%d",
        pr.number,
        sanitize_node_id_component(thread.id),
        sanitize_node_id_component(comment.id),
        index
      ),
      name = thread_comment_node_name(comment),
      type = "file",
      extra = {
        kind = target and "comment_thread_item" or "comment_event_thread_item",
        pr = pr,
        details = details,
        target = target,
        timeline_item = timeline_item,
      },
    }
  end
  return nodes
end

local function build_thread_nodes(pr, details, threads)
  table.sort(threads, function(left, right)
    return event_sort_key(left.created_at, left.id) < event_sort_key(right.created_at, right.id)
  end)

  local nodes = {}
  for _, thread in ipairs(threads) do
    nodes[#nodes + 1] = {
      id = string.format("ghpr-review:%d:comments:thread:%s", pr.number, sanitize_node_id_component(thread.id)),
      name = thread_node_name(thread),
      type = "directory",
      extra = {
        kind = thread.target and "comment_thread" or "comment_event_thread",
        pr = pr,
        details = details,
        target = thread.target,
        timeline_item = timeline_item_for_thread(thread),
        comment_status = thread.status,
      },
      children = build_thread_comment_nodes(pr, details, thread),
    }
  end

  return nodes
end

local function collect_comment_thread_groups(pr, details, threads)
  local files = {}
  local orphan_threads = {}

  for index, raw_thread in ipairs(type(threads) == "table" and threads or {}) do
    local thread = normalize_thread_entry(raw_thread, index, pr, details)
    if thread.path ~= "" then
      files[thread.path] = files[thread.path] or { threads = {} }
      files[thread.path].threads[#files[thread.path].threads + 1] = thread
    else
      orphan_threads[#orphan_threads + 1] = thread
    end
  end

  return files, orphan_threads
end

local function build_comment_file_tree_nodes(pr, details, files)
  local file_paths = vim.tbl_keys(files)
  if vim.tbl_isempty(file_paths) then
    return {
      {
        id = string.format("ghpr-review:%d:comments:file-empty", pr.number),
        name = "No file comments",
        type = "message",
        extra = {
          kind = "message",
          pr = pr,
          details = details,
        },
      },
    }, 0
  end

  local thread_count = 0
  local entries = {}
  for _, path in ipairs(file_paths) do
    local bucket = files[path]
    thread_count = thread_count + #(bucket.threads or {})
    entries[#entries + 1] = {
      path = path,
      payload = bucket,
    }
  end

  local render_options = config.get_path_render("gh_pr")
  local nodes = path_tree.build_nodes(entries, {
    mode = render_options.mode,
    separator = render_options.separator,
    create_directory_node = function(display_name, full_path)
      return {
        id = string.format("ghpr-review:%d:comments:dir:%s", pr.number, full_path),
        name = display_name,
        type = "directory",
        extra = {
          kind = "directory",
          pr = pr,
          details = details,
        },
        children = {},
      }
    end,
    create_file_node = function(file_item)
      local path = file_item.path
      local file_name = path:match("[^/\\]+$") or path
      local bucket = file_item.payload
      return {
        id = string.format("ghpr-review:%d:comments:file:%s", pr.number, sanitize_node_id_component(path)),
        name = file_name,
        type = "comment_file",
        path = path,
        extra = {
          kind = "comment_file",
          comment_path = path,
          file_name = file_name,
          pr = pr,
          details = details,
        },
        children = build_thread_nodes(pr, details, bucket.threads or {}),
      }
    end,
  })

  return nodes, thread_count
end

local function build_review_event_nodes(pr, details, reviews)
  local items = vim.deepcopy(type(reviews) == "table" and reviews or {})
  table.sort(items, function(left, right)
    return event_sort_key(left.submitted_at, left.id) < event_sort_key(right.submitted_at, right.id)
  end)

  local nodes = {}
  for index, review in ipairs(items) do
    local state = type(review.state) == "string" and review.state:upper() or "COMMENTED"
    nodes[#nodes + 1] = {
      id = string.format("ghpr-review:%d:comments:review:%s:%d", pr.number, sanitize_node_id_component(review.id), index),
      name = string.format("Review @%s [%s] [%s]", review.author or "unknown", state, display_event_time(review.submitted_at)),
      type = "file",
      extra = {
        kind = "comment_event_review",
        review_state = state,
        pr = pr,
        details = details,
        timeline_item = {
          kind = "review",
          author = review.author,
          state = state,
          body = review.body,
          created_at = review.submitted_at,
          association = review.association,
          url = review.url,
          commit_oid = review.commit_oid,
        },
      },
    }
  end

  return nodes
end

local function build_global_comment_event_nodes(pr, details, comments)
  local items = vim.deepcopy(type(comments) == "table" and comments or {})
  table.sort(items, function(left, right)
    return event_sort_key(left.created_at, left.id) < event_sort_key(right.created_at, right.id)
  end)

  local nodes = {}
  for index, comment in ipairs(items) do
    nodes[#nodes + 1] = {
      id = string.format("ghpr-review:%d:comments:global-comment:%s:%d", pr.number, sanitize_node_id_component(comment.id), index),
      name = string.format("Comment @%s [%s]", comment.author or "unknown", display_event_time(comment.created_at)),
      type = "file",
      extra = {
        kind = "comment_event_global",
        pr = pr,
        details = details,
        timeline_item = {
          kind = "comment",
          author = comment.author,
          body = comment.body,
          created_at = comment.created_at,
          association = comment.association,
          url = comment.url,
        },
      },
    }
  end

  return nodes
end

local function build_comment_nodes(pr, details)
  local threads = type(details.review_threads) == "table" and details.review_threads or nil
  local thread_error = type(details.review_threads_error) == "string" and details.review_threads_error or nil

  if not threads then
    return {
      {
        id = string.format("ghpr-review:%d:comments-loading", pr.number),
        name = "Loading comments...",
        type = "message",
        extra = {
          kind = "message",
          pr = pr,
          details = details,
        },
      },
    }
  end

  local model = pr_service.build_overview_model(details, threads, {
    checks = 1,
    commits = 1,
    timeline = 1000,
    comments = 1000,
    reviews = 1000,
    threads = 1000,
  }, {
    repository = repository_full_name(details),
    thread_error = thread_error,
  })

  local files, orphan_threads = collect_comment_thread_groups(pr, details, threads)
  local by_file_nodes, by_file_thread_count = build_comment_file_tree_nodes(pr, details, files)
  local review_nodes = build_review_event_nodes(pr, details, type(model.reviews) == "table" and model.reviews.items or {})
  local comment_nodes = build_global_comment_event_nodes(pr, details, type(model.comments) == "table" and model.comments.items or {})
  local orphan_nodes = build_thread_nodes(pr, details, orphan_threads)

  local sections = {}
  if thread_error then
    sections[#sections + 1] = {
      id = string.format("ghpr-review:%d:comments-refresh-error", pr.number),
      name = "Unable to refresh review threads: " .. thread_error,
      type = "message",
      extra = {
        kind = "message",
        pr = pr,
        details = details,
      },
    }
  end

  local global_total = #review_nodes + #comment_nodes + #orphan_nodes
  local has_content = by_file_thread_count > 0 or global_total > 0

  if not has_content then
    if not vim.tbl_isempty(sections) then
      return sections
    end
    return {
      {
        id = string.format("ghpr-review:%d:comments-empty", pr.number),
        name = "No comments found for current PR",
        type = "message",
        extra = {
          kind = "message",
          pr = pr,
          details = details,
        },
      },
    }
  end

  sections[#sections + 1] = {
    id = string.format("ghpr-review:%d:comments:by-file", pr.number),
    name = string.format("By File (%d threads)", by_file_thread_count),
    type = "directory",
    extra = {
      kind = "comments_section",
      pr = pr,
      details = details,
    },
    children = by_file_nodes,
  }

  local global_children = {}
  global_children[#global_children + 1] = {
    id = string.format("ghpr-review:%d:comments:global-reviews", pr.number),
    name = string.format("Reviews (%d)", #review_nodes),
    type = "directory",
    extra = {
      kind = "comments_section",
      pr = pr,
      details = details,
    },
    children = not vim.tbl_isempty(review_nodes) and review_nodes or {
      {
        id = string.format("ghpr-review:%d:comments:global-reviews-empty", pr.number),
        name = "No review events",
        type = "message",
        extra = { kind = "message", pr = pr, details = details },
      },
    },
  }

  global_children[#global_children + 1] = {
    id = string.format("ghpr-review:%d:comments:global-comments", pr.number),
    name = string.format("General Comments (%d)", #comment_nodes),
    type = "directory",
    extra = {
      kind = "comments_section",
      pr = pr,
      details = details,
    },
    children = not vim.tbl_isempty(comment_nodes) and comment_nodes or {
      {
        id = string.format("ghpr-review:%d:comments:global-comments-empty", pr.number),
        name = "No general comments",
        type = "message",
        extra = { kind = "message", pr = pr, details = details },
      },
    },
  }

  if not vim.tbl_isempty(orphan_nodes) then
    global_children[#global_children + 1] = {
      id = string.format("ghpr-review:%d:comments:global-orphan-threads", pr.number),
      name = string.format("Threads (No file) (%d)", #orphan_nodes),
      type = "directory",
      extra = {
        kind = "comments_section",
        pr = pr,
        details = details,
      },
      children = orphan_nodes,
    }
  end

  sections[#sections + 1] = {
    id = string.format("ghpr-review:%d:comments:global", pr.number),
    name = string.format("Global (%d events)", global_total),
    type = "directory",
    extra = {
      kind = "comments_section",
      pr = pr,
      details = details,
    },
    children = global_children,
  }

  return sections
end

local function build_root_nodes(pr, details, repo_full_name)
  local files_children, viewed_files, total_files = build_file_nodes(pr, details, repo_full_name)
  local labels_children = build_label_nodes(pr, details)
  local reviewers_children = build_reviewer_nodes(pr, details)
  local commits_children = build_commit_nodes(pr, details)
  local checks_children = build_check_nodes(pr, details)
  local comments_children = build_comment_nodes(pr, details)
  local files_title = total_files > 0 and string.format("Files %d/%d viewed", viewed_files, total_files) or "Files"

  return {
    {
      id = string.format("ghpr-review:%d:root", pr.number),
      name = string.format("PR #%d - %s", pr.number, pr.title or ""),
      type = "folder",
      extra = {
        kind = "root",
        pr = pr,
        details = details,
      },
      children = {
        {
          id = string.format("ghpr-review:%d:overview", pr.number),
          name = "Overview",
          type = "overview",
          extra = {
            kind = "overview",
            pr = pr,
            details = details,
          },
        },
        {
          id = string.format("ghpr-review:%d:labels", pr.number),
          name = "Labels",
          type = "directory",
          extra = {
            kind = "labels",
            pr = pr,
            details = details,
          },
          children = labels_children,
        },
        {
          id = string.format("ghpr-review:%d:files", pr.number),
          name = files_title,
          type = "files",
          extra = {
            kind = "files",
            pr = pr,
            details = details,
          },
          children = files_children,
        },
        {
          id = string.format("ghpr-review:%d:reviewers", pr.number),
          name = "Reviewers",
          type = "directory",
          extra = {
            kind = "reviewers",
            pr = pr,
            details = details,
          },
          children = reviewers_children,
        },
        {
          id = string.format("ghpr-review:%d:commits", pr.number),
          name = "Commits",
          type = "directory",
          extra = {
            kind = "commits",
            pr = pr,
            details = details,
          },
          children = commits_children,
        },
        {
          id = string.format("ghpr-review:%d:checks", pr.number),
          name = "Checks",
          type = "directory",
          extra = {
            kind = "checks",
            pr = pr,
            details = details,
          },
          children = checks_children,
        },
        {
          id = string.format("ghpr-review:%d:comments", pr.number),
          name = "Comments",
          type = "directory",
          extra = {
            kind = "comments",
            pr = pr,
            details = details,
          },
          children = comments_children,
        },
      },
    },
  }
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

local function active_review_for_repo(repo_context)
  if type(repo_context) ~= "table" or type(repo_context.repository) ~= "table" then
    return nil, nil
  end

  return runtime_state.get_active_review(repo_context.repository.full_name)
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
  local review_pr, _ = active_review_for_repo(repo_context)
  local details = matching_details(session, review_pr)

  if session.last_error then
    nodes[#nodes + 1] = message_node(
      "ghpr-review:refresh-error:" .. repo_context.key,
      "Refresh error: " .. tostring(session.last_error)
    )
  end

  if not review_pr then
    nodes[#nodes + 1] = message_node(
      "ghpr-review:no-active:" .. repo_context.key,
      "No active review for this repository. Use 'Start Review' from PR source."
    )
    return nodes
  end

  if session.loading and not details then
    nodes[#nodes + 1] = message_node("ghpr-review:loading:" .. repo_context.key, "Loading PR review...")
    return nodes
  end

  if not details then
    nodes[#nodes + 1] = message_node("ghpr-review:empty:" .. repo_context.key, "Loading PR review...")
    return nodes
  end

  if show_stale_badge and session.stale then
    nodes[#nodes + 1] = message_node(
      "ghpr-review:stale:" .. repo_context.key,
      "Showing cached PR review while refreshing..."
    )
  end

  append_nodes(nodes, build_root_nodes(details, details, repo_context.repository.full_name))
  return nodes
end

local function render_state(state, session, repo_context)
  if type(state) ~= "table" then
    return false
  end

  local details = matching_details(session, active_review_for_repo(repo_context))
  if details then
    runtime_state.set_active_pr(details, details)
    runtime_state.set_active_review(repo_context.repository.full_name, details, details)
  end

  local ok = pcall(renderer.show_nodes, build_nodes(session, repo_context), state)
  return ok
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
    if type(state) ~= "table" or state.gh_pr_review_repo_key ~= repo_key then
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

local function apply_runtime_cache(session)
  local review_pr, review_details = runtime_state.get_active_review(session.repository.full_name)
  local review_number = type(review_pr) == "table" and tonumber(review_pr.number) or nil
  if not review_number or not has_full_details(review_details) then
    return
  end

  if tonumber(session.pr_number) == review_number and has_full_details(session.details) then
    return
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
  local states = follow.visible_source_states("gh_pr_review")
  if vim.tbl_isempty(states) then
    return false
  end

  local context = follow.resolve_buffer_context()
  for _, state in ipairs(states) do
    local repo_key = type(state) == "table" and state.gh_pr_review_repo_key or nil
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

local function finish_refresh(repo_context, payload)
  payload = type(payload) == "table" and payload or {}
  local refresh_context = normalize_refresh_context(payload.refresh_context)
  local ui_refresh = should_update_ui(refresh_context)
  local session = ensure_repo_session(repo_context)
  session.inflight = false
  session.loading = false

  if payload.error then
    session.last_error = payload.error
    session.stale = session_is_stale(session)
    if ui_refresh then
      render_repo_states(repo_context.key)
    end

    local pending = consume_pending_refresh(session)
    if pending then
      start_background_refresh(repo_context, pending)
    end
    return
  end

  local previous_snapshot = build_review_snapshot(session.pr_number, session.details)

  session.last_error = nil
  session.pr_number = payload.pr_number
  session.details = dedupe_details_files(payload.details)
  session.updated_at = now_seconds()
  session.stale = session_is_stale(session)

  local current_snapshot = build_review_snapshot(session.pr_number, session.details)
  local change_summary = summarize_review_changes(previous_snapshot, current_snapshot)

  comments_source.invalidate_cache()
  persist_session(repo_context, session)

  if ui_refresh then
    render_repo_states(repo_context.key)
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

  local review_pr, _ = active_review_for_repo(repo_context)
  if type(review_pr) == "table" and tonumber(review_pr.number) ~= tonumber(session.pr_number) then
    queue_pending_refresh(session, {
      force = true,
      refresh_context = refresh_context,
    })
  end

  local pending = consume_pending_refresh(session)
  if pending then
    start_background_refresh(repo_context, pending)
  end
end

start_background_refresh = function(repo_context, opts)
  opts = opts or {}
  opts.refresh_context = normalize_refresh_context(opts.refresh_context)
  local ui_refresh = should_update_ui(opts.refresh_context)
  local session = ensure_repo_session(repo_context)
  local review_pr, _ = active_review_for_repo(repo_context)
  local review_number = type(review_pr) == "table" and tonumber(review_pr.number) or nil
  if not review_number then
    session.loading = false
    session.inflight = false
    if ui_refresh then
      render_repo_states(repo_context.key)
    end
    return false
  end

  if session.inflight then
    queue_pending_refresh(session, {
      force = true,
      refresh_context = opts.refresh_context,
    })
    return false
  end

  local ttl = tonumber(cache_options().ttl_seconds) or 60
  local age = now_seconds() - (tonumber(session.updated_at) or 0)
  local has_matching = has_full_details(session.details) and tonumber(session.pr_number) == review_number
  if not opts.force and has_matching and session.updated_at > 0 and age < ttl and not session_is_stale(session) then
    return false
  end

  session.inflight = true
  session.loading = true
  session.stale = session_is_stale(session)
  if ui_refresh then
    if opts.refresh_context.reason == "timer" and opts.refresh_context.notify then
      vim.notify("Updating PR...", vim.log.levels.INFO)
    end
    render_repo_states(repo_context.key)
  end

  pr_service.fetch_details_async(review_number, function(details, details_err)
    if not details then
      finish_refresh(repo_context, {
        error = details_err or "Unable to fetch PR details",
        refresh_context = opts.refresh_context,
      })
      return
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

      finish_refresh(repo_context, {
        pr_number = review_number,
        details = details,
        refresh_context = opts.refresh_context,
      })
    end)
  end)

  return true
end

local function show_message(state, id, message)
  renderer.show_nodes({
    message_node(id, message),
  }, state)
end

M.navigate = function(state, path)
  if not repo.ensure_git_repo() then
    show_message(state, "ghpr-review:not-git", "Open a git repository to use gh-pr review")
    return
  end

  local repo_context, context_err = resolve_repo_context()
  if not repo_context then
    show_message(state, "ghpr-review:repo-error", "Unable to resolve repository: " .. tostring(context_err))
    return
  end

  state.path = path or vim.fn.getcwd()
  local session = ensure_repo_session(repo_context)
  register_state(session, state)
  apply_runtime_cache(session)
  session.stale = session_is_stale(session)

  start_background_refresh(repo_context, { force = false })
  render_state(state, session, repo_context)
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
  local winid = vim.api.nvim_get_current_win()
  if not winid or not vim.api.nvim_win_is_valid(winid) then
    return false, nil
  end

  local bufnr = vim.api.nvim_win_get_buf(winid)
  local filetype = vim.api.nvim_get_option_value("filetype", { buf = bufnr })
  if filetype ~= "neo-tree" then
    return false, nil
  end

  if vim.b[bufnr].neo_tree_source ~= "gh_pr_review" then
    return false, nil
  end

  local state = nil
  local manager_ok, manager = pcall(require, "neo-tree.sources.manager")
  if manager_ok and type(manager.get_state_for_window) == "function" then
    local ok, resolved_state = pcall(manager.get_state_for_window, winid)
    if ok then
      state = resolved_state
    end
  end

  return true, state
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
  vim.api.nvim_set_hl(0, "GhPrReviewerPending", { default = true, link = "DiagnosticWarn" })
  vim.api.nvim_set_hl(0, "GhPrReviewerApproved", { default = true, link = "DiagnosticOk" })
  vim.api.nvim_set_hl(0, "GhPrReviewerChanges", { default = true, link = "DiagnosticError" })
  vim.api.nvim_set_hl(0, "GhPrViewedBadge", { default = true, link = "DiagnosticWarn" })
  vim.api.nvim_set_hl(0, "GhPrLabelDefault", { default = true, link = "Identifier" })
  vim.api.nvim_set_hl(0, "GhPrCommentThreadResolved", { default = true, link = "DiffAdd" })
  vim.api.nvim_set_hl(0, "GhPrCommentThreadUnresolved", { default = true, link = "DiagnosticWarn" })
  vim.api.nvim_set_hl(0, "GhPrCommentThreadClosed", { default = true, link = "Comment" })
  vim.api.nvim_set_hl(0, "GhPrCommentReviewApproved", { default = true, link = "DiagnosticOk" })
  vim.api.nvim_set_hl(0, "GhPrCommentReviewChanges", { default = true, link = "DiagnosticError" })
  vim.api.nvim_set_hl(0, "GhPrCommentReviewCommented", { default = true, link = "DiagnosticInfo" })

  local commands = require("gh-pr.neotree.review_commands")
  local components = require("gh-pr.neotree.components")

  source_config.commands = vim.tbl_deep_extend("force", source_config.commands or {}, commands)
  source_config.components = source_config.components or components
  source_config.renderers = vim.tbl_deep_extend("force", source_config.renderers or {}, DEFAULT_RENDERERS)

  source_config.window = source_config.window or {}
  source_config.window.mappings = source_config.window.mappings or {}

  local default_mappings = {
    ["<space>"] = "toggle_node",
    ["<CR>"] = "gh_pr_review_open",
    ["R"] = "refresh",
    ["o"] = "open_overview",
    ["d"] = "open_diff",
    ["O"] = "open_original",
    ["M"] = "open_modified",
    ["p"] = "toggle_viewed",
    ["v"] = "toggle_viewed",
    ["l"] = "edit_labels_multi",
    ["r"] = "edit_reviewers_multi",
    ["g"] = "comment_file_global",
    ["S"] = "submit_pending_comment_review",
    ["A"] = "submit_pending_approve_review",
    ["C"] = "submit_pending_request_changes_review",
    ["D"] = "discard_pending_review",
    ["zA"] = "expand_all_review_nodes",
    ["za"] = "collapse_all_review_nodes",
    ["zF"] = "expand_files_nodes",
    ["zf"] = "collapse_files_nodes",
    ["zV"] = "expand_viewed_file_paths",
    ["zv"] = "collapse_viewed_file_paths",
    ["zC"] = "expand_comments_by_file",
    ["zc"] = "collapse_comments_by_file",
    ["zG"] = "expand_comments_global",
    ["zg"] = "collapse_comments_global",
    ["s"] = "start_review",
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

return M
