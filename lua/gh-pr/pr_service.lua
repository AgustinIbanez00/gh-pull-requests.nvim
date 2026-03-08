local M = {}

local config = require("gh-pr.config")
local gh = require("gh-pr.gh")
local repo = require("gh-pr.repo")
local pr_check_annotations = require("gh-pr.core.pr_service.check_annotations")
local pr_code_scanning = require("gh-pr.core.pr_service.code_scanning")
local pr_dependency_review = require("gh-pr.core.pr_service.dependency_review")
local pr_threads = require("gh-pr.core.pr_service.threads")
local pr_timeline = require("gh-pr.core.pr_service.timeline")
local pr_overview_model = require("gh-pr.core.pr_service.overview_model")
local pr_viewed_files = require("gh-pr.core.pr_service.viewed_files")

local user_cache = {
  login = nil,
}

local default_pr_fields = table.concat({
  "number",
  "title",
  "state",
  "isDraft",
  "author",
  "updatedAt",
  "reviewDecision",
  "url",
  "headRefName",
  "baseRefName",
}, ",")

local detail_fields = table.concat({
  "number",
  "title",
  "body",
  "state",
  "isDraft",
  "author",
  "assignees",
  "labels",
  "milestone",
  "reviewDecision",
  "latestReviews",
  "url",
  "headRefName",
  "headRefOid",
  "baseRefName",
  "headRepository",
  "headRepositoryOwner",
  "isCrossRepository",
  "mergeStateStatus",
  "mergeable",
  "maintainerCanModify",
  "createdAt",
  "updatedAt",
  "mergedAt",
  "additions",
  "deletions",
  "changedFiles",
  "files",
  "commits",
  "comments",
  "statusCheckRollup",
  "reviews",
  "reviewRequests",
}, ",")

local function notify_error(err)
  if err and err ~= "" then
    vim.notify(err, vim.log.levels.ERROR)
  end
end

local function get_user_login()
  if user_cache.login then
    return user_cache.login, nil
  end

  local user, err = gh.run_json({ "api", "user" })
  if not user then
    return nil, err
  end

  if type(user.login) ~= "string" or user.login == "" then
    return nil, "Unable to resolve current GitHub user"
  end

  user_cache.login = user.login
  return user_cache.login, nil
end

local function get_user_login_async(callback)
  callback = callback or function() end
  if user_cache.login then
    callback(user_cache.login, nil)
    return
  end

  gh.run_json_async({ "api", "user" }, nil, function(user, err)
    if not user then
      callback(nil, err)
      return
    end

    if type(user.login) ~= "string" or user.login == "" then
      callback(nil, "Unable to resolve current GitHub user")
      return
    end

    user_cache.login = user.login
    callback(user_cache.login, nil)
  end)
end

function M.get_current_user_login()
  return get_user_login()
end

local function has_search_qualifier(query, qualifier)
  if type(query) ~= "string" or query == "" then
    return false
  end

  if type(qualifier) ~= "string" or qualifier == "" then
    return false
  end

  local pattern = string.format("%%f[%%w_]%s:", qualifier:lower())
  return query:lower():find(pattern) ~= nil
end

local function should_append_repo_filter(query)
  return not has_search_qualifier(query, "repo") and not has_search_qualifier(query, "org")
end

local function append_repo_filter(query, repository)
  if not should_append_repo_filter(query) then
    return query
  end

  return string.format("%s repo:%s", query, repository.full_name)
end

local function apply_query_placeholders(query, context)
  local normalized = type(query) == "string" and query or ""
  context = type(context) == "table" and context or {}

  local user = type(context.user) == "string" and context.user or ""
  local owner = type(context.owner) == "string" and context.owner or ""
  local repository_name = type(context.repository) == "string" and context.repository or ""

  normalized = normalized:gsub("%${user}", user)
  normalized = normalized:gsub("%${owner}", owner)
  normalized = normalized:gsub("%${repository}", repository_name)
  normalized = normalized:gsub("@org", owner)

  return normalized
end

local function expand_query(raw_query, repository)
  if raw_query == "default" then
    return "is:open repo:" .. repository.full_name
  end

  local query = raw_query
  local user, user_err = get_user_login()
  if not user then
    return nil, user_err
  end

  query = apply_query_placeholders(query, {
    user = user,
    owner = repository.owner,
    repository = repository.name,
  })
  query = append_repo_filter(query, repository)

  return query, nil
end

local function expand_query_async(raw_query, repository, callback)
  callback = callback or function() end
  if raw_query == "default" then
    callback("is:open repo:" .. repository.full_name, nil)
    return
  end

  get_user_login_async(function(user, user_err)
    if not user then
      callback(nil, user_err)
      return
    end

    local query = apply_query_placeholders(raw_query, {
      user = user,
      owner = repository.owner,
      repository = repository.name,
    })
    query = append_repo_filter(query, repository)
    callback(query, nil)
  end)
end

function M.resolve_repository()
  local plugin_config = config.get()
  local repository, err = repo.resolve_repository(plugin_config.remotes)
  if not repository then
    return nil, err
  end

  return repository, nil
end

local function normalize_repository_filter(input)
  if type(input) == "table" then
    if type(input.owner) == "string" and input.owner ~= "" and type(input.name) == "string" and input.name ~= "" then
      input.full_name = input.full_name or (input.owner .. "/" .. input.name)
      return input
    end

    if type(input.full_name) == "string" and input.full_name ~= "" then
      local owner, name = input.full_name:match("^([^/]+)/(.+)$")
      if owner and name then
        return {
          owner = owner,
          name = name,
          full_name = input.full_name,
        }
      end
    end
  end

  if type(input) == "string" and input ~= "" then
    local owner, name = input:match("^([^/]+)/(.+)$")
    if owner and name then
      return {
        owner = owner,
        name = name,
        full_name = input,
      }
    end
  end

  return nil
end

local function normalize_repo(owner, name)
  if type(owner) ~= "string" or owner == "" then
    return nil
  end

  if type(name) ~= "string" or name == "" then
    return nil
  end

  return {
    owner = {
      login = owner,
    },
    name = name,
    nameWithOwner = owner .. "/" .. name,
  }
end

local function enrich_details_with_repositories(details)
  if type(details) ~= "table" then
    return details
  end

  local base_repo, _ = M.resolve_repository()
  if base_repo then
    details.baseRepository = normalize_repo(base_repo.owner, base_repo.name)
  end

  if type(details.headRepository) == "table" then
    local owner
    if type(details.headRepositoryOwner) == "table" then
      owner = details.headRepositoryOwner.login
    elseif details.baseRepository and details.isCrossRepository == false then
      owner = details.baseRepository.owner and details.baseRepository.owner.login
    end

    if owner then
      details.headRepository.owner = details.headRepository.owner or { login = owner }
      if not details.headRepository.nameWithOwner and type(details.headRepository.name) == "string" then
        details.headRepository.nameWithOwner = owner .. "/" .. details.headRepository.name
      end
    end
  end

  if not details.baseRepository and type(details.headRepository) == "table" then
    details.baseRepository = details.headRepository
  end

  return details
end

local function clamp_positive(value, fallback, max_value)
  local number = tonumber(value)
  if not number then
    number = fallback
  end

  number = math.floor(number)
  if number < 1 then
    number = fallback
  end

  if max_value and number > max_value then
    number = max_value
  end

  return number
end

local function normalize_string(value, fallback)
  if type(value) == "string" and value ~= "" then
    return value
  end

  return fallback or ""
end

local function normalize_login(entity, fallback)
  fallback = fallback or "unknown"
  if type(entity) == "table" then
    if type(entity.login) == "string" and entity.login ~= "" then
      return entity.login
    end
    if type(entity.author) == "table" and type(entity.author.login) == "string" and entity.author.login ~= "" then
      return entity.author.login
    end
  end

  if type(entity) == "string" and entity ~= "" then
    return entity
  end

  return fallback
end

