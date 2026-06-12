local M = {}

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

local function normalize_range(start_line, line)
  local target = normalize_line_number(line)
  if not target then
    return nil, nil
  end

  local first = normalize_line_number(start_line)
  if not first then
    return nil, target
  end

  if first > target then
    first, target = target, first
  end
  if first == target then
    first = nil
  end

  return first, target
end

local function normalized_side(side)
  local raw = type(side) == "string" and side or ""
  local value = raw:upper()
  if value == "LEFT" or value == "RIGHT" then
    return value
  end
  raw = raw:lower()
  if raw == "base" then
    return "LEFT"
  end
  if raw == "head" then
    return "RIGHT"
  end
  return ""
end

local function hunk_count(value)
  if type(value) ~= "string" or value == "" then
    return 1
  end
  local count = tonumber(value)
  if not count or count < 0 then
    return 1
  end
  return math.floor(count)
end

local function add_target(targets, side, line, kind, patch_line)
  if type(targets) ~= "table" then
    return
  end
  local lnum = normalize_line_number(line)
  if not lnum then
    return
  end

  targets[side][lnum] = {
    side = side,
    line = lnum,
    kind = kind,
    patch_line = patch_line,
  }
end

function M.parse_patch(patch)
  local parsed = {
    LEFT = {},
    RIGHT = {},
    has_hunks = false,
  }

  if type(patch) ~= "string" or patch == "" then
    return parsed
  end

  local old_line = nil
  local new_line = nil
  local patch_line = 0

  for _, raw in ipairs(vim.split(patch, "\n", { plain = true, trimempty = false })) do
    patch_line = patch_line + 1
    local old_start, old_count_raw, new_start, new_count_raw =
      raw:match("^@@%s+%-(%d+),?(%d*)%s+%+(%d+),?(%d*)%s+@@")

    if old_start and new_start then
      old_line = tonumber(old_start)
      new_line = tonumber(new_start)
      parsed.has_hunks = true

      if hunk_count(old_count_raw) == 0 then
        old_line = nil
      end
      if hunk_count(new_count_raw) == 0 then
        new_line = nil
      end
    elseif parsed.has_hunks and (old_line or new_line) then
      local prefix = raw:sub(1, 1)
      if prefix == " " then
        add_target(parsed, "LEFT", old_line, "context", patch_line)
        add_target(parsed, "RIGHT", new_line, "context", patch_line)
        old_line = old_line and (old_line + 1) or nil
        new_line = new_line and (new_line + 1) or nil
      elseif prefix == "-" then
        add_target(parsed, "LEFT", old_line, "delete", patch_line)
        old_line = old_line and (old_line + 1) or nil
      elseif prefix == "+" then
        add_target(parsed, "RIGHT", new_line, "add", patch_line)
        new_line = new_line and (new_line + 1) or nil
      elseif prefix == "\\" then
        -- "\ No newline at end of file" does not consume either side.
      end
    end
  end

  return parsed
end

local function target_from_side_range(path, parsed, side, start_line, line)
  local target_side = normalized_side(side)
  if target_side == "" then
    return nil, "Unable to resolve diff side for inline comment."
  end

  if type(parsed) ~= "table" or parsed.has_hunks ~= true then
    return nil, "No textual patch is available for this file."
  end

  local first, last = normalize_range(start_line, line)
  if not last then
    return nil, "Unable to resolve target line for inline comment."
  end

  local side_map = type(parsed[target_side]) == "table" and parsed[target_side] or {}
  local range_start = first or last
  for current = range_start, last do
    if type(side_map[current]) ~= "table" then
      return nil, "Inline comments are only available on lines that are part of this diff."
    end
  end

  return {
    path = path,
    start_line = first,
    line = last,
    side = target_side,
    start_side = target_side,
  }, nil
end

local function validate_plain_file_range(path, side, start_line, line, max_line)
  local first, last = normalize_range(start_line, line)
  if not last then
    return nil, "Unable to resolve target line for inline comment."
  end

  local limit = normalize_line_number(max_line)
  if not limit then
    return nil, "Unable to resolve file length for inline comment."
  end

  local range_start = first or last
  if range_start > limit or last > limit then
    return nil, "Selected range is outside this file."
  end

  local target_side = normalized_side(side)
  if target_side == "" then
    return nil, "Unable to resolve diff side for inline comment."
  end

  return {
    path = path,
    start_line = first,
    line = last,
    side = target_side,
    start_side = target_side,
  }, nil
end

local function unified_side_and_line(entry, preferred_side)
  if type(entry) ~= "table" then
    return nil, nil
  end

  local kind = type(entry.kind) == "string" and entry.kind or ""
  if kind == "delete" or kind == "del" or kind == "remove" then
    return "LEFT", normalize_line_number(entry.base_line or entry.original_line)
  end

  if kind == "add" then
    return "RIGHT", normalize_line_number(entry.head_line or entry.line)
  end

  if kind == "context" or kind == "equal" or kind == "unchanged" or kind == "" then
    if normalized_side(preferred_side) == "LEFT" then
      return "LEFT", normalize_line_number(entry.base_line or entry.original_line)
    end
    return "RIGHT", normalize_line_number(entry.head_line or entry.line)
  end

  return nil, nil
end

