local M = {
  name = "gh_pr_review",
  display_name = "GH PR Review",
}

local cache_store = require("gh-pr.cache_store")
local comments_source = require("gh-pr.neotree.comments_source")
local config = require("gh-pr.config")
local follow = require("gh-pr.neotree.follow")
local highlights = require("gh-pr.highlights")
local review_checks_section = require("gh-pr.neotree.review_sections.checks")
local review_comments_section = require("gh-pr.neotree.review_sections.comments")
local review_files_section = require("gh-pr.neotree.review_sections.files")
local review_overview_section = require("gh-pr.neotree.review_sections.overview")
local review_reviewers_section = require("gh-pr.neotree.review_sections.reviewers")
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
    commit_files_by_key = {},
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

local function ensure_commit_file_cache(session)
  if type(session) ~= "table" then
    return {}
  end

  if type(session.commit_files_by_key) ~= "table" then
    session.commit_files_by_key = {}
  end

  return session.commit_files_by_key
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

local function build_file_nodes(pr, details, repo_full_name)
  return review_files_section.build_nodes(pr, details, repo_full_name)
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

local function commit_cache_key(pr_number, oid, fallback_key)
  if type(oid) == "string" and oid ~= "" then
    return string.format("%d:%s", pr_number, oid)
  end

  local fallback = sanitize_node_id_component(fallback_key or "commit")
  return string.format("%d:unknown:%s", pr_number, fallback)
end

local function commit_file_status_prefix(status)
  local normalized = type(status) == "string" and status:lower() or ""
  if normalized == "added" then
    return "A"
  end
  if normalized == "removed" then
    return "D"
  end
  if normalized == "renamed" then
    return "R"
  end
  if normalized == "copied" then
    return "C"
  end
  return "M"
end

local function normalize_commit_file_for_node(file)
  if type(file) ~= "table" then
    return nil
  end

  local path = type(file.path) == "string" and file.path or (type(file.filename) == "string" and file.filename or "")
  if path == "" then
    return nil
  end

  local previous = file.previousFilename or file.previous_filename
  if type(previous) ~= "string" then
    previous = ""
  end

  return {
    path = path,
    filename = type(file.filename) == "string" and file.filename ~= "" and file.filename or path,
    previousFilename = previous,
    previous_filename = previous,
    status = type(file.status) == "string" and file.status or "",
    additions = tonumber(file.additions) or 0,
    deletions = tonumber(file.deletions) or 0,
    patch = type(file.patch) == "string" and file.patch or "",
  }
end

local function commit_file_display_name(file)
  local path = file.path
  local previous = file.previous_filename or file.previousFilename or ""
  local normalized_status = type(file.status) == "string" and file.status:lower() or ""
  if normalized_status == "renamed" and previous ~= "" and previous ~= path then
    return string.format("[%s] %s -> %s", commit_file_status_prefix(normalized_status), previous, path)
  end
  return string.format("[%s] %s", commit_file_status_prefix(normalized_status), path)
end

