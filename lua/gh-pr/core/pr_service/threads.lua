local M = {}

local MAX_COMMENT_RANGE_LINES = 200
local COMMENT_RANGE_EDGE_SEGMENT = math.floor(MAX_COMMENT_RANGE_LINES / 2)

local review_threads_query = [[
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
              commit { oid }
              originalCommit { oid }
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

local function review_threads_args(repository, number, opts, ctx)
  local threads_first = ctx.clamp_positive(opts.threads_first, 50, 100)
  local comments_first = ctx.clamp_positive(opts.comments_first, 50, 100)

  return {
    "api",
    "graphql",
    "-f",
    "query=" .. review_threads_query,
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
  }
end

local function parse_review_threads_response(response)
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

function M.fetch_review_threads(number, opts, ctx)
  opts = opts or {}

  local repository, repo_err = ctx.resolve_repository()
  if not repository then
    return nil, repo_err
  end

  local response, err = ctx.gh.run_json(review_threads_args(repository, number, opts, ctx))

  if not response then
    return nil, err
  end

  return parse_review_threads_response(response)
end

function M.fetch_review_threads_async(number, opts, callback, ctx)
  opts = type(opts) == "table" and opts or {}
  callback = callback or function() end

  local repository, repo_err = ctx.resolve_repository()
  if not repository then
    callback(nil, repo_err)
    return
  end

  ctx.gh.run_json_async(review_threads_args(repository, number, opts, ctx), nil, function(response, err)
    if not response then
      callback(nil, err)
      return
    end

    local threads, parse_err = parse_review_threads_response(response)
    if not threads then
      callback(nil, parse_err)
      return
    end

    callback(threads, nil)
  end)
end

function M.normalize_diff_side(value, ctx)
  local side = ctx.normalize_string(value, ""):upper()
  if side == "LEFT" or side == "RIGHT" then
    return side
  end
  return ""
end

function M.first_positive_line(...)
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

local function add_line_items_with_range(index, path, side, lines, item)
  if type(lines) ~= "table" or vim.tbl_isempty(lines) then
    return
  end

  local range_start = tonumber(lines[1])
  local range_end = tonumber(lines[#lines])
  local range_length = #lines

  for position, line in ipairs(lines) do
    local ranged_item = vim.tbl_extend("force", {}, item, {
      range_side = side,
      range_start = range_start,
      range_end = range_end,
      range_length = range_length,
      range_index = position,
    })
    add_line_item(index, path, side, line, ranged_item)
  end
end

local function normalize_line_range(start_line, end_line)
  local start_value = tonumber(start_line)
  local end_value = tonumber(end_line)

  if start_value then
    start_value = math.floor(start_value)
  end
  if end_value then
    end_value = math.floor(end_value)
  end

  if not start_value or start_value < 1 then
    start_value = nil
  end
  if not end_value or end_value < 1 then
    end_value = nil
  end

  if not start_value and not end_value then
    return nil, nil
  end

  if not start_value then
    start_value = end_value
  elseif not end_value then
    end_value = start_value
  end

  if start_value > end_value then
    start_value, end_value = end_value, start_value
  end

  return start_value, end_value
end

local function expand_line_range(start_line, end_line)
  local range_start, range_end = normalize_line_range(start_line, end_line)
  if not range_start or not range_end then
    return {}
  end

  local total = range_end - range_start + 1
  local lines = {}

  if total <= MAX_COMMENT_RANGE_LINES then
    for line = range_start, range_end do
      lines[#lines + 1] = line
    end
    return lines
  end

  local first_end = math.min(range_end, range_start + COMMENT_RANGE_EDGE_SEGMENT - 1)
  local second_start = math.max(range_start, range_end - COMMENT_RANGE_EDGE_SEGMENT + 1)

  for line = range_start, first_end do
    lines[#lines + 1] = line
  end
  for line = second_start, range_end do
    lines[#lines + 1] = line
  end

  return lines
end

local function sort_line_index(index, ctx)
  for _, sides in pairs(index) do
    for _, side in ipairs({ "head", "base" }) do
      local line_map = sides[side] or {}
      for _, entries in pairs(line_map) do
        table.sort(entries, function(left, right)
          local left_key = ctx.normalize_string(left.created_at, "") .. ":" .. ctx.normalize_string(left.comment_id, "")
          local right_key = ctx.normalize_string(right.created_at, "") .. ":" .. ctx.normalize_string(right.comment_id, "")
          return left_key < right_key
        end)
      end
    end
  end
end

function M.build_line_comment_index(threads, opts, ctx)
  opts = opts or {}

  local show_resolved = opts.show_resolved ~= false
  local show_outdated = opts.show_outdated ~= false
  local normalized_threads = ctx.normalize_threads(threads)
  local index = {}

  for _, thread in ipairs(normalized_threads) do
    if thread.is_resolved and not show_resolved then
      goto continue
    end

    if thread.is_outdated and not show_outdated then
      goto continue
    end

    local thread_path = ctx.normalize_string(thread.path, "")
    local thread_side = M.normalize_diff_side(thread.diff_side, ctx)

    for _, comment in ipairs(thread.comments or {}) do
      local path = ctx.normalize_string(comment.path, thread_path)
      local comment_side = M.normalize_diff_side(comment.diff_side, ctx)
      local side_hint = comment_side ~= "" and comment_side or thread_side

      local head_line = M.first_positive_line(comment.line, thread.line, thread.start_line)
      local base_line = M.first_positive_line(comment.original_line, thread.original_line, thread.original_start_line)

      if side_hint == "RIGHT" and not head_line then
        head_line = M.first_positive_line(thread.line, thread.start_line)
      elseif side_hint == "LEFT" and not base_line then
        base_line = M.first_positive_line(thread.original_line, thread.original_start_line)
      end

      local head_start = M.first_positive_line(thread.start_line)
      local base_start = M.first_positive_line(thread.original_start_line)
      local head_range = expand_line_range(head_start, head_line)
      local base_range = expand_line_range(base_start, base_line)

      if vim.tbl_isempty(head_range) and type(head_line) == "number" and head_line > 0 then
        head_range = { head_line }
      end
      if vim.tbl_isempty(base_range) and type(base_line) == "number" and base_line > 0 then
        base_range = { base_line }
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

      add_line_items_with_range(index, path, "head", head_range, entry)
      add_line_items_with_range(index, path, "base", base_range, entry)
    end

    ::continue::
  end

  sort_line_index(index, ctx)
  return index
end

return M
