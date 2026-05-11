local utils = require("gh-pr.overview_utils")
local highlights = require("gh-pr.highlights")

local M = {}

local base_highlights_ready = false
local label_highlights = {}

local REVIEW_HIGHLIGHT = {
  APPROVED = "GhPrOverviewReviewApproved",
  CHANGES_REQUESTED = "GhPrOverviewReviewChanges",
  REVIEW_REQUIRED = "GhPrOverviewReviewPending",
}

local REVIEWER_HIGHLIGHT = {
  APPROVED = "GhPrOverviewReviewerApproved",
  PENDING = "GhPrOverviewReviewerPending",
  CHANGES_REQUESTED = "GhPrOverviewReviewerChanges",
  COMMENTED = "GhPrOverviewReviewerCommented",
}

local CHECK_HIGHLIGHT = {
  success = "GhPrOverviewCheckPass",
  failure = "GhPrOverviewCheckFail",
  pending = "GhPrOverviewCheckPending",
  default = "GhPrOverviewCheckNeutral",
}

local TIMELINE_HIGHLIGHT_BY_KEY = {
  comment = "GhPrOverviewTimelineComment",
  review_commented = "GhPrOverviewTimelineReview",
  review_approved = "GhPrOverviewReviewApproved",
  review_changes_requested = "GhPrOverviewReviewChanges",
  thread_comment = "GhPrOverviewTimelineThread",
  commit = "GhPrOverviewTimelineCommit",
  pr_change = "GhPrOverviewTimelinePrChange",
  pr_review_requested = "GhPrOverviewReviewPending",
}

local TIMELINE_ICON_NERD = {
  comment = "󰙯",
  review_commented = "󰍩",
  review_approved = "󰄬",
  review_changes_requested = "󰅖",
  thread_comment = "󰘥",
  commit = "󰜘",
  pr_change = "󰑓",
  pr_review_requested = "󰒃",
}

local TIMELINE_ICON_UNICODE = {
  comment = "💬",
  review_commented = "💬",
  review_approved = "✅",
  review_changes_requested = "❌",
  thread_comment = "💬",
  commit = "⎇",
  pr_change = "↻",
  pr_review_requested = "👀",
}

local function normalize_hex_color(value)
  if type(value) ~= "string" then
    return nil
  end

  local color = value:gsub("#", "")
  if #color == 3 then
    color = color:sub(1, 1) .. color:sub(1, 1)
      .. color:sub(2, 2) .. color:sub(2, 2)
      .. color:sub(3, 3) .. color:sub(3, 3)
  end

  if #color ~= 6 or not color:match("^[0-9a-fA-F]+$") then
    return nil
  end

  return "#" .. color:lower()
end

local function rgb_from_hex(color)
  local normalized = normalize_hex_color(color)
  if not normalized then
    return nil, nil, nil
  end

  local raw = normalized:sub(2)
  local r = tonumber(raw:sub(1, 2), 16)
  local g = tonumber(raw:sub(3, 4), 16)
  local b = tonumber(raw:sub(5, 6), 16)
  if not r or not g or not b then
    return nil, nil, nil
  end
  return r, g, b
end

local function label_fg_for_bg(r, g, b)
  local luminance = (0.299 * r) + (0.587 * g) + (0.114 * b)
  if luminance >= 140 then
    return "#111111"
  end
  return "#f8f8f8"
end

function M.ensure_base_highlights()
  if base_highlights_ready then
    return
  end
  base_highlights_ready = true
  highlights.ensure_baseline_links()
end

function M.ensure_label_highlight(color)
  local normalized = normalize_hex_color(color)
  if not normalized then
    return "GhPrOverviewBadge"
  end

  local existing = label_highlights[normalized]
  if existing then
    return existing
  end

  local r, g, b = rgb_from_hex(normalized)
  if not r then
    return "GhPrOverviewBadge"
  end

  local group = "GhPrOverviewLabel" .. normalized:gsub("#", ""):upper()
  local fg = label_fg_for_bg(r, g, b)
  vim.api.nvim_set_hl(0, group, {
    fg = fg,
    bg = normalized,
    bold = true,
  })
  label_highlights[normalized] = group
  return group
