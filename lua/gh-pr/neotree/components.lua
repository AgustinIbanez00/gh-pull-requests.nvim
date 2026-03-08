local highlights = require("neo-tree.ui.highlights")
local common = require("neo-tree.sources.common.components")
local runtime_state = require("gh-pr.state")

local M = {}
local dynamic_label_highlights = {}
local CHECK_RUNNING_STATES = {
  QUEUED = true,
  IN_PROGRESS = true,
  PENDING = true,
  EXPECTED = true,
  WAITING = true,
  REQUESTED = true,
}
local CHECK_FAILURE_STATES = {
  FAILURE = true,
  FAIL = true,
  ERROR = true,
  TIMED_OUT = true,
  CANCELLED = true,
  ACTION_REQUIRED = true,
  STARTUP_FAILURE = true,
  STALE = true,
}
local CHECK_SUCCESS_STATES = {
  SUCCESS = true,
  PASS = true,
  PASSED = true,
  NEUTRAL = true,
  SKIPPED = true,
}
local FILE_STATUS_DISPLAY = {
  added = { text = "A", highlight = "GhPrFileStatusAdded" },
  modified = { text = "M", highlight = "GhPrFileStatusModified" },
  deleted = { text = "D", highlight = "GhPrFileStatusDeleted" },
  renamed = { text = "R", highlight = "GhPrFileStatusRenamed" },
  copied = { text = "C", highlight = "GhPrFileStatusCopied" },
}
local FILE_PARENT_PATH_MAX_CHARS = 26

local function severity_highlight(value)
  local severity = type(value) == "string" and value:lower() or ""
  if severity == "critical" then
    return "GhPrSecurityAlertCritical"
  end
  if severity == "high" then
    return "GhPrSecurityAlertHigh"
  end
  if severity == "medium" or severity == "moderate" then
    return "GhPrSecurityAlertMedium"
  end
  if severity == "low" then
    return "GhPrSecurityAlertLow"
  end
  return nil
end

local function display_width(value)
  if type(value) ~= "string" or value == "" then
    return 0
  end
  return vim.fn.strdisplaywidth(value)
end

local function left_pad_display_width(value, width)
  local text = type(value) == "string" and value or ""
  local target = math.max(0, math.floor(tonumber(width) or 0))
  local current = display_width(text)
  if current >= target then
    return text
  end
  return string.rep(" ", target - current) .. text
end

local function uppercase(value)
  if type(value) ~= "string" then
    return ""
  end
  return value:upper()
end

local function normalize_login(value)
  if type(value) == "table" and type(value.login) == "string" and value.login ~= "" then
    return value.login
  end
  if type(value) == "string" and value ~= "" then
    return value
  end
  return nil
end

local function resolve_pr_context(node)
  local extra = type(node.extra) == "table" and node.extra or {}
  local pr = type(extra.pr) == "table" and extra.pr or nil
  local details = type(extra.details) == "table" and extra.details or nil
  return pr, details
end

local function title_for_pr_node(node, pr)
  if type(pr) ~= "table" then
    return node.name or ""
  end

  local number = tonumber(pr.number)
  local title = type(pr.title) == "string" and pr.title or ""
  if title == "" then
    title = "(untitled)"
  end
  if number then
    return string.format("#%d %s", number, title)
  end
  return title
end

local function normalize_check_state(check)
  local status = uppercase(check.status ~= "" and check.status or check.state)
  local conclusion = uppercase(check.conclusion)

  if CHECK_RUNNING_STATES[status] then
    return "running"
  end
  if CHECK_FAILURE_STATES[conclusion] or CHECK_FAILURE_STATES[status] then
    return "failed"
  end
  if CHECK_SUCCESS_STATES[conclusion] or CHECK_SUCCESS_STATES[status] then
    return "success"
  end

  return "none"
end

local function check_state_for_pr(node)
  local pr, details = resolve_pr_context(node)
  local source = type(details) == "table" and details or pr
  local checks = type(source) == "table" and source.statusCheckRollup or nil
  if type(checks) ~= "table" or vim.tbl_isempty(checks) then
    return "none"
  end

  local has_failed = false
  local has_success = false
  for _, check in ipairs(checks) do
    local state = normalize_check_state(type(check) == "table" and check or {})
    if state == "running" then
      return "running"
    end
    if state == "failed" then
      has_failed = true
    elseif state == "success" then
      has_success = true
    end
  end

  if has_failed then
    return "failed"
  end
  if has_success then
    return "success"
  end
  return "none"
