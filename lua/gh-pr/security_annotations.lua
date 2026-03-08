local highlights = require("gh-pr.highlights")

local M = {}

local namespace = vim.api.nvim_create_namespace("gh-pr-security-annotations")
local sign_group = "gh_pr_security_annotations"

local sign_names = {
  critical = "GhPrSecurityAlertSignCritical",
  high = "GhPrSecurityAlertSignHigh",
  medium = "GhPrSecurityAlertSignMedium",
  low = "GhPrSecurityAlertSignLow",
}

local hl_groups = {
  critical = "GhPrSecurityAlertCritical",
  high = "GhPrSecurityAlertHigh",
  medium = "GhPrSecurityAlertMedium",
  low = "GhPrSecurityAlertLow",
}

local virt_hl_groups = {
  critical = "GhPrSecurityAlertVirtCritical",
  high = "GhPrSecurityAlertVirtHigh",
  medium = "GhPrSecurityAlertVirtMedium",
  low = "GhPrSecurityAlertVirtLow",
}

local MAX_HIGHLIGHT_RANGE = 80

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

local function normalize_severity(value)
  local severity = type(value) == "string" and value:lower() or "low"
  if severity == "critical" or severity == "high" or severity == "medium" or severity == "low" then
    return severity
  end
  if severity == "moderate" or severity == "warning" then
    return "medium"
  end
  if severity == "error" then
    return "high"
  end
  return "low"
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
  vim.fn.sign_define(sign_names.critical, { text = "C!", texthl = "GhPrSecurityAlertCritical" })
  vim.fn.sign_define(sign_names.high, { text = "H!", texthl = "GhPrSecurityAlertHigh" })
  vim.fn.sign_define(sign_names.medium, { text = "M!", texthl = "GhPrSecurityAlertMedium" })
  vim.fn.sign_define(sign_names.low, { text = "L!", texthl = "GhPrSecurityAlertLow" })
end

local function compact_label(alert)
  local severity = normalize_severity(alert.severity)
  local prefix = severity:upper()
  local start_line = tonumber(alert.start_line) or 0
  local end_line = tonumber(alert.end_line) or start_line
  local range = start_line > 0 and (start_line == end_line and ("L" .. start_line) or string.format("L%d-L%d", start_line, end_line)) or "L?"
  local title = safe_string(alert.rule_name, "")
  if title == "" then
    title = safe_string(safe_string(alert.message, ""):match("([^\r\n]+)"), "Security alert")
  end
  return string.format("[%s] %s %s", prefix, range, title)
end

function M.clear_buffer(bufnr)
  if type(bufnr) ~= "number" or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  vim.api.nvim_buf_clear_namespace(bufnr, namespace, 0, -1)
  pcall(vim.fn.sign_unplace, sign_group, { buffer = bufnr })
  vim.b[bufnr].gh_pr_security_alerts = {}
  vim.b[bufnr].gh_pr_active_security_alert_key = nil
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

  local alerts = type(ctx.alerts) == "table" and ctx.alerts or {}
  if vim.tbl_isempty(alerts) then
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

  for _, alert in ipairs(alerts) do
    local normalized_path = normalize_path(type(alert) == "table" and alert.path or "")
    if normalized_path ~= "" and path_set[normalized_path] then
      local start_line = normalize_line(alert.start_line)
      local end_line = normalize_line(alert.end_line) or start_line
      if start_line then
        local severity = normalize_severity(alert.severity)
        line_map[start_line] = line_map[start_line] or {}
        line_map[start_line][#line_map[start_line] + 1] = vim.deepcopy(alert)

        local sign_key = table.concat({
          tostring(start_line),
          severity,
          safe_string(alert.rule_id, ""),
          safe_string(alert.rule_name, ""),
        }, ":")
        if not placed[sign_key] then
          placed[sign_key] = true
          pcall(vim.fn.sign_place, 0, sign_group, sign_names[severity], bufnr, {
            lnum = start_line,
            priority = 36,
          })
        end

        local bounded_end = math.min(end_line or start_line, start_line + MAX_HIGHLIGHT_RANGE - 1)
        for line = start_line, bounded_end do
          pcall(vim.api.nvim_buf_set_extmark, bufnr, namespace, line - 1, 0, {
            line_hl_group = hl_groups[severity],
            hl_eol = true,
            priority = 72,
          })
        end

        pcall(vim.api.nvim_buf_set_extmark, bufnr, namespace, start_line - 1, 0, {
          virt_text = { { compact_label(alert), virt_hl_groups[severity] } },
          virt_text_pos = "eol",
          priority = 68,
        })
      end
    end
  end

  vim.b[bufnr].gh_pr_security_alerts = line_map
  vim.b[bufnr].gh_pr_active_security_alert_key = safe_string(ctx.alert_key, "")
end

return M
