local M = {}

local config = require("gh-pr.config")
local registry = require("gh-pr.neotree.registry")
local uv = vim.uv or vim.loop

local runtime_initialized = false
local auto_refresh_group = nil
local auto_refresh_timer = nil
local follow_current_file_seq = 0

local function stop_auto_refresh_timer()
  if auto_refresh_timer then
    auto_refresh_timer:stop()
    auto_refresh_timer:close()
    auto_refresh_timer = nil
  end
end

local function start_auto_refresh_timer()
  stop_auto_refresh_timer()

  local cache_config = ((config.get() or {}).cache or {})
  local gh_pr_cache_options = type(cache_config.gh_pr) == "table" and cache_config.gh_pr or {}
  local gh_pr_review_cache_options = type(cache_config.gh_pr_review) == "table" and cache_config.gh_pr_review or {}

  local gh_pr_enabled = gh_pr_cache_options.auto_refresh_when_focused ~= false
  local gh_pr_review_enabled = gh_pr_review_cache_options.auto_refresh_when_focused ~= false
  if not gh_pr_enabled and not gh_pr_review_enabled then
    return
  end

  local intervals = {}
  if gh_pr_enabled then
    intervals[#intervals + 1] = tonumber(gh_pr_cache_options.ttl_seconds) or 60
  end
  if gh_pr_review_enabled then
    intervals[#intervals + 1] = tonumber(gh_pr_review_cache_options.ttl_seconds) or 60
  end

  local interval = intervals[1] or 60
  for index = 2, #intervals do
    interval = math.min(interval, intervals[index])
  end
  interval = math.max(1, math.floor(interval))

  if not uv or type(uv.new_timer) ~= "function" then
    return
  end

  auto_refresh_timer = uv.new_timer()
  if not auto_refresh_timer then
    return
  end

  local interval_ms = interval * 1000
  auto_refresh_timer:start(interval_ms, interval_ms, vim.schedule_wrap(function()
    local source = registry.get("gh_pr")
    if gh_pr_enabled and type(source) == "table" and type(source.request_refresh) == "function" then
      local focused = type(source.is_focused) == "function" and source.is_focused() == true
      pcall(source.request_refresh, nil, {
        force = false,
        notify_error = false,
        refresh_context = {
          mode = focused and "ui-refresh" or "cache-only",
          reason = "timer",
          notify = focused,
        },
      })
    end

    local review_source = registry.get("gh_pr_review")
    if gh_pr_review_enabled and type(review_source) == "table" and type(review_source.request_refresh) == "function" then
      local focused = type(review_source.is_focused) == "function" and review_source.is_focused() == true
      pcall(review_source.request_refresh, nil, {
        force = false,
        notify_error = false,
        refresh_context = {
          mode = focused and "ui-refresh" or "cache-only",
          reason = "timer",
          notify = focused,
        },
      })
    end
  end))
end

local function follow_current_file_options()
  local options = (config.get() or {}).follow_current_file or {}
  local sources = type(options.sources) == "table" and options.sources or {}
  local debounce_ms = tonumber(options.debounce_ms)
  if type(debounce_ms) ~= "number" then
    debounce_ms = 60
  end
  debounce_ms = math.max(0, math.floor(debounce_ms))

  return {
    enabled = options.enabled ~= false,
    debounce_ms = debounce_ms,
    source_pr = sources.pr ~= false,
    source_pr_review = sources.pr_review ~= false,
  }
end

local function schedule_follow_current_file()
  local options = follow_current_file_options()
  if not options.enabled then
    return
  end

  follow_current_file_seq = follow_current_file_seq + 1
  local token = follow_current_file_seq
  vim.defer_fn(function()
    if token ~= follow_current_file_seq then
      return
    end

    local review_visible = false
    if options.source_pr_review then
      local review_source = registry.get("gh_pr_review")
      if type(review_source) == "table" and type(review_source.follow_current_file_if_visible) == "function" then
        local ok, visible = pcall(review_source.follow_current_file_if_visible, { reason = "autocmd" })
        review_visible = ok and visible == true
      end
    end

    if not review_visible and options.source_pr then
      local source = registry.get("gh_pr")
      if type(source) == "table" and type(source.follow_current_file_if_visible) == "function" then
        pcall(source.follow_current_file_if_visible, { reason = "autocmd" })
      end
    end
  end, options.debounce_ms)
end

local function read_buffer_boolean_option(bufnr, option_name)
  if type(bufnr) ~= "number" or bufnr < 1 or not vim.api.nvim_buf_is_valid(bufnr) then
    return false
  end

  local ok, value = pcall(vim.api.nvim_get_option_value, option_name, { buf = bufnr })
  if not ok then
    return false
  end
  return value == true
end

local function has_ghpr_uri_name(bufnr)
  if type(bufnr) ~= "number" or bufnr < 1 or not vim.api.nvim_buf_is_valid(bufnr) then
    return false
  end

  local ok, name = pcall(vim.api.nvim_buf_get_name, bufnr)
  if not ok or type(name) ~= "string" or name == "" then
    return false
  end

  return name:sub(1, 7) == "ghpr://"
end

local function clear_modified_on_readonly_ghpr_buffer(bufnr)
  if not has_ghpr_uri_name(bufnr) then
    return
  end

  local readonly = read_buffer_boolean_option(bufnr, "readonly")
  local modifiable = read_buffer_boolean_option(bufnr, "modifiable")
  if (not readonly) and modifiable then
    return
  end

  if not read_buffer_boolean_option(bufnr, "modified") then
    return
  end

  pcall(vim.api.nvim_set_option_value, "modified", false, { buf = bufnr })
end

function M.is_initialized()
  return runtime_initialized
end

function M.restart_auto_refresh_timer()
  if not runtime_initialized then
    return
  end

  start_auto_refresh_timer()
end

function M.ensure_initialized(opts)
  opts = opts or {}
  if runtime_initialized then
    return true
  end

  local ensure_required_dependencies = opts.ensure_required_dependencies
  if type(ensure_required_dependencies) == "function" then
    ensure_required_dependencies()
  end

  local setup_highlights = opts.setup_highlights
  if type(setup_highlights) == "function" then
    setup_highlights()
  end

  local setup_state = opts.setup_state
  if type(setup_state) == "function" then
    setup_state()
  end

  local setup_queries = opts.setup_queries
  if type(setup_queries) == "function" then
    setup_queries(opts.skip_query_file_load == true)
  end

  start_auto_refresh_timer()

  if not auto_refresh_group then
    auto_refresh_group = vim.api.nvim_create_augroup("GhPrAutoRefresh", { clear = true })
    vim.api.nvim_create_autocmd("VimLeavePre", {
      group = auto_refresh_group,
      callback = stop_auto_refresh_timer,
    })
    vim.api.nvim_create_autocmd({ "BufEnter", "WinEnter" }, {
      group = auto_refresh_group,
      callback = schedule_follow_current_file,
    })
    vim.api.nvim_create_autocmd({ "BufEnter", "WinEnter", "BufModifiedSet" }, {
      group = auto_refresh_group,
      callback = function(args)
        local bufnr = type(args) == "table" and tonumber(args.buf) or nil
        if type(bufnr) ~= "number" or bufnr < 1 then
          bufnr = vim.api.nvim_get_current_buf()
        end
        clear_modified_on_readonly_ghpr_buffer(bufnr)
      end,
    })
  end

  runtime_initialized = true
  return true
end

return M