local function build_commit_file_nodes(pr, details, commit_details)
  local nodes = {}
  local files = type(commit_details) == "table" and type(commit_details.files) == "table" and commit_details.files or {}
  local commit_oid = type(commit_details) == "table" and type(commit_details.oid) == "string" and commit_details.oid or ""
  local commit_context = {
    oid = commit_oid,
    parent_oid = type(commit_details) == "table" and type(commit_details.parent_oid) == "string"
        and commit_details.parent_oid
      or "",
    headline = type(commit_details) == "table" and type(commit_details.headline) == "string"
        and commit_details.headline
      or "",
    body = type(commit_details) == "table" and type(commit_details.body) == "string" and commit_details.body or "",
    url = type(commit_details) == "table" and type(commit_details.url) == "string" and commit_details.url or "",
    author = type(commit_details) == "table" and type(commit_details.author) == "string" and commit_details.author or nil,
    repository = type(commit_details) == "table" and type(commit_details.repository) == "string"
        and commit_details.repository
      or "",
  }

  for index, raw_file in ipairs(files) do
    local file = normalize_commit_file_for_node(raw_file)
    if file then
      nodes[#nodes + 1] = {
        id = string.format(
          "ghpr-review:%d:commit-file:%s:%s:%d",
          pr.number,
          sanitize_node_id_component(commit_oid ~= "" and commit_oid or "commit"),
          sanitize_node_id_component(file.path),
          index
        ),
        name = commit_file_display_name(file),
        type = "file",
        path = file.path,
        extra = {
          kind = "commit_file",
          pr = pr,
          details = details,
          file = file,
          commit = vim.deepcopy(commit_context),
        },
      }
    end
  end

  if vim.tbl_isempty(nodes) then
    return {
      {
        id = string.format(
          "ghpr-review:%d:commit:%s:files-empty",
          pr.number,
          sanitize_node_id_component(commit_oid ~= "" and commit_oid or "commit")
        ),
        name = "No files in commit",
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

local function build_commit_nodes(pr, details, session)
  local nodes = {}
  local seen_commit_ids = {}
  local commit_cache = ensure_commit_file_cache(session)
  for _, commit in ipairs(type(details.commits) == "table" and details.commits or {}) do
    local oid = type(commit.oid) == "string" and commit.oid or ""
    local headline = type(commit.messageHeadline) == "string" and commit.messageHeadline or "(no commit headline)"
    local commit_key = oid ~= "" and oid or (headline .. ":" .. tostring(type(commit.url) == "string" and commit.url or ""))
    if not seen_commit_ids[commit_key] then
      seen_commit_ids[commit_key] = true
      local cache_key = commit_cache_key(pr.number, oid, commit_key)
      local cached = type(commit_cache[cache_key]) == "table" and commit_cache[cache_key] or nil
      local cached_commit = type(cached) == "table" and type(cached.commit) == "table" and cached.commit or nil

      nodes[#nodes + 1] = {
        id = string.format("ghpr-review:%d:commit:%s", pr.number, oid ~= "" and oid or tostring(#nodes + 1)),
        name = string.format("%s %s", short_sha(oid), headline),
        type = "directory",
        children = type(cached) == "table" and type(cached.nodes) == "table" and vim.deepcopy(cached.nodes) or nil,
        extra = {
          kind = "commit",
          commit = {
            oid = oid,
            parent_oid = type(commit.parent_oid) == "string" and commit.parent_oid
              or (type(cached_commit) == "table" and type(cached_commit.parent_oid) == "string" and cached_commit.parent_oid or ""),
            headline = headline,
            body = type(commit.messageBody) == "string" and commit.messageBody
              or (type(cached_commit) == "table" and type(cached_commit.body) == "string" and cached_commit.body or ""),
            url = type(commit.url) == "string" and commit.url
              or (type(cached_commit) == "table" and type(cached_commit.url) == "string" and cached_commit.url or ""),
            author = type(commit.author) == "table" and commit.author.login
              or (type(cached_commit) == "table" and type(cached_commit.author) == "string" and cached_commit.author or nil),
            cache_key = cache_key,
            files_total = type(cached) == "table" and tonumber(cached.files_total) or nil,
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

local function build_check_nodes(pr, details)
  return review_checks_section.build_nodes(pr, details)
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

local function build_comment_nodes(pr, details)
  return review_comments_section.build_nodes(pr, details, {
    repository = repository_full_name(details),
  })
end

local function build_root_nodes(pr, details, repo_full_name, session)
  local files_children, viewed_files, total_files = build_file_nodes(pr, details, repo_full_name)
  local labels_children = build_label_nodes(pr, details)
  local reviewers_children = build_reviewer_nodes(pr, details)
  local commits_children = build_commit_nodes(pr, details, session)
  local checks_children = build_check_nodes(pr, details)
  local comments_children = build_comment_nodes(pr, details)
  local reviewer_states, _ = review_reviewers_section.count_states(reviewers_children)
  local commits_total = review_overview_section.count_commit_entries(commits_children)
  local check_states, _ = review_checks_section.count_states(checks_children)

  return review_overview_section.build_root_nodes(pr, details, {
    labels = labels_children,
    files = {
      title = review_overview_section.files_title(viewed_files, total_files),
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
    comments = {
      title = review_comments_section.build_section_title(details),
      children = comments_children,
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

  append_nodes(nodes, build_root_nodes(details, details, repo_context.repository.full_name, session))
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

  if tonumber(session.pr_number) ~= review_number then
    session.commit_files_by_key = {}
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
  if previous_snapshot.pr_number ~= current_snapshot.pr_number
    or previous_snapshot.commits.signature ~= current_snapshot.commits.signature then
    session.commit_files_by_key = {}
  end
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

function M.ensure_commit_files(state, node)
  if type(state) ~= "table" or type(state.tree) ~= "table" then
    return false, "Unable to resolve PR Review state"
  end

  local commit_node = type(node) == "table" and node or state.tree:get_node()
  local extra = type(commit_node) == "table" and type(commit_node.extra) == "table" and commit_node.extra or nil
  if type(extra) ~= "table" or extra.kind ~= "commit" then
    return false, "Selected node is not a commit"
  end

  local commit = type(extra.commit) == "table" and extra.commit or nil
  if type(commit) ~= "table" or type(commit.oid) ~= "string" or commit.oid == "" then
    return false, "Selected commit has no oid"
  end

  local pr = type(extra.pr) == "table" and extra.pr or nil
  local details = type(extra.details) == "table" and extra.details or nil
  local pr_number = tonumber(type(pr) == "table" and pr.number or nil) or tonumber(type(details) == "table" and details.number or nil)
  if not pr_number then
    return false, "Unable to resolve pull request number for selected commit"
  end

  local repo_key = type(state.gh_pr_review_repo_key) == "string" and state.gh_pr_review_repo_key or nil
  local session = type(repo_key) == "string" and runtime_cache.repos[repo_key] or nil
  if not session then
    local repo_context, context_err = resolve_repo_context()
    if not repo_context then
      return false, "Unable to resolve repository context: " .. tostring(context_err)
    end
    session = ensure_repo_session(repo_context)
  end

  if type(details) ~= "table" or not has_full_details(details) then
    if tonumber(session.pr_number) == pr_number and has_full_details(session.details) then
      details = session.details
    end
  end
  if type(details) ~= "table" then
    return false, "Unable to resolve pull request details for selected commit"
  end

  local cache_key = type(commit.cache_key) == "string" and commit.cache_key ~= ""
      and commit.cache_key
    or commit_cache_key(pr_number, commit.oid, commit.headline or commit.url or commit.oid)
  local commit_cache = ensure_commit_file_cache(session)
  local cached = type(commit_cache[cache_key]) == "table" and commit_cache[cache_key] or nil
  if type(cached) == "table" and type(cached.nodes) == "table" then
    commit_node.type = "directory"
    commit_node.children = vim.deepcopy(cached.nodes)
    if type(commit_node.extra) == "table" and type(commit_node.extra.commit) == "table" then
      commit_node.extra.commit.cache_key = cache_key
      commit_node.extra.commit.parent_oid = type(cached.commit) == "table"
          and type(cached.commit.parent_oid) == "string"
          and cached.commit.parent_oid
        or ""
      commit_node.extra.commit.files_total = tonumber(cached.files_total) or nil
    end
    return true, nil, false
  end

  local repository = repository_full_name(details)
  if repository == "" and type(session.repository) == "table" and type(session.repository.full_name) == "string" then
    repository = session.repository.full_name
  end

  local commit_details, commit_err = pr_service.fetch_commit_details(pr_number, commit.oid, {
    repository = repository ~= "" and repository or nil,
  })
  if not commit_details then
    return false, commit_err
  end

  local effective_pr = pr or details
  local child_nodes = build_commit_file_nodes(effective_pr, details, commit_details)
  local cached_commit = {
    oid = commit_details.oid,
    parent_oid = commit_details.parent_oid,
    headline = commit_details.headline,
    body = commit_details.body,
    url = commit_details.url,
    author = commit_details.author,
    repository = commit_details.repository,
  }
  commit_cache[cache_key] = {
    commit = cached_commit,
    files_total = tonumber(commit_details.files_total) or (type(commit_details.files) == "table" and #commit_details.files or 0),
    nodes = vim.deepcopy(child_nodes),
  }

  commit_node.type = "directory"
  commit_node.children = vim.deepcopy(child_nodes)
  if type(commit_node.extra) == "table" and type(commit_node.extra.commit) == "table" then
    commit_node.extra.commit.cache_key = cache_key
    commit_node.extra.commit.parent_oid = type(commit_details.parent_oid) == "string" and commit_details.parent_oid or ""
    commit_node.extra.commit.files_total = tonumber(commit_details.files_total)
      or (type(commit_details.files) == "table" and #commit_details.files or 0)
  end

  return true, nil, true
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
    ["zV"] = "expand_viewed_file_paths",
    ["zv"] = "collapse_viewed_file_paths",
    ["zC"] = "expand_comments_by_file",
    ["zc"] = "collapse_comments_by_file",
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

return M

