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
  if not (node.extra and node.extra.kind == "file" and node.extra.repo and node.extra.pr and node.path) then
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
