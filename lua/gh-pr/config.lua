local M = {}
local diff_shortcuts = require("gh-pr.diff_shortcuts")

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
  pr_review = {
    files = {
      flat = false,
    },
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
      show_authors = true,
      max_authors = 2,
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
    reactions = {
      render = "emoji",
      viewer_marker = "*",
      picker = {
        position = "cursor",
        border = "rounded",
        enter = true,
        width = 56,
        height = 10,
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
      width_ratio = 0.9,
      height_ratio = 0.9,
      min_width = 110,
      min_height = 30,
      max_width = 220,
      max_height = 80,
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
      mode = "full",
      provider = "render-markdown",
      max_lines = 500,
      code_block_border = false,
      link_preview_keymap = "gp",
      link_preview_max_bytes = 10485760,
      github_style = true,
      github_style_separators = "rules",
      diff_gutter = "none",
      link_preview_renderable_extensions = {
        "txt",
        "md",
        "markdown",
        "json",
        "yaml",
        "yml",
        "csv",
        "log",
      },
      link_preview_disallowed_extensions = {
        "zip",
      },
      link_preview_open_local = "disabled",
    },
    thread_snippet = {
      context_before = 5,
      context_after = 5,
    },
    thread_fix_diff = {
      enabled = true,
      show_action_line = true,
      keymap = "gf",
      inline = true,
      context_before = 5,
      context_after = 5,
      fallback_to_buffer = true,
    },
    panes = {
      layout = {
        sidebar_width_ratio = 0.34,
        summary_height_ratio = 0.38,
        gap = 1,
        min_left_width = 58,
        min_sidebar_width = 30,
        min_summary_height = 10,
        min_activity_height = 12,
      },
      activity = {
        visual_style = "minimal",
        max_body_lines = 8,
        max_events = 120,
        show_code_context = true,
      },
      keymaps = {
        cycle_next = "<Tab>",
        cycle_prev = "<S-Tab>",
        focus_summary = "g1",
        focus_activity = "g2",
        focus_meta = "g3",
        help = "?",
        focus_left = "<C-h>",
        focus_down = "<C-j>",
        focus_up = "<C-k>",
        focus_right = "<C-l>",
      },
    },
    tabs = {
      "summary",
      "checks",
      "commits",
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
      pr_changes = true,
      labels = true,
    },
  },
  overview_v2 = {
    enabled = false,
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
    render_endlines = false,
    debug = {
      codediff_failures = false,
    },
    whitespace = {
      tab = ">-",
      space = ".",
      trail = "~",
      nbsp = "+",
      color = nil,
      highlight_group = "GhPrDiffWhitespace",
    },
    endlines = {
      lf = "LF",
      crlf = "CRLF",
      cr = "CR",
      color = "#d16969",
      highlight_group = "GhPrDiffEndline",
    },
    shortcuts = vim.deepcopy(diff_shortcuts.defaults),
    comments_panel = {
      enabled = true,
      auto_open = "if_comments",
      position = "bottom",
      height_ratio = 0.28,
      min_height = 8,
      max_height = 18,
      follow_cursor = true,
      show_resolved = true,
      show_outdated = true,
      close_with_dq = true,
    },
    images = {
      enabled = true,
      backend = "snacks",
      formats = { "png", "jpg", "jpeg", "gif", "webp", "bmp", "svg" },
      cache_dir = nil,
      fallback = "placeholder",
      fallback_mode = "menu",
      fallback_default_action = "metadata",
      fallback_menu_keymap = "gf",
      fallback_open_local = "disabled",
      fallback_github_target = "pr_files",
      show_metadata = true,
      metadata_resolution_strategy = "hybrid",
      metadata_external_command = { "magick", "identify", "-format", "%w %h", "{file}" },
      max_bytes = 26214400,
    },
    non_text = {
      enabled = true,
      auto_preview = true,
      show_metadata = true,
    },
    prefetch = {
      enabled = true,
      concurrency = 4,
      text_extensions = {
        "txt",
        "md",
        "markdown",
        "json",
        "jsonc",
        "yaml",
        "yml",
        "toml",
        "ini",
        "cfg",
        "conf",
        "log",
        "csv",
        "tsv",
        "lua",
        "vim",
        "js",
        "jsx",
        "ts",
        "tsx",
        "css",
        "scss",
        "sass",
        "less",
        "html",
        "htm",
        "xml",
        "sh",
        "bash",
        "zsh",
        "fish",
        "ps1",
        "psm1",
        "psd1",
        "bat",
        "cmd",
        "sql",
        "c",
        "h",
        "cpp",
        "hpp",
        "cc",
        "hh",
        "cs",
        "go",
        "rs",
        "py",
        "rb",
        "php",
        "java",
        "kt",
        "kts",
      },
    },
  },
  ui = {
    use_neotree = true,
    telescope_fallback = true,
    neotree_sources = {
      pr = {
        auto_register = true,
        gate = "github_repo",
        workspace = "cwd",
      },
    },
  },
  mappings = {
    global = {
      enabled = false,
      keys = {
        open = "<leader>gho",
        list = "<leader>ghl",
        comments = "<leader>ghm",
        refresh = "<leader>ghr",
        overview = "<leader>ghv",
        checkout = "<leader>ghc",
        open_diff = "<leader>ghd",
        review_tree = "<leader>ghx",
        toggle_reviewed = "<leader>ght",
        next_change = "<leader>ghn",
        prev_change = "<leader>ghp",
      },
    },
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
local deprecation_warnings = {}

local function notify_deprecation_once(key, message)
  if deprecation_warnings[key] then
    return
  end
  deprecation_warnings[key] = true
  if type(vim.notify_once) == "function" then
    vim.notify_once(message, vim.log.levels.WARN, { title = "gh-pr" })
    return
  end
  if type(vim.notify) == "function" then
    vim.notify(message, vim.log.levels.WARN)
  end
end

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

local function sanitize_local_open_policy(value, default_value)
  local policy = type(value) == "string" and value:lower() or default_value
  if policy == "disabled" or policy == "reveal_only" or policy == "system" then
    return policy
  end
  return default_value
end

local function sanitize_non_negative_integer(value, default_value)
  if type(value) ~= "number" then
    return default_value
  end

  local rounded = math.floor(value)
  if rounded < 0 then
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
    comments = true,
    reviews = true,
    threads = true,
    timeline = true,
    files = true,
  }
  local aliases = {
    timeline = "summary",
    comments = "summary",
    reviews = "summary",
    threads = "summary",
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

local function sanitize_extension_list(input, fallback)
  local source = type(input) == "table" and input or fallback
  local result = {}
  local seen = {}

  for _, value in ipairs(source) do
    if type(value) == "string" and value ~= "" then
      local normalized = value:lower():gsub("^%.+", "")
      if normalized ~= "" and not seen[normalized] then
        seen[normalized] = true
        result[#result + 1] = normalized
      end
    end
  end

  if vim.tbl_isempty(result) then
    return vim.deepcopy(fallback)
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
  if type(result.markdown.mode) == "string" then
    result.markdown.mode = result.markdown.mode:lower()
  end
  if result.markdown.mode ~= "full" and result.markdown.mode ~= "legacy" then
    result.markdown.mode = defaults.overview.markdown.mode
  end
  if type(result.markdown.provider) == "string" then
    result.markdown.provider = result.markdown.provider:lower()
  end
  if result.markdown.provider == "auto" or result.markdown.provider == "markview" then
    result.markdown.provider = "render-markdown"
  end
  if result.markdown.provider ~= "builtin" and result.markdown.provider ~= "render-markdown" then
    result.markdown.provider = defaults.overview.markdown.provider
  end
  result.markdown.max_lines = sanitize_positive_integer(result.markdown.max_lines, defaults.overview.markdown.max_lines)
  if result.markdown.max_lines < 50 then
    result.markdown.max_lines = 50
  end
  if type(result.markdown.code_block_border) ~= "boolean" then
    result.markdown.code_block_border = defaults.overview.markdown.code_block_border
  end
  if type(result.markdown.link_preview_keymap) ~= "string" then
    result.markdown.link_preview_keymap = defaults.overview.markdown.link_preview_keymap
  end
  result.markdown.link_preview_max_bytes = sanitize_positive_integer(
    result.markdown.link_preview_max_bytes,
    defaults.overview.markdown.link_preview_max_bytes
  )
  result.markdown.link_preview_renderable_extensions = sanitize_extension_list(
    result.markdown.link_preview_renderable_extensions,
    defaults.overview.markdown.link_preview_renderable_extensions
  )
  result.markdown.link_preview_disallowed_extensions = sanitize_extension_list(
    result.markdown.link_preview_disallowed_extensions,
    defaults.overview.markdown.link_preview_disallowed_extensions
  )
  result.markdown.link_preview_open_local = sanitize_local_open_policy(
    result.markdown.link_preview_open_local,
    defaults.overview.markdown.link_preview_open_local
  )
  if type(result.markdown.github_style) ~= "boolean" then
    result.markdown.github_style = defaults.overview.markdown.github_style
  end
  if type(result.markdown.github_style_separators) == "string" then
    result.markdown.github_style_separators = result.markdown.github_style_separators:lower()
  end
  if result.markdown.github_style_separators ~= "rules" then
    result.markdown.github_style_separators = defaults.overview.markdown.github_style_separators
  end
  if type(result.markdown.diff_gutter) == "string" then
    result.markdown.diff_gutter = result.markdown.diff_gutter:lower()
  end
  if result.markdown.diff_gutter ~= "old_new_code" and result.markdown.diff_gutter ~= "none" then
    result.markdown.diff_gutter = defaults.overview.markdown.diff_gutter
  end
  if result.markdown.diff_gutter == "old_new_code" then
    result.markdown.diff_gutter = "none"
  end

  result.thread_snippet = type(result.thread_snippet) == "table" and result.thread_snippet or {}
  result.thread_snippet.context_before = sanitize_non_negative_integer(
    result.thread_snippet.context_before,
    defaults.overview.thread_snippet.context_before
  )
  result.thread_snippet.context_after = sanitize_non_negative_integer(
    result.thread_snippet.context_after,
    defaults.overview.thread_snippet.context_after
  )
  if result.thread_snippet.context_before > 200 then
    result.thread_snippet.context_before = 200
  end
  if result.thread_snippet.context_after > 200 then
    result.thread_snippet.context_after = 200
  end

  result.thread_fix_diff = type(result.thread_fix_diff) == "table" and result.thread_fix_diff or {}
  if type(result.thread_fix_diff.enabled) ~= "boolean" then
    result.thread_fix_diff.enabled = defaults.overview.thread_fix_diff.enabled
  end
  if type(result.thread_fix_diff.show_action_line) ~= "boolean" then
    result.thread_fix_diff.show_action_line = defaults.overview.thread_fix_diff.show_action_line
  end
  if type(result.thread_fix_diff.keymap) ~= "string" then
    result.thread_fix_diff.keymap = defaults.overview.thread_fix_diff.keymap
  end
  if type(result.thread_fix_diff.inline) ~= "boolean" then
    result.thread_fix_diff.inline = defaults.overview.thread_fix_diff.inline
  end
  result.thread_fix_diff.context_before = sanitize_non_negative_integer(
    result.thread_fix_diff.context_before,
    defaults.overview.thread_fix_diff.context_before
  )
  result.thread_fix_diff.context_after = sanitize_non_negative_integer(
    result.thread_fix_diff.context_after,
    defaults.overview.thread_fix_diff.context_after
  )
  if result.thread_fix_diff.context_before > 200 then
    result.thread_fix_diff.context_before = 200
  end
  if result.thread_fix_diff.context_after > 200 then
    result.thread_fix_diff.context_after = 200
  end
  if type(result.thread_fix_diff.fallback_to_buffer) ~= "boolean" then
    result.thread_fix_diff.fallback_to_buffer = defaults.overview.thread_fix_diff.fallback_to_buffer
  end

  result.panes = type(result.panes) == "table" and result.panes or {}
  result.panes.layout = type(result.panes.layout) == "table" and result.panes.layout or {}
  local sidebar_ratio = tonumber(result.panes.layout.sidebar_width_ratio)
  if type(sidebar_ratio) ~= "number" or sidebar_ratio < 0.2 or sidebar_ratio > 0.6 then
    sidebar_ratio = defaults.overview.panes.layout.sidebar_width_ratio
  end
  result.panes.layout.sidebar_width_ratio = sidebar_ratio
  local summary_ratio = tonumber(result.panes.layout.summary_height_ratio)
  if type(summary_ratio) ~= "number" or summary_ratio < 0.2 or summary_ratio > 0.8 then
    summary_ratio = defaults.overview.panes.layout.summary_height_ratio
  end
  result.panes.layout.summary_height_ratio = summary_ratio
  result.panes.layout.gap = sanitize_non_negative_integer(result.panes.layout.gap, defaults.overview.panes.layout.gap)
  if result.panes.layout.gap > 3 then
    result.panes.layout.gap = defaults.overview.panes.layout.gap
  end
  result.panes.layout.min_left_width = sanitize_positive_integer(
    result.panes.layout.min_left_width,
    defaults.overview.panes.layout.min_left_width
  )
  result.panes.layout.min_sidebar_width = sanitize_positive_integer(
    result.panes.layout.min_sidebar_width,
    defaults.overview.panes.layout.min_sidebar_width
  )
  result.panes.layout.min_summary_height = sanitize_positive_integer(
    result.panes.layout.min_summary_height,
    defaults.overview.panes.layout.min_summary_height
  )
  result.panes.layout.min_activity_height = sanitize_positive_integer(
    result.panes.layout.min_activity_height,
    defaults.overview.panes.layout.min_activity_height
  )

  result.panes.activity = type(result.panes.activity) == "table" and result.panes.activity or {}
  if type(result.panes.activity.visual_style) == "string" then
    result.panes.activity.visual_style = result.panes.activity.visual_style:lower()
  end
  if result.panes.activity.visual_style ~= "minimal" and result.panes.activity.visual_style ~= "classic" then
    result.panes.activity.visual_style = defaults.overview.panes.activity.visual_style
  end
  result.panes.activity.max_body_lines = sanitize_positive_integer(
    result.panes.activity.max_body_lines,
    defaults.overview.panes.activity.max_body_lines
  )
  result.panes.activity.max_events = sanitize_positive_integer(
    result.panes.activity.max_events,
    defaults.overview.panes.activity.max_events
  )
  if type(result.panes.activity.show_code_context) ~= "boolean" then
    result.panes.activity.show_code_context = defaults.overview.panes.activity.show_code_context
  end

  result.panes.keymaps = type(result.panes.keymaps) == "table" and result.panes.keymaps or {}
  if type(result.panes.keymaps.cycle_next) ~= "string" then
    result.panes.keymaps.cycle_next = defaults.overview.panes.keymaps.cycle_next
  end
  if type(result.panes.keymaps.cycle_prev) ~= "string" then
    result.panes.keymaps.cycle_prev = defaults.overview.panes.keymaps.cycle_prev
  end
  if type(result.panes.keymaps.focus_summary) ~= "string" then
    result.panes.keymaps.focus_summary = defaults.overview.panes.keymaps.focus_summary
  end
  if type(result.panes.keymaps.focus_activity) ~= "string" then
    result.panes.keymaps.focus_activity = defaults.overview.panes.keymaps.focus_activity
  end
  if type(result.panes.keymaps.focus_meta) ~= "string" then
    result.panes.keymaps.focus_meta = defaults.overview.panes.keymaps.focus_meta
  end
  if type(result.panes.keymaps.help) ~= "string" then
    result.panes.keymaps.help = defaults.overview.panes.keymaps.help
  end
  if type(result.panes.keymaps.focus_left) ~= "string" then
    result.panes.keymaps.focus_left = defaults.overview.panes.keymaps.focus_left
  end
  if type(result.panes.keymaps.focus_down) ~= "string" then
    result.panes.keymaps.focus_down = defaults.overview.panes.keymaps.focus_down
  end
  if type(result.panes.keymaps.focus_up) ~= "string" then
    result.panes.keymaps.focus_up = defaults.overview.panes.keymaps.focus_up
  end
  if type(result.panes.keymaps.focus_right) ~= "string" then
    result.panes.keymaps.focus_right = defaults.overview.panes.keymaps.focus_right
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
  if type(result.show.checks) ~= "boolean" then
    result.show.checks = defaults.overview.show.checks
  end
  if type(result.show.commits) ~= "boolean" then
    result.show.commits = defaults.overview.show.commits
  end
  if type(result.show.timeline) ~= "boolean" then
    result.show.timeline = defaults.overview.show.timeline
  end
  if type(result.show.comments) ~= "boolean" then
    result.show.comments = defaults.overview.show.comments
  end
  if type(result.show.reviews) ~= "boolean" then
    result.show.reviews = defaults.overview.show.reviews
  end
  if type(result.show.threads) ~= "boolean" then
    result.show.threads = defaults.overview.show.threads
  end
  if type(result.show.pr_changes) ~= "boolean" then
    result.show.pr_changes = defaults.overview.show.pr_changes
  end
  if type(result.show.labels) ~= "boolean" then
    result.show.labels = defaults.overview.show.labels
  end

  return result
end

local function merge_legacy_overview_v2_alias(overview, overview_v2)
  if type(overview_v2) ~= "table" then
    return overview
  end

  local legacy_overview = {
    date_format = overview_v2.date_format,
    window = overview_v2.window,
    show = overview_v2.show,
    panes = {
      layout = overview_v2.layout,
      activity = overview_v2.activity,
      keymaps = overview_v2.keymaps,
    },
  }

  if type(overview_v2.enabled) == "boolean" then
    legacy_overview.window = type(legacy_overview.window) == "table" and legacy_overview.window or {}
    legacy_overview.window.enabled = overview_v2.enabled
  end

  return vim.tbl_deep_extend("force", legacy_overview, type(overview) == "table" and overview or {})
end

local function build_overview_v2_alias(overview)
  local source = type(overview) == "table" and overview or {}
  local panes = type(source.panes) == "table" and source.panes or {}
  local window = type(source.window) == "table" and source.window or {}

  return {
    enabled = window.enabled ~= false,
    date_format = source.date_format,
    window = window,
    layout = panes.layout,
    activity = panes.activity,
    show = source.show,
    keymaps = panes.keymaps,
  }
end

local function sanitize_overview_v2(overview_v2)
  local canonical = sanitize_overview(merge_legacy_overview_v2_alias(nil, overview_v2))
  local result = build_overview_v2_alias(canonical)
  local source = type(overview_v2) == "table" and overview_v2 or nil

  if source and type(source.enabled) == "boolean" then
    result.enabled = source.enabled
  else
    result.enabled = defaults.overview_v2.enabled
  end

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

local function sanitize_pr_review(pr_review)
  if type(pr_review) ~= "table" then
    return vim.deepcopy(defaults.pr_review)
  end

  local result = vim.tbl_deep_extend("force", vim.deepcopy(defaults.pr_review), pr_review)
  result.files = type(result.files) == "table" and result.files or {}
  if type(result.files.flat) ~= "boolean" then
    result.files.flat = defaults.pr_review.files.flat
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

local function sanitize_mappings(mappings)
  if type(mappings) ~= "table" then
    return vim.deepcopy(defaults.mappings)
  end

  local result = vim.tbl_deep_extend("force", vim.deepcopy(defaults.mappings), mappings)
  result.global = type(result.global) == "table" and result.global or {}

  if type(result.global.enabled) ~= "boolean" then
    result.global.enabled = defaults.mappings.global.enabled
  end

  result.global.keys = type(result.global.keys) == "table" and result.global.keys or {}
  for key, lhs in pairs(defaults.mappings.global.keys) do
    if type(result.global.keys[key]) ~= "string" or result.global.keys[key] == "" then
      result.global.keys[key] = lhs
    end
  end

  return result
end

local function sanitize_neotree_sources(neotree_sources)
  if type(neotree_sources) ~= "table" then
    return vim.deepcopy(defaults.ui.neotree_sources)
  end

  local result = vim.tbl_deep_extend("force", vim.deepcopy(defaults.ui.neotree_sources), neotree_sources)
  result.pr = type(result.pr) == "table" and result.pr or {}

  if type(result.pr.auto_register) ~= "boolean" then
    result.pr.auto_register = defaults.ui.neotree_sources.pr.auto_register
  end

  if result.pr.gate ~= "github_repo" and result.pr.gate ~= "git_repo" and result.pr.gate ~= "manual" then
    result.pr.gate = defaults.ui.neotree_sources.pr.gate
  end

  if result.pr.workspace ~= "cwd" and result.pr.workspace ~= "buffer_repo" and result.pr.workspace ~= "neotree_root" then
    result.pr.workspace = defaults.ui.neotree_sources.pr.workspace
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
  if type(result.virtual_text.show_authors) ~= "boolean" then
    result.virtual_text.show_authors = defaults.line_comments.virtual_text.show_authors
  end
  result.virtual_text.max_authors =
    sanitize_positive_integer(result.virtual_text.max_authors, defaults.line_comments.virtual_text.max_authors)
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

  result.reactions = type(result.reactions) == "table" and result.reactions or {}
  if result.reactions.render ~= "emoji" and result.reactions.render ~= "text" then
    result.reactions.render = defaults.line_comments.reactions.render
  end
  if type(result.reactions.viewer_marker) ~= "string" or result.reactions.viewer_marker == "" then
    result.reactions.viewer_marker = defaults.line_comments.reactions.viewer_marker
  end

  result.reactions.picker = type(result.reactions.picker) == "table" and result.reactions.picker or {}
  if type(result.reactions.picker.enter) ~= "boolean" then
    result.reactions.picker.enter = defaults.line_comments.reactions.picker.enter
  end
  if result.reactions.picker.position ~= "cursor"
    and result.reactions.picker.position ~= "editor"
    and result.reactions.picker.position ~= "preview_window" then
    result.reactions.picker.position = defaults.line_comments.reactions.picker.position
  end
  if result.reactions.picker.border ~= "rounded"
    and result.reactions.picker.border ~= "single"
    and result.reactions.picker.border ~= "double"
    and result.reactions.picker.border ~= "solid"
    and result.reactions.picker.border ~= "shadow"
    and result.reactions.picker.border ~= "none" then
    result.reactions.picker.border = defaults.line_comments.reactions.picker.border
  end
  result.reactions.picker.width = math.max(
    36,
    sanitize_positive_integer(result.reactions.picker.width, defaults.line_comments.reactions.picker.width)
  )
  result.reactions.picker.height = math.max(
    8,
    sanitize_positive_integer(result.reactions.picker.height, defaults.line_comments.reactions.picker.height)
  )

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
  if type(result.render_endlines) ~= "boolean" then
    result.render_endlines = defaults.diff_view.render_endlines
  end

  result.debug = type(result.debug) == "table" and result.debug or {}
  if type(result.debug.codediff_failures) ~= "boolean" then
    result.debug.codediff_failures = defaults.diff_view.debug.codediff_failures
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

  result.endlines = type(result.endlines) == "table" and result.endlines or {}
  local function sanitize_endline_marker(value, fallback)
    if type(value) ~= "string" or value == "" then
      return fallback
    end
    local trimmed = value:gsub("[%c]", "")
    if trimmed == "" then
      return fallback
    end
    return trimmed
  end
  result.endlines.lf = sanitize_endline_marker(result.endlines.lf, defaults.diff_view.endlines.lf)
  result.endlines.crlf = sanitize_endline_marker(result.endlines.crlf, defaults.diff_view.endlines.crlf)
  result.endlines.cr = sanitize_endline_marker(result.endlines.cr, defaults.diff_view.endlines.cr)
  if type(result.endlines.color) ~= "string" or result.endlines.color == "" then
    result.endlines.color = defaults.diff_view.endlines.color
  end
  if type(result.endlines.highlight_group) ~= "string" or result.endlines.highlight_group == "" then
    result.endlines.highlight_group = defaults.diff_view.endlines.highlight_group
  end

  result.shortcuts = diff_shortcuts.resolve(result.shortcuts)

  result.comments_panel = type(result.comments_panel) == "table" and result.comments_panel or {}
  if type(result.comments_panel.enabled) ~= "boolean" then
    result.comments_panel.enabled = defaults.diff_view.comments_panel.enabled
  end
  local comments_panel_auto_open = result.comments_panel.auto_open
  if comments_panel_auto_open == true then
    comments_panel_auto_open = "if_comments"
  elseif comments_panel_auto_open == false then
    comments_panel_auto_open = "never"
  end
  if comments_panel_auto_open ~= "never"
    and comments_panel_auto_open ~= "if_comments"
    and comments_panel_auto_open ~= "always" then
    comments_panel_auto_open = defaults.diff_view.comments_panel.auto_open
  end
  result.comments_panel.auto_open = comments_panel_auto_open

  local comments_panel_position = type(result.comments_panel.position) == "string"
      and result.comments_panel.position:lower()
    or defaults.diff_view.comments_panel.position
  if comments_panel_position ~= "bottom" and comments_panel_position ~= "right" then
    comments_panel_position = defaults.diff_view.comments_panel.position
  end
  result.comments_panel.position = comments_panel_position

  local comments_panel_height_ratio = tonumber(result.comments_panel.height_ratio)
  if type(comments_panel_height_ratio) ~= "number" or comments_panel_height_ratio < 0.10 or comments_panel_height_ratio > 0.80 then
    comments_panel_height_ratio = defaults.diff_view.comments_panel.height_ratio
  end
  result.comments_panel.height_ratio = comments_panel_height_ratio

  local comments_panel_min_height = tonumber(result.comments_panel.min_height)
  if type(comments_panel_min_height) ~= "number" then
    comments_panel_min_height = defaults.diff_view.comments_panel.min_height
  end
  comments_panel_min_height = math.floor(comments_panel_min_height)
  if comments_panel_min_height < 3 then
    comments_panel_min_height = defaults.diff_view.comments_panel.min_height
  end
  result.comments_panel.min_height = comments_panel_min_height

  local comments_panel_max_height = tonumber(result.comments_panel.max_height)
  if type(comments_panel_max_height) ~= "number" then
    comments_panel_max_height = defaults.diff_view.comments_panel.max_height
  end
  comments_panel_max_height = math.floor(comments_panel_max_height)
  if comments_panel_max_height < comments_panel_min_height then
    comments_panel_max_height = math.max(comments_panel_min_height, defaults.diff_view.comments_panel.max_height)
  end
  result.comments_panel.max_height = comments_panel_max_height

  if type(result.comments_panel.follow_cursor) ~= "boolean" then
    result.comments_panel.follow_cursor = defaults.diff_view.comments_panel.follow_cursor
  end
  if type(result.comments_panel.show_resolved) ~= "boolean" then
    result.comments_panel.show_resolved = defaults.diff_view.comments_panel.show_resolved
  end
  if type(result.comments_panel.show_outdated) ~= "boolean" then
    result.comments_panel.show_outdated = defaults.diff_view.comments_panel.show_outdated
  end
  if type(result.comments_panel.close_with_dq) ~= "boolean" then
    result.comments_panel.close_with_dq = defaults.diff_view.comments_panel.close_with_dq
  end

  result.images = type(result.images) == "table" and result.images or {}
  if type(result.images.enabled) ~= "boolean" then
    result.images.enabled = defaults.diff_view.images.enabled
  end
  if type(result.images.backend) ~= "string" or result.images.backend == "" then
    result.images.backend = defaults.diff_view.images.backend
  end
  result.images.backend = result.images.backend:lower()
  if result.images.backend ~= "snacks" then
    result.images.backend = defaults.diff_view.images.backend
  end

  local formats = {}
  for _, ext in ipairs(type(result.images.formats) == "table" and result.images.formats or {}) do
    if type(ext) == "string" and ext ~= "" then
      local normalized = ext:lower():gsub("^%.+", "")
      if normalized ~= "" then
        formats[#formats + 1] = normalized
      end
    end
  end
  if vim.tbl_isempty(formats) then
    formats = vim.deepcopy(defaults.diff_view.images.formats)
  end
  result.images.formats = formats

  if type(result.images.cache_dir) ~= "string" or result.images.cache_dir == "" then
    result.images.cache_dir = defaults.diff_view.images.cache_dir
  end

  if type(result.images.fallback) ~= "string" or result.images.fallback == "" then
    result.images.fallback = defaults.diff_view.images.fallback
  end
  result.images.fallback = result.images.fallback:lower()
  if result.images.fallback ~= "placeholder" then
    result.images.fallback = defaults.diff_view.images.fallback
  end

  if type(result.images.fallback_mode) ~= "string" or result.images.fallback_mode == "" then
    result.images.fallback_mode = defaults.diff_view.images.fallback_mode
  end
  result.images.fallback_mode = result.images.fallback_mode:lower()
  if result.images.fallback_mode ~= "menu"
    and result.images.fallback_mode ~= "metadata_only"
    and result.images.fallback_mode ~= "auto_local"
    and result.images.fallback_mode ~= "auto_github" then
    result.images.fallback_mode = defaults.diff_view.images.fallback_mode
  end

  if type(result.images.fallback_default_action) ~= "string" or result.images.fallback_default_action == "" then
    result.images.fallback_default_action = defaults.diff_view.images.fallback_default_action
  end
  result.images.fallback_default_action = result.images.fallback_default_action:lower()
  if result.images.fallback_default_action ~= "metadata"
    and result.images.fallback_default_action ~= "open_local_current"
    and result.images.fallback_default_action ~= "open_local_both"
    and result.images.fallback_default_action ~= "open_github" then
    result.images.fallback_default_action = defaults.diff_view.images.fallback_default_action
  end

  if type(result.images.fallback_menu_keymap) ~= "string" then
    result.images.fallback_menu_keymap = defaults.diff_view.images.fallback_menu_keymap
  end

  result.images.fallback_open_local = sanitize_local_open_policy(
    result.images.fallback_open_local,
    defaults.diff_view.images.fallback_open_local
  )

  if type(result.images.fallback_github_target) ~= "string" or result.images.fallback_github_target == "" then
    result.images.fallback_github_target = defaults.diff_view.images.fallback_github_target
  end
  result.images.fallback_github_target = result.images.fallback_github_target:lower()
  if result.images.fallback_github_target ~= "pr_files" and result.images.fallback_github_target ~= "pr" then
    result.images.fallback_github_target = defaults.diff_view.images.fallback_github_target
  end

  if type(result.images.show_metadata) ~= "boolean" then
    result.images.show_metadata = defaults.diff_view.images.show_metadata
  end

  if type(result.images.metadata_resolution_strategy) ~= "string" or result.images.metadata_resolution_strategy == "" then
    result.images.metadata_resolution_strategy = defaults.diff_view.images.metadata_resolution_strategy
  end
  result.images.metadata_resolution_strategy = result.images.metadata_resolution_strategy:lower()
  if result.images.metadata_resolution_strategy ~= "internal"
    and result.images.metadata_resolution_strategy ~= "external"
    and result.images.metadata_resolution_strategy ~= "hybrid" then
    result.images.metadata_resolution_strategy = defaults.diff_view.images.metadata_resolution_strategy
  end

  local external_command = {}
  for _, token in ipairs(type(result.images.metadata_external_command) == "table" and result.images.metadata_external_command or {}) do
    if type(token) == "string" and token ~= "" then
      external_command[#external_command + 1] = token
    end
  end
  if vim.tbl_isempty(external_command) then
    external_command = vim.deepcopy(defaults.diff_view.images.metadata_external_command)
  end
  result.images.metadata_external_command = external_command

  local max_bytes = tonumber(result.images.max_bytes)
  if type(max_bytes) ~= "number" or max_bytes < 1 then
    max_bytes = defaults.diff_view.images.max_bytes
  end
  result.images.max_bytes = math.floor(max_bytes)

  result.non_text = type(result.non_text) == "table" and result.non_text or {}
  if type(result.non_text.enabled) ~= "boolean" then
    result.non_text.enabled = defaults.diff_view.non_text.enabled
  end
  if type(result.non_text.auto_preview) ~= "boolean" then
    result.non_text.auto_preview = defaults.diff_view.non_text.auto_preview
  end
  if type(result.non_text.show_metadata) ~= "boolean" then
    result.non_text.show_metadata = defaults.diff_view.non_text.show_metadata
  end

  result.prefetch = type(result.prefetch) == "table" and result.prefetch or {}
  if type(result.prefetch.enabled) ~= "boolean" then
    result.prefetch.enabled = defaults.diff_view.prefetch.enabled
  end
  result.prefetch.concurrency = sanitize_positive_integer(
    result.prefetch.concurrency,
    defaults.diff_view.prefetch.concurrency
  )
  result.prefetch.text_extensions = sanitize_extension_list(
    result.prefetch.text_extensions,
    defaults.diff_view.prefetch.text_extensions
  )

  return result
end

function M.setup(opts)
  opts = type(opts) == "table" and opts or {}
  local legacy_overview_v2_input = type(opts.overview_v2) == "table" and opts.overview_v2 or nil
  local merged_overview_input = merge_legacy_overview_v2_alias(
    type(opts.overview) == "table" and opts.overview or nil,
    legacy_overview_v2_input
  )

  if legacy_overview_v2_input and not vim.tbl_isempty(legacy_overview_v2_input) then
    notify_deprecation_once(
      "overview_v2",
      "gh-pr: `overview_v2` is deprecated; migrate to `overview` "
        .. "(date_format/window/show) and `overview.panes` (layout/activity/keymaps)."
    )
  end

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
  state.overview = sanitize_overview(merged_overview_input)
  state.overview_v2 = sanitize_overview_v2(build_overview_v2_alias(state.overview))
  if legacy_overview_v2_input and type(legacy_overview_v2_input.enabled) == "boolean" then
    state.overview_v2.enabled = legacy_overview_v2_input.enabled
  else
    state.overview_v2.enabled = defaults.overview_v2.enabled
  end
  state.cache = sanitize_cache(state.cache)
  state.follow_current_file = sanitize_follow_current_file(state.follow_current_file)
  state.diff_view = sanitize_diff_view(state.diff_view)
  state.path_render = sanitize_path_render(state.path_render, opts)
  state.pr_review = sanitize_pr_review(state.pr_review)
  state.mappings = sanitize_mappings(state.mappings)

  if type(state.ui) ~= "table" then
    state.ui = vim.deepcopy(defaults.ui)
  end

  if type(state.ui.use_neotree) ~= "boolean" then
    state.ui.use_neotree = defaults.ui.use_neotree
  end

  if type(state.ui.telescope_fallback) ~= "boolean" then
    state.ui.telescope_fallback = defaults.ui.telescope_fallback
  end

  state.ui.neotree_sources = sanitize_neotree_sources(state.ui.neotree_sources)
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
