local M = {}

local config = require("gh-pr.config")
local overview = require("gh-pr.overview")
local pr_service = require("gh-pr.pr_service")
local state = require("gh-pr.state")
local thread_popup = require("gh-pr.thread_popup")
local virtual_files = require("gh-pr.virtual_files")

local function normalize_repository(details)
  local repository = details.baseRepository or details.headRepository
  if not repository then
    local resolved, _ = pr_service.resolve_repository()
    return resolved and resolved.full_name or nil
  end

  if type(repository.nameWithOwner) == "string" then
    return repository.nameWithOwner
  end

  local owner
  if type(repository.owner) == "table" then
    owner = repository.owner.login
  else
    owner = repository.owner
  end

  local name = repository.name
  if not name and type(repository.nameWithOwner) == "string" then
    local _, parsed = repository.nameWithOwner:match("^([^/]+)/(.+)$")
    name = parsed
  end

  if type(owner) == "string" and type(name) == "string" then
    return owner .. "/" .. name
  end

  local resolved, _ = pr_service.resolve_repository()
  return resolved and resolved.full_name or nil
end

local function notify_error(err)
  if err then
    vim.notify(err, vim.log.levels.ERROR)
  end
end

local function notify_info(message)
  vim.notify(message, vim.log.levels.INFO)
end

local function notify_warn(message)
  vim.notify(message, vim.log.levels.WARN)
end

local function positive_integer(value, fallback)
  local number = tonumber(value)
  if not number then
    return fallback
  end

  number = math.floor(number)
  if number < 1 then
    return fallback
  end

  return number
end

local function valid_overview_sections()
  return {
    checks = true,
    commits = true,
    timeline = true,
  }
end

local function normalize_overview_limits(input)
  local overview_config = (config.get() or {}).overview or {}
  local defaults = overview_config.max_items or {}
  local limits = type(input) == "table" and vim.deepcopy(input) or {}

  limits.checks = positive_integer(limits.checks, positive_integer(defaults.checks, 10))
  limits.commits = positive_integer(limits.commits, positive_integer(defaults.commits, 10))
  limits.timeline = positive_integer(
    limits.timeline,
    positive_integer(defaults.timeline, math.max(positive_integer(defaults.comments, 30), positive_integer(defaults.reviews, 30)))
  )
  limits.comments = positive_integer(limits.comments, limits.timeline)
  limits.reviews = positive_integer(limits.reviews, limits.timeline)
  limits.threads = positive_integer(limits.threads, limits.timeline)
  limits.timeline = math.max(limits.timeline, limits.comments, limits.reviews, limits.threads)

  return limits
end

local function current_overview_limits()
  local bufnr = vim.api.nvim_get_current_buf()
  local stored = vim.b[bufnr].gh_pr_overview_limits
  return normalize_overview_limits(type(stored) == "table" and stored or nil)
end

local function line_comment_options()
  local options = (config.get() or {}).line_comments or {}
  return {
    enabled = options.enabled ~= false,
    show_resolved = options.show_resolved ~= false,
    show_outdated = options.show_outdated ~= false,
    keymap = type(options.keymap) == "string" and options.keymap ~= "" and options.keymap or "K",
    signs = type(options.signs) == "table" and options.signs or {},
    max_popup_width = positive_integer(options.max_popup_width, 90),
    max_popup_height = positive_integer(options.max_popup_height, 18),
  }
end

local function build_line_comment_context(pr_number)
  local options = line_comment_options()
  if not options.enabled then
    return nil
  end

  local threads, thread_err = pr_service.fetch_review_threads(pr_number, {
    threads_first = 100,
    comments_first = 100,
  })

  if not threads then
    notify_warn("Unable to load line comments for this PR: " .. tostring(thread_err))
    return nil
  end

  local index = pr_service.build_line_comment_index(threads, {
    show_resolved = options.show_resolved,
    show_outdated = options.show_outdated,
  })

  return {
    index = index,
    keymap = options.keymap,
    signs = options.signs,
    max_popup_width = options.max_popup_width,
    max_popup_height = options.max_popup_height,
  }
end

local function find_file_in_details(details, path)
  if not details or type(details.files) ~= "table" then
    return nil
  end

  for _, file in ipairs(details.files) do
    if file.path == path or file.filename == path then
      return file
    end
  end

  return nil
end

local function resolve_file(file)
  if file then
    return file
  end

  local active_file = state.get_active_file()
  if active_file then
    return active_file
  end

  local path = vim.b.gh_pr_path
  if type(path) == "string" and path ~= "" then
    local _, details = state.get_active_pr()
    return find_file_in_details(details, path)
  end

  return nil
end

local function resolve_pr_number(number)
  if type(number) == "number" then
    return number
  end

  if type(number) == "string" and number ~= "" then
    local parsed = tonumber(number)
    if parsed then
      return parsed
    end
  end

  if type(vim.b.gh_pr_number) == "number" then
    return vim.b.gh_pr_number
  end

  local active_pr = state.get_active_pr()
  if active_pr and active_pr.number then
    return active_pr.number
  end

  return nil
end

local function has_full_pr_details(details)
  if type(details) ~= "table" then
    return false
  end

  if type(details.files) == "table" then
    return true
  end

  if type(details.baseRepository) == "table" or type(details.headRepository) == "table" then
    return true
  end

  if type(details.body) == "string" then
    return true
  end

  return false
