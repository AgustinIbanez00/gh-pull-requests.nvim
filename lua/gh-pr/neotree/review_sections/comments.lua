local pr_service = require("gh-pr.pr_service")

local M = {}

local THREAD_SUMMARY_ORDER = { "UNRESOLVED", "RESOLVED", "CLOSED" }
local REVIEW_EVENT_SUMMARY_ORDER = { "REQUEST_CHANGES", "APPROVED", "COMMENTED" }

local function sanitize_node_id_component(value)
  local raw = type(value) == "string" and value or tostring(value or "")
  raw = raw:gsub("[^%w%-%._]", "_")
  if raw == "" then
    return "item"
  end
  return raw
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
    database_id = tonumber(raw_comment.databaseId) or tonumber(raw_comment.database_id),
    author = normalize_actor_login(raw_comment.author),
    created_at = created_at,
    body = body,
    url = url,
    state = state,
    outdated = raw_comment.outdated == true,
    is_pending = raw_comment.isPending == true or raw_comment.is_pending == true,
    viewer_did_author = raw_comment.viewerDidAuthor == true or raw_comment.viewer_did_author == true,
    reaction_groups = vim.deepcopy(type(raw_comment.reactionGroups) == "table" and raw_comment.reactionGroups or (type(raw_comment.reaction_groups) == "table" and raw_comment.reaction_groups or {})),
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

local function normalize_summary_state_label(state)
  local value = type(state) == "string" and state:upper() or ""
  if value == "CHANGES_REQUESTED" then
    return "REQUEST_CHANGES"
  end
  return value
end

local function count_entries_by_state(items, state_resolver)
  local counts = {}
  local total = 0
  local list = type(items) == "table" and items or {}
  if type(state_resolver) ~= "function" then
    return counts, total
  end

  for _, item in ipairs(list) do
    local state = normalize_summary_state_label(state_resolver(item))
    if state ~= "" then
      counts[state] = (tonumber(counts[state]) or 0) + 1
      total = total + 1
    end
  end

  return counts, total
end

