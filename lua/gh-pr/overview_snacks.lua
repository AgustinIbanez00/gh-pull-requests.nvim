local M = {}

local runtime_state = require("gh-pr.state")

local namespace = vim.api.nvim_create_namespace("gh-pr-overview")
local views = {}

local TAB_DEFS = {
  summary = { label = "Summary" },
  checks = { label = "Checks", section = "checks" },
  commits = { label = "Commits", section = "commits" },
  timeline = { label = "Timeline", section = "timeline" },
  files = { label = "Files" },
}

local DEFAULT_TABS = { "summary", "checks", "commits", "timeline", "files" }
local TAB_ALIASES = {
  comments = "timeline",
  reviews = "timeline",
  threads = "timeline",
}

local function safe_string(value, fallback)
  if type(value) == "string" and value ~= "" then
    return value
  end
  return fallback or ""
end

local function split_lines(text)
  if type(text) ~= "string" then
    return {}
  end
  return vim.split(text, "\n", { plain = true })
end

local function first_non_empty_line(text, fallback)
  for _, line in ipairs(split_lines(text)) do
    local trimmed = vim.trim(line)
    if trimmed ~= "" then
      return trimmed
    end
  end
  return fallback or ""
end

local function format_time(value, date_format)
  local text = safe_string(value, "")
  if text == "" then
    return "-"
  end

  local seconds = vim.fn.strptime("%Y-%m-%dT%H:%M:%SZ", text)
  if type(seconds) ~= "number" or seconds <= 0 then
    return text
  end

  return vim.fn.strftime(date_format, seconds)
end

local function open_url(url)
  if type(url) ~= "string" or url == "" then
    return
  end

  if vim.ui and type(vim.ui.open) == "function" then
    vim.ui.open(url)
    return
  end

  vim.notify("Unable to open URL. vim.ui.open is unavailable.", vim.log.levels.WARN)
end

local function ensure_overview_buffer(pr_number, bufnr)
  local target_name = string.format("ghpr://overview/%d", pr_number)

  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    local current_name = vim.api.nvim_buf_get_name(bufnr)
    if current_name == target_name then
      return bufnr
    end
  end

  local existing = vim.fn.bufnr(target_name)
  if type(existing) == "number" and existing > 0 and vim.api.nvim_buf_is_valid(existing) then
    return existing
  end

  for _, candidate in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(candidate) then
      local ok, name = pcall(vim.api.nvim_buf_get_name, candidate)
      if ok and name == target_name then
        return candidate
      end
    end
  end

  local created = vim.api.nvim_create_buf(true, true)
  local set_name_ok = pcall(vim.api.nvim_buf_set_name, created, target_name)
  if not set_name_ok then
    vim.api.nvim_buf_set_name(created, string.format("%s:%d", target_name, created))
  end
  return created
end

local function valid_buf(bufnr)
  return type(bufnr) == "number" and bufnr > 0 and vim.api.nvim_buf_is_valid(bufnr)
end

local function window_filetype(winid)
  if type(winid) ~= "number" or winid <= 0 or not vim.api.nvim_win_is_valid(winid) then
    return nil
  end
  local bufnr = vim.api.nvim_win_get_buf(winid)
  return vim.api.nvim_get_option_value("filetype", { buf = bufnr })
end

local function is_navigation_window(winid)
  return window_filetype(winid) ~= "neo-tree"
end

local function ensure_navigation_window()
  local current = vim.api.nvim_get_current_win()
  if is_navigation_window(current) then
    return current
  end

  local alternate = vim.fn.win_getid(vim.fn.winnr("#"))
  if type(alternate) == "number" and alternate > 0 and vim.api.nvim_win_is_valid(alternate) and is_navigation_window(alternate) then
    pcall(vim.api.nvim_set_current_win, alternate)
    return alternate
  end

  for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if winid ~= current and is_navigation_window(winid) then
      pcall(vim.api.nvim_set_current_win, winid)
      return winid
    end
  end

  vim.cmd("vsplit")
  local created = vim.api.nvim_get_current_win()
  if window_filetype(created) == "neo-tree" then
    vim.cmd("enew")
  end
  return created
end

local function join_list(values)
  if type(values) ~= "table" or vim.tbl_isempty(values) then
    return "(none)"
  end
  return table.concat(values, ", ")
end