end

local function resolve_active_pr(number, opts)
  opts = opts or {}
  local target = resolve_pr_number(number)
  if not target then
    return nil, nil, "No active pull request selected"
  end

  local active_pr, active_details = state.get_active_pr()
  if active_pr
    and active_pr.number == target
    and active_details
    and opts.refresh ~= true
    and has_full_pr_details(active_details) then
    return active_pr, active_details, nil
  end

  local details, err = pr_service.fetch_details(target)
  if not details then
    return nil, nil, err
  end

  state.set_active_pr(details, details)
  return details, details, nil
end

local function jump_to_line(line)
  local target = tonumber(line)
  if not target or target < 1 then
    return
  end

  local bufnr = vim.api.nvim_get_current_buf()
  local last = vim.api.nvim_buf_line_count(bufnr)
  local clamped = math.max(1, math.min(last, math.floor(target)))
  pcall(vim.api.nvim_win_set_cursor, 0, { clamped, 0 })
end

local function window_filetype(winid)
  if not winid or not vim.api.nvim_win_is_valid(winid) then
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
  return vim.api.nvim_get_current_win()
end

local preview_window = {
  tabid = nil,
  winid = nil,
}

local function preview_options()
  local options = (((config.get() or {}).line_comments or {}).comments_tree or {}).preview or {}
  return {
    keymap = type(options.keymap) == "string" and options.keymap ~= "" and options.keymap or "p",
    position = options.position == "right" and options.position or "right",
    keep_focus = options.keep_focus ~= false,
  }
end

local function valid_window(winid)
  return type(winid) == "number" and winid > 0 and vim.api.nvim_win_is_valid(winid)
end

local function is_marked_preview_window(winid)
  if not valid_window(winid) or window_filetype(winid) == "neo-tree" then
    return false
  end

  local ok, value = pcall(vim.api.nvim_win_get_var, winid, "gh_pr_comments_preview")
  return ok and value == true
end

local function mark_preview_window(winid)
  if valid_window(winid) then
    pcall(vim.api.nvim_win_set_var, winid, "gh_pr_comments_preview", true)
  end
end

local function ensure_preview_window(position)
  local current_tab = vim.api.nvim_get_current_tabpage()
  if preview_window.tabid == current_tab and valid_window(preview_window.winid) and window_filetype(preview_window.winid) ~= "neo-tree" then
    return preview_window.winid
  end

  for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(current_tab)) do
    if is_marked_preview_window(winid) then
      preview_window.tabid = current_tab
      preview_window.winid = winid
      return winid
    end
  end

  if position == "right" then
    vim.cmd("botright vsplit")
  else
    vim.cmd("vsplit")
  end

  local created = vim.api.nvim_get_current_win()
  mark_preview_window(created)
  preview_window.tabid = current_tab
  preview_window.winid = created
  return created
end

local function resolve_comment_target(target)
  if type(target) ~= "table" then
    return nil, nil, nil, nil, "Invalid comment target"
  end

  local pr = target.pr
  local details = target.details
  if type(pr) ~= "table" or type(details) ~= "table" then
    local resolved_pr, resolved_details, err = resolve_active_pr(target.pr_number or target.number, { refresh = false })
    if not resolved_pr then
      return nil, nil, nil, nil, err
    end
    pr = resolved_pr
    details = resolved_details
  end

  state.set_active_pr(pr, details)

  local path = target.path
  if type(path) ~= "string" or path == "" then
    return nil, nil, nil, nil, "Missing comment path"
  end

  local file = find_file_in_details(details, path) or {
    path = path,
    filename = path,
  }
  state.set_active_file(file)

  local side = type(target.side) == "string" and target.side or "head"
  local line = side == "base" and (target.original_line or target.line) or (target.line or target.original_line)
  local popup_comments = nil
  if type(target.thread_comments) == "table" and not vim.tbl_isempty(target.thread_comments) then
    popup_comments = target.thread_comments
  elseif type(target.line_comments) == "table" and not vim.tbl_isempty(target.line_comments) then
    popup_comments = target.line_comments
  end

  local popup_thread = nil
  if type(popup_comments) == "table" then
    popup_thread = {
      thread_id = type(target.thread_id) == "string" and target.thread_id ~= ""
          and target.thread_id
        or string.format("line:%s:%s:%s", path, side, tostring(line or 0)),
      path = path,
      side = side,
      line = tonumber(target.line) or tonumber(line) or tonumber(target.original_line),
      original_line = tonumber(target.original_line) or tonumber(line) or tonumber(target.line),
      selected_comment_id = type(target.selected_comment_id) == "string" and target.selected_comment_id or "",
      is_resolved = target.thread_is_resolved == true,
      is_outdated = target.thread_is_outdated == true,
      comments = {},
    }

    for index, item in ipairs(popup_comments) do
      if type(item) == "table" then
        popup_thread.comments[#popup_thread.comments + 1] = {
          id = type(item.id) == "string" and item.id ~= "" and item.id or tostring(index),
          author = type(item.author) == "string" and item.author ~= "" and item.author or "unknown",
          created_at = type(item.created_at) == "string" and item.created_at or "",
          body = type(item.body) == "string" and item.body or "",
          url = type(item.url) == "string" and item.url or "",
          state = type(item.state) == "string" and item.state or "",
          outdated = item.outdated == true,
        }
      end
    end
  end

  return file, side, line, popup_thread, nil
