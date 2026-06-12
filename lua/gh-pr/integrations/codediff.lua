local M = {}

local uv = vim.uv or vim.loop

local virtual_files = require("gh-pr.virtual_files")

-- Lazy, dependency-free access to the file logger (codediff channel).
local function log_codediff(level, message)
  local ok, logger = pcall(require, "gh-pr.core.logger")
  if ok then
    logger.log("codediff", level, message)
  end
end

local temp_state = {
  root = nil,
  file_cache = {},
  remote_pair_cache = {},
  dir_cache = {},
  dir_jobs = {},
  pr_explorer_sessions = {},
  cleanup_attached = false,
  readonly_guard_attached = false,
  pr_explorer_tracking_attached = false,
}

local IS_WINDOWS = package.config:sub(1, 1) == "\\"

local function safe_string(value)
  return type(value) == "string" and value or ""
end

local function normalize_layout(layout)
  local value = safe_string(layout):lower()
  if value == "inline" or value == "unified" then
    return "inline"
  end
  return "side-by-side"
end

local function apply_codediff_preferences(opts)
  opts = type(opts) == "table" and opts or {}
  local ok_config, codediff_config = pcall(require, "codediff.config")
  if not ok_config or type(codediff_config) ~= "table" or type(codediff_config.setup) ~= "function" then
    return
  end

  pcall(codediff_config.setup, {
    diff = {
      layout = normalize_layout(opts.layout),
      ignore_trim_whitespace = opts.ignore_trim_whitespace == true,
    },
  })
end

local function normalize_path(path)
  local value = safe_string(path):gsub("\\", "/")
  if IS_WINDOWS then
    value = value:lower()
  end
  return value
end

local function normalize_abs_path(path)
  if type(path) ~= "string" or path == "" then
    return ""
  end
  local absolute = vim.fn.fnamemodify(path, ":p")
  return normalize_path(absolute)
end

local function joinpath(...)
  if vim.fs and type(vim.fs.joinpath) == "function" then
    return vim.fs.joinpath(...)
  end
  return table.concat({ ... }, "/")
end

local function file_readable(path)
  return type(path) == "string" and path ~= "" and vim.fn.filereadable(path) == 1
end

local function ensure_dir(path)
  if type(path) ~= "string" or path == "" then
    return false
  end
  local created = vim.fn.mkdir(path, "p")
  return created ~= 0 or vim.fn.isdirectory(path) == 1
end

local function cache_root()
  if type(temp_state.root) == "string" and temp_state.root ~= "" then
    return temp_state.root, nil
  end

  local root = joinpath(vim.fn.stdpath("cache"), "gh-pr", "codediff")
  if not ensure_dir(root) then
    log_codediff("error", "Unable to prepare codediff cache directory: " .. root)
    return nil, "Unable to prepare codediff cache directory"
  end

  temp_state.root = root
  return root, nil
end

local function ensure_cleanup_autocmd()
  if temp_state.cleanup_attached then
    return
  end
  temp_state.cleanup_attached = true

  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = vim.api.nvim_create_augroup("GhPrCodediffTempCleanup", { clear = true }),
    callback = function()
      local root = temp_state.root
      if type(root) == "string" and root ~= "" and vim.fn.isdirectory(root) == 1 then
        pcall(vim.fn.delete, root, "rf")
      end
    end,
  })
end

local function is_valid_buf(bufnr)
  return type(bufnr) == "number" and bufnr > 0 and vim.api.nvim_buf_is_valid(bufnr)
end

local function is_valid_tab(tabpage)
  return type(tabpage) == "number" and tabpage > 0 and vim.api.nvim_tabpage_is_valid(tabpage)
end

local function is_valid_win(winid)
  return type(winid) == "number" and winid > 0 and vim.api.nvim_win_is_valid(winid)
end

local function sha256(value)
  local ok, digest = pcall(vim.fn.sha256, tostring(value))
  if ok and type(digest) == "string" and digest ~= "" then
    return digest
  end
  return tostring(math.abs((uv.hrtime and uv.hrtime() or os.time())))
end

