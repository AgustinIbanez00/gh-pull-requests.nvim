local M = {}

local core = require("gh-pr.core.create_pull_request")
local comment_composer = require("gh-pr.comment_composer")
local multi_select = require("gh-pr.multi_select")
local overview_edit_picker = require("gh-pr.ui.overview.edit_picker")

local namespace = vim.api.nvim_create_namespace("gh-pr-create-pull-request")

local steps = {
  { key = "title", label = "Title" },
  { key = "body", label = "Description" },
  { key = "head", label = "Branch" },
  { key = "labels", label = "Labels" },
  { key = "reviewers", label = "Reviewers" },
  { key = "draft", label = "Draft" },
  { key = "review", label = "Review" },
}

local function normalize_string(value)
  if type(value) ~= "string" then
    return ""
  end
  return vim.trim(value)
end

local function normalize_title(value)
  return normalize_string(value):gsub("%s+", " ")
end

local function split_initial_lines(value)
  if type(value) ~= "string" or value == "" then
    return { "" }
  end
  local lines = vim.split(value, "\n", { plain = true })
  if vim.tbl_isempty(lines) then
    return { "" }
  end
  return lines
end

local function valid_buf(bufnr)
  return type(bufnr) == "number" and bufnr > 0 and vim.api.nvim_buf_is_valid(bufnr)
end

local function valid_win(winid)
  return type(winid) == "number" and winid > 0 and vim.api.nvim_win_is_valid(winid)
end

local function notify(level, message)
  if type(message) == "string" and message ~= "" then
    vim.notify(message, level)
  end
end

local function summarize_text(value, empty_label, limit)
  local text = normalize_string(value)
  if text == "" then
    return empty_label or "(empty)"
  end

  text = text:gsub("\n", " ")
  limit = tonumber(limit) or 72
  if #text > limit then
    return text:sub(1, limit - 3) .. "..."
  end
  return text
end