end

local function open_target_file(file, side, line)
  if side == "base" then
    M.open_original(file)
  else
    M.open_modified(file)
  end
  jump_to_line(line)
end

function M.set_active_pr(pr, details)
  state.set_active_pr(pr, details)
end

function M.set_active_file(file)
  state.set_active_file(file)
end

function M.activate_pr(number, refresh)
  local pr, details, err = resolve_active_pr(number, { refresh = refresh == true })
  if not pr then
    return nil, nil, err
  end
  return pr, details, nil
end

function M.open_comment_location(target, opts)
  opts = opts or {}
  local file, side, line, popup_thread, err = resolve_comment_target(target)
  if not file then
    return notify_error(err)
  end

  local comments_tree_options = (((config.get() or {}).line_comments or {}).comments_tree or {})
  local open_thread_popup = comments_tree_options.auto_open_thread_popup ~= false
  if type(opts.open_thread_popup) == "boolean" then
    open_thread_popup = opts.open_thread_popup
  end

  ensure_navigation_window()
  open_target_file(file, side, line)

  if open_thread_popup and popup_thread and type(popup_thread.comments) == "table" and not vim.tbl_isempty(popup_thread.comments) then
    local current_buf = vim.api.nvim_get_current_buf()
    local current_win = vim.api.nvim_get_current_win()
    local ok, popup_err = thread_popup.open(popup_thread, {
      mode = opts.popup_mode == "preview" and "preview" or "open",
      origin_bufnr = current_buf,
      anchor_win = current_win,
      enter = opts.focus_thread_popup,
    })
    if not ok and popup_err ~= "thread popup disabled by config" and popup_err ~= "thread has no comments" then
      notify_warn("Unable to open thread popup: " .. tostring(popup_err))
    end
  end
end

function M.preview_comment_location(target, opts)
  opts = opts or {}
  local file, side, line, popup_thread, err = resolve_comment_target(target)
  if not file then
    return notify_error(err)
  end

  local comments_tree_options = (((config.get() or {}).line_comments or {}).comments_tree or {})
  local open_thread_popup = comments_tree_options.auto_open_thread_popup ~= false
  if type(opts.open_thread_popup) == "boolean" then
    open_thread_popup = opts.open_thread_popup
  end

  local preview_opts = preview_options()
  local origin_window = vim.api.nvim_get_current_win()
  local preview_win = ensure_preview_window(preview_opts.position)
  if not valid_window(preview_win) then
    return notify_error("Unable to open preview window")
  end

  local switched, switch_err = pcall(vim.api.nvim_set_current_win, preview_win)
  if not switched then
    return notify_error("Unable to focus preview window: " .. tostring(switch_err))
  end

  open_target_file(file, side, line)
  local popup_focused = false

  if open_thread_popup and popup_thread and type(popup_thread.comments) == "table" and not vim.tbl_isempty(popup_thread.comments) then
    local preview_buf = vim.api.nvim_get_current_buf()
    local ok, popup_err = thread_popup.open(popup_thread, {
      mode = opts.popup_mode == "open" and "open" or "preview",
      origin_bufnr = preview_buf,
      anchor_win = preview_win,
      enter = opts.focus_thread_popup,
    })
    if ok then
      popup_focused = vim.api.nvim_get_current_win() ~= preview_win
    end
    if not ok and popup_err ~= "thread popup disabled by config" and popup_err ~= "thread has no comments" then
      notify_warn("Unable to open thread popup: " .. tostring(popup_err))
    end
  end

  if preview_opts.keep_focus and valid_window(origin_window) and not popup_focused then
    pcall(vim.api.nvim_set_current_win, origin_window)
  end
end

local function build_overview_callbacks(pr_number)
  return {
    approve = function()
      M.review("approve")
    end,
    request_changes = function()
      M.review("request_changes")
    end,
    comment = function()
      M.review("comment")
    end,
    merge = function()
      M.merge()
    end,
    checkout = function()
      M.checkout(pr_number)
    end,
    refresh = function()
      M.refresh_overview()
    end,
    open_url = function()
      M.open_overview_url(pr_number)
    end,
    open_comments_tree = function()
      M.open_comments(pr_number)
    end,
    edit_stub = function(kind, payload)
      M.overview_edit_stub(kind, payload)
    end,
    more_section = function(section)
      M.overview_more(section)
    end,
    open_location = function(target)
      M.open_comment_location(target)
    end,
    open_commit_diff = function(commit)
      M.open_commit_diff(commit)
    end,
    open_file_diff = function(file)
      M.open_diff(file)
    end,
    open_file_original = function(file)
      M.open_original(file)
    end,
    open_file_modified = function(file)
      M.open_modified(file)
    end,
  }
end

