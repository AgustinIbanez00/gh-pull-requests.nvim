local runtime_state = require("gh-pr.state")
local utils = require("gh-pr.overview_utils")
local styles = require("gh-pr.overview_styles")

local M = {}

M.TAB_DEFS = {
  summary = { label = "Summary" },
  checks = { label = "Checks", section = "checks" },
  commits = { label = "Commits", section = "commits" },
  timeline = { label = "Activity", section = "timeline" },
  files = { label = "Files" },
}

M.DEFAULT_TABS = { "summary", "checks", "commits", "timeline", "files" }
M.TAB_ALIASES = {
  comments = "timeline",
  reviews = "timeline",
  threads = "timeline",
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

local function summary_actions(view)
  local model = view.model
  return {
    { key = "o", label = "Open pull request in browser", action = { kind = "url", url = model.url } },
    { key = "C", label = "Open Comments PR tree", action = { kind = "open_comments_tree" } },
    { key = "et", label = "Edit title", action = summary_action("edit_title", { current = model.title }) },
    { key = "eb", label = "Edit description", action = summary_action("edit_body", { current = model.description }) },
    {
      key = "el",
      label = "Edit labels",
      action = summary_action("edit_labels", {
        current = table.concat(vim.tbl_map(function(label)
          return utils.safe_string(label.name, "")
        end, model.labels and model.labels.items or {}), ", "),
      }),
    },
    {
      key = "er",
      label = "Edit reviewers",
      action = summary_action("edit_reviewers", {
        current = table.concat(model.people and model.people.review_requests or {}, ", "),
      }),
    },
    {
      key = "ea",
      label = "Edit assignees",
      action = summary_action("edit_assignees", {
        current = table.concat(model.people and model.people.assignees or {}, ", "),
      }),
    },
    {
      key = "em",
      label = "Edit milestone",
      action = summary_action("edit_milestone", {
        current = utils.safe_string(model.summary and model.summary.milestone, ""),
      }),
    },
    {
      key = "es",
      label = "Change state",
      action = summary_action("change_state", {
        current = utils.safe_string(model.summary and model.summary.state, ""),
      }),
    },
    {
      key = "ed",
      label = "Toggle draft/ready",
      action = summary_action("change_draft", {
        current = model.summary and model.summary.is_draft and "draft" or "ready",
      }),
    },
  }
end

local function build_summary_items(view)
  local model = view.model
  local summary = model.summary or {}
  local people = model.people or {}
  local theme = view.theme
  local date_format = view.date_format
  local items = {}

  local state_token = styles.state_text(summary)
  local review_token = utils.safe_string(summary.review_decision, "REVIEW_REQUIRED")
  local merge_state = utils.safe_string(summary.merge_state, "-")
  local mergeable = utils.safe_string(summary.mergeable, "-")

  items[#items + 1] = {
    lines = {
      string.format(
        "@%s opened %s into %s",
        utils.safe_string(summary.author, "unknown"),
        utils.safe_string(summary.head_ref, "?"),
        utils.safe_string(summary.base_ref, "?")
      ),
    },
    hl = "GhPrOverviewBranch",
    trailing_blank = false,
  }

  local status_line = string.format(
    "State: %s   Review: %s   Merge: %s (%s)",
    state_token,
    review_token,
    merge_state,
    mergeable
  )
  local status_spans = {}
  map_token_span(status_spans, status_line, state_token, styles.state_highlight(summary, theme))
  map_token_span(status_spans, status_line, review_token, styles.review_highlight(review_token, theme))
  items[#items + 1] = {
    lines = { status_line },
    highlights = status_spans,
    trailing_blank = false,
  }

  items[#items + 1] = {
    lines = {
      string.format(
        "Changed files: %d   +%d   -%d",
        tonumber(summary.files_changed) or 0,
        tonumber(summary.additions) or 0,
        tonumber(summary.deletions) or 0
      ),
      string.format("Created: %s", utils.format_time(summary.created_at, date_format)),
      string.format("Updated: %s", utils.format_time(summary.updated_at, date_format)),
    },
    trailing_blank = false,
  }

  if utils.safe_string(summary.merged_at, "") ~= "" then
    items[#items + 1] = {
      lines = { string.format("Merged: %s", utils.format_time(summary.merged_at, date_format)) },
      hl = "GhPrOverviewStateMerged",
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
    lines = { "Actions" },
    hl = "GhPrOverviewHeading",
    trailing_blank = false,
  }

  for _, action in ipairs(summary_actions(view)) do
    local action_line = string.format("[%s] %s", action.key, action.label)
    items[#items + 1] = {
      lines = { action_line },
      highlights = {
        {
          line = 1,
          start_col = 0,
          end_col = 2 + #action.key,
          group = "GhPrOverviewActionKey",
        },
      },
      action = action.action,
      trailing_blank = false,
    }
  end

  items[#items + 1] = {
    lines = { "Description" },
    hl = "GhPrOverviewHeading",
    action = summary_action("edit_body", { current = model.description }),
    trailing_blank = false,
  }

  local body_lines = utils.split_lines(utils.safe_string(model.description, ""))
  if vim.tbl_isempty(body_lines) then
    body_lines = { "(no pull request description)" }
  end
  items[#items + 1] = {
    lines = body_lines,
    trailing_blank = false,
  }

  if utils.safe_string(model.thread_error, "") ~= "" then
    items[#items + 1] = {
      lines = { "Thread data warning: " .. model.thread_error },
      hl = "WarningMsg",
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
  local model = view.model
  local date_format = view.date_format
  local items = {}

  for _, event in ipairs(model.timeline and model.timeline.items or {}) do
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

    local body_lines = utils.split_lines(utils.safe_string(event.body, ""))
    if vim.tbl_isempty(body_lines) then
      body_lines = { "(no text)" }
    end
    for _, line in ipairs(body_lines) do
      lines[#lines + 1] = line
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
  render.lines[#render.lines + 1] = text
  local line_number = #render.lines
  if type(hl_group) == "string" and hl_group ~= "" then
    render.highlights[#render.highlights + 1] = {
      line = line_number - 1,
      start_col = 0,
      end_col = -1,
      group = hl_group,
    }
  end
  return line_number
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
  if vim.tbl_isempty(lines) then
    lines = { "" }
  end

  local first_action_line
  for index, text in ipairs(lines) do
    local is_first = index == 1
    local prefix = is_first and "  " or "    "
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
    first_action_line = nil,
  }

  add_line(render_data, string.format("Pull Request #%d", tonumber(model.number) or 0), "GhPrOverviewTitle")
  add_line(render_data, utils.safe_string(model.title, "(no title)"), "Title")

  local summary = model.summary or {}
  local state = styles.state_text(summary)
  local branch_line = string.format(
    "%s  @%s  %s -> %s",
    state,
    utils.safe_string(summary.author, "unknown"),
    utils.safe_string(summary.head_ref, "?"),
    utils.safe_string(summary.base_ref, "?")
  )
  local branch_line_no = add_line(render_data, branch_line)
  local state_start = branch_line:find(state, 1, true)
  if state_start then
    add_highlight(
      render_data,
      branch_line_no,
      state_start - 1,
      (state_start - 1) + #state,
      styles.state_highlight(summary, view.theme)
    )
  end
  add_highlight(render_data, branch_line_no, 0, -1, "GhPrOverviewBranch")

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

  add_line(render_data, "H/L: tabs   <CR>: open   D/O/M: diff/original/modified   gr: load more", "GhPrOverviewMuted")
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
    add_line(render_data, "  (no items)", "GhPrOverviewMuted")
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