local function summarize_list(values)
  values = core.normalize_list(values)
  if vim.tbl_isempty(values) then
    return "(none)"
  end
  if #values <= 4 then
    return table.concat(values, ", ")
  end

  local preview = {}
  for index = 1, 3 do
    preview[#preview + 1] = values[index]
  end
  preview[#preview + 1] = string.format("+%d more", #values - 3)
  return table.concat(preview, ", ")
end

local function step_index_for_key(key)
  for index, step in ipairs(steps) do
    if step.key == key then
      return index
    end
  end
  return nil
end

local function current_step(state)
  return steps[state.step_index] or steps[#steps]
end

local function step_label_for_key(key)
  for _, step in ipairs(steps) do
    if step.key == key then
      return step.label
    end
  end
  return tostring(key or "field")
end

local function set_step_for_field(state, field)
  local index = step_index_for_key(field)
  if index then
    state.step_index = index
  end
end

local function repository_label(state)
  local repository = type(state.context.repository) == "table" and normalize_string(state.context.repository.full_name) or ""
  if repository == "" then
    return "(unknown repository)"
  end
  return repository
end

local function truncate_text(text, limit)
  text = type(text) == "string" and text or ""
  limit = tonumber(limit) or 0
  if limit <= 3 or #text <= limit then
    return text
  end
  return text:sub(1, limit - 3) .. "..."
end

local function window_width(state)
  if valid_win(state.winid) then
    local ok, width = pcall(vim.api.nvim_win_get_width, state.winid)
    if ok and type(width) == "number" and width > 0 then
      return width
    end
  end
  return tonumber(state.width) or 100
end

local function add_highlight(highlights, line, group, start_col, end_col)
  if type(group) ~= "string" or group == "" then
    return
  end
  highlights[#highlights + 1] = {
    line = line,
    group = group,
    start_col = tonumber(start_col) or 0,
    end_col = tonumber(end_col) or -1,
  }
end

local function add_line(lines, highlights, text, group)
  lines[#lines + 1] = text
  if group then
    add_highlight(highlights, #lines, group, 0, -1)
  end
end

local function status_highlight(status)
  if status == "complete" then
    return "GhPrCreateTabDone"
  end
  if status == "required_missing" or status == "invalid" then
    return "GhPrCreateTabWarn"
  end
  return "GhPrCreateTab"
end

local function status_text(status, message)
  if status == "complete" then
    return "Complete"
  end
  if status == "required_missing" then
    return message or "Required value missing"
  end
  if status == "invalid" then
    return message or "Invalid"
  end
  return message or "Optional value empty"
end

local function step_status(state, step)
  local key = type(step) == "table" and step.key or nil

  if key == "title" then
    if normalize_string(state.data.title) == "" then
      return "required_missing", "Title is required"
    end
    return "complete", "Complete"
  end

  if key == "body" then
    if normalize_string(state.data.body) == "" then
      return "optional_empty", "Optional description is empty"
    end
    return "complete", "Complete"
  end

  if key == "head" then
    if normalize_string(state.data.head) == "" then
      return "required_missing", "Head branch is required"
    end
    local ok, err = core.validate_head(state.data, state.context)
    if not ok then
      return "invalid", err
    end
    return "complete", "Complete"
  end

  if key == "labels" then
    if vim.tbl_isempty(core.normalize_list(state.data.labels)) then
      return "optional_empty", "No labels selected"
    end
    return "complete", "Complete"
  end

  if key == "reviewers" then
    if vim.tbl_isempty(core.normalize_list(state.data.reviewers)) then
      return "optional_empty", "No reviewers selected"
    end
    return "complete", "Complete"
  end

  if key == "draft" then
    return "complete", state.data.draft == true and "Draft pull request" or "Ready for review"
  end

  if key == "review" then
    if state.submitting == true then
      return "complete", "Creating pull request..."
    end
    local ok, err = core.validate_state(state.data, state.context)
    if not ok then
      return "invalid", err
    end
    return "complete", "Ready to create"
  end

  return "optional_empty", "Optional value empty"
end

local function build_tabline(state)
  local text = ""
  local ranges = {}
  local tabs = {}

  for index, step in ipairs(steps) do
    local status, message = step_status(state, step)
    local active = index == state.step_index
    local segment = string.format("%d %s", index, step.label)
    if status == "required_missing" or status == "invalid" then
      segment = segment .. "!"
    end
    if active then
      segment = "[" .. segment .. "]"
    end

    local prefix = text == "" and "" or "  "
    local start_col = #text + #prefix
    text = text .. prefix .. segment
    ranges[#ranges + 1] = {
      start_col = start_col,
      end_col = start_col + #segment,
      group = active and "GhPrCreateTabActive" or status_highlight(status),
    }
    tabs[#tabs + 1] = {
      index = index,
      key = step.key,
      label = step.label,
      status = status,
      message = message,
      active = active,
      group = ranges[#ranges].group,
    }
  end

  return text, ranges, tabs
end

local function render_title_panel(state, lines, highlights, status, message)
  add_line(lines, highlights, "Title", "GhPrCreateHint")
  add_line(lines, highlights, "Status: " .. status_text(status, message), status_highlight(status))
  add_line(lines, highlights, "Current: " .. summarize_text(state.data.title, "(required)", 92))
  add_line(lines, highlights, "")
  add_line(lines, highlights, "Action: <CR>/e or 1 opens the title composer.", "GhPrCreateMuted")
end

local function render_body_panel(state, lines, highlights, status, message)
  add_line(lines, highlights, "Description", "GhPrCreateHint")
  add_line(lines, highlights, "Status: " .. status_text(status, message), status_highlight(status))
  add_line(lines, highlights, "Current: " .. summarize_text(state.data.body, "(empty)", 92))
  add_line(lines, highlights, "")
  add_line(lines, highlights, "Action: <CR>/e or 2 opens the multiline composer.", "GhPrCreateMuted")
end

local function render_head_panel(state, lines, highlights, status, message)
  add_line(lines, highlights, "Branch", "GhPrCreateHint")
  add_line(lines, highlights, "Status: " .. status_text(status, message), status_highlight(status))
  add_line(lines, highlights, "Base: " .. (normalize_string(state.data.base) ~= "" and state.data.base or "(missing)") .. " (read-only)")
  add_line(lines, highlights, "Head: " .. (normalize_string(state.data.head) ~= "" and state.data.head or "(required)"))
  add_line(lines, highlights, "")
  add_line(lines, highlights, "Action: <CR>/e or 3 opens the branch selector.", "GhPrCreateMuted")
end

local function render_labels_panel(state, lines, highlights, status, message)
  add_line(lines, highlights, "Labels", "GhPrCreateHint")
  add_line(lines, highlights, "Status: " .. status_text(status, message), status_highlight(status))
  add_line(lines, highlights, "Selected: " .. summarize_list(state.data.labels))
  add_line(lines, highlights, "")
  add_line(lines, highlights, "Action: <CR>/e or 4 opens the preloaded label selector.", "GhPrCreateMuted")
end

local function render_reviewers_panel(state, lines, highlights, status, message)
  add_line(lines, highlights, "Reviewers", "GhPrCreateHint")
  add_line(lines, highlights, "Status: " .. status_text(status, message), status_highlight(status))
  add_line(lines, highlights, "Selected: " .. summarize_list(state.data.reviewers))
  add_line(lines, highlights, "")
  add_line(lines, highlights, "Action: <CR>/e or 5 opens the preloaded reviewer selector.", "GhPrCreateMuted")
end

local function render_draft_panel(state, lines, highlights, status, message)
  add_line(lines, highlights, "Draft", "GhPrCreateHint")
  add_line(lines, highlights, "Status: " .. status_text(status, message), status_highlight(status))
  add_line(lines, highlights, "Current: " .. (state.data.draft == true and "Draft" or "Ready for review"))
  add_line(lines, highlights, "")
  add_line(lines, highlights, "Action: <CR>/e or 6 opens the draft selector.", "GhPrCreateMuted")
end

local function render_review_panel(state, lines, highlights, status, message)
  add_line(lines, highlights, "Review", "GhPrCreateHint")
  add_line(lines, highlights, "Status: " .. status_text(status, message), status_highlight(status))
  if status ~= "complete" then
    local _, _, field = core.validate_state(state.data, state.context)
    add_line(lines, highlights, "Fix: " .. step_label_for_key(field), "GhPrCreateMuted")
    add_line(lines, highlights, "")
  end

  for _, line in ipairs(core.summary_lines(state.data, state.context)) do
    add_line(lines, highlights, "  " .. line)
  end

  add_line(lines, highlights, "")
  add_line(lines, highlights, "Action: <CR>/e or 7 opens the final confirmation.", "GhPrCreateMuted")
end

local function render_active_panel(state, lines, highlights, tabs)
  local active = current_step(state)
  local tab = tabs[state.step_index] or {}
  local status = tab.status
  local message = tab.message

  if active.key == "title" then
    render_title_panel(state, lines, highlights, status, message)
  elseif active.key == "body" then
    render_body_panel(state, lines, highlights, status, message)
  elseif active.key == "head" then
    render_head_panel(state, lines, highlights, status, message)
  elseif active.key == "labels" then
    render_labels_panel(state, lines, highlights, status, message)
  elseif active.key == "reviewers" then
    render_reviewers_panel(state, lines, highlights, status, message)
  elseif active.key == "draft" then
    render_draft_panel(state, lines, highlights, status, message)
  else
    render_review_panel(state, lines, highlights, status, message)
  end
end

local function branch_item_label(item)
  item = type(item) == "table" and item or {}
  local label = normalize_string(item.label) ~= "" and normalize_string(item.label) or normalize_string(item.value)
  local tags = {}
  if item.current == true then
    tags[#tags + 1] = "current"
  end
  if item.base == true then
    tags[#tags + 1] = "base"
  end
  if item.remote_available ~= true then
    tags[#tags + 1] = "not pushed"
  end
  if not vim.tbl_isempty(tags) then
    label = label .. " (" .. table.concat(tags, ", ") .. ")"
  end
  return label
end

local function selector_details(state)
  local repository = type(state.context.repository) == "table" and normalize_string(state.context.repository.full_name) or ""
  return {
    repository = repository,
    labels = {},
    reviewRequests = {},
  }
end

local function selector_context(state)
  return {
    normalize_repository = function(details)
      if type(details) == "table" and normalize_string(details.repository) ~= "" then
        return normalize_string(details.repository)
      end
      return type(state.context.repository) == "table" and normalize_string(state.context.repository.full_name) or nil
    end,
    notify_error = state.notify_error,
    notify_warn = state.notify_warn,
    pr_service = state.pr_service,
  }
end

local function close_window(state)
  if valid_win(state.winid) then
    pcall(vim.api.nvim_win_close, state.winid, true)
  end
end

local function restore_origin(state)
  if valid_win(state.origin_winid) then
    pcall(vim.api.nvim_set_current_win, state.origin_winid)
  end
end

local function finish(state)
  if state.finished then
    return
  end
  state.finished = true
  close_window(state)
  restore_origin(state)
end

local function handle_selector_failure(state, label, err, retry)
  state.notify_error(string.format("Unable to load %s: %s", label, tostring(err)))
  state.select({ "retry", "skip", "cancel" }, {
    prompt = string.format("Unable to load %s. Retry, skip this step, or cancel?", label),
  }, function(choice)
    if choice == "retry" then
      retry()
      return
    end
    if choice == "skip" then
      if label == "labels" then
        state.data.labels = {}
      elseif label == "reviewers" then
        state.data.reviewers = {}
      end
      M._advance(state)
      return
    end
    M._cancel(state)
  end)
end

local function open_title_step(state, done)
  state.open_composer({
    title = "New PR title",
    filetype = "text",
    border = "rounded",
    width_ratio = 0.72,
    height_ratio = 0.22,
    min_width = 64,
    min_height = 5,
    max_height = 10,
    initial_lines = { state.data.title ~= "" and state.data.title or "" },
    enter = true,
    on_cancel = function()
      done(nil, { cancelled = true })
    end,
    on_submit = function(text)
      done(normalize_title(text))
    end,
  })
end

local function open_body_step(state, done)
  state.open_composer({
    title = "New PR description",
    filetype = "markdown",
    border = "rounded",
    width_ratio = 0.90,
    height_ratio = 0.82,
    min_width = 90,
    min_height = 16,
    max_width = 220,
    max_height = 80,
    initial_lines = split_initial_lines(state.data.body),
    enter = true,
    on_cancel = function()
      done(nil, { cancelled = true })
    end,
    on_submit = function(text)
      done(type(text) == "string" and text or "")
    end,
  })
end

local function open_head_step(state, done)
  local candidates = type(state.context.head_candidates) == "table" and state.context.head_candidates or {}
  if vim.tbl_isempty(candidates) then
    state.notify_warn("No local or remote branches were found for PR creation")
    done(nil, { cancelled = true })
    return
  end

  state.select(candidates, {
    prompt = string.format("Select PR head branch (base is %s):", state.data.base),
    format_item = branch_item_label,
  }, function(choice)
    if type(choice) ~= "table" then
      done(nil, { cancelled = true })
      return
    end
    done(normalize_string(choice.value))
  end)
end

local function open_label_step(state, done)
  local details = selector_details(state)
  local ctx = selector_context(state)
  local labels, err = overview_edit_picker.load_label_candidates(details, ctx)
  if not labels then
    handle_selector_failure(state, "labels", err, function()
      open_label_step(state, done)
    end)
    return
  end

  state.open_multi_select({
    title = "New PR - Labels",
    items = overview_edit_picker.build_label_items(labels, state.data.labels),
    on_confirm = function(values)
      done(values or {})
    end,
    on_cancel = function()
      done(nil, { cancelled = true })
    end,
  })
end

local function open_reviewer_step(state, done)
  local details = selector_details(state)
  local ctx = selector_context(state)
  local candidates, err = overview_edit_picker.load_reviewer_candidates(details, ctx)
  if not candidates then
    handle_selector_failure(state, "reviewers", err, function()
      open_reviewer_step(state, done)
    end)
    return
  end

  for _, warning in ipairs(type(candidates.warnings) == "table" and candidates.warnings or {}) do
    state.notify_warn(warning)
  end

  state.open_multi_select({
    title = "New PR - Reviewers",
    items = overview_edit_picker.build_reviewer_items(candidates, state.data.reviewers),
    on_confirm = function(values)
      done(values or {})
    end,
    on_cancel = function()
      done(nil, { cancelled = true })
    end,
  })
end

local function open_draft_step(state, done)
  local choices = {
    { label = "Ready for review", value = false },
    { label = "Draft", value = true },
  }

  state.select(choices, {
    prompt = "Create as draft?",
    format_item = function(item)
      return item.label
    end,
  }, function(choice)
    if type(choice) ~= "table" then
      done(nil, { cancelled = true })
      return
    end
    done(choice.value == true)
  end)
end

local function default_handlers()
  return {
    title = open_title_step,
    body = open_body_step,
    head = open_head_step,
    labels = open_label_step,
    reviewers = open_reviewer_step,
    draft = open_draft_step,
  }
end

local function default_confirm_create(state, callback)
  state.select({ "create", "back", "cancel" }, {
    prompt = "Create this pull request?",
  }, function(choice)
    if choice == "create" then
      callback(true)
      return
    end
    if choice == "back" then
      callback("back")
      return
    end
    callback(false)
  end)
end

local function offer_open_overview(state, result)
  if type(result) ~= "table" or type(result.number) ~= "number" or type(state.open_overview) ~= "function" then
    return
  end

  state.select({ "open overview", "close" }, {
    prompt = string.format("Open PR #%d overview?", result.number),
  }, function(choice)
    if choice == "open overview" then
      state.open_overview(result.number)
    end
  end)
end

local function submit_review_step(state)
  local ok, err, field = core.validate_state(state.data, state.context)
  if not ok then
    state.notify_warn(err)
    set_step_for_field(state, field)
    M.render(state)
    return
  end

  state.confirm_create(state, function(confirmed)
    if confirmed == "back" then
      M._back(state)
      return
    end
    if confirmed ~= true then
      M.render(state)
      return
    end

    state.submitting = true
    M.render(state)
    state.notify_info("Creating pull request...")
    state.submit(state, function(result, submit_err)
      state.submitting = false
      if submit_err then
        state.notify_error(submit_err)
        M.render(state)
        return
      end

      local message = "Pull request created"
      if type(result) == "table" and type(result.number) == "number" then
        message = string.format("Pull request #%d created", result.number)
      end
      if type(result) == "table" and normalize_string(result.url) ~= "" then
        message = message .. ": " .. result.url
      end
      state.notify_info(message)
      finish(state)
      state.refresh_sources({ force = true })
      offer_open_overview(state, result)
    end)
  end)
end

function M._new_session(opts)
  opts = type(opts) == "table" and opts or {}
  local context = type(opts.context) == "table" and opts.context or {}
  local data = core.new_state(context)
  if type(opts.initial_state) == "table" then
    data = vim.tbl_extend("force", data, vim.deepcopy(opts.initial_state))
  end
  if normalize_string(data.base) == "" then
    data.base = normalize_string(context.default_branch)
  end
  if normalize_string(data.head) == "" then
    data.head = normalize_string(context.current_branch)
  end

  local handlers = default_handlers()
  if type(opts.handlers) == "table" then
    handlers = vim.tbl_extend("force", handlers, opts.handlers)
  end
  local step_index = math.max(1, math.min(#steps, tonumber(opts.step_index) or 1))

  return {
    context = context,
    data = data,
    step_index = step_index,
    bufnr = opts.bufnr,
    winid = opts.winid,
    origin_winid = opts.origin_winid,
    finished = false,
    submitting = false,
    handlers = handlers,
    pr_service = opts.pr_service or context.pr_service or require("gh-pr.pr_service"),
    open_composer = opts.open_composer or function(composer_opts)
      return comment_composer.open(composer_opts)
    end,
    open_multi_select = opts.open_multi_select or function(select_opts)
      return multi_select.open(select_opts)
    end,
    select = opts.select or function(items, select_opts, callback)
      return vim.ui.select(items, select_opts, callback)
    end,
    confirm_create = opts.confirm_create or default_confirm_create,
    submit = opts.submit or function(session, callback)
      core.submit(session.data, session.context, callback)
    end,
    refresh_sources = opts.refresh_sources or function() end,
    open_overview = opts.open_overview,
    setup_highlights = opts.setup_highlights or function()
      local ok, highlights = pcall(require, "gh-pr.highlights")
      if ok and type(highlights.setup) == "function" then
        highlights.setup()
      end
    end,
    notify_error = opts.notify_error or function(message)
      notify(vim.log.levels.ERROR, message)
    end,
    notify_info = opts.notify_info or function(message)
      notify(vim.log.levels.INFO, message)
    end,
    notify_warn = opts.notify_warn or function(message)
      notify(vim.log.levels.WARN, message)
    end,
  }
end

function M.render(state)
  if type(state) ~= "table" or not valid_buf(state.bufnr) then
    return
  end

  if type(state.setup_highlights) == "function" then
    pcall(state.setup_highlights)
  end

  local width = window_width(state)
  local lines = {}
  local highlights = {}
  local header = string.format(
    "Repo: %s  Base: %s  Head: %s",
    repository_label(state),
    normalize_string(state.data.base) ~= "" and state.data.base or "(missing)",
    normalize_string(state.data.head) ~= "" and state.data.head or "(missing)"
  )
  local hint = "1-7 jump+edit | h/l or arrows move | <CR>/e edit | q/Esc cancel"
  local tabline, ranges, tabs = build_tabline(state)

  add_line(lines, highlights, "Create pull request", "GhPrCreateHint")
  add_line(lines, highlights, truncate_text(header, width), "GhPrCreateMuted")
  add_line(lines, highlights, truncate_text(hint, width), "GhPrCreateMuted")
  add_line(lines, highlights, "")

  local tabline_line = #lines + 1
  add_line(lines, highlights, truncate_text(tabline, width))
  for _, range in ipairs(ranges) do
    if range.start_col < width then
      add_highlight(highlights, tabline_line, range.group, range.start_col, math.min(range.end_col, width))
    end
  end

  add_line(lines, highlights, "")
  render_active_panel(state, lines, highlights, tabs)

  vim.api.nvim_buf_set_option(state.bufnr, "modifiable", true)
  vim.api.nvim_buf_set_lines(state.bufnr, 0, -1, false, lines)
  vim.api.nvim_buf_clear_namespace(state.bufnr, namespace, 0, -1)
  for _, item in ipairs(highlights) do
    local line = (tonumber(item.line) or 1) - 1
    if line >= 0 and line < #lines then
      pcall(
        vim.api.nvim_buf_add_highlight,
        state.bufnr,
        namespace,
        item.group or "Normal",
        line,
        tonumber(item.start_col) or 0,
        tonumber(item.end_col) or -1
      )
    end
  end
  vim.api.nvim_buf_set_option(state.bufnr, "modifiable", false)
  pcall(vim.api.nvim_set_option_value, "modified", false, { buf = state.bufnr })

  state.last_render = {
    lines = vim.deepcopy(lines),
    highlights = vim.deepcopy(highlights),
    tabs = vim.deepcopy(tabs),
  }
  return state.last_render
end

function M._advance(state)
  if type(state) ~= "table" then
    return
  end
  state.step_index = math.min(#steps, (tonumber(state.step_index) or 1) + 1)
  M.render(state)
end

function M._back(state)
  if type(state) ~= "table" then
    return
  end
  state.step_index = math.max(1, (tonumber(state.step_index) or 1) - 1)
  M.render(state)
end

function M._focus(state, index)
  if type(state) ~= "table" then
    return
  end
  local next_index = tonumber(index)
  if not next_index then
    return
  end
  state.step_index = math.max(1, math.min(#steps, next_index))
  M.render(state)
end

function M._jump_activate(state, index)
  if type(state) ~= "table" or state.submitting == true then
    return
  end
  M._focus(state, index)
  M._activate(state)
end

function M._cancel(state)
  if type(state) ~= "table" then
    return
  end
  finish(state)
  state.notify_info("Pull request creation cancelled")
end

function M._complete_step(state, key, value, opts)
  opts = type(opts) == "table" and opts or {}
  if opts.cancelled == true then
    M.render(state)
    return
  end

  if key == "title" then
    local title = normalize_title(value)
    if title == "" then
      state.notify_warn("Title cannot be empty")
      M.render(state)
      return
    end
    state.data.title = title
  elseif key == "body" then
    state.data.body = type(value) == "string" and value or ""
  elseif key == "head" then
    state.data.head = normalize_string(value)
    local ok, err = core.validate_head(state.data, state.context)
    if not ok then
      state.notify_warn(err)
      M.render(state)
      return
    end
  elseif key == "labels" then
    state.data.labels = core.normalize_list(value)
  elseif key == "reviewers" then
    state.data.reviewers = core.normalize_list(value)
  elseif key == "draft" then
    state.data.draft = value == true
  end

  M._advance(state)
end

function M._activate(state)
  if type(state) ~= "table" or state.submitting == true then
    return
  end

  local step = current_step(state)
  if step.key == "review" then
    submit_review_step(state)
    return
  end

  local handler = state.handlers[step.key]
  if type(handler) ~= "function" then
    state.notify_error("Missing PR creation step handler: " .. tostring(step.key))
    return
  end

  handler(state, function(value, opts)
    M._complete_step(state, step.key, value, opts)
  end)
end

local function setup_keymaps(state)
  local opts = {
    buffer = state.bufnr,
    silent = true,
    nowait = true,
  }

  vim.keymap.set("n", "<CR>", function()
    M._activate(state)
  end, vim.tbl_extend("force", opts, { desc = "Activate PR creation tab" }))
  vim.keymap.set("n", "e", function()
    M._activate(state)
  end, vim.tbl_extend("force", opts, { desc = "Activate PR creation tab" }))
  vim.keymap.set("n", "h", function()
    M._back(state)
  end, vim.tbl_extend("force", opts, { desc = "Previous PR creation tab" }))
  vim.keymap.set("n", "<Left>", function()
    M._back(state)
  end, vim.tbl_extend("force", opts, { desc = "Previous PR creation tab" }))
  vim.keymap.set("n", "l", function()
    M._advance(state)
  end, vim.tbl_extend("force", opts, { desc = "Next PR creation tab" }))
  vim.keymap.set("n", "<Right>", function()
    M._advance(state)
  end, vim.tbl_extend("force", opts, { desc = "Next PR creation tab" }))
  vim.keymap.set("n", "p", function()
    M._back(state)
  end, vim.tbl_extend("force", opts, { desc = "Previous PR creation tab" }))
  vim.keymap.set("n", "b", function()
    M._back(state)
  end, vim.tbl_extend("force", opts, { desc = "Previous PR creation tab" }))
  for index = 1, #steps do
    vim.keymap.set("n", tostring(index), function()
      M._jump_activate(state, index)
    end, vim.tbl_extend("force", opts, { desc = string.format("Open PR creation tab %d", index) }))
  end
  vim.keymap.set("n", "q", function()
    M._cancel(state)
  end, vim.tbl_extend("force", opts, { desc = "Cancel PR creation wizard" }))
  vim.keymap.set("n", "<Esc>", function()
    M._cancel(state)
  end, vim.tbl_extend("force", opts, { desc = "Cancel PR creation wizard" }))
end

local function open_window(state)
  local max_width = math.max(40, vim.o.columns - 4)
  local width = math.min(110, max_width, math.max(76, math.floor(vim.o.columns * 0.86)))
  local height = math.max(18, math.min(34, math.floor((vim.o.lines - vim.o.cmdheight - 1) * 0.70)))
  local row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1)
  local col = math.max(0, math.floor((vim.o.columns - width) / 2))

  state.origin_winid = vim.api.nvim_get_current_win()
  state.bufnr = vim.api.nvim_create_buf(false, true)
  state.width = width
  vim.api.nvim_buf_set_option(state.bufnr, "buftype", "nofile")
  vim.api.nvim_buf_set_option(state.bufnr, "bufhidden", "wipe")
  vim.api.nvim_buf_set_option(state.bufnr, "swapfile", false)
  vim.api.nvim_buf_set_option(state.bufnr, "modifiable", false)
  vim.api.nvim_buf_set_option(state.bufnr, "filetype", "ghpr_create")

  state.winid = vim.api.nvim_open_win(state.bufnr, true, {
    relative = "editor",
    row = row,
    col = col,
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    title = "Create GitHub pull request",
    title_pos = "center",
    noautocmd = true,
  })

  vim.api.nvim_win_set_option(state.winid, "wrap", false)
  vim.api.nvim_win_set_option(state.winid, "cursorline", true)
  vim.api.nvim_win_set_option(state.winid, "number", false)
  vim.api.nvim_win_set_option(state.winid, "relativenumber", false)
  vim.api.nvim_win_set_option(state.winid, "signcolumn", "no")
  vim.api.nvim_win_set_option(state.winid, "winhl", "NormalFloat:NormalFloat,FloatBorder:FloatBorder")

  setup_keymaps(state)
  M.render(state)

  vim.api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(state.winid),
    once = true,
    callback = function()
      if not state.finished then
        state.finished = true
        restore_origin(state)
      end
    end,
  })
end

function M.open(opts)
  opts = type(opts) == "table" and opts or {}
  local notify_error = opts.notify_error or function(message)
    notify(vim.log.levels.ERROR, message)
  end

  local context = opts.context
  if type(context) ~= "table" then
    local resolved, err = core.resolve_context(opts.context_opts or opts)
    if not resolved then
      notify_error(err)
      return nil, err
    end
    context = resolved
  end

  context.gh = context.gh or opts.gh
  context.pr_service = context.pr_service or opts.pr_service

  local state = M._new_session(vim.tbl_extend("force", opts, {
    context = context,
  }))
  open_window(state)
  return state, nil
end

return M
