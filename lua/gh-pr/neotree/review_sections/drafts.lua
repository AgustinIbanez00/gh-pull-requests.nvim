local M = {}

local function safe_string(value, fallback)
  if type(value) == "string" and value ~= "" then
    return value
  end
  return fallback or ""
end

local function sanitize_node_id_component(value)
  local raw = type(value) == "string" and value or tostring(value or "")
  raw = raw:gsub("[^%w%-%._]", "_")
  if raw == "" then
    return "item"
  end
  return raw
end

local function normalize_path(path)
  if type(path) ~= "string" then
    return ""
  end
  local normalized = path:gsub("\\", "/"):gsub("/+", "/")
  normalized = normalized:gsub("^/", ""):gsub("/$", "")
  return normalized
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

local function normalize_side(value, head_line, base_line)
  local side = type(value) == "string" and value:upper() or ""
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

local function display_event_time(value)
  local raw = safe_string(value, "")
  if raw == "" then
    return "-"
  end
  return raw:gsub("T", " "):gsub("Z", "")
end

local function comment_sort_key(comment)
  return safe_string(comment.created_at, "") .. ":" .. safe_string(comment.id, "")
end

local function pending_comments(details)
  if type(details) ~= "table" then
    return {}
  end
  return type(details.pending_review_comments) == "table" and details.pending_review_comments or {}
end

local function build_target(pr, details, thread, selected_comment_id)
  if thread.path == "" then
    return nil
  end

  local head_line = first_positive_line(thread.line, thread.start_line)
  local base_line = first_positive_line(thread.original_line, thread.original_start_line)
  local side = normalize_side(thread.diff_side, head_line, base_line)
  local line = side == "base" and (base_line or head_line) or (head_line or base_line)
  local original_line = base_line or head_line
  if not line or not original_line then
    return nil
  end

  local popup_comments = {}
  for _, comment in ipairs(thread.comments) do
    popup_comments[#popup_comments + 1] = {
      id = comment.id,
      database_id = tonumber(comment.database_id) or tonumber(comment.databaseId),
      author = comment.author,
      created_at = comment.created_at,
      body = comment.body,
      url = comment.url,
      state = comment.state,
      outdated = comment.outdated == true,
      is_pending = true,
      viewer_did_author = comment.viewer_did_author == true,
      reaction_groups = vim.deepcopy(type(comment.reaction_groups) == "table" and comment.reaction_groups or {}),
      path = comment.path,
      line = comment.line,
      original_line = comment.original_line,
    }
  end

  return {
    pr = pr,
    details = details,
    path = thread.path,
    side = side,
    line = line,
    original_line = original_line,
    thread_id = thread.id,
    thread_comments = popup_comments,
    selected_comment_id = selected_comment_id,
    thread_is_resolved = thread.is_resolved == true,
    thread_is_outdated = thread.is_outdated == true,
  }
end

