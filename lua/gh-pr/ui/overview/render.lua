local utils = require("gh-pr.overview_utils")
local styles = require("gh-pr.overview_styles")

local M = {}

local function sanitize_positive_integer(value, fallback, min_value, max_value)
  local number = tonumber(value)
  if type(number) ~= "number" then
    return fallback
  end
  number = math.floor(number)
  if type(min_value) == "number" and number < min_value then
    return fallback
  end
  if type(max_value) == "number" and number > max_value then
    return fallback
  end
  return number
end

function M.sanitize_activity_opts(input)
  local source = type(input) == "table" and input or {}
  return {
    max_body_lines = sanitize_positive_integer(source.max_body_lines, 8, 2, 80),
    max_events = sanitize_positive_integer(source.max_events, 120, 20, 500),
    show_code_context = source.show_code_context ~= false,
  }
end

local function new_payload()
  return {
    lines = {},
    highlights = {},
    actions = {},
  }
end

local function add_line(payload, text, highlight, action)
  payload.lines[#payload.lines + 1] = text
  local line = #payload.lines
  if type(highlight) == "string" and highlight ~= "" then
    payload.highlights[#payload.highlights + 1] = {
      line = line,
      start_col = 0,
      end_col = -1,
      group = highlight,
    }
  end
  if type(action) == "table" then
    payload.actions[line] = action
  end
  return line
end

local function add_span(payload, line, start_col, end_col, group)
  if type(group) ~= "string" or group == "" then
    return
  end
  payload.highlights[#payload.highlights + 1] = {
    line = line,
    start_col = math.max(0, tonumber(start_col) or 0),
    end_col = tonumber(end_col) or -1,
    group = group,
  }
end

local function normalize_show_flags(session)
  return type(session.show) == "table" and session.show or {}
end

local function timeline_kind_enabled(session, kind)
  local show = normalize_show_flags(session)
  if show.timeline == false then
    return false
  end
  if kind == "comment" then
    return show.comments ~= false
  end
  if kind == "review" then
    return show.reviews ~= false
  end
  if kind == "thread_comment" then
    return show.threads ~= false
  end
  if kind == "commit" then
    return show.commits ~= false
  end
  if kind == "pr_change" then
    return show.pr_changes ~= false
  end
  return false
end

local function timeline_event_visible(session, event)
  local kind = utils.safe_string(type(event) == "table" and event.kind or "", "")
  if kind == "" then
    return false
  end
  return timeline_kind_enabled(session, kind)
end

local function filtered_timeline_events(session)
  local result = {}
  for _, item in ipairs(session.model.timeline and session.model.timeline.items or {}) do
    if timeline_event_visible(session, item) then
      result[#result + 1] = item
    end
  end

  local max_events = session.activity and session.activity.max_events or 120
  if #result <= max_events then
    return result
  end

  local trimmed = {}
  local start_index = #result - max_events + 1
  for index = start_index, #result do
    trimmed[#trimmed + 1] = result[index]
  end
  return trimmed
end

local function visible_timeline_total(session)
  local model = session.model or {}
  local total = 0
  if timeline_kind_enabled(session, "comment") then
    total = total + (tonumber(model.comments and model.comments.total) or 0)
  end
  if timeline_kind_enabled(session, "review") then
    total = total + (tonumber(model.reviews and model.reviews.total) or 0)
  end
  if timeline_kind_enabled(session, "thread_comment") then
    total = total + (tonumber(model.threads and model.threads.total) or 0)
  end
  if timeline_kind_enabled(session, "commit") then
    total = total + (tonumber(model.commits and model.commits.total) or 0)
  end
  if timeline_kind_enabled(session, "pr_change") then
    total = total + (tonumber(model.pr_changes and model.pr_changes.total) or 0)
  end
  return total
end

local function thread_group_key(event, index)
  local thread_id = utils.safe_string(event.thread_id, "")
  if thread_id ~= "" then
    return thread_id
  end
  local path = utils.safe_string(event.path, "(unknown)")
  local line = tonumber(event.line) or tonumber(event.original_line) or 0
  return string.format("%s:%d:%d", path, line, index)
end

local function build_activity_entries(session)
  local entries = {}
  local thread_map = {}

  for index, event in ipairs(filtered_timeline_events(session)) do
    if event.kind == "thread_comment" then
      local key = thread_group_key(event, index)
      local thread = thread_map[key]
      if not thread then
        thread = {
          id = key,
          path = utils.safe_string(event.path, "(unknown path)"),
          side = utils.safe_string(event.side, "head"),
          line = tonumber(event.line) or 0,
          original_line = tonumber(event.original_line) or 0,
          diff_hunk = utils.safe_string(event.diff_hunk, ""),
          is_resolved = event.is_resolved == true,
          is_outdated = event.is_outdated == true,
          comments = {},
        }
        thread_map[key] = thread
        entries[#entries + 1] = {
          kind = "thread",
          thread = thread,
        }
      end

      thread.comments[#thread.comments + 1] = event
      if thread.diff_hunk == "" then
        thread.diff_hunk = utils.safe_string(event.diff_hunk, "")
      end
      if thread.path == "(unknown path)" then
        thread.path = utils.safe_string(event.path, thread.path)
      end
      if thread.line < 1 then
        thread.line = tonumber(event.line) or thread.line
      end
      if thread.original_line < 1 then
        thread.original_line = tonumber(event.original_line) or thread.original_line
      end
      if event.is_resolved == true then
        thread.is_resolved = true
      end
      if event.is_outdated == true then
        thread.is_outdated = true
      end
    else
      entries[#entries + 1] = {
        kind = "event",
        event = event,
      }
    end
  end

  return entries
end

local function parse_hunk_header(line)
  if type(line) ~= "string" then
    return nil, nil
  end
  local old_start, _, new_start = line:match("^@@%s*%-(%d+),?(%d*)%s+%+(%d+),?(%d*)%s*@@")
  if not old_start or not new_start then
    return nil, nil
  end
  return tonumber(old_start), tonumber(new_start)
end

local function parse_diff_hunk_lines(lines)
  local parsed = {}
  local old_line = nil
  local new_line = nil
  local header_index = nil

  for index, text in ipairs(lines) do
    local old_start, new_start = parse_hunk_header(text)
    if old_start and new_start then
      old_line = old_start
      new_line = new_start
      header_index = index
      parsed[#parsed + 1] = {
        index = index,
        is_header = true,
        header_index = index,
      }
    else
      local item = {
        index = index,
        is_header = false,
        header_index = header_index,
      }
      local first = type(text) == "string" and text:sub(1, 1) or ""
      if type(old_line) == "number" and type(new_line) == "number" then
        if first == "-" and text:sub(1, 3) ~= "---" then
          item.old_line = old_line
          old_line = old_line + 1
        elseif first == "+" and text:sub(1, 3) ~= "+++" then
          item.new_line = new_line
          new_line = new_line + 1
        else
          item.old_line = old_line
          item.new_line = new_line
          old_line = old_line + 1
          new_line = new_line + 1
        end
      end
      parsed[#parsed + 1] = item
    end
  end

  return parsed
end

local function best_focus_index(parsed, side, line_number)
  if type(line_number) ~= "number" or line_number < 1 then
    return nil
  end
  local best_index = nil
  local best_distance = nil
  for _, item in ipairs(parsed) do
    if item.is_header ~= true then
      local candidate_line = side == "base" and item.old_line or item.new_line
      if type(candidate_line) == "number" then
        local distance = math.abs(candidate_line - line_number)
        if best_distance == nil or distance < best_distance then
          best_distance = distance
          best_index = item.index
        end
      end
    end
  end
  return best_index
end

local function pick_thread_focus_index(parsed, thread)
  local primary_side = utils.safe_string(thread.side, "head")
  if primary_side ~= "base" then
    primary_side = "head"
  end

  local head_line = tonumber(thread.line)
  local base_line = tonumber(thread.original_line)
  local primary_line = primary_side == "base" and base_line or head_line
  local focus_index = best_focus_index(parsed, primary_side, primary_line)
  if focus_index then
    return focus_index
  end

  local secondary_side = primary_side == "base" and "head" or "base"
  local secondary_line = secondary_side == "base" and base_line or head_line
  focus_index = best_focus_index(parsed, secondary_side, secondary_line)
  if focus_index then
    return focus_index
  end

  for _, item in ipairs(parsed) do
    if item.is_header ~= true then
      return item.index
    end
  end
  return nil
end

local function trim_diff_hunk(thread, diff_hunk, context_before, context_after)
  local source_lines = utils.split_lines(diff_hunk)
  if vim.tbl_isempty(source_lines) then
    return {}
  end

  local parsed = parse_diff_hunk_lines(source_lines)
  local focus_index = pick_thread_focus_index(parsed, thread)
  if type(focus_index) ~= "number" then
    return source_lines
  end

  local start_index = math.max(1, focus_index - context_before)
  local end_index = math.min(#source_lines, focus_index + context_after)
  local result = {}

  if start_index > 1 then
    result[#result + 1] = string.format("... (%d lines trimmed above)", start_index - 1)
  end
  for index = start_index, end_index do
    result[#result + 1] = source_lines[index]
  end
  if end_index < #source_lines then
    result[#result + 1] = string.format("... (%d lines trimmed below)", #source_lines - end_index)
  end
  return result
end

local function thread_default_expanded(thread)
  return not (thread.is_resolved == true or thread.is_outdated == true)
end

local function thread_expanded(session, thread)
  local thread_id = utils.safe_string(thread.id, "")
  if thread_id == "" then
    return thread_default_expanded(thread)
  end
  local folds = type(session.activity_folds) == "table" and session.activity_folds or {}
  local override = folds[thread_id]
  if type(override) == "boolean" then
    return override
  end
  return thread_default_expanded(thread)
end

local function normalized_side(value)
  local side = utils.safe_string(value, "head")
  side = side:lower()
  if side == "left" or side == "base" then
    return "base"
  end
  return "head"
end

local function positive_line(first, second)
  local line = tonumber(first)
  if type(line) == "number" and line > 0 then
    return line
  end
  line = tonumber(second)
  if type(line) == "number" and line > 0 then
    return line
  end
  return nil
end

local function build_thread_popup_comments(thread)
  local result = {}
  local comments = type(thread) == "table" and type(thread.comments) == "table" and thread.comments or {}
  for index, comment in ipairs(comments) do
    if type(comment) == "table" then
      result[#result + 1] = {
        id = utils.safe_string(comment.id, tostring(index)),
        author = utils.safe_string(comment.author, "unknown"),
        created_at = utils.safe_string(comment.created_at, ""),
        body = utils.safe_string(comment.body, ""),
        url = utils.safe_string(comment.url, ""),
        state = utils.safe_string(comment.state, ""),
        outdated = comment.outdated == true,
      }
    end
  end
  return result
end

local function open_location_action(thread, event)
  local path = utils.safe_string(type(event) == "table" and event.path or thread.path, "")
  if path == "" then
    return nil
  end
  local line = positive_line(type(event) == "table" and event.line or thread.line, thread.line)
  local original_line = positive_line(type(event) == "table" and event.original_line or thread.original_line, thread.original_line)
  if type(line) ~= "number" then
    line = original_line
  end
  if type(original_line) ~= "number" then
    original_line = line
  end
  if type(line) ~= "number" then
    return nil
  end

  local comments = build_thread_popup_comments(thread)
  local selected_comment_id = utils.safe_string(type(event) == "table" and event.id or "", "")
  local target = {
    path = path,
    side = normalized_side(type(event) == "table" and event.side or thread.side),
    line = line,
    original_line = original_line,
    thread_id = utils.safe_string(thread.id, ""),
    thread_is_resolved = thread.is_resolved == true,
    thread_is_outdated = thread.is_outdated == true,
  }
  if not vim.tbl_isempty(comments) then
    target.thread_comments = comments
    if selected_comment_id ~= "" then
      target.selected_comment_id = selected_comment_id
    end
  end

  return {
    kind = "location",
    target = target,
    fallback_url = type(event) == "table" and event.url or nil,
  }
end

local function thread_comment_evolution_diff_action(session, thread, comment)
  if type(comment) ~= "table" then
    return nil
  end

  local location_action = open_location_action(thread, comment)
  if type(location_action) ~= "table" or type(location_action.target) ~= "table" then
    return nil
  end

  local payload = {
    pr_number = tonumber(session.model and session.model.number) or 0,
    path = location_action.target.path,
    side = location_action.target.side,
    line = location_action.target.line,
    original_line = location_action.target.original_line,
    comment_commit_oid = utils.safe_string(comment.commit_oid, ""),
    comment_original_commit_oid = utils.safe_string(comment.original_commit_oid, ""),
    fallback_target = location_action.target,
  }

  return {
    kind = "thread_comment_evolution_diff",
    payload = payload,
    fallback_url = utils.safe_string(comment.url, ""),
  }
end

local function event_action(event)
  if event.kind == "commit" then
    local commit = type(event.commit) == "table" and event.commit or {
      oid = event.oid,
      oid_short = event.oid_short,
      headline = event.headline,
      url = event.url,
      author = event.author,
      committed_at = event.created_at,
    }
    return {
      kind = "commit",
      commit = commit,
    }
  end

  if event.kind == "thread_comment" then
    local target = type(event.target) == "table" and event.target or nil
    if target then
      return {
        kind = "location",
        target = {
          path = target.path,
          side = target.side,
          line = target.line,
          original_line = target.original_line,
        },
        fallback_url = event.url,
      }
    end
  end

  local url = utils.safe_string(event.url, "")
  if url ~= "" then
    return {
      kind = "url",
      url = url,
    }
  end
  return nil
end

local function activity_event_title(event, date_format)
  local kind = utils.safe_string(event.kind, "comment")
  local author = utils.safe_string(event.author, "unknown")
  local when = utils.format_time(event.created_at, date_format)
  if kind == "review" then
    local state = utils.safe_string(event.state, "COMMENTED")
    return string.format("### Review `%s` | @%s | %s", state, author, when)
  end
  if kind == "commit" then
    local oid = utils.safe_string(event.oid_short, "")
    if oid == "" then
      oid = utils.safe_string(event.oid, ""):sub(1, 8)
    end
    if oid == "" then
      oid = "--------"
    end
    return string.format("### Commit `%s` | @%s | %s", oid, author, when)
  end
  if kind == "pr_change" then
    local summary = utils.safe_string(event.change_summary, "PR updated")
    return string.format("### %s | @%s | %s", summary, author, when)
  end
  return string.format("### Comment | @%s | %s", author, when)
end

local function append_limited_body(payload, body, max_lines, indent)
  local lines = utils.split_lines(utils.safe_string(body, ""))
  if vim.tbl_isempty(lines) then
    add_line(payload, indent .. "(no text)", "GhPrOverviewMuted")
    return
  end
  local total = #lines
  local limit = math.min(total, max_lines)
  for index = 1, limit do
    local value = vim.trim(lines[index])
    if value == "" then
      value = " "
    end
    add_line(payload, indent .. value)
  end
  if total > limit then
    add_line(payload, indent .. string.format("... (%d more lines)", total - limit), "GhPrOverviewMuted")
  end
end

local function render_summary(session)
  local payload = new_payload()
  local model = session.model or {}
  local summary = model.summary or {}
  local title = utils.safe_string(model.title, "(untitled)")
  local author = utils.safe_string(summary.author, "unknown")
  local keymaps = type(session.keymaps) == "table" and session.keymaps or {}

  add_line(payload, string.format("# PR #%d", tonumber(model.number) or 0), "GhPrOverviewHeading")
  add_line(payload, title, "GhPrOverviewTitle")
  add_line(
    payload,
    string.format(
      "Commands: `%s/%s` panes | `%s` summary | `%s` activity | `%s` collab | `<CR>` open | `%s` help",
      utils.safe_string(keymaps.cycle_next, "<Tab>"),
      utils.safe_string(keymaps.cycle_prev, "<S-Tab>"),
      utils.safe_string(keymaps.focus_summary, "g1"),
      utils.safe_string(keymaps.focus_activity, "g2"),
      utils.safe_string(keymaps.focus_meta, "g3"),
      utils.safe_string(keymaps.help, "?")
    ),
    "GhPrOverviewMuted"
  )
  add_line(payload, "")

  local state_text = styles.state_text(summary)
  local state_line = string.format(
    "State: `%s` | Review: `%s` | Author: @%s",
    state_text,
    utils.safe_string(summary.review_decision, "REVIEW_REQUIRED"),
    author
  )
  local state_row = add_line(payload, state_line)
  local state_token = "`" .. state_text .. "`"
  local start_col = state_line:find(state_token, 1, true)
  if start_col then
    add_span(payload, state_row, start_col - 1, start_col - 1 + #state_token, styles.state_highlight(summary, session.theme))
  end

  add_line(
    payload,
    string.format(
      "Branches: `%s` -> `%s`",
      utils.safe_string(summary.head_ref, "?"),
      utils.safe_string(summary.base_ref, "?")
    ),
    "GhPrOverviewBranch"
  )
  add_line(
    payload,
    string.format(
      "Stats: +%d -%d | %d files changed",
      tonumber(summary.additions) or 0,
      tonumber(summary.deletions) or 0,
      tonumber(summary.files_changed) or 0
    )
  )
  add_line(
    payload,
    string.format(
      "Updated: %s",
      utils.format_time(summary.updated_at, session.date_format)
    ),
    "GhPrOverviewMuted"
  )
  add_line(payload, "")

  add_line(payload, "## Quick Actions", "GhPrOverviewHeading")
  add_line(payload, "- Approve review (`a`)")
  add_line(payload, "- Request changes (`d`)")
  add_line(payload, "- Comment review (`c`)")
  add_line(payload, "- Merge (`m`) | Checkout (`k`)")
  add_line(payload, "- Open PR in browser (`b`)", nil, { kind = "open_url" })
  add_line(payload, "- Open comments tree (`C`)", nil, { kind = "open_comments_tree" })
  add_line(payload, "- Refresh (`R`)", nil, { kind = "refresh" })
  add_line(payload, "")

  add_line(payload, "## Description", "GhPrOverviewHeading")
  local description_lines = utils.split_lines(utils.safe_string(model.description, ""))
  if vim.tbl_isempty(description_lines) then
    add_line(payload, "(no pull request description)", "GhPrOverviewMuted")
  else
    for _, line in ipairs(description_lines) do
      add_line(payload, line)
    end
  end

  return payload
end

local function render_activity_thread(session, payload, thread)
  local expanded = thread_expanded(session, thread)
  local prefix = expanded and "### [open]" or "### [closed]"
  local flags = {}
  if thread.is_resolved then
    flags[#flags + 1] = "resolved"
  end
  if thread.is_outdated then
    flags[#flags + 1] = "outdated"
  end

  local location = utils.safe_string(thread.path, "(unknown path)")
  if tonumber(thread.line) and thread.line > 0 then
    location = string.format("%s:%d", location, thread.line)
  end
  if not vim.tbl_isempty(flags) then
    location = location .. " [" .. table.concat(flags, ", ") .. "]"
  end

  add_line(payload, string.format("%s Thread | %s", prefix, location), "GhPrOverviewTimelineThread", {
    kind = "toggle_activity_thread",
    thread_id = thread.id,
    expanded = expanded,
    default_expanded = thread_default_expanded(thread),
  })

  if not expanded then
    add_line(payload, "")
    return
  end

  local open_action = open_location_action(thread)
  if open_action then
    add_line(payload, "- Open commented location", nil, open_action)
  end

  local before = tonumber(session.thread_snippet and session.thread_snippet.context_before) or 5
  local after = tonumber(session.thread_snippet and session.thread_snippet.context_after) or 5
  if session.activity.show_code_context ~= false then
    local snippet = trim_diff_hunk(thread, utils.safe_string(thread.diff_hunk, ""), before, after)
    if not vim.tbl_isempty(snippet) then
      add_line(payload, "")
      add_line(payload, "```diff")
      for _, line in ipairs(snippet) do
        add_line(payload, line)
      end
      add_line(payload, "```")
    end
  end

  add_line(payload, "")
  for index, comment in ipairs(thread.comments) do
    local level = index == 1 and 1 or 2
    local indent = level == 1 and "  " or "    "
    local marker = level == 1 and "-" or "->"
    local author = utils.safe_string(comment.author, "unknown")
    local when = utils.format_time(comment.created_at, session.date_format)
    local action = open_location_action(thread, comment)
    if not action then
      action = event_action(comment)
    end
    local evolution_action = thread_comment_evolution_diff_action(session, thread, comment)
    add_line(payload, string.format("%s%s @%s | %s", indent, marker, author, when), nil, action)
    append_limited_body(payload, comment.body, session.activity.max_body_lines, indent .. "  ")
    if type(evolution_action) == "table" then
      add_line(payload, string.format("%s  ↪ View evolution diff", indent), "GhPrOverviewActionKey", evolution_action)
    end
    add_line(payload, "")
  end
end

local function render_activity_event(session, payload, event)
  local title = activity_event_title(event, session.date_format)
  local highlight = styles.timeline_highlight(event, session.theme)
  add_line(payload, title, highlight, event_action(event))

  if event.kind == "commit" then
    local headline = utils.safe_string(type(event.commit) == "table" and event.commit.headline or event.headline, "")
    if headline ~= "" then
      add_line(payload, headline)
    end
    local body = utils.safe_string(type(event.commit) == "table" and event.commit.body or "", "")
    if body ~= "" then
      append_limited_body(payload, body, session.activity.max_body_lines, "")
    end
  else
    local body = utils.safe_string(event.body, "")
    append_limited_body(payload, body, session.activity.max_body_lines, "")
  end

  add_line(payload, "")
end

local function render_activity(session)
  local payload = new_payload()
  local entries = build_activity_entries(session)
  local visible_total = visible_timeline_total(session)
  local shown = #entries
  add_line(payload, "# Activity", "GhPrOverviewHeading")
  add_line(payload, string.format("Showing %d of %d events", shown, visible_total), "GhPrOverviewMuted")
  add_line(payload, "")

  if vim.tbl_isempty(entries) then
    add_line(payload, "(no activity to display with current filters)", "GhPrOverviewMuted")
    return payload
  end

  for _, entry in ipairs(entries) do
    if entry.kind == "thread" then
      render_activity_thread(session, payload, entry.thread)
    else
      render_activity_event(session, payload, entry.event)
    end
  end

  local shown_events = #filtered_timeline_events(session)
  if visible_total > shown_events then
    add_line(payload, "Load more activity (`gr`)", "GhPrOverviewActionText", {
      kind = "more_section",
      section = "timeline",
    })
  end

  return payload
end

local function render_meta(session)
  local payload = new_payload()
  local model = session.model or {}
  local summary = model.summary or {}
  local people = model.people or {}

  add_line(payload, "# Collaboration", "GhPrOverviewHeading")
  add_line(payload, "")
  add_line(payload, "## Review", "GhPrOverviewHeading")
  local review_line = string.format("Decision: `%s`", utils.safe_string(summary.review_decision, "REVIEW_REQUIRED"))
  local review_row = add_line(payload, review_line)
  local review_decision = utils.safe_string(summary.review_decision, "REVIEW_REQUIRED")
  local review_token = "`" .. review_decision .. "`"
  local review_start = review_line:find(review_token, 1, true)
  if review_start then
    add_span(
      payload,
      review_row,
      review_start - 1,
      review_start - 1 + #review_token,
      styles.review_highlight(review_decision, session.theme)
    )
  end
  add_line(payload, string.format("Merge state: `%s`", utils.safe_string(summary.merge_state, "unknown")))
  add_line(payload, string.format("Mergeable: `%s`", utils.safe_string(summary.mergeable, "unknown")))
  add_line(payload, "")

  add_line(payload, "## Reviewers (`er`)", "GhPrOverviewHeading")
  local reviewers = type(people.review_requests) == "table" and people.review_requests or {}
  if vim.tbl_isempty(reviewers) then
    add_line(payload, "- (none)", "GhPrOverviewMuted")
  else
    for _, reviewer in ipairs(reviewers) do
      add_line(payload, "- @" .. utils.safe_string(reviewer, "unknown"), "GhPrOverviewReviewer")
    end
  end
  add_line(payload, "")

  add_line(payload, "## Assignees (`ea`)", "GhPrOverviewHeading")
  local assignees = type(people.assignees) == "table" and people.assignees or {}
  if vim.tbl_isempty(assignees) then
    add_line(payload, "- (none)", "GhPrOverviewMuted")
  else
    for _, assignee in ipairs(assignees) do
      add_line(payload, "- @" .. utils.safe_string(assignee, "unknown"), "GhPrOverviewAssignee")
    end
  end
  add_line(payload, "")

  add_line(payload, "## Labels (`el`)", "GhPrOverviewHeading")
  local labels = type(model.labels) == "table" and type(model.labels.items) == "table" and model.labels.items or {}
  if vim.tbl_isempty(labels) then
    add_line(payload, "- (none)", "GhPrOverviewMuted")
  else
    for _, label in ipairs(labels) do
      local name = utils.safe_string(label.name, "label")
      local line = "- [" .. name .. "]"
      local row = add_line(payload, line)
      local highlight = session.theme.labels ~= false and styles.ensure_label_highlight(utils.safe_string(label.color, "")) or "GhPrOverviewBadge"
      add_span(payload, row, 2, 3 + #name, highlight)
    end
  end
  add_line(payload, "")

  add_line(payload, "## Milestone (`em`)", "GhPrOverviewHeading")
  local milestone = utils.safe_string(summary.milestone, "")
  if milestone == "" then
    add_line(payload, "- (none)", "GhPrOverviewMuted")
  else
    add_line(payload, "- " .. milestone, "GhPrOverviewBadge")
  end
  add_line(payload, "")

  add_line(payload, "## Edits", "GhPrOverviewHeading")
  add_line(payload, "- Edit title (`et`)", nil, { kind = "edit_stub", edit_kind = "edit_title", payload = { current = model.title } })
  add_line(
    payload,
    "- Edit description (`eb`)",
    nil,
    { kind = "edit_stub", edit_kind = "edit_body", payload = { current = model.description } }
  )
  add_line(payload, "- Edit labels (`el`)", nil, { kind = "edit_stub", edit_kind = "edit_labels", payload = {} })
  add_line(payload, "- Edit reviewers (`er`)", nil, { kind = "edit_stub", edit_kind = "edit_reviewers", payload = {} })
  add_line(payload, "- Edit assignees (`ea`)", nil, { kind = "edit_stub", edit_kind = "edit_assignees", payload = {} })
  add_line(
    payload,
    "- Edit milestone (`em`)",
    nil,
    { kind = "edit_stub", edit_kind = "edit_milestone", payload = { current = milestone } }
  )
  add_line(
    payload,
    "- Change state (`es`)",
    nil,
    { kind = "edit_stub", edit_kind = "change_state", payload = { current = utils.safe_string(summary.state, "") } }
  )
  add_line(
    payload,
    "- Toggle draft (`ed`)",
    nil,
    {
      kind = "edit_stub",
      edit_kind = "change_draft",
      payload = { current = summary.is_draft == true and "draft" or "ready" },
    }
  )
  add_line(payload, "")

  add_line(payload, "## Commits", "GhPrOverviewHeading")
  local commits = type(model.commits) == "table" and type(model.commits.items) == "table" and model.commits.items or {}
  if vim.tbl_isempty(commits) then
    add_line(payload, "- (none)", "GhPrOverviewMuted")
  else
    for _, commit in ipairs(commits) do
      local oid = utils.safe_string(commit.oid_short, "")
      if oid == "" then
        oid = utils.safe_string(commit.oid, ""):sub(1, 8)
      end
      if oid == "" then
        oid = "--------"
      end
      local text = string.format("- `%s` %s", oid, utils.safe_string(commit.headline, "(no headline)"))
      add_line(payload, text, nil, {
        kind = "commit",
        commit = commit,
      })
    end
  end

  return payload
end

function M.render(session)
  return {
    summary = render_summary(session),
    activity = render_activity(session),
    meta = render_meta(session),
  }
end

return M