local function join_labels(labels)
  if type(labels) ~= "table" or vim.tbl_isempty(labels) then
    return "(none)"
  end

  local parts = {}
  for _, label in ipairs(labels) do
    parts[#parts + 1] = "[" .. safe_string(label.name, "unknown") .. "]"
  end
  return table.concat(parts, " ")
end

local function attach_buffer_metadata(bufnr, model, view)
  vim.b[bufnr].gh_pr_number = model.number
  vim.b[bufnr].gh_pr_repo = model.repository
  vim.b[bufnr].gh_pr_overview_ui = "snacks"
  vim.b[bufnr].gh_pr_overview_layout = "tabs"
  vim.b[bufnr].gh_pr_overview_tab = view.current_tab
  vim.b[bufnr].gh_pr_overview_limits = vim.deepcopy(model.limits or {})
  vim.b[bufnr].gh_pr_overview_sections = {
    checks = model.checks and model.checks.total or 0,
    commits = model.commits and model.commits.total or 0,
    timeline = model.timeline and model.timeline.total or 0,
    comments = model.comments and model.comments.total or 0,
    reviews = model.reviews and model.reviews.total or 0,
    threads = model.threads and model.threads.total or 0,
  }
end

local function status_line(summary)
  local state = safe_string(summary.state, "UNKNOWN")
  local decision = safe_string(summary.review_decision, "REVIEW_REQUIRED")
  local draft = summary.is_draft == true and "draft" or "ready"
  return string.format("State %s | %s | decision %s", state, draft, decision)
end

local function check_marker(check)
  local status = safe_string(check.status, ""):upper()
  local conclusion = safe_string(check.conclusion, ""):upper()
  if conclusion == "SUCCESS" then
    return "PASS", "DiffAdd"
  end
  if conclusion == "FAILURE" or conclusion == "CANCELLED" or conclusion == "TIMED_OUT" then
    return "FAIL", "DiffDelete"
  end
  if status == "IN_PROGRESS" or status == "QUEUED" or status == "PENDING" then
    return "WAIT", "WarningMsg"
  end
  return "INFO", "Identifier"
end

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

local function build_summary_items(model, date_format)
  local summary = model.summary or {}
  local people = model.people or {}
  local items = {}

  items[#items + 1] = {
    lines = {
      string.format(
        "@%s opened this pull request into %s from %s.",
        safe_string(summary.author, "unknown"),
        safe_string(summary.base_ref, "?"),
        safe_string(summary.head_ref, "?")
      ),
    },
    hl = "Identifier",
    trailing_blank = false,
  }
  items[#items + 1] = {
    lines = {
      status_line(summary),
      string.format(
        "Changed files %d | +%d | -%d",
        tonumber(summary.files_changed) or 0,
        tonumber(summary.additions) or 0,
        tonumber(summary.deletions) or 0
      ),
      string.format("Created %s | Updated %s", format_time(summary.created_at, date_format), format_time(summary.updated_at, date_format)),
    },
    trailing_blank = false,
  }

  if safe_string(summary.merged_at, "") ~= "" then
    items[#items + 1] = {
      lines = { "Merged at " .. format_time(summary.merged_at, date_format) },
      hl = "DiffAdd",
      trailing_blank = false,
    }
  end

  items[#items + 1] = {
    lines = { "Assignees: " .. join_list(people.assignees) },
    trailing_blank = false,
  }
  items[#items + 1] = {
    lines = { "Review requests: " .. join_list(people.review_requests) },
    trailing_blank = false,
  }
  items[#items + 1] = {
    lines = { "Labels: " .. join_labels(model.labels and model.labels.items or {}) },
    trailing_blank = false,
  }

  if safe_string(model.url, "") ~= "" then
    items[#items + 1] = {
      lines = { "Open Pull Request in browser" },
      hl = "Identifier",
      action = { kind = "url", url = model.url },
      trailing_blank = false,
    }
  end

  local body = split_lines(safe_string(model.description, ""))
  if vim.tbl_isempty(body) then
    body = { "(no pull request description)" }
  end

  items[#items + 1] = {
    lines = { "Description" },
    hl = "Special",
    trailing_blank = false,
  }
  items[#items + 1] = {
    lines = body,
    trailing_blank = false,
  }

  return items
end

local function build_checks_items(model)
  local items = {}
  for _, check in ipairs(model.checks and model.checks.items or {}) do
    local marker, hl = check_marker(check)
    items[#items + 1] = {
      lines = {
        string.format(
          "[%s] %s",
          marker,
          safe_string(check.name, "check")
        ),
        string.format("status=%s | conclusion=%s", safe_string(check.status, "-"), safe_string(check.conclusion, "-")),
      },
      hl = hl,
      action = { kind = "url", url = safe_string(check.url, "") },
      trailing_blank = false,
    }
  end
  return items
end

local function build_commits_items(model, date_format)
  local items = {}
  for _, commit in ipairs(model.commits and model.commits.items or {}) do
    local body_preview = first_non_empty_line(commit.body, "")
    local lines = {
      string.format("%s %s", safe_string(commit.oid_short, "--------"), safe_string(commit.headline, "(no commit headline)")),
      string.format("@%s | %s", safe_string(commit.author, "unknown"), format_time(commit.committed_at, date_format)),
    }
    if body_preview ~= "" then
      lines[#lines + 1] = body_preview
    end

    items[#items + 1] = {
      lines = lines,
      action = commit_action(commit),
      trailing_blank = false,
    }
  end
  return items
end

local function build_timeline_items(model, date_format)
  local items = {}
  for _, event in ipairs(model.timeline and model.timeline.items or {}) do
    local event_type = safe_string(event.kind, "comment")
    local author = safe_string(event.author, "unknown")
    local timestamp = format_time(event.created_at, date_format)
    local lines = {}
    local hl = "Identifier"

    if event_type == "review" then
      local state = safe_string(event.state, "COMMENTED")
      lines[#lines + 1] = string.format("Review %s by @%s at %s", state, author, timestamp)
      if state == "APPROVED" then
        hl = "DiffAdd"
      elseif state == "CHANGES_REQUESTED" then
        hl = "DiffDelete"
      end
    elseif event_type == "thread_comment" then
      local flags = {}
      if event.is_resolved then
        flags[#flags + 1] = "resolved"
      end
      if event.is_outdated then
        flags[#flags + 1] = "outdated"
      end
      local where = safe_string(event.path, "(unknown path)")
      local line = tonumber(event.line) or 0
      if line > 0 then
        where = where .. ":" .. tostring(line)
      end
      if not vim.tbl_isempty(flags) then
        where = where .. " [" .. table.concat(flags, ", ") .. "]"
      end
      lines[#lines + 1] = string.format("Thread comment by @%s at %s", author, timestamp)
      lines[#lines + 1] = where
      hl = event.is_resolved and "DiffAdd" or (event.is_outdated and "WarningMsg" or "Identifier")
    else
      lines[#lines + 1] = string.format("Comment by @%s at %s", author, timestamp)
      hl = "Identifier"
    end

    local body_lines = split_lines(safe_string(event.body, ""))
    if vim.tbl_isempty(body_lines) then
      body_lines = { "(no text)" }
    end
    for _, line in ipairs(body_lines) do
      lines[#lines + 1] = line
    end

    items[#items + 1] = {
      lines = lines,
      hl = hl,
      action = timeline_action(event),
      trailing_blank = true,
    }
  end
  return items
end

local function build_files_items(model)
  local items = {}
  local repository = safe_string(model.repository, "")
  local pr_number = tonumber(model.number) or 0

  for _, file in ipairs(model.files and model.files.items or {}) do
    local viewed = repository ~= "" and runtime_state.is_viewed(repository, pr_number, safe_string(file.path, ""))
    local marker = viewed and "x" or " "
    local status = safe_string(file.status, "")
    local status_prefix = status ~= "" and ("[" .. status .. "] ") or ""

    items[#items + 1] = {
      lines = {
        string.format(
          "%s %s%s | +%d -%d",
          marker,
          status_prefix,
          safe_string(file.path, safe_string(file.filename, "(unknown file)")),
          tonumber(file.additions) or 0,
          tonumber(file.deletions) or 0
        ),
      },
      action = file_action(file),
      trailing_blank = false,
    }
  end

  return items
end

local function tab_items(view)
  local model = view.model
  local date_format = view.date_format
  local tab = view.current_tab

  if tab == "summary" then
    return build_summary_items(model, date_format)
  end
  if tab == "checks" then
    return build_checks_items(model)
  end
  if tab == "commits" then
    return build_commits_items(model, date_format)
  end
  if tab == "timeline" then
    return build_timeline_items(model, date_format)
  end
  if tab == "files" then
    return build_files_items(model)
  end
  return {}
end

local function tab_index(view, tab_name)
  for index, name in ipairs(view.tabs) do
    if name == tab_name then
      return index
    end
  end
  return 1
end

local function clamp_line(bufnr, line)
  local count = vim.api.nvim_buf_line_count(bufnr)
  if count < 1 then
    return 1
  end
  local value = tonumber(line) or 1
  value = math.floor(value)
  if value < 1 then
    return 1
  end
  if value > count then
    return count
  end
  return value
end

local function current_win_for_buf(bufnr)
  local winid = vim.fn.bufwinid(bufnr)
  if type(winid) == "number" and winid > 0 and vim.api.nvim_win_is_valid(winid) then
    return winid
  end
  return nil
end

local function save_cursor(view)
  local winid = current_win_for_buf(view.bufnr)
  if not winid then
    return
  end
  local cursor = vim.api.nvim_win_get_cursor(winid)
  view.cursor_by_tab[view.current_tab] = cursor[1]
end

local function add_line(render, text, highlight)
  render.lines[#render.lines + 1] = text
  if highlight then
    render.highlights[#render.highlights + 1] = {
      line = #render.lines - 1,
      start_col = 0,
      end_col = -1,
      group = highlight,
    }
  end
end

local function render_item(render_data, item, tab_name)
  local lines = type(item.lines) == "table" and item.lines or { safe_string(item.text, "") }
  if vim.tbl_isempty(lines) then
    lines = { "" }
  end

  local action_line
  for index, text in ipairs(lines) do
    local prefix = index == 1 and "  " or "    "
    add_line(render_data, prefix .. safe_string(text, ""), index == 1 and item.hl or nil)
    if index == 1 then
      action_line = #render_data.lines
    end
  end

  if item.action and action_line then
    render_data.line_actions[action_line] = item.action
    if not render_data.first_action_line then
      render_data.first_action_line = action_line
    end
  end

  if item.trailing_blank == true or (item.trailing_blank == nil and tab_name == "timeline") then
    add_line(render_data, "")
  end
end

local function render(view)
  local model = view.model
  local bufnr = view.bufnr
  local render_data = {
    lines = {},
    highlights = {},
    line_actions = {},
    first_action_line = nil,
  }

  add_line(render_data, string.format("Pull Request #%d", model.number), "Special")
  add_line(render_data, safe_string(model.title, "(no title)"), "Title")
  add_line(render_data, status_line(model.summary or {}), "Identifier")
  add_line(render_data, string.format("Repository: %s", safe_string(model.repository, "-")))
  add_line(render_data, string.format("URL: %s", safe_string(model.url, "-")), "Comment")
  add_line(render_data, "")

  local tab_line = ""
  local tab_segments = {}
  local col = 0
  for index, tab_name in ipairs(view.tabs) do
    local tab_def = TAB_DEFS[tab_name]
    local segment = string.format("[%d %s]", index, tab_def and tab_def.label or tab_name)
    if index > 1 then
      tab_line = tab_line .. " "
      col = col + 1
    end
    local start_col = col
    tab_line = tab_line .. segment
    col = col + #segment
    tab_segments[#tab_segments + 1] = {
      start_col = start_col,
      end_col = col,
      active = tab_name == view.current_tab,
    }
  end

  add_line(render_data, tab_line)
  local tab_line_index = #render_data.lines - 1
  for _, segment in ipairs(tab_segments) do
    render_data.highlights[#render_data.highlights + 1] = {
      line = tab_line_index,
      start_col = segment.start_col,
      end_col = segment.end_col,
      group = segment.active and "TabLineSel" or "Comment",
    }
  end

  add_line(render_data, "")

  local current_def = TAB_DEFS[view.current_tab] or { label = view.current_tab }
  add_line(render_data, current_def.label, "Special")
  add_line(render_data, "")

  local items = tab_items(view)
  if vim.tbl_isempty(items) then
    add_line(render_data, "(no items)", "Comment")
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
      add_line(render_data, string.format("Showing %d/%d. Press gr to load more.", shown, total), "Comment")
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
  attach_buffer_metadata(bufnr, model, view)

  local target_line = view.cursor_by_tab[view.current_tab] or render_data.first_action_line or 1
  target_line = clamp_line(bufnr, target_line)
  view.cursor_by_tab[view.current_tab] = target_line

  local winid = current_win_for_buf(bufnr)
  if winid then
    pcall(vim.api.nvim_win_set_cursor, winid, { target_line, 0 })
    vim.api.nvim_set_option_value("wrap", true, { win = winid })
    vim.api.nvim_set_option_value("linebreak", true, { win = winid })
    vim.api.nvim_set_option_value("breakindent", true, { win = winid })
  end
end

local function current_action(view)
  local winid = current_win_for_buf(view.bufnr)
  if not winid then
    return nil
  end
  local line = vim.api.nvim_win_get_cursor(winid)[1]
  return view.line_actions[line]
end

local function execute_action(view, action, variant)
  if type(action) ~= "table" then
    return
  end

  if action.kind == "url" then
    open_url(action.url)
    return
  end

  if action.kind == "location" then
    if type(view.callbacks.open_location) == "function" and type(action.target) == "table" then
      view.callbacks.open_location(action.target)
      return
    end
    open_url(action.fallback_url)
    return
  end

  if action.kind == "commit" and type(action.commit) == "table" then
    if type(view.callbacks.open_commit_diff) == "function" then
      view.callbacks.open_commit_diff(action.commit)
      return
    end
    open_url(action.commit.url)
    return
  end

  if action.kind == "file" and type(action.file) == "table" then
    if variant == "original" and type(view.callbacks.open_file_original) == "function" then
      view.callbacks.open_file_original(action.file)
      return
    end
    if variant == "modified" and type(view.callbacks.open_file_modified) == "function" then
      view.callbacks.open_file_modified(action.file)
      return
    end
    if type(view.callbacks.open_file_diff) == "function" then
      view.callbacks.open_file_diff(action.file)
    end
  end
end

local function switch_tab(view, index)
  if index < 1 or index > #view.tabs then
    return
  end
  local next_tab = view.tabs[index]
  if next_tab == view.current_tab then
    return
  end

  save_cursor(view)
  view.current_tab = next_tab
  render(view)
end

local function shift_tab(view, step)
  local current = tab_index(view, view.current_tab)
  local next_index = ((current - 1 + step) % #view.tabs) + 1
  switch_tab(view, next_index)
end

local function run_more_current(view)
  local tab_def = TAB_DEFS[view.current_tab]
  if not tab_def or not tab_def.section then
    return
  end
  if type(view.callbacks.more_section) == "function" then
    view.callbacks.more_section(tab_def.section)
  end
end

local function map(bufnr, lhs, rhs, desc)
  vim.keymap.set("n", lhs, rhs, { buffer = bufnr, silent = true, nowait = true, desc = desc })
end

local function ensure_keymaps(view)
  if view.keymaps_set then
    return
  end
  view.keymaps_set = true

  local bufnr = view.bufnr
  local function with_view(fn)
    return function()
      local current = views[bufnr]
      if current then
        fn(current)
      end
    end
  end

  map(bufnr, "a", function()
    if type(view.callbacks.approve) == "function" then
      view.callbacks.approve()
    end
  end, "GH PR Overview: approve")
  map(bufnr, "d", function()
    if type(view.callbacks.request_changes) == "function" then
      view.callbacks.request_changes()
    end
  end, "GH PR Overview: request changes")
  map(bufnr, "c", function()
    if type(view.callbacks.comment) == "function" then
      view.callbacks.comment()
    end
  end, "GH PR Overview: comment")
  map(bufnr, "m", function()
    if type(view.callbacks.merge) == "function" then
      view.callbacks.merge()
    end
  end, "GH PR Overview: merge")
  map(bufnr, "k", function()
    if type(view.callbacks.checkout) == "function" then
      view.callbacks.checkout()
    end
  end, "GH PR Overview: checkout")
  map(bufnr, "R", function()
    if type(view.callbacks.refresh) == "function" then
      view.callbacks.refresh()
    end
  end, "GH PR Overview: refresh")
  map(bufnr, "o", function()
    if type(view.callbacks.open_url) == "function" then
      view.callbacks.open_url()
    end
  end, "GH PR Overview: open PR URL")
  map(bufnr, "q", function()
    if type(view.callbacks.close) == "function" then
      view.callbacks.close()
      return
    end
    if vim.api.nvim_buf_is_valid(bufnr) then
      pcall(vim.api.nvim_buf_delete, bufnr, { force = false })
    end
  end, "GH PR Overview: close")

  map(bufnr, "H", with_view(function(current)
    shift_tab(current, -1)
  end), "GH PR Overview: previous tab")
  map(bufnr, "L", with_view(function(current)
    shift_tab(current, 1)
  end), "GH PR Overview: next tab")
  map(bufnr, "<CR>", with_view(function(current)
    execute_action(current, current_action(current), "default")
  end), "GH PR Overview: open selection")
  map(bufnr, "D", with_view(function(current)
    execute_action(current, current_action(current), "default")
  end), "GH PR Overview: open diff for selection")
  map(bufnr, "O", with_view(function(current)
    execute_action(current, current_action(current), "original")
  end), "GH PR Overview: open original file")
  map(bufnr, "M", with_view(function(current)
    execute_action(current, current_action(current), "modified")
  end), "GH PR Overview: open modified file")
  map(bufnr, "gr", with_view(function(current)
    run_more_current(current)
  end), "GH PR Overview: load more for current tab")

  for index = 1, 9 do
    map(bufnr, tostring(index), with_view(function(current)
      switch_tab(current, index)
    end), "GH PR Overview: go to tab " .. tostring(index))
  end
end

local function sanitize_tabs(input_tabs)
  local selected = {}
  local seen = {}
  for _, tab_name in ipairs(type(input_tabs) == "table" and input_tabs or DEFAULT_TABS) do
    if type(tab_name) == "string" then
      local normalized = tab_name:lower()
      normalized = TAB_ALIASES[normalized] or normalized
      if TAB_DEFS[normalized] and not seen[normalized] then
        seen[normalized] = true
        selected[#selected + 1] = normalized
      end
    end
  end
  if vim.tbl_isempty(selected) then
    return vim.deepcopy(DEFAULT_TABS)
  end
  return selected
end

function M.open(model, opts)
  opts = opts or {}
  model = model or {}

  local Snacks = require("snacks")
  ensure_navigation_window()

  local bufnr = ensure_overview_buffer(model.number, opts.bufnr)
  if not valid_buf(bufnr) then
    bufnr = ensure_overview_buffer(model.number, nil)
  end
  if not valid_buf(bufnr) then
    error("Unable to create gh-pr overview buffer")
  end

  local tabs = sanitize_tabs(opts.tabs)
  local callbacks = opts.actions or {}

  callbacks.close = callbacks.close or function()
    if vim.api.nvim_buf_is_valid(bufnr) then
      pcall(vim.api.nvim_buf_delete, bufnr, { force = false })
    end
  end

  local view = views[bufnr] or {
    bufnr = bufnr,
    tabs = tabs,
    current_tab = tabs[1],
    cursor_by_tab = {},
    line_actions = {},
    keymaps_set = false,
  }

  view.tabs = tabs
  view.current_tab = TAB_ALIASES[view.current_tab] or view.current_tab
  view.current_tab = TAB_DEFS[view.current_tab] and view.current_tab or tabs[1]
  view.model = model
  view.callbacks = callbacks
  view.date_format = safe_string(opts.date_format, "%Y-%m-%d %H:%M")

  if type(opts.cursor_line) == "number" then
    view.cursor_by_tab[view.current_tab] = math.max(1, math.floor(opts.cursor_line))
  end

  views[bufnr] = view

  Snacks.win({
    show = true,
    buf = bufnr,
    position = "current",
    enter = true,
    fixbuf = false,
    keys = {
      q = false,
    },
    bo = {
      buftype = "nofile",
      bufhidden = "wipe",
      swapfile = false,
      modifiable = false,
      filetype = "ghpr_overview",
    },
    wo = {
      number = false,
      relativenumber = false,
      signcolumn = "no",
      wrap = true,
      linebreak = true,
      breakindent = true,
      cursorline = true,
      foldcolumn = "0",
      spell = false,
    },
  })

  ensure_keymaps(view)
  render(view)

  if not view.cleanup_registered then
    view.cleanup_registered = true
    vim.api.nvim_create_autocmd({ "BufWipeout", "BufDelete" }, {
      buffer = bufnr,
      once = true,
      callback = function()
        views[bufnr] = nil
      end,
    })
  end
end

return M