function M.open_overview(number, opts)
  opts = opts or {}
  local pr, details, err = resolve_active_pr(number, { refresh = opts.refresh == true })
  if not pr then
    return notify_error(err)
  end

  local overview_config = (config.get() or {}).overview or {}
  local limits = normalize_overview_limits(opts.overview_limits)
  local threads, thread_err = pr_service.fetch_review_threads(pr.number, {
    threads_first = limits.threads,
    comments_first = math.min(100, limits.threads * 4),
  })

  if not threads then
    threads = {}
  end

  local repository = normalize_repository(details) or ""
  local model = pr_service.build_overview_model(details, threads, limits, {
    repository = repository,
    thread_error = thread_err,
  })

  overview.open(model, {
    bufnr = opts.reuse_buffer and vim.api.nvim_get_current_buf() or nil,
    cursor_line = opts.cursor_line,
    ui = overview_config.ui or "snacks",
    layout = overview_config.layout or "tabs",
    window = overview_config.window or {},
    theme = overview_config.theme or {},
    tabs = overview_config.tabs,
    show = overview_config.show or {},
    date_format = overview_config.date_format or "%Y-%m-%d %H:%M",
    actions = build_overview_callbacks(pr.number),
  })
end

function M.refresh_overview()
  local bufnr = vim.api.nvim_get_current_buf()
  local number = vim.b[bufnr].gh_pr_number
  if type(number) ~= "number" then
    return notify_error("Current buffer is not a gh-pr overview")
  end

  local cursor = vim.api.nvim_win_get_cursor(0)
  M.open_overview(number, {
    refresh = true,
    reuse_buffer = true,
    cursor_line = cursor[1],
    overview_limits = current_overview_limits(),
  })
end

function M.overview_more(section, count)
  section = type(section) == "string" and section:lower() or ""
  if section == "comments" or section == "reviews" or section == "threads" then
    section = "timeline"
  end
  if not valid_overview_sections()[section] then
    return notify_error("Section must be one of: checks, commits, timeline")
  end

  local bufnr = vim.api.nvim_get_current_buf()
  local number = vim.b[bufnr].gh_pr_number
  if type(number) ~= "number" then
    return notify_error("Current buffer is not a gh-pr overview")
  end

  local overview_config = (config.get() or {}).overview or {}
  local step = positive_integer(count, positive_integer(overview_config.expand_step, 20))
  local limits = current_overview_limits()
  if section == "timeline" then
    limits.timeline = positive_integer(limits.timeline, step) + step
    limits.comments = limits.timeline
    limits.reviews = limits.timeline
    limits.threads = limits.timeline
  else
    limits[section] = positive_integer(limits[section], step) + step
  end

  local cursor = vim.api.nvim_win_get_cursor(0)
  M.open_overview(number, {
    refresh = true,
    reuse_buffer = true,
    cursor_line = cursor[1],
    overview_limits = limits,
  })
end

function M.open_overview_url(number)
  local pr, _, err = resolve_active_pr(number)
  if not pr then
    return notify_error(err)
  end

  local ok, open_err = pr_service.open_in_browser(pr.number)
  if not ok then
    if vim.ui and type(vim.ui.open) == "function" and type(pr.url) == "string" and pr.url ~= "" then
      vim.ui.open(pr.url)
      return
    end
    return notify_error(open_err)
  end
end

function M.open_comments(number)
  local pr, _, err = resolve_active_pr(number)
  if not pr then
    return notify_error(err)
  end

  local command = string.format("GhPrComments %d", pr.number)
  local ok, run_err = pcall(vim.cmd, command)
  if not ok then
    return notify_error("Unable to open Comments PR view: " .. tostring(run_err))
  end
end

local overview_edit_labels = {
  edit_title = "Edit title",
  edit_body = "Edit description",
  edit_labels = "Edit labels",
  edit_reviewers = "Edit reviewers",
  edit_assignees = "Edit assignees",
  edit_milestone = "Edit milestone",
  change_state = "Change state",
  change_draft = "Change draft status",
}

local function normalize_string(value)
  if type(value) ~= "string" then
    return ""
  end
  return vim.trim(value)
end

local function normalize_key(value)
  return normalize_string(value):lower()
end

