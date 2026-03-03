local runtime_state = require("gh-pr.state")
local markdown = require("gh-pr.overview_markdown")
local utils = require("gh-pr.overview_utils")
local styles = require("gh-pr.overview_styles")

local M = {}

M.TAB_DEFS = {
  summary = { label = "Summary" },
  checks = { label = "Checks", section = "checks" },
  commits = { label = "Commits", section = "commits" },
  files = { label = "Files" },
}

M.DEFAULT_TABS = { "summary", "checks", "commits", "files" }
M.TAB_ALIASES = {
  timeline = "summary",
  comments = "summary",
  reviews = "summary",
  threads = "summary",
}

local function file_action(file)
  return {
    kind = "file",
    file = {
      path = file.path,
      filename = file.filename,
      previousFilename = file.previous_filename,
      status = file.status,
      additions = file.additions,
      deletions = file.deletions,
    },
  }
end

local function commit_action(commit)
  return {
    kind = "commit",
    commit = {
      oid = commit.oid,
      oid_short = commit.oid_short,
      headline = commit.headline,
      url = commit.url,
      author = commit.author,
      committed_at = commit.committed_at,
    },
  }
end

local function timeline_action(item)
  if item.kind == "commit" then
    local commit = type(item.commit) == "table" and item.commit or item
    return commit_action(commit)
  end

  if item.kind == "thread_comment" and type(item.target) == "table" then
    return {
      kind = "location",
      target = {
        path = item.target.path,
        side = item.target.side,
        line = item.target.line,
        original_line = item.target.original_line,
      },
      fallback_url = item.url,
    }
  end

  return {
    kind = "url",
    url = item.url,
  }
end

local function summary_action(kind, payload)
  return {
    kind = "edit_stub",
    edit_kind = kind,
    payload = payload or {},
  }
end

function M.tab_index(view, tab_name)
  for index, name in ipairs(view.tabs) do
    if name == tab_name then
      return index
    end
  end
  return 1
end

function M.tab_count(model, tab_name)
  if tab_name == "checks" then
    return tonumber(model.checks and model.checks.total) or 0
  end
  if tab_name == "commits" then
    return tonumber(model.commits and model.commits.total) or 0
  end
  if tab_name == "timeline" then
    return tonumber(model.timeline and model.timeline.total) or 0
  end
  if tab_name == "files" then
    return tonumber(model.files and model.files.total) or 0
  end
  return nil
end

local function map_token_span(spans, text, token, group)
  if type(token) ~= "string" or token == "" then
    return
  end
  local start_idx = text:find(token, 1, true)
  if not start_idx then
    return
  end
  spans[#spans + 1] = {
    line = 1,
    start_col = start_idx - 1,
    end_col = (start_idx - 1) + #token,
    group = group,
  }
end

local function build_chip_line(prefix, values, opts)
  opts = opts or {}
  local line = prefix
  local spans = {}

  if type(values) ~= "table" or vim.tbl_isempty(values) then
    line = line .. "(none)"
    spans[#spans + 1] = {
      line = 1,
      start_col = #prefix,
      end_col = -1,
      group = "GhPrOverviewMuted",
    }
    return line, spans
  end

  local separator = ""
  for _, value in ipairs(values) do
    local name = opts.resolve_name and opts.resolve_name(value) or utils.safe_string(value, "")
    if name ~= "" then
      line = line .. separator
      local token = "[" .. name .. "]"
      local start_col = #line
      line = line .. token
      local highlight = opts.resolve_group and opts.resolve_group(value) or "GhPrOverviewBadge"
      spans[#spans + 1] = {
        line = 1,
        start_col = start_col,
        end_col = start_col + #token,
        group = highlight,
      }
      separator = " "
    end
  end

  if line == prefix then
    line = line .. "(none)"
    spans[#spans + 1] = {
      line = 1,
      start_col = #prefix,
      end_col = -1,
      group = "GhPrOverviewMuted",
    }
  end

  return line, spans
end

local function overview_show_flags(view)
  return type(view.show) == "table" and view.show or {}
end

local function timeline_kind_enabled(view, kind)
  local show = overview_show_flags(view)
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

local function timeline_event_is_visible(view, event)
  local kind = utils.safe_string(type(event) == "table" and event.kind or "", "")
  if kind == "" then
    return false
  end
  return timeline_kind_enabled(view, kind)
end

