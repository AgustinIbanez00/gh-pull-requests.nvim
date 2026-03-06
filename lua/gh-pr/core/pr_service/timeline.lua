local M = {}

local function timeline_sort_key(item, ctx)
  return ctx.normalize_string(item.created_at, "") .. ":" .. ctx.normalize_string(item.id, "")
end

local function timeline_thread_target(thread, comment, ctx)
  local path = ctx.normalize_string(comment.path, ctx.normalize_string(thread.path, ""))
  if path == "" then
    return nil
  end

  local side_hint = ctx.normalize_diff_side(comment.diff_side)
  if side_hint == "" then
    side_hint = ctx.normalize_diff_side(thread.diff_side)
  end

  local head_line = ctx.first_positive_line(comment.line, thread.line, thread.start_line)
  local base_line = ctx.first_positive_line(comment.original_line, thread.original_line, thread.original_start_line)

  if side_hint == "RIGHT" and not head_line then
    head_line = ctx.first_positive_line(thread.line, thread.start_line)
  elseif side_hint == "LEFT" and not base_line then
    base_line = ctx.first_positive_line(thread.original_line, thread.original_start_line)
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

local function build_commit_timeline_item(commit, ctx)
  local oid = ctx.normalize_string(type(commit) == "table" and commit.oid, "")
  local oid_short = ctx.normalize_string(type(commit) == "table" and commit.oid_short, "")
  if oid_short == "" and oid ~= "" then
    oid_short = oid:sub(1, 8)
  end
  local headline = ctx.normalize_string(type(commit) == "table" and commit.headline, "(no commit headline)")
  local body = ctx.normalize_string(type(commit) == "table" and commit.body, "")
  local commit_id = oid
  if commit_id == "" then
    commit_id = ctx.normalize_string(type(commit) == "table" and commit.committed_at, "") .. ":" .. headline
  end
  if body == "" then
    body = headline
  else
    body = headline .. "\n" .. body
  end

  return {
    id = "commit:" .. commit_id,
    kind = "commit",
    author = ctx.normalize_string(type(commit) == "table" and commit.author, "unknown"),
    body = body,
    headline = headline,
    created_at = ctx.normalize_string(type(commit) == "table" and commit.committed_at, ""),
    url = ctx.normalize_string(type(commit) == "table" and commit.url, ""),
    oid = oid,
    oid_short = oid_short,
    commit = {
      oid = oid,
      oid_short = oid_short,
      headline = headline,
      body = ctx.normalize_string(type(commit) == "table" and commit.body, ""),
      author = ctx.normalize_string(type(commit) == "table" and commit.author, "unknown"),
      committed_at = ctx.normalize_string(type(commit) == "table" and commit.committed_at, ""),
      url = ctx.normalize_string(type(commit) == "table" and commit.url, ""),
    },
  }
end

function M.normalize_pr_change_events(events, ctx)
  local normalized = {}
  for _, event in ipairs(type(events) == "table" and events or {}) do
    local change_summary = ctx.normalize_string(event.change_summary, "")
    local change_details = ctx.normalize_string(event.change_details, "")
    local change_label_color = ctx.normalize_string(event.change_label_color, "")
    local body = ctx.normalize_string(event.body, "")
    if body == "" then
      if change_summary ~= "" and change_details ~= "" then
        body = change_summary .. "\n" .. change_details
      elseif change_summary ~= "" then
        body = change_summary
      else
        body = "(pull request updated)"
      end
    end

    normalized[#normalized + 1] = {
      id = ctx.normalize_string(event.id, ctx.normalize_string(event.created_at, "") .. ":" .. change_summary),
      kind = "pr_change",
      change_type = ctx.normalize_string(event.change_type, "updated"),
      change_summary = change_summary ~= "" and change_summary or "(pull request updated)",
      change_details = change_details,
      change_label_color = change_label_color,
      author = ctx.normalize_string(event.author, "unknown"),
      body = body,
      created_at = ctx.normalize_string(event.created_at, ""),
      url = ctx.normalize_string(event.url, ""),
      source = ctx.normalize_string(event.source, "graphql"),
    }
  end
  return normalized