end

local function normalize_hex_color(value)
  if type(value) ~= "string" then
    return nil
  end

  local cleaned = value:gsub("#", ""):upper()
  if cleaned:match("^[0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F]$") then
    return cleaned
  end
  return nil
end

local function label_highlight(color)
  local hex = normalize_hex_color(color)
  if not hex then
    return "GhPrLabelDefault"
  end

  local group = "GhPrLabel_" .. hex
  if not dynamic_label_highlights[group] then
    dynamic_label_highlights[group] = true
    pcall(vim.api.nvim_set_hl, 0, group, {
      fg = "#" .. hex,
      bold = true,
    })
  end

  return group
end

local function file_icon_from_name(name)
  local ok, devicons = pcall(require, "nvim-web-devicons")
  if not ok then
    return nil
  end

  local icon, icon_hl = devicons.get_icon(name, nil, { default = true })
  if not icon then
    return nil
  end

  return { text = icon .. " ", highlight = icon_hl or highlights.FILE_ICON }
end

local function icon_for_node(node)
  if node.extra and node.extra.kind == "reviewer" then
    return { text = "󰀄 ", highlight = highlights.FILE_ICON }
  end

  if node.extra and node.extra.kind == "commit" then
    return { text = "󰜘 ", highlight = highlights.FILE_ICON }
  end

  if node.extra and node.extra.kind == "check" then
    return { text = "󰙨 ", highlight = highlights.FILE_ICON }
  end

  if node.extra and (node.extra.kind == "security" or node.extra.kind == "security_code_scanning" or node.extra.kind == "security_dependency_review") then
    return { text = "󰒃 ", highlight = highlights.FILE_ICON }
  end

  if node.extra and (node.extra.kind == "security_code_scanning_file" or node.extra.kind == "security_dependency_manifest") then
    local name = node.extra.file_path or node.extra.manifest_path or node.name
    local icon = file_icon_from_name(name)
    if icon then
      return icon
    end
    return { text = "󰈙 ", highlight = highlights.FILE_ICON }
  end

  if node.extra and node.extra.kind == "security_code_scanning_alert" then
    return { text = "󰅚 ", highlight = highlights.FILE_ICON }
  end

  if node.extra and node.extra.kind == "security_dependency_package" then
    return { text = "󰏖 ", highlight = highlights.FILE_ICON }
  end

  if node.extra and node.extra.kind == "security_dependency_vulnerability" then
    return { text = "󰳦 ", highlight = highlights.FILE_ICON }
  end

  if node.extra and node.extra.kind == "check_annotation_file" then
    return { text = "󰈙 ", highlight = highlights.FILE_ICON }
  end

  if node.extra and node.extra.kind == "check_annotation" then
    return { text = "󰅚 ", highlight = highlights.FILE_ICON }
  end

  if node.extra and node.extra.kind == "label" then
    return { text = "󰓹 ", highlight = highlights.FILE_ICON }
  end

  if node.extra and node.extra.kind == "comment_thread" then
    return { text = "󰙩 ", highlight = highlights.FILE_ICON }
  end

  if node.extra and node.extra.kind == "comment_event_review" then
    return { text = "󰦑 ", highlight = highlights.FILE_ICON }
  end

  if node.extra
    and (node.extra.kind == "comment_event_global" or node.extra.kind == "comment_thread_item" or node.extra.kind == "comment_event_thread_item") then
    return { text = "󰍩 ", highlight = highlights.FILE_ICON }
  end

  if node.extra and node.extra.kind == "comment_file" then
    local name = node.extra.file_name
      or (type(node.path) == "string" and node.path:match("[^/\\]+$"))
      or node.name
    local icon = file_icon_from_name(name)
    if icon then
      return icon
    end
    return { text = "󰈙 ", highlight = highlights.FILE_ICON }
  end

  if node.type == "directory" or node.type == "folder" or node.type == "query" or node.type == "files" then
    if node:is_expanded() then
      return { text = " ", highlight = highlights.DIRECTORY_ICON }
    end
    return { text = " ", highlight = highlights.DIRECTORY_ICON }
  end

  if node.type == "pr" then
    return { text = " ", highlight = highlights.DIRECTORY_ICON }
  end

  if node.type == "overview" then
    return { text = "󰈙 ", highlight = highlights.FILE_ICON }
  end

  if node.type == "message" then
    return { text = "󰍡 ", highlight = highlights.MESSAGE }
  end

  if node.type == "file" then
    local icon = file_icon_from_name(node.name)
    if icon then
      return icon
    end
    return { text = "󰈙 ", highlight = highlights.FILE_ICON }
  end

  return { text = "󰉋 ", highlight = highlights.DIRECTORY_ICON }