local function target_from_unified_range(path, parsed, unified_line_map, start_line, line, opts)
  opts = type(opts) == "table" and opts or {}

  local first, last = normalize_range(start_line, line)
  if not last then
    return nil, "Unable to resolve target line for inline comment."
  end

  if type(unified_line_map) ~= "table" or vim.tbl_isempty(unified_line_map) then
    return nil, "Unable to validate the unified diff selection. Refresh the diff and try again."
  end

  local range_start = first or last
  local target_side = nil
  local target_start = nil
  local target_line = nil
  local previous_target_line = nil

  for render_line = range_start, last do
    local side, mapped_line = unified_side_and_line(unified_line_map[render_line], opts.preferred_side)
    if not side or not mapped_line then
      return nil, "Inline comments are only available on lines that are part of this diff."
    end
    if target_side and side ~= target_side then
      return nil, "Inline comment ranges cannot mix original and modified diff sides."
    end
    if previous_target_line and mapped_line ~= previous_target_line + 1 then
      return nil, "Selected inline comment range is not continuous on the target side."
    end

    local checked = target_from_side_range(path, parsed, side, mapped_line, mapped_line)
    if not checked then
      return nil, "Inline comments are only available on lines that are part of this diff."
    end

    target_side = side
    target_start = target_start or mapped_line
    target_line = mapped_line
    previous_target_line = mapped_line
  end

  return {
    path = path,
    start_line = target_start ~= target_line and target_start or nil,
    line = target_line,
    side = target_side,
    start_side = target_side,
  }, nil
end

local function current_buffer_line_count(bufnr)
  if type(bufnr) == "number" and bufnr > 0 and vim.api.nvim_buf_is_valid(bufnr) then
    return vim.api.nvim_buf_line_count(bufnr)
  end
  return nil
end

function M.resolve_buffer_range(ctx)
  ctx = type(ctx) == "table" and ctx or {}

  local path = type(ctx.path) == "string" and ctx.path or ""
  if path == "" then
    return nil, "Unable to resolve file path for inline comment."
  end

  local action = type(ctx.action) == "string" and ctx.action or "comment"
  local bufnr = tonumber(ctx.bufnr) or vim.api.nvim_get_current_buf()
  local kind = type(ctx.kind) == "string" and ctx.kind or ""
  local file_mode = type(ctx.file_mode) == "string" and ctx.file_mode or ""
  local backend = type(ctx.backend) == "string" and ctx.backend or ""
  local layout = type(ctx.layout) == "string" and ctx.layout or ""
  local max_line = tonumber(ctx.max_line) or current_buffer_line_count(bufnr)
  local parsed = type(ctx.parsed_patch) == "table" and ctx.parsed_patch or M.parse_patch(ctx.patch)

  local target
  local err
  if file_mode == "added_single" then
    target, err = validate_plain_file_range(path, "RIGHT", ctx.start_line, ctx.line, max_line)
  elseif file_mode == "removed_single" then
    target, err = target_from_side_range(path, parsed, "LEFT", ctx.start_line, ctx.line)
  elseif kind == "base" then
    target, err = target_from_side_range(path, parsed, "LEFT", ctx.start_line, ctx.line)
  elseif kind == "head" then
    target, err = target_from_side_range(path, parsed, "RIGHT", ctx.start_line, ctx.line)
  elseif kind == "unified" and backend == "codediff" and layout == "inline" then
    target, err = target_from_side_range(path, parsed, "RIGHT", ctx.start_line, ctx.line)
  elseif kind == "unified" then
    target, err = target_from_unified_range(path, parsed, ctx.unified_line_map, ctx.start_line, ctx.line, {
      preferred_side = ctx.preferred_side,
    })
  else
    return nil, "Inline comments are only available in PR diff buffers."
  end

  if not target then
    return nil, err
  end

  if action == "suggestion" and target.side ~= "RIGHT" then
    return nil, "Inline suggestions are only available on modified/right-side diff lines."
  end

  return target, nil
end

function M.commentable_lines(ctx)
  ctx = type(ctx) == "table" and ctx or {}

  local path = type(ctx.path) == "string" and ctx.path or ""
  if path == "" then
    return {}
  end

  local bufnr = tonumber(ctx.bufnr) or vim.api.nvim_get_current_buf()
  local kind = type(ctx.kind) == "string" and ctx.kind or ""
  local file_mode = type(ctx.file_mode) == "string" and ctx.file_mode or ""
  local backend = type(ctx.backend) == "string" and ctx.backend or ""
  local layout = type(ctx.layout) == "string" and ctx.layout or ""
  local parsed = type(ctx.parsed_patch) == "table" and ctx.parsed_patch or M.parse_patch(ctx.patch)
  if parsed.has_hunks ~= true then
    return {}
  end

  local side = nil
  if file_mode == "removed_single" or kind == "base" then
    side = "LEFT"
  elseif file_mode == "added_single" or kind == "head" then
    side = "RIGHT"
  elseif kind == "unified" and backend == "codediff" and layout == "inline" then
    side = "RIGHT"
  end
  if not side then
    return {}
  end

  local max_line = tonumber(ctx.max_line) or current_buffer_line_count(bufnr) or 0
  local zones = {}
  for line in pairs(parsed[side] or {}) do
    if line >= 1 and (max_line == 0 or line <= max_line) then
      zones[line] = {
        path = path,
        line = line,
        side = side,
        start_side = side,
      }
    end
  end

  return zones
end

M._normalize_range = normalize_range

return M
