local M = {}

function M.build(details, threads, limits, opts, ctx)
  opts = opts or {}
  details = type(details) == "table" and details or {}
  limits = type(limits) == "table" and limits or {}

  local normalized_labels = ctx.normalize_labels(details.labels)
  local normalized_assignees = ctx.normalize_assignees(details.assignees)
  local normalized_review_requests = ctx.normalize_review_requests(details.reviewRequests)
  local normalized_checks = ctx.normalize_checks(details.statusCheckRollup)
  local normalized_commits = ctx.normalize_commits(details.commits)
  local normalized_comments = ctx.normalize_comments(details.comments)
  local normalized_reviews = ctx.normalize_reviews(details.reviews)
  local normalized_threads = ctx.normalize_threads(threads)
  local normalized_pr_changes = ctx.normalize_pr_change_events(opts.pr_change_events)
  local normalized_files = ctx.normalize_files(details.files)

  local checks_limit = ctx.clamp_positive(limits.checks, 10)
  local commits_limit = ctx.clamp_positive(limits.commits, 10)
  local timeline_limit = ctx.clamp_positive(
    limits.timeline,
    math.max(ctx.clamp_positive(limits.comments, 20), ctx.clamp_positive(limits.reviews, 20), ctx.clamp_positive(limits.threads, 20))
  )
  local comments_limit = ctx.clamp_positive(limits.comments, timeline_limit)
  local reviews_limit = ctx.clamp_positive(limits.reviews, timeline_limit)
  local threads_limit = ctx.clamp_positive(limits.threads, timeline_limit)
  local normalized_limits = vim.deepcopy(limits)
  normalized_limits.checks = checks_limit
  normalized_limits.commits = commits_limit
  normalized_limits.timeline = math.max(timeline_limit, comments_limit, reviews_limit, threads_limit)
  normalized_limits.comments = comments_limit
  normalized_limits.reviews = reviews_limit
  normalized_limits.threads = threads_limit

  local checks_limited, checks_total = ctx.take_recent(normalized_checks, checks_limit)
  local commits_limited, commits_total = ctx.take_recent(normalized_commits, commits_limit)
  local comments_limited, comments_total = ctx.take_recent(normalized_comments, comments_limit)
  local reviews_limited, reviews_total = ctx.take_recent(normalized_reviews, reviews_limit)
  local threads_limited, threads_total = ctx.take_recent(normalized_threads, threads_limit)
  local pr_changes_limited, pr_changes_total = ctx.take_recent(normalized_pr_changes, normalized_limits.timeline)
  local timeline_all = ctx.build_timeline_items(
    normalized_comments,
    normalized_reviews,
    normalized_threads,
    normalized_commits,
    normalized_pr_changes
  )
  local timeline_limited, timeline_total = ctx.take_recent(timeline_all, normalized_limits.timeline)

  local author = ctx.normalize_login(details.author, "unknown")
  local milestone_title = ""
  if type(details.milestone) == "table" then
    milestone_title = ctx.normalize_string(details.milestone.title, "")
  end

  return {
    number = tonumber(details.number) or 0,
    title = ctx.normalize_string(details.title, ""),
    url = ctx.normalize_string(details.url, ""),
    repository = ctx.normalize_string(opts.repository, ""),
    description = ctx.normalize_string(details.body, ""),
    thread_error = ctx.normalize_string(opts.thread_error, ""),
    pr_change_error = ctx.normalize_string(opts.pr_change_error, ""),
    limits = normalized_limits,
    summary = {
      state = ctx.normalize_string(details.state, "UNKNOWN"),
      is_draft = details.isDraft == true,
      author = author,
      review_decision = ctx.normalize_string(details.reviewDecision, "REVIEW_REQUIRED"),
      merge_state = ctx.normalize_string(details.mergeStateStatus, ""),
      mergeable = ctx.normalize_string(details.mergeable, ""),
      maintainer_can_modify = details.maintainerCanModify == true,
      head_ref = ctx.normalize_string(details.headRefName, "?"),
      base_ref = ctx.normalize_string(details.baseRefName, "?"),
      created_at = ctx.normalize_string(details.createdAt, ""),
      updated_at = ctx.normalize_string(details.updatedAt, ""),
      merged_at = ctx.normalize_string(details.mergedAt, ""),
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
    pr_changes = {
      items = pr_changes_limited,
      total = pr_changes_total,
    },
    files = {
      items = normalized_files,
      total = #normalized_files,
    },
  }
end

return M