end

local function has_nerd_font()
  local configured = vim.g.have_nerd_font
  if type(configured) == "boolean" then
    return configured
  end

  local guifont = type(vim.o.guifont) == "string" and vim.o.guifont:lower() or ""
  if guifont == "" then
    return false
  end

  return guifont:find("nerd", 1, true) ~= nil
end

local function icon_set()
  if has_nerd_font() then
    return {
      viewed = "",
      comment = "󰍩",
    }
  end

  return {
    viewed = "✓",
    comment = "💬",
  }
end

local function is_review_file_node(node)
  local extra = type(node) == "table" and type(node.extra) == "table" and node.extra or nil
  return extra ~= nil and extra.kind == "file" and extra.repo ~= nil and type(extra.pr) == "table" and node.path ~= nil
end

local function normalize_file_status(value)
  local normalized = type(value) == "string" and value:lower() or ""
  if normalized == "removed" then
    return "deleted"
  end
  if normalized == "deleted" then
    return "deleted"
  end
  if normalized == "added" then
    return "added"
  end
  if normalized == "renamed" then
    return "renamed"
  end
  if normalized == "copied" then
    return "copied"
  end
  return "modified"
end

local function resolve_review_file_status(node)
  local extra = node.extra
  local status = normalize_file_status(extra.file_status)
  if status ~= "modified" then
    return status
  end

  local file = type(extra.file) == "table" and extra.file or {}
  return normalize_file_status(file.status)
end

local function resolve_file_comment_count(node)
  local extra = type(node) == "table" and type(node.extra) == "table" and node.extra or {}
  local file_comment_count = tonumber(extra.file_comment_count)
  if file_comment_count ~= nil then
    return math.max(0, math.floor(file_comment_count))
  end
  return math.max(0, math.floor(tonumber(extra.open_thread_count) or 0))
end

local function compact_parent_path(path, max_chars)
  if type(path) ~= "string" or path == "" then
    return ""
  end

  local limit = tonumber(max_chars) or FILE_PARENT_PATH_MAX_CHARS
  limit = math.max(8, math.floor(limit))
  if #path <= limit then
    return path
  end

  local suffix_limit = math.max(3, limit - 2)
  local segments = vim.split(path, "/", { plain = true, trimempty = true })
  local suffix = {}
  local suffix_len = 0

  for index = #segments, 1, -1 do
    local segment = segments[index]
    local next_len = suffix_len + #segment + (suffix_len > 0 and 1 or 0)
    if next_len > suffix_limit then
      break
    end
    table.insert(suffix, 1, segment)
    suffix_len = next_len
  end

  if vim.tbl_isempty(suffix) then
    local tail = path:sub(-(suffix_limit))
    tail = tail:gsub("^/+", "")
    return "…/" .. tail
  end

  return "…/" .. table.concat(suffix, "/")
end

local function should_show_file_parent_path(node)
  if not is_review_file_node(node) then
    return false
  end

  local extra = type(node.extra) == "table" and node.extra or {}
  if extra.path_render_mode ~= "flat" then
    return false
  end

  return type(extra.parent_path) == "string" and extra.parent_path ~= ""
end

M.kind_icon = function(_, node, _)
  return icon_for_node(node)
end

