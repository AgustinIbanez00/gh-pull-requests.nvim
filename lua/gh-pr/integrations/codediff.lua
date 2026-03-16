local M = {}

local uv = vim.uv or vim.loop

local virtual_files = require("gh-pr.virtual_files")

local temp_state = {
  root = nil,
  file_cache = {},
  dir_cache = {},
  cleanup_attached = false,
  readonly_guard_attached = false,
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

local function apply_codediff_readonly_lock(bufnr)
  local is_temp = is_codediff_temp_buffer(bufnr)
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
    return nil, "codediff.nvim is unavailable (`:CodeDiff` not found)"
  end

  local ok, cmd_err = pcall(vim.cmd, command)
  if not ok then
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

local function resolve_file_open_result(base_temp_path, head_temp_path)
  local base_buf = find_buffer_for_path(base_temp_path)
  local head_buf = find_buffer_for_path(head_temp_path)
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
    base_temp_path = base_temp_path,
    head_temp_path = head_temp_path,
  }, nil
end

local function fallback_error(message)
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

  local owner = safe_string(repository.owner)
  local name = safe_string(repository.name)
  if owner ~= "" and name ~= "" then
    return owner .. "/" .. name
  end

  return ""
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

  local data, data_err = virtual_files.load_remote_file_pair(details, file)
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

  virtual_files.load_remote_file_pair_async(details, file, function(data, data_err)
    if not data then
      callback(nil, data_err or "Unable to load file content from GitHub")
      return
    end

    callback(prepare_pair_from_data(opts, data))
  end)
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

  local signature = { pair_scope(opts), "directory" }
  for _, raw in ipairs(files) do
    local file = type(raw) == "table" and raw or {}
    signature[#signature + 1] = table.concat({
      safe_string(file.path ~= "" and file.path or file.filename),
      safe_string(file.previous_filename ~= "" and file.previous_filename or file.previousFilename),
      safe_string(file.status),
      safe_string(file.patch),
    }, ":")
  end
  local dir_key = sha256(table.concat(signature, "|"))

  local cached = temp_state.dir_cache[dir_key]
  if type(cached) == "table"
    and vim.fn.isdirectory(cached.base_dir or "") == 1
    and vim.fn.isdirectory(cached.head_dir or "") == 1 then
    return cached, nil
  end

  local base_dir = joinpath(root, "dirs", dir_key, "base")
  local head_dir = joinpath(root, "dirs", dir_key, "head")
  if not ensure_dir(base_dir) or not ensure_dir(head_dir) then
    return nil, "Unable to prepare codediff temporary directories"
  end

  for _, raw in ipairs(files) do
    local file = type(raw) == "table" and raw or {}
    local data, data_err = virtual_files.load_remote_file_pair(details, file)
    if not data then
      return nil, data_err or "Unable to load commit file content from GitHub"
    end

    local textual_ok, textual_err = ensure_textual_remote_pair(data)
    if not textual_ok then
      return nil, textual_err
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
  end

  local prepared = {
    mode = "directory",
    base_dir = base_dir,
    head_dir = head_dir,
    key = dir_key,
  }
  temp_state.dir_cache[dir_key] = prepared
  ensure_cleanup_autocmd()
  return prepared, nil
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
    vim.fn.fnameescape(prepared.head_temp_path),
    layout_flag
  )
  local ok_open, open_err = run_codediff_command(command)
  if not ok_open then
    return nil, open_err
  end

  local opened, resolve_err = resolve_file_open_result(prepared.base_temp_path, prepared.head_temp_path)
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

  M.focus_side_and_line(opened, opts)
  return opened, nil
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

return M
