local M = {}

local config = require("gh-pr.config")
local gh = require("gh-pr.gh")
local repo = require("gh-pr.repo")

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

local function append_repo_filter(query, repository)
  if query:find("repo:", 1, true) then
    return query
  end

  return string.format("%s repo:%s", query, repository.full_name)
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

  query = query:gsub("%${user}", user)
  query = query:gsub("%${owner}", repository.owner)
  query = query:gsub("%${repository}", repository.name)
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

    local query = raw_query
    query = query:gsub("%${user}", user)
    query = query:gsub("%${owner}", repository.owner)
    query = query:gsub("%${repository}", repository.name)
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
        author = normalize_login(comment.author, "unknown"),
        body = normalize_string(comment.body, ""),
        created_at = normalize_string(comment.createdAt, ""),
        state = normalize_string(comment.state, ""),
        outdated = comment.outdated == true,
        url = normalize_string(comment.url, ""),
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
  for _, file in ipairs(type(files) == "table" and files or {}) do
    local path = normalize_string(file.path, normalize_string(file.filename, ""))
    if path ~= "" then
      normalized[#normalized + 1] = {
        path = path,
        filename = normalize_string(file.filename, path),
        previous_filename = normalize_string(file.previousFilename, normalize_string(file.previous_filename, "")),
        status = normalize_string(file.status, ""),
        additions = tonumber(file.additions) or 0,
        deletions = tonumber(file.deletions) or 0,
        patch = normalize_string(file.patch, ""),
      }
    end
  end
  return normalized
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

  return prs, nil
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
      callback(prs, nil)
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

  return enrich_details_with_repositories(details), nil
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

    callback(enrich_details_with_repositories(details), nil)
  end)
end

