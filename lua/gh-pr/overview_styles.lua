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

local CHECK_HIGHLIGHT = {
  success = "GhPrOverviewCheckPass",
  failure = "GhPrOverviewCheckFail",
  pending = "GhPrOverviewCheckPending",
  default = "GhPrOverviewCheckNeutral",
}

local TIMELINE_HIGHLIGHT = {
  comment = "GhPrOverviewTimelineComment",
  review = "GhPrOverviewTimelineReview",
  thread_comment = "GhPrOverviewTimelineThread",
  commit = "GhPrOverviewTimelineCommit",
  pr_change = "GhPrOverviewTimelinePrChange",
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
    return "Identifier"
  end
  return TIMELINE_HIGHLIGHT[utils.safe_string(event.kind, "")] or "Identifier"
end

return M