local function filtered_timeline_events(view)
  local events = {}
  for _, event in ipairs(view.model.timeline and view.model.timeline.items or {}) do
    if timeline_event_is_visible(view, event) then
      events[#events + 1] = event
    end
  end
  return events
end

local function visible_timeline_total(view)
  local model = view.model or {}
  local total = 0
  if timeline_kind_enabled(view, "comment") then
    total = total + (tonumber(model.comments and model.comments.total) or 0)
  end
  if timeline_kind_enabled(view, "review") then
    total = total + (tonumber(model.reviews and model.reviews.total) or 0)
  end
  if timeline_kind_enabled(view, "thread_comment") then
    total = total + (tonumber(model.threads and model.threads.total) or 0)
  end
  if timeline_kind_enabled(view, "commit") then
    total = total + (tonumber(model.commits and model.commits.total) or 0)
  end
  if timeline_kind_enabled(view, "pr_change") then
    total = total + (tonumber(model.pr_changes and model.pr_changes.total) or 0)
  end
  return total
end

local function summary_activity_enabled(view)
  return timeline_kind_enabled(view, "comment")
    or timeline_kind_enabled(view, "review")
    or timeline_kind_enabled(view, "thread_comment")
    or timeline_kind_enabled(view, "commit")
    or timeline_kind_enabled(view, "pr_change")
end

local function markdown_github_style_enabled(view)
  local markdown_opts = type(view) == "table" and type(view.markdown) == "table" and view.markdown or {}
  return markdown_opts.github_style ~= false
end

local function markdown_separator_style(view)
  local markdown_opts = type(view) == "table" and type(view.markdown) == "table" and view.markdown or {}
  local style = utils.safe_string(markdown_opts.github_style_separators, "rules"):lower()
  if style ~= "rules" then
    style = "rules"
  end
  return style
end

local function markdown_diff_gutter_mode(view)
  local markdown_opts = type(view) == "table" and type(view.markdown) == "table" and view.markdown or {}
  local mode = utils.safe_string(markdown_opts.diff_gutter, "none"):lower()
  if mode ~= "old_new_code" and mode ~= "none" then
    mode = "none"
  end
  if mode == "old_new_code" then
    mode = "none"
  end
  return mode
end

local function event_url_action(url)
  local value = utils.safe_string(url, "")
  if value == "" then
    return nil
  end
  return {
    kind = "url",
    url = value,
  }
end

local function thread_group_key(event, index)
  local thread_id = utils.safe_string(event.thread_id, "")
  if thread_id ~= "" then
    return thread_id
  end
  local path = utils.safe_string(event.path, "unknown")
  local line = tonumber(event.line) or tonumber(event.original_line) or 0
  return string.format("fallback:%s:%d:%d", path, line, tonumber(index) or 0)
end

local function build_activity_entries(view)
  local entries = {}
  local thread_groups = {}
  local filtered = filtered_timeline_events(view)

  for index, event in ipairs(filtered) do
    local kind = utils.safe_string(event.kind, "")
    if kind == "thread_comment" then
      local key = thread_group_key(event, index)
      local group = thread_groups[key]
      if not group then
        group = {
          id = key,
          comments = {},
          path = utils.safe_string(event.path, "(unknown path)"),
          line = tonumber(event.line) or 0,
          original_line = tonumber(event.original_line) or 0,
          side = utils.safe_string(event.side, ""),
          is_resolved = event.is_resolved == true,
          is_outdated = event.is_outdated == true,
          diff_hunk = utils.safe_string(event.diff_hunk, ""),
          anchor_event = event,
        }
        thread_groups[key] = group
        entries[#entries + 1] = {
          kind = "thread",
          thread = group,
        }
      end

      group.comments[#group.comments + 1] = event
      if group.diff_hunk == "" then
        group.diff_hunk = utils.safe_string(event.diff_hunk, "")
      end
      local event_path = utils.safe_string(event.path, "")
      if group.path == "(unknown path)" and event_path ~= "" then
        group.path = event_path
      end
      local event_line = tonumber(event.line) or 0
      if group.line < 1 and event_line > 0 then
        group.line = event_line
      end
      local event_original_line = tonumber(event.original_line) or 0
      if group.original_line < 1 and event_original_line > 0 then
        group.original_line = event_original_line
      end
      if group.side == "" then
        group.side = utils.safe_string(event.side, "")
      end
      if event.is_resolved == true then
        group.is_resolved = true
      end
      if event.is_outdated == true then
        group.is_outdated = true
      end
    else
      entries[#entries + 1] = {
        kind = "event",
        event = event,
      }
    end
  end

  return entries, #filtered
end

local function timeline_item_location_text(path, line, is_resolved, is_outdated)
  local where = utils.safe_string(path, "(unknown path)")
  if tonumber(line) and tonumber(line) > 0 then
    where = string.format("%s:%d", where, line)
  end

  local flags = {}
  if is_resolved then
    flags[#flags + 1] = "resolved"
  end
  if is_outdated then
    flags[#flags + 1] = "outdated"
  end
  if not vim.tbl_isempty(flags) then
    where = where .. " [" .. table.concat(flags, ", ") .. "]"
  end

  return where
end

local function build_activity_event_item(event, date_format, theme, markdown_style)
  local kind = utils.safe_string(event.kind, "comment")
  local author = utils.safe_string(event.author, "unknown")
  local timestamp = utils.format_time(event.created_at, date_format)
  local lines = {}
  local highlight = styles.timeline_highlight(event, theme)
  local action = event_url_action(event.url)
  local append_body = true

  if kind == "review" then
    local state = utils.safe_string(event.state, "COMMENTED")
    if markdown_style then
      lines[#lines + 1] = string.format("### Review `%s` · @%s · %s", state, author, timestamp)
    else
      lines[#lines + 1] = string.format("Review %s by @%s on %s", state, author, timestamp)
    end
    if state == "APPROVED" then
      highlight = "GhPrOverviewReviewApproved"
    elseif state == "CHANGES_REQUESTED" then
      highlight = "GhPrOverviewReviewChanges"
    end
    if utils.safe_string(event.commit_oid, "") ~= "" then
      lines[#lines + 1] = "Commit: " .. event.commit_oid:sub(1, 8)
    end
  elseif kind == "commit" then
    local commit = type(event.commit) == "table" and event.commit or event
    local oid_short = utils.safe_string(commit.oid_short, "")
    if oid_short == "" then
      oid_short = utils.safe_string(commit.oid, "")
      if oid_short ~= "" then
        oid_short = oid_short:sub(1, 8)
      end
    end
    if oid_short == "" then
      oid_short = "--------"
    end
    if markdown_style then
      lines[#lines + 1] = string.format("### Commit `%s` · @%s · %s", oid_short, author, timestamp)
    else
      lines[#lines + 1] = string.format("Commit %s by @%s on %s", oid_short, author, timestamp)
    end
    local headline = utils.safe_string(commit.headline, "(no commit headline)")
    lines[#lines + 1] = headline
    local preview = utils.first_non_empty_line(utils.safe_string(commit.body, ""), "")
    if preview ~= "" and preview ~= headline then
      lines[#lines + 1] = preview
    end
    action = commit_action(commit)
    append_body = false
  elseif kind == "pr_change" then
    local summary = utils.safe_string(event.change_summary, "")
    local details = utils.safe_string(event.change_details, "")
    local change_type = utils.safe_string(event.change_type, "updated")
    local title_map = {
      labeled = "Label Added",
      unlabeled = "Label Removed",
      assigned = "Assignee Added",
      unassigned = "Assignee Removed",
      review_requested = "Review Requested",
      review_request_removed = "Review Request Removed",
      renamed_title = "Title Updated",
      base_ref_changed = "Base Branch Changed",
      head_ref_force_pushed = "Force Push",
      ready_for_review = "Marked Ready",
      converted_to_draft = "Converted To Draft",
      closed = "Closed",
      reopened = "Reopened",
      merged = "Merged",
      milestoned = "Milestone Added",
      demilestoned = "Milestone Removed",
      updated = "PR Updated",
    }
    local title = title_map[change_type] or "PR Updated"
    if markdown_style then
      lines[#lines + 1] = string.format("### %s · @%s · %s", title, author, timestamp)
    else
      lines[#lines + 1] = string.format("%s by @%s on %s", title, author, timestamp)
    end
    if summary ~= "" then
      lines[#lines + 1] = summary
    end
    if details ~= "" then
      lines[#lines + 1] = details
    end
    append_body = false
  else
    if markdown_style then
      lines[#lines + 1] = string.format("### Comment · @%s · %s", author, timestamp)
    else
      lines[#lines + 1] = string.format("Comment by @%s on %s", author, timestamp)
    end
  end

  if append_body then
    local body_lines = utils.split_lines(utils.safe_string(event.body, ""))
    if vim.tbl_isempty(body_lines) then
      body_lines = { "(no text)" }
    end
    for _, line in ipairs(body_lines) do
      lines[#lines + 1] = line
    end
  end

  return {
    lines = lines,
    hl = highlight,
    action = action,
    markdown_block = markdown_style,
    trailing_blank = markdown_style ~= true,
  }
end

local function thread_default_expanded(thread)
  if type(thread) ~= "table" then
    return true
  end
  return not (thread.is_resolved == true or thread.is_outdated == true)
end

local function thread_is_expanded(view, thread)
  local thread_id = type(thread) == "table" and utils.safe_string(thread.id, "") or ""
  if thread_id == "" then
    return thread_default_expanded(thread)
  end

  local folds = type(view.activity_folds) == "table" and view.activity_folds or {}
  local override = folds[thread_id]
  if type(override) == "boolean" then
    return override
  end

  return thread_default_expanded(thread)
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
  local current_header = nil
  local old_line = nil
  local new_line = nil

  for index, text in ipairs(lines) do
    local old_start, new_start = parse_hunk_header(text)
    if old_start and new_start then
      current_header = index
      old_line = old_start
      new_line = new_start
      parsed[#parsed + 1] = {
        index = index,
        is_header = true,
        header_index = index,
      }
    else
      local item = {
        index = index,
        is_header = false,
        header_index = current_header,
      }

      if type(old_line) == "number" and type(new_line) == "number" then
        local prefix = type(text) == "string" and text:sub(1, 1) or ""
        if prefix == "-" and text:sub(1, 3) ~= "---" then
          item.old_line = old_line
          old_line = old_line + 1
        elseif prefix == "+" and text:sub(1, 3) ~= "+++" then
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

local function build_diff_entries_from_lines(lines)
  local source = type(lines) == "table" and lines or {}
  local parsed = parse_diff_hunk_lines(source)
  local entries = {}

  for index, text in ipairs(source) do
    local parsed_item = parsed[index] or {}
    entries[#entries + 1] = {
      text = utils.safe_string(text, ""),
      old_line = parsed_item.old_line,
      new_line = parsed_item.new_line,
      is_header = parsed_item.is_header == true,
    }
  end

  return entries
end

local function diff_entries_to_plain_lines(entries)
  local lines = {}
  for _, entry in ipairs(type(entries) == "table" and entries or {}) do
    lines[#lines + 1] = utils.safe_string(type(entry) == "table" and entry.text or entry, "")
  end
  return lines
end

local function diff_markdown_lines(view, lines, entries)
  local normalized_entries = type(entries) == "table" and entries or build_diff_entries_from_lines(lines)
  local _ = markdown_diff_gutter_mode(view) -- deprecated, kept for backward-compatible option parsing
  return diff_entries_to_plain_lines(normalized_entries)
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
          best_index = item.index
          best_distance = distance
          if distance == 0 then
            break
          end
        end
      end
    end
  end

  return best_index
end

local function pick_thread_focus_index(parsed, thread)
  local primary_side = utils.safe_string(type(thread) == "table" and thread.side or "", "head")
  if primary_side ~= "base" then
    primary_side = "head"
  end

  local head_line = tonumber(type(thread) == "table" and thread.line or nil)
  local base_line = tonumber(type(thread) == "table" and thread.original_line or nil)
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

  return #parsed > 0 and parsed[1].index or nil
end

local function thread_snippet_context(view)
  local source = type(view) == "table" and type(view.thread_snippet) == "table" and view.thread_snippet or {}
  local before = math.floor(tonumber(source.context_before) or 5)
  local after = math.floor(tonumber(source.context_after) or 5)
  if before < 0 then
    before = 0
  end
  if after < 0 then
    after = 0
  end
  return before, after
end

local function trim_diff_hunk_for_thread(thread, diff_hunk, context_before, context_after)
  local lines = utils.split_lines(diff_hunk)
  if vim.tbl_isempty(lines) then
    return {}
  end

  local parsed = parse_diff_hunk_lines(lines)
  local focus_index = pick_thread_focus_index(parsed, thread)
  if type(focus_index) ~= "number" or focus_index < 1 then
    return build_diff_entries_from_lines(lines)
  end

  local start_index = math.max(1, focus_index - context_before)
  local end_index = math.min(#lines, focus_index + context_after)

  local trimmed = {}
  if start_index > 1 then
    trimmed[#trimmed + 1] = {
      text = string.format("... (%d lines trimmed above)", start_index - 1),
    }
  end
  for index = start_index, end_index do
    local item = parsed[index] or {}
    trimmed[#trimmed + 1] = {
      text = lines[index],
      old_line = item.old_line,
      new_line = item.new_line,
      is_header = item.is_header == true,
    }
  end
  if end_index < #lines then
    trimmed[#trimmed + 1] = {
      text = string.format("... (%d lines trimmed below)", #lines - end_index),
    }
  end

  return trimmed
end

local function build_thread_snippet_item(thread, view)
  local diff_hunk = utils.safe_string(type(thread) == "table" and thread.diff_hunk or "", "")
  local markdown_mode = type(view) == "table"
      and type(view.markdown) == "table"
      and utils.safe_string(view.markdown.mode, "full")
    or "full"
  local context_before, context_after = thread_snippet_context(view)
  local title = markdown_github_style_enabled(view) and "#### Code Context" or "Code context"

  if diff_hunk == "" then
    return {
      lines = {
        title,
        markdown_mode == "full" and "```text" or "(No code context available for this thread)",
        markdown_mode == "full" and "(No code context available for this thread)" or nil,
        markdown_mode == "full" and "```" or nil,
      },
      hl = "GhPrOverviewMuted",
      markdown_block = markdown_mode == "full",
      trailing_blank = false,
    }
  end

  local snippet_entries = trim_diff_hunk_for_thread(thread, diff_hunk, context_before, context_after)
  if vim.tbl_isempty(snippet_entries) then
    snippet_entries = build_diff_entries_from_lines(utils.split_lines(diff_hunk))
  end
  local snippet_lines = diff_markdown_lines(view, nil, snippet_entries)

  if markdown_mode == "full" then
    local lines = { title, "```diff" }
    for _, line in ipairs(snippet_lines) do
      lines[#lines + 1] = line
    end
    lines[#lines + 1] = "```"
    return {
      lines = lines,
      markdown_block = true,
      trailing_blank = false,
    }
  end

  local markdown_text = table.concat({
    title,
    "```diff",
    table.concat(snippet_lines, "\n"),
    "```",
  }, "\n")
  local payload = markdown.render(markdown_text, view.markdown)
  return {
    lines = payload.lines,
    highlights = payload.highlights,
    inline_links = payload.links,
    markdown_block = true,
    trailing_blank = false,
  }
end

local function thread_fix_diff_options(view)
  local source = type(view) == "table" and type(view.thread_fix_diff) == "table" and view.thread_fix_diff or {}
  return {
    enabled = source.enabled ~= false,
    show_action_line = source.show_action_line ~= false,
    inline = source.inline ~= false,
    context_before = math.min(200, math.max(0, math.floor(tonumber(source.context_before) or 5))),
    context_after = math.min(200, math.max(0, math.floor(tonumber(source.context_after) or 5))),
    fallback_to_buffer = source.fallback_to_buffer ~= false,
  }
end

local function thread_fix_diff_state(view, fix_action)
  if type(fix_action) ~= "table" then
    return nil
  end
  if type(view) ~= "table" then
    return nil
  end
  if type(view.thread_fix_inline) ~= "table" then
    return nil
  end

  local key = utils.thread_fix_action_key(fix_action)
  if type(key) ~= "string" or key == "" then
    return nil
  end

  local state = view.thread_fix_inline[key]
  if type(state) ~= "table" then
    return nil
  end
  return state
end

local function build_thread_fix_diff_action(comment, thread, opts)
  opts = type(opts) == "table" and opts or {}
  local scope = utils.safe_string(opts.scope, type(comment) == "table" and "comment" or "thread")
  local path = utils.safe_string(type(comment) == "table" and comment.path or "", "")
  if path == "" then
    path = utils.safe_string(type(thread) == "table" and thread.path or "", "")
  end
  if path == "" then
    return nil
  end

  return {
    kind = "open_thread_fix_diff",
    pr_number = tonumber(opts.pr_number) or nil,
    path = path,
    line = tonumber(type(comment) == "table" and scope == "comment" and comment.line or nil)
      or tonumber(type(thread) == "table" and thread.line or nil)
      or 0,
    original_line = tonumber(type(comment) == "table" and scope == "comment" and comment.original_line or nil)
      or tonumber(type(thread) == "table" and thread.original_line or nil)
      or 0,
    side = utils.safe_string(
      type(comment) == "table" and scope == "comment" and comment.side or "",
      utils.safe_string(type(thread) == "table" and thread.side or "", "head")
    ),
    thread_id = utils.safe_string(type(thread) == "table" and thread.id or "", ""),
    comment_id = scope == "comment" and utils.safe_string(type(comment) == "table" and comment.id or "", "") or "",
    target_scope = scope == "thread" and "thread" or "comment",
    comment_commit_oid = scope == "comment"
        and utils.safe_string(type(comment) == "table" and comment.commit_oid or "", "")
      or "",
    comment_original_commit_oid = scope == "comment"
        and utils.safe_string(type(comment) == "table" and comment.original_commit_oid or "", "")
      or "",
  }
end

local function build_thread_evolution_diff_action(comment, thread, opts)
  opts = type(opts) == "table" and opts or {}
  local scope = utils.safe_string(opts.scope, type(comment) == "table" and "comment" or "thread")
  local path = utils.safe_string(type(comment) == "table" and comment.path or "", "")
  if path == "" then
    path = utils.safe_string(type(thread) == "table" and thread.path or "", "")
  end
  if path == "" then
    return nil
  end

  local side = utils.safe_string(
    type(comment) == "table" and scope == "comment" and comment.side or "",
    utils.safe_string(type(thread) == "table" and thread.side or "", "head")
  )
  local line = tonumber(type(comment) == "table" and scope == "comment" and comment.line or nil)
    or tonumber(type(thread) == "table" and thread.line or nil)
    or 0
  local original_line = tonumber(type(comment) == "table" and scope == "comment" and comment.original_line or nil)
    or tonumber(type(thread) == "table" and thread.original_line or nil)
    or 0
  if line < 1 and original_line > 0 then
    line = original_line
  end
  if original_line < 1 and line > 0 then
    original_line = line
  end

  return {
    kind = "open_thread_comment_evolution_diff",
    pr_number = tonumber(opts.pr_number) or nil,
    path = path,
    line = line,
    original_line = original_line,
    side = side,
    thread_id = utils.safe_string(type(thread) == "table" and thread.id or "", ""),
    comment_id = scope == "comment" and utils.safe_string(type(comment) == "table" and comment.id or "", "") or "",
    comment_commit_oid = scope == "comment"
        and utils.safe_string(type(comment) == "table" and comment.commit_oid or "", "")
      or "",
    comment_original_commit_oid = scope == "comment"
        and utils.safe_string(type(comment) == "table" and comment.original_commit_oid or "", "")
      or "",
    fallback_target = {
      path = path,
      side = side,
      line = line,
      original_line = original_line,
      thread_id = utils.safe_string(type(thread) == "table" and thread.id or "", ""),
      selected_comment_id = scope == "comment" and utils.safe_string(type(comment) == "table" and comment.id or "", "") or "",
      thread_is_resolved = type(thread) == "table" and thread.is_resolved == true,
      thread_is_outdated = type(thread) == "table" and thread.is_outdated == true,
    },
  }
end

local function build_thread_comment_item(comment, date_format, level, fix_action, trailing_blank, markdown_style)
  local normalized_level = utils.clamp(math.floor(tonumber(level) or 0), 0, 2)
  local comment_indent = string.rep("  ", normalized_level)
  local body_indent = comment_indent .. "  "
  local lines = {}
  if markdown_style then
    if normalized_level > 0 then
      lines[#lines + 1] = string.format(
        "##### Reply · @%s · %s",
        utils.safe_string(comment.author, "unknown"),
        utils.format_time(comment.created_at, date_format)
      )
    else
      lines[#lines + 1] = string.format(
        "#### @%s · %s",
        utils.safe_string(comment.author, "unknown"),
        utils.format_time(comment.created_at, date_format)
      )
    end
  else
    lines[#lines + 1] = string.format(
      "%s@%s on %s",
      comment_indent,
      utils.safe_string(comment.author, "unknown"),
      utils.format_time(comment.created_at, date_format)
    )
  end
  local body_lines = utils.split_lines(utils.safe_string(comment.body, ""))
  if vim.tbl_isempty(body_lines) then
    body_lines = { "(no text)" }
  end
  for _, line in ipairs(body_lines) do
    if markdown_style then
      local prefix = normalized_level > 0 and "> " or ""
      lines[#lines + 1] = prefix .. line
    else
      lines[#lines + 1] = body_indent .. line
    end
  end

  local action = event_url_action(comment.url)
  if type(fix_action) == "table" and fix_action.kind == "open_thread_fix_diff" then
    if type(action) == "table" then
      action.thread_fix_action = fix_action
    else
      action = fix_action
    end
  end

  return {
    lines = lines,
    hl = normalized_level > 0 and "GhPrOverviewMuted" or "GhPrOverviewTimelineThread",
    action = action,
    markdown_block = markdown_style == true,
    trailing_blank = trailing_blank == true,
  }
end

local function build_thread_evolution_diff_item(level, action, is_last, markdown_style)
  local normalized_level = utils.clamp(math.floor(tonumber(level) or 0), 0, 2)
  local line_indent = string.rep("  ", normalized_level) .. "  "
  return {
    lines = {
      markdown_style and "- ↪ View evolution diff" or (line_indent .. "↪ View evolution diff"),
    },
    hl = "GhPrOverviewActionKey",
    action = action,
    markdown_block = markdown_style == true,
    trailing_blank = is_last == true,
  }
end

local function build_thread_fix_diff_item(level, fix_action, is_last, fix_state, markdown_style)
  local normalized_level = utils.clamp(math.floor(tonumber(level) or 0), 0, 2)
  local line_indent = string.rep("  ", normalized_level) .. "  "
  local expanded = type(fix_state) == "table" and fix_state.expanded == true
  local loading = expanded and type(fix_state) == "table" and fix_state.status == "loading"
  local label = "↪ View fix diff"
  if loading then
    label = "↪ Loading fix diff..."
  elseif expanded then
    label = "↪ Hide fix diff"
  end
  return {
    lines = {
      markdown_style and ("- " .. label) or (line_indent .. label),
    },
    hl = "GhPrOverviewActionKey",
    action = fix_action,
    markdown_block = markdown_style == true,
    trailing_blank = is_last == true,
  }
end

local function build_thread_fix_diff_inline_item(view, fix_state, is_last)
  local markdown_mode = type(view) == "table"
      and type(view.markdown) == "table"
      and utils.safe_string(view.markdown.mode, "full")
    or "full"
  local commit_oid = utils.safe_string(type(fix_state) == "table" and fix_state.commit_oid or "", "")
  local title = commit_oid ~= "" and ("Fix diff (commit " .. commit_oid:sub(1, 8) .. ")") or "Fix diff"
  if markdown_github_style_enabled(view) then
    title = "#### " .. title
  end
  local status = utils.safe_string(type(fix_state) == "table" and fix_state.status or "", "")
  local lines = {}

  if status == "loading" then
    return {
      lines = {
        title,
        "(Loading latest commit patch...)",
      },
      hl = "GhPrOverviewMuted",
      trailing_blank = is_last == true,
    }
  end

  if status == "fallback" then
    local message = utils.safe_string(type(fix_state) == "table" and fix_state.error or "", "Opened legacy diff buffer fallback")
    return {
      lines = {
        title,
        message,
      },
      hl = "GhPrOverviewMuted",
      trailing_blank = is_last == true,
    }
  end

  if status == "error" then
    local message = utils.safe_string(type(fix_state) == "table" and fix_state.error or "", "Unable to resolve fix diff")
    if markdown_mode == "full" then
      return {
        lines = {
          title,
          "```text",
          message,
          "```",
        },
        hl = "GhPrOverviewMuted",
        markdown_block = true,
        trailing_blank = is_last == true,
      }
    end

    local payload = markdown.render(table.concat({
      title,
      "```text",
      message,
      "```",
    }, "\n"), view.markdown)
    return {
      lines = payload.lines,
      highlights = payload.highlights,
      inline_links = payload.links,
      markdown_block = true,
      trailing_blank = is_last == true,
    }
  end

  local snippet = type(fix_state) == "table" and type(fix_state.lines) == "table" and fix_state.lines or {}
  local snippet_entries = type(fix_state) == "table" and type(fix_state.diff_entries) == "table" and fix_state.diff_entries or nil
  if vim.tbl_isempty(snippet) and vim.tbl_isempty(snippet_entries or {}) then
    snippet = { "(No fix diff context available)" }
  end
  local snippet_lines = diff_markdown_lines(view, snippet, snippet_entries)

  if markdown_mode == "full" then
    lines = {
      title,
      "```diff",
    }
    for _, line in ipairs(snippet_lines) do
      lines[#lines + 1] = line
    end
    lines[#lines + 1] = "```"
    return {
      lines = lines,
      markdown_block = true,
      trailing_blank = is_last == true,
    }
  end

  local payload = markdown.render(table.concat({
    title,
    "```diff",
    table.concat(snippet_lines, "\n"),
    "```",
  }, "\n"), view.markdown)
  return {
    lines = payload.lines,
    highlights = payload.highlights,
    inline_links = payload.links,
    markdown_block = true,
    trailing_blank = is_last == true,
  }
end

local function append_thread_fix_diff_items(items, view, level, fix_action, is_last, show_action_line, markdown_style)
  if type(fix_action) ~= "table" or fix_action.kind ~= "open_thread_fix_diff" then
    return false
  end

  local state = thread_fix_diff_state(view, fix_action)
  local expanded = type(state) == "table" and state.expanded == true

  if show_action_line == true then
    items[#items + 1] = build_thread_fix_diff_item(level, fix_action, is_last == true and not expanded, state, markdown_style)
  end

  if expanded then
    items[#items + 1] = build_thread_fix_diff_inline_item(view, state, is_last == true)
    return true
  end

  return show_action_line == true
end

local function append_summary_activity_items(view, items)
  if not summary_activity_enabled(view) then
    return 0, 0
  end

  local markdown_style = markdown_github_style_enabled(view)
  local separator_style = markdown_separator_style(view)
  local date_format = view.date_format
  local entries, shown = build_activity_entries(view)
  local total = visible_timeline_total(view)
  local pr_number = tonumber(type(view) == "table" and type(view.model) == "table" and view.model.number or nil) or nil

  local function add_activity_separator()
    if markdown_style ~= true or separator_style ~= "rules" then
      return
    end
    items[#items + 1] = {
      lines = { "---" },
      markdown_block = true,
      trailing_blank = false,
    }
  end

  items[#items + 1] = {
    lines = { markdown_style and "## Activity" or "Activity" },
    hl = "GhPrOverviewHeading",
    markdown_block = markdown_style == true,
    trailing_blank = false,
  }

  if vim.tbl_isempty(entries) then
    items[#items + 1] = {
      lines = { "(no activity)" },
      hl = "GhPrOverviewMuted",
      trailing_blank = false,
    }
    return shown, total
  end

  for _, entry in ipairs(entries) do
    if entry.kind == "event" then
      items[#items + 1] = build_activity_event_item(entry.event, date_format, view.theme, markdown_style)
      add_activity_separator()
    elseif entry.kind == "thread" and type(entry.thread) == "table" then
      local thread = entry.thread
      local fix_opts = thread_fix_diff_options(view)
      local first = thread.comments[1] or {}
      local header_fix_action = nil
      if fix_opts.enabled then
        header_fix_action = build_thread_fix_diff_action(nil, thread, {
          scope = "thread",
          pr_number = pr_number,
        })
      end
      local header_fix_state = thread_fix_diff_state(view, header_fix_action)
      local header_fix_expanded = type(header_fix_state) == "table" and header_fix_state.expanded == true
      local default_expanded = thread_default_expanded(thread)
      local expanded = thread_is_expanded(view, thread)
      local marker = expanded and "▾" or "▸"
      local location = timeline_item_location_text(thread.path, thread.line, thread.is_resolved, thread.is_outdated)
      local header
      if markdown_style then
        header = string.format(
          "### %s Thread (%d comments) · @%s · %s",
          marker,
          #thread.comments,
          utils.safe_string(first.author, "unknown"),
          utils.format_time(first.created_at, date_format)
        )
      else
        header = string.format(
          "%s Thread (%d comments) by @%s on %s",
          marker,
          #thread.comments,
          utils.safe_string(first.author, "unknown"),
          utils.format_time(first.created_at, date_format)
        )
      end
      local has_header_fix_action = type(header_fix_action) == "table"
      local collapsed_has_inline_block = expanded ~= true and header_fix_expanded == true
      local collapsed_has_fix_line = expanded ~= true and fix_opts.show_action_line and has_header_fix_action

      items[#items + 1] = {
        lines = markdown_style and { header, "`" .. location .. "`" } or { header, location },
        hl = "GhPrOverviewTimelineThread",
        action = {
          kind = "toggle_activity_thread",
          thread_id = thread.id,
          expanded = expanded,
          default_expanded = default_expanded,
          thread_fix_action = header_fix_action,
        },
        markdown_block = markdown_style == true,
        trailing_blank = expanded ~= true and not collapsed_has_fix_line and not collapsed_has_inline_block,
      }

      if expanded ~= true and has_header_fix_action then
        append_thread_fix_diff_items(items, view, 0, header_fix_action, true, fix_opts.show_action_line, markdown_style)
        add_activity_separator()
      end

      if expanded then
        items[#items + 1] = {
          lines = {
            markdown_style and ("Open location: `" .. location .. "`") or ("Open location: " .. location),
          },
          hl = "GhPrOverviewMuted",
          action = timeline_action(thread.anchor_event or first),
          markdown_block = markdown_style == true,
          trailing_blank = false,
        }

        items[#items + 1] = build_thread_snippet_item(thread, view)

        for index, comment in ipairs(thread.comments) do
          local level = tonumber(comment.reply_depth) or tonumber(comment.depth)
          if type(level) ~= "number" then
            level = index > 1 and 1 or 0
          end
          local fix_action = nil
          if fix_opts.enabled then
            fix_action = build_thread_fix_diff_action(comment, thread, {
              scope = "comment",
              pr_number = pr_number,
            })
          end
          local evolution_action = build_thread_evolution_diff_action(comment, thread, {
            scope = "comment",
            pr_number = pr_number,
          })
          local fix_state = thread_fix_diff_state(view, fix_action)
          local fix_expanded = type(fix_state) == "table" and fix_state.expanded == true
          local add_fix_line = fix_opts.show_action_line and type(fix_action) == "table"
          local has_evolution_line = type(evolution_action) == "table"
          local is_last_comment = index == #thread.comments
          local trailing_after_comment = not add_fix_line and not fix_expanded and not has_evolution_line and is_last_comment
          items[#items + 1] = build_thread_comment_item(
            comment,
            date_format,
            level,
            fix_action,
            trailing_after_comment,
            markdown_style
          )
          if type(fix_action) == "table" then
            append_thread_fix_diff_items(
              items,
              view,
              level,
              fix_action,
              is_last_comment and not has_evolution_line,
              fix_opts.show_action_line,
              markdown_style
            )
          end
          if has_evolution_line then
            items[#items + 1] = build_thread_evolution_diff_item(level, evolution_action, is_last_comment, markdown_style)
          end
        end
        add_activity_separator()
      elseif not has_header_fix_action then
        add_activity_separator()
      end
    end
  end

  return shown, total
end

local function build_summary_items(view)
  local model = view.model
  local people = model.people or {}
  local theme = view.theme
  local items = {}
  local summary = model.summary or {}
  local markdown_style = markdown_github_style_enabled(view)

  if markdown_style then
    items[#items + 1] = {
      lines = { "## Metadata" },
      hl = "GhPrOverviewHeading",
      markdown_block = true,
      trailing_blank = false,
    }
  end

  if utils.safe_string(summary.milestone, "") ~= "" then
    items[#items + 1] = {
      lines = { "Milestone: " .. utils.safe_string(summary.milestone, "") },
      hl = "Identifier",
      trailing_blank = false,
    }
  end

  local labels_line, labels_spans = build_chip_line("Labels: ", model.labels and model.labels.items or {}, {
    resolve_name = function(label)
      return utils.safe_string(label.name, "unknown")
    end,
    resolve_group = function(label)
      if theme.labels then
        return styles.ensure_label_highlight(label.color)
      end
      return "GhPrOverviewBadge"
    end,
  })
  items[#items + 1] = {
    lines = { labels_line },
    highlights = labels_spans,
    trailing_blank = false,
  }

  local reviewers_line, reviewers_spans = build_chip_line("Reviewers: ", people.review_requests or {}, {
    resolve_group = function()
      if theme.reviewers then
        return "GhPrOverviewReviewer"
      end
      return "GhPrOverviewBadge"
    end,
  })
  items[#items + 1] = {
    lines = { reviewers_line },
    highlights = reviewers_spans,
    trailing_blank = false,
  }

  local assignees_line, assignees_spans = build_chip_line("Assignees: ", people.assignees or {}, {
    resolve_group = function()
      if theme.reviewers then
        return "GhPrOverviewAssignee"
      end
      return "GhPrOverviewBadge"
    end,
  })
  items[#items + 1] = {
    lines = { assignees_line },
    highlights = assignees_spans,
    trailing_blank = true,
  }

  items[#items + 1] = {
    lines = { markdown_style and "## Description" or "Description" },
    hl = "GhPrOverviewHeading",
    action = summary_action("edit_body", { current = model.description }),
    markdown_block = markdown_style == true,
    trailing_blank = false,
  }

  local body_payload = markdown.render(model.description, view.markdown)
  items[#items + 1] = {
    lines = body_payload.lines,
    highlights = body_payload.highlights,
    inline_links = body_payload.links,
    markdown_block = body_payload.markdown_block == true,
    trailing_blank = true,
  }

  if utils.safe_string(model.thread_error, "") ~= "" then
    items[#items + 1] = {
      lines = {
        markdown_style and ("> Thread data warning: " .. model.thread_error) or ("Thread data warning: " .. model.thread_error),
      },
      hl = "WarningMsg",
      markdown_block = markdown_style == true,
      trailing_blank = false,
    }
  end

  if utils.safe_string(model.pr_change_error, "") ~= "" then
    items[#items + 1] = {
      lines = {
        markdown_style and ("> PR changes warning: " .. model.pr_change_error)
          or ("PR changes warning: " .. model.pr_change_error),
      },
      hl = "WarningMsg",
      markdown_block = markdown_style == true,
      trailing_blank = false,
    }
  end

  local activity_shown, activity_total = append_summary_activity_items(view, items)
  if activity_total > activity_shown then
    items[#items + 1] = {
      lines = {
        string.format("Showing %d/%d activity items. Press gr to load more.", activity_shown, activity_total),
      },
      hl = "GhPrOverviewMuted",
      action = { kind = "more_section", section = "timeline" },
      trailing_blank = false,
    }
  end

  return items
end

local function build_checks_items(view)
  local model = view.model
  local items = {}
  for _, check in ipairs(model.checks and model.checks.items or {}) do
    local marker, hl = styles.check_marker(check, view.theme)
    local lines = {
      string.format("[%s] %s", marker, utils.safe_string(check.name, "check")),
      string.format(
        "status=%s | conclusion=%s",
        utils.safe_string(check.status, "-"),
        utils.safe_string(check.conclusion, "-")
      ),
    }
    if utils.safe_string(check.workflow, "") ~= "" then
      lines[#lines + 1] = "workflow=" .. check.workflow
    end

    items[#items + 1] = {
      lines = lines,
      hl = hl,
      action = { kind = "url", url = utils.safe_string(check.url, "") },
      trailing_blank = false,
    }
  end
  return items
end

local function build_commits_items(view)
  local model = view.model
  local date_format = view.date_format
  local items = {}

  for _, commit in ipairs(model.commits and model.commits.items or {}) do
    local lines = {
      string.format(
        "%s %s",
        utils.safe_string(commit.oid_short, "--------"),
        utils.safe_string(commit.headline, "(no commit headline)")
      ),
      string.format("@%s | %s", utils.safe_string(commit.author, "unknown"), utils.format_time(commit.committed_at, date_format)),
    }
    local preview = utils.first_non_empty_line(commit.body, "")
    if preview ~= "" then
      lines[#lines + 1] = preview
    end

    items[#items + 1] = {
      lines = lines,
      action = commit_action(commit),
      trailing_blank = false,
    }
  end

  return items
end

local function build_timeline_items(view)
  local date_format = view.date_format
  local items = {}

  for _, event in ipairs(filtered_timeline_events(view)) do
    local kind = utils.safe_string(event.kind, "comment")
    local author = utils.safe_string(event.author, "unknown")
    local timestamp = utils.format_time(event.created_at, date_format)
    local lines = {}
    local highlight = styles.timeline_highlight(event, view.theme)

    if kind == "review" then
      local state = utils.safe_string(event.state, "COMMENTED")
      lines[#lines + 1] = string.format("Review %s by @%s on %s", state, author, timestamp)
      if state == "APPROVED" then
        highlight = "GhPrOverviewReviewApproved"
      elseif state == "CHANGES_REQUESTED" then
        highlight = "GhPrOverviewReviewChanges"
      end
      if utils.safe_string(event.commit_oid, "") ~= "" then
        lines[#lines + 1] = "Commit: " .. event.commit_oid:sub(1, 8)
      end
    elseif kind == "commit" then
      local oid_short = utils.safe_string(event.oid_short, "")
      if oid_short == "" and utils.safe_string(event.oid, "") ~= "" then
        oid_short = event.oid:sub(1, 8)
      end
      lines[#lines + 1] = string.format(
        "Commit %s by @%s on %s",
        oid_short ~= "" and oid_short or "--------",
        author,
        timestamp
      )
      lines[#lines + 1] = utils.safe_string(event.headline, "(no commit headline)")
    elseif kind == "pr_change" then
      local summary = utils.safe_string(event.change_summary, "PR updated")
      local details = utils.safe_string(event.change_details, "")
      lines[#lines + 1] = string.format("PR change by @%s on %s", author, timestamp)
      lines[#lines + 1] = summary
      if details ~= "" then
        lines[#lines + 1] = details
      end
    elseif kind == "thread_comment" then
      local where = utils.safe_string(event.path, "(unknown path)")
      if tonumber(event.line) and tonumber(event.line) > 0 then
        where = string.format("%s:%d", where, event.line)
      end
      local flags = {}
      if event.is_resolved then
        flags[#flags + 1] = "resolved"
      end
      if event.is_outdated then
        flags[#flags + 1] = "outdated"
      end
      if not vim.tbl_isempty(flags) then
        where = where .. " [" .. table.concat(flags, ", ") .. "]"
      end
      lines[#lines + 1] = string.format("Thread comment by @%s on %s", author, timestamp)
      lines[#lines + 1] = where
    else
      lines[#lines + 1] = string.format("Comment by @%s on %s", author, timestamp)
    end

    if kind ~= "commit" and kind ~= "pr_change" then
      local body_lines = utils.split_lines(utils.safe_string(event.body, ""))
      if vim.tbl_isempty(body_lines) then
        body_lines = { "(no text)" }
      end
      for _, line in ipairs(body_lines) do
        lines[#lines + 1] = line
      end
    end

    items[#items + 1] = {
      lines = lines,
      hl = highlight,
      action = timeline_action(event),
      trailing_blank = true,
    }
  end

  return items
end

local function build_files_items(view)
  local model = view.model
  local repository = utils.safe_string(model.repository, "")
  local pr_number = tonumber(model.number) or 0
  local items = {}

  for _, file in ipairs(model.files and model.files.items or {}) do
    local path = utils.safe_string(file.path, utils.safe_string(file.filename, "(unknown file)"))
    local viewed = repository ~= "" and runtime_state.is_viewed(repository, pr_number, path)
    local marker = viewed and "x" or " "
    local status = utils.safe_string(file.status, "")
    local status_token = status ~= "" and ("[" .. status .. "] ") or ""
    local lines = {
      string.format(
        "[%s] %s%s | +%d -%d",
        marker,
        status_token,
        path,
        tonumber(file.additions) or 0,
        tonumber(file.deletions) or 0
      ),
    }
    if utils.safe_string(file.previous_filename, "") ~= "" then
      lines[#lines + 1] = "renamed from " .. file.previous_filename
    end

    items[#items + 1] = {
      lines = lines,
      action = file_action(file),
      trailing_blank = false,
    }
  end

  return items
end

local function tab_items(view)
  if view.current_tab == "summary" then
    return build_summary_items(view)
  end
  if view.current_tab == "checks" then
    return build_checks_items(view)
  end
  if view.current_tab == "commits" then
    return build_commits_items(view)
  end
  if view.current_tab == "timeline" then
    return build_timeline_items(view)
  end
  if view.current_tab == "files" then
    return build_files_items(view)
  end
  return {}
end

local function add_line(render, text, hl_group)
  local chunks = utils.split_lines(utils.safe_string(text, ""))
  if vim.tbl_isempty(chunks) then
    chunks = { "" }
  end

  local first_line_number = nil
  for _, chunk in ipairs(chunks) do
    render.lines[#render.lines + 1] = chunk
    local line_number = #render.lines
    first_line_number = first_line_number or line_number
    if type(hl_group) == "string" and hl_group ~= "" then
      render.highlights[#render.highlights + 1] = {
        line = line_number - 1,
        start_col = 0,
        end_col = -1,
        group = hl_group,
      }
    end
  end

  return first_line_number or #render.lines
end

local function add_highlight(render, line_number, start_col, end_col, group)
  if type(group) ~= "string" or group == "" then
    return
  end
  if type(line_number) ~= "number" or line_number < 1 then
    return
  end

  render.highlights[#render.highlights + 1] = {
    line = line_number - 1,
    start_col = math.max(0, tonumber(start_col) or 0),
    end_col = tonumber(end_col) or -1,
    group = group,
  }
end

local function render_item(render_data, item, tab_name)
  local lines = type(item.lines) == "table" and item.lines or { utils.safe_string(item.text, "") }
  local compact_lines = {}
  for _, line in ipairs(lines) do
    if line ~= nil then
      compact_lines[#compact_lines + 1] = line
    end
  end
  lines = compact_lines
  if vim.tbl_isempty(lines) then
    lines = { "" }
  end

  local first_action_line
  local markdown_mode = utils.safe_string(render_data.markdown_mode, "legacy")
  local markdown_item = markdown_mode == "full" or item.markdown_block == true
  local item_inline_links = type(item.inline_links) == "table" and item.inline_links or {}
  for index, text in ipairs(lines) do
    local is_first = index == 1
    local prefix = markdown_item and "" or (is_first and "  " or "    ")
    local line_number = add_line(render_data, prefix .. utils.safe_string(text, ""), is_first and item.hl or nil)
    if is_first and item.action then
      first_action_line = line_number
    end

    local local_highlights = type(item.highlights) == "table" and item.highlights or {}
    for _, hl in ipairs(local_highlights) do
      if hl.line == index then
        local start_col = #prefix + (tonumber(hl.start_col) or 0)
        local end_col = hl.end_col
        if type(end_col) == "number" and end_col >= 0 then
          end_col = #prefix + end_col
        end
        add_highlight(render_data, line_number, start_col, end_col, hl.group)
      end
    end

    for _, link in ipairs(item_inline_links) do
      if link.line == index and type(link.url) == "string" and link.url ~= "" then
        local start_col = #prefix + (tonumber(link.start_col) or 0)
        local end_col = tonumber(link.end_col) or start_col
        if end_col >= 0 then
          end_col = #prefix + end_col
        end
        if not render_data.inline_actions[line_number] then
          render_data.inline_actions[line_number] = {}
        end
        render_data.inline_actions[line_number][#render_data.inline_actions[line_number] + 1] = {
          start_col = start_col,
          end_col = end_col,
          action = {
            kind = "markdown_link",
            label = type(link.label) == "string" and link.label or "",
            url = link.url,
          },
        }
      end
    end
  end

  if first_action_line then
    render_data.line_actions[first_action_line] = item.action
    if not render_data.first_action_line then
      render_data.first_action_line = first_action_line
    end
  end

  if item.trailing_blank == true or (item.trailing_blank == nil and tab_name == "timeline") then
    add_line(render_data, "")
  end
end

function M.render(view, namespace)
  local model = view.model
  local bufnr = view.bufnr
  local render_data = {
    lines = {},
    highlights = {},
    line_actions = {},
    inline_actions = {},
    first_action_line = nil,
    markdown_mode = type(view.markdown) == "table" and utils.safe_string(view.markdown.mode, "legacy") or "legacy",
  }

  add_line(render_data, string.format("Pull Request #%d", tonumber(model.number) or 0), "GhPrOverviewTitle")
  add_line(render_data, utils.safe_string(model.title, "(no title)"), "Title")

  local summary = model.summary or {}
  local state_token = styles.state_text(summary)
  local review_token = utils.safe_string(summary.review_decision, "REVIEW_REQUIRED")
  local merge_state = utils.safe_string(summary.merge_state, "-")
  local mergeable = utils.safe_string(summary.mergeable, "-")
  local date_format = view.date_format

  local branch_line = string.format(
    "@%s opened %s into %s",
    utils.safe_string(summary.author, "unknown"),
    utils.safe_string(summary.head_ref, "?"),
    utils.safe_string(summary.base_ref, "?")
  )
  add_line(render_data, branch_line, "GhPrOverviewBranch")

  local status_line = string.format(
    "State: %s   Review: %s   Merge: %s (%s)",
    state_token,
    review_token,
    merge_state,
    mergeable
  )
  local status_line_no = add_line(render_data, status_line)
  local status_spans = {}
  map_token_span(status_spans, status_line, state_token, styles.state_highlight(summary, view.theme))
  map_token_span(status_spans, status_line, review_token, styles.review_highlight(review_token, view.theme))
  for _, span in ipairs(status_spans) do
    add_highlight(render_data, status_line_no, span.start_col, span.end_col, span.group)
  end

  add_line(
    render_data,
    string.format(
      "Changed files: %d   +%d   -%d",
      tonumber(summary.files_changed) or 0,
      tonumber(summary.additions) or 0,
      tonumber(summary.deletions) or 0
    )
  )
  add_line(
    render_data,
    string.format(
      "Created: %s   Updated: %s",
      utils.format_time(summary.created_at, date_format),
      utils.format_time(summary.updated_at, date_format)
    )
  )
  if utils.safe_string(summary.merged_at, "") ~= "" then
    add_line(render_data, string.format("Merged: %s", utils.format_time(summary.merged_at, date_format)), "GhPrOverviewStateMerged")
  end

  add_line(render_data, string.format("Repository: %s", utils.safe_string(model.repository, "-")), "GhPrOverviewMuted")
  local url_line = string.format("URL: %s", utils.safe_string(model.url, "-"))
  local url_line_no = add_line(render_data, url_line, "GhPrOverviewMuted")
  render_data.line_actions[url_line_no] = { kind = "url", url = utils.safe_string(model.url, "") }
  if not render_data.first_action_line then
    render_data.first_action_line = url_line_no
  end
  add_line(render_data, "")

  local tab_line = ""
  local tab_segments = {}
  local cursor = 0
  for index, tab_name in ipairs(view.tabs) do
    local label = M.TAB_DEFS[tab_name] and M.TAB_DEFS[tab_name].label or tab_name
    local count = M.tab_count(model, tab_name)
    if type(count) == "number" and count > 0 and tab_name ~= "summary" then
      label = string.format("%s %d", label, count)
    end

    local segment = string.format("[%d %s]", index, label)
    if index > 1 then
      tab_line = tab_line .. " "
      cursor = cursor + 1
    end
    local start_col = cursor
    tab_line = tab_line .. segment
    cursor = cursor + #segment
    tab_segments[#tab_segments + 1] = {
      start_col = start_col,
      end_col = cursor,
      active = tab_name == view.current_tab,
    }
  end

  local tab_line_no = add_line(render_data, tab_line)
  for _, segment in ipairs(tab_segments) do
    add_highlight(
      render_data,
      tab_line_no,
      segment.start_col,
      segment.end_col,
      segment.active and "GhPrOverviewTabActive" or "GhPrOverviewTab"
    )
  end

  local hint = "H/L: tabs   <CR>: open/toggle   D/O/M: diff/original/modified   b: browser"
  local link_preview_key = type(view.markdown.link_preview_keymap) == "string" and view.markdown.link_preview_keymap or "gp"
  if link_preview_key ~= "" then
    hint = hint .. "   " .. link_preview_key .. ": preview link"
  end
  local thread_fix_key = ""
  if type(view.thread_fix_diff) == "table" and view.thread_fix_diff.enabled ~= false then
    thread_fix_key = type(view.thread_fix_diff.keymap) == "string" and view.thread_fix_diff.keymap or "gf"
  end
  if thread_fix_key ~= "" then
    hint = hint .. "   " .. thread_fix_key .. ": fix diff"
  end
  hint = hint .. "   gr: load more"
  add_line(render_data, hint, "GhPrOverviewMuted")
  add_line(
    render_data,
    "C: comments tree   a/d/c: review   m: merge   k: checkout   et/eb/el/er/ea/em/es/ed: edit",
    "GhPrOverviewMuted"
  )
  add_line(render_data, "")

  local current_def = M.TAB_DEFS[view.current_tab] or { label = view.current_tab }
  local section_count = M.tab_count(model, view.current_tab)
  if type(section_count) == "number" and section_count > 0 then
    add_line(render_data, string.format("%s (%d)", current_def.label, section_count), "GhPrOverviewHeading")
  else
    add_line(render_data, current_def.label, "GhPrOverviewHeading")
  end
  add_line(render_data, "")

  local items = tab_items(view)
  if vim.tbl_isempty(items) then
    add_line(render_data, "(no items)", "GhPrOverviewMuted")
  else
    for _, item in ipairs(items) do
      render_item(render_data, item, view.current_tab)
    end
  end

  local section_name = current_def.section
  if section_name and type(model[section_name]) == "table" then
    local shown = #(model[section_name].items or {})
    local total = tonumber(model[section_name].total) or shown
    if total > shown then
      add_line(render_data, "")
      local hint_line = add_line(
        render_data,
        string.format("Showing %d/%d. Press gr to load more.", shown, total),
        "GhPrOverviewMuted"
      )
      render_data.line_actions[hint_line] = { kind = "more_section", section = section_name }
    end
  end

  vim.api.nvim_buf_set_option(bufnr, "modifiable", true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, render_data.lines)
  vim.api.nvim_buf_set_option(bufnr, "modifiable", false)

  vim.api.nvim_buf_clear_namespace(bufnr, namespace, 0, -1)
  for _, hl in ipairs(render_data.highlights) do
    vim.api.nvim_buf_add_highlight(bufnr, namespace, hl.group, hl.line, hl.start_col, hl.end_col)
  end

  view.line_actions = render_data.line_actions
  view.inline_actions = render_data.inline_actions
  view.first_action_line = render_data.first_action_line

  local target_line = view.cursor_by_tab[view.current_tab] or render_data.first_action_line or 1
  target_line = utils.clamp_line(bufnr, target_line)
  view.cursor_by_tab[view.current_tab] = target_line

  local winid = utils.current_win_for_buf(bufnr)
  if winid then
    utils.ensure_window_options(winid)
    pcall(vim.api.nvim_win_set_cursor, winid, { target_line, 0 })
  end
end

local function tab_is_visible(tab_name, show)
  if tab_name == "checks" then
    return show.checks ~= false
  end
  if tab_name == "commits" then
    return show.commits ~= false
  end
  if tab_name == "timeline" then
    if show.timeline == false then
      return false
    end
    local allow_comments = show.comments ~= false
    local allow_reviews = show.reviews ~= false
    local allow_threads = show.threads ~= false
    return allow_comments or allow_reviews or allow_threads
  end
  if tab_name == "summary" then
    return true
  end
  if tab_name == "files" then
    return true
  end
  return false
end

function M.sanitize_tabs(input_tabs, show)
  local selected = {}
  local seen = {}
  local source = type(input_tabs) == "table" and input_tabs or M.DEFAULT_TABS
  show = type(show) == "table" and show or {}

  for _, tab_name in ipairs(source) do
    if type(tab_name) == "string" then
      local normalized = tab_name:lower()
      normalized = M.TAB_ALIASES[normalized] or normalized
      if M.TAB_DEFS[normalized] and not seen[normalized] and tab_is_visible(normalized, show) then
        selected[#selected + 1] = normalized
        seen[normalized] = true
      end
    end
  end

  if vim.tbl_isempty(selected) then
    return vim.deepcopy(M.DEFAULT_TABS)
  end

  return selected
end

return M