function M.fetch_review_threads(number, opts)
  opts = opts or {}

  local repository, repo_err = M.resolve_repository()
  if not repository then
    return nil, repo_err
  end

  local threads_first = clamp_positive(opts.threads_first, 50, 100)
  local comments_first = clamp_positive(opts.comments_first, 50, 100)

  local query = [[
query($owner:String!, $name:String!, $number:Int!, $threadsFirst:Int!, $commentsFirst:Int!) {
  repository(owner:$owner, name:$name) {
    pullRequest(number:$number) {
      reviewThreads(first:$threadsFirst) {
        nodes {
          id
          isResolved
          isOutdated
          path
          line
          originalLine
          startLine
          originalStartLine
          diffSide
          comments(first:$commentsFirst) {
            nodes {
              id
              path
              line
              originalLine
              diffHunk
              author { login }
              body
              createdAt
              state
              outdated
              url
            }
          }
        }
      }
    }
  }
}
]]

  local response, err = gh.run_json({
    "api",
    "graphql",
    "-f",
    "query=" .. query,
    "-F",
    "owner=" .. repository.owner,
    "-F",
    "name=" .. repository.name,
    "-F",
    "number=" .. tostring(number),
    "-F",
    "threadsFirst=" .. tostring(threads_first),
    "-F",
    "commentsFirst=" .. tostring(comments_first),
  })

  if not response then
    return nil, err
  end

  if type(response.errors) == "table" and #response.errors > 0 then
    local first_error = response.errors[1]
    if type(first_error) == "table" and type(first_error.message) == "string" and first_error.message ~= "" then
      return nil, first_error.message
    end
    return nil, "GraphQL error while loading review threads"
  end

  local data = response.data
  local repo_node = type(data) == "table" and data.repository or nil
  local pr = type(repo_node) == "table" and repo_node.pullRequest or nil
  local review_threads = type(pr) == "table" and pr.reviewThreads or nil
  local nodes = type(review_threads) == "table" and review_threads.nodes or {}

  local threads = {}
  for _, node in ipairs(type(nodes) == "table" and nodes or {}) do
    local comments = {}
    local comments_nodes = type(node.comments) == "table" and node.comments.nodes or {}
    for _, comment in ipairs(type(comments_nodes) == "table" and comments_nodes or {}) do
      comments[#comments + 1] = comment
    end

    threads[#threads + 1] = {
      id = node.id,
      isResolved = node.isResolved,
      isOutdated = node.isOutdated,
      path = node.path,
      line = node.line,
      originalLine = node.originalLine,
      startLine = node.startLine,
      originalStartLine = node.originalStartLine,
      diffSide = node.diffSide,
      comments = comments,
    }
  end

  return threads, nil
end

local function normalize_diff_side(value)
  local side = normalize_string(value, ""):upper()
  if side == "LEFT" or side == "RIGHT" then
    return side
  end
  return ""
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

local function ensure_line_bucket(index, path)
  if type(path) ~= "string" or path == "" then
    return nil
  end

  index[path] = index[path] or {
    head = {},
    base = {},
  }

  return index[path]
end

local function add_line_item(index, path, side, line, item)
  if side ~= "head" and side ~= "base" then
    return
  end

  if type(line) ~= "number" or line < 1 then
    return
  end

  local bucket = ensure_line_bucket(index, path)
  if not bucket then
    return
  end

  bucket[side][line] = bucket[side][line] or {}
  bucket[side][line][#bucket[side][line] + 1] = item
end

local function sort_line_index(index)
  for _, sides in pairs(index) do
    for _, side in ipairs({ "head", "base" }) do
      local line_map = sides[side] or {}
      for _, entries in pairs(line_map) do
        table.sort(entries, function(left, right)
          local left_key = normalize_string(left.created_at, "") .. ":" .. normalize_string(left.comment_id, "")
          local right_key = normalize_string(right.created_at, "") .. ":" .. normalize_string(right.comment_id, "")
          return left_key < right_key
        end)
      end
    end
  end
end

function M.build_line_comment_index(threads, opts)
  opts = opts or {}

  local show_resolved = opts.show_resolved ~= false
  local show_outdated = opts.show_outdated ~= false
  local normalized_threads = normalize_threads(threads)
  local index = {}

  for _, thread in ipairs(normalized_threads) do
    if thread.is_resolved and not show_resolved then
      goto continue
    end

    if thread.is_outdated and not show_outdated then
      goto continue
    end

    local thread_path = normalize_string(thread.path, "")
    local thread_side = normalize_diff_side(thread.diff_side)

    for _, comment in ipairs(thread.comments or {}) do
      local path = normalize_string(comment.path, thread_path)
      local comment_side = normalize_diff_side(comment.diff_side)
      local side_hint = comment_side ~= "" and comment_side or thread_side

      local head_line = first_positive_line(comment.line, thread.line, thread.start_line)
      local base_line = first_positive_line(comment.original_line, thread.original_line, thread.original_start_line)

      if side_hint == "RIGHT" and not head_line then
        head_line = first_positive_line(thread.line, thread.start_line)
      elseif side_hint == "LEFT" and not base_line then
        base_line = first_positive_line(thread.original_line, thread.original_start_line)
      end

      local entry = {
        thread_id = thread.id,
        comment_id = comment.id,
        path = path,
        author = comment.author,
        body = comment.body,
        created_at = comment.created_at,
        state = comment.state,
        url = comment.url,
        is_resolved = thread.is_resolved == true,
        is_outdated = thread.is_outdated == true,
        diff_side = side_hint,
        line = head_line,
        original_line = base_line,
      }

      add_line_item(index, path, "head", head_line, entry)
      add_line_item(index, path, "base", base_line, entry)
    end

    ::continue::
  end

  sort_line_index(index)
  return index
end

local function timeline_sort_key(item)
  return normalize_string(item.created_at, "") .. ":" .. normalize_string(item.id, "")
end

local function timeline_thread_target(thread, comment)
  local path = normalize_string(comment.path, normalize_string(thread.path, ""))
  if path == "" then
    return nil
  end

  local side_hint = normalize_diff_side(comment.diff_side)
  if side_hint == "" then
    side_hint = normalize_diff_side(thread.diff_side)
  end

  local head_line = first_positive_line(comment.line, thread.line, thread.start_line)
  local base_line = first_positive_line(comment.original_line, thread.original_line, thread.original_start_line)

  if side_hint == "RIGHT" and not head_line then
    head_line = first_positive_line(thread.line, thread.start_line)
  elseif side_hint == "LEFT" and not base_line then
    base_line = first_positive_line(thread.original_line, thread.original_start_line)
  end

  if not head_line and not base_line then
    return nil
  end

  if not head_line then
    head_line = base_line
  end
  if not base_line then
    base_line = head_line
  end

  return {
    path = path,
    side = side_hint == "LEFT" and "base" or "head",
    line = head_line,
    original_line = base_line,
  }
end

local function build_timeline_items(comments, reviews, threads)
  local items = {}

  for _, comment in ipairs(type(comments) == "table" and comments or {}) do
    items[#items + 1] = {
      id = "comment:" .. normalize_string(comment.id, ""),
      kind = "comment",
      author = normalize_string(comment.author, "unknown"),
      association = normalize_string(comment.association, ""),
      body = normalize_string(comment.body, ""),
      created_at = normalize_string(comment.created_at, ""),
      url = normalize_string(comment.url, ""),
    }
  end

  for _, review in ipairs(type(reviews) == "table" and reviews or {}) do
    items[#items + 1] = {
      id = "review:" .. normalize_string(review.id, ""),
      kind = "review",
      author = normalize_string(review.author, "unknown"),
      association = normalize_string(review.association, ""),
      state = normalize_string(review.state, "COMMENTED"),
      body = normalize_string(review.body, ""),
      created_at = normalize_string(review.submitted_at, ""),
      url = normalize_string(review.url, ""),
      commit_oid = normalize_string(review.commit_oid, ""),
    }
  end

  for _, thread in ipairs(type(threads) == "table" and threads or {}) do
    for _, comment in ipairs(type(thread.comments) == "table" and thread.comments or {}) do
      local target = timeline_thread_target(thread, comment)
      items[#items + 1] = {
        id = "thread:" .. normalize_string(thread.id, "") .. ":" .. normalize_string(comment.id, ""),
        kind = "thread_comment",
        author = normalize_string(comment.author, "unknown"),
        body = normalize_string(comment.body, ""),
        state = normalize_string(comment.state, ""),
        created_at = normalize_string(comment.created_at, ""),
        url = normalize_string(comment.url, ""),
        path = target and target.path or normalize_string(comment.path, normalize_string(thread.path, "")),
        line = target and target.line or first_positive_line(comment.line, thread.line, thread.start_line),
        original_line = target and target.original_line
          or first_positive_line(comment.original_line, thread.original_line, thread.original_start_line),
        side = target and target.side or "head",
        target = target,
        thread_id = normalize_string(thread.id, ""),
        is_resolved = thread.is_resolved == true,
        is_outdated = thread.is_outdated == true,
      }
    end
  end

  table.sort(items, function(left, right)
    return timeline_sort_key(left) < timeline_sort_key(right)
  end)
  return items
end

function M.build_overview_model(details, threads, limits, opts)
  opts = opts or {}
  details = type(details) == "table" and details or {}
  limits = type(limits) == "table" and limits or {}

  local normalized_labels = normalize_labels(details.labels)
  local normalized_assignees = normalize_assignees(details.assignees)
  local normalized_review_requests = normalize_review_requests(details.reviewRequests)
  local normalized_checks = normalize_checks(details.statusCheckRollup)
  local normalized_commits = normalize_commits(details.commits)
  local normalized_comments = normalize_comments(details.comments)
  local normalized_reviews = normalize_reviews(details.reviews)
  local normalized_threads = normalize_threads(threads)
  local normalized_files = normalize_files(details.files)

  local checks_limit = clamp_positive(limits.checks, 10)
  local commits_limit = clamp_positive(limits.commits, 10)
  local timeline_limit = clamp_positive(
    limits.timeline,
    math.max(clamp_positive(limits.comments, 20), clamp_positive(limits.reviews, 20), clamp_positive(limits.threads, 20))
  )
  local comments_limit = clamp_positive(limits.comments, timeline_limit)
  local reviews_limit = clamp_positive(limits.reviews, timeline_limit)
  local threads_limit = clamp_positive(limits.threads, timeline_limit)
  local normalized_limits = vim.deepcopy(limits)
  normalized_limits.checks = checks_limit
  normalized_limits.commits = commits_limit
  normalized_limits.timeline = math.max(timeline_limit, comments_limit, reviews_limit, threads_limit)
  normalized_limits.comments = comments_limit
  normalized_limits.reviews = reviews_limit
  normalized_limits.threads = threads_limit

  local checks_limited, checks_total = take_recent(normalized_checks, checks_limit)
  local commits_limited, commits_total = take_recent(normalized_commits, commits_limit)
  local comments_limited, comments_total = take_recent(normalized_comments, comments_limit)
  local reviews_limited, reviews_total = take_recent(normalized_reviews, reviews_limit)
  local threads_limited, threads_total = take_recent(normalized_threads, threads_limit)
  local timeline_all = build_timeline_items(normalized_comments, normalized_reviews, normalized_threads)
  local timeline_limited, timeline_total = take_recent(timeline_all, normalized_limits.timeline)

  local author = normalize_login(details.author, "unknown")
  local milestone_title = ""
  if type(details.milestone) == "table" then
    milestone_title = normalize_string(details.milestone.title, "")
  end

  return {
    number = tonumber(details.number) or 0,
    title = normalize_string(details.title, ""),
    url = normalize_string(details.url, ""),
    repository = normalize_string(opts.repository, ""),
    description = normalize_string(details.body, ""),
    thread_error = normalize_string(opts.thread_error, ""),
    limits = normalized_limits,
    summary = {
      state = normalize_string(details.state, "UNKNOWN"),
      is_draft = details.isDraft == true,
      author = author,
      review_decision = normalize_string(details.reviewDecision, "REVIEW_REQUIRED"),
      merge_state = normalize_string(details.mergeStateStatus, ""),
      mergeable = normalize_string(details.mergeable, ""),
      maintainer_can_modify = details.maintainerCanModify == true,
      head_ref = normalize_string(details.headRefName, "?"),
      base_ref = normalize_string(details.baseRefName, "?"),
      created_at = normalize_string(details.createdAt, ""),
      updated_at = normalize_string(details.updatedAt, ""),
      merged_at = normalize_string(details.mergedAt, ""),
      milestone = milestone_title,
      files_changed = tonumber(details.changedFiles) or (type(details.files) == "table" and #details.files or 0),
      additions = tonumber(details.additions) or 0,
      deletions = tonumber(details.deletions) or 0,
    },
    people = {
      assignees = normalized_assignees,
      review_requests = normalized_review_requests,
    },
    labels = {
      items = normalized_labels,
      total = #normalized_labels,
    },
    checks = {
      items = checks_limited,
      total = checks_total,
    },
    commits = {
      items = commits_limited,
      total = commits_total,
    },
    timeline = {
      items = timeline_limited,
      total = timeline_total,
    },
    comments = {
      items = comments_limited,
      total = comments_total,
    },
    reviews = {
      items = reviews_limited,
      total = reviews_total,
    },
    threads = {
      items = threads_limited,
      total = threads_total,
    },
    files = {
      items = normalized_files,
      total = #normalized_files,
    },
  }
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

  local endpoint = string.format("repos/%s/pulls/%d/files", repository.full_name, number)
  local files, err = gh.run_json({ "api", endpoint })
  if not files then
    return nil, err
  end

  return files, nil
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
