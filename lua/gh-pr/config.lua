local M = {}

local defaults = {
  remotes = { "origin", "upstream" },
  max_results = 30,
  file_list_layout = "tree",
  hide_viewed_files = false,
  line_comments = {
    enabled = true,
    keymap = "K",
    indicator_style = "sign_and_highlight",
    show_resolved = true,
    show_outdated = true,
    max_popup_width = 90,
    max_popup_height = 18,
    comments_tree = {
      preview = {
        keymap = "p",
        position = "right",
        keep_focus = true,
      },
    },
    signs = {
      open = "C>",
      resolved = "C=",
      outdated = "C~",
    },
  },
  overview = {
    ui = "snacks",
    layout = "tabs",
    expand_step = 20,
    date_format = "%Y-%m-%d %H:%M",
    tabs = {
      "summary",
      "checks",
      "commits",
      "timeline",
      "files",
    },
    max_items = {
      checks = 10,
      commits = 10,
      timeline = 30,
      comments = 30,
      reviews = 30,
      threads = 30,
    },
    show = {
      checks = true,
      commits = true,
      timeline = true,
      comments = true,
      reviews = true,
      threads = true,
      labels = true,
    },
  },
  cache = {
    gh_pr = {
      enabled = true,
      ttl_seconds = 60,
      auto_refresh_when_focused = true,
      max_cache_age_seconds = 900,
      show_stale_badge = true,
      sync_visible_buffers = true,
    },
  },
  ui = {
    use_neotree = true,
    telescope_fallback = true,
  },
  queries = {
    {
      folder = "Inbox",
      label = "Waiting For My Review",
      query = "is:open review-requested:@me",
    },
    {
      folder = "Inbox",
      label = "Assigned To Me",
      query = "is:open assignee:@me",
    },
    {
      folder = "Mine",
      label = "Created By Me",
      query = "is:open author:@me",
    },
    {
      folder = "All",
      label = "All Open",
      query = "is:open",
    },
  },
}

local state = vim.deepcopy(defaults)

local function sanitize_query(item, index)
  if type(item) ~= "table" then
    return nil
  end

  local label = type(item.label) == "string" and item.label or ("Query " .. index)
  local query = type(item.query) == "string" and item.query or "is:open"
  local folder = type(item.folder) == "string" and item.folder or "General"

  return {
    id = item.id or (folder .. ":" .. label),
    folder = folder,
    label = label,
    query = query,
  }
end

local function sanitize_queries(queries)
  if type(queries) ~= "table" or vim.tbl_isempty(queries) then
    queries = defaults.queries
  end

  local result = {}
  for index, query in ipairs(queries) do
    local sanitized = sanitize_query(query, index)
    if sanitized then
      table.insert(result, sanitized)
    end
  end

  if vim.tbl_isempty(result) then
    for index, query in ipairs(defaults.queries) do
      table.insert(result, sanitize_query(query, index))
    end
  end

  return result
end

local function sanitize_remotes(remotes)
  if type(remotes) ~= "table" or vim.tbl_isempty(remotes) then
    return vim.deepcopy(defaults.remotes)
  end

  local result = {}
  for _, remote in ipairs(remotes) do
    if type(remote) == "string" and remote ~= "" then
      table.insert(result, remote)
    end
  end

  if vim.tbl_isempty(result) then
    return vim.deepcopy(defaults.remotes)
  end

  return result
end

local function sanitize_positive_integer(value, default_value)
  if type(value) ~= "number" then
    return default_value
  end

  local rounded = math.floor(value)
  if rounded < 1 then
    return default_value
  end

  return rounded
end

