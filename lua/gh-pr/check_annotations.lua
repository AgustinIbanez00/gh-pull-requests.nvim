local highlights = require("gh-pr.highlights")

local M = {}

local namespace = vim.api.nvim_create_namespace("gh-pr-check-annotations")
local sign_group = "gh_pr_check_annotations"

local sign_names = {
  failure = "GhPrCheckAnnotationSignFailure",
  warning = "GhPrCheckAnnotationSignWarning",
  notice = "GhPrCheckAnnotationSignNotice",
}

local MAX_HIGHLIGHT_RANGE = 80

local hl_groups = {
  failure = "GhPrCheckAnnotationFail",
  warning = "GhPrCheckAnnotationWarn",
  notice = "GhPrCheckAnnotationNotice",
}

local virt_hl_groups = {
  failure = "GhPrCheckAnnotationVirtFail",
  warning = "GhPrCheckAnnotationVirtWarn",
  notice = "GhPrCheckAnnotationVirtNotice",
}

local function safe_string(value, fallback)
  if type(value) == "string" and value ~= "" then
    return value
  end
  return fallback or ""
end

local function normalize_path(path)
  if type(path) ~= "string" then
    return ""
  end
  return path:gsub("\\", "/"):gsub("/+", "/"):gsub("^/", ""):gsub("/$", "")
end

local function normalize_paths(primary, alternatives)
  local ordered = {}
  local seen = {}

  local function add(path)
    local normalized = normalize_path(path)
    if normalized == "" or seen[normalized] then
      return
    end
    seen[normalized] = true
    ordered[#ordered + 1] = normalized
  end

  add(primary)
  for _, candidate in ipairs(type(alternatives) == "table" and alternatives or {}) do
    add(candidate)
  end

  return ordered
end

local function normalize_level(value)
  local level = type(value) == "string" and value:lower() or "notice"
  if level ~= "failure" and level ~= "warning" then
    level = "notice"
  end
  return level
end

local function normalize_line(value)
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

local function ensure_highlights()
  highlights.ensure_baseline_links()
end

local function ensure_signs()
  vim.fn.sign_define(sign_names.failure, { text = "E!", texthl = "GhPrCheckAnnotationFail" })
  vim.fn.sign_define(sign_names.warning, { text = "W!", texthl = "GhPrCheckAnnotationWarn" })
  vim.fn.sign_define(sign_names.notice, { text = "N!", texthl = "GhPrCheckAnnotationNotice" })
end

local function compact_label(annotation)
  local level = normalize_level(annotation.annotation_level)
  local prefix = level == "failure" and "FAIL" or (level == "warning" and "WARN" or "NOTE")
  local start_line = tonumber(annotation.start_line) or 0
  local end_line = tonumber(annotation.end_line) or start_line
  local range = start_line > 0 and (start_line == end_line and ("L" .. start_line) or string.format("L%d-L%d", start_line, end_line)) or "L?"
  local title = safe_string(annotation.title, "")
  if title == "" then
    title = safe_string(annotation.message:match("([^\r\n]+)"), "Annotation")
  end
  return string.format("[%s] %s %s", prefix, range, title)
end

function M.clear_buffer(bufnr)
  if type(bufnr) ~= "number" or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  vim.api.nvim_buf_clear_namespace(bufnr, namespace, 0, -1)
  pcall(vim.fn.sign_unplace, sign_group, { buffer = bufnr })
  vim.b[bufnr].gh_pr_check_annotations = {}
  vim.b[bufnr].gh_pr_active_check_annotation_key = nil
end

function M.attach_to_buffer(bufnr, ctx)
  ctx = type(ctx) == "table" and ctx or {}
  if type(bufnr) ~= "number" or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  M.clear_buffer(bufnr)

  local side = safe_string(ctx.side, safe_string(vim.b[bufnr].gh_pr_file_kind, ""))
  if side ~= "head" then
    return
  end

  local annotations = type(ctx.annotations) == "table" and ctx.annotations or {}
  if vim.tbl_isempty(annotations) then
    return
  end

  local path_set = {}
  for _, path in ipairs(normalize_paths(ctx.file_path, ctx.alternate_paths)) do
    path_set[path] = true
  end
  if vim.tbl_isempty(path_set) then
    return
  end

  ensure_highlights()
  ensure_signs()

  local placed = {}
  local line_map = {}

  for _, annotation in ipairs(annotations) do
    local normalized_path = normalize_path(type(annotation) == "table" and annotation.path or "")
    if normalized_path ~= "" and path_set[normalized_path] then
      local start_line = normalize_line(annotation.start_line)
      local end_line = normalize_line(annotation.end_line) or start_line
      if start_line then
        local level = normalize_level(annotation.annotation_level)
        line_map[start_line] = line_map[start_line] or {}
        line_map[start_line][#line_map[start_line] + 1] = vim.deepcopy(annotation)

        local sign_key = table.concat({ tostring(start_line), level, safe_string(annotation.title, "") }, ":")
        if not placed[sign_key] then
          placed[sign_key] = true
          pcall(vim.fn.sign_place, 0, sign_group, sign_names[level], bufnr, {
            lnum = start_line,
            priority = 35,
          })
        end

        local bounded_end = math.min(end_line or start_line, start_line + MAX_HIGHLIGHT_RANGE - 1)
        for line = start_line, bounded_end do
          pcall(vim.api.nvim_buf_set_extmark, bufnr, namespace, line - 1, 0, {
            line_hl_group = hl_groups[level],
            hl_eol = true,
            priority = 70,
          })
        end

        pcall(vim.api.nvim_buf_set_extmark, bufnr, namespace, start_line - 1, 0, {
          virt_text = { { compact_label(annotation), virt_hl_groups[level] } },
          virt_text_pos = "eol",
          priority = 65,
        })
      end
    end
  end

  vim.b[bufnr].gh_pr_check_annotations = line_map
  vim.b[bufnr].gh_pr_active_check_annotation_key = safe_string(ctx.check_key, "")
end

return M