local function summary_count_parts(counts, preferred_order)
  local parts = {}
  local seen = {}
  local values = type(counts) == "table" and counts or {}

  for _, state in ipairs(type(preferred_order) == "table" and preferred_order or {}) do
    seen[state] = true
    local count = tonumber(values[state]) or 0
    if count > 0 then
      parts[#parts + 1] = string.format("%d %s", count, state)
    end
  end

  local extra_states = {}
  for state, value in pairs(values) do
    local count = tonumber(value) or 0
    if state ~= "" and not seen[state] and count > 0 then
      extra_states[#extra_states + 1] = state
    end
  end
  table.sort(extra_states)

  for _, state in ipairs(extra_states) do
    parts[#parts + 1] = string.format("%d %s", tonumber(values[state]) or 0, state)
  end

  return parts
end

local function summary_fraction_parts(counts, preferred_order, total)
  local parts = {}
  local max = tonumber(total) or 0
  if max < 1 then
    return parts
  end

  local seen = {}
  local values = type(counts) == "table" and counts or {}

  for _, state in ipairs(type(preferred_order) == "table" and preferred_order or {}) do
    seen[state] = true
    local count = tonumber(values[state]) or 0
    if count > 0 then
      parts[#parts + 1] = string.format("%d/%d %s", count, max, state)
    end
  end

  local extra_states = {}
  for state, value in pairs(values) do
    local count = tonumber(value) or 0
    if state ~= "" and not seen[state] and count > 0 then
      extra_states[#extra_states + 1] = state
    end
  end
  table.sort(extra_states)

  for _, state in ipairs(extra_states) do
    parts[#parts + 1] = string.format("%d/%d %s", tonumber(values[state]) or 0, max, state)
  end

  return parts
end

local function title_with_summary(base_title, parts)
  local base = type(base_title) == "string" and base_title or ""
  local clean_parts = {}
  for _, part in ipairs(type(parts) == "table" and parts or {}) do
    if type(part) == "string" and part ~= "" then
      clean_parts[#clean_parts + 1] = part
    end
  end

  if vim.tbl_isempty(clean_parts) then
    return base
  end

  return string.format("%s %s", base, table.concat(clean_parts, " "))
end

local function summary_total_part(count, label)
  local value = tonumber(count) or 0
  if value < 1 then
    return nil
  end

  local text = type(label) == "string" and label or ""
  if text == "" then
    return tostring(value)
  end

  return string.format("%d %s", value, text)
end

local function count_review_event_states(nodes)
  return count_entries_by_state(nodes, function(node)
    local extra = type(node) == "table" and type(node.extra) == "table" and node.extra or nil
    if extra and extra.kind == "comment_event_review" then
      return extra.review_state
    end
    return nil
  end)
end

local function count_thread_states(threads)
  return count_entries_by_state(threads, function(thread)
    if type(thread) == "table" then
      return thread.status
    end
    return nil
  end)
end

function M.count_raw_thread_states(raw_threads)
  return count_entries_by_state(raw_threads, function(raw_thread)
    if type(raw_thread) ~= "table" then
      return nil
    end
    return (normalize_thread_status(raw_thread))
  end)
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
      is_pending = comment.is_pending == true,
      viewer_did_author = comment.viewer_did_author == true,
      reaction_groups = vim.deepcopy(type(comment.reaction_groups) == "table" and comment.reaction_groups or {}),
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

local function collect_orphan_threads(pr, details, threads)
  local orphan_threads = {}

  for index, raw_thread in ipairs(type(threads) == "table" and threads or {}) do
    local thread = normalize_thread_entry(raw_thread, index, pr, details)
    if thread.path == "" then
      orphan_threads[#orphan_threads + 1] = thread
    end
  end

  return orphan_threads
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

function M.build_section_title(details)
  local title = "Comments"
  if type(details) == "table" and type(details.review_threads) == "table" then
    local thread_states, thread_total = M.count_raw_thread_states(details.review_threads)
    title = title_with_summary(title, summary_fraction_parts(thread_states, THREAD_SUMMARY_ORDER, thread_total))
  end
  return title
end

function M.build_nodes(pr, details, options)
  options = type(options) == "table" and options or {}
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

  local repository = type(options.repository) == "string" and options.repository or ""
  local model = pr_service.build_overview_model(details, threads, {
    checks = 1,
    commits = 1,
    timeline = 1000,
    comments = 1000,
    reviews = 1000,
    threads = 1000,
  }, {
    repository = repository,
    thread_error = thread_error,
  })

  local orphan_threads = collect_orphan_threads(pr, details, threads)
  local review_nodes = build_review_event_nodes(pr, details, type(model.reviews) == "table" and model.reviews.items or {})
  local comment_nodes = build_global_comment_event_nodes(pr, details, type(model.comments) == "table" and model.comments.items or {})
  local orphan_nodes = build_thread_nodes(pr, details, orphan_threads)
  local orphan_thread_states, orphan_thread_total = count_thread_states(orphan_threads)
  local review_event_states, _ = count_review_event_states(review_nodes)

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
  local has_content = global_total > 0

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

  local global_children = {}
  local review_events_name = title_with_summary(
    "Reviews",
    summary_count_parts(review_event_states, REVIEW_EVENT_SUMMARY_ORDER)
  )
  global_children[#global_children + 1] = {
    id = string.format("ghpr-review:%d:comments:global-reviews", pr.number),
    name = review_events_name,
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
    name = title_with_summary("General Comments", {
      summary_total_part(#comment_nodes),
    }),
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
      name = title_with_summary(
        "Threads (No file)",
        summary_fraction_parts(orphan_thread_states, THREAD_SUMMARY_ORDER, orphan_thread_total)
      ),
      type = "directory",
      extra = {
        kind = "comments_section",
        pr = pr,
        details = details,
      },
      children = orphan_nodes,
    }
  end

  local global_summary_parts = {
    summary_total_part(global_total, "EVENTS"),
    summary_total_part(#review_nodes, "REVIEWS"),
    summary_total_part(#comment_nodes, "COMMENTS"),
    summary_total_part(#orphan_nodes, "THREADS"),
  }
  sections[#sections + 1] = {
    id = string.format("ghpr-review:%d:comments:global", pr.number),
    name = title_with_summary("Global", global_summary_parts),
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

return M