local function sanitize_overview_tabs(tabs)
  local allowed = {
    summary = true,
    checks = true,
    commits = true,
    timeline = true,
    comments = true,
    reviews = true,
    threads = true,
    files = true,
  }
  local aliases = {
    comments = "timeline",
    reviews = "timeline",
    threads = "timeline",
  }

  local source = type(tabs) == "table" and tabs or defaults.overview.tabs
  local result = {}
  local seen = {}

  for _, name in ipairs(source) do
    if type(name) == "string" then
      local normalized = name:lower()
      normalized = aliases[normalized] or normalized
      if allowed[normalized] and not seen[normalized] then
        seen[normalized] = true
        result[#result + 1] = normalized
      end
    end
  end

  if vim.tbl_isempty(result) then
    return vim.deepcopy(defaults.overview.tabs)
  end

  return result
end

local function sanitize_overview(overview)
  if type(overview) ~= "table" then
    return vim.deepcopy(defaults.overview)
  end

  local raw_max_items = type(overview.max_items) == "table" and overview.max_items or {}
  local result = vim.tbl_deep_extend("force", vim.deepcopy(defaults.overview), overview)

  if result.ui ~= "snacks" then
    result.ui = defaults.overview.ui
  end

  if result.layout ~= "tabs" then
    result.layout = defaults.overview.layout
  end

  if type(result.date_format) ~= "string" or result.date_format == "" then
    result.date_format = defaults.overview.date_format
  end

  result.tabs = sanitize_overview_tabs(result.tabs)
  result.expand_step = sanitize_positive_integer(result.expand_step, defaults.overview.expand_step)

  result.max_items = type(result.max_items) == "table" and result.max_items or {}
  result.max_items.checks = sanitize_positive_integer(result.max_items.checks, defaults.overview.max_items.checks)
  result.max_items.commits = sanitize_positive_integer(result.max_items.commits, defaults.overview.max_items.commits)
  result.max_items.timeline = sanitize_positive_integer(raw_max_items.timeline, defaults.overview.max_items.timeline)
  result.max_items.comments = result.max_items.timeline
  result.max_items.reviews = result.max_items.timeline
  result.max_items.threads = result.max_items.timeline

  result.show = type(result.show) == "table" and result.show or {}
  result.show.checks = type(result.show.checks) == "boolean" and result.show.checks or defaults.overview.show.checks
  result.show.commits = type(result.show.commits) == "boolean" and result.show.commits or defaults.overview.show.commits
  result.show.timeline = type(result.show.timeline) == "boolean" and result.show.timeline or defaults.overview.show.timeline
  result.show.comments = type(result.show.comments) == "boolean" and result.show.comments or defaults.overview.show.comments
  result.show.reviews = type(result.show.reviews) == "boolean" and result.show.reviews or defaults.overview.show.reviews
  result.show.threads = type(result.show.threads) == "boolean" and result.show.threads or defaults.overview.show.threads
  result.show.labels = type(result.show.labels) == "boolean" and result.show.labels or defaults.overview.show.labels

  return result
end

local function sanitize_cache(cache_options)
  if type(cache_options) ~= "table" then
    return vim.deepcopy(defaults.cache)
  end

  local result = vim.tbl_deep_extend("force", vim.deepcopy(defaults.cache), cache_options)
  result.gh_pr = type(result.gh_pr) == "table" and result.gh_pr or {}

  if type(result.gh_pr.enabled) ~= "boolean" then
    result.gh_pr.enabled = defaults.cache.gh_pr.enabled
  end

  result.gh_pr.ttl_seconds = sanitize_positive_integer(result.gh_pr.ttl_seconds, defaults.cache.gh_pr.ttl_seconds)
  result.gh_pr.max_cache_age_seconds = sanitize_positive_integer(
    result.gh_pr.max_cache_age_seconds,
    defaults.cache.gh_pr.max_cache_age_seconds
  )

  if type(result.gh_pr.auto_refresh_when_focused) ~= "boolean" then
    result.gh_pr.auto_refresh_when_focused = defaults.cache.gh_pr.auto_refresh_when_focused
  end

  if type(result.gh_pr.show_stale_badge) ~= "boolean" then
    result.gh_pr.show_stale_badge = defaults.cache.gh_pr.show_stale_badge
  end

  if type(result.gh_pr.sync_visible_buffers) ~= "boolean" then
    result.gh_pr.sync_visible_buffers = defaults.cache.gh_pr.sync_visible_buffers
  end

  return result
end

local function sanitize_line_comments(line_comments)
  if type(line_comments) ~= "table" then
    return vim.deepcopy(defaults.line_comments)
  end

  local result = vim.tbl_deep_extend("force", vim.deepcopy(defaults.line_comments), line_comments)

  result.enabled = result.enabled ~= false
  result.show_resolved = result.show_resolved ~= false
  result.show_outdated = result.show_outdated ~= false

  if type(result.keymap) ~= "string" or result.keymap == "" then
    result.keymap = defaults.line_comments.keymap
  end

  if result.indicator_style ~= "sign_and_highlight" and result.indicator_style ~= "sign_only" and result.indicator_style ~= "highlight_only" then
    result.indicator_style = defaults.line_comments.indicator_style
  end

  result.max_popup_width = sanitize_positive_integer(result.max_popup_width, defaults.line_comments.max_popup_width)
  result.max_popup_height = sanitize_positive_integer(result.max_popup_height, defaults.line_comments.max_popup_height)

  result.signs = type(result.signs) == "table" and result.signs or {}
  result.signs.open = type(result.signs.open) == "string" and result.signs.open ~= "" and result.signs.open
    or defaults.line_comments.signs.open
  result.signs.resolved = type(result.signs.resolved) == "string" and result.signs.resolved ~= "" and result.signs.resolved
    or defaults.line_comments.signs.resolved
  result.signs.outdated = type(result.signs.outdated) == "string" and result.signs.outdated ~= "" and result.signs.outdated
    or defaults.line_comments.signs.outdated

  result.comments_tree = type(result.comments_tree) == "table" and result.comments_tree or {}
  result.comments_tree.preview = type(result.comments_tree.preview) == "table" and result.comments_tree.preview or {}
  result.comments_tree.preview.keymap = type(result.comments_tree.preview.keymap) == "string"
      and result.comments_tree.preview.keymap ~= "" and result.comments_tree.preview.keymap
    or defaults.line_comments.comments_tree.preview.keymap
  if result.comments_tree.preview.position ~= "right" then
    result.comments_tree.preview.position = defaults.line_comments.comments_tree.preview.position
  end
  if type(result.comments_tree.preview.keep_focus) ~= "boolean" then
    result.comments_tree.preview.keep_focus = defaults.line_comments.comments_tree.preview.keep_focus
  end

  return result
end

function M.setup(opts)
  opts = opts or {}
  state = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts)
  state.remotes = sanitize_remotes(state.remotes)
  state.queries = sanitize_queries(state.queries)

  if state.file_list_layout ~= "flat" then
    state.file_list_layout = "tree"
  end

  if type(state.max_results) ~= "number" or state.max_results < 1 then
    state.max_results = defaults.max_results
  end

  if type(state.hide_viewed_files) ~= "boolean" then
    state.hide_viewed_files = defaults.hide_viewed_files
  end

  state.line_comments = sanitize_line_comments(state.line_comments)
  state.overview = sanitize_overview(state.overview)
  state.cache = sanitize_cache(state.cache)

  if type(state.ui) ~= "table" then
    state.ui = vim.deepcopy(defaults.ui)
  end

  if type(state.ui.use_neotree) ~= "boolean" then
    state.ui.use_neotree = defaults.ui.use_neotree
  end

  if type(state.ui.telescope_fallback) ~= "boolean" then
    state.ui.telescope_fallback = defaults.ui.telescope_fallback
  end
end

function M.get()
  return state
end

function M.get_queries()
  return state.queries
end

function M.set_queries(queries)
  state.queries = sanitize_queries(queries)
end

function M.add_query(query)
  local sanitized = sanitize_query(query or {}, #state.queries + 1)
  if not sanitized then
    return false
  end

  local queries = vim.deepcopy(state.queries)
  table.insert(queries, sanitized)
  state.queries = sanitize_queries(queries)
  return true
end

function M.update_query(id, query)
  local queries = vim.deepcopy(state.queries)
  for index, current in ipairs(queries) do
    if current.id == id then
      local merged = vim.tbl_deep_extend("force", current, query or {})
      queries[index] = sanitize_query(merged, index)
      state.queries = sanitize_queries(queries)
      return true
    end
  end
  return false
end

function M.delete_query(id)
  local next_queries = {}
  for _, query in ipairs(state.queries) do
    if query.id ~= id then
      table.insert(next_queries, query)
    end
  end

  if #next_queries == #state.queries then
    return false
  end

  state.queries = sanitize_queries(next_queries)
  return true
end

return M
