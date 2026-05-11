local M = {}

local function valid_buf(bufnr)
  return type(bufnr) == "number" and bufnr > 0 and vim.api.nvim_buf_is_valid(bufnr)
end

local function positive(value, fallback)
  local n = tonumber(value)
  if not n then
    return fallback
  end
  n = math.floor(n)
  if n < 1 then
    return fallback
  end
  return n
end

local function non_negative(value, fallback)
  local n = tonumber(value)
  if not n then
    return fallback
  end
  n = math.floor(n)
  if n < 0 then
    return fallback
  end
  return n
end

local function hunk_kind(added, deleted)
  if added > 0 and deleted > 0 then
    return "modify"
  end
  if added > 0 then
    return "add"
  end
  if deleted > 0 then
    return "delete"
  end
  return "change"
end

local function make_hunk(opts)
  opts = type(opts) == "table" and opts or {}
  local added = non_negative(opts.added, 0)
  local deleted = non_negative(opts.deleted, 0)
  if added == 0 and deleted == 0 then
    return nil
  end

  local base_start = positive(opts.base_start, 1)
  local head_start = positive(opts.head_start, base_start)
  local target_side = type(opts.target_side) == "string" and opts.target_side or nil
  if target_side ~= "base" and target_side ~= "head" and target_side ~= "unified" then
    target_side = added > 0 and "head" or "base"
  end

  return {
    index = 0,
    kind = type(opts.kind) == "string" and opts.kind or hunk_kind(added, deleted),
    base_start = base_start,
    base_end = positive(opts.base_end, math.max(base_start, base_start + math.max(deleted, 1) - 1)),
    head_start = head_start,
    head_end = positive(opts.head_end, math.max(head_start, head_start + math.max(added, 1) - 1)),
    target_side = target_side,
    target_line = positive(opts.target_line, target_side == "base" and base_start or head_start),
    added = added,
    deleted = deleted,
    render_start = positive(opts.render_start, nil),
    render_end = positive(opts.render_end, nil),
  }
end

local function finalize(hunks)
  table.sort(hunks, function(a, b)
    local a_line = tonumber(a.target_line) or math.huge
    local b_line = tonumber(b.target_line) or math.huge
    if a_line ~= b_line then
      return a_line < b_line
    end
    return (a.index or 0) < (b.index or 0)
  end)

  for index, hunk in ipairs(hunks) do
    hunk.index = index
  end
  return hunks
end

local function range_from_codediff(side, fallback_start)
  side = type(side) == "table" and side or {}
  local start_line = positive(side.start_line or side.start or side.line, fallback_start)
  local count = tonumber(side.count or side.line_count)
  if count then
    count = math.max(0, math.floor(count))
    return start_line, count, math.max(start_line, start_line + math.max(count, 1) - 1)
  end

  local end_line = tonumber(side.end_line or side["end"])
  if end_line then
    end_line = math.floor(end_line)
    count = math.max(0, end_line - start_line)
    return start_line, count, math.max(start_line, end_line - 1)
  end

  return start_line, 1, start_line
end