local function take_recent(items, limit)
  items = type(items) == "table" and items or {}
  local total = #items
  local count = clamp_positive(limit, total > 0 and total or 1)

  if total <= count then
    return vim.deepcopy(items), total
  end

  local selected = {}
  local start_index = total - count + 1
  for index = start_index, total do
    selected[#selected + 1] = items[index]
  end

  return selected, total
end

local function normalize_labels(labels)
  local normalized = {}
  for _, item in ipairs(type(labels) == "table" and labels or {}) do
    normalized[#normalized + 1] = {
      name = normalize_string(item.name, "unknown"),
      color = normalize_string(item.color, ""),
      description = normalize_string(item.description, ""),
    }
  end
  return normalized
end

local function normalize_review_requests(review_requests)
  local normalized = {}
  for _, item in ipairs(type(review_requests) == "table" and review_requests or {}) do
    normalized[#normalized + 1] = normalize_login(item, "unknown")
  end
  return normalized
end

local function normalize_assignees(assignees)
  local normalized = {}
  for _, item in ipairs(type(assignees) == "table" and assignees or {}) do
    normalized[#normalized + 1] = normalize_login(item, "unknown")
  end
  return normalized
end

local function normalize_commits(commits)
  local normalized = {}
  for _, commit in ipairs(type(commits) == "table" and commits or {}) do
    local first_author = type(commit.authors) == "table" and commit.authors[1] or nil
    local author = normalize_login(first_author or commit.author, "unknown")
    local oid = normalize_string(commit.oid, "")
    normalized[#normalized + 1] = {
      oid = oid,
      oid_short = oid ~= "" and oid:sub(1, 8) or "",
      headline = normalize_string(commit.messageHeadline, "(no commit headline)"),
      body = normalize_string(commit.messageBody, ""),
      authored_at = normalize_string(commit.authoredDate, commit.committedDate or ""),
      committed_at = normalize_string(commit.committedDate, commit.authoredDate or ""),
      author = author,
      url = normalize_string(commit.url, ""),
    }
  end
  return normalized
end

local function normalize_comments(comments)
  local normalized = {}
  for _, comment in ipairs(type(comments) == "table" and comments or {}) do
    normalized[#normalized + 1] = {
      id = normalize_string(comment.id, ""),
      author = normalize_login(comment.author, "unknown"),
      association = normalize_string(comment.authorAssociation, ""),
      body = normalize_string(comment.body, ""),
      created_at = normalize_string(comment.createdAt, ""),
      url = normalize_string(comment.url, ""),
    }
  end
  return normalized
end

local function normalize_reviews(reviews)
  local normalized = {}
  for _, review in ipairs(type(reviews) == "table" and reviews or {}) do
    local commit = type(review.commit) == "table" and normalize_string(review.commit.oid, "") or ""
    normalized[#normalized + 1] = {
      id = normalize_string(review.id, ""),
      author = normalize_login(review.author, "unknown"),
      state = normalize_string(review.state, "COMMENTED"),
      body = normalize_string(review.body, ""),
      submitted_at = normalize_string(review.submittedAt, ""),
      association = normalize_string(review.authorAssociation, ""),
      commit_oid = commit,
      url = normalize_string(review.url, ""),
    }
  end
  return normalized
end

local function normalize_reaction_groups(groups)
  local normalized = {}
  for _, group in ipairs(type(groups) == "table" and groups or {}) do
    local content = normalize_string(group.content, "")
    if content ~= "" then
      local users = type(group.users) == "table" and group.users or {}
      normalized[#normalized + 1] = {
        content = content,
        total_count = tonumber(users.totalCount) or tonumber(group.totalCount) or 0,
        viewer_has_reacted = group.viewerHasReacted == true,
      }
    end
  end
  return normalized
end

local function normalize_checks(checks)
  local normalized = {}
  for _, check in ipairs(type(checks) == "table" and checks or {}) do
    local name = normalize_string(check.name, check.context or "")
    if name == "" and type(check.workflowRun) == "table" and type(check.workflowRun.workflow) == "table" then
      name = normalize_string(check.workflowRun.workflow.name, "")
    end
    if name == "" then
      name = normalize_string(check.__typename, "check")
    end

    normalized[#normalized + 1] = {
      name = name,
      status = normalize_string(check.status, check.state or ""),
      conclusion = normalize_string(check.conclusion, ""),
      workflow = normalize_string(check.workflowName, ""),
      url = normalize_string(check.detailsUrl, check.targetUrl or check.url or ""),
      details_url = normalize_string(check.detailsUrl, ""),
      target_url = normalize_string(check.targetUrl, ""),
      check_run_id = tonumber(check.checkRunId) or tonumber(check.check_run_id) or tonumber(check.databaseId),
      database_id = tonumber(check.databaseId),
      head_sha = normalize_string(check.headSha, ""),
    }
  end
  return normalized
end

local function normalize_threads(threads)
  local normalized = {}
  for _, thread in ipairs(type(threads) == "table" and threads or {}) do
    local thread_comments = {}
    for _, comment in ipairs(type(thread.comments) == "table" and thread.comments or {}) do
      thread_comments[#thread_comments + 1] = {
        id = normalize_string(comment.id, ""),
        path = normalize_string(comment.path, normalize_string(thread.path, "")),
        line = tonumber(comment.line) or 0,
        original_line = tonumber(comment.originalLine) or 0,
        diff_hunk = normalize_string(comment.diffHunk, ""),
        diff_side = normalize_string(comment.diffSide, normalize_string(thread.diffSide, "")),
        commit_oid = normalize_string(type(comment.commit) == "table" and comment.commit.oid or "", ""),
        original_commit_oid = normalize_string(type(comment.originalCommit) == "table" and comment.originalCommit.oid or "", ""),
        author = normalize_login(comment.author, "unknown"),
        viewer_did_author = comment.viewerDidAuthor == true or comment.viewer_did_author == true,
        body = normalize_string(comment.body, ""),
        created_at = normalize_string(comment.createdAt, ""),
        state = normalize_string(comment.state, ""),
        outdated = comment.outdated == true,
        url = normalize_string(comment.url, ""),
        reaction_groups = normalize_reaction_groups(comment.reactionGroups or comment.reaction_groups),
        is_pending = comment.isPending == true or comment.is_pending == true or normalize_string(comment.state, ""):upper() == "PENDING",
      }
    end

    normalized[#normalized + 1] = {
      id = normalize_string(thread.id, ""),
      path = normalize_string(thread.path, ""),
      line = tonumber(thread.line) or 0,
      original_line = tonumber(thread.originalLine) or 0,
      start_line = tonumber(thread.startLine) or 0,
      original_start_line = tonumber(thread.originalStartLine) or 0,
      diff_side = normalize_string(thread.diffSide, ""),
      is_resolved = thread.isResolved == true,
      is_outdated = thread.isOutdated == true,
      comments = thread_comments,
    }
  end

  return normalized
end

local function normalize_files(files)
  local normalized = {}
  local by_path = {}
  local order = {}

  local function upsert(entry)
    local existing = by_path[entry.path]
    if not existing then
      by_path[entry.path] = entry
      order[#order + 1] = entry.path
      return
    end

    if existing.filename == "" and entry.filename ~= "" then
      existing.filename = entry.filename
    end
    if existing.previous_filename == "" and entry.previous_filename ~= "" then
      existing.previous_filename = entry.previous_filename
    end
    if existing.status == "" and entry.status ~= "" then
      existing.status = entry.status
    end
    if existing.patch == "" and entry.patch ~= "" then
      existing.patch = entry.patch
    end
    if tonumber(existing.additions) == 0 and tonumber(entry.additions) > 0 then
      existing.additions = entry.additions
    end
    if tonumber(existing.deletions) == 0 and tonumber(entry.deletions) > 0 then
      existing.deletions = entry.deletions
    end
  end

  for _, file in ipairs(type(files) == "table" and files or {}) do
    local path = normalize_string(file.path, normalize_string(file.filename, ""))
    if path ~= "" then
      upsert({
        path = path,
        filename = normalize_string(file.filename, path),
        previous_filename = normalize_string(file.previousFilename, normalize_string(file.previous_filename, "")),
        status = normalize_string(file.status, ""),
        additions = tonumber(file.additions) or 0,
        deletions = tonumber(file.deletions) or 0,
        patch = normalize_string(file.patch, ""),
      })
    end
  end

  for _, path in ipairs(order) do
    normalized[#normalized + 1] = by_path[path]
  end

  return normalized
end

local function dedupe_prs(prs)
  local result = {}
  local seen = {}
  for _, pr in ipairs(type(prs) == "table" and prs or {}) do
    local number = tonumber(type(pr) == "table" and pr.number or nil)
    local key = number and tostring(number) or nil
    if key and not seen[key] then
      seen[key] = true
      result[#result + 1] = pr
    end
  end
  return result
end

local function normalize_file_key(path)
  if type(path) ~= "string" then
    return nil
  end

  local normalized = path:gsub("\\", "/"):gsub("/+", "/"):gsub("^/", ""):gsub("/$", "")
  if normalized == "" then
    return nil
  end
  return normalized
end

local function details_files_need_enrichment(files)
  for _, file in ipairs(type(files) == "table" and files or {}) do
    if type(file) == "table" then
      local status = normalize_string(file.status, "")
      if status == "" then
        return true
      end
    end
  end
  return false
end

local function merge_file_metadata(details, rest_files)
  if type(details) ~= "table" then
    return details
  end

  local rest_map = {}
  for _, item in ipairs(type(rest_files) == "table" and rest_files or {}) do
    local key = normalize_file_key(item.filename or item.path)
    if key then
      rest_map[key] = {
        filename = normalize_string(item.filename, key),
        previous_filename = normalize_string(item.previous_filename, ""),
        status = normalize_string(item.status, ""),
        additions = tonumber(item.additions) or 0,
        deletions = tonumber(item.deletions) or 0,
        patch = normalize_string(item.patch, ""),
      }
    end
  end

  if vim.tbl_isempty(rest_map) then
    return details
  end

  local merged = {}
  local seen = {}
  for _, file in ipairs(type(details.files) == "table" and details.files or {}) do
    local key = normalize_file_key(file.path or file.filename)
    if key then
      local meta = rest_map[key] or {}
      seen[key] = true
      merged[#merged + 1] = {
        path = normalize_string(file.path, normalize_string(file.filename, key)),
        filename = normalize_string(file.filename, normalize_string(meta.filename, key)),
        previousFilename = normalize_string(
          file.previousFilename,
          normalize_string(file.previous_filename, normalize_string(meta.previous_filename, ""))
        ),
        status = normalize_string(file.status, normalize_string(meta.status, "")),
        additions = tonumber(file.additions) or tonumber(meta.additions) or 0,
        deletions = tonumber(file.deletions) or tonumber(meta.deletions) or 0,
        patch = normalize_string(file.patch, normalize_string(meta.patch, "")),
      }
    end
  end

  for key, meta in pairs(rest_map) do
    if not seen[key] then
      merged[#merged + 1] = {
        path = key,
        filename = normalize_string(meta.filename, key),
        previousFilename = normalize_string(meta.previous_filename, ""),
        status = normalize_string(meta.status, ""),
        additions = tonumber(meta.additions) or 0,
        deletions = tonumber(meta.deletions) or 0,
        patch = normalize_string(meta.patch, ""),
      }
    end
  end

  details.files = merged
  return details
end

function M.list_for_query(query)
  local repository, repo_err = M.resolve_repository()
  if not repository then
    return nil, repo_err
  end

  local search, query_err = expand_query(query, repository)
  if not search then
    return nil, query_err
  end

  local plugin_config = config.get()
  local args = {
    "pr",
    "list",
    "--limit",
    tostring(plugin_config.max_results),
    "--state",
    "all",
    "--search",
    search,
    "--json",
    default_pr_fields,
  }

  local prs, err = gh.run_json(args)
  if not prs then
    return nil, err
  end

  return dedupe_prs(prs), nil
end

function M.list_for_query_async(query, callback, opts)
  callback = callback or function() end
  opts = opts or {}

  local repository = normalize_repository_filter(opts.repository)
  if not repository then
    local resolved, repo_err = M.resolve_repository()
    if not resolved then
      callback(nil, repo_err)
      return
    end
    repository = resolved
  end

  expand_query_async(query, repository, function(search, query_err)
    if not search then
      callback(nil, query_err)
      return
    end

    local plugin_config = config.get()
    local args = {
      "pr",
      "list",
      "--limit",
      tostring(plugin_config.max_results),
      "--state",
      "all",
      "--search",
      search,
      "--json",
      default_pr_fields,
    }

    gh.run_json_async(args, nil, function(prs, err)
      if not prs then
        callback(nil, err)
        return
      end
      callback(dedupe_prs(prs), nil)
    end)
  end)
end

function M.list_queries_with_results()
  local results = {}

  for _, query in ipairs(config.get_queries()) do
    local prs, err = M.list_for_query(query.query)
    if not prs then
      table.insert(results, {
        query = query,
        error = err,
        prs = {},
      })
    else
      table.insert(results, {
        query = query,
        error = nil,
        prs = prs,
      })
    end
  end

  return results
end

function M.list_queries_with_results_async(callback, opts)
  callback = callback or function() end
  opts = opts or {}

  local repository = normalize_repository_filter(opts.repository)
  if not repository then
    local resolved, repo_err = M.resolve_repository()
    if not resolved then
      callback(nil, repo_err)
      return
    end
    repository = resolved
  end

  local configured_queries = config.get_queries()
  local results = {}
  local index = 1

  local function load_next()
    local query = configured_queries[index]
    if not query then
      callback(results, nil)
      return
    end

    M.list_for_query_async(query.query, function(prs, err)
      if not prs then
        results[#results + 1] = {
          query = query,
          error = err,
          prs = {},
        }
      else
        results[#results + 1] = {
          query = query,
          error = nil,
          prs = prs,
        }
      end

      index = index + 1
      load_next()
    end, {
      repository = repository,
    })
  end

  load_next()
end

function M.fetch_details(number)
  local details, err = gh.run_json({
    "pr",
    "view",
    tostring(number),
    "--json",
    detail_fields,
  })

  if not details then
    return nil, err
  end

  local enriched = enrich_details_with_repositories(details)
  if type(enriched) == "table" and details_files_need_enrichment(enriched.files) then
    local rest_files, rest_err = M.fetch_pr_files_api(number)
    if rest_files then
      enriched = merge_file_metadata(enriched, rest_files)
    elseif rest_err and rest_err ~= "" then
      -- keep details from gh pr view; callers can still infer mode from fetch errors
    end
  end

  return enriched, nil
end

function M.fetch_details_async(number, callback)
  callback = callback or function() end
  gh.run_json_async({
    "pr",
    "view",
    tostring(number),
    "--json",
    detail_fields,
  }, nil, function(details, err)
    if not details then
      callback(nil, err)
      return
    end

    local enriched = enrich_details_with_repositories(details)
    if type(enriched) ~= "table" or not details_files_need_enrichment(enriched.files) then
      callback(enriched, nil)
      return
    end

    M.fetch_pr_files_api_async(number, function(rest_files)
      if rest_files then
        enriched = merge_file_metadata(enriched, rest_files)
      end
      callback(enriched, nil)
    end)
  end)
end

local function threads_service_context()
  return {
    clamp_positive = clamp_positive,
    normalize_string = normalize_string,
    normalize_threads = normalize_threads,
    resolve_repository = M.resolve_repository,
    gh = gh,
  }
end

local function timeline_model_context()
  local normalize_diff_side = function(value)
    return pr_threads.normalize_diff_side(value, {
      normalize_string = normalize_string,
    })
  end

  return {
    normalize_string = normalize_string,
    normalize_login = normalize_login,
    normalize_diff_side = normalize_diff_side,
    first_positive_line = pr_threads.first_positive_line,
  }
end

local function overview_model_context()
  local timeline_ctx = timeline_model_context()

  return {
    clamp_positive = clamp_positive,
    normalize_string = normalize_string,
    normalize_login = normalize_login,
    normalize_labels = normalize_labels,
    normalize_assignees = normalize_assignees,
    normalize_review_requests = normalize_review_requests,
    normalize_checks = normalize_checks,
    normalize_commits = normalize_commits,
    normalize_comments = normalize_comments,
    normalize_reviews = normalize_reviews,
    normalize_threads = normalize_threads,
    normalize_files = normalize_files,
    take_recent = take_recent,
    normalize_pr_change_events = function(events)
      return pr_timeline.normalize_pr_change_events(events, timeline_ctx)
    end,
    build_timeline_items = function(comments, reviews, threads, commits, pr_change_events)
      return pr_timeline.build_timeline_items(comments, reviews, threads, commits, pr_change_events, timeline_ctx)
    end,
  }
end

function M.fetch_review_threads(number, opts)
  return pr_threads.fetch_review_threads(number, opts, threads_service_context())
end

function M.fetch_review_threads_async(number, opts, callback)
  return pr_threads.fetch_review_threads_async(number, opts, callback, threads_service_context())
end

function M.fetch_review_threads_with_pending(number, opts)
  local threads, thread_err = M.fetch_review_threads(number, opts)
  if not threads then
    return nil, thread_err
  end

  local pending_payload, pending_err = M.fetch_pending_review_comments(number)
  if pending_payload and type(M.merge_pending_review_comments) == "function" then
    threads = M.merge_pending_review_comments(threads, pending_payload)
  end

  return threads, pending_err
end

function M.fetch_review_threads_with_pending_async(number, opts, callback)
  callback = callback or function() end

  M.fetch_review_threads_async(number, opts, function(threads, thread_err)
    if not threads then
      callback(nil, thread_err)
      return
    end

    if type(M.fetch_pending_review_comments_async) ~= "function" then
      callback(threads, nil)
      return
    end

    M.fetch_pending_review_comments_async(number, function(pending_payload, pending_err)
      if pending_payload and type(M.merge_pending_review_comments) == "function" then
        threads = M.merge_pending_review_comments(threads, pending_payload)
      end

      callback(threads, pending_err)
    end)
  end)
end

function M.build_line_comment_index(threads, opts)
  return pr_threads.build_line_comment_index(threads, opts, threads_service_context())
end

function M.build_overview_model(details, threads, limits, opts)
  return pr_overview_model.build(details, threads, limits, opts, overview_model_context())
end
local function normalize_repository_from_input(input)
  if type(input) == "string" and input ~= "" then
    local owner, name = input:match("^([^/]+)/(.+)$")
    if owner and name then
      return {
        owner = owner,
        name = name,
        full_name = owner .. "/" .. name,
      }
    end
  end

  if type(input) == "table" then
    if type(input.full_name) == "string" and input.full_name ~= "" then
      local owner, name = input.full_name:match("^([^/]+)/(.+)$")
      if owner and name then
        return {
          owner = owner,
          name = name,
          full_name = input.full_name,
        }
      end
    end

    if type(input.owner) == "string" and input.owner ~= "" and type(input.name) == "string" and input.name ~= "" then
      return {
        owner = input.owner,
        name = input.name,
        full_name = input.owner .. "/" .. input.name,
      }
    end
  end

  return nil
end

function M.fetch_commit_details(pr_number, oid, opts)
  opts = opts or {}
  oid = normalize_string(oid, "")
  if oid == "" then
    return nil, "Missing commit oid"
  end

  local repository = normalize_repository_from_input(opts.repository)
  if not repository then
    local resolved, repo_err = M.resolve_repository()
    if not resolved then
      return nil, repo_err
    end
    repository = resolved
  end

  local endpoint = string.format("repos/%s/%s/commits/%s", repository.owner, repository.name, oid)
  local payload, err = gh.run_json({ "api", endpoint })
  if not payload then
    return nil, err
  end

  local commit_block = type(payload.commit) == "table" and payload.commit or {}
  local message = normalize_string(commit_block.message, "")
  local headline = message:match("([^\n]+)") or "(no commit message)"
  local body = message:match("^[^\n]*\n(.*)$") or ""
  local authored_at = type(commit_block.author) == "table" and normalize_string(commit_block.author.date, "") or ""
  local committed_at = type(commit_block.committer) == "table" and normalize_string(commit_block.committer.date, "") or authored_at
  local author = normalize_login(payload.author or commit_block.author, "unknown")
  local sha = normalize_string(payload.sha, oid)
  local parents = type(payload.parents) == "table" and payload.parents or {}
  local parent_oid = normalize_string(type(parents[1]) == "table" and parents[1].sha or "", "")

  local files = normalize_files(payload.files)
  for _, file in ipairs(files) do
    file.patch = normalize_string(file.patch, "")
  end

  local stats = type(payload.stats) == "table" and payload.stats or {}
  return {
    pr_number = tonumber(pr_number) or 0,
    oid = sha,
    oid_short = sha ~= "" and sha:sub(1, 8) or "",
    headline = headline,
    body = body,
    authored_at = authored_at,
    committed_at = committed_at,
    author = author,
    repository = repository.full_name,
    url = normalize_string(payload.html_url, ""),
    parent_oid = parent_oid,
    parents_total = #parents,
    files = files,
    files_total = #files,
    additions = tonumber(stats.additions) or 0,
    deletions = tonumber(stats.deletions) or 0,
  }, nil
end

local function append_csv_flag(args, flag, values)
  if type(values) ~= "table" or vim.tbl_isempty(values) then
    return false
  end

  local normalized = {}
  for _, value in ipairs(values) do
    if type(value) == "string" and value ~= "" then
      normalized[#normalized + 1] = value
    end
  end

  if vim.tbl_isempty(normalized) then
    return false
  end

  table.insert(args, flag)
  table.insert(args, table.concat(normalized, ","))
  return true
end

function M.edit(number, operations)
  operations = type(operations) == "table" and operations or {}
  local args = { "pr", "edit", tostring(number) }
  local has_operations = false

  if operations.title ~= nil then
    table.insert(args, "--title")
    table.insert(args, tostring(operations.title))
    has_operations = true
  end

  if operations.body ~= nil then
    table.insert(args, "--body")
    table.insert(args, tostring(operations.body))
    has_operations = true
  end

  if operations.base ~= nil then
    table.insert(args, "--base")
    table.insert(args, tostring(operations.base))
    has_operations = true
  end

  if operations.remove_milestone == true then
    table.insert(args, "--remove-milestone")
    has_operations = true
  elseif operations.milestone ~= nil then
    table.insert(args, "--milestone")
    table.insert(args, tostring(operations.milestone))
    has_operations = true
  end

  if append_csv_flag(args, "--add-label", operations.add_labels) then
    has_operations = true
  end
  if append_csv_flag(args, "--remove-label", operations.remove_labels) then
    has_operations = true
  end
  if append_csv_flag(args, "--add-reviewer", operations.add_reviewers) then
    has_operations = true
  end
  if append_csv_flag(args, "--remove-reviewer", operations.remove_reviewers) then
    has_operations = true
  end
  if append_csv_flag(args, "--add-assignee", operations.add_assignees) then
    has_operations = true
  end
  if append_csv_flag(args, "--remove-assignee", operations.remove_assignees) then
    has_operations = true
  end

  if not has_operations then
    return false, "No edit operations provided"
  end

  local _, err = gh.run(args)
  if err then
    return false, err
  end

  return true, nil
end

function M.change_state(number, target_state)
  local normalized = normalize_string(target_state, ""):lower()
  local args
  if normalized == "open" then
    args = { "pr", "reopen", tostring(number) }
  elseif normalized == "closed" then
    args = { "pr", "close", tostring(number) }
  else
    return false, "Unsupported target state"
  end

  local _, err = gh.run(args)
  if err then
    return false, err
  end

  return true, nil
end

function M.change_draft(number, target_mode)
  local normalized = normalize_string(target_mode, ""):lower()
  local args = { "pr", "ready", tostring(number) }
  if normalized == "draft" then
    table.insert(args, "--undo")
  elseif normalized ~= "ready" then
    return false, "Unsupported draft target"
  end

  local _, err = gh.run(args)
  if err then
    return false, err
  end

  return true, nil
end

function M.checkout(number)
  local _, err = gh.run({ "pr", "checkout", tostring(number) })
  if err then
    return false, err
  end

  return true, nil
end

function M.open_in_browser(number)
  local _, err = gh.run({ "pr", "view", tostring(number), "--web" })
  if err then
    return false, err
  end

  return true, nil
end

function M.open_url_in_browser(url)
  local target = type(url) == "string" and vim.trim(url) or ""
  if target == "" then
    return false, "Missing URL"
  end
  if not target:match("^https?://") then
    return false, "Only http/https URLs are supported"
  end

  local _, err = gh.run({ "browse", target })
  if err then
    return false, err
  end

  return true, nil
end

function M.review(number, event, body)
  local args = { "pr", "review", tostring(number) }

  if event == "approve" then
    table.insert(args, "--approve")
    if body and body ~= "" then
      table.insert(args, "--body")
      table.insert(args, body)
    end
  elseif event == "request_changes" then
    table.insert(args, "--request-changes")
    table.insert(args, "--body")
    table.insert(args, body ~= "" and body or "Requested changes from gh-pr.nvim")
  elseif event == "comment" then
    table.insert(args, "--comment")
    table.insert(args, "--body")
    table.insert(args, body ~= "" and body or "Comment from gh-pr.nvim")
  else
    return false, "Unsupported review event"
  end

  local _, err = gh.run(args)
  if err then
    return false, err
  end

  return true, nil
end

function M.comment(number, body)
  local message = type(body) == "string" and vim.trim(body) or ""
  if message == "" then
    return false, "Comment message cannot be empty"
  end

  local _, err = gh.run({
    "pr",
    "comment",
    tostring(number),
    "--body",
    message,
  })
  if err then
    return false, err
  end

  return true, nil
end

local function graphql_error_message(response, fallback)
  fallback = fallback or "GraphQL request failed"
  if type(response) ~= "table" then
    return fallback
  end

  local errors = response.errors
  if type(errors) ~= "table" or #errors == 0 then
    return fallback
  end

  local first_error = errors[1]
  if type(first_error) == "table" and type(first_error.message) == "string" and first_error.message ~= "" then
    return first_error.message
  end

  return fallback
end

local function run_graphql(query, variables)
  local args = {
    "api",
    "graphql",
    "-f",
    "query=" .. query,
  }

  for _, variable in ipairs(type(variables) == "table" and variables or {}) do
    local key = type(variable.key) == "string" and variable.key or nil
    local value = variable.value
    if key and value ~= nil then
      local flag = variable.flag == "-F" and "-F" or "-f"
      table.insert(args, flag)
      table.insert(args, key .. "=" .. tostring(value))
    end
  end

  local response, err = gh.run_json(args)
  if not response then
    return nil, err
  end

  if type(response.errors) == "table" and #response.errors > 0 then
    return nil, graphql_error_message(response)
  end

  return response, nil
end

local function run_graphql_async(query, variables, callback)
  callback = callback or function() end

  local args = {
    "api",
    "graphql",
    "-f",
    "query=" .. query,
  }

  for _, variable in ipairs(type(variables) == "table" and variables or {}) do
    local key = type(variable.key) == "string" and variable.key or nil
    local value = variable.value
    if key and value ~= nil then
      local flag = variable.flag == "-F" and "-F" or "-f"
      table.insert(args, flag)
      table.insert(args, key .. "=" .. tostring(value))
    end
  end

  gh.run_json_async(args, nil, function(response, err)
    if not response then
      callback(nil, err)
      return
    end

    if type(response.errors) == "table" and #response.errors > 0 then
      callback(nil, graphql_error_message(response))
      return
    end

    callback(response, nil)
  end)
end

local function timeline_service_context()
  local normalize_diff_side = function(value)
    return pr_threads.normalize_diff_side(value, {
      normalize_string = normalize_string,
    })
  end

  return {
    normalize_string = normalize_string,
    normalize_login = normalize_login,
    clamp_positive = clamp_positive,
    resolve_repository = M.resolve_repository,
    normalize_repository_from_input = normalize_repository_from_input,
    run_graphql = run_graphql,
    run_graphql_async = run_graphql_async,
    normalize_diff_side = normalize_diff_side,
    first_positive_line = pr_threads.first_positive_line,
  }
end

local function viewed_files_service_context()
  return {
    clamp_positive = clamp_positive,
    resolve_repository = M.resolve_repository,
    run_graphql = run_graphql,
    run_graphql_async = run_graphql_async,
  }
end

local function check_annotations_service_context()
  return {
    gh = gh,
    clamp_positive = clamp_positive,
    normalize_string = normalize_string,
    resolve_repository = M.resolve_repository,
    normalize_repository_from_input = normalize_repository_from_input,
  }
end

local function code_scanning_service_context()
  return {
    gh = gh,
    clamp_positive = clamp_positive,
    normalize_string = normalize_string,
    resolve_repository = M.resolve_repository,
    normalize_repository_from_input = normalize_repository_from_input,
  }
end

local function dependency_review_service_context()
  return {
    gh = gh,
    clamp_positive = clamp_positive,
    normalize_string = normalize_string,
    resolve_repository = M.resolve_repository,
    normalize_repository_from_input = normalize_repository_from_input,
  }
end

function M.fetch_pr_change_events(number, opts)
  return pr_timeline.fetch_pr_change_events(number, opts, timeline_service_context())
end

function M.fetch_pr_change_events_async(number, opts, callback)
  return pr_timeline.fetch_pr_change_events_async(number, opts, callback, timeline_service_context())
end

function M.fetch_viewed_files(number, opts)
  return pr_viewed_files.fetch_viewed_files(number, opts, viewed_files_service_context())
end

function M.fetch_viewed_files_async(number, opts, callback)
  return pr_viewed_files.fetch_viewed_files_async(number, opts, callback, viewed_files_service_context())
end

function M.fetch_check_annotations(number, check, opts)
  return pr_check_annotations.fetch_check_annotations(number, check, opts, check_annotations_service_context())
end

function M.fetch_check_annotations_async(number, check, opts, callback)
  return pr_check_annotations.fetch_check_annotations_async(number, check, opts, callback, check_annotations_service_context())
end

function M.fetch_code_scanning_alerts(number, opts)
  return pr_code_scanning.fetch_code_scanning_alerts(number, opts, code_scanning_service_context())
end

function M.fetch_code_scanning_alerts_async(number, opts, callback)
  return pr_code_scanning.fetch_code_scanning_alerts_async(number, opts, callback, code_scanning_service_context())
end

function M.fetch_dependency_review(number, opts)
  return pr_dependency_review.fetch_dependency_review(number, opts, dependency_review_service_context())
end

function M.fetch_dependency_review_async(number, opts, callback)
  return pr_dependency_review.fetch_dependency_review_async(number, opts, callback, dependency_review_service_context())
end

function M.set_files_viewed(number, paths, viewed, opts)
  return pr_viewed_files.set_files_viewed(number, paths, viewed, opts, viewed_files_service_context())
end
local function fetch_review_context(number)
  local repository, repo_err = M.resolve_repository()
  if not repository then
    return nil, repo_err
  end

  local query = [[
query($owner:String!, $name:String!, $number:Int!) {
  repository(owner:$owner, name:$name) {
    pullRequest(number:$number) {
      id
      reviews(first:50, states:[PENDING]) {
        nodes {
          id
          state
          body
          author { login }
          comments(first:100) {
            nodes {
              id
              path
              line
              originalLine
              diffHunk
              diffSide
              body
              createdAt
              state
              outdated
              url
              author { login }
              commit { oid }
              originalCommit { oid }
              replyTo { id }
              reactionGroups {
                content
                viewerHasReacted
                users {
                  totalCount
                }
              }
              pullRequestReviewThread {
                id
                isResolved
                isOutdated
                path
                line
                originalLine
                startLine
                originalStartLine
                diffSide
              }
            }
          }
        }
      }
    }
  }
}
]]

  local response, err = run_graphql(query, {
    { flag = "-f", key = "owner", value = repository.owner },
    { flag = "-f", key = "name", value = repository.name },
    { flag = "-F", key = "number", value = tonumber(number) or number },
  })
  if not response then
    return nil, err
  end

  local data = response.data
  local repo_node = type(data) == "table" and data.repository or nil
  local pr_node = type(repo_node) == "table" and repo_node.pullRequest or nil
  if type(pr_node) ~= "table" or type(pr_node.id) ~= "string" or pr_node.id == "" then
    return nil, "Unable to resolve pull request GraphQL id"
  end

  local pending_reviews = {}
  local reviews_nodes = type(pr_node.reviews) == "table" and pr_node.reviews.nodes or {}
  for _, item in ipairs(type(reviews_nodes) == "table" and reviews_nodes or {}) do
    local comments = {}
    local comment_nodes = type(item.comments) == "table" and item.comments.nodes or {}
    for _, comment in ipairs(type(comment_nodes) == "table" and comment_nodes or {}) do
      local thread = type(comment.pullRequestReviewThread) == "table" and comment.pullRequestReviewThread or {}
      comments[#comments + 1] = {
        id = normalize_string(comment.id, ""),
        path = normalize_string(comment.path, normalize_string(thread.path, "")),
        line = tonumber(comment.line) or tonumber(thread.line) or 0,
        original_line = tonumber(comment.originalLine) or tonumber(thread.originalLine) or 0,
        start_line = tonumber(thread.startLine) or 0,
        original_start_line = tonumber(thread.originalStartLine) or 0,
        diff_hunk = normalize_string(comment.diffHunk, ""),
        diff_side = normalize_string(comment.diffSide, normalize_string(thread.diffSide, "")),
        body = normalize_string(comment.body, ""),
        created_at = normalize_string(comment.createdAt, ""),
        state = normalize_string(comment.state, "PENDING"),
        outdated = comment.outdated == true,
        url = normalize_string(comment.url, ""),
        author = normalize_login(comment.author, "unknown"),
        commit_oid = normalize_string(type(comment.commit) == "table" and comment.commit.oid or "", ""),
        original_commit_oid = normalize_string(type(comment.originalCommit) == "table" and comment.originalCommit.oid or "", ""),
        thread_id = normalize_string(thread.id, ""),
        thread_is_resolved = thread.isResolved == true,
        thread_is_outdated = thread.isOutdated == true,
        thread_path = normalize_string(thread.path, ""),
        thread_line = tonumber(thread.line) or 0,
        thread_original_line = tonumber(thread.originalLine) or 0,
        thread_start_line = tonumber(thread.startLine) or 0,
        thread_original_start_line = tonumber(thread.originalStartLine) or 0,
        thread_diff_side = normalize_string(thread.diffSide, ""),
        reply_to_id = normalize_string(type(comment.replyTo) == "table" and comment.replyTo.id or "", ""),
        reaction_groups = normalize_reaction_groups(comment.reactionGroups),
        is_pending = true,
      }
    end

    pending_reviews[#pending_reviews + 1] = {
      id = normalize_string(item.id, ""),
      state = normalize_string(item.state, ""),
      body = normalize_string(item.body, ""),
      author = normalize_login(item.author, "unknown"),
      comments = comments,
    }
  end

  return {
    repository = repository,
    pull_request_id = pr_node.id,
    pending_reviews = pending_reviews,
  }, nil
end

local function fetch_review_context_async(number, callback)
  callback = callback or function() end

  local repository, repo_err = M.resolve_repository()
  if not repository then
    callback(nil, repo_err)
    return
  end

  local query = [[
query($owner:String!, $name:String!, $number:Int!) {
  repository(owner:$owner, name:$name) {
    pullRequest(number:$number) {
      id
      reviews(first:50, states:[PENDING]) {
        nodes {
          id
          state
          body
          author { login }
          comments(first:100) {
            nodes {
              id
              path
              line
              originalLine
              diffHunk
              diffSide
              body
              createdAt
              state
              outdated
              url
              author { login }
              commit { oid }
              originalCommit { oid }
              replyTo { id }
              reactionGroups {
                content
                viewerHasReacted
                users {
                  totalCount
                }
              }
              pullRequestReviewThread {
                id
                isResolved
                isOutdated
                path
                line
                originalLine
                startLine
                originalStartLine
                diffSide
              }
            }
          }
        }
      }
    }
  }
}
]]

  run_graphql_async(query, {
    { flag = "-f", key = "owner", value = repository.owner },
    { flag = "-f", key = "name", value = repository.name },
    { flag = "-F", key = "number", value = tonumber(number) or number },
  }, function(response, err)
    if not response then
      callback(nil, err)
      return
    end

    local data = response.data
    local repo_node = type(data) == "table" and data.repository or nil
    local pr_node = type(repo_node) == "table" and repo_node.pullRequest or nil
    if type(pr_node) ~= "table" or type(pr_node.id) ~= "string" or pr_node.id == "" then
      callback(nil, "Unable to resolve pull request GraphQL id")
      return
    end

    local pending_reviews = {}
    local reviews_nodes = type(pr_node.reviews) == "table" and pr_node.reviews.nodes or {}
    for _, item in ipairs(type(reviews_nodes) == "table" and reviews_nodes or {}) do
      local comments = {}
      local comment_nodes = type(item.comments) == "table" and item.comments.nodes or {}
      for _, comment in ipairs(type(comment_nodes) == "table" and comment_nodes or {}) do
        local thread = type(comment.pullRequestReviewThread) == "table" and comment.pullRequestReviewThread or {}
        comments[#comments + 1] = {
          id = normalize_string(comment.id, ""),
          path = normalize_string(comment.path, normalize_string(thread.path, "")),
          line = tonumber(comment.line) or tonumber(thread.line) or 0,
          original_line = tonumber(comment.originalLine) or tonumber(thread.originalLine) or 0,
          start_line = tonumber(thread.startLine) or 0,
          original_start_line = tonumber(thread.originalStartLine) or 0,
          diff_hunk = normalize_string(comment.diffHunk, ""),
          diff_side = normalize_string(comment.diffSide, normalize_string(thread.diffSide, "")),
          body = normalize_string(comment.body, ""),
          created_at = normalize_string(comment.createdAt, ""),
          state = normalize_string(comment.state, "PENDING"),
          outdated = comment.outdated == true,
          url = normalize_string(comment.url, ""),
          author = normalize_login(comment.author, "unknown"),
          commit_oid = normalize_string(type(comment.commit) == "table" and comment.commit.oid or "", ""),
          original_commit_oid = normalize_string(type(comment.originalCommit) == "table" and comment.originalCommit.oid or "", ""),
          thread_id = normalize_string(thread.id, ""),
          thread_is_resolved = thread.isResolved == true,
          thread_is_outdated = thread.isOutdated == true,
          thread_path = normalize_string(thread.path, ""),
          thread_line = tonumber(thread.line) or 0,
          thread_original_line = tonumber(thread.originalLine) or 0,
          thread_start_line = tonumber(thread.startLine) or 0,
          thread_original_start_line = tonumber(thread.originalStartLine) or 0,
          thread_diff_side = normalize_string(thread.diffSide, ""),
          reply_to_id = normalize_string(type(comment.replyTo) == "table" and comment.replyTo.id or "", ""),
          reaction_groups = normalize_reaction_groups(comment.reactionGroups),
          is_pending = true,
        }
      end

      pending_reviews[#pending_reviews + 1] = {
        id = normalize_string(item.id, ""),
        state = normalize_string(item.state, ""),
        body = normalize_string(item.body, ""),
        author = normalize_login(item.author, "unknown"),
        comments = comments,
      }
    end

    callback({
      repository = repository,
      pull_request_id = pr_node.id,
      pending_reviews = pending_reviews,
    }, nil)
  end)
end

local function pending_review_for_login(context, login)
  local selected = nil
  for _, review in ipairs(type(context.pending_reviews) == "table" and context.pending_reviews or {}) do
    if normalize_string(review.author, "") == login then
      selected = review
    end
  end
  return selected
end

local function create_pending_review(pull_request_id, author_login)
  local mutation = [[
mutation($pullRequestId:ID!) {
  addPullRequestReview(input:{ pullRequestId:$pullRequestId }) {
    pullRequestReview {
      id
      state
      body
    }
  }
}
]]

  local response, err = run_graphql(mutation, {
    { flag = "-f", key = "pullRequestId", value = pull_request_id },
  })
  if not response then
    return nil, err
  end

  local data = response.data
  local mutation_node = type(data) == "table" and data.addPullRequestReview or nil
  local review = type(mutation_node) == "table" and mutation_node.pullRequestReview or nil
  if type(review) ~= "table" or type(review.id) ~= "string" or review.id == "" then
    return nil, "Unable to create pending review"
  end

  return {
    id = normalize_string(review.id, ""),
    state = normalize_string(review.state, "PENDING"),
    body = normalize_string(review.body, ""),
    author = normalize_string(author_login, "unknown"),
    created = true,
  }, nil
end

function M.find_pending_review(number)
  local context, context_err = fetch_review_context(number)
  if not context then
    return nil, context_err
  end

  local login, login_err = get_user_login()
  if not login then
    return nil, login_err
  end

  local pending = pending_review_for_login(context, login)
  if not pending then
    return nil, nil
  end

  pending.pull_request_id = context.pull_request_id
  pending.created = false
  return pending, nil
end

function M.find_pending_review_async(number, callback)
  callback = callback or function() end

  fetch_review_context_async(number, function(context, context_err)
    if not context then
      callback(nil, context_err)
      return
    end

    get_user_login_async(function(login, login_err)
      if not login then
        callback(nil, login_err)
        return
      end

      local pending = pending_review_for_login(context, login)
      if not pending then
        callback(nil, nil)
        return
      end

      pending.pull_request_id = context.pull_request_id
      pending.created = false
      callback(pending, nil)
    end)
  end)
end

function M.fetch_pending_review_comments(number)
  local pending, pending_err = M.find_pending_review(number)
  if pending_err then
    return nil, pending_err
  end

  if not pending then
    return {
      review = nil,
      comments = {},
    }, nil
  end

  return {
    review = pending,
    comments = vim.deepcopy(type(pending.comments) == "table" and pending.comments or {}),
  }, nil
end

function M.fetch_pending_review_comments_async(number, callback)
  callback = callback or function() end

  M.find_pending_review_async(number, function(pending, pending_err)
    if pending_err then
      callback(nil, pending_err)
      return
    end

    if not pending then
      callback({
        review = nil,
        comments = {},
      }, nil)
      return
    end

    callback({
      review = pending,
      comments = vim.deepcopy(type(pending.comments) == "table" and pending.comments or {}),
    }, nil)
  end)
end

function M.ensure_pending_review(number)
  local context, context_err = fetch_review_context(number)
  if not context then
    return nil, context_err
  end

  local login, login_err = get_user_login()
  if not login then
    return nil, login_err
  end

  local pending = pending_review_for_login(context, login)
  if pending then
    pending.pull_request_id = context.pull_request_id
    pending.created = false
    return pending, nil
  end

  local created, created_err = create_pending_review(context.pull_request_id, login)
  if not created then
    return nil, created_err
  end

  created.pull_request_id = context.pull_request_id
  return created, nil
end

local function merge_pending_review_comments(threads, pending_payload)
  local merged = normalize_threads(threads)
  local by_thread_id = {}
  local fallback_threads = {}

  for _, thread in ipairs(merged) do
    local thread_id = normalize_string(thread.id, "")
    if thread_id ~= "" then
      by_thread_id[thread_id] = thread
    end
  end

  local comments = type(pending_payload) == "table" and type(pending_payload.comments) == "table" and pending_payload.comments or {}
  for _, comment in ipairs(comments) do
    local path = normalize_string(comment.path, normalize_string(comment.thread_path, ""))
    local thread_id = normalize_string(comment.thread_id, "")
    local target = thread_id ~= "" and by_thread_id[thread_id] or nil

    if not target then
      local fallback_key = thread_id
      if fallback_key == "" then
        fallback_key = table.concat({
          path,
          tostring(tonumber(comment.line) or tonumber(comment.thread_line) or 0),
          tostring(tonumber(comment.original_line) or tonumber(comment.thread_original_line) or 0),
        }, ":")
      end

      target = fallback_threads[fallback_key]
      if not target then
        target = {
          id = thread_id ~= "" and thread_id or ("pending:" .. normalize_string(comment.id, fallback_key)),
          path = path,
          line = tonumber(comment.thread_line) or tonumber(comment.line) or 0,
          original_line = tonumber(comment.thread_original_line) or tonumber(comment.original_line) or 0,
          start_line = tonumber(comment.thread_start_line) or tonumber(comment.line) or 0,
          original_start_line = tonumber(comment.thread_original_start_line) or tonumber(comment.original_line) or 0,
          diff_side = normalize_string(comment.thread_diff_side, normalize_string(comment.diff_side, "")),
          is_resolved = comment.thread_is_resolved == true,
          is_outdated = comment.thread_is_outdated == true,
          comments = {},
        }
        fallback_threads[fallback_key] = target
        merged[#merged + 1] = target
        if thread_id ~= "" then
          by_thread_id[thread_id] = target
        end
      end
    end

    local exists = false
    for _, existing in ipairs(type(target.comments) == "table" and target.comments or {}) do
      if normalize_string(existing.id, "") == normalize_string(comment.id, "") then
        exists = true
        break
      end
    end

    if not exists then
      target.comments[#target.comments + 1] = {
        id = normalize_string(comment.id, ""),
        path = path,
        line = tonumber(comment.line) or 0,
        original_line = tonumber(comment.original_line) or 0,
        diff_hunk = normalize_string(comment.diff_hunk, ""),
        diff_side = normalize_string(comment.diff_side, normalize_string(comment.thread_diff_side, "")),
        commit_oid = normalize_string(comment.commit_oid, ""),
        original_commit_oid = normalize_string(comment.original_commit_oid, ""),
        author = normalize_login(comment.author, "unknown"),
        body = normalize_string(comment.body, ""),
        created_at = normalize_string(comment.created_at, ""),
        state = normalize_string(comment.state, "PENDING"),
        outdated = comment.outdated == true,
        url = normalize_string(comment.url, ""),
        reaction_groups = normalize_reaction_groups(comment.reaction_groups),
        is_pending = true,
      }
    end

    table.sort(target.comments, function(left, right)
      local left_key = normalize_string(left.created_at, "") .. ":" .. normalize_string(left.id, "")
      local right_key = normalize_string(right.created_at, "") .. ":" .. normalize_string(right.id, "")
      return left_key < right_key
    end)
  end

  return merged
end

function M.merge_pending_review_comments(threads, pending_payload)
  return merge_pending_review_comments(threads, pending_payload)
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

function M.add_pending_inline_comment(number, opts)
  opts = type(opts) == "table" and opts or {}

  local path = normalize_string(opts.path, "")
  if path == "" then
    return false, "Missing file path for inline comment"
  end

  local body = type(opts.body) == "string" and opts.body or ""
  if vim.trim(body) == "" then
    return false, "Inline comment message cannot be empty"
  end

  local line = normalize_line_number(opts.line)
  if not line then
    return false, "Missing target line for inline comment"
  end

  local start_line = normalize_line_number(opts.start_line)
  if start_line and start_line > line then
    start_line, line = line, start_line
  end
  if start_line and start_line == line then
    start_line = nil
  end

  local side = pr_threads.normalize_diff_side(opts.side, {
    normalize_string = normalize_string,
  })
  if side == "" then
    side = "RIGHT"
  end
  local start_side = pr_threads.normalize_diff_side(opts.start_side, {
    normalize_string = normalize_string,
  })
  if start_side == "" then
    start_side = side
  end

  local pending, pending_err = M.ensure_pending_review(number)
  if not pending then
    return false, pending_err
  end

  local pull_request_id = normalize_string(pending.pull_request_id, "")
  if pull_request_id == "" then
    return false, "Unable to resolve pull request id for inline comment"
  end

  local response
  local err
  if start_line then
    local mutation = [[
mutation(
  $pullRequestId:ID!,
  $path:String!,
  $body:String!,
  $startLine:Int!,
  $line:Int!,
  $startSide:DiffSide!,
  $side:DiffSide!
) {
  addPullRequestReviewThread(input:{
    pullRequestId:$pullRequestId,
    path:$path,
    body:$body,
    startLine:$startLine,
    line:$line,
    startSide:$startSide,
    side:$side
  }) {
    thread {
      id
      path
      startLine
      line
      diffSide
    }
  }
}
]]

    response, err = run_graphql(mutation, {
      { flag = "-f", key = "pullRequestId", value = pull_request_id },
      { flag = "-f", key = "path", value = path },
      { flag = "-f", key = "body", value = body },
      { flag = "-F", key = "startLine", value = start_line },
      { flag = "-F", key = "line", value = line },
      { flag = "-F", key = "startSide", value = start_side },
      { flag = "-F", key = "side", value = side },
    })
  else
    local mutation = [[
mutation($pullRequestId:ID!, $path:String!, $body:String!, $line:Int!, $side:DiffSide!) {
  addPullRequestReviewThread(input:{
    pullRequestId:$pullRequestId,
    path:$path,
    body:$body,
    line:$line,
    side:$side
  }) {
    thread {
      id
      path
      line
      diffSide
    }
  }
}
]]

    response, err = run_graphql(mutation, {
      { flag = "-f", key = "pullRequestId", value = pull_request_id },
      { flag = "-f", key = "path", value = path },
      { flag = "-f", key = "body", value = body },
      { flag = "-F", key = "line", value = line },
      { flag = "-F", key = "side", value = side },
    })
  end

  if not response then
    return false, err
  end

  local data = response.data
  local mutation_node = type(data) == "table" and data.addPullRequestReviewThread or nil
  local thread = type(mutation_node) == "table" and mutation_node.thread or nil
  if type(thread) ~= "table" or type(thread.id) ~= "string" or thread.id == "" then
    return false, "Unable to create inline review comment"
  end

  return true, nil
end

function M.add_pending_review_comment(number, body, opts)
  opts = type(opts) == "table" and opts or {}

  local message = type(body) == "string" and vim.trim(body) or ""
  if message == "" then
    return false, "Pending review comment message cannot be empty"
  end

  local pending, pending_err = M.ensure_pending_review(number)
  if not pending then
    return false, pending_err
  end

  local review_id = normalize_string(pending.id, "")
  if review_id == "" then
    return false, "Missing pending review id"
  end

  local final_body = message
  if opts.append == true then
    local current_body = normalize_string(pending.body, "")
    if current_body ~= "" then
      local separator = normalize_string(opts.separator, "\n\n---\n\n")
      final_body = current_body .. separator .. message
    end
  end

  local mutation = [[
mutation($pullRequestReviewId:ID!, $body:String!) {
  updatePullRequestReview(input:{
    pullRequestReviewId:$pullRequestReviewId,
    body:$body
  }) {
    pullRequestReview {
      id
      state
      body
    }
  }
}
]]

  local response, err = run_graphql(mutation, {
    { flag = "-f", key = "pullRequestReviewId", value = review_id },
    { flag = "-f", key = "body", value = final_body },
  })
  if not response then
    return false, err
  end

  local data = response.data
  local mutation_node = type(data) == "table" and data.updatePullRequestReview or nil
  local review = type(mutation_node) == "table" and mutation_node.pullRequestReview or nil
  if type(review) ~= "table" or type(review.id) ~= "string" or review.id == "" then
    return false, "Unable to update pending review comment"
  end

  return true, nil
end

function M.reply_to_review_thread(number, opts)
  opts = type(opts) == "table" and opts or {}

  local thread_id = normalize_string(opts.thread_id, "")
  if thread_id == "" then
    return false, "Missing review thread id"
  end

  local body = type(opts.body) == "string" and vim.trim(opts.body) or ""
  if body == "" then
    return false, "Thread reply message cannot be empty"
  end

  local pending, pending_err = M.ensure_pending_review(number)
  if not pending then
    return false, pending_err
  end

  local review_id = normalize_string(pending.id, "")
  if review_id == "" then
    return false, "Missing pending review id"
  end

  local mutation = [[
mutation($pullRequestReviewId:ID!, $pullRequestReviewThreadId:ID!, $body:String!) {
  addPullRequestReviewThreadReply(input:{
    pullRequestReviewId:$pullRequestReviewId,
    pullRequestReviewThreadId:$pullRequestReviewThreadId,
    body:$body
  }) {
    comment {
      id
      body
    }
  }
}
]]

  local response, err = run_graphql(mutation, {
    { flag = "-f", key = "pullRequestReviewId", value = review_id },
    { flag = "-f", key = "pullRequestReviewThreadId", value = thread_id },
    { flag = "-f", key = "body", value = body },
  })
  if not response then
    return false, err
  end

  local data = response.data
  local mutation_node = type(data) == "table" and data.addPullRequestReviewThreadReply or nil
  local comment = type(mutation_node) == "table" and mutation_node.comment or nil
  if type(comment) ~= "table" or type(comment.id) ~= "string" or comment.id == "" then
    return false, "Unable to add reply to review thread"
  end

  return true, nil
end

function M.update_review_comment(comment_id, body)
  comment_id = normalize_string(comment_id, "")
  local message = type(body) == "string" and vim.trim(body) or ""
  if comment_id == "" then
    return false, "Missing review comment id"
  end
  if message == "" then
    return false, "Review comment message cannot be empty"
  end

  local mutation = [[
mutation($pullRequestReviewCommentId:ID!, $body:String!) {
  updatePullRequestReviewComment(input:{
    pullRequestReviewCommentId:$pullRequestReviewCommentId,
    body:$body
  }) {
    pullRequestReviewComment {
      id
      body
    }
  }
}
]]

  local response, err = run_graphql(mutation, {
    { flag = "-f", key = "pullRequestReviewCommentId", value = comment_id },
    { flag = "-f", key = "body", value = message },
  })
  if not response then
    return false, err
  end

  local data = response.data
  local mutation_node = type(data) == "table" and data.updatePullRequestReviewComment or nil
  local comment = type(mutation_node) == "table" and mutation_node.pullRequestReviewComment or nil
  if type(comment) ~= "table" or normalize_string(comment.id, "") == "" then
    return false, "Unable to update review comment"
  end

  return true, nil
end

function M.delete_review_comment(comment_id)
  comment_id = normalize_string(comment_id, "")
  if comment_id == "" then
    return false, "Missing review comment id"
  end

  local mutation = [[
mutation($pullRequestReviewCommentId:ID!) {
  deletePullRequestReviewComment(input:{
    pullRequestReviewCommentId:$pullRequestReviewCommentId
  }) {
    pullRequestReviewComment {
      id
    }
  }
}
]]

  local response, err = run_graphql(mutation, {
    { flag = "-f", key = "pullRequestReviewCommentId", value = comment_id },
  })
  if not response then
    return false, err
  end

  local data = response.data
  local mutation_node = type(data) == "table" and data.deletePullRequestReviewComment or nil
  local comment = type(mutation_node) == "table" and mutation_node.pullRequestReviewComment or nil
  if type(comment) ~= "table" or normalize_string(comment.id, "") == "" then
    return false, "Unable to delete review comment"
  end

  return true, nil
end

function M.set_review_comment_reaction(comment_id, content, enabled)
  comment_id = normalize_string(comment_id, "")
  content = normalize_string(content, ""):upper()
  if comment_id == "" then
    return false, "Missing review comment id"
  end
  if content == "" then
    return false, "Missing reaction content"
  end

  local mutation_name = enabled == false and "removeReaction" or "addReaction"
  local mutation = string.format([[
mutation($subjectId:ID!, $content:ReactionContent!) {
  %s(input:{
    subjectId:$subjectId,
    content:$content
  }) {
    subject {
      id
    }
  }
}
]], mutation_name)

  local response, err = run_graphql(mutation, {
    { flag = "-f", key = "subjectId", value = comment_id },
    { flag = "-F", key = "content", value = content },
  })
  if not response then
    return false, err
  end

  local data = response.data
  local mutation_node = type(data) == "table" and data[mutation_name] or nil
  local subject = type(mutation_node) == "table" and mutation_node.subject or nil
  if type(subject) ~= "table" or normalize_string(subject.id, "") == "" then
    return false, enabled == false and "Unable to remove reaction" or "Unable to add reaction"
  end

  return true, nil
end

local function mutate_review_thread_resolution(thread_id, resolved)
  thread_id = normalize_string(thread_id, "")
  if thread_id == "" then
    return false, "Missing review thread id"
  end

  local mutation_name = resolved == true and "resolveReviewThread" or "unresolveReviewThread"
  local mutation = string.format([[
mutation($threadId:ID!) {
  %s(input:{ threadId:$threadId }) {
    thread {
      id
      isResolved
    }
  }
}
]], mutation_name)

  local response, err = run_graphql(mutation, {
    { flag = "-f", key = "threadId", value = thread_id },
  })
  if not response then
    return false, err
  end

  local data = response.data
  local mutation_node = type(data) == "table" and data[mutation_name] or nil
  local thread = type(mutation_node) == "table" and mutation_node.thread or nil
  if type(thread) ~= "table" or type(thread.id) ~= "string" or thread.id == "" then
    return false, resolved == true
        and "Unable to resolve review thread"
      or "Unable to unresolve review thread"
  end

  return true, nil
end

function M.resolve_review_thread(thread_id)
  return mutate_review_thread_resolution(thread_id, true)
end

function M.unresolve_review_thread(thread_id)
  return mutate_review_thread_resolution(thread_id, false)
end

local function normalize_pending_event(event)
  local normalized = normalize_string(event, ""):lower()
  if normalized == "comment" then
    return "COMMENT", nil
  end
  if normalized == "approve" then
    return "APPROVE", nil
  end
  if normalized == "request_changes" then
    return "REQUEST_CHANGES", nil
  end
  return nil, "Unsupported pending review event"
end

function M.submit_pending_review(number, event, body)
  local pending, pending_err = M.ensure_pending_review(number)
  if not pending then
    return false, pending_err
  end

  local review_id = normalize_string(pending.id, "")
  if review_id == "" then
    return false, "Missing pending review id"
  end

  local event_enum, event_err = normalize_pending_event(event)
  if not event_enum then
    return false, event_err
  end

  local response
  local err
  local text = type(body) == "string" and body or ""
  if text ~= "" then
    local mutation = [[
mutation($pullRequestReviewId:ID!, $event:PullRequestReviewEvent!, $body:String!) {
  submitPullRequestReview(input:{
    pullRequestReviewId:$pullRequestReviewId,
    event:$event,
    body:$body
  }) {
    pullRequestReview {
      id
      state
      submittedAt
    }
  }
}
]]

    response, err = run_graphql(mutation, {
      { flag = "-f", key = "pullRequestReviewId", value = review_id },
      { flag = "-F", key = "event", value = event_enum },
      { flag = "-f", key = "body", value = text },
    })
  else
    local mutation = [[
mutation($pullRequestReviewId:ID!, $event:PullRequestReviewEvent!) {
  submitPullRequestReview(input:{
    pullRequestReviewId:$pullRequestReviewId,
    event:$event
  }) {
    pullRequestReview {
      id
      state
      submittedAt
    }
  }
}
]]

    response, err = run_graphql(mutation, {
      { flag = "-f", key = "pullRequestReviewId", value = review_id },
      { flag = "-F", key = "event", value = event_enum },
    })
  end

  if not response then
    return false, err
  end

  return true, nil
end

function M.discard_pending_review(number)
  local pending, pending_err = M.find_pending_review(number)
  if pending_err then
    return false, pending_err
  end
  if not pending then
    return false, "No pending review found for current user"
  end

  local review_id = normalize_string(pending.id, "")
  if review_id == "" then
    return false, "Missing pending review id"
  end

  local mutation = [[
mutation($pullRequestReviewId:ID!) {
  deletePullRequestReview(input:{ pullRequestReviewId:$pullRequestReviewId }) {
    clientMutationId
  }
}
]]

  local response, err = run_graphql(mutation, {
    { flag = "-f", key = "pullRequestReviewId", value = review_id },
  })
  if not response then
    return false, err
  end

  return true, nil
end

function M.merge(number, method, delete_branch)
  local args = { "pr", "merge", tostring(number) }

  if method == "squash" then
    table.insert(args, "--squash")
  elseif method == "rebase" then
    table.insert(args, "--rebase")
  else
    table.insert(args, "--merge")
  end

  if delete_branch then
    table.insert(args, "--delete-branch")
  end

  local _, err = gh.run(args)
  if err then
    return false, err
  end

  return true, nil
end

function M.fetch_pr_files_api(number)
  local repository, repo_err = M.resolve_repository()
  if not repository then
    return nil, repo_err
  end

  local endpoint = string.format("repos/%s/pulls/%d/files?per_page=100", repository.full_name, number)
  local files, err = gh.run_json({ "api", endpoint })
  if not files then
    return nil, err
  end

  return files, nil
end

function M.fetch_pr_files_api_async(number, callback)
  callback = callback or function() end

  local repository, repo_err = M.resolve_repository()
  if not repository then
    callback(nil, repo_err)
    return
  end

  local endpoint = string.format("repos/%s/pulls/%d/files?per_page=100", repository.full_name, number)
  gh.run_json_async({ "api", endpoint }, nil, function(files, err)
    if not files then
      callback(nil, err)
      return
    end

    callback(files, nil)
  end)
end

local function append_page_params(endpoint, page, per_page)
  local separator = endpoint:find("?", 1, true) and "&" or "?"
  return string.format("%s%sper_page=%d&page=%d", endpoint, separator, per_page, page)
end

local function fetch_paginated_endpoint(endpoint, opts)
  opts = type(opts) == "table" and opts or {}
  local per_page = clamp_positive(opts.per_page, 100, 100)
  local max_pages = clamp_positive(opts.max_pages, 20, 100)

  local rows = {}
  for page = 1, max_pages do
    local page_endpoint = append_page_params(endpoint, page, per_page)
    local payload, err = gh.run_json({ "api", page_endpoint })
    if not payload then
      return nil, err
    end

    if type(payload) ~= "table" then
      return nil, "Unexpected GitHub API response format"
    end

    local count = 0
    for _, item in ipairs(payload) do
      rows[#rows + 1] = item
      count = count + 1
    end

    if count < per_page then
      break
    end
  end

  return rows, nil
end

local function resolve_repository_from_opts(opts)
  opts = type(opts) == "table" and opts or {}
  local repository = normalize_repository_filter(opts.repository)
  if repository then
    return repository, nil
  end
  return M.resolve_repository()
end

function M.fetch_repo_labels(opts)
  local repository, repo_err = resolve_repository_from_opts(opts)
  if not repository then
    return nil, repo_err
  end

  local endpoint = string.format("repos/%s/labels", repository.full_name)
  local items, err = fetch_paginated_endpoint(endpoint, opts)
  if not items then
    return nil, err
  end

  local labels = {}
  local seen = {}
  for _, item in ipairs(items) do
    local name = normalize_string(item.name, "")
    local key = normalize_string(name, ""):lower()
    if name ~= "" and key ~= "" and not seen[key] then
      seen[key] = true
      labels[#labels + 1] = {
        name = name,
        color = normalize_string(item.color, ""),
        description = normalize_string(item.description, ""),
      }
    end
  end

  table.sort(labels, function(left, right)
    return normalize_string(left.name, ""):lower() < normalize_string(right.name, ""):lower()
  end)

  return labels, nil
end

function M.fetch_reviewer_candidates(opts)
  local repository, repo_err = resolve_repository_from_opts(opts)
  if not repository then
    return nil, repo_err
  end

  local users_endpoint = string.format("repos/%s/collaborators", repository.full_name)
  local users_payload, users_err = fetch_paginated_endpoint(users_endpoint, opts)
  if not users_payload then
    return nil, users_err
  end

  local users = {}
  for _, item in ipairs(users_payload) do
    local login = normalize_string(item.login, "")
    if login ~= "" then
      users[#users + 1] = {
        kind = "user",
        value = login,
        display = "@" .. login,
      }
    end
  end

  table.sort(users, function(left, right)
    return left.value:lower() < right.value:lower()
  end)

  local teams = {}
  local warnings = {}
  local teams_endpoint = string.format("repos/%s/teams", repository.full_name)
  local teams_payload, teams_err = fetch_paginated_endpoint(teams_endpoint, opts)
  if teams_payload then
    for _, item in ipairs(teams_payload) do
      local slug = normalize_string(item.slug, "")
      local org = type(item.organization) == "table" and normalize_string(item.organization.login, "") or repository.owner
      if slug ~= "" and org ~= "" then
        local value = org .. "/" .. slug
        teams[#teams + 1] = {
          kind = "team",
          value = value,
          display = "@" .. value,
        }
      end
    end

    table.sort(teams, function(left, right)
      return left.value:lower() < right.value:lower()
    end)
  elseif type(teams_err) == "string" and teams_err ~= "" then
    warnings[#warnings + 1] = "Unable to load teams for reviewers: " .. teams_err
  end

  local merged = {}
  local seen = {}
  local function append_candidates(items)
    for _, item in ipairs(items) do
      local key = normalize_string(item.value, ""):lower()
      if key ~= "" and not seen[key] then
        seen[key] = true
        merged[#merged + 1] = item
      end
    end
  end
  append_candidates(users)
  append_candidates(teams)

  return {
    repository = repository.full_name,
    users = users,
    teams = teams,
    merged = merged,
    warnings = warnings,
  }, nil
end

function M.fetch_patch_for_file(number, path)
  if type(path) ~= "string" or path == "" then
    return nil, "Invalid file path for patch fallback"
  end

  local files, err = M.fetch_pr_files_api(number)
  if not files then
    return nil, err
  end

  for _, item in ipairs(files) do
    if item.filename == path or item.previous_filename == path then
      if type(item.patch) == "string" and item.patch ~= "" then
        return item.patch, nil
      end
      return nil, "No textual patch available for this file"
    end
  end

  return nil, "File patch not found in pull request"
end

function M.notify_failure(err)
  notify_error(err)
end

return M
