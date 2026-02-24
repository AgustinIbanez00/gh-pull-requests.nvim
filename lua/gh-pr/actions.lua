local M = {}

local config = require("gh-pr.config")
local overview = require("gh-pr.overview")
local pr_service = require("gh-pr.pr_service")
local state = require("gh-pr.state")
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

local function resolve_active_pr(number, opts)
  opts = opts or {}
  local target = resolve_pr_number(number)
  if not target then
    return nil, nil, "No active pull request selected"
  end

  local active_pr, active_details = state.get_active_pr()
  if active_pr and active_pr.number == target and active_details and opts.refresh ~= true then
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
    return nil, nil, nil, "Invalid comment target"
  end

  local pr = target.pr
  local details = target.details
  if type(pr) ~= "table" or type(details) ~= "table" then
    local resolved_pr, resolved_details, err = resolve_active_pr(target.pr_number or target.number, { refresh = false })
    if not resolved_pr then
      return nil, nil, nil, err
    end
    pr = resolved_pr
    details = resolved_details
  end

  state.set_active_pr(pr, details)

  local path = target.path
  if type(path) ~= "string" or path == "" then
    return nil, nil, nil, "Missing comment path"
  end

  local file = find_file_in_details(details, path) or {
    path = path,
    filename = path,
  }
  state.set_active_file(file)

  local side = type(target.side) == "string" and target.side or "head"
  local line = side == "base" and (target.original_line or target.line) or (target.line or target.original_line)
  return file, side, line, nil
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

function M.open_comment_location(target)
  local file, side, line, err = resolve_comment_target(target)
  if not file then
    return notify_error(err)
  end

  ensure_navigation_window()
  open_target_file(file, side, line)
end

function M.preview_comment_location(target)
  local file, side, line, err = resolve_comment_target(target)
  if not file then
    return notify_error(err)
  end

  local opts = preview_options()
  local origin_window = vim.api.nvim_get_current_win()
  local preview_win = ensure_preview_window(opts.position)
  if not valid_window(preview_win) then
    return notify_error("Unable to open preview window")
  end

  local switched, switch_err = pcall(vim.api.nvim_set_current_win, preview_win)
  if not switched then
    return notify_error("Unable to focus preview window: " .. tostring(switch_err))
  end

  open_target_file(file, side, line)

  if opts.keep_focus and valid_window(origin_window) then
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
    callback(input or "")
  end)
end

function M.review(event)
  local pr, _, err = resolve_active_pr()
  if not pr then
    return notify_error(err)
  end

  local defaults = {
    approve = "",
    request_changes = "Requested changes from Neovim",
    comment = "Comment from Neovim",
  }

  prompt_review_body(defaults[event] or "", function(body)
    local ok, review_err = pr_service.review(pr.number, event, body)
    if not ok then
      notify_error(review_err)
      return
    end

    notify_info(string.format("Review submitted for PR #%d", pr.number))
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