local function normalize_threads(raw_comments)
  local by_path = {}

  for index, raw_comment in ipairs(type(raw_comments) == "table" and raw_comments or {}) do
    local state = safe_string(raw_comment.state, "PENDING"):upper()
    if state == "PENDING" or raw_comment.isPending == true or raw_comment.is_pending == true then
      local path = normalize_path(raw_comment.path or raw_comment.thread_path)
      local file_key = path ~= "" and path or "(no file)"
      local thread_id = safe_string(raw_comment.thread_id, "pending:" .. safe_string(raw_comment.id, tostring(index)))
      local path_bucket = by_path[file_key]
      if type(path_bucket) ~= "table" then
        path_bucket = {
          path = path,
          threads = {},
          thread_order = {},
        }
        by_path[file_key] = path_bucket
      end

      local thread = path_bucket.threads[thread_id]
      if type(thread) ~= "table" then
        thread = {
          id = thread_id,
          path = path,
          diff_side = safe_string(raw_comment.thread_diff_side, raw_comment.diff_side),
          line = first_positive_line(raw_comment.thread_line, raw_comment.line),
          original_line = first_positive_line(raw_comment.thread_original_line, raw_comment.original_line),
          start_line = first_positive_line(raw_comment.thread_start_line, raw_comment.line),
          original_start_line = first_positive_line(raw_comment.thread_original_start_line, raw_comment.original_line),
          is_resolved = raw_comment.thread_is_resolved == true,
          is_outdated = raw_comment.thread_is_outdated == true,
          comments = {},
        }
        path_bucket.threads[thread_id] = thread
        path_bucket.thread_order[#path_bucket.thread_order + 1] = thread_id
      end

      local comment = {
        id = safe_string(raw_comment.id, tostring(index)),
        database_id = tonumber(raw_comment.database_id) or tonumber(raw_comment.databaseId),
        author = safe_string(raw_comment.author, "unknown"),
        body = safe_string(raw_comment.body, ""),
        created_at = safe_string(raw_comment.created_at, ""),
        url = safe_string(raw_comment.url, ""),
        state = "PENDING",
        outdated = raw_comment.outdated == true,
        is_pending = true,
        viewer_did_author = raw_comment.viewer_did_author == true,
        reaction_groups = vim.deepcopy(type(raw_comment.reaction_groups) == "table" and raw_comment.reaction_groups or {}),
        path = path,
        line = first_positive_line(raw_comment.line, raw_comment.thread_line, raw_comment.thread_start_line),
        original_line = first_positive_line(
          raw_comment.original_line,
          raw_comment.thread_original_line,
          raw_comment.thread_original_start_line
        ),
      }
      thread.comments[#thread.comments + 1] = comment
    end
  end

  local ordered = {}
  local file_keys = vim.tbl_keys(by_path)
  table.sort(file_keys, function(left, right)
    return left:lower() < right:lower()
  end)

  for _, file_key in ipairs(file_keys) do
    local file_bucket = by_path[file_key]
    local threads = {}
    for _, thread_id in ipairs(file_bucket.thread_order) do
      local thread = file_bucket.threads[thread_id]
      table.sort(thread.comments, function(left, right)
        return comment_sort_key(left) < comment_sort_key(right)
      end)
      threads[#threads + 1] = thread
    end

    table.sort(threads, function(left, right)
      local left_key = comment_sort_key(left.comments[1] or {})
      local right_key = comment_sort_key(right.comments[1] or {})
      return left_key < right_key
    end)

    ordered[#ordered + 1] = {
      display_path = file_key,
      path = file_bucket.path,
      threads = threads,
    }
  end

  return ordered
end

local function thread_node_name(thread)
  local author = type(thread.comments[1]) == "table" and safe_string(thread.comments[1].author, "unknown") or "unknown"
  local created_at = type(thread.comments[1]) == "table" and display_event_time(thread.comments[1].created_at) or "-"
  local line = first_positive_line(thread.line, thread.original_line, thread.start_line, thread.original_start_line)
  local line_label = line and (" L" .. tostring(line)) or ""
  return string.format("Thread @%s [PENDING] [%s]%s", author, created_at, line_label)
end

local function comment_node_name(comment)
  return string.format("@%s [PENDING] [%s]", safe_string(comment.author, "unknown"), display_event_time(comment.created_at))
end

local function clone_target_with_comment(target, comment_id)
  if type(target) ~= "table" then
    return nil
  end
  local copy = vim.deepcopy(target)
  copy.selected_comment_id = comment_id
  return copy
end

local function build_comment_nodes(pr, details, thread)
  local thread_target = build_target(pr, details, thread, nil)
  local nodes = {}

  for index, comment in ipairs(thread.comments) do
    local target = clone_target_with_comment(thread_target, comment.id)
    nodes[#nodes + 1] = {
      id = string.format(
        "ghpr-review:%d:drafts:thread-item:%s:%s:%d",
        pr.number,
        sanitize_node_id_component(thread.id),
        sanitize_node_id_component(comment.id),
        index
      ),
      name = comment_node_name(comment),
      type = "file",
      extra = {
        kind = type(target) == "table" and "comment_thread_item" or "message",
        pr = pr,
        details = details,
        target = target,
      },
    }
  end

  return nodes, thread_target
end

local function build_thread_nodes(pr, details, grouped_file)
  local nodes = {}

  for _, thread in ipairs(grouped_file.threads) do
    local children, target = build_comment_nodes(pr, details, thread)
    nodes[#nodes + 1] = {
      id = string.format("ghpr-review:%d:drafts:thread:%s", pr.number, sanitize_node_id_component(thread.id)),
      name = thread_node_name(thread),
      type = "directory",
      extra = {
        kind = type(target) == "table" and "comment_thread" or "directory",
        pr = pr,
        details = details,
        target = target,
      },
      children = children,
    }
  end

  return nodes
end

function M.build_section_title(details)
  local total = #pending_comments(details)
  if total > 0 then
    return string.format("Drafts %d", total)
  end
  return "Drafts"
end

function M.build_nodes(pr, details)
  if type(details) ~= "table" or details.pending_review_loaded ~= true then
    return {
      {
        id = string.format("ghpr-review:%d:drafts-loading", pr.number),
        name = "Loading draft comments...",
        type = "message",
        extra = {
          kind = "message",
          pr = pr,
          details = details,
        },
      },
    }
  end

  local comments = pending_comments(details)
  if vim.tbl_isempty(comments) and type(details.pending_review_error) == "string" and details.pending_review_error ~= "" then
    return {
      {
        id = string.format("ghpr-review:%d:drafts-error", pr.number),
        name = "Unable to load draft comments: " .. details.pending_review_error,
        type = "message",
        extra = {
          kind = "message",
          pr = pr,
          details = details,
        },
      },
    }
  end

  local grouped_files = normalize_threads(comments)
  if vim.tbl_isempty(grouped_files) then
    return {
      {
        id = string.format("ghpr-review:%d:drafts-empty", pr.number),
        name = "No draft comments in current pending review",
        type = "message",
        extra = {
          kind = "message",
          pr = pr,
          details = details,
        },
      },
    }
  end

  local nodes = {}
  for _, grouped_file in ipairs(grouped_files) do
    local comment_total = 0
    for _, thread in ipairs(grouped_file.threads) do
      comment_total = comment_total + #thread.comments
    end

    nodes[#nodes + 1] = {
      id = string.format("ghpr-review:%d:drafts-file:%s", pr.number, sanitize_node_id_component(grouped_file.display_path)),
      name = string.format("%s x%d", grouped_file.display_path, comment_total),
      type = "comment_file",
      path = grouped_file.path ~= "" and grouped_file.path or nil,
      extra = {
        kind = "drafts_file",
        pr = pr,
        details = details,
      },
      children = build_thread_nodes(pr, details, grouped_file),
    }
  end

  return nodes
end

return M
