local M = {}

local defaults = {
  remotes = { "origin", "upstream" },
  max_results = 30,
  file_list_layout = "tree",
  path_render = {
    scope = "both",
    mode = "compact",
    separator = "/",
    show_status_prefix = true,
  },
  hide_viewed_files = false,
  line_comments = {
    enabled = true,
    keymap = "K",
    indicator_style = "sign_and_virtual_text",
    show_resolved = true,
    show_outdated = true,
    max_popup_width = 90,
    max_popup_height = 18,
    popup = {
      enter = true,
      position = "cursor",
      border = "rounded",
      wrap = true,
      close_on_move = true,
      max_width = 90,
      max_height = 18,
    },
    virtual_text = {
      enabled = true,
      prefix = "C",
      show_count = true,
      position = "eol",
    },
    comments_tree = {
      auto_open_thread_popup = true,
      preview = {
        keymap = "p",
        position = "right",
        keep_focus = true,
      },
      thread_popup = {
        enabled = true,
        width_ratio = 0.62,
        height_ratio = 0.55,
        min_width = 80,
        min_height = 12,
        max_width = 140,
        max_height = 40,
        border = "rounded",
        wrap = true,
        enter = true,
        position = "cursor",
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
    window = {
      enabled = true,
      border = "rounded",
      width_ratio = 0.88,
      height_ratio = 0.88,
      min_width = 100,
      min_height = 28,
      max_width = 180,
      max_height = 60,
      backdrop = 0,
      enter = true,
    },
    theme = {
      state_colors = true,
      checks_colors = true,
      labels = true,
      reviewers = true,
      timeline_kinds = true,
    },
    markdown = {
      enabled = true,
      provider = "auto",
      max_lines = 500,
      code_block_border = false,
    },
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
    gh_pr_review = {
      enabled = true,
      ttl_seconds = 60,
      auto_refresh_when_focused = true,
      max_cache_age_seconds = 900,
      show_stale_badge = true,
      sync_visible_buffers = true,
    },
  },
  follow_current_file = {
    enabled = true,
    debounce_ms = 60,
    sources = {
      pr = true,
      pr_review = true,
    },
  },
  diff_view = {
    mode = "vertical",
    ignore_whitespace = false,
    render_whitespace = true,
    whitespace = {
      tab = ">-",
      space = ".",
      trail = "~",
      nbsp = "+",
      color = nil,
      highlight_group = "GhPrDiffWhitespace",
    },
    shortcuts = {
      toggle_whitespace = ",dw",
      toggle_render_whitespace = ",dt",
      cycle_mode = ",dm",
      set_vertical = ",dv",
      set_horizontal = ",dh",
      set_unified = ",du",
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

local function sanitize_ratio(value, default_value)
  if type(value) ~= "number" then
    return default_value
  end

  if value < 0.2 or value > 0.95 then
    return default_value
  end

  return value
end

local function sanitize_legacy_file_list_layout(value)
  if value == "flat" then
    return "flat"
  end
  return "tree"
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

  result.window = type(result.window) == "table" and result.window or {}
  if type(result.window.enabled) ~= "boolean" then
    result.window.enabled = defaults.overview.window.enabled
  end
  if result.window.border ~= "rounded"
    and result.window.border ~= "single"
    and result.window.border ~= "double"
    and result.window.border ~= "solid"
    and result.window.border ~= "shadow"
    and result.window.border ~= "none" then
    result.window.border = defaults.overview.window.border
  end
  result.window.width_ratio = sanitize_ratio(result.window.width_ratio, defaults.overview.window.width_ratio)
  result.window.height_ratio = sanitize_ratio(result.window.height_ratio, defaults.overview.window.height_ratio)
  result.window.min_width = sanitize_positive_integer(result.window.min_width, defaults.overview.window.min_width)
  result.window.min_height = sanitize_positive_integer(result.window.min_height, defaults.overview.window.min_height)
  result.window.max_width = sanitize_positive_integer(result.window.max_width, defaults.overview.window.max_width)
  result.window.max_height = sanitize_positive_integer(result.window.max_height, defaults.overview.window.max_height)
  if result.window.max_width < result.window.min_width then
    result.window.max_width = result.window.min_width
  end
  if result.window.max_height < result.window.min_height then
    result.window.max_height = result.window.min_height
  end
  if type(result.window.backdrop) == "number" then
    result.window.backdrop = math.max(0, math.min(100, math.floor(result.window.backdrop)))
  elseif result.window.backdrop ~= false then
    result.window.backdrop = defaults.overview.window.backdrop
  end
  if type(result.window.enter) ~= "boolean" then
    result.window.enter = defaults.overview.window.enter
  end

  result.theme = type(result.theme) == "table" and result.theme or {}
  if type(result.theme.state_colors) ~= "boolean" then
    result.theme.state_colors = defaults.overview.theme.state_colors
  end
  if type(result.theme.checks_colors) ~= "boolean" then
    result.theme.checks_colors = defaults.overview.theme.checks_colors
  end
  if type(result.theme.labels) ~= "boolean" then
    result.theme.labels = defaults.overview.theme.labels
  end
  if type(result.theme.reviewers) ~= "boolean" then
    result.theme.reviewers = defaults.overview.theme.reviewers
  end
  if type(result.theme.timeline_kinds) ~= "boolean" then
    result.theme.timeline_kinds = defaults.overview.theme.timeline_kinds
  end

  result.markdown = type(result.markdown) == "table" and result.markdown or {}
  if type(result.markdown.enabled) ~= "boolean" then
    result.markdown.enabled = defaults.overview.markdown.enabled
  end
  if type(result.markdown.provider) == "string" then
    result.markdown.provider = result.markdown.provider:lower()
  end
  if result.markdown.provider ~= "auto"
    and result.markdown.provider ~= "builtin"
    and result.markdown.provider ~= "render-markdown"
    and result.markdown.provider ~= "markview" then
    result.markdown.provider = defaults.overview.markdown.provider
  end
  result.markdown.max_lines = sanitize_positive_integer(result.markdown.max_lines, defaults.overview.markdown.max_lines)
  if result.markdown.max_lines < 50 then
    result.markdown.max_lines = 50
  end
  if type(result.markdown.code_block_border) ~= "boolean" then
    result.markdown.code_block_border = defaults.overview.markdown.code_block_border
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
  result.gh_pr_review = type(result.gh_pr_review) == "table" and result.gh_pr_review or {}

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

  if type(result.gh_pr_review.enabled) ~= "boolean" then
    result.gh_pr_review.enabled = defaults.cache.gh_pr_review.enabled
  end

  result.gh_pr_review.ttl_seconds = sanitize_positive_integer(
    result.gh_pr_review.ttl_seconds,
    defaults.cache.gh_pr_review.ttl_seconds
  )
  result.gh_pr_review.max_cache_age_seconds = sanitize_positive_integer(
    result.gh_pr_review.max_cache_age_seconds,
    defaults.cache.gh_pr_review.max_cache_age_seconds
  )

  if type(result.gh_pr_review.auto_refresh_when_focused) ~= "boolean" then
    result.gh_pr_review.auto_refresh_when_focused = defaults.cache.gh_pr_review.auto_refresh_when_focused
  end

  if type(result.gh_pr_review.show_stale_badge) ~= "boolean" then
    result.gh_pr_review.show_stale_badge = defaults.cache.gh_pr_review.show_stale_badge
  end

  if type(result.gh_pr_review.sync_visible_buffers) ~= "boolean" then
    result.gh_pr_review.sync_visible_buffers = defaults.cache.gh_pr_review.sync_visible_buffers
  end

  return result
end

local function sanitize_path_render(path_render, opts)
  local result = vim.tbl_deep_extend("force", vim.deepcopy(defaults.path_render), type(path_render) == "table" and path_render or {})

  if result.scope ~= "both" and result.scope ~= "files" and result.scope ~= "comments" then
    result.scope = defaults.path_render.scope
  end

  if result.mode ~= "compact" and result.mode ~= "tree" and result.mode ~= "flat" then
    result.mode = defaults.path_render.mode
  end

  if type(result.separator) ~= "string" or result.separator == "" then
    result.separator = defaults.path_render.separator
  end

  if type(result.show_status_prefix) ~= "boolean" then
    result.show_status_prefix = defaults.path_render.show_status_prefix
  end

  if opts.path_render == nil and opts.file_list_layout ~= nil then
    result.mode = sanitize_legacy_file_list_layout(opts.file_list_layout)
  end

  return result
end

local function sanitize_follow_current_file(follow_current_file)
  if type(follow_current_file) ~= "table" then
    return vim.deepcopy(defaults.follow_current_file)
  end

  local result = vim.tbl_deep_extend("force", vim.deepcopy(defaults.follow_current_file), follow_current_file)
  if type(result.enabled) ~= "boolean" then
    result.enabled = defaults.follow_current_file.enabled
  end

  local debounce_ms = tonumber(result.debounce_ms)
  if type(debounce_ms) ~= "number" then
    debounce_ms = defaults.follow_current_file.debounce_ms
  end
  debounce_ms = math.floor(debounce_ms)
  if debounce_ms < 0 then
    debounce_ms = defaults.follow_current_file.debounce_ms
  end
  result.debounce_ms = debounce_ms

  result.sources = type(result.sources) == "table" and result.sources or {}
  if type(result.sources.pr) ~= "boolean" then
    result.sources.pr = defaults.follow_current_file.sources.pr
  end
  if type(result.sources.pr_review) ~= "boolean" then
    result.sources.pr_review = defaults.follow_current_file.sources.pr_review
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

  if result.indicator_style ~= "sign_and_highlight"
    and result.indicator_style ~= "sign_only"
    and result.indicator_style ~= "highlight_only"
    and result.indicator_style ~= "sign_and_virtual_text"
    and result.indicator_style ~= "virtual_text_only" then
    result.indicator_style = defaults.line_comments.indicator_style
  end

  result.max_popup_width = sanitize_positive_integer(result.max_popup_width, defaults.line_comments.max_popup_width)
  result.max_popup_height = sanitize_positive_integer(result.max_popup_height, defaults.line_comments.max_popup_height)

  result.popup = type(result.popup) == "table" and result.popup or {}
  if type(result.popup.enter) ~= "boolean" then
    result.popup.enter = defaults.line_comments.popup.enter
  end

  if result.popup.position ~= "cursor" and result.popup.position ~= "editor" and result.popup.position ~= "preview_window" then
    result.popup.position = defaults.line_comments.popup.position
  end

  if result.popup.border ~= "rounded"
    and result.popup.border ~= "single"
    and result.popup.border ~= "double"
    and result.popup.border ~= "solid"
    and result.popup.border ~= "shadow"
    and result.popup.border ~= "none" then
    result.popup.border = defaults.line_comments.popup.border
  end

  if type(result.popup.wrap) ~= "boolean" then
    result.popup.wrap = defaults.line_comments.popup.wrap
  end

  if type(result.popup.close_on_move) ~= "boolean" then
    result.popup.close_on_move = defaults.line_comments.popup.close_on_move
  end

  local legacy_popup_width = sanitize_positive_integer(result.max_popup_width, defaults.line_comments.max_popup_width)
  local legacy_popup_height = sanitize_positive_integer(result.max_popup_height, defaults.line_comments.max_popup_height)
  result.popup.max_width = sanitize_positive_integer(result.popup.max_width, legacy_popup_width)
  result.popup.max_height = sanitize_positive_integer(result.popup.max_height, legacy_popup_height)

  result.virtual_text = type(result.virtual_text) == "table" and result.virtual_text or {}
  if type(result.virtual_text.enabled) ~= "boolean" then
    result.virtual_text.enabled = defaults.line_comments.virtual_text.enabled
  end
  if type(result.virtual_text.prefix) ~= "string" or result.virtual_text.prefix == "" then
    result.virtual_text.prefix = defaults.line_comments.virtual_text.prefix
  end
  if type(result.virtual_text.show_count) ~= "boolean" then
    result.virtual_text.show_count = defaults.line_comments.virtual_text.show_count
  end
  if result.virtual_text.position ~= "eol" and result.virtual_text.position ~= "inline" then
    result.virtual_text.position = defaults.line_comments.virtual_text.position
  end

  result.signs = type(result.signs) == "table" and result.signs or {}
  result.signs.open = type(result.signs.open) == "string" and result.signs.open ~= "" and result.signs.open
    or defaults.line_comments.signs.open
  result.signs.resolved = type(result.signs.resolved) == "string" and result.signs.resolved ~= "" and result.signs.resolved
    or defaults.line_comments.signs.resolved
  result.signs.outdated = type(result.signs.outdated) == "string" and result.signs.outdated ~= "" and result.signs.outdated
    or defaults.line_comments.signs.outdated

  result.comments_tree = type(result.comments_tree) == "table" and result.comments_tree or {}
  if type(result.comments_tree.auto_open_thread_popup) ~= "boolean" then
    result.comments_tree.auto_open_thread_popup = defaults.line_comments.comments_tree.auto_open_thread_popup
  end

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

  result.comments_tree.thread_popup = type(result.comments_tree.thread_popup) == "table"
      and result.comments_tree.thread_popup
    or {}
  if type(result.comments_tree.thread_popup.enabled) ~= "boolean" then
    result.comments_tree.thread_popup.enabled = defaults.line_comments.comments_tree.thread_popup.enabled
  end

  result.comments_tree.thread_popup.width_ratio = sanitize_ratio(
    result.comments_tree.thread_popup.width_ratio,
    defaults.line_comments.comments_tree.thread_popup.width_ratio
  )
  result.comments_tree.thread_popup.height_ratio = sanitize_ratio(
    result.comments_tree.thread_popup.height_ratio,
    defaults.line_comments.comments_tree.thread_popup.height_ratio
  )
  result.comments_tree.thread_popup.min_width = sanitize_positive_integer(
    result.comments_tree.thread_popup.min_width,
    defaults.line_comments.comments_tree.thread_popup.min_width
  )
  result.comments_tree.thread_popup.min_height = sanitize_positive_integer(
    result.comments_tree.thread_popup.min_height,
    defaults.line_comments.comments_tree.thread_popup.min_height
  )
  result.comments_tree.thread_popup.max_width = sanitize_positive_integer(
    result.comments_tree.thread_popup.max_width,
    defaults.line_comments.comments_tree.thread_popup.max_width
  )
  result.comments_tree.thread_popup.max_height = sanitize_positive_integer(
    result.comments_tree.thread_popup.max_height,
    defaults.line_comments.comments_tree.thread_popup.max_height
  )

  if result.comments_tree.thread_popup.max_width < result.comments_tree.thread_popup.min_width then
    result.comments_tree.thread_popup.max_width = result.comments_tree.thread_popup.min_width
  end
  if result.comments_tree.thread_popup.max_height < result.comments_tree.thread_popup.min_height then
    result.comments_tree.thread_popup.max_height = result.comments_tree.thread_popup.min_height
  end

  if result.comments_tree.thread_popup.border ~= "rounded"
    and result.comments_tree.thread_popup.border ~= "single"
    and result.comments_tree.thread_popup.border ~= "double"
    and result.comments_tree.thread_popup.border ~= "solid"
    and result.comments_tree.thread_popup.border ~= "shadow"
    and result.comments_tree.thread_popup.border ~= "none" then
    result.comments_tree.thread_popup.border = defaults.line_comments.comments_tree.thread_popup.border
  end

  if type(result.comments_tree.thread_popup.wrap) ~= "boolean" then
    result.comments_tree.thread_popup.wrap = defaults.line_comments.comments_tree.thread_popup.wrap
  end

  if type(result.comments_tree.thread_popup.enter) ~= "boolean" then
    result.comments_tree.thread_popup.enter = defaults.line_comments.comments_tree.thread_popup.enter
  end

  if result.comments_tree.thread_popup.position ~= "cursor" and result.comments_tree.thread_popup.position ~= "preview_window" then
    result.comments_tree.thread_popup.position = defaults.line_comments.comments_tree.thread_popup.position
  end

  return result
end

local function sanitize_diff_view(diff_view)
  if type(diff_view) ~= "table" then
    return vim.deepcopy(defaults.diff_view)
  end

  local function sanitize_listchars_token(value, fallback)
    if type(value) ~= "string" or value == "" then
      return fallback
    end
    if value:find(",", 1, true) or value:find(":", 1, true) then
      return fallback
    end
    return value
  end

  local result = vim.tbl_deep_extend("force", vim.deepcopy(defaults.diff_view), diff_view)
  if result.mode ~= "vertical" and result.mode ~= "horizontal" and result.mode ~= "unified" then
    result.mode = defaults.diff_view.mode
  end

  if type(result.ignore_whitespace) ~= "boolean" then
    result.ignore_whitespace = defaults.diff_view.ignore_whitespace
  end

  if type(result.render_whitespace) ~= "boolean" then
    result.render_whitespace = defaults.diff_view.render_whitespace
  end

  result.whitespace = type(result.whitespace) == "table" and result.whitespace or {}
  result.whitespace.tab = sanitize_listchars_token(result.whitespace.tab, defaults.diff_view.whitespace.tab)
  result.whitespace.space = sanitize_listchars_token(result.whitespace.space, defaults.diff_view.whitespace.space)
  result.whitespace.trail = sanitize_listchars_token(result.whitespace.trail, defaults.diff_view.whitespace.trail)
  result.whitespace.nbsp = sanitize_listchars_token(result.whitespace.nbsp, defaults.diff_view.whitespace.nbsp)

  if type(result.whitespace.color) ~= "string" or result.whitespace.color == "" then
    result.whitespace.color = defaults.diff_view.whitespace.color
  end

  if type(result.whitespace.highlight_group) ~= "string" or result.whitespace.highlight_group == "" then
    result.whitespace.highlight_group = defaults.diff_view.whitespace.highlight_group
  end

  result.shortcuts = type(result.shortcuts) == "table" and result.shortcuts or {}
  result.shortcuts.toggle_whitespace = type(result.shortcuts.toggle_whitespace) == "string"
      and result.shortcuts.toggle_whitespace
    or defaults.diff_view.shortcuts.toggle_whitespace
  result.shortcuts.toggle_render_whitespace = type(result.shortcuts.toggle_render_whitespace) == "string"
      and result.shortcuts.toggle_render_whitespace
    or defaults.diff_view.shortcuts.toggle_render_whitespace
  result.shortcuts.cycle_mode = type(result.shortcuts.cycle_mode) == "string" and result.shortcuts.cycle_mode
    or defaults.diff_view.shortcuts.cycle_mode
  result.shortcuts.set_vertical = type(result.shortcuts.set_vertical) == "string" and result.shortcuts.set_vertical
    or defaults.diff_view.shortcuts.set_vertical
  result.shortcuts.set_horizontal = type(result.shortcuts.set_horizontal) == "string" and result.shortcuts.set_horizontal
    or defaults.diff_view.shortcuts.set_horizontal
  result.shortcuts.set_unified = type(result.shortcuts.set_unified) == "string" and result.shortcuts.set_unified
    or defaults.diff_view.shortcuts.set_unified

  return result
end

function M.setup(opts)
  opts = opts or {}
  state = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts)
  state.remotes = sanitize_remotes(state.remotes)
  state.queries = sanitize_queries(state.queries)

  state.file_list_layout = sanitize_legacy_file_list_layout(state.file_list_layout)

  if type(state.max_results) ~= "number" or state.max_results < 1 then
    state.max_results = defaults.max_results
  end

  if type(state.hide_viewed_files) ~= "boolean" then
    state.hide_viewed_files = defaults.hide_viewed_files
  end

  state.line_comments = sanitize_line_comments(state.line_comments)
  state.overview = sanitize_overview(state.overview)
  state.cache = sanitize_cache(state.cache)
  state.follow_current_file = sanitize_follow_current_file(state.follow_current_file)
  state.diff_view = sanitize_diff_view(state.diff_view)
  state.path_render = sanitize_path_render(state.path_render, opts)

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

function M.get_path_render(source_name)
  local path_render = type(state.path_render) == "table" and state.path_render or vim.deepcopy(defaults.path_render)
  local applies =
    path_render.scope == "both"
    or (path_render.scope == "files" and source_name == "gh_pr")
    or (path_render.scope == "comments" and source_name == "gh_pr_comments")

  if applies then
    return vim.deepcopy(path_render)
  end

  if source_name == "gh_pr" then
    return {
      scope = "files",
      mode = sanitize_legacy_file_list_layout(state.file_list_layout),
      separator = path_render.separator or defaults.path_render.separator,
      show_status_prefix = path_render.show_status_prefix ~= false,
    }
  end

  if source_name == "gh_pr_comments" then
    return {
      scope = "comments",
      mode = "flat",
      separator = path_render.separator or defaults.path_render.separator,
      show_status_prefix = path_render.show_status_prefix ~= false,
    }
  end

  return vim.deepcopy(path_render)
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