M.name = function(config, node, _)
  local text = node.name or ""
  local hl = config.highlight or highlights.FILE_NAME

  if node.type == "message" then
    hl = highlights.MESSAGE
  elseif node.type == "directory" or node.type == "folder" or node.type == "query" or node.type == "pr" or node.type == "files" then
    hl = highlights.DIRECTORY_NAME
  end

  if node.extra and node.extra.kind == "reviewer" then
    local state = type(node.extra.reviewer_state) == "string" and node.extra.reviewer_state:upper() or "PENDING"
    if state == "APPROVED" then
      hl = "GhPrReviewerApproved"
    elseif state == "CHANGES_REQUESTED" then
      hl = "GhPrReviewerChanges"
    else
      hl = "GhPrReviewerPending"
    end
  end

  if node.extra and node.extra.kind == "check" then
    local state = type(node.extra.check_state) == "string" and node.extra.check_state:upper() or ""
    if state == "PASS" or state == "SUCCESS" then
      hl = "DiffAdd"
    elseif state == "FAIL" or state == "FAILURE" then
      hl = "DiagnosticError"
    elseif state == "PENDING" then
      hl = "DiagnosticWarn"
    end
  end

  if node.extra and node.extra.kind == "check_annotation" then
    local level = type(node.extra.annotation_level) == "string" and node.extra.annotation_level:lower() or "notice"
    if level == "failure" then
      hl = "GhPrCheckAnnotationFail"
    elseif level == "warning" then
      hl = "GhPrCheckAnnotationWarn"
    else
      hl = "GhPrCheckAnnotationNotice"
    end
  end

  if node.extra and (node.extra.kind == "security_code_scanning_alert" or node.extra.kind == "security_dependency_vulnerability") then
    hl = severity_highlight(node.extra.alert_severity or node.extra.security_severity) or hl
  end

  if node.extra and node.extra.kind == "security_dependency_package" and node.extra.has_vulnerabilities == true then
    hl = severity_highlight(node.extra.security_severity) or hl
  end

  if node.extra and node.extra.kind == "label" then
    hl = label_highlight(node.extra.label_color)
  end

  if node.extra and node.extra.kind == "comment_thread" then
    local status = type(node.extra.comment_status) == "string" and node.extra.comment_status:upper() or "UNRESOLVED"
    if status == "RESOLVED" then
      hl = "GhPrCommentThreadResolved"
    elseif status == "CLOSED" then
      hl = "GhPrCommentThreadClosed"
    else
      hl = "GhPrCommentThreadUnresolved"
    end
  end

  if node.extra and node.extra.kind == "comment_event_review" then
    local review_state = type(node.extra.review_state) == "string" and node.extra.review_state:upper() or "COMMENTED"
    if review_state == "APPROVED" then
      hl = "GhPrCommentReviewApproved"
    elseif review_state == "CHANGES_REQUESTED" then
      hl = "GhPrCommentReviewChanges"
    else
      hl = "GhPrCommentReviewCommented"
    end
  end

  if node.type == "pr" and type(node.extra) == "table" and type(node.extra.pr) == "table" and node.extra.pr.isDraft == true then
    hl = "GhPrPrDraft"
  end

  return {
    text = text,
    highlight = hl,
  }
end

M.pr_title = function(config, node, _)
  local pr = select(1, resolve_pr_context(node))
  return {
    text = title_for_pr_node(node, pr),
    highlight = config.highlight or highlights.DIRECTORY_NAME,
  }
end

M.pr_draft_badge = function(_, node, _)
  local pr, details = resolve_pr_context(node)
  local is_draft = (type(pr) == "table" and pr.isDraft == true) or (type(details) == "table" and details.isDraft == true)
  if not is_draft then
    return { text = "", highlight = "GhPrPrDraft" }
  end

  return {
    text = " [DRAFT]",
    highlight = "GhPrPrDraft",
  }
end

M.pr_author_badge = function(_, node, _)
  local pr, details = resolve_pr_context(node)
  local author = normalize_login(type(pr) == "table" and pr.author or nil)
    or normalize_login(type(details) == "table" and details.author or nil)
  if not author then
    return { text = "", highlight = "GhPrPrAuthor" }
  end

  local login = author:gsub("^@", "")
  if login == "" then
    return { text = "", highlight = "GhPrPrAuthor" }
  end

  return {
    text = " @" .. login,
    highlight = "GhPrPrAuthor",
  }
end

M.pr_checks_badge = function(_, node, _)
  local state = check_state_for_pr(node)
  if state == "running" then
    return {
      text = " ●",
      highlight = "GhPrCheckRunning",
    }
  end
  if state == "success" then
    return {
      text = " ✓",
      highlight = "GhPrCheckSuccess",
    }
  end
  if state == "failed" then
    return {
      text = " ✗",
      highlight = "GhPrCheckFailed",
    }
  end

  return {
    text = "",
    highlight = "GhPrCheckRunning",
  }