local function parse_csv_items(value)
  if type(value) ~= "string" then
    return {}
  end

  local items = {}
  local seen = {}
  for _, raw in ipairs(vim.split(value, ",", { plain = true })) do
    local item = normalize_string(raw)
    if item ~= "" then
      local key = normalize_key(item)
      if key ~= "" and not seen[key] then
        seen[key] = true
        items[#items + 1] = item
      end
    end
  end

  return items
end

local function summarize_list(items, empty_label)
  items = type(items) == "table" and items or {}
  if vim.tbl_isempty(items) then
    return empty_label or "(none)"
  end

  if #items <= 5 then
    return table.concat(items, ", ")
  end

  local preview = {}
  for index = 1, 4 do
    preview[#preview + 1] = items[index]
  end
  preview[#preview + 1] = string.format("+%d more", #items - 4)
  return table.concat(preview, ", ")
end

local function summarize_text(value, max_length)
  local text = normalize_string(value)
  if text == "" then
    return "(empty)"
  end

  text = text:gsub("\n", " ")
  local limit = positive_integer(max_length, 80)
  if #text > limit then
    return text:sub(1, limit - 3) .. "..."
  end
  return text
end

local function extract_name(item)
  if type(item) == "string" then
    return normalize_string(item)
  end

  if type(item) ~= "table" then
    return ""
  end

  if type(item.login) == "string" and item.login ~= "" then
    return normalize_string(item.login)
  end

  if type(item.name) == "string" and item.name ~= "" then
    return normalize_string(item.name)
  end

  if type(item.slug) == "string" and item.slug ~= "" then
    if type(item.organization) == "table" and type(item.organization.login) == "string" and item.organization.login ~= "" then
      return normalize_string(item.organization.login .. "/" .. item.slug)
    end
    return normalize_string(item.slug)
  end

  if type(item.requestedReviewer) == "table" then
    return extract_name(item.requestedReviewer)
  end

  if type(item.user) == "table" then
    return extract_name(item.user)
  end

  if type(item.team) == "table" then
    return extract_name(item.team)
  end

  return ""
end

local function normalize_items(items)
  local result = {}
  local seen = {}

  for _, item in ipairs(type(items) == "table" and items or {}) do
    local name = extract_name(item)
    if name ~= "" then
      local key = normalize_key(name)
      if key ~= "" and not seen[key] then
        seen[key] = true
        result[#result + 1] = name
      end
    end
  end

  return result
end

local function compute_replacement_diff(current_items, desired_items)
  local current = {}
  local desired = {}
  local add = {}
  local remove = {}

  for _, item in ipairs(current_items) do
    local key = normalize_key(item)
    if key ~= "" then
      current[key] = item
    end
  end

  for _, item in ipairs(desired_items) do
    local key = normalize_key(item)
    if key ~= "" and not desired[key] then
      desired[key] = item
      if not current[key] then
        add[#add + 1] = item
      end
    end
  end

  for _, item in ipairs(current_items) do
    local key = normalize_key(item)
    if key ~= "" and not desired[key] then
      remove[#remove + 1] = item
    end
  end

  return add, remove
end

local function current_milestone(details)
  if type(details.milestone) == "table" and type(details.milestone.title) == "string" then
    return normalize_string(details.milestone.title)
  end
  return ""
end

local function current_labels(details)
  return normalize_items(details.labels)
end

local function current_reviewers(details)
  return normalize_items(details.reviewRequests)
end

local function current_assignees(details)
  return normalize_items(details.assignees)
end

local function confirm_overview_edit(pr_number, action_label, summary, callback)
  local prompt = string.format(
    "Apply %s on PR #%d? %s",
    action_label,
    pr_number,
    summary
  )

  vim.ui.select({ "confirm", "cancel" }, {
    prompt = prompt,
  }, function(choice)
    callback(choice == "confirm")
  end)
end

local function build_title_edit(choice, details)
  local next_title = normalize_string(choice)
  local current_title = normalize_string(details.title)
  if next_title == "" then
    return nil, "Title cannot be empty", false
  end
  if next_title == current_title then
    return nil, "No changes detected for title", true
  end

  return {
    summary = string.format("title: %s", summarize_text(next_title, 80)),
    success = "Title updated",
    run = function(pr_number)
      return pr_service.edit(pr_number, { title = next_title })
    end,
  }, nil, false
end

local function build_body_edit(choice, details)
  local next_body = type(choice) == "string" and choice or ""
  local current_body = type(details.body) == "string" and details.body or ""
  if next_body == current_body then
    return nil, "No changes detected for description", true
  end

  local summary
  if normalize_string(next_body) == "" then
    summary = "description: clear"
  else
    summary = string.format("description: %s", summarize_text(next_body, 80))
  end

  return {
    summary = summary,
    success = "Description updated",
    run = function(pr_number)
      return pr_service.edit(pr_number, { body = next_body })
    end,
  }, nil, false
end

local function build_milestone_edit(choice, details)
  local next_milestone = normalize_string(choice)
  local current_value = current_milestone(details)
  if next_milestone == current_value then
    return nil, "No changes detected for milestone", true
  end

  if next_milestone == "" then
    if current_value == "" then
      return nil, "No changes detected for milestone", true
    end

    return {
      summary = "milestone: remove",
      success = "Milestone removed",
      run = function(pr_number)
        return pr_service.edit(pr_number, { remove_milestone = true })
      end,
    }, nil, false
  end

  return {
    summary = string.format("milestone: %s", summarize_text(next_milestone, 60)),
    success = "Milestone updated",
    run = function(pr_number)
      return pr_service.edit(pr_number, { milestone = next_milestone })
    end,
  }, nil, false
end

local function build_list_edit(kind, choice, current_values)
  local desired = parse_csv_items(type(choice) == "string" and choice or "")
  local add, remove = compute_replacement_diff(current_values, desired)

  if vim.tbl_isempty(add) and vim.tbl_isempty(remove) then
    return nil, "No changes detected", true
  end

  local summary = string.format(
    "final: [%s] | add: [%s] | remove: [%s]",
    summarize_list(desired),
    summarize_list(add),
    summarize_list(remove)
  )

  local operations = {}
  local success

  if kind == "edit_labels" then
    operations.add_labels = add
    operations.remove_labels = remove
    success = "Labels updated"
  elseif kind == "edit_reviewers" then
    operations.add_reviewers = add
    operations.remove_reviewers = remove
    success = "Reviewers updated"
  elseif kind == "edit_assignees" then
    operations.add_assignees = add
    operations.remove_assignees = remove
    success = "Assignees updated"
  else
    return nil, "Unsupported list edit action", false
  end

  return {
    summary = summary,
    success = success,
    run = function(pr_number)
      return pr_service.edit(pr_number, operations)
    end,
  }, nil, false
end

local function build_state_change(choice, details)
  local target = normalize_key(choice)
  if target ~= "open" and target ~= "closed" then
    return nil, "Invalid state selection", false
  end

  local current = normalize_key(details.state)
  if current == target then
    return nil, "No changes detected for PR state", true
  end

  local before_state = (current ~= "" and current or "unknown"):upper()
  local after_state = target:upper()
  return {
    summary = string.format("state: %s -> %s", before_state, after_state),
    success = string.format("PR state changed to %s", after_state),
    run = function(pr_number)
      return pr_service.change_state(pr_number, target)
    end,
  }, nil, false
end

local function build_draft_change(choice, details)
  local target = normalize_key(choice)
  if target ~= "ready" and target ~= "draft" then
    return nil, "Invalid draft status selection", false
  end

  local current = details.isDraft == true and "draft" or "ready"
  if current == target then
    return nil, "No changes detected for draft status", true
  end

  return {
    summary = string.format("draft status: %s -> %s", current:upper(), target:upper()),
    success = string.format("Draft status changed to %s", target:upper()),
    run = function(pr_number)
      return pr_service.change_draft(pr_number, target)
    end,
  }, nil, false
end

local function build_overview_edit_operation(kind, choice, details)
  if kind == "edit_title" then
    return build_title_edit(choice, details)
  end
  if kind == "edit_body" then
    return build_body_edit(choice, details)
  end
  if kind == "edit_milestone" then
    return build_milestone_edit(choice, details)
  end
  if kind == "edit_labels" then
    return build_list_edit(kind, choice, current_labels(details))
  end
  if kind == "edit_reviewers" then
    return build_list_edit(kind, choice, current_reviewers(details))
  end
  if kind == "edit_assignees" then
    return build_list_edit(kind, choice, current_assignees(details))
  end
  if kind == "change_state" then
    return build_state_change(choice, details)
  end
  if kind == "change_draft" then
    return build_draft_change(choice, details)
  end

  return nil, "Unsupported overview edit action", false
end

local function refresh_overview_after_edit()
  local ok, err = pcall(M.refresh_overview)
  if not ok then
    notify_warn("Overview updated remotely, but local refresh failed: " .. tostring(err))
  end
end

local function overview_edit_picker(kind, payload, callback)
  payload = type(payload) == "table" and payload or {}

  if kind == "change_state" then
    vim.ui.select({ "open", "closed" }, {
      prompt = "Target state:",
    }, function(choice)
      callback(choice)
    end)
    return
  end

  if kind == "change_draft" then
    vim.ui.select({ "ready", "draft" }, {
      prompt = "Target draft status:",
    }, function(choice)
      callback(choice)
    end)
    return
  end

  local default_value = payload.current
  if type(default_value) ~= "string" then
    default_value = ""
  end

  local prompt = string.format("%s: ", overview_edit_labels[kind] or "Edit")
  vim.ui.input({
    prompt = prompt,
    default = default_value,
  }, function(input)
    callback(input)
  end)
end

function M.overview_edit_stub(kind, payload)
  local label = overview_edit_labels[kind]
  if not label then
    return notify_warn("Unsupported overview edit action")
  end

  local pr, details, err = resolve_active_pr()
  if not pr then
    return notify_error(err)
  end

  overview_edit_picker(kind, payload, function(choice)
    if choice == nil then
      notify_info(label .. " cancelled")
      return
    end

    local operation, build_err, noop = build_overview_edit_operation(kind, choice, details)
    if noop then
      notify_info(build_err or "No changes detected")
      return
    end
    if not operation then
      notify_error(build_err)
      return
    end

    confirm_overview_edit(pr.number, label, operation.summary or "", function(confirmed)
      if not confirmed then
        notify_info(label .. " cancelled")
        return
      end

      local ok, op_err = operation.run(pr.number)
      if not ok then
        notify_error(op_err)
        return
      end

      notify_info(operation.success or (label .. " completed"))
      refresh_overview_after_edit()
    end)
  end)
end

local function resolve_commit(commit)
  if type(commit) == "table" and type(commit.oid) == "string" and commit.oid ~= "" then
    return commit
  end

  local bufnr = vim.api.nvim_get_current_buf()
  local oid = vim.b[bufnr].gh_pr_commit_oid
  if type(oid) == "string" and oid ~= "" then
    return {
      oid = oid,
      url = vim.b[bufnr].gh_pr_commit_url,
    }
  end

  return nil
end

function M.open_commit_diff(commit)
  local pr, details, err = resolve_active_pr()
  if not pr then
    return notify_error(err)
  end

  local selected_commit = resolve_commit(commit)
  if not selected_commit then
    return notify_error("No commit selected")
  end

  local repository = normalize_repository(details) or ""
  local commit_details, commit_err = pr_service.fetch_commit_details(pr.number, selected_commit.oid, {
    repository = repository,
  })
  if not commit_details then
    if type(selected_commit.url) == "string" and selected_commit.url ~= "" and vim.ui and type(vim.ui.open) == "function" then
      vim.ui.open(selected_commit.url)
      return
    end
    return notify_error(commit_err)
  end

  local _, open_err = virtual_files.open_commit_patch(details, pr, commit_details)
  if open_err then
    if type(commit_details.url) == "string" and commit_details.url ~= "" and vim.ui and type(vim.ui.open) == "function" then
      vim.ui.open(commit_details.url)
      return
    end
    return notify_error(open_err)
  end
end

function M.open_diff(file)
  local pr, details, err = resolve_active_pr()
  if not pr then
    return notify_error(err)
  end

  local selected_file = resolve_file(file)
  if not selected_file then
    return notify_error("No file selected for diff")
  end

  state.set_active_file(selected_file)
  local comments_ctx = build_line_comment_context(pr.number)

  local _, diff_err = virtual_files.open_diff(details, pr, selected_file, {
    line_comments = comments_ctx,
  })
  if diff_err then
    return notify_error(diff_err)
  end
end

function M.open_original(file)
  local pr, details, err = resolve_active_pr()
  if not pr then
    return notify_error(err)
  end

  local selected_file = resolve_file(file)
  if not selected_file then
    return notify_error("No file selected")
  end

  state.set_active_file(selected_file)
  local comments_ctx = build_line_comment_context(pr.number)

  local _, open_err = virtual_files.open_original(details, pr, selected_file, {
    line_comments = comments_ctx,
  })
  if open_err then
    return notify_error(open_err)
  end
end

function M.open_modified(file)
  local pr, details, err = resolve_active_pr()
  if not pr then
    return notify_error(err)
  end

  local selected_file = resolve_file(file)
  if not selected_file then
    return notify_error("No file selected")
  end

  state.set_active_file(selected_file)
  local comments_ctx = build_line_comment_context(pr.number)

  local _, open_err = virtual_files.open_modified(details, pr, selected_file, {
    line_comments = comments_ctx,
  })
  if open_err then
    return notify_error(open_err)
  end
end

local function file_path(file)
  if type(file) ~= "table" then
    return nil
  end

  local path = file.path or file.filename
  if type(path) ~= "string" or path == "" then
    return nil
  end

  return path
end

local function current_file_path()
  if type(vim.b.gh_pr_path) == "string" and vim.b.gh_pr_path ~= "" then
    return vim.b.gh_pr_path
  end

  return file_path(state.get_active_file())
end

local function ordered_pr_files(details)
  local entries = {}
  for _, file in ipairs(type(details.files) == "table" and details.files or {}) do
    local path = file_path(file)
    if path then
      entries[#entries + 1] = {
        file = file,
        path = path,
      }
    end
  end
  return entries
end

local function current_navigation_mode()
  if vim.wo.diff then
    return "diff"
  end

  local kind = vim.b.gh_pr_file_kind
  if kind == "base" then
    return "base"
  end
  if kind == "head" then
    return "head"
  end

  return "head"
end

local function find_diff_pair_windows()
  local tab = vim.api.nvim_get_current_tabpage()
  local base_win, head_win

  for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
    local ok_diff, is_diff = pcall(vim.api.nvim_get_option_value, "diff", { win = winid })
    if ok_diff and is_diff then
      local bufnr = vim.api.nvim_win_get_buf(winid)
      local kind = vim.b[bufnr].gh_pr_file_kind
      if kind == "base" and not base_win then
        base_win = winid
      elseif kind == "head" and not head_win then
        head_win = winid
      end
    end
  end

  return base_win, head_win
end

local function open_diff_in_place(file)
  local base_win, head_win = find_diff_pair_windows()
  if not valid_window(base_win) or not valid_window(head_win) then
    return false
  end

  local origin = vim.api.nvim_get_current_win()
  if not pcall(vim.api.nvim_set_current_win, base_win) then
    return false
  end
  M.open_original(file)

  if not pcall(vim.api.nvim_set_current_win, head_win) then
    if valid_window(origin) then
      pcall(vim.api.nvim_set_current_win, origin)
    end
    return false
  end
  M.open_modified(file)

  if valid_window(origin) then
    pcall(vim.api.nvim_set_current_win, origin)
  end
  return true
end

local function file_matches_filter(entry, repository, pr_number, reviewed_only)
  if not reviewed_only then
    return true
  end

  if type(repository) ~= "string" or repository == "" then
    return false
  end

  return state.is_viewed(repository, pr_number, entry.path)
end

local function pick_next_file(details, pr, step, reviewed_only)
  local entries = ordered_pr_files(details)
  if #entries == 0 then
    return nil, "Current PR has no files"
  end

  local repository = reviewed_only and normalize_repository(details) or nil
  if reviewed_only and not repository then
    return nil, "Unable to resolve repository for reviewed files"
  end

  local current_path = current_file_path()
  local current_index = nil
  if current_path then
    for index, entry in ipairs(entries) do
      if entry.path == current_path then
        current_index = index
        break
      end
    end
  end

  if current_index == nil then
    current_index = step > 0 and 0 or 1
  end

  local total = #entries
  for offset = 1, total do
    local index = ((current_index - 1) + (offset * step)) % total + 1
    local entry = entries[index]
    if file_matches_filter(entry, repository, pr.number, reviewed_only) then
      return entry.file, nil
    end
  end

  if reviewed_only then
    return nil, "No reviewed files found in this PR"
  end

  return nil, "Unable to resolve next file in PR"
end

local function open_file_for_navigation(file, mode)
  if mode == "base" then
    M.open_original(file)
    return
  end

  if mode == "diff" then
    if open_diff_in_place(file) then
      return
    end
    M.open_diff(file)
    return
  end

  M.open_modified(file)
end

local function navigate_files(step, reviewed_only)
  local pr, details, err = resolve_active_pr()
  if not pr then
    return notify_error(err)
  end

  local target, target_err = pick_next_file(details, pr, step, reviewed_only)
  if not target then
    return notify_error(target_err)
  end

  open_file_for_navigation(target, current_navigation_mode())
end

function M.next_file()
  navigate_files(1, false)
end

function M.prev_file()
  navigate_files(-1, false)
end

function M.next_reviewed_file()
  navigate_files(1, true)
end

function M.prev_reviewed_file()
  navigate_files(-1, true)
end

function M.checkout(number)
  local pr, _, err = resolve_active_pr(number)
  if not pr then
    return notify_error(err)
  end

  local ok, checkout_err = pr_service.checkout(pr.number)
  if not ok then
    return notify_error(checkout_err)
  end

  notify_info(string.format("Checked out PR #%d", pr.number))
end

function M.mark_file_viewed(file, viewed)
  local pr, details, err = resolve_active_pr()
  if not pr then
    return notify_error(err)
  end

  local selected_file = resolve_file(file)
  if not selected_file then
    return notify_error("No file selected")
  end

  local repository = normalize_repository(details)
  if not repository then
    return notify_error("Unable to resolve repository for viewed state")
  end

  local path = selected_file.path or selected_file.filename
  if not path then
    return notify_error("Unable to resolve file path")
  end

  if viewed == nil then
    viewed = not state.is_viewed(repository, pr.number, path)
  end

  state.set_viewed(repository, pr.number, path, viewed)
  state.set_active_file(selected_file)

  notify_info(string.format("Marked %s as %s", path, viewed and "viewed" or "unviewed"))
end

function M.toggle_viewed()
  local path = vim.b.gh_pr_path
  local number = vim.b.gh_pr_number
  local repository = vim.b.gh_pr_repo

  if type(path) == "string" and type(number) == "number" and type(repository) == "string" then
    local viewed = state.toggle_viewed(repository, number, path)
    notify_info(string.format("Marked %s as %s", path, viewed and "viewed" or "unviewed"))
    return
  end

  M.mark_file_viewed(nil, nil)
end

local function prompt_review_body(default_body, callback)
  vim.ui.input({
    prompt = "Review message: ",
    default = default_body,
  }, function(input)
    if input == nil then
      callback("", true)
      return
    end
    callback(input, false)
  end)
end

local function review_event_label(event)
  local labels = {
    approve = "approve",
    request_changes = "request changes",
    comment = "comment",
  }

  return labels[event]
end

local function review_body_summary(body)
  local raw = type(body) == "string" and body or ""
  if raw == "" then
    return "(empty message)"
  end

  local first_line = vim.split(raw, "\n", { plain = true })[1] or ""
  first_line = vim.trim(first_line)
  if first_line == "" then
    return "(empty message)"
  end
  if #first_line > 70 then
    return first_line:sub(1, 67) .. "..."
  end
  return first_line
end

local function confirm_review_submission(event, pr_number, body, callback)
  local label = review_event_label(event) or event
  local prompt = string.format(
    "Submit %s review for PR #%d? Message: %s",
    label,
    pr_number,
    review_body_summary(body)
  )

  vim.ui.select({ "confirm", "cancel" }, {
    prompt = prompt,
  }, function(choice)
    callback(choice == "confirm")
  end)
end

function M.review(event)
  local pr, _, err = resolve_active_pr()
  if not pr then
    return notify_error(err)
  end

  local label = review_event_label(event)
  if not label then
    return notify_error("Unsupported review event")
  end

  local defaults = {
    approve = "",
    request_changes = "Requested changes from Neovim",
    comment = "Comment from Neovim",
  }

  prompt_review_body(defaults[event] or "", function(body, input_cancelled)
    if input_cancelled then
      notify_info("Review submission cancelled")
      return
    end

    confirm_review_submission(event, pr.number, body, function(confirmed)
      if not confirmed then
        notify_info("Review submission cancelled")
        return
      end

      local ok, review_err = pr_service.review(pr.number, event, body)
      if not ok then
        notify_error(review_err)
        return
      end

      notify_info(string.format("%s review submitted for PR #%d", label:gsub("^%l", string.upper), pr.number))
    end)
  end)
end

function M.merge(method)
  local pr, _, err = resolve_active_pr()
  if not pr then
    return notify_error(err)
  end

  method = method or "merge"

  vim.ui.select({ "no", "yes" }, {
    prompt = "Delete branch after merge?",
  }, function(delete_choice)
    if not delete_choice then
      return
    end

    local ok, merge_err = pr_service.merge(pr.number, method, delete_choice == "yes")
    if not ok then
      notify_error(merge_err)
      return
    end

    notify_info(string.format("Merge requested for PR #%d", pr.number))
  end)
end

function M.next_change()
  if vim.wo.diff then
    vim.cmd("normal! ]c")
  end
end

function M.prev_change()
  if vim.wo.diff then
    vim.cmd("normal! [c")
  end
end

function M.current_viewed_state()
  local path = vim.b.gh_pr_path
  local number = vim.b.gh_pr_number
  local repository = vim.b.gh_pr_repo

  if type(path) == "string" and type(number) == "number" and type(repository) == "string" then
    return state.is_viewed(repository, number, path)
  end

  return false
end

return M