function M.from_codediff_changes(changes)
  local hunks = {}
  for _, change in ipairs(type(changes) == "table" and changes or {}) do
    local original = type(change.original) == "table" and change.original or change.base
    local modified = type(change.modified) == "table" and change.modified or change.head
    local base_start, deleted, base_end = range_from_codediff(original, 1)
    local head_start, added, head_end = range_from_codediff(modified, base_start)
    local target_side = added > 0 and "head" or "base"
    local hunk = make_hunk({
      base_start = base_start,
      base_end = base_end,
      head_start = head_start,
      head_end = head_end,
      target_side = target_side,
      target_line = target_side == "base" and base_start or head_start,
      added = added,
      deleted = deleted,
    })
    if hunk then
      hunks[#hunks + 1] = hunk
    end
  end
  return finalize(hunks)
end

function M.from_codediff_open_result(open_result)
  local diff_result = type(open_result) == "table" and open_result.diff_result or nil
  return M.from_codediff_changes(type(diff_result) == "table" and diff_result.changes or nil)
end

function M.from_unified_line_map(line_map)
  local hunks = {}
  local max_line = 0
  for line in pairs(type(line_map) == "table" and line_map or {}) do
    if type(line) == "number" and line > max_line then
      max_line = line
    end
  end

  local current = nil
  local function flush()
    if current then
      local hunk = make_hunk(current)
      if hunk then
        hunks[#hunks + 1] = hunk
      end
      current = nil
    end
  end

  for render_line = 1, max_line do
    local meta = line_map[render_line]
    local kind = type(meta) == "table" and meta.kind or nil
    if kind == "add" or kind == "delete" then
      if not current then
        current = {
          target_side = "unified",
          target_line = render_line,
          render_start = render_line,
          render_end = render_line,
          base_start = positive(meta.base_line, positive(meta.head_line, render_line)),
          base_end = positive(meta.base_line, positive(meta.head_line, render_line)),
          head_start = positive(meta.head_line, positive(meta.base_line, render_line)),
          head_end = positive(meta.head_line, positive(meta.base_line, render_line)),
          added = 0,
          deleted = 0,
        }
      end
      current.render_end = render_line
      if kind == "add" then
        current.added = current.added + 1
        current.head_start = math.min(current.head_start, positive(meta.head_line, current.head_start))
        current.head_end = math.max(current.head_end, positive(meta.head_line, current.head_end))
      else
        current.deleted = current.deleted + 1
        current.base_start = math.min(current.base_start, positive(meta.base_line, current.base_start))
        current.base_end = math.max(current.base_end, positive(meta.base_line, current.base_end))
      end
    else
      flush()
    end
  end
  flush()

  return finalize(hunks)
end

local function buffer_text(bufnr)
  if not valid_buf(bufnr) then
    return "", 0
  end
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  return table.concat(lines, "\n"), #lines
end

function M.from_buffers(base_buf, head_buf, opts)
  opts = type(opts) == "table" and opts or {}
  if not valid_buf(base_buf) or not valid_buf(head_buf) then
    return {}
  end

  local base_text = buffer_text(base_buf)
  local head_text = buffer_text(head_buf)
  local diff_opts = vim.tbl_extend("force", { result_type = "indices" }, type(opts.diff_options) == "table" and opts.diff_options or {})
  local raw = vim.diff(base_text, head_text, diff_opts) or {}
  local hunks = {}
  for _, item in ipairs(raw) do
    local base_start = positive(item[1], 1)
    local deleted = non_negative(item[2], 0)
    local head_start = positive(item[3], base_start)
    local added = non_negative(item[4], 0)
    local target_side = added > 0 and "head" or "base"
    local hunk = make_hunk({
      base_start = base_start,
      base_end = base_start + math.max(deleted, 1) - 1,
      head_start = head_start,
      head_end = head_start + math.max(added, 1) - 1,
      target_side = target_side,
      target_line = target_side == "base" and base_start or head_start,
      added = added,
      deleted = deleted,
    })
    if hunk then
      hunks[#hunks + 1] = hunk
    end
  end
  return finalize(hunks)
end

function M.from_single_buffer(bufnr, file_mode)
  if not valid_buf(bufnr) then
    return {}
  end
  local count = math.max(1, vim.api.nvim_buf_line_count(bufnr))
  local mode = type(file_mode) == "string" and file_mode or ""
  if mode == "removed_single" then
    return finalize({
      make_hunk({
        base_start = 1,
        head_start = 1,
        target_side = "base",
        target_line = 1,
        added = 0,
        deleted = count,
      }),
    })
  end
  return finalize({
    make_hunk({
      base_start = 1,
      head_start = 1,
      target_side = "head",
      target_line = 1,
      added = count,
      deleted = 0,
    }),
  })
end

function M.from_virtual_result(diff_result)
  if type(diff_result) ~= "table" then
    return {}
  end

  local unified_buf = tonumber(diff_result.unified_buf)
  if valid_buf(unified_buf) then
    local hunks = M.from_unified_line_map(vim.b[unified_buf].gh_pr_unified_line_map)
    if #hunks > 0 then
      return hunks
    end
  end

  local file_mode = type(diff_result.file_mode) == "string" and diff_result.file_mode or ""
  local single_buf = tonumber(diff_result.single_buf)
  if valid_buf(single_buf) or file_mode == "added_single" or file_mode == "removed_single" then
    return M.from_single_buffer(single_buf, file_mode)
  end

  return M.from_buffers(tonumber(diff_result.base_buf), tonumber(diff_result.head_buf))
end

return M