end

function M.state_text(summary)
  local state = utils.safe_string(summary.state, "UNKNOWN"):upper()
  local merged = utils.safe_string(summary.merged_at, "")
  if merged ~= "" then
    return "MERGED"
  end
  if summary.is_draft == true and state == "OPEN" then
    return "OPEN (DRAFT)"
  end
  return state
end

function M.state_highlight(summary, theme)
  if not theme.state_colors then
    return "GhPrOverviewBadge"
  end

  local merged = utils.safe_string(summary.merged_at, "")
  if merged ~= "" then
    return "GhPrOverviewStateMerged"
  end

  local state = utils.safe_string(summary.state, "UNKNOWN"):upper()
  if state == "OPEN" then
    return "GhPrOverviewStateOpen"
  end
  if state == "CLOSED" then
    return "GhPrOverviewStateClosed"
  end
  return "GhPrOverviewBadge"
end

function M.review_highlight(decision, theme)
  if not theme.state_colors then
    return "GhPrOverviewBadge"
  end
  return REVIEW_HIGHLIGHT[utils.safe_string(decision, ""):upper()] or "GhPrOverviewBadge"
end

function M.reviewer_highlight(state, theme)
  if not theme.state_colors then
    return "GhPrOverviewBadge"
  end
  return REVIEWER_HIGHLIGHT[utils.safe_string(state, ""):upper()] or "GhPrOverviewBadge"
end

function M.check_marker(check, theme)
  local status = utils.safe_string(check.status, ""):upper()
  local conclusion = utils.safe_string(check.conclusion, ""):upper()

  if conclusion == "SUCCESS" then
    return "PASS", theme.checks_colors and CHECK_HIGHLIGHT.success or CHECK_HIGHLIGHT.default
  end
  if conclusion == "FAILURE"
    or conclusion == "CANCELLED"
    or conclusion == "TIMED_OUT"
    or conclusion == "ACTION_REQUIRED" then
    return "FAIL", theme.checks_colors and CHECK_HIGHLIGHT.failure or CHECK_HIGHLIGHT.default
  end
  if status == "IN_PROGRESS" or status == "QUEUED" or status == "PENDING" then
    return "WAIT", theme.checks_colors and CHECK_HIGHLIGHT.pending or CHECK_HIGHLIGHT.default
  end

  return "INFO", CHECK_HIGHLIGHT.default
end

function M.timeline_highlight(event, theme)
  if not theme.timeline_kinds then
    return "GhPrOverviewMuted"
  end
  local key = M.timeline_kind_key(event)
  return TIMELINE_HIGHLIGHT_BY_KEY[key] or "GhPrOverviewMuted"
end

function M.timeline_kind_key(event)
  event = type(event) == "table" and event or {}
  local kind = utils.safe_string(event.kind, "")

  if kind == "review" then
    local state = utils.safe_string(event.state, "COMMENTED"):upper()
    if state == "APPROVED" then
      return "review_approved"
    end
    if state == "CHANGES_REQUESTED" then
      return "review_changes_requested"
    end
    return "review_commented"
  end

  if kind == "pr_change" then
    local change_type = utils.safe_string(event.change_type, ""):lower()
    if change_type == "review_requested" then
      return "pr_review_requested"
    end
    return "pr_change"
  end

  if kind == "commit" then
    return "commit"
  end
  if kind == "thread_comment" then
    return "thread_comment"
  end
  if kind == "comment" then
    return "comment"
  end
  return "comment"
end

local function has_nerd_font()
  local configured = vim.g.have_nerd_font
  if configured ~= nil then
    return configured == true or configured == 1
  end

  local guifont = utils.safe_string(vim.o.guifont, ""):lower()
  return guifont:find("nerd", 1, true) ~= nil
end

function M.timeline_icon(event)
  local key = M.timeline_kind_key(event)
  local icons = has_nerd_font() and TIMELINE_ICON_NERD or TIMELINE_ICON_UNICODE
  return icons[key] or icons.comment
end

return M