local function sanitize_relative_path(path, fallback_name)
  local normalized = safe_string(path):gsub("\\", "/")
  normalized = normalized:gsub("^/*", "")

  local parts = {}
  for part in normalized:gmatch("[^/]+") do
    if part ~= "" and part ~= "." and part ~= ".." then
      parts[#parts + 1] = part
    end
  end

  local result = table.concat(parts, "/")
  if result == "" then
    return fallback_name or "file.txt"
  end
  return result
end

local function write_bytes(path, content)
  local parent = path:match("^(.*)[/\\][^/\\]+$")
  if parent and parent ~= "" and not ensure_dir(parent) then
    return nil, "Unable to prepare temp directory for codediff file"
  end

  local fd, open_err = uv.fs_open(path, "w", 420)
  if not fd then
    return nil, tostring(open_err or "Unable to open codediff temp file")
  end

  local payload = type(content) == "string" and content or ""
  local ok_write, write_err = uv.fs_write(fd, payload, -1)
  uv.fs_close(fd)
  if not ok_write then
    return nil, tostring(write_err or "Unable to write codediff temp file")
  end

  return path, nil
end

local function ensure_cached_file(cache_key, relative_path, content)
  local cached = temp_state.file_cache[cache_key]
  if file_readable(cached) then
    return cached, nil
  end

  local root, root_err = cache_root()
  if not root then
    return nil, root_err
  end

  local sanitized = sanitize_relative_path(relative_path, "file.txt")
  local path = joinpath(root, "pairs", sha256(cache_key), sanitized)
  local written, write_err = write_bytes(path, content)
  if not written then
    return nil, write_err
  end

  temp_state.file_cache[cache_key] = written
  ensure_cleanup_autocmd()
  return written, nil
end

local function is_probably_binary(content)
  if type(content) ~= "string" or content == "" then
    return false
  end
  if content:find("\0", 1, true) then
    return true
  end

  local sample = content:sub(1, 4096)
  local invalid = 0
  for i = 1, #sample do
    local byte = sample:byte(i)
    if byte and (byte < 9 or (byte > 13 and byte < 32)) then
      invalid = invalid + 1
    end
  end
  return #sample > 0 and (invalid / #sample) > 0.12
end

local function ensure_codediff_command()
  if vim.fn.exists(":CodeDiff") == 2 then
    return true
  end
  pcall(require, "codediff")
  return vim.fn.exists(":CodeDiff") == 2
end

local function codediff_cache_root_normalized()
  local root = safe_string(temp_state.root)
  if root == "" then
    local resolved, err = cache_root()
    if not resolved then
      return nil, err
    end
    root = resolved
  end

  local normalized = normalize_abs_path(root)
  if normalized == "" then
    return nil, "Unable to resolve codediff cache root"
  end
  if normalized:sub(-1) ~= "/" then
    normalized = normalized .. "/"
  end
  return normalized, nil
end

local function is_codediff_temp_buffer(bufnr)
  if not is_valid_buf(bufnr) then
    return false
  end

  local root, root_err = codediff_cache_root_normalized()
  if not root then
    return false, root_err
  end

  local name = normalize_abs_path(vim.api.nvim_buf_get_name(bufnr))
  if name == "" then
    return false
  end
  return name:sub(1, #root) == root
end

local function mark_codediff_temp_buffer(bufnr)
  local is_temp = is_codediff_temp_buffer(bufnr)
  if not is_temp then
    return false
  end

  vim.b[bufnr].gh_pr_lsp_exclude = true
  vim.b[bufnr].gh_pr_transient_diff_buffer = true
  vim.b[bufnr].gh_pr_codediff_temp = true
  return true
end

local function apply_codediff_readonly_lock(bufnr)
  local is_temp = mark_codediff_temp_buffer(bufnr)
  if not is_temp then
    return false
  end

  pcall(vim.api.nvim_set_option_value, "readonly", false, { buf = bufnr })
  pcall(vim.api.nvim_set_option_value, "modifiable", true, { buf = bufnr })
  pcall(vim.api.nvim_set_option_value, "modified", false, { buf = bufnr })
  pcall(vim.api.nvim_set_option_value, "swapfile", false, { buf = bufnr })
  pcall(vim.api.nvim_set_option_value, "readonly", true, { buf = bufnr })
  pcall(vim.api.nvim_set_option_value, "modifiable", false, { buf = bufnr })

  for _, winid in ipairs(vim.fn.win_findbuf(bufnr)) do
    if type(winid) == "number" and winid > 0 and vim.api.nvim_win_is_valid(winid) then
      pcall(vim.api.nvim_set_option_value, "number", true, { win = winid })
      pcall(vim.api.nvim_set_option_value, "relativenumber", true, { win = winid })
    end
  end

  return true
end

local function apply_readonly_lock_to_tab(tabpage)
  if not is_valid_tab(tabpage) then
    return
  end

  for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(tabpage)) do
    if vim.api.nvim_win_is_valid(winid) then
      local bufnr = vim.api.nvim_win_get_buf(winid)
      apply_codediff_readonly_lock(bufnr)
    end
  end
end

local function ensure_readonly_guard_autocmd()
  if temp_state.readonly_guard_attached then
    return true, nil
  end

  local _, root_err = codediff_cache_root_normalized()
  if root_err then
    return nil, root_err
  end

  temp_state.readonly_guard_attached = true
  local group = vim.api.nvim_create_augroup("GhPrCodediffReadonly", { clear = true })
  vim.api.nvim_create_autocmd({ "BufAdd", "BufFilePost" }, {
    group = group,
    desc = "gh-pr: mark codediff temp buffers as transient",
    callback = function(args)
      mark_codediff_temp_buffer(tonumber(args.buf))
    end,
  })
  vim.api.nvim_create_autocmd({ "BufReadPost", "BufWinEnter" }, {
    group = group,
    desc = "gh-pr: keep codediff temp buffers readonly",
    callback = function(args)
      apply_codediff_readonly_lock(tonumber(args.buf))
    end,
  })

  return true, nil
end

function M.is_available()
  return ensure_codediff_command()
end

local function run_codediff_command(command)
  if not ensure_codediff_command() then
    local message = "codediff.nvim is unavailable (`:CodeDiff` not found)"
    log_codediff("error", message)
    return nil, message
  end

  local ok, cmd_err = pcall(vim.cmd, command)
  if not ok then
    log_codediff("error", string.format("CodeDiff command failed: %s -> %s", tostring(command), tostring(cmd_err)))
    return nil, tostring(cmd_err)
  end
  return true, nil
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

local function resolve_snapshot_concurrency()
  local ok_config, config = pcall(require, "gh-pr.config")
  if not ok_config or type(config) ~= "table" or type(config.get) ~= "function" then
    return 4
  end

  local plugin_config = type(config.get()) == "table" and config.get() or {}
  local diff_view = type(plugin_config.diff_view) == "table" and plugin_config.diff_view or {}
  local prefetch = type(diff_view.prefetch) == "table" and diff_view.prefetch or {}
  return positive_integer(prefetch.concurrency, 4)
end

local function schedule(callback, ...)
  if type(callback) ~= "function" then
    return
  end

  local args = { ... }
  vim.schedule(function()
    callback((table.unpack or unpack)(args))
  end)
end

local function start_progress_notifier(total)
  local timer = uv.new_timer()
  local state = {
    current = 0,
    total = positive_integer(total, 0),
    shown = false,
    stopped = false,
  }

  if timer then
    timer:start(350, 1000, vim.schedule_wrap(function()
      if state.stopped then
        return
      end
      state.shown = true
      vim.notify(
        string.format("gh-pr: Loading codediff explorer: %d/%d files", state.current, state.total),
        vim.log.levels.INFO
      )
    end))
  end

  local function stop()
    state.stopped = true
    if timer then
      timer:stop()
      timer:close()
    end
  end

  return {
    update = function(current, next_total)
      state.current = positive_integer(current, state.current)
      state.total = positive_integer(next_total, state.total)
    end,
    finish = function(message, level)
      stop()
      if state.shown and type(message) == "string" and message ~= "" then
        vim.notify(message, level or vim.log.levels.INFO)
      end
    end,
    stop = stop,
  }
end

local function find_buffer_for_path(path)
  local target = normalize_abs_path(path)
  if target == "" then
    return nil
  end

  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      local name = normalize_abs_path(vim.api.nvim_buf_get_name(bufnr))
      if name == target then
        return bufnr
      end
    end
  end

  return nil
end

local function resolve_lifecycle_windows()
  local ok_lifecycle, lifecycle = pcall(require, "codediff.ui.lifecycle")
  if not ok_lifecycle then
    return nil
  end

  local tabpage = vim.api.nvim_get_current_tabpage()
  local base_buf, head_buf = lifecycle.get_buffers(tabpage)
  local base_win, head_win = lifecycle.get_windows(tabpage)

  if type(base_buf) ~= "number" or type(head_buf) ~= "number" then
    return nil
  end

  return {
    tabpage = tabpage,
    base_buf = base_buf,
    head_buf = head_buf,
    base_win = base_win,
    head_win = head_win,
  }
end

local function resolve_file_open_result(base_open_path, head_open_path)
  local base_buf = find_buffer_for_path(base_open_path)
  local head_buf = find_buffer_for_path(head_open_path)
  local base_win = nil
  local head_win = nil

  if type(base_buf) == "number" and base_buf > 0 then
    local candidate = vim.fn.bufwinid(base_buf)
    if type(candidate) == "number" and candidate > 0 and vim.api.nvim_win_is_valid(candidate) then
      base_win = candidate
    end
  end

  if type(head_buf) == "number" and head_buf > 0 then
    local candidate = vim.fn.bufwinid(head_buf)
    if type(candidate) == "number" and candidate > 0 and vim.api.nvim_win_is_valid(candidate) then
      head_win = candidate
    end
  end

  if not (base_buf and head_buf and base_win and head_win) then
    local lifecycle_result = resolve_lifecycle_windows()
    if lifecycle_result then
      base_buf = base_buf or lifecycle_result.base_buf
      head_buf = head_buf or lifecycle_result.head_buf
      base_win = base_win or lifecycle_result.base_win
      head_win = head_win or lifecycle_result.head_win
    end
  end

  if not (base_buf and head_buf) then
    return nil, "Unable to resolve opened codediff buffers"
  end

  local tabpage = nil
  if type(base_win) == "number" and base_win > 0 and vim.api.nvim_win_is_valid(base_win) then
    tabpage = vim.api.nvim_win_get_tabpage(base_win)
  elseif type(head_win) == "number" and head_win > 0 and vim.api.nvim_win_is_valid(head_win) then
    tabpage = vim.api.nvim_win_get_tabpage(head_win)
  else
    tabpage = vim.api.nvim_get_current_tabpage()
  end

  return {
    mode = "file",
    tabpage = tabpage,
    base_buf = base_buf,
    head_buf = head_buf,
    base_win = base_win,
    head_win = head_win,
    base_temp_path = base_open_path,
    head_temp_path = head_open_path,
  }, nil
end

local function fallback_error(message)
  log_codediff("debug", "Falling back to virtual backend: " .. tostring(message))
  return {
    requires_virtual = true,
    message = message,
  }
end

local function ensure_textual_remote_pair(data)
  if type(data) ~= "table" then
    return nil, "Invalid remote pair payload"
  end

  if data.is_image == true then
    return nil, fallback_error("Image diffs are not supported by codediff backend.")
  end

  local base_content = safe_string(data.base_content)
  local head_content = safe_string(data.head_content)
  if is_probably_binary(base_content) or is_probably_binary(head_content) then
    return nil, fallback_error("Binary/non-renderable content requires virtual fallback backend.")
  end

  return true, nil
end

local function pair_scope(opts)
  opts = type(opts) == "table" and opts or {}
  local details = type(opts.details) == "table" and opts.details or {}
  local file = type(opts.file) == "table" and opts.file or {}
  local cache_scope = safe_string(opts.cache_scope)

  if cache_scope ~= "" then
    return cache_scope
  end

  local path = safe_string(file.path ~= "" and file.path or file.filename)
  return table.concat({
    safe_string(details.baseRefName),
    safe_string(details.headRefName),
    path,
    safe_string(file.status),
  }, "|")
end

local function repository_identity(repository)
  repository = type(repository) == "table" and repository or {}
  local full_name = safe_string(repository.full_name)
  if full_name ~= "" then
    return full_name
  end

  full_name = safe_string(repository.nameWithOwner)
  if full_name ~= "" then
    return full_name
  end

  local owner = safe_string(type(repository.owner) == "table" and repository.owner.login or repository.owner)
  local name = safe_string(repository.name)
  if owner ~= "" and name ~= "" then
    return owner .. "/" .. name
  end

  return ""
end

local function file_lookup_candidates(file)
  file = type(file) == "table" and file or {}
  local candidates = {}
  local seen = {}

  local function add(path)
    local normalized = sanitize_relative_path(path, "")
    if normalized ~= "" and not seen[normalized] then
      seen[normalized] = true
      candidates[#candidates + 1] = normalized
    end
  end

  add(file.path)
  add(file.filename)
  add(file.previous_filename)
  add(file.previousFilename)

  return candidates
end

local function build_pr_file_lookup(details)
  local lookup = {}
  for _, raw in ipairs(type(details) == "table" and type(details.files) == "table" and details.files or {}) do
    if type(raw) == "table" then
      for _, candidate in ipairs(file_lookup_candidates(raw)) do
        if lookup[candidate] == nil then
          lookup[candidate] = raw
        end
      end
    end
  end
  return lookup
end

local function resolve_lookup_file(lookup, file_data)
  lookup = type(lookup) == "table" and lookup or {}
  file_data = type(file_data) == "table" and file_data or {}
  for _, candidate in ipairs({
    sanitize_relative_path(file_data.path, ""),
    sanitize_relative_path(file_data.old_path, ""),
  }) do
    if candidate ~= "" and type(lookup[candidate]) == "table" then
      return lookup[candidate]
    end
  end
  return nil
end

local function pr_explorer_session_key(opts)
  opts = type(opts) == "table" and opts or {}
  local details = type(opts.details) == "table" and opts.details or {}
  return table.concat({
    "pr-explorer",
    repository_identity(details.baseRepository),
    tostring(tonumber(opts.pr_number) or tonumber(details.number) or 0),
    safe_string(details.baseRefName),
    safe_string(details.headRefName),
  }, "|")
end

local function pair_side_cache_key(opts, data, side, relative_path)
  opts = type(opts) == "table" and opts or {}
  data = type(data) == "table" and data or {}
  local details = type(opts.details) == "table" and opts.details or {}
  local asset = side == "base" and data.base_asset or data.head_asset
  local repository = side == "base" and data.base_repo or data.head_repo
  local ref = side == "base" and safe_string(details.baseRefName) or safe_string(details.headRefName)
  local content_key = safe_string(type(asset) == "table" and asset.sha or "")
  if content_key == "" then
    content_key = ref
  end

  return table.concat({
    side,
    repository_identity(repository),
    sanitize_relative_path(relative_path, side .. ".txt"),
    content_key,
  }, "|")
end

local function prepare_pair_from_data(opts, data)
  opts = type(opts) == "table" and opts or {}
  data = type(data) == "table" and data or {}
  local textual_ok, textual_err = ensure_textual_remote_pair(data)
  if not textual_ok then
    return nil, textual_err
  end

  local base_relative = sanitize_relative_path(data.base_path, "base.txt")
  local head_relative = sanitize_relative_path(data.head_path, "head.txt")
  local base_key = pair_side_cache_key(opts, data, "base", base_relative)
  local head_key = pair_side_cache_key(opts, data, "head", head_relative)

  local base_temp, base_err = ensure_cached_file(base_key, base_relative, safe_string(data.base_content))
  if not base_temp then
    return nil, base_err
  end

  local head_temp, head_err = ensure_cached_file(head_key, head_relative, safe_string(data.head_content))
  if not head_temp then
    return nil, head_err
  end

  return {
    data = data,
    base_temp_path = base_temp,
    head_temp_path = head_temp,
  }, nil
end

local function prepare_pair_from_remote(opts)
  opts = type(opts) == "table" and opts or {}
  local details = type(opts.details) == "table" and opts.details or nil
  local file = type(opts.file) == "table" and opts.file or nil
  if not details or not file then
    return nil, "Missing details/file payload for codediff open"
  end

  local scope = pair_scope(opts)
  local data = temp_state.remote_pair_cache[scope]
  local data_err = nil
  if type(data) ~= "table" then
    data, data_err = virtual_files.load_remote_file_pair(details, file)
    if type(data) == "table" then
      temp_state.remote_pair_cache[scope] = data
    end
  end
  if not data then
    return nil, data_err or "Unable to load file content from GitHub"
  end

  return prepare_pair_from_data(opts, data)
end

local function prepare_pair_from_remote_async(opts, callback)
  callback = callback or function() end
  opts = type(opts) == "table" and opts or {}
  local details = type(opts.details) == "table" and opts.details or nil
  local file = type(opts.file) == "table" and opts.file or nil
  if not details or not file then
    callback(nil, "Missing details/file payload for codediff open")
    return
  end

  local scope = pair_scope(opts)
  local cached = temp_state.remote_pair_cache[scope]
  if type(cached) == "table" then
    callback(prepare_pair_from_data(opts, cached))
    return
  end

  virtual_files.load_remote_file_pair_async(details, file, function(data, data_err)
    if not data then
      callback(nil, data_err or "Unable to load file content from GitHub")
      return
    end

    temp_state.remote_pair_cache[scope] = data
    callback(prepare_pair_from_data(opts, data))
  end)
end

local function directory_signature(opts, files)
  local signature = { pair_scope(opts), "directory" }
  for _, raw in ipairs(type(files) == "table" and files or {}) do
    local file = type(raw) == "table" and raw or {}
    signature[#signature + 1] = table.concat({
      safe_string(file.path ~= "" and file.path or file.filename),
      safe_string(file.previous_filename ~= "" and file.previous_filename or file.previousFilename),
      safe_string(file.status),
      safe_string(file.patch),
    }, ":")
  end
  return sha256(table.concat(signature, "|"))
end

local function cached_directory_snapshot(dir_key)
  local cached = temp_state.dir_cache[dir_key]
  if type(cached) == "table"
    and vim.fn.isdirectory(cached.base_dir or "") == 1
    and vim.fn.isdirectory(cached.head_dir or "") == 1 then
    return cached
  end
  return nil
end

local function target_candidate_set(target_path)
  local target_candidates = {}
  for _, candidate in ipairs(file_lookup_candidates({
    path = target_path,
    filename = target_path,
  })) do
    target_candidates[candidate] = true
  end
  return target_candidates
end

local function file_matches_candidates(file, target_candidates)
  if next(target_candidates) == nil then
    return false
  end

  for _, candidate in ipairs(file_lookup_candidates(file)) do
    if target_candidates[candidate] then
      return true
    end
  end
  return false
end

local function status_letter(status, file_mode)
  local mode = safe_string(file_mode)
  if mode == "added_single" then
    return "A"
  end
  if mode == "removed_single" then
    return "D"
  end

  local value = safe_string(status):lower()
  if value == "added" or value == "a" then
    return "A"
  end
  if value == "removed" or value == "deleted" or value == "d" then
    return "D"
  end
  if value == "renamed" or value == "r" then
    return "R"
  end
  if value == "copied" or value == "c" then
    return "C"
  end
  return "M"
end

local function snapshot_entry_from_data(data)
  data = type(data) == "table" and data or {}
  local file_mode = safe_string(data.file_mode)
  local path = file_mode == "removed_single"
      and sanitize_relative_path(data.base_path, "")
    or sanitize_relative_path(data.head_path, "")
  if path == "" then
    path = sanitize_relative_path(data.base_path, "")
  end
  if path == "" then
    return nil
  end
  return {
    path = path,
    status = status_letter(data.status, file_mode),
    group = "unstaged",
  }
end

local function status_result_from_entries(entries)
  return {
    conflicts = {},
    unstaged = vim.deepcopy(type(entries) == "table" and entries or {}),
    staged = {},
  }
end

local function prepare_directory_snapshot(opts)
  opts = type(opts) == "table" and opts or {}
  local details = type(opts.details) == "table" and opts.details or nil
  local files = type(opts.files) == "table" and opts.files or nil
  if not details or not files then
    return nil, "Missing details/files payload for codediff directory open"
  end

  if vim.tbl_isempty(files) then
    return nil, "Selected commit has no files to open in codediff"
  end

  local root, root_err = cache_root()
  if not root then
    return nil, root_err
  end

  local dir_key = directory_signature(opts, files)

  local cached = cached_directory_snapshot(dir_key)
  if cached then
    return cached, nil
  end
  if opts.only_if_cached == true then
    return nil, "codediff PR explorer snapshot is not ready yet"
  end

  local base_dir = joinpath(root, "dirs", dir_key, "base")
  local head_dir = joinpath(root, "dirs", dir_key, "head")
  if not ensure_dir(base_dir) or not ensure_dir(head_dir) then
    return nil, "Unable to prepare codediff temporary directories"
  end

  local target_candidates = target_candidate_set(opts.target_path)

  local included = 0
  local entries = {}
  local target_included = next(target_candidates) == nil

  for _, raw in ipairs(files) do
    local file = type(raw) == "table" and raw or {}
    local matches_target = file_matches_candidates(file, target_candidates)

    local scope = pair_scope({
      details = details,
      file = file,
    })
    local data = temp_state.remote_pair_cache[scope]
    local data_err = nil
    if type(data) ~= "table" then
      data, data_err = virtual_files.load_remote_file_pair(details, file)
      if type(data) == "table" then
        temp_state.remote_pair_cache[scope] = data
      end
    end
    if not data then
      if matches_target then
        return nil, data_err or "Unable to load commit file content from GitHub"
      end
      goto continue
    end

    local textual_ok, textual_err = ensure_textual_remote_pair(data)
    if not textual_ok then
      if matches_target then
        return nil, textual_err
      end
      goto continue
    end

    local file_mode = safe_string(data.file_mode)
    local include_base = file_mode ~= "added_single"
    local include_head = file_mode ~= "removed_single"
    if file_mode == "" then
      local status = safe_string(data.status)
      include_base = status ~= "added"
      include_head = status ~= "removed"
    end

    if include_base then
      local base_rel = sanitize_relative_path(data.base_path, "base.txt")
      local base_path = joinpath(base_dir, base_rel)
      local _, write_base_err = write_bytes(base_path, safe_string(data.base_content))
      if write_base_err then
        return nil, write_base_err
      end
    end

    if include_head then
      local head_rel = sanitize_relative_path(data.head_path, "head.txt")
      local head_path = joinpath(head_dir, head_rel)
      local _, write_head_err = write_bytes(head_path, safe_string(data.head_content))
      if write_head_err then
        return nil, write_head_err
      end
    end

    included = included + 1
    entries[#entries + 1] = snapshot_entry_from_data(data)
    if matches_target then
      target_included = true
    end

    ::continue::
  end

  if included < 1 then
    return nil, fallback_error("No textual files are available for codediff explorer.")
  end
  if not target_included then
    return nil, "Selected file is unavailable in codediff PR explorer"
  end

  local prepared = {
    mode = "directory",
    base_dir = base_dir,
    head_dir = head_dir,
    key = dir_key,
    included = included,
    entries = entries,
    status_result = status_result_from_entries(entries),
  }
  temp_state.dir_cache[dir_key] = prepared
  ensure_cleanup_autocmd()
  return prepared, nil
end

local function prepare_directory_snapshot_async(opts, progress, callback)
  if type(progress) == "function" and type(callback) ~= "function" then
    callback = progress
    progress = nil
  end
  callback = callback or function() end
  opts = type(opts) == "table" and opts or {}
  local details = type(opts.details) == "table" and opts.details or nil
  local files = type(opts.files) == "table" and opts.files or nil
  if not details or not files then
    schedule(callback, nil, "Missing details/files payload for codediff directory open")
    return
  end

  if vim.tbl_isempty(files) then
    schedule(callback, nil, "Selected commit has no files to open in codediff")
    return
  end

  local root, root_err = cache_root()
  if not root then
    schedule(callback, nil, root_err)
    return
  end

  local dir_key = directory_signature(opts, files)
  local cached = cached_directory_snapshot(dir_key)
  if cached then
    schedule(callback, cached, nil)
    return
  end

  local running_job = temp_state.dir_jobs[dir_key]
  if type(running_job) == "table" then
    running_job.callbacks[#running_job.callbacks + 1] = callback
    if type(progress) == "function" then
      running_job.progress[#running_job.progress + 1] = progress
    end
    return
  end

  local base_dir = joinpath(root, "dirs", dir_key, "base")
  local head_dir = joinpath(root, "dirs", dir_key, "head")
  if not ensure_dir(base_dir) or not ensure_dir(head_dir) then
    schedule(callback, nil, "Unable to prepare codediff temporary directories")
    return
  end

  local job = {
    callbacks = { callback },
    progress = type(progress) == "function" and { progress } or {},
    completed = 0,
    included = 0,
    entries = {},
    failed = false,
    target_included = next(target_candidate_set(opts.target_path)) == nil,
  }
  temp_state.dir_jobs[dir_key] = job

  local target_candidates = target_candidate_set(opts.target_path)
  local index = 0
  local active = 0
  local total = #files
  local concurrency = math.min(resolve_snapshot_concurrency(), total)

  local function notify_progress()
    for _, on_progress in ipairs(job.progress) do
      pcall(on_progress, {
        completed = job.completed,
        total = total,
        included = job.included,
      })
    end
  end

  local function finish(prepared, err)
    temp_state.dir_jobs[dir_key] = nil
    for _, done in ipairs(job.callbacks) do
      schedule(done, prepared, err)
    end
  end

  local function fail(err)
    if job.failed then
      return
    end
    job.failed = true
    finish(nil, err)
  end

  local function maybe_done()
    if job.failed then
      return
    end
    if job.completed < total then
      return
    end
    if job.included < 1 then
      finish(nil, fallback_error("No textual files are available for codediff explorer."))
      return
    end
    if not job.target_included then
      finish(nil, "Selected file is unavailable in codediff PR explorer")
      return
    end

    local prepared = {
      mode = "directory",
      base_dir = base_dir,
      head_dir = head_dir,
      key = dir_key,
      included = job.included,
      entries = job.entries,
      status_result = status_result_from_entries(job.entries),
    }
    temp_state.dir_cache[dir_key] = prepared
    ensure_cleanup_autocmd()
    finish(prepared, nil)
  end

  local pump
  pump = function()
    if job.failed then
      return
    end

    while active < concurrency and index < total do
      index = index + 1
      active = active + 1
      local file = type(files[index]) == "table" and files[index] or {}
      local matches_target = file_matches_candidates(file, target_candidates)
      local scope = pair_scope({
        details = details,
        file = file,
      })
      local cached_pair = temp_state.remote_pair_cache[scope]

      local function handle_pair(data, data_err)
        active = active - 1
        job.completed = job.completed + 1

        if not data then
          if matches_target then
            fail(data_err or "Unable to load commit file content from GitHub")
            return
          end
          notify_progress()
          pump()
          maybe_done()
          return
        end

        temp_state.remote_pair_cache[scope] = data
        local textual_ok, textual_err = ensure_textual_remote_pair(data)
        if not textual_ok then
          if matches_target then
            fail(textual_err)
            return
          end
          notify_progress()
          pump()
          maybe_done()
          return
        end

        local file_mode = safe_string(data.file_mode)
        local include_base = file_mode ~= "added_single"
        local include_head = file_mode ~= "removed_single"
        if file_mode == "" then
          local status = safe_string(data.status)
          include_base = status ~= "added"
          include_head = status ~= "removed"
        end

        if include_base then
          local base_rel = sanitize_relative_path(data.base_path, "base.txt")
          local base_path = joinpath(base_dir, base_rel)
          local _, write_base_err = write_bytes(base_path, safe_string(data.base_content))
          if write_base_err then
            fail(write_base_err)
            return
          end
        end

        if include_head then
          local head_rel = sanitize_relative_path(data.head_path, "head.txt")
          local head_path = joinpath(head_dir, head_rel)
          local _, write_head_err = write_bytes(head_path, safe_string(data.head_content))
          if write_head_err then
            fail(write_head_err)
            return
          end
        end

        job.included = job.included + 1
        local entry = snapshot_entry_from_data(data)
        if entry then
          job.entries[#job.entries + 1] = entry
        end
        if matches_target then
          job.target_included = true
        end

        notify_progress()
        pump()
        maybe_done()
      end

      if type(cached_pair) == "table" then
        vim.schedule(function()
          handle_pair(cached_pair, nil)
        end)
      else
        local ok_async, async_err = pcall(virtual_files.load_remote_file_pair_async, details, file, handle_pair)
        if not ok_async then
          handle_pair(nil, tostring(async_err))
        end
      end
    end
  end

  notify_progress()
  pump()
end

local function resolve_tab_open_result(tabpage)
  if not is_valid_tab(tabpage) then
    return nil
  end

  local ok_lifecycle, lifecycle = pcall(require, "codediff.ui.lifecycle")
  if not ok_lifecycle then
    return nil
  end

  local session = lifecycle.get_session(tabpage)
  if type(session) ~= "table" then
    return nil
  end

  local base_buf = tonumber(session.original_bufnr)
  local head_buf = tonumber(session.modified_bufnr)
  if not is_valid_buf(base_buf) or not is_valid_buf(head_buf) then
    return nil
  end

  return {
    mode = "file",
    tabpage = tabpage,
    base_buf = base_buf,
    head_buf = head_buf,
    base_win = session.original_win,
    head_win = session.modified_win,
    base_path = safe_string(session.original_path),
    head_path = safe_string(session.modified_path),
    layout = session.layout == "inline" and "inline" or "side-by-side",
    diff_result = type(session.stored_diff_result) == "table" and session.stored_diff_result or nil,
  }
end

local function resolve_selected_file_paths(file)
  file = type(file) == "table" and file or {}
  local base_path = sanitize_relative_path(file.previous_filename or file.previousFilename or file.path or file.filename, "")
  local head_path = sanitize_relative_path(file.path or file.filename, "")
  return base_path, head_path
end

local function resolve_selected_relative_path(file)
  file = type(file) == "table" and file or {}
  return sanitize_relative_path(file.path or file.filename, "")
end

local function resolve_selected_file_mode(file)
  local status = safe_string(type(file) == "table" and file.status or ""):lower()
  if status == "added" or status == "a" then
    return "added_single"
  end
  if status == "removed" or status == "d" then
    return "removed_single"
  end
  return "diff_pair"
end

local function build_pending_focus(opts, target_path)
  return {
    target_side = opts.target_side,
    target_line = opts.target_line,
    target_original_line = opts.target_original_line,
    target_path = sanitize_relative_path(target_path, ""),
  }
end

local function consume_pending_focus(session, selected_file)
  local pending_focus = type(session) == "table" and type(session.pending_focus) == "table"
      and vim.deepcopy(session.pending_focus)
    or {}
  session.pending_focus = nil

  if type(selected_file) ~= "table" then
    pending_focus.target_line = nil
    pending_focus.target_original_line = nil
    pending_focus.target_path = nil
    return pending_focus
  end

  local pending_path = sanitize_relative_path(pending_focus.target_path, "")
  if pending_path ~= "" and pending_path ~= resolve_selected_relative_path(selected_file) then
    pending_focus.target_side = nil
    pending_focus.target_line = nil
    pending_focus.target_original_line = nil
  end
  pending_focus.target_path = nil

  return pending_focus
end

local function valid_pr_explorer_session(session)
  if type(session) ~= "table" then
    return false
  end

  if not is_valid_tab(tonumber(session.tabpage)) then
    return false
  end

  if vim.fn.isdirectory(session.base_dir or "") ~= 1 or vim.fn.isdirectory(session.head_dir or "") ~= 1 then
    return false
  end

  return true
end

local function current_pr_explorer_layout(tabpage)
  local ok_lifecycle, lifecycle = pcall(require, "codediff.ui.lifecycle")
  if not ok_lifecycle then
    return nil
  end
  local session = lifecycle.get_session(tabpage)
  if type(session) ~= "table" then
    return nil
  end
  return session.layout == "inline" and "inline" or "side-by-side"
end

local function ensure_pr_explorer_layout(tabpage, layout)
  local desired = normalize_layout(layout)
  local current = current_pr_explorer_layout(tabpage)
  if current == nil or current == desired then
    return true, nil
  end

  local ok_view, view = pcall(require, "codediff.ui.view")
  if not ok_view or type(view.toggle_layout) ~= "function" then
    return nil, "Unable to toggle codediff PR explorer layout"
  end

  local ok_toggle, toggle_err = pcall(view.toggle_layout, tabpage)
  if not ok_toggle then
    return nil, tostring(toggle_err)
  end

  return true, nil
end

local function resolve_explorer_selection(explorer, relative_path)
  explorer = type(explorer) == "table" and explorer or {}
  local path = sanitize_relative_path(relative_path, "")
  local status_result = type(explorer.status_result) == "table" and explorer.status_result or {}

  local groups = {
    { name = "conflicts", items = type(status_result.conflicts) == "table" and status_result.conflicts or {} },
    { name = "unstaged", items = type(status_result.unstaged) == "table" and status_result.unstaged or {} },
    { name = "staged", items = type(status_result.staged) == "table" and status_result.staged or {} },
  }

  for _, group in ipairs(groups) do
    for _, raw in ipairs(group.items) do
      local item = type(raw) == "table" and raw or {}
      if sanitize_relative_path(item.path, "") == path then
        local selection = vim.deepcopy(item)
        selection.group = group.name
        return selection
      end
    end
  end

  return nil
end

local function move_explorer_cursor_to_selection(explorer, selection)
  if type(explorer) ~= "table"
    or type(selection) ~= "table"
    or not is_valid_win(tonumber(explorer.winid))
    or type(explorer.tree) ~= "table"
    or type(explorer.tree.get_node) ~= "function" then
    return
  end

  local line_count = vim.api.nvim_buf_line_count(explorer.bufnr)
  for line = 1, line_count do
    local node = explorer.tree:get_node(line)
    if node
      and type(node.data) == "table"
      and sanitize_relative_path(node.data.path, "") == sanitize_relative_path(selection.path, "")
      and safe_string(node.data.group) == safe_string(selection.group) then
      pcall(vim.api.nvim_win_set_cursor, explorer.winid, { line, 0 })
      break
    end
  end
end

local function clear_pr_explorer_session(key)
  if type(key) == "string" and key ~= "" then
    temp_state.pr_explorer_sessions[key] = nil
  end
end

local function normalize_focus_side(side)
  local value = safe_string(side):lower()
  if value == "base" or value == "left" or value == "original" then
    return "base"
  end
  return "head"
end

local function current_pr_explorer_session(tabpage)
  if not is_valid_tab(tabpage) then
    return nil
  end

  for _, session in pairs(temp_state.pr_explorer_sessions) do
    if valid_pr_explorer_session(session) and tonumber(session.tabpage) == tonumber(tabpage) then
      return session
    end
  end

  return nil
end

local function current_pr_explorer_file_path(open_result)
  open_result = type(open_result) == "table" and open_result or {}

  local function buffer_path(bufnr)
    if not is_valid_buf(bufnr) then
      return ""
    end

    local path = vim.b[bufnr].gh_pr_file_path or vim.b[bufnr].gh_pr_path or ""
    return sanitize_relative_path(path, "")
  end

  local head_path = buffer_path(tonumber(open_result.head_buf))
  if head_path ~= "" then
    return head_path
  end

  local base_path = buffer_path(tonumber(open_result.base_buf))
  if base_path ~= "" then
    return base_path
  end

  head_path = sanitize_relative_path(open_result.head_path, "")
  if head_path ~= "" then
    return head_path
  end

  return sanitize_relative_path(open_result.base_path, "")
end

local function cursor_line_for_window(winid)
  if not is_valid_win(tonumber(winid)) then
    return nil
  end

  local ok, cursor = pcall(vim.api.nvim_win_get_cursor, winid)
  if not ok or type(cursor) ~= "table" then
    return nil
  end

  return positive_integer(cursor[1], nil)
end

local function store_pr_explorer_file_position(session)
  if not valid_pr_explorer_session(session) then
    return
  end

  local open_result = resolve_tab_open_result(session.tabpage)
  if type(open_result) ~= "table" then
    return
  end

  local path = current_pr_explorer_file_path(open_result)
  if path == "" then
    return
  end

  local base_line = cursor_line_for_window(open_result.base_win)
  local head_line = cursor_line_for_window(open_result.head_win)
  if type(base_line) ~= "number" and type(head_line) ~= "number" then
    return
  end

  local target_side = normalize_focus_side(session.last_view_side)
  if target_side == "base" and type(base_line) ~= "number" then
    target_side = "head"
  elseif target_side ~= "base" and type(head_line) ~= "number" and type(base_line) == "number" then
    target_side = "base"
  end

  session.file_positions = type(session.file_positions) == "table" and session.file_positions or {}
  session.file_positions[path] = {
    target_side = target_side,
    target_line = head_line,
    target_original_line = base_line or head_line,
    target_path = path,
  }
end

local function saved_pr_explorer_focus(session, selected_file)
  if type(session) ~= "table" or type(session.file_positions) ~= "table" then
    return nil
  end

  local path = type(selected_file) == "table" and resolve_selected_relative_path(selected_file) or ""
  if path == "" then
    return nil
  end

  local saved = session.file_positions[path]
  if type(saved) ~= "table" then
    return nil
  end

  return vim.deepcopy(saved)
end

local function merge_focus(preferred, fallback)
  local result = vim.deepcopy(type(fallback) == "table" and fallback or {})
  preferred = type(preferred) == "table" and preferred or {}

  for key, value in pairs(preferred) do
    if value ~= nil then
      result[key] = value
    end
  end

  return result
end

local function resolve_pr_explorer_focus(session, selected_file)
  local pending_focus = consume_pending_focus(session, selected_file)
  local saved_focus = saved_pr_explorer_focus(session, selected_file)
  return merge_focus(pending_focus, saved_focus)
end

local function update_pr_explorer_last_view_side(session)
  if not valid_pr_explorer_session(session) then
    return
  end

  local open_result = resolve_tab_open_result(session.tabpage)
  if type(open_result) ~= "table" then
    return
  end

  local current_buf = vim.api.nvim_get_current_buf()
  if tonumber(open_result.base_buf) == tonumber(current_buf) then
    session.last_view_side = "base"
  elseif tonumber(open_result.head_buf) == tonumber(current_buf) then
    session.last_view_side = "head"
  end
end

local function ensure_pr_explorer_tracking_autocmd()
  if temp_state.pr_explorer_tracking_attached then
    return
  end

  temp_state.pr_explorer_tracking_attached = true
  local group = vim.api.nvim_create_augroup("GhPrCodediffPrExplorerTracking", { clear = true })
  vim.api.nvim_create_autocmd({ "BufEnter", "BufWinEnter", "WinEnter", "TabEnter" }, {
    group = group,
    desc = "gh-pr: track last focused PR codediff side",
    callback = function()
      local session = current_pr_explorer_session(vim.api.nvim_get_current_tabpage())
      if session then
        update_pr_explorer_last_view_side(session)
      end
    end,
  })
end

local function is_passive_pr_explorer_selection(opts)
  opts = type(opts) == "table" and opts or {}
  return opts.no_jump == true or opts.passive == true
end

local function sync_pr_explorer_selection(session, selected_file, version, attempt)
  session = type(session) == "table" and session or {}
  attempt = tonumber(attempt) or 0

  if not valid_pr_explorer_session(session) then
    clear_pr_explorer_session(session.key)
    return
  end

  if tonumber(session.selection_version) ~= tonumber(version) then
    return
  end

  local open_result = resolve_tab_open_result(session.tabpage)
  if type(open_result) ~= "table" then
    if attempt >= 8 then
      return
    end
    vim.schedule(function()
      sync_pr_explorer_selection(session, selected_file, version, attempt + 1)
    end)
    return
  end

  if type(selected_file) == "table" then
    local base_path, head_path = resolve_selected_file_paths(selected_file)
    open_result.base_path = base_path
    open_result.head_path = head_path
    open_result.file_mode = resolve_selected_file_mode(selected_file)
  end

  apply_readonly_lock_to_tab(session.tabpage)
  M.focus_side_and_line(open_result, resolve_pr_explorer_focus(session, selected_file))

  if type(session.on_selection) == "function" and type(selected_file) == "table" then
    session.on_selection(selected_file, open_result)
  end
end

local function added_pr_explorer_file_path(session, file_data)
  if type(session) ~= "table" or type(file_data) ~= "table" then
    return nil
  end

  local relative_path = resolve_selected_relative_path(file_data)
  if relative_path == "" then
    return nil
  end

  local head_path = joinpath(session.head_dir or "", relative_path)
  if file_readable(head_path) then
    return head_path
  end

  return nil
end

local function should_use_added_single_file_view(file_data)
  local status = safe_string(type(file_data) == "table" and file_data.status or ""):lower()
  return status == "a" or status == "added"
end

local function show_pr_explorer_added_single_file(session, file_data)
  local head_path = added_pr_explorer_file_path(session, file_data)
  if not head_path then
    return false
  end

  local layout = current_pr_explorer_layout(session.tabpage)
  if layout == "inline" then
    local ok_inline, inline_view = pcall(require, "codediff.ui.view.inline_view")
    if not ok_inline or type(inline_view.show_single_file) ~= "function" then
      return false
    end
    inline_view.show_single_file(session.tabpage, head_path, {
      side = "modified",
    })
  else
    local ok_side, side_by_side = pcall(require, "codediff.ui.view.side_by_side")
    if not ok_side or type(side_by_side.show_untracked_file) ~= "function" then
      return false
    end
    side_by_side.show_untracked_file(session.tabpage, head_path)
  end

  apply_readonly_lock_to_tab(session.tabpage)
  return true
end

local function attach_pr_explorer_hooks(session)
  if not valid_pr_explorer_session(session) then
    return nil, "Unable to attach codediff PR explorer hooks"
  end

  local ok_lifecycle, lifecycle = pcall(require, "codediff.ui.lifecycle")
  if not ok_lifecycle or type(lifecycle.get_explorer) ~= "function" then
    return nil, "codediff explorer lifecycle is unavailable"
  end

  local explorer = lifecycle.get_explorer(session.tabpage)
  if type(explorer) ~= "table" or type(explorer.on_file_select) ~= "function" then
    return nil, "Unable to resolve codediff explorer session"
  end

  if explorer._gh_pr_session_key == session.key then
    session.explorer = explorer
    return true, nil
  end

  local original_on_file_select = explorer.on_file_select
  explorer.on_file_select = function(file_data, opts)
    opts = type(opts) == "table" and opts or {}

    if session.suppress_next_auto_select == true then
      session.suppress_next_auto_select = nil
      return
    end

    if is_passive_pr_explorer_selection(opts) then
      original_on_file_select(file_data, opts)
      return
    end

    store_pr_explorer_file_position(session)

    local selected_file = resolve_lookup_file(session.file_lookup, file_data)
    local version = (tonumber(session.selection_version) or 0) + 1
    session.selection_version = version

    original_on_file_select(file_data, opts)

    if should_use_added_single_file_view(file_data) then
      vim.schedule(function()
        if valid_pr_explorer_session(session) then
          show_pr_explorer_added_single_file(session, file_data)
        end
      end)
    end

    vim.schedule(function()
      sync_pr_explorer_selection(session, selected_file, version, 0)
    end)
  end
  explorer._gh_pr_session_key = session.key
  session.explorer = explorer
  return true, nil
end

local function create_pr_explorer_session(opts)
  opts = type(opts) == "table" and opts or {}
  local prepared, prepare_err = prepare_directory_snapshot({
    details = opts.details,
    files = opts.files,
    cache_scope = opts.cache_scope,
    target_path = opts.target_path,
    only_if_cached = opts.only_if_cached == true,
  })
  if not prepared then
    return nil, nil, prepare_err
  end

  local ok_view, view = pcall(require, "codediff.ui.view")
  if not ok_view or type(view.create) ~= "function" then
    return nil, nil, "codediff explorer internals are unavailable"
  end

  local status_result = type(prepared.status_result) == "table" and prepared.status_result or nil
  local root1 = prepared.base_dir
  local root2 = prepared.head_dir
  if type(status_result) ~= "table" then
    local ok_dir, dir_mod = pcall(require, "codediff.core.dir")
    if not ok_dir or type(dir_mod.diff_directories) ~= "function" then
      return nil, nil, "codediff explorer internals are unavailable"
    end
    local diff = dir_mod.diff_directories(prepared.base_dir, prepared.head_dir)
    status_result = type(diff) == "table" and type(diff.status_result) == "table" and diff.status_result or nil
    root1 = type(diff) == "table" and diff.root1 or prepared.base_dir
    root2 = type(diff) == "table" and diff.root2 or prepared.head_dir
  end
  if type(status_result) ~= "table" then
    return nil, nil, "Unable to build codediff PR explorer snapshot"
  end
  if #status_result.unstaged < 1 and #status_result.staged < 1 and #(status_result.conflicts or {}) < 1 then
    return nil, nil, "No textual changes are available in the codediff PR explorer snapshot"
  end

  local focus_file = sanitize_relative_path(opts.target_path, "")
  local session_config = {
    mode = "explorer",
    git_root = nil,
    original_path = root1,
    modified_path = root2,
    original_revision = nil,
    modified_revision = nil,
    layout = normalize_layout(opts.layout),
    explorer_data = {
      status_result = status_result,
      focus_file = focus_file ~= "" and focus_file or nil,
    },
  }

  view.create(session_config, "")
  local tabpage = vim.api.nvim_get_current_tabpage()

  local session = {
    key = opts.session_key,
    tabpage = tabpage,
    base_dir = prepared.base_dir,
    head_dir = prepared.head_dir,
    file_lookup = build_pr_file_lookup(opts.details),
    on_selection = opts.on_selection,
    pending_focus = build_pending_focus(opts, focus_file),
    file_positions = {},
    last_view_side = normalize_focus_side(opts.target_side),
    suppress_next_auto_select = true,
    selection_version = 0,
  }
  temp_state.pr_explorer_sessions[opts.session_key] = session

  ensure_pr_explorer_tracking_autocmd()
  local attached, attach_err = attach_pr_explorer_hooks(session)
  if not attached then
    clear_pr_explorer_session(opts.session_key)
    return nil, nil, attach_err
  end

  apply_readonly_lock_to_tab(tabpage)

  return session, {
    mode = "directory",
    tabpage = tabpage,
    base_dir = prepared.base_dir,
    head_dir = prepared.head_dir,
    layout = normalize_layout(opts.layout),
  }, nil
end

local function create_pr_explorer_session_from_prepared(opts, prepared)
  opts = type(opts) == "table" and opts or {}
  if type(prepared) ~= "table" then
    return nil, nil, "Unable to build codediff PR explorer snapshot"
  end

  temp_state.dir_cache[prepared.key] = prepared
  return create_pr_explorer_session(vim.tbl_extend("force", opts, {
    only_if_cached = true,
  }))
end

local function create_pr_explorer_session_async(opts, progress, callback)
  if type(progress) == "function" and type(callback) ~= "function" then
    callback = progress
    progress = nil
  end
  callback = callback or function() end
  opts = type(opts) == "table" and opts or {}
  prepare_directory_snapshot_async({
    details = opts.details,
    files = opts.files,
    cache_scope = opts.cache_scope,
    target_path = opts.target_path,
  }, progress, function(prepared, prepare_err)
    if not prepared then
      callback(nil, nil, prepare_err)
      return
    end

    local session, opened, open_err = create_pr_explorer_session_from_prepared(opts, prepared)
    callback(session, opened, open_err)
  end)
end

local function resolve_focus_line(opts, side)
  if side == "base" then
    return positive_integer(opts.target_original_line, positive_integer(opts.target_line, nil))
  end
  return positive_integer(opts.target_line, positive_integer(opts.target_original_line, nil))
end

function M.focus_side_and_line(opened, opts)
  opened = type(opened) == "table" and opened or {}
  opts = type(opts) == "table" and opts or {}

  local side = safe_string(opts.target_side):lower()
  if side ~= "base" and side ~= "head" then
    side = "head"
  end

  local winid = side == "base" and tonumber(opened.base_win) or tonumber(opened.head_win)
  if not winid or winid < 1 or not vim.api.nvim_win_is_valid(winid) then
    local bufnr = side == "base" and tonumber(opened.base_buf) or tonumber(opened.head_buf)
    if bufnr and bufnr > 0 then
      local candidate = vim.fn.bufwinid(bufnr)
      if type(candidate) == "number" and candidate > 0 and vim.api.nvim_win_is_valid(candidate) then
        winid = candidate
      end
    end
  end

  if not winid or winid < 1 or not vim.api.nvim_win_is_valid(winid) then
    return nil, "Unable to focus codediff window"
  end

  local target_line = resolve_focus_line(opts, side)
  pcall(vim.api.nvim_set_current_win, winid)
  if type(target_line) == "number" and target_line > 0 then
    local bufnr = vim.api.nvim_win_get_buf(winid)
    local max_line = vim.api.nvim_buf_line_count(bufnr)
    local line = math.max(1, math.min(max_line, target_line))
    pcall(vim.api.nvim_win_set_cursor, winid, { line, 0 })
  end

  return true, nil
end

local function open_prepared_file_diff(opts, prepared)
  opts = type(opts) == "table" and opts or {}
  prepared = type(prepared) == "table" and prepared or {}

  local head_open_path = prepared.head_temp_path
  local local_head_path = safe_string(opts.local_head_path)
  if local_head_path ~= "" and safe_string(prepared.data.file_mode) ~= "removed_single" then
    local absolute_local_head = vim.fn.fnamemodify(local_head_path, ":p")
    if absolute_local_head ~= "" and (vim.fn.filereadable(absolute_local_head) == 1 or vim.fn.bufexists(absolute_local_head) == 1) then
      head_open_path = absolute_local_head
      local_head_path = absolute_local_head
    else
      local_head_path = ""
    end
  else
    local_head_path = ""
  end

  local layout = normalize_layout(opts.layout)
  local layout_flag = "--side-by-side"
  if layout == "inline" then
    layout_flag = "--inline"
  end

  apply_codediff_preferences({
    layout = layout,
    ignore_trim_whitespace = opts.ignore_trim_whitespace == true,
  })

  local command = string.format(
    "CodeDiff file %s %s %s",
    vim.fn.fnameescape(prepared.base_temp_path),
    vim.fn.fnameescape(head_open_path),
    layout_flag
  )
  local ok_open, open_err = run_codediff_command(command)
  if not ok_open then
    return nil, open_err
  end

  local opened, resolve_err = resolve_file_open_result(prepared.base_temp_path, head_open_path)
  if not opened then
    return nil, resolve_err
  end

  apply_codediff_readonly_lock(opened.base_buf)
  apply_codediff_readonly_lock(opened.head_buf)
  apply_readonly_lock_to_tab(opened.tabpage)

  opened.file_mode = safe_string(prepared.data.file_mode)
  opened.status = safe_string(prepared.data.status)
  opened.base_path = safe_string(prepared.data.base_path)
  opened.head_path = safe_string(prepared.data.head_path)
  opened.layout = layout
  opened.source_name = safe_string(opts.source_name)
  opened.local_head_path = local_head_path ~= "" and local_head_path or nil

  M.focus_side_and_line(opened, opts)
  return opened, nil
end

function M.open_pr_file_diff(opts)
  opts = type(opts) == "table" and opts or {}
  local guard_ok, guard_err = ensure_readonly_guard_autocmd()
  if not guard_ok and guard_err then
    return nil, guard_err
  end

  local prepared, prepare_err = prepare_pair_from_remote(opts)
  if not prepared then
    return nil, prepare_err
  end

  return open_prepared_file_diff(opts, prepared)
end

function M.open_pr_file_diff_async(opts, callback)
  callback = callback or function() end
  opts = type(opts) == "table" and opts or {}
  local guard_ok, guard_err = ensure_readonly_guard_autocmd()
  if not guard_ok and guard_err then
    schedule(callback, nil, guard_err)
    return
  end

  prepare_pair_from_remote_async(opts, function(prepared, prepare_err)
    if not prepared then
      callback(nil, prepare_err)
      return
    end

    local opened, open_err = open_prepared_file_diff(opts, prepared)
    callback(opened, open_err)
  end)
end

function M.open_pr_explorer_diff(opts)
  opts = type(opts) == "table" and opts or {}
  local details = type(opts.details) == "table" and opts.details or nil
  local file = type(opts.file) == "table" and opts.file or nil
  if not details or not file then
    return nil, "Missing details/file payload for codediff PR explorer"
  end

  local guard_ok, guard_err = ensure_readonly_guard_autocmd()
  if not guard_ok and guard_err then
    return nil, guard_err
  end
  if not ensure_codediff_command() then
    return nil, "codediff.nvim is unavailable (`:CodeDiff` not found)"
  end

  local focus_path = sanitize_relative_path(file.path or file.filename, "")
  if focus_path == "" then
    return nil, "Unable to resolve selected path for codediff PR explorer"
  end

  apply_codediff_preferences({
    layout = opts.layout,
    ignore_trim_whitespace = opts.ignore_trim_whitespace == true,
  })

  local session_key = pr_explorer_session_key({
    details = details,
    pr_number = opts.pr_number,
  })
  local session = temp_state.pr_explorer_sessions[session_key]
  if not valid_pr_explorer_session(session) then
    clear_pr_explorer_session(session_key)
    session = nil
  end

  if session and opts.reuse ~= false then
    store_pr_explorer_file_position(session)
    session.file_lookup = build_pr_file_lookup(details)
    session.on_selection = opts.on_selection
    session.pending_focus = build_pending_focus(opts, focus_path)

    ensure_pr_explorer_tracking_autocmd()
    local attached, attach_err = attach_pr_explorer_hooks(session)
    if not attached then
      clear_pr_explorer_session(session_key)
      return nil, attach_err
    end

    pcall(vim.api.nvim_set_current_tabpage, session.tabpage)
    local layout_ok, layout_err = ensure_pr_explorer_layout(session.tabpage, opts.layout)
    if not layout_ok then
      return nil, layout_err
    end

    local selection = resolve_explorer_selection(session.explorer, focus_path)
    if not selection then
      return nil, "Unable to resolve selected file inside codediff PR explorer"
    end

    move_explorer_cursor_to_selection(session.explorer, selection)

    return {
      mode = "directory",
      tabpage = session.tabpage,
      base_dir = session.base_dir,
      head_dir = session.head_dir,
      layout = current_pr_explorer_layout(session.tabpage) or normalize_layout(opts.layout),
    }, nil
  end

  local _, opened, open_err = create_pr_explorer_session({
    session_key = session_key,
    details = details,
    files = type(opts.files) == "table" and opts.files or details.files,
    target_path = focus_path,
    layout = opts.layout,
    target_side = opts.target_side,
    target_line = opts.target_line,
    target_original_line = opts.target_original_line,
    on_selection = opts.on_selection,
    cache_scope = table.concat({
      session_key,
      safe_string(details.baseRefName),
      safe_string(details.headRefName),
    }, "|"),
    only_if_cached = opts.only_if_cached == true,
  })
  if not opened then
    return nil, open_err
  end

  return opened, nil
end

function M.open_pr_explorer_diff_async(opts, callback)
  callback = callback or function() end
  opts = type(opts) == "table" and opts or {}
  local details = type(opts.details) == "table" and opts.details or nil
  local file = type(opts.file) == "table" and opts.file or nil
  if not details or not file then
    schedule(callback, nil, "Missing details/file payload for codediff PR explorer")
    return
  end

  local guard_ok, guard_err = ensure_readonly_guard_autocmd()
  if not guard_ok and guard_err then
    schedule(callback, nil, guard_err)
    return
  end
  if not ensure_codediff_command() then
    schedule(callback, nil, "codediff.nvim is unavailable (`:CodeDiff` not found)")
    return
  end

  local focus_path = sanitize_relative_path(file.path or file.filename, "")
  if focus_path == "" then
    schedule(callback, nil, "Unable to resolve selected path for codediff PR explorer")
    return
  end

  local opened_ready, ready_err = M.open_pr_explorer_diff(vim.tbl_extend("force", opts, {
    only_if_cached = true,
  }))
  if opened_ready then
    schedule(callback, opened_ready, nil)
    return
  end

  apply_codediff_preferences({
    layout = opts.layout,
    ignore_trim_whitespace = opts.ignore_trim_whitespace == true,
  })

  local session_key = pr_explorer_session_key({
    details = details,
    pr_number = opts.pr_number,
  })
  create_pr_explorer_session_async({
    session_key = session_key,
    details = details,
    files = type(opts.files) == "table" and opts.files or details.files,
    target_path = focus_path,
    layout = opts.layout,
    target_side = opts.target_side,
    target_line = opts.target_line,
    target_original_line = opts.target_original_line,
    on_selection = opts.on_selection,
    cache_scope = table.concat({
      session_key,
      safe_string(details.baseRefName),
      safe_string(details.headRefName),
    }, "|"),
  }, opts.progress, function(_, opened, open_err)
    callback(opened, open_err or ready_err)
  end)
end

function M.prepare_directory_snapshot_async(opts, progress, callback)
  return prepare_directory_snapshot_async(opts, progress, callback)
end

function M.prefetch_pr_explorer_snapshot(opts, callback)
  callback = callback or function() end
  opts = type(opts) == "table" and opts or {}
  local details = type(opts.details) == "table" and opts.details or nil
  local file = type(opts.file) == "table" and opts.file or nil
  if not details or not file then
    schedule(callback, nil, "Missing details/file payload for codediff PR explorer")
    return
  end

  local focus_path = sanitize_relative_path(file.path or file.filename, "")
  local session_key = pr_explorer_session_key({
    details = details,
    pr_number = opts.pr_number,
  })
  local progress = start_progress_notifier(#(type(opts.files) == "table" and opts.files or details.files or {}))
  prepare_directory_snapshot_async({
    details = details,
    files = type(opts.files) == "table" and opts.files or details.files,
    cache_scope = table.concat({
      session_key,
      safe_string(details.baseRefName),
      safe_string(details.headRefName),
    }, "|"),
    target_path = focus_path,
  }, function(state)
    progress.update(state.completed, state.total)
  end, function(prepared, err)
    if prepared then
      progress.finish(
        string.format("gh-pr: codediff PR explorer snapshot ready (%d files)", tonumber(prepared.included) or 0),
        vim.log.levels.INFO
      )
    else
      progress.finish("gh-pr: unable to prepare codediff PR explorer snapshot: " .. tostring(err), vim.log.levels.WARN)
    end
    callback(prepared, err)
  end)
end

function M.prefetch_pr_file_pair(opts, callback)
  callback = callback or function() end
  prepare_pair_from_remote_async(opts, callback)
end

function M.open_commit_diff(opts)
  opts = type(opts) == "table" and opts or {}

  if type(opts.file) == "table" then
    return M.open_pr_file_diff({
      details = opts.details,
      file = opts.file,
      cache_scope = opts.cache_scope,
      layout = opts.layout,
      ignore_trim_whitespace = opts.ignore_trim_whitespace,
      target_side = opts.target_side,
      target_line = opts.target_line,
      target_original_line = opts.target_original_line,
    })
  end

  local prepared, prepare_err = prepare_directory_snapshot({
    details = opts.details,
    files = opts.files,
    cache_scope = opts.cache_scope,
  })
  if not prepared then
    return nil, prepare_err
  end

  local guard_ok, guard_err = ensure_readonly_guard_autocmd()
  if not guard_ok and guard_err then
    return nil, guard_err
  end

  apply_codediff_preferences({
    layout = "side-by-side",
    ignore_trim_whitespace = opts.ignore_trim_whitespace == true,
  })

  local command = string.format(
    "CodeDiff dir %s %s --side-by-side",
    vim.fn.fnameescape(prepared.base_dir),
    vim.fn.fnameescape(prepared.head_dir)
  )
  local ok_open, open_err = run_codediff_command(command)
  if not ok_open then
    return nil, open_err
  end

  local tabpage = vim.api.nvim_get_current_tabpage()
  apply_readonly_lock_to_tab(tabpage)

  return {
    mode = "directory",
    tabpage = tabpage,
    base_dir = prepared.base_dir,
    head_dir = prepared.head_dir,
  }, nil
end

function M.open_compare_diff(opts)
  return M.open_commit_diff(opts)
end

M._temp_buffer_helpers = {
  is_codediff_temp_buffer = is_codediff_temp_buffer,
  mark_codediff_temp_buffer = mark_codediff_temp_buffer,
}

return M