end

function M.build_timeline_items(comments, reviews, threads, commits, pr_change_events, ctx)
  local items = {}

  for _, comment in ipairs(type(comments) == "table" and comments or {}) do
    items[#items + 1] = {
      id = "comment:" .. ctx.normalize_string(comment.id, ""),
      kind = "comment",
      author = ctx.normalize_string(comment.author, "unknown"),
      association = ctx.normalize_string(comment.association, ""),
      body = ctx.normalize_string(comment.body, ""),
      created_at = ctx.normalize_string(comment.created_at, ""),
      url = ctx.normalize_string(comment.url, ""),
    }
  end

  for _, review in ipairs(type(reviews) == "table" and reviews or {}) do
    items[#items + 1] = {
      id = "review:" .. ctx.normalize_string(review.id, ""),
      kind = "review",
      author = ctx.normalize_string(review.author, "unknown"),
      association = ctx.normalize_string(review.association, ""),
      state = ctx.normalize_string(review.state, "COMMENTED"),
      body = ctx.normalize_string(review.body, ""),
      created_at = ctx.normalize_string(review.submitted_at, ""),
      url = ctx.normalize_string(review.url, ""),
      commit_oid = ctx.normalize_string(review.commit_oid, ""),
    }
  end

  for _, thread in ipairs(type(threads) == "table" and threads or {}) do
    for _, comment in ipairs(type(thread.comments) == "table" and thread.comments or {}) do
      local target = timeline_thread_target(thread, comment, ctx)
      items[#items + 1] = {
        id = "thread:" .. ctx.normalize_string(thread.id, "") .. ":" .. ctx.normalize_string(comment.id, ""),
        kind = "thread_comment",
        author = ctx.normalize_string(comment.author, "unknown"),
        body = ctx.normalize_string(comment.body, ""),
        diff_hunk = ctx.normalize_string(comment.diff_hunk, ""),
        state = ctx.normalize_string(comment.state, ""),
        created_at = ctx.normalize_string(comment.created_at, ""),
        url = ctx.normalize_string(comment.url, ""),
        path = target and target.path or ctx.normalize_string(comment.path, ctx.normalize_string(thread.path, "")),
        line = target and target.line or ctx.first_positive_line(comment.line, thread.line, thread.start_line),
        original_line = target and target.original_line
          or ctx.first_positive_line(comment.original_line, thread.original_line, thread.original_start_line),
        side = target and target.side or "head",
        target = target,
        thread_id = ctx.normalize_string(thread.id, ""),
        commit_oid = ctx.normalize_string(comment.commit_oid, ""),
        original_commit_oid = ctx.normalize_string(comment.original_commit_oid, ""),
        is_resolved = thread.is_resolved == true,
        is_outdated = thread.is_outdated == true,
      }
    end
  end

  for _, commit in ipairs(type(commits) == "table" and commits or {}) do
    items[#items + 1] = build_commit_timeline_item(commit, ctx)
  end

  for _, event in ipairs(type(pr_change_events) == "table" and pr_change_events or {}) do
    items[#items + 1] = {
      id = "pr_change:" .. ctx.normalize_string(event.id, ""),
      kind = "pr_change",
      change_type = ctx.normalize_string(event.change_type, "updated"),
      change_summary = ctx.normalize_string(event.change_summary, ""),
      change_details = ctx.normalize_string(event.change_details, ""),
      change_label_color = ctx.normalize_string(event.change_label_color, ""),
      author = ctx.normalize_string(event.author, "unknown"),
      body = ctx.normalize_string(event.body, ""),
      created_at = ctx.normalize_string(event.created_at, ""),
      url = ctx.normalize_string(event.url, ""),
      source = ctx.normalize_string(event.source, "graphql"),
    }
  end

  table.sort(items, function(left, right)
    return timeline_sort_key(left, ctx) < timeline_sort_key(right, ctx)
  end)
  return items
end

local pr_change_events_query = [[
query($owner:String!, $name:String!, $number:Int!, $first:Int!, $after:String) {
  repository(owner:$owner, name:$name) {
    pullRequest(number:$number) {
      url
      timelineItems(
        first:$first
        after:$after
        itemTypes:[
          BASE_REF_CHANGED_EVENT
          HEAD_REF_FORCE_PUSHED_EVENT
          MERGED_EVENT
          READY_FOR_REVIEW_EVENT
          CONVERT_TO_DRAFT_EVENT
          REVIEW_REQUESTED_EVENT
          REVIEW_REQUEST_REMOVED_EVENT
          ASSIGNED_EVENT
          UNASSIGNED_EVENT
          LABELED_EVENT
          UNLABELED_EVENT
          MILESTONED_EVENT
          DEMILESTONED_EVENT
          CLOSED_EVENT
          REOPENED_EVENT
          RENAMED_TITLE_EVENT
        ]
      ) {
        pageInfo {
          hasNextPage
          endCursor
        }
        nodes {
          __typename
          ... on Node {
            id
          }
          ... on ClosedEvent {
            createdAt
            stateReason
            actor { login }
          }
          ... on ReopenedEvent {
            createdAt
            actor { login }
          }
          ... on MergedEvent {
            createdAt
            mergeRefName
            actor { login }
            commit { oid }
          }
          ... on ReadyForReviewEvent {
            createdAt
            actor { login }
          }
          ... on ConvertToDraftEvent {
            createdAt
            actor { login }
          }
          ... on RenamedTitleEvent {
            createdAt
            actor { login }
            previousTitle
            currentTitle
          }
          ... on BaseRefChangedEvent {
            createdAt
            actor { login }
            previousRefName
            currentRefName
          }
          ... on HeadRefForcePushedEvent {
            createdAt
            actor { login }
            beforeCommit { oid }
            afterCommit { oid }
            ref { name }
          }
          ... on ReviewRequestedEvent {
            createdAt
            actor { login }
            requestedReviewer {
              __typename
              ... on User {
                login
              }
              ... on Team {
                slug
                name
              }
            }
          }
          ... on ReviewRequestRemovedEvent {
            createdAt
            actor { login }
            requestedReviewer {
              __typename
              ... on User {
                login
              }
              ... on Team {
                slug
                name
              }
            }
          }
          ... on AssignedEvent {
            createdAt
            actor { login }
            assignee {
              __typename
              ... on User { login }
              ... on Mannequin { login }
            }
          }
          ... on UnassignedEvent {
            createdAt
            actor { login }
            assignee {
              __typename
              ... on User { login }
              ... on Mannequin { login }
            }
          }
          ... on LabeledEvent {
            createdAt
            actor { login }
            label { name color }
          }
          ... on UnlabeledEvent {
            createdAt
            actor { login }
            label { name color }
          }
          ... on MilestonedEvent {
            createdAt
            actor { login }
            milestoneTitle
          }
          ... on DemilestonedEvent {
            createdAt
            actor { login }
            milestoneTitle
          }
        }
      }
    }
  }
}
]]

local function short_oid(value, ctx)
  local oid = ctx.normalize_string(value, "")
  if oid == "" then
    return ""
  end
  return oid:sub(1, 8)
end

local function requested_reviewer_name(node, ctx)
  local reviewer = type(node) == "table" and type(node.requestedReviewer) == "table" and node.requestedReviewer or {}
  local reviewer_type = ctx.normalize_string(reviewer.__typename, "")
  if reviewer_type == "Team" then
    local slug = ctx.normalize_string(reviewer.slug, "")
    if slug ~= "" then
      return "@" .. slug
    end
    local name = ctx.normalize_string(reviewer.name, "")
    if name ~= "" then
      return name
    end
  end

  local login = ctx.normalize_login(reviewer, "")
  if login ~= "" and login ~= "unknown" then
    return "@" .. login
  end

  return "(unknown reviewer)"
end

local function assignee_name(node, ctx)
  local assignee = type(node) == "table" and type(node.assignee) == "table" and node.assignee or {}
  local login = ctx.normalize_login(assignee, "")
  if login ~= "" and login ~= "unknown" then
    return "@" .. login
  end
  return "(unknown assignee)"
end

local function normalize_pr_change_node(node, fallback_url, ctx)
  if type(node) ~= "table" then
    return nil
  end

  local typename = ctx.normalize_string(node.__typename, "")
  if typename == "" then
    return nil
  end

  local created_at = ctx.normalize_string(node.createdAt, "")
  local id = ctx.normalize_string(node.id, typename .. ":" .. created_at)
  local author = ctx.normalize_login(node.actor, "unknown")
  local change_type = ""
  local change_summary = ""
  local change_details = ""
  local change_label_color = ""

  if typename == "ClosedEvent" then
    change_type = "closed"
    change_summary = "Closed pull request"
    local reason = ctx.normalize_string(node.stateReason, "")
    if reason ~= "" then
      change_details = "Reason: " .. reason
    end
  elseif typename == "ReopenedEvent" then
    change_type = "reopened"
    change_summary = "Reopened pull request"
  elseif typename == "MergedEvent" then
    change_type = "merged"
    local merge_ref = ctx.normalize_string(node.mergeRefName, "")
    change_summary = merge_ref ~= "" and ("Merged into `" .. merge_ref .. "`") or "Merged pull request"
    local merged_commit = type(node.commit) == "table" and short_oid(node.commit.oid, ctx) or ""
    if merged_commit ~= "" then
      change_details = "Merge commit: `" .. merged_commit .. "`"
    end
  elseif typename == "ReadyForReviewEvent" then
    change_type = "ready_for_review"
    change_summary = "Marked ready for review"
  elseif typename == "ConvertToDraftEvent" then
    change_type = "converted_to_draft"
    change_summary = "Converted to draft"
  elseif typename == "RenamedTitleEvent" then
    change_type = "renamed_title"
    change_summary = "Renamed pull request title"
    local previous_title = ctx.normalize_string(node.previousTitle, "")
    local current_title = ctx.normalize_string(node.currentTitle, "")
    if previous_title ~= "" or current_title ~= "" then
      change_details = string.format(
        "`%s` -> `%s`",
        previous_title ~= "" and previous_title or "(empty)",
        current_title ~= "" and current_title or "(empty)"
      )
    end
  elseif typename == "BaseRefChangedEvent" then
    change_type = "base_ref_changed"
    change_summary = "Changed base branch"
    local previous_ref = ctx.normalize_string(node.previousRefName, "")
    local current_ref = ctx.normalize_string(node.currentRefName, "")
    if previous_ref ~= "" or current_ref ~= "" then
      change_details = string.format(
        "`%s` -> `%s`",
        previous_ref ~= "" and previous_ref or "(unknown)",
        current_ref ~= "" and current_ref or "(unknown)"
      )
    end
  elseif typename == "HeadRefForcePushedEvent" then
    change_type = "head_ref_force_pushed"
    change_summary = "Force-pushed branch"
    local ref_name = type(node.ref) == "table" and ctx.normalize_string(node.ref.name, "") or ""
    local before_oid = type(node.beforeCommit) == "table" and short_oid(node.beforeCommit.oid, ctx) or ""
    local after_oid = type(node.afterCommit) == "table" and short_oid(node.afterCommit.oid, ctx) or ""
    local base = ""
    if before_oid ~= "" or after_oid ~= "" then
      base = string.format("`%s` -> `%s`", before_oid ~= "" and before_oid or "(unknown)", after_oid ~= "" and after_oid or "(unknown)")
    end
    if ref_name ~= "" and base ~= "" then
      change_details = string.format("`%s`: %s", ref_name, base)
    elseif ref_name ~= "" then
      change_details = string.format("`%s`", ref_name)
    else
      change_details = base
    end
  elseif typename == "ReviewRequestedEvent" then
    change_type = "review_requested"
    change_summary = "Requested review"
    change_details = requested_reviewer_name(node, ctx)
  elseif typename == "ReviewRequestRemovedEvent" then
    change_type = "review_request_removed"
    change_summary = "Removed review request"
    change_details = requested_reviewer_name(node, ctx)
  elseif typename == "AssignedEvent" then
    change_type = "assigned"
    change_summary = "Assigned"
    change_details = assignee_name(node, ctx)
  elseif typename == "UnassignedEvent" then
    change_type = "unassigned"
    change_summary = "Unassigned"
    change_details = assignee_name(node, ctx)
  elseif typename == "LabeledEvent" then
    change_type = "labeled"
    change_summary = "Added label"
    change_details = ctx.normalize_string(type(node.label) == "table" and node.label.name, "(unknown label)")
    change_label_color = ctx.normalize_string(type(node.label) == "table" and node.label.color, "")
  elseif typename == "UnlabeledEvent" then
    change_type = "unlabeled"
    change_summary = "Removed label"
    change_details = ctx.normalize_string(type(node.label) == "table" and node.label.name, "(unknown label)")
    change_label_color = ctx.normalize_string(type(node.label) == "table" and node.label.color, "")
  elseif typename == "MilestonedEvent" then
    change_type = "milestoned"
    change_summary = "Added milestone"
    change_details = ctx.normalize_string(node.milestoneTitle, "(unknown milestone)")
  elseif typename == "DemilestonedEvent" then
    change_type = "demilestoned"
    change_summary = "Removed milestone"
    change_details = ctx.normalize_string(node.milestoneTitle, "(unknown milestone)")
  else
    return nil
  end

  local body = change_summary
  if change_details ~= "" then
    body = body .. "\n" .. change_details
  end

  return {
    id = id,
    change_type = change_type,
    change_summary = change_summary,
    change_details = change_details,
    change_label_color = change_label_color,
    author = author,
    body = body,
    created_at = created_at,
    url = ctx.normalize_string(fallback_url, ""),
    source = "graphql",
  }
end

local function parse_pr_change_events_response(response, fallback_url, ctx)
  local data = type(response) == "table" and response.data or nil
  local repo_node = type(data) == "table" and data.repository or nil
  local pr_node = type(repo_node) == "table" and repo_node.pullRequest or nil
  if type(pr_node) ~= "table" then
    return nil, nil, nil, "Unable to resolve pull request timeline for PR changes"
  end

  local pull_request_url = ctx.normalize_string(pr_node.url, ctx.normalize_string(fallback_url, ""))
  local timeline_items = type(pr_node.timelineItems) == "table" and pr_node.timelineItems or {}
  local nodes = type(timeline_items.nodes) == "table" and timeline_items.nodes or {}
  local page_info = type(timeline_items.pageInfo) == "table" and timeline_items.pageInfo or {}
  local has_next_page = page_info.hasNextPage == true
  local end_cursor = ctx.normalize_string(page_info.endCursor, "")
  local events = {}

  for _, node in ipairs(nodes) do
    local event = normalize_pr_change_node(node, pull_request_url, ctx)
    if type(event) == "table" then
      events[#events + 1] = event
    end
  end

  return events, has_next_page, end_cursor, nil
end

function M.finalize_pr_change_events(collected, max_items, ctx)
  local items = {}
  for _, item in ipairs(type(collected) == "table" and collected or {}) do
    items[#items + 1] = item
  end

  table.sort(items, function(left, right)
    return timeline_sort_key(left, ctx) < timeline_sort_key(right, ctx)
  end)

  if #items > max_items then
    local trimmed = {}
    local start_index = #items - max_items + 1
    for index = start_index, #items do
      trimmed[#trimmed + 1] = items[index]
    end
    items = trimmed
  end

  return items
end

function M.fetch_pr_change_events_async(number, opts, callback, ctx)
  opts = type(opts) == "table" and opts or {}
  callback = callback or function() end

  if type(ctx.run_graphql_async) ~= "function" then
    local events, err = M.fetch_pr_change_events(number, opts, ctx)
    callback(events, err)
    return
  end

  local repository = ctx.normalize_repository_from_input(opts.repository)
  if not repository then
    local resolved, repo_err = ctx.resolve_repository()
    if not resolved then
      callback(nil, repo_err)
      return
    end
    repository = resolved
  end

  local first = ctx.clamp_positive(opts.first or opts.limit, 100, 100)
  local max_items = ctx.clamp_positive(opts.max_items, first)
  local max_pages = ctx.clamp_positive(opts.max_pages, 3, 10)
  local fallback_url = ctx.normalize_string(opts.pr_url, "")
  local after = nil
  local collected = {}
  local page = 1

  local function fetch_next_page()
    if page > max_pages then
      callback(M.finalize_pr_change_events(collected, max_items, ctx), nil)
      return
    end

    local variables = {
      { flag = "-f", key = "owner", value = repository.owner },
      { flag = "-f", key = "name", value = repository.name },
      { flag = "-F", key = "number", value = tonumber(number) or number },
      { flag = "-F", key = "first", value = first },
    }
    if after ~= "" then
      variables[#variables + 1] = { flag = "-f", key = "after", value = after }
    end

    ctx.run_graphql_async(pr_change_events_query, variables, function(response, err)
      if not response then
        callback(nil, err)
        return
      end

      local page_items, has_next_page, end_cursor, parse_err = parse_pr_change_events_response(response, fallback_url, ctx)
      if not page_items then
        callback(nil, parse_err)
        return
      end

      for _, item in ipairs(page_items) do
        collected[#collected + 1] = item
      end

      if #collected >= max_items or not has_next_page or end_cursor == "" then
        callback(M.finalize_pr_change_events(collected, max_items, ctx), nil)
        return
      end

      after = end_cursor
      page = page + 1
      fetch_next_page()
    end)
  end

  fetch_next_page()
end

function M.fetch_pr_change_events(number, opts, ctx)
  opts = type(opts) == "table" and opts or {}

  local repository = ctx.normalize_repository_from_input(opts.repository)
  if not repository then
    local resolved, repo_err = ctx.resolve_repository()
    if not resolved then
      return nil, repo_err
    end
    repository = resolved
  end

  local first = ctx.clamp_positive(opts.first or opts.limit, 100, 100)
  local max_items = ctx.clamp_positive(opts.max_items, first)
  local max_pages = ctx.clamp_positive(opts.max_pages, 3, 10)
  local fallback_url = ctx.normalize_string(opts.pr_url, "")
  local after = nil
  local collected = {}

  for _ = 1, max_pages do
    local variables = {
      { flag = "-f", key = "owner", value = repository.owner },
      { flag = "-f", key = "name", value = repository.name },
      { flag = "-F", key = "number", value = tonumber(number) or number },
      { flag = "-F", key = "first", value = first },
    }
    if after ~= "" then
      variables[#variables + 1] = { flag = "-f", key = "after", value = after }
    end

    local response, err = ctx.run_graphql(pr_change_events_query, variables)
    if not response then
      return nil, err
    end

    local page_items, has_next_page, end_cursor, parse_err = parse_pr_change_events_response(response, fallback_url, ctx)
    if not page_items then
      return nil, parse_err
    end

    for _, item in ipairs(page_items) do
      collected[#collected + 1] = item
    end

    if #collected >= max_items then
      break
    end
    if not has_next_page or end_cursor == "" then
      break
    end

    after = end_cursor
  end

  return M.finalize_pr_change_events(collected, max_items, ctx), nil
end

return M