end

M.viewed_badge = function(_, node, _)
  if not is_review_file_node(node) then
    return { text = "", highlight = "GhPrViewedBadge" }
  end

  local viewed = runtime_state.is_viewed(node.extra.repo, node.extra.pr.number, node.path)
  if viewed then
    return {
      text = " VIEWED",
      highlight = "GhPrViewedBadge",
    }
  end

  return { text = "", highlight = "GhPrViewedBadge" }
end

M.file_status_letter = function(_, node, _)
  if not is_review_file_node(node) then
    return { text = "", highlight = "GhPrFileStatusModified" }
  end

  local status_key = resolve_review_file_status(node)
  local status = FILE_STATUS_DISPLAY[status_key] or FILE_STATUS_DISPLAY.modified
  return {
    text = " " .. status.text,
    highlight = status.highlight,
  }
end

M.file_viewed_icon = function(_, node, _)
  if not is_review_file_node(node) then
    return { text = "", highlight = "GhPrFileViewedIndicator" }
  end

  local viewed = runtime_state.is_viewed(node.extra.repo, node.extra.pr.number, node.path)
  if viewed ~= true then
    return { text = "", highlight = "GhPrFileViewedIndicator" }
  end

  local icons = icon_set()
  return {
    text = " " .. icons.viewed,
    highlight = "GhPrFileViewedIndicator",
  }
end

M.file_comments_badge = function(_, node, _)
  if not is_review_file_node(node) then
    return { text = "", highlight = "GhPrFileCommentsBadge" }
  end

  local count = resolve_file_comment_count(node)
  if count < 1 then
    return { text = "", highlight = "GhPrFileCommentsBadge" }
  end

  local icons = icon_set()
  return {
    text = string.format(" %s x%d", icons.comment, count),
    highlight = "GhPrFileCommentsBadge",
  }
end

M.file_review_badges = function(_, node, _)
  if not is_review_file_node(node) then
    return { text = "", highlight = "GhPrFileCommentsBadge" }
  end

  local status_key = resolve_review_file_status(node)
  local status = FILE_STATUS_DISPLAY[status_key] or FILE_STATUS_DISPLAY.modified

  local icons = icon_set()
  local viewed = runtime_state.is_viewed(node.extra.repo, node.extra.pr.number, node.path) == true
  local file_comment_count = resolve_file_comment_count(node)

  local status_slot = left_pad_display_width(status.text, 1)
  local viewed_width = math.max(1, display_width(icons.viewed))
  local viewed_slot = viewed and icons.viewed or ""
  viewed_slot = left_pad_display_width(viewed_slot, viewed_width)

  local badges = {
    {
      text = " " .. status_slot,
      highlight = status.highlight,
    },
    {
      text = " " .. viewed_slot,
      highlight = "GhPrFileViewedIndicator",
    },
  }

  if file_comment_count > 0 then
    badges[#badges + 1] = {
      text = string.format(" %s x%d", icons.comment, file_comment_count),
      highlight = "GhPrFileCommentsBadge",
    }
  end

  return badges
end

M.file_parent_path = function(_, node, _)
  if not should_show_file_parent_path(node) then
    return { text = "", highlight = "GhPrFilePathContext" }
  end

  local compact = compact_parent_path(node.extra.parent_path, FILE_PARENT_PATH_MAX_CHARS)
  if compact == "" then
    return { text = "", highlight = "GhPrFilePathContext" }
  end

  return {
    text = " · " .. compact,
    highlight = "GhPrFilePathContext",
  }
end

M.folder_viewed_badge = function(_, node, _)
  if not (node.extra and node.extra.kind == "directory") then
    return { text = "", highlight = "GhPrViewedBadge" }
  end

  local counts = node.extra.viewed_counts
  if type(counts) ~= "table" then
    return { text = "", highlight = "GhPrViewedBadge" }
  end

  local viewed = tonumber(counts.viewed) or 0
  local total = tonumber(counts.total) or 0
  local show_prefix = node.extra.show_viewed_prefix == true
  if not show_prefix or total < 1 or viewed < 1 then
    return { text = "", highlight = "GhPrViewedBadge" }
  end

  return {
    text = string.format("%d/%d VIEWED ", viewed, total),
    highlight = "GhPrViewedBadge",
  }
end

return vim.tbl_deep_extend("force", common, M)
