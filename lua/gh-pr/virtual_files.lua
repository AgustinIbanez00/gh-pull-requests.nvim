local M = {}

local config = require("gh-pr.config")
local diff_shortcuts_config = require("gh-pr.diff_shortcuts")
local gh = require("gh-pr.gh")
local image_renderer = require("gh-pr.image_renderer")
local line_comments = require("gh-pr.line_comments")
local state = require("gh-pr.state")

local base64_chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local extmark_namespaces = {
  unified_highlight = vim.api.nvim_create_namespace("gh-pr-unified-diff"),
  unified_syntax = vim.api.nvim_create_namespace("gh-pr-unified-syntax"),
  endline = vim.api.nvim_create_namespace("gh-pr-endline-render"),
  whitespace = vim.api.nvim_create_namespace("gh-pr-whitespace-render"),
}
local unified_highlight_ns = extmark_namespaces.unified_highlight
local unified_syntax_ns = extmark_namespaces.unified_syntax
local endline_render_ns = extmark_namespaces.endline
local whitespace_render_ns = extmark_namespaces.whitespace

local function clear_extmark_namespaces(bufnr, namespace_keys)
  if type(bufnr) ~= "number" or bufnr < 1 or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  local keys = type(namespace_keys) == "table"
      and namespace_keys
    or { "unified_highlight", "unified_syntax", "endline", "whitespace" }

  for _, key in ipairs(keys) do
    local namespace = extmark_namespaces[key]
    if type(namespace) == "number" then
      pcall(vim.api.nvim_buf_clear_namespace, bufnr, namespace, 0, -1)
    end
  end
end

local function ensure_virtual_buffer_cleanup(bufnr)
  if type(bufnr) ~= "number" or bufnr < 1 or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  if vim.b[bufnr].gh_pr_virtual_cleanup_attached == true then
    return
  end
  vim.b[bufnr].gh_pr_virtual_cleanup_attached = true

  vim.api.nvim_create_autocmd({ "BufWipeout", "BufUnload" }, {
    buffer = bufnr,
    callback = function()
      image_renderer.clear(bufnr)
      clear_extmark_namespaces(bufnr)
    end,
  })
end

local function decode_base64_fallback(data)
  data = data:gsub("[^" .. base64_chars .. "=]", "")

  return (data:gsub(".", function(char)
    if char == "=" then
      return ""
    end

    local index = base64_chars:find(char, 1, true)
    if not index then
      return ""
    end

    local bits = ""
    local value = index - 1
    for bit = 6, 1, -1 do
      if value % (2 ^ bit) - value % (2 ^ (bit - 1)) > 0 then
        bits = bits .. "1"
      else
        bits = bits .. "0"
      end
    end

    return bits
  end):gsub("%d%d%d?%d?%d?%d?%d?%d?", function(byte)
    if #byte ~= 8 then
      return ""
    end

    local value = 0
    for bit = 1, 8 do
      if byte:sub(bit, bit) == "1" then
        value = value + 2 ^ (8 - bit)
      end
    end

    return string.char(value)
  end))
end

local function decode_base64(data)
  if not data or data == "" then
    return ""
  end

  local normalized = data:gsub("\n", "")

  if vim.base64 and vim.base64.decode then
    local ok, decoded = pcall(vim.base64.decode, normalized)
    if ok then
      return decoded
    end
  end

  return decode_base64_fallback(normalized)
end

local function url_encode_segment(segment)
  local encoded = segment:gsub("([^%w%-_%.~])", function(char)
    return string.format("%%%02X", string.byte(char))
  end)
  return encoded
end

local function url_encode(text)
  local encoded = text:gsub("([^%w%-_%.~])", function(char)
    return string.format("%%%02X", string.byte(char))
  end)
  return encoded
end

local function encode_path(path)
  local parts = {}
  for part in path:gmatch("[^/]+") do
    table.insert(parts, url_encode_segment(part))
  end
  return table.concat(parts, "/")
end

local function extract_repo(repo)
  if type(repo) ~= "table" then
    return nil
  end

  local parsed_owner, parsed_name
  if type(repo.nameWithOwner) == "string" then
    parsed_owner, parsed_name = repo.nameWithOwner:match("^([^/]+)/(.+)$")
  end

  local owner
  if type(repo.owner) == "table" then
    owner = repo.owner.login or repo.owner.name
  else
    owner = repo.owner
  end
  owner = owner or parsed_owner

  local name = repo.name or parsed_name
  if type(owner) ~= "string" or owner == "" or type(name) ~= "string" or name == "" then
    return nil
  end

  return {
    owner = owner,
    name = name,
    full_name = repo.nameWithOwner or (owner .. "/" .. name),
  }
end

local function resolve_base_repository(details)
  return extract_repo(details.baseRepository) or extract_repo(details.headRepository)
end

local function resolve_head_repository(details, base_repository)
  return extract_repo(details.headRepository) or base_repository
end

local function resolve_image_options()
  local diff_view = (config.get() or {}).diff_view or {}
  local images = type(diff_view.images) == "table" and diff_view.images or {}
  local formats = {}
  for _, ext in ipairs(type(images.formats) == "table" and images.formats or {}) do
    if type(ext) == "string" and ext ~= "" then
      formats[#formats + 1] = ext:lower():gsub("^%.+", "")
    end
  end
  if vim.tbl_isempty(formats) then
    formats = { "png", "jpg", "jpeg", "gif", "webp", "bmp", "svg" }
  end

  local max_bytes = tonumber(images.max_bytes)
  if type(max_bytes) ~= "number" or max_bytes < 1 then
    max_bytes = 26214400
  end

  local external_command = {}
  for _, token in ipairs(type(images.metadata_external_command) == "table" and images.metadata_external_command or {}) do
    if type(token) == "string" and token ~= "" then
      external_command[#external_command + 1] = token
    end
  end
  if vim.tbl_isempty(external_command) then
    external_command = { "magick", "identify", "-format", "%w %h", "{file}" }
  end

  local fallback_open_local = type(images.fallback_open_local) == "string" and images.fallback_open_local:lower()
    or "disabled"
  if fallback_open_local ~= "disabled" and fallback_open_local ~= "reveal_only" and fallback_open_local ~= "system" then
    fallback_open_local = "disabled"
  end

  return {
    enabled = images.enabled ~= false,
    backend = type(images.backend) == "string" and images.backend:lower() or "snacks",
    formats = formats,
    cache_dir = type(images.cache_dir) == "string" and images.cache_dir ~= "" and images.cache_dir or nil,
    fallback = type(images.fallback) == "string" and images.fallback:lower() or "placeholder",
    fallback_mode = type(images.fallback_mode) == "string" and images.fallback_mode:lower() or "menu",
    fallback_default_action = type(images.fallback_default_action) == "string"
        and images.fallback_default_action:lower()
      or "metadata",
    fallback_menu_keymap = type(images.fallback_menu_keymap) == "string" and images.fallback_menu_keymap or "gf",
    fallback_open_local = fallback_open_local,
    fallback_github_target = type(images.fallback_github_target) == "string"
        and images.fallback_github_target:lower()
      or "pr_files",
    show_metadata = images.show_metadata ~= false,
    metadata_resolution_strategy = type(images.metadata_resolution_strategy) == "string"
        and images.metadata_resolution_strategy:lower()
      or "hybrid",
    metadata_external_command = external_command,
    max_bytes = math.floor(max_bytes),
  }
end

local function resolve_non_text_options()
  local diff_view = (config.get() or {}).diff_view or {}
  local non_text = type(diff_view.non_text) == "table" and diff_view.non_text or {}
  return {
    enabled = non_text.enabled ~= false,
    auto_preview = non_text.auto_preview ~= false,
    show_metadata = non_text.show_metadata ~= false,
  }
end

local function resolve_text_extension_set()
  local diff_view = (config.get() or {}).diff_view or {}
  local prefetch = type(diff_view.prefetch) == "table" and diff_view.prefetch or {}
  local set = {}
  for _, ext in ipairs(type(prefetch.text_extensions) == "table" and prefetch.text_extensions or {}) do
    if type(ext) == "string" and ext ~= "" then
      set[ext:lower():gsub("^%.+", "")] = true
    end
  end
  return set
end

local function normalize_asset_path(path)
  if type(path) ~= "string" then
    return ""
  end
  return path:gsub("\\", "/")
end

local function path_extension(path)
  return image_renderer.extension(normalize_asset_path(path))
end

local function file_patch_available(file)
  return type(file) == "table" and type(file.patch) == "string" and file.patch ~= ""
end

local function looks_like_binary_bytes(bytes)
  if type(bytes) ~= "string" or bytes == "" then
    return false
  end
  if bytes:find("\0", 1, true) then
    return true
  end

  local sample = bytes:sub(1, 4096)
  local invalid = 0
  for index = 1, #sample do
    local byte = sample:byte(index)
    if byte < 9 or (byte > 13 and byte < 32) then
      invalid = invalid + 1
    end
  end

  return invalid > 0 and (invalid / #sample) > 0.12
end

local function resolve_file_path(file)
  if type(file) ~= "table" then
    return ""
  end
  return normalize_asset_path(file.path or file.filename or "")
end

local function classify_file(file, opts)
  opts = type(opts) == "table" and opts or {}
  local path = resolve_file_path(file)
  if path == "" then
    return "text"
  end

  local image_options = type(opts.image_options) == "table" and opts.image_options or resolve_image_options()
  if image_renderer.is_image_path(path, image_options.formats) then
    return "image"
  end

  if file_patch_available(file) then
    return "text"
  end

  local ext = path_extension(path)
  local text_extensions = type(opts.text_extensions) == "table" and opts.text_extensions or resolve_text_extension_set()
  if ext ~= "" and text_extensions[ext] == true then
    return "text"
  end

  local asset = type(opts.asset) == "table" and opts.asset or nil
  if asset and asset.is_binary == true then
    return "asset"
  end
  if asset and looks_like_binary_bytes(asset.bytes) then
    return "asset"
  end

  return "asset"
end

M.classify_file = classify_file

local function empty_asset(path)
  return {
    path = normalize_asset_path(path),
    ext = image_renderer.extension(normalize_asset_path(path)),
    size = 0,
    sha = "",
    encoding = "",
    is_image = false,
    is_binary = false,
    bytes = "",
    text = "",
    skipped = false,
  }
end

local function asset_from_payload(path, payload, image_options)
  local size = tonumber(payload.size) or 0
  local normalized_path = normalize_asset_path(path)
  local ext = image_renderer.extension(normalized_path)
  local is_image = image_renderer.is_image_path(normalized_path, image_options and image_options.formats or nil)

  if payload.encoding ~= "base64" then
    return {
      path = normalized_path,
      ext = ext,
      size = size,
      sha = type(payload.sha) == "string" and payload.sha or "",
      encoding = type(payload.encoding) == "string" and payload.encoding or "",
      is_image = is_image,
      is_binary = is_image ~= true,
      bytes = "",
      text = "",
      skipped = false,
    }, nil
  end

  if is_image and image_options and tonumber(image_options.max_bytes) and size > image_options.max_bytes then
    return {
      path = normalized_path,
      ext = ext,
      size = size,
      sha = type(payload.sha) == "string" and payload.sha or "",
      encoding = payload.encoding,
      is_image = true,
      is_binary = false,
      bytes = "",
      text = "",
      skipped = true,
      skip_reason = "image exceeds configured max_bytes",
    }, nil
  end

  local decoded = decode_base64(payload.content)
  local is_binary = (not is_image) and looks_like_binary_bytes(decoded)
  return {
    path = normalized_path,
    ext = ext,
    size = size > 0 and size or #decoded,
    sha = type(payload.sha) == "string" and payload.sha or "",
    encoding = payload.encoding,
    is_image = is_image,
    is_binary = is_binary,
    bytes = decoded,
    text = is_binary and "" or decoded,
    skipped = false,
  }, nil
end

local function fetch_asset(repository, ref, path, image_options)
  if not repository or not ref or not path then
    return nil, "Missing repository/ref/path to fetch content"
  end

  local api = string.format(
    "repos/%s/%s/contents/%s?ref=%s",
    repository.owner,
    repository.name,
    encode_path(path),
    url_encode(ref)
  )
  local payload, err = gh.run_json({ "api", api })
  if not payload then
    return nil, err
  end

  return asset_from_payload(path, payload, image_options)
end

local function fetch_asset_async(repository, ref, path, image_options, callback)
  callback = callback or function() end
  if not repository or not ref or not path then
    callback(nil, "Missing repository/ref/path to fetch content")
    return
  end

  local api = string.format(
    "repos/%s/%s/contents/%s?ref=%s",
    repository.owner,
    repository.name,
    encode_path(path),
    url_encode(ref)
  )
  gh.run_json_async({ "api", api }, nil, function(payload, err)
    if not payload then
      callback(nil, err)
      return
    end

    local asset, asset_err = asset_from_payload(path, payload, image_options)
    callback(asset, asset_err)
  end)
end

local function is_not_found_error(err)
  if type(err) ~= "string" then
    return false
  end

  local lowered = err:lower()
  return lowered:find("404", 1, true) ~= nil
    or lowered:find("not found", 1, true) ~= nil
end

local function set_buffer_content(bufnr, lines)
  local was_readonly = vim.api.nvim_buf_get_option(bufnr, "readonly")
  if was_readonly then
    vim.api.nvim_buf_set_option(bufnr, "readonly", false)
  end
  vim.api.nvim_buf_set_option(bufnr, "modifiable", true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  pcall(vim.api.nvim_set_option_value, "modified", false, { buf = bufnr })
  vim.api.nvim_buf_set_option(bufnr, "modifiable", false)
  if was_readonly then
    vim.api.nvim_buf_set_option(bufnr, "readonly", true)
  end
end

local function split_text_with_endings(content)
  local text = type(content) == "string" and content or ""
  if text == "" then
    return {}, {}
  end

  local lines = {}
  local endings = {}
  local current = {}
  local index = 1
  local length = #text

  while index <= length do
    local char = text:sub(index, index)
    if char == "\r" then
      lines[#lines + 1] = table.concat(current)
      current = {}
      if index < length and text:sub(index + 1, index + 1) == "\n" then
        endings[#lines] = "crlf"
        index = index + 2
      else
        endings[#lines] = "cr"
        index = index + 1
      end
    elseif char == "\n" then
      lines[#lines + 1] = table.concat(current)
      current = {}
      endings[#lines] = "lf"
      index = index + 1
    else
      current[#current + 1] = char
      index = index + 1
    end
  end

  if #current > 0 then
    lines[#lines + 1] = table.concat(current)
  end

  return lines, endings
end

local function split_buffer_text_with_endings(content)
  local lines, endings = split_text_with_endings(content)
  if vim.tbl_isempty(lines) then
    return { "" }, {}
  end
  return lines, endings
end

local function virtual_uri(kind, repository, pr_number, path)
  local repo_name = repository.full_name:gsub("/", "-")
  return string.format("ghpr://%s/%d/%s/%s", repo_name, pr_number, kind, path)
end

local function normalize_path(path)
  if type(path) ~= "string" then
    return ""
  end

  return (path:gsub("\\", "/"))
end

local function buffer_canonical_path(bufnr)
  return normalize_path(vim.b[bufnr].gh_pr_file_path or vim.b[bufnr].gh_pr_path)
end

local function windows_showing_buffer(bufnr)
  local wins = {}
  for _, tabid in ipairs(vim.api.nvim_list_tabpages()) do
    for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(tabid)) do
      if vim.api.nvim_win_is_valid(winid) and vim.api.nvim_win_get_buf(winid) == bufnr then
        wins[#wins + 1] = { tabid = tabid, winid = winid }
      end
    end
  end
  return wins
end

local function find_window_for_buffer(bufnr, tabid)
  for _, item in ipairs(windows_showing_buffer(bufnr)) do
    if not tabid or item.tabid == tabid then
      return item
    end
  end
  return nil
end

local function focus_existing_buffer(bufnr)
  if type(bufnr) ~= "number" or bufnr < 1 or not vim.api.nvim_buf_is_valid(bufnr) then
    return false
  end

  local current_tab = vim.api.nvim_get_current_tabpage()
  local in_current = find_window_for_buffer(bufnr, current_tab)
  if in_current then
    pcall(vim.api.nvim_set_current_win, in_current.winid)
    return true
  end

  local anywhere = find_window_for_buffer(bufnr, nil)
  if anywhere then
    pcall(vim.api.nvim_set_current_tabpage, anywhere.tabid)
    pcall(vim.api.nvim_set_current_win, anywhere.winid)
    return true
  end

  return false
end

local function choose_preferred_buffer(buffers)
  if vim.tbl_isempty(buffers) then
    return nil
  end

  local current_buf = vim.api.nvim_get_current_buf()
  for _, bufnr in ipairs(buffers) do
    if bufnr == current_buf then
      return bufnr
    end
  end

  local current_tab = vim.api.nvim_get_current_tabpage()
  for _, bufnr in ipairs(buffers) do
    if find_window_for_buffer(bufnr, current_tab) then
      return bufnr
    end
  end

  return buffers[1]
end

local function collect_matching_buffers(repository_full_name, pr_number, canonical_path, kind)
  local target_path = normalize_path(canonical_path)
  if type(repository_full_name) ~= "string" or repository_full_name == "" then
    return {}
  end
  if type(pr_number) ~= "number" or target_path == "" then
    return {}
  end

  local matches = {}
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      local repo_name = vim.b[bufnr].gh_pr_repo
      local number = vim.b[bufnr].gh_pr_number
      local file_kind = vim.b[bufnr].gh_pr_file_kind
      local path = buffer_canonical_path(bufnr)
      if repo_name == repository_full_name
        and number == pr_number
        and path == target_path
        and (not kind or file_kind == kind) then
        matches[#matches + 1] = bufnr
      end
    end
  end

  return matches
end

local function collapse_duplicate_buffers(buffers, keep)
  if type(keep) ~= "number" or keep < 1 or not vim.api.nvim_buf_is_valid(keep) then
    return
  end

  for _, bufnr in ipairs(buffers) do
    if bufnr ~= keep and vim.api.nvim_buf_is_valid(bufnr) then
      for _, win in ipairs(windows_showing_buffer(bufnr)) do
        if vim.api.nvim_win_is_valid(win.winid) then
          pcall(vim.api.nvim_win_set_buf, win.winid, keep)
        end
      end
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end
  end
end

local function resolve_existing_buffer(repository, pr_number, canonical_path, kind)
  if type(repository) ~= "table" or type(repository.full_name) ~= "string" then
    return nil
  end

  local buffers = collect_matching_buffers(repository.full_name, pr_number, canonical_path, kind)
  local keep = choose_preferred_buffer(buffers)
  if not keep then
    return nil
  end

  collapse_duplicate_buffers(buffers, keep)
  return keep
end

local function set_buffer_name_if_available(bufnr, name)
  if type(name) ~= "string" or name == "" then
    return false
  end

  local current_name = vim.api.nvim_buf_get_name(bufnr)
  if current_name == name then
    return true
  end

  local existing = vim.fn.bufnr(name)
  if type(existing) == "number" and existing > 0 and existing ~= bufnr and vim.api.nvim_buf_is_valid(existing) then
    return false
  end

  local ok = pcall(vim.api.nvim_buf_set_name, bufnr, name)
  return ok
end

local function normalize_diff_mode(mode, fallback)
  if mode == "vertical" or mode == "horizontal" or mode == "unified" then
    return mode
  end

  return fallback or "vertical"
end

local function resolve_configured_diff_view()
  local options = (config.get() or {}).diff_view or {}
  local whitespace = type(options.whitespace) == "table" and options.whitespace or {}
  local endlines = type(options.endlines) == "table" and options.endlines or {}
  local images = resolve_image_options()
  return {
    mode = normalize_diff_mode(options.mode, "vertical"),
    ignore_whitespace = options.ignore_whitespace == true,
    render_whitespace = options.render_whitespace ~= false,
    render_endlines = options.render_endlines == true,
    whitespace = {
      tab = type(whitespace.tab) == "string" and whitespace.tab ~= "" and whitespace.tab or ">-",
      space = type(whitespace.space) == "string" and whitespace.space ~= "" and whitespace.space or ".",
      trail = type(whitespace.trail) == "string" and whitespace.trail ~= "" and whitespace.trail or "~",
      nbsp = type(whitespace.nbsp) == "string" and whitespace.nbsp ~= "" and whitespace.nbsp or "+",
      color = type(whitespace.color) == "string" and whitespace.color ~= "" and whitespace.color or nil,
      highlight_group = type(whitespace.highlight_group) == "string" and whitespace.highlight_group ~= ""
          and whitespace.highlight_group
        or "GhPrDiffWhitespace",
    },
    endlines = {
      lf = type(endlines.lf) == "string" and endlines.lf ~= "" and endlines.lf or "LF",
      crlf = type(endlines.crlf) == "string" and endlines.crlf ~= "" and endlines.crlf or "CRLF",
      cr = type(endlines.cr) == "string" and endlines.cr ~= "" and endlines.cr or "CR",
      color = type(endlines.color) == "string" and endlines.color ~= "" and endlines.color or nil,
      highlight_group = type(endlines.highlight_group) == "string" and endlines.highlight_group ~= ""
          and endlines.highlight_group
        or "GhPrDiffEndline",
    },
    images = images,
    shortcuts = type(options.shortcuts) == "table" and options.shortcuts or {},
  }
end

local function resolve_diff_view_shortcuts()
  local configured = resolve_configured_diff_view()
  local resolved = diff_shortcuts_config.resolve(configured.shortcuts)
  return diff_shortcuts_config.expand_localleader(resolved)
end

local function display_keybinding(key)
  if type(key) ~= "string" or key == "" then
    return ""
  end

  local localleader = type(vim.g.maplocalleader) == "string" and vim.g.maplocalleader or ","
  if localleader == "" then
    localleader = ","
  end

  local expanded = key:gsub("<[Ll]ocal[Ll]eader>", function()
    return localleader
  end)
  return vim.fn.keytrans(vim.api.nvim_replace_termcodes(expanded, true, true, true))
end

local function format_asset_bytes(bytes)
  local size = tonumber(bytes) or 0
  if size < 1024 then
    return string.format("%d B", size)
  end
  if size < (1024 * 1024) then
    return string.format("%.1f KB", size / 1024)
  end
  if size < (1024 * 1024 * 1024) then
    return string.format("%.1f MB", size / (1024 * 1024))
  end
  return string.format("%.1f GB", size / (1024 * 1024 * 1024))
end

local MIME_BY_EXTENSION = {
  png = "image/png",
  jpg = "image/jpeg",
  jpeg = "image/jpeg",
  gif = "image/gif",
  webp = "image/webp",
  bmp = "image/bmp",
  svg = "image/svg+xml",
  zip = "application/zip",
  pdf = "application/pdf",
  mp4 = "video/mp4",
  mov = "video/quicktime",
  avi = "video/x-msvideo",
  mp3 = "audio/mpeg",
  wav = "audio/wav",
  doc = "application/msword",
  docx = "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
  xls = "application/vnd.ms-excel",
  xlsx = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
  ppt = "application/vnd.ms-powerpoint",
  pptx = "application/vnd.openxmlformats-officedocument.presentationml.presentation",
  exe = "application/vnd.microsoft.portable-executable",
  dll = "application/vnd.microsoft.portable-executable",
  bin = "application/octet-stream",
}

local function infer_asset_mime(path, asset_kind)
  if asset_kind == "image" then
    local ext = path_extension(path)
    return MIME_BY_EXTENSION[ext] or "image/*"
  end
  local ext = path_extension(path)
  return MIME_BY_EXTENSION[ext] or "application/octet-stream"
end

local function normalize_asset_card_action(action)
  local value = type(action) == "string" and action:lower() or ""
  if value == "metadata" or value == "open_local_current" or value == "open_local_both" or value == "open_github" then
    return value
  end
  return "metadata"
end

local function asset_action_label(action, asset_kind)
  local normalized = normalize_asset_card_action(action)
  if normalized == "metadata" then
    return "Show metadata/actions in buffer"
  end
  if normalized == "open_local_current" then
    return asset_kind == "image" and "Open current image locally" or "Open current revision locally"
  end
  if normalized == "open_local_both" then
    return asset_kind == "image" and "Open base + modified images locally" or "Open both revisions locally"
  end
  return asset_kind == "image" and "Open GitHub PR image comparison" or "Open GitHub PR file view"
end

local function build_asset_side_entry(side, path, asset, present, asset_kind)
  local normalized_path = normalize_asset_path(path)
  local resolved_asset = type(asset) == "table" and asset or empty_asset(normalized_path)
  return {
    side = side,
    label = side == "base" and "Base" or "Modified",
    present = present ~= false,
    path = normalized_path,
    ext = type(resolved_asset.ext) == "string" and resolved_asset.ext or path_extension(normalized_path),
    size = tonumber(resolved_asset.size) or 0,
    sha = type(resolved_asset.sha) == "string" and resolved_asset.sha or "",
    mime = infer_asset_mime(normalized_path, asset_kind),
    error = type(resolved_asset.error) == "string" and resolved_asset.error or "",
  }
end

local function append_asset_side_lines(lines, entry, show_metadata)
  lines[#lines + 1] = string.format("%s revision", entry.label)
  if entry.present ~= true then
    lines[#lines + 1] = "  status: not present in this revision"
    return
  end

  lines[#lines + 1] = string.format("  path: %s", entry.path ~= "" and entry.path or "(unknown)")
  if entry.error ~= "" then
    lines[#lines + 1] = string.format("  error: %s", entry.error)
    return
  end
  if show_metadata ~= false then
    lines[#lines + 1] = string.format("  mime: %s", entry.mime)
    lines[#lines + 1] = string.format("  size: %s (%d bytes)", format_asset_bytes(entry.size), entry.size)
    lines[#lines + 1] = string.format("  sha: %s", entry.sha ~= "" and entry.sha:sub(1, 12) or "-")
    if entry.ext ~= "" then
      lines[#lines + 1] = string.format("  extension: .%s", entry.ext)
    end
  end
end

local function build_asset_card_lines(opts)
  opts = type(opts) == "table" and opts or {}
  local shortcuts = resolve_diff_view_shortcuts()
  local default_key = display_keybinding(shortcuts.image_default_action or "<localleader>io")
  local menu_key = display_keybinding(shortcuts.image_fallback_menu or "<localleader>im")
  local asset_kind = opts.asset_kind == "image" and "image" or "binary"
  local current_side = opts.current_side == "base" and "base" or "head"
  local lines = {
    string.format("gh-pr %s preview", asset_kind),
    "",
    string.format("path: %s", opts.display_path ~= "" and opts.display_path or "(unknown)"),
    string.format("status: %s", type(opts.status) == "string" and opts.status ~= "" and opts.status or "unknown"),
    string.format("current side: %s", current_side == "base" and "base" or "modified"),
  }
  if type(opts.reason) == "string" and opts.reason ~= "" then
    lines[#lines + 1] = string.format("preview note: %s", opts.reason)
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "Metadata"

  local action_lines = {}
  append_asset_side_lines(lines, opts.base_entry, opts.show_metadata)
  lines[#lines + 1] = ""
  append_asset_side_lines(lines, opts.head_entry, opts.show_metadata)
  lines[#lines + 1] = ""
  lines[#lines + 1] = "Actions"

  local ordered_actions = {
    "open_local_current",
    "open_local_both",
    "open_github",
    "metadata",
  }
  for _, action in ipairs(ordered_actions) do
    if action == "open_local_current" then
      local current_entry = current_side == "base" and opts.base_entry or opts.head_entry
      if current_entry.present == true then
        lines[#lines + 1] = string.format("  %s", asset_action_label(action, asset_kind))
        action_lines[#lines] = action
      end
    elseif action == "open_local_both" then
      if opts.base_entry.present == true and opts.head_entry.present == true then
        lines[#lines + 1] = string.format("  %s", asset_action_label(action, asset_kind))
        action_lines[#lines] = action
      end
    else
      lines[#lines + 1] = string.format("  %s", asset_action_label(action, asset_kind))
      action_lines[#lines] = action
    end
  end

  lines[#lines + 1] = ""
  lines[#lines + 1] = string.format(
    "Tip: press <CR> on an action row, %s for the default action, or %s for the full menu.",
    default_key ~= "" and default_key or "<localleader>io",
    menu_key ~= "" and menu_key or "<localleader>im"
  )

  return lines, action_lines
end

local function should_show_diff_open_hint(bufnr, file_kind, shortcuts)
  if type(bufnr) ~= "number" or bufnr < 1 or not vim.api.nvim_buf_is_valid(bufnr) then
    return false
  end
  if vim.b[bufnr].gh_pr_diff_open_hint_shown == true then
    return false
  end
  if shortcuts.show_open_hint == false then
    return false
  end
  return file_kind == "base" or file_kind == "head" or file_kind == "unified"
end

local function maybe_notify_diff_open_hint(bufnr, file_kind, shortcuts)
  if not should_show_diff_open_hint(bufnr, file_kind, shortcuts) then
    return
  end

  vim.b[bufnr].gh_pr_diff_open_hint_shown = true
  local quick = display_keybinding(shortcuts.close_quick)
  local close_review = display_keybinding(shortcuts.close_all_open_review)
  if quick == "" and close_review == "" then
    return
  end

  local message
  if quick ~= "" and close_review ~= "" then
    message = string.format("gh-pr diff: close with %s (quick) or %s (close + PR Review)", quick, close_review)
  elseif quick ~= "" then
    message = string.format("gh-pr diff: close with %s (quick)", quick)
  else
    message = string.format("gh-pr diff: close with %s (close + PR Review)", close_review)
  end

  vim.schedule(function()
    if vim.api.nvim_buf_is_valid(bufnr) then
      vim.notify(message, vim.log.levels.INFO)
    end
  end)
end

function M.resolve_diff_view_options(overrides)
  local configured = resolve_configured_diff_view()
  local persisted = type(state.get_diff_view_prefs) == "function" and state.get_diff_view_prefs() or {}
  local options = vim.tbl_deep_extend("force", configured, type(persisted) == "table" and persisted or {})
  options.mode = normalize_diff_mode(options.mode, configured.mode)
  options.ignore_whitespace = options.ignore_whitespace == true
  options.render_whitespace = options.render_whitespace ~= false
  options.render_endlines = options.render_endlines == true
  options.whitespace = type(options.whitespace) == "table" and options.whitespace or configured.whitespace
  options.endlines = type(options.endlines) == "table" and options.endlines or configured.endlines
  options.images = type(options.images) == "table" and options.images or configured.images

  if type(overrides) == "table" then
    if overrides.view_mode ~= nil then
      options.mode = normalize_diff_mode(overrides.view_mode, options.mode)
    end
    if type(overrides.ignore_whitespace) == "boolean" then
      options.ignore_whitespace = overrides.ignore_whitespace
    end
    if type(overrides.render_whitespace) == "boolean" then
      options.render_whitespace = overrides.render_whitespace
    end
    if type(overrides.render_endlines) == "boolean" then
      options.render_endlines = overrides.render_endlines
    end
  end

  return options
end

local function set_pr_buffer_keymaps(bufnr, keymap_opts)
  keymap_opts = type(keymap_opts) == "table" and keymap_opts or {}
  local asset_mode = keymap_opts.is_non_text == true

  local function remove_buffer_keymap(mode, lhs)
    if type(lhs) == "string" and lhs ~= "" then
      pcall(vim.keymap.del, mode, lhs, { buffer = bufnr })
    end
  end

  local function call_action(name)
    return function()
      local ok, actions = pcall(require, "gh-pr.actions")
      if ok and type(actions[name]) == "function" then
        actions[name]()
      end
    end
  end

  local opts = { buffer = bufnr, silent = true, nowait = true }
  local diff_shortcuts = resolve_diff_view_shortcuts()
  local configured_lc = (config.get() or {}).line_comments or {}
  local line_comment_key = type(configured_lc.keymap) == "string" and configured_lc.keymap or "K"
  local file_kind = type(vim.b[bufnr].gh_pr_file_kind) == "string" and vim.b[bufnr].gh_pr_file_kind or ""
  local function set_buffer_keymap(mode, lhs, rhs, desc)
    if type(lhs) ~= "string" or lhs == "" then
      return
    end
    vim.keymap.set(mode, lhs, rhs, vim.tbl_extend("force", opts, { desc = desc }))
  end

  local managed_normal = {
    diff_shortcuts.inline_comment,
    diff_shortcuts.inline_suggestion,
    diff_shortcuts.line_comments_popup,
    diff_shortcuts.refresh,
    diff_shortcuts.close_quick,
    diff_shortcuts.close_all_open_review,
    diff_shortcuts.help,
    diff_shortcuts.next_change,
    diff_shortcuts.prev_change,
    diff_shortcuts.next_file,
    diff_shortcuts.prev_file,
    diff_shortcuts.next_reviewed_file,
    diff_shortcuts.prev_reviewed_file,
    diff_shortcuts.toggle_whitespace,
    diff_shortcuts.toggle_render_whitespace,
    diff_shortcuts.toggle_render_endlines,
    diff_shortcuts.cycle_mode,
    diff_shortcuts.set_vertical,
    diff_shortcuts.set_horizontal,
    diff_shortcuts.set_unified,
    diff_shortcuts.submit_pending_comment,
    diff_shortcuts.submit_pending_approve,
    diff_shortcuts.submit_pending_request_changes,
    diff_shortcuts.discard_pending_review,
    diff_shortcuts.toggle_review_tree,
    diff_shortcuts.toggle_comments_panel,
    diff_shortcuts.image_default_action,
    diff_shortcuts.image_fallback_menu,
  }
  for _, lhs in ipairs(managed_normal) do
    remove_buffer_keymap("n", lhs)
  end
  remove_buffer_keymap("x", diff_shortcuts.inline_comment)
  remove_buffer_keymap("x", diff_shortcuts.inline_suggestion)
  remove_buffer_keymap("n", line_comment_key)

  -- Clean legacy single-key mappings to avoid collisions with native Neovim keys.
  for _, lhs in ipairs({
    "c",
    "s",
    "R",
    "q",
    "Q",
    "?",
    "n",
    "p",
    "f",
    "F",
    "v",
    "V",
    "w",
    "t",
    "e",
    "m",
    "i",
    "h",
    "u",
    "rc",
    "ra",
    "rr",
    "rd",
    "x",
    "<CR>",
    "gf",
  }) do
    remove_buffer_keymap("n", lhs)
  end
  remove_buffer_keymap("x", "c")
  remove_buffer_keymap("x", "s")

  set_buffer_keymap("n", diff_shortcuts.refresh, call_action("refresh_current_diff_buffer"), "Refresh current diff from GitHub")
  set_buffer_keymap("n", diff_shortcuts.close_quick, call_action("close_quick"), "Close quick diff view")
  set_buffer_keymap("n", diff_shortcuts.close_all_open_review, call_action("close_all_and_open_review"), "Close diff views and open PR Review")
  set_buffer_keymap("n", diff_shortcuts.help, call_action("show_diff_shortcuts"), "Show PR diff shortcuts")
  set_buffer_keymap("n", diff_shortcuts.next_file, call_action("next_file"), "Next PR file")
  set_buffer_keymap("n", diff_shortcuts.prev_file, call_action("prev_file"), "Previous PR file")
  set_buffer_keymap("n", diff_shortcuts.next_reviewed_file, call_action("next_reviewed_file"), "Next reviewed PR file")
  set_buffer_keymap("n", diff_shortcuts.prev_reviewed_file, call_action("prev_reviewed_file"), "Previous reviewed PR file")
  set_buffer_keymap("n", diff_shortcuts.submit_pending_comment, call_action("submit_pending_comment_review"), "Submit pending comment review")
  set_buffer_keymap("n", diff_shortcuts.submit_pending_approve, call_action("submit_pending_approve_review"), "Submit pending approve review")
  set_buffer_keymap(
    "n",
    diff_shortcuts.submit_pending_request_changes,
    call_action("submit_pending_request_changes_review"),
    "Submit pending request changes review"
  )
  set_buffer_keymap("n", diff_shortcuts.discard_pending_review, call_action("discard_pending_review"), "Discard pending review")
  set_buffer_keymap("n", diff_shortcuts.toggle_review_tree, call_action("toggle_review_tree"), "Toggle PR Review source")
  set_buffer_keymap("n", diff_shortcuts.toggle_comments_panel, call_action("toggle_diff_comments_panel"), "Toggle diff comments panel")

  if asset_mode then
    set_buffer_keymap(
      "n",
      diff_shortcuts.image_default_action,
      call_action("run_non_text_default_action"),
      "Run default non-text preview action"
    )
    set_buffer_keymap("n", diff_shortcuts.image_fallback_menu, call_action("open_non_text_actions_menu"), "Open non-text preview actions menu")
    set_buffer_keymap("n", "<CR>", call_action("run_non_text_action_at_cursor"), "Run action under cursor in non-text preview")
    maybe_notify_diff_open_hint(bufnr, file_kind, diff_shortcuts)
    return
  end

  set_buffer_keymap("n", diff_shortcuts.inline_comment, call_action("add_inline_comment"), "Add inline PR comment")
  set_buffer_keymap("x", diff_shortcuts.inline_comment, call_action("add_inline_comment_visual"), "Add inline PR comment for selection")
  set_buffer_keymap("n", diff_shortcuts.inline_suggestion, call_action("add_inline_suggestion"), "Add inline PR suggestion")
  set_buffer_keymap(
    "x",
    diff_shortcuts.inline_suggestion,
    call_action("add_inline_suggestion_visual"),
    "Add inline PR suggestion for selection"
  )
  if file_kind ~= "unified" then
    set_buffer_keymap("n", diff_shortcuts.line_comments_popup, function()
      line_comments.show_at_cursor(bufnr)
    end, "Show line comments popup")
  end
  set_buffer_keymap("n", diff_shortcuts.next_change, call_action("next_change"), "Next PR change")
  set_buffer_keymap("n", diff_shortcuts.prev_change, call_action("prev_change"), "Previous PR change")
  set_buffer_keymap("n", diff_shortcuts.toggle_whitespace, call_action("toggle_diff_whitespace"), "Toggle whitespace diff mode")
  set_buffer_keymap(
    "n",
    diff_shortcuts.toggle_render_whitespace,
    call_action("toggle_diff_render_whitespace"),
    "Toggle whitespace/tab rendering"
  )
  set_buffer_keymap(
    "n",
    diff_shortcuts.toggle_render_endlines,
    call_action("toggle_diff_render_endlines"),
    "Toggle endline rendering (LF/CRLF/CR)"
  )
  set_buffer_keymap("n", diff_shortcuts.cycle_mode, call_action("cycle_diff_view_mode"), "Cycle diff render mode")
  set_buffer_keymap("n", diff_shortcuts.set_vertical, call_action("set_diff_view_mode_vertical"), "Set vertical diff mode")
  set_buffer_keymap("n", diff_shortcuts.set_horizontal, call_action("set_diff_view_mode_horizontal"), "Set horizontal diff mode")
  set_buffer_keymap("n", diff_shortcuts.set_unified, call_action("set_diff_view_mode_unified"), "Set unified diff mode")
  maybe_notify_diff_open_hint(bufnr, file_kind, diff_shortcuts)
end

local function apply_buffer_mode_cleanup(bufnr, opts)
  opts = type(opts) == "table" and opts or {}
  local is_non_text = opts.is_non_text == true
  local images = type(opts.images) == "table" and opts.images or resolve_image_options()

  set_pr_buffer_keymaps(bufnr, {
    is_non_text = is_non_text,
    images = images,
  })
  ensure_virtual_buffer_cleanup(bufnr)
  image_renderer.clear(bufnr)

  if is_non_text then
    clear_extmark_namespaces(bufnr, { "whitespace", "endline" })
    return
  end
end

local function apply_line_highlights(bufnr, highlights)
  clear_extmark_namespaces(bufnr, { "unified_highlight" })
  if type(highlights) ~= "table" then
    return
  end

  for _, item in ipairs(highlights) do
    local line = type(item.line) == "number" and item.line or nil
    local group = type(item.group) == "string" and item.group or nil
    if line and group and line > 0 then
      pcall(vim.api.nvim_buf_add_highlight, bufnr, unified_highlight_ns, group, line - 1, 0, -1)
    end
  end
end

local function resolve_path_filetype(path)
  if type(path) ~= "string" or path == "" then
    return ""
  end

  return vim.filetype.match({ filename = path }) or ""
end

local function resolve_treesitter_lang(filetype)
  if type(filetype) ~= "string" or filetype == "" then
    return nil
  end

  if vim.treesitter
    and vim.treesitter.language
    and type(vim.treesitter.language.get_lang) == "function" then
    local ok, mapped = pcall(vim.treesitter.language.get_lang, filetype)
    if ok and type(mapped) == "string" and mapped ~= "" then
      return mapped
    end
  end

  return filetype
end

local function resolve_capture_group(capture_name, lang)
  if type(capture_name) ~= "string" or capture_name == "" then
    return nil
  end

  local candidates = {}
  if type(lang) == "string" and lang ~= "" then
    candidates[#candidates + 1] = "@" .. capture_name .. "." .. lang
  end
  candidates[#candidates + 1] = "@" .. capture_name

  for _, group in ipairs(candidates) do
    if vim.fn.hlexists(group) == 1 then
      return group
    end
  end

  return nil
end

local function apply_unified_syntax_highlights(bufnr, path, line_map)
  clear_extmark_namespaces(bufnr, { "unified_syntax" })

  if type(line_map) ~= "table" then
    return
  end
  if not vim.treesitter or type(vim.treesitter.get_string_parser) ~= "function" then
    return
  end
  if not vim.treesitter.query or type(vim.treesitter.query.get) ~= "function" then
    return
  end

  local filetype = resolve_path_filetype(path)
  if filetype == "" then
    return
  end

  local lang = resolve_treesitter_lang(filetype)
  if not lang then
    return
  end

  local ok_query, query = pcall(vim.treesitter.query.get, lang, "highlights")
  if not ok_query or not query then
    return
  end

  local rendered_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local source_lines = {}
  local source_to_buffer_line = {}
  for rendered_index = 1, #rendered_lines do
    local meta = line_map[rendered_index]
    if type(meta) == "table" and (meta.kind == "context" or meta.kind == "add") then
      local text = rendered_lines[rendered_index] or ""
      source_lines[#source_lines + 1] = #text >= 2 and text:sub(3) or ""
      source_to_buffer_line[#source_lines] = rendered_index
    end
  end

  if #source_lines == 0 then
    return
  end
  if #source_lines > 5000 then
    return
  end

  local source_text = table.concat(source_lines, "\n")
  local ok_parser, parser = pcall(vim.treesitter.get_string_parser, source_text, lang)
  if not ok_parser or not parser then
    return
  end

  local ok_parse, trees = pcall(parser.parse, parser)
  if not ok_parse or type(trees) ~= "table" then
    return
  end

  for _, tree in ipairs(trees) do
    local root = tree and tree:root() or nil
    if root then
      for capture_id, node in query:iter_captures(root, source_text, 0, -1) do
        local capture_name = query.captures[capture_id]
        local group = resolve_capture_group(capture_name, lang)
        if group then
          local row_start, col_start, row_end, col_end = node:range()
          for source_row = row_start, row_end do
            local buffer_line = source_to_buffer_line[source_row + 1]
            if buffer_line then
              local start_col = source_row == row_start and col_start or 0
              local end_col = source_row == row_end and col_end or -1
              pcall(
                vim.api.nvim_buf_add_highlight,
                bufnr,
                unified_syntax_ns,
                group,
                buffer_line - 1,
                math.max(0, start_col + 2),
                end_col >= 0 and (end_col + 2) or -1
              )
            end
          end
        end
      end
    end
  end
end

local function open_buffer(content, path, kind, details, pr, repo_override, comment_ctx, canonical_path, buffer_opts)
  buffer_opts = type(buffer_opts) == "table" and buffer_opts or {}
  local repository = repo_override or resolve_base_repository(details)
  local image_asset = type(buffer_opts.image_asset) == "table" and buffer_opts.image_asset or nil
  local asset_kind = type(buffer_opts.asset_kind) == "string" and buffer_opts.asset_kind or nil
  if asset_kind ~= "image" and asset_kind ~= "binary" then
    asset_kind = nil
  end
  local is_image = asset_kind == "image" and image_asset ~= nil
  local is_non_text = asset_kind == "image" or asset_kind == "binary"
  local images_cfg = type(buffer_opts.images) == "table" and buffer_opts.images or resolve_image_options()
  local image_reason = type(buffer_opts.image_reason) == "string" and buffer_opts.image_reason or ""
  local file_status = type(buffer_opts.file_status) == "string" and buffer_opts.file_status or ""
  local image_side = type(buffer_opts.image_side) == "string" and buffer_opts.image_side or kind
  local image_base_path = type(buffer_opts.image_base_path) == "string" and buffer_opts.image_base_path or nil
  local image_head_path = type(buffer_opts.image_head_path) == "string" and buffer_opts.image_head_path or nil
  local preview_lines = type(buffer_opts.preview_lines) == "table" and vim.deepcopy(buffer_opts.preview_lines) or nil
  local asset_actions = type(buffer_opts.asset_actions) == "table" and vim.deepcopy(buffer_opts.asset_actions) or {}
  local base_preview_entry = type(buffer_opts.base_preview_entry) == "table" and vim.deepcopy(buffer_opts.base_preview_entry) or nil
  local head_preview_entry = type(buffer_opts.head_preview_entry) == "table" and vim.deepcopy(buffer_opts.head_preview_entry) or nil
  local pr_url = type(buffer_opts.pr_url) == "string" and buffer_opts.pr_url or ""
  if pr_url == "" and type(details) == "table" and type(details.url) == "string" then
    pr_url = details.url
  end
  if pr_url == "" and type(pr) == "table" and type(pr.url) == "string" then
    pr_url = pr.url
  end
  if pr_url ~= "" then
    pr_url = pr_url:gsub("/+$", "")
  end
  local pr_files_url = type(buffer_opts.pr_files_url) == "string" and buffer_opts.pr_files_url or ""
  if pr_files_url == "" and pr_url ~= "" then
    if pr_url:find("/files$", 1, true) then
      pr_files_url = pr_url
    else
      pr_files_url = pr_url .. "/files"
    end
  end
  local canonical = normalize_path(canonical_path ~= nil and canonical_path or path)
  if canonical == "" then
    canonical = normalize_path(path)
  end

  local path_for_uri = canonical ~= "" and canonical or path
  local buffer_name = repository and virtual_uri(kind, repository, pr.number, path_for_uri) or nil

  local existing = nil
  if type(buffer_opts.existing_bufnr) == "number"
    and buffer_opts.existing_bufnr > 0
    and vim.api.nvim_buf_is_valid(buffer_opts.existing_bufnr) then
    existing = buffer_opts.existing_bufnr
  end
  if buffer_name then
    if not existing then
      local found = vim.fn.bufnr(buffer_name)
      if type(found) == "number" and found > 0 and vim.api.nvim_buf_is_valid(found) then
        existing = found
      end
    end
  end

  local bufnr = existing or vim.api.nvim_create_buf(true, true)
  local lines
  local endline_map = nil
  if type(preview_lines) == "table" then
    lines = preview_lines
  elseif is_image then
    lines = image_renderer.build_placeholder_lines({
      path = path,
      side = image_side,
      status = file_status,
      size = image_asset.size,
      sha = image_asset.sha,
      show_metadata = images_cfg.show_metadata ~= false,
      reason = image_reason,
    })
  else
    lines, endline_map = split_buffer_text_with_endings(content or "")
  end
  local ft = type(buffer_opts.filetype) == "string" and buffer_opts.filetype
    or (is_non_text and "markdown" or ((kind == "patch" or kind == "unified") and "diff" or resolve_path_filetype(path)))

  set_buffer_content(bufnr, lines)

  vim.api.nvim_buf_set_option(bufnr, "buftype", "nofile")
  vim.api.nvim_buf_set_option(bufnr, "bufhidden", "wipe")
  vim.api.nvim_buf_set_option(bufnr, "swapfile", false)
  vim.api.nvim_buf_set_option(bufnr, "readonly", true)
  vim.api.nvim_buf_set_option(bufnr, "filetype", ft)

  if repository then
    if not existing and buffer_name then
      vim.api.nvim_buf_set_name(bufnr, buffer_name)
    elseif buffer_name then
      set_buffer_name_if_available(bufnr, buffer_name)
    end
    vim.b[bufnr].gh_pr_repo = repository.full_name
  end

  vim.b[bufnr].gh_pr_path = path
  if canonical ~= "" then
    vim.b[bufnr].gh_pr_file_path = canonical
  else
    vim.b[bufnr].gh_pr_file_path = nil
  end
  vim.b[bufnr].gh_pr_number = pr.number
  vim.b[bufnr].gh_pr_file_kind = kind
  vim.b[bufnr].gh_pr_file_mode = type(buffer_opts.file_mode) == "string" and buffer_opts.file_mode or nil
  vim.b[bufnr].gh_pr_diff_backend = "virtual"
  vim.b[bufnr].gh_pr_is_image = is_image
  vim.b[bufnr].gh_pr_is_non_text = is_non_text
  vim.b[bufnr].gh_pr_asset_kind = is_non_text and asset_kind or nil
  vim.b[bufnr].gh_pr_asset_side = is_non_text and image_side or nil
  vim.b[bufnr].gh_pr_asset_status = is_non_text and file_status or nil
  vim.b[bufnr].gh_pr_asset_actions = is_non_text and asset_actions or nil
  vim.b[bufnr].gh_pr_asset_preview = is_non_text and {
    asset_kind = asset_kind,
    current_side = image_side,
    status = file_status,
    reason = image_reason,
    base = base_preview_entry,
    head = head_preview_entry,
  } or nil
  vim.b[bufnr].gh_pr_image_side = is_image and image_side or nil
  vim.b[bufnr].gh_pr_image_cache_path = nil
  vim.b[bufnr].gh_pr_image_reason = is_image and image_reason or nil
  vim.b[bufnr].gh_pr_image_status = is_image and file_status or nil
  vim.b[bufnr].gh_pr_pr_url = pr_url ~= "" and pr_url or nil
  vim.b[bufnr].gh_pr_pr_files_url = pr_files_url ~= "" and pr_files_url or nil
  vim.b[bufnr].gh_pr_image_base_path = is_image and image_base_path or nil
  vim.b[bufnr].gh_pr_image_head_path = is_image and image_head_path or nil
  vim.b[bufnr].gh_pr_image_size = is_image and tonumber(image_asset.size or 0) or nil
  vim.b[bufnr].gh_pr_image_sha = is_image and image_asset.sha or nil
  vim.b[bufnr].gh_pr_image_ext = is_image and image_asset.ext or nil
  vim.b[bufnr].gh_pr_image_fallback = is_image and false or nil
  vim.b[bufnr].gh_pr_image_fallback_notified_reason = nil
  vim.b[bufnr].gh_pr_comment_side = nil
  vim.b[bufnr].gh_pr_unified_line_map = nil
  vim.b[bufnr].gh_pr_endline_map = is_non_text and nil or endline_map

  if (not is_non_text) and type(comment_ctx) == "table" then
    local side = comment_ctx.side
    if side == "base" or side == "head" then
      vim.b[bufnr].gh_pr_comment_side = side
      line_comments.attach_to_buffer(bufnr, {
        index = comment_ctx.index,
        side = side,
        file_path = path,
        alternate_paths = comment_ctx.alternate_paths,
        keymap = comment_ctx.keymap,
        signs = comment_ctx.signs,
        max_popup_width = comment_ctx.max_popup_width,
        max_popup_height = comment_ctx.max_popup_height,
      })
    end
  end

  apply_line_highlights(bufnr, buffer_opts.line_highlights)

  if (not is_non_text) and type(buffer_opts.unified_line_map) == "table" then
    vim.b[bufnr].gh_pr_unified_line_map = buffer_opts.unified_line_map
  end
  if (not is_non_text) and kind == "unified" then
    apply_unified_syntax_highlights(bufnr, canonical ~= "" and canonical or path, vim.b[bufnr].gh_pr_unified_line_map)
  else
    clear_extmark_namespaces(bufnr, { "unified_syntax" })
  end

  apply_buffer_mode_cleanup(bufnr, {
    is_non_text = is_non_text,
    images = images_cfg,
  })

  return bufnr
end

local function build_comment_ctx(ctx, side, alternatives)
  if type(ctx) ~= "table" or type(ctx.index) ~= "table" then
    return nil
  end

  return {
    index = ctx.index,
    side = side,
    alternate_paths = alternatives or {},
    keymap = ctx.keymap,
    signs = ctx.signs,
    max_popup_width = ctx.max_popup_width,
    max_popup_height = ctx.max_popup_height,
  }
end

local function resolve_paths(file)
  local current_path = file.path or file.filename
  local previous_path = file.previousFilename or file.previous_filename

  if file.status == "RENAMED" or file.status == "renamed" then
    return previous_path or current_path, current_path
  end

  return current_path, current_path
end

local function finalize_remote_pair(opts)
  opts = type(opts) == "table" and opts or {}
  local base_asset = type(opts.base_asset) == "table" and opts.base_asset or empty_asset(opts.base_path)
  local head_asset = type(opts.head_asset) == "table" and opts.head_asset or empty_asset(opts.head_path)
  local status = type(opts.status) == "string" and opts.status or ""
  local errors = {}
  local file_mode = "diff_pair"
  local fetch_base_err = opts.fetch_base_err
  local fetch_head_err = opts.fetch_head_err

  if status == "added" then
    file_mode = "added_single"
  elseif status == "removed" then
    file_mode = "removed_single"
  else
    if fetch_base_err and not fetch_head_err and is_not_found_error(fetch_base_err) then
      file_mode = "added_single"
      errors = {}
    elseif fetch_head_err and not fetch_base_err and is_not_found_error(fetch_head_err) then
      file_mode = "removed_single"
      errors = {}
    end
  end

  if #errors > 0 then
    return nil, string.format(
      "Unable to load virtual file content from GitHub (%s)",
      table.concat(errors, " | ")
    )
  end

  local asset_kind = classify_file(opts.file, {
    image_options = opts.image_options,
    text_extensions = opts.text_extensions,
    asset = (type(head_asset) == "table" and head_asset.is_image ~= true and head_asset.present ~= false) and head_asset or base_asset,
  })

  return {
    base_content = base_asset.text or "",
    head_content = head_asset.text or "",
    base_path = opts.base_path,
    head_path = opts.head_path,
    repo = opts.base_repository,
    base_repo = opts.base_repository,
    head_repo = opts.head_repository,
    file_mode = file_mode,
    status = status,
    image_options = opts.image_options,
    base_asset = base_asset,
    head_asset = head_asset,
    asset_kind = asset_kind,
    is_image = asset_kind == "image",
    is_non_text = asset_kind == "image" or asset_kind == "asset",
  }, nil
end

local function read_base_and_head(details, _, file)
  local base_repository = resolve_base_repository(details)
  local head_repository = resolve_head_repository(details, base_repository)
  local image_options = resolve_image_options()

  if not base_repository then
    return nil, "Unable to resolve base repository"
  end

  local base_path, head_path = resolve_paths(file)
  if not head_path or head_path == "" then
    return nil, "Unable to resolve file path"
  end

  local status = (file.status or ""):lower()
  local base_asset = empty_asset(base_path)
  local head_asset = empty_asset(head_path)
  local fetch_base_err = nil
  local fetch_head_err = nil

  if status ~= "added" then
    base_asset, fetch_base_err = fetch_asset(base_repository, details.baseRefName, base_path, image_options)
  end

  if status ~= "removed" then
    head_asset, fetch_head_err = fetch_asset(head_repository, details.headRefName, head_path, image_options)
  end

  return finalize_remote_pair({
    status = status,
    file = file,
    base_path = base_path,
    head_path = head_path,
    image_options = image_options,
    text_extensions = resolve_text_extension_set(),
    base_repository = base_repository,
    head_repository = head_repository,
    base_asset = base_asset,
    head_asset = head_asset,
    fetch_base_err = fetch_base_err,
    fetch_head_err = fetch_head_err,
  })
end

local function read_base_and_head_async(details, _, file, callback)
  callback = callback or function() end

  local base_repository = resolve_base_repository(details)
  local head_repository = resolve_head_repository(details, base_repository)
  local image_options = resolve_image_options()

  if not base_repository then
    callback(nil, "Unable to resolve base repository")
    return
  end

  local base_path, head_path = resolve_paths(file)
  if not head_path or head_path == "" then
    callback(nil, "Unable to resolve file path")
    return
  end

  local status = (file.status or ""):lower()
  local base_asset = empty_asset(base_path)
  local head_asset = empty_asset(head_path)
  local fetch_base_err = nil
  local fetch_head_err = nil
  local pending = 0
  local finished = false

  local function maybe_finish()
    if finished or pending > 0 then
      return
    end
    finished = true
    callback(finalize_remote_pair({
      status = status,
      file = file,
      base_path = base_path,
      head_path = head_path,
      image_options = image_options,
      text_extensions = resolve_text_extension_set(),
      base_repository = base_repository,
      head_repository = head_repository,
      base_asset = base_asset,
      head_asset = head_asset,
      fetch_base_err = fetch_base_err,
      fetch_head_err = fetch_head_err,
    }))
  end

  if status ~= "added" then
    pending = pending + 1
    fetch_asset_async(base_repository, details.baseRefName, base_path, image_options, function(asset, err)
      base_asset = type(asset) == "table" and asset or empty_asset(base_path)
      fetch_base_err = err
      pending = pending - 1
      maybe_finish()
    end)
  end

  if status ~= "removed" then
    pending = pending + 1
    fetch_asset_async(head_repository, details.headRefName, head_path, image_options, function(asset, err)
      head_asset = type(asset) == "table" and asset or empty_asset(head_path)
      fetch_head_err = err
      pending = pending - 1
      maybe_finish()
    end)
  end

  maybe_finish()
end

local function normalize_commit_file(file)
  if type(file) ~= "table" then
    return nil
  end

  local path = file.path or file.filename
  if type(path) ~= "string" or path == "" then
    return nil
  end

  local previous = file.previous_filename or file.previousFilename
  if type(previous) ~= "string" then
    previous = ""
  end

  return {
    path = path,
    previous = previous,
    status = type(file.status) == "string" and file.status:lower() or "",
    patch = type(file.patch) == "string" and file.patch or "",
  }
end

local function append_lines(lines, text)
  local chunks = split_text_with_endings(text)
  for _, chunk in ipairs(chunks) do
    lines[#lines + 1] = chunk
  end
end

local function build_commit_patch_text(commit)
  local files = type(commit.files) == "table" and commit.files or {}
  local lines = {}
  local file_count = 0

  for _, raw in ipairs(files) do
    local file = normalize_commit_file(raw)
    if file then
      file_count = file_count + 1

      local old_path = file.previous ~= "" and file.previous or file.path
      local old_spec = "a/" .. old_path
      local new_spec = "b/" .. file.path

      if file.status == "added" then
        old_spec = "/dev/null"
      elseif file.status == "removed" then
        new_spec = "/dev/null"
      end

      lines[#lines + 1] = string.format("diff --git a/%s b/%s", old_path, file.path)
      if file.status == "renamed" and file.previous ~= "" then
        lines[#lines + 1] = "rename from " .. file.previous
        lines[#lines + 1] = "rename to " .. file.path
      end
      lines[#lines + 1] = "--- " .. old_spec
      lines[#lines + 1] = "+++ " .. new_spec

      if file.patch ~= "" then
        append_lines(lines, file.patch)
      else
        lines[#lines + 1] = "@@"
        lines[#lines + 1] = "(no textual patch available for this file)"
      end

      lines[#lines + 1] = ""
    end
  end

  if file_count == 0 then
    return nil, nil, "Selected commit has no files to render"
  end

  local sha = type(commit.oid) == "string" and commit.oid or "commit"
  local short = sha ~= "" and sha:sub(1, 8) or "commit"
  local path = string.format("commit/%s.diff", short)
  return table.concat(lines, "\n"), path, nil
end

local function is_regular_window(winid)
  if not vim.api.nvim_win_is_valid(winid) then
    return false
  end

  local ok, config_value = pcall(vim.api.nvim_win_get_config, winid)
  if not ok or type(config_value) ~= "table" then
    return false
  end

  return config_value.relative == ""
end

local function prepare_diff_workspace(new_tab)
  if new_tab ~= false then
    vim.cmd("tabnew")
    return vim.api.nvim_get_current_win()
  end

  local current = vim.api.nvim_get_current_win()
  local tabid = vim.api.nvim_get_current_tabpage()
  for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(tabid)) do
    if winid ~= current and is_regular_window(winid) then
      pcall(vim.api.nvim_win_close, winid, true)
    end
  end

  return current
end

local function split_content_lines(content)
  local lines = split_text_with_endings(content or "")
  if #lines == 1 and lines[1] == "" then
    return {}
  end
  return lines
end

local function build_unified_diff_text(base_content, head_content, ignore_whitespace)
  local base_lines = split_content_lines(base_content)
  local head_lines = split_content_lines(head_content)
  local rendered = {}
  local highlights = {}
  local line_map = {}

  local function append(prefix, text, highlight, meta)
    rendered[#rendered + 1] = prefix .. text
    if highlight then
      highlights[#highlights + 1] = {
        line = #rendered,
        group = highlight,
      }
    end
    if type(meta) == "table" then
      line_map[#rendered] = meta
    end
  end

  local hunks = vim.diff(base_content or "", head_content or "", {
    result_type = "indices",
    ignore_whitespace = ignore_whitespace == true,
  }) or {}

  local base_index = 1
  local head_index = 1

  for _, hunk in ipairs(hunks) do
    local start_base = tonumber(hunk[1]) or base_index
    local count_base = tonumber(hunk[2]) or 0
    local start_head = tonumber(hunk[3]) or head_index
    local count_head = tonumber(hunk[4]) or 0

    while base_index < start_base and head_index < start_head do
      append("  ", head_lines[head_index] or "", nil, {
        kind = "context",
        head_line = head_index,
        base_line = base_index,
      })
      base_index = base_index + 1
      head_index = head_index + 1
    end

    for index = 0, count_base - 1 do
      append("- ", base_lines[start_base + index] or "", "DiffDelete", {
        kind = "delete",
        base_line = start_base + index,
      })
    end

    for index = 0, count_head - 1 do
      append("+ ", head_lines[start_head + index] or "", "DiffAdd", {
        kind = "add",
        head_line = start_head + index,
      })
    end

    base_index = start_base + count_base
    head_index = start_head + count_head
  end

  while base_index <= #base_lines and head_index <= #head_lines do
    append("  ", head_lines[head_index] or "", nil, {
      kind = "context",
      head_line = head_index,
      base_line = base_index,
    })
    base_index = base_index + 1
    head_index = head_index + 1
  end

  while base_index <= #base_lines do
    append("- ", base_lines[base_index] or "", "DiffDelete", {
      kind = "delete",
      base_line = base_index,
    })
    base_index = base_index + 1
  end

  while head_index <= #head_lines do
    append("+ ", head_lines[head_index] or "", "DiffAdd", {
      kind = "add",
      head_line = head_index,
    })
    head_index = head_index + 1
  end

  if #rendered == 0 then
    rendered = { "  " }
    line_map[1] = { kind = "context" }
  end

  return table.concat(rendered, "\n"), highlights, line_map
end

local function apply_window_diffopt(winid, ignore_whitespace)
  local ok, diffopt_value = pcall(vim.api.nvim_get_option_value, "diffopt", { win = winid })
  if not ok then
    return
  end

  local entries = {}
  for token in tostring(diffopt_value):gmatch("[^,]+") do
    if token ~= "iwhite" and token ~= "iwhiteall" and token ~= "iwhiteeol" and token ~= "iblank" then
      entries[#entries + 1] = token
    end
  end

  if ignore_whitespace then
    local with_iwhiteall = vim.deepcopy(entries)
    with_iwhiteall[#with_iwhiteall + 1] = "iwhiteall"
    local set_ok = pcall(vim.api.nvim_set_option_value, "diffopt", table.concat(with_iwhiteall, ","), { win = winid })
    if set_ok then
      return
    end

    entries[#entries + 1] = "iwhite"
  end

  pcall(vim.api.nvim_set_option_value, "diffopt", table.concat(entries, ","), { win = winid })
end

local function first_marker_char(value, fallback)
  local marker = type(value) == "string" and value or ""
  if marker == "" then
    marker = fallback
  end
  if type(marker) ~= "string" or marker == "" then
    marker = fallback
  end
  if type(marker) ~= "string" or marker == "" then
    return ""
  end
  return vim.fn.strcharpart(marker, 0, 1)
end

local function apply_window_whitespace_render(winid, enabled)
  if type(winid) ~= "number" or winid < 1 or not vim.api.nvim_win_is_valid(winid) then
    return
  end

  local bufnr = vim.api.nvim_win_get_buf(winid)
  if type(bufnr) ~= "number" or bufnr < 1 or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  clear_extmark_namespaces(bufnr, { "whitespace" })

  -- Keep diff buffers independent from global `list` rendering.
  pcall(vim.api.nvim_set_option_value, "list", false, { win = winid })

  local winvars = vim.w[winid]
  local previous_winhl = winvars.gh_pr_whitespace_prev_winhl
  if previous_winhl ~= nil then
    pcall(vim.api.nvim_set_option_value, "winhl", previous_winhl, { win = winid })
    winvars.gh_pr_whitespace_prev_winhl = nil
  end

  if enabled ~= true or vim.b[bufnr].gh_pr_is_non_text == true then
    return
  end

  local diff_view = resolve_configured_diff_view()
  local whitespace = type(diff_view.whitespace) == "table" and diff_view.whitespace or {}
  local token_tab = first_marker_char(whitespace.tab, ">")
  local token_space = first_marker_char(whitespace.space, ".")
  local token_trail = first_marker_char(whitespace.trail, "~")

  local group = type(whitespace.highlight_group) == "string" and whitespace.highlight_group ~= ""
      and whitespace.highlight_group
    or "GhPrDiffWhitespace"
  local color = type(whitespace.color) == "string" and whitespace.color ~= "" and whitespace.color or nil
  if color then
    pcall(vim.api.nvim_set_hl, 0, group, { fg = color, nocombine = true })
  elseif group ~= "Whitespace" and vim.fn.hlexists(group) == 0 then
    pcall(vim.api.nvim_set_hl, 0, group, { link = "Whitespace", default = true })
  end

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  for line_index, line in ipairs(lines) do
    if line ~= "" then
      local leading_start, leading_end = line:find("^[ \t]+")
      local trailing_start, trailing_end = line:find("[ \t]+$")

      local function mark_range(start_col, end_col, use_trailing_token)
        if type(start_col) ~= "number" or type(end_col) ~= "number" or start_col > end_col then
          return
        end
        for byte_col = start_col, end_col do
          local char = line:sub(byte_col, byte_col)
          local marker = (char == "\t") and token_tab or (use_trailing_token and token_trail or token_space)
          if marker ~= "" then
            pcall(vim.api.nvim_buf_set_extmark, bufnr, whitespace_render_ns, line_index - 1, byte_col - 1, {
              virt_text = { { marker, group } },
              virt_text_pos = "overlay",
              hl_mode = "combine",
              priority = 125,
            })
          end
        end
      end

      if leading_start and leading_end then
        mark_range(leading_start, leading_end, false)
      end

      if trailing_start and trailing_end then
        local start_col = trailing_start
        if leading_end and start_col <= leading_end then
          start_col = leading_end + 1
        end
        mark_range(start_col, trailing_end, true)
      end
    end
  end
end

local function apply_window_endline_render(winid, enabled)
  if type(winid) ~= "number" or winid < 1 or not vim.api.nvim_win_is_valid(winid) then
    return
  end

  local bufnr = vim.api.nvim_win_get_buf(winid)
  if type(bufnr) ~= "number" or bufnr < 1 or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  clear_extmark_namespaces(bufnr, { "endline" })
  if enabled ~= true or vim.b[bufnr].gh_pr_is_non_text == true then
    return
  end

  local endline_map = vim.b[bufnr].gh_pr_endline_map
  if type(endline_map) ~= "table" or vim.tbl_isempty(endline_map) then
    return
  end

  local diff_view = resolve_configured_diff_view()
  local endline_cfg = type(diff_view.endlines) == "table" and diff_view.endlines or {}
  local group = type(endline_cfg.highlight_group) == "string" and endline_cfg.highlight_group ~= ""
      and endline_cfg.highlight_group
    or "GhPrDiffEndline"
  local color = type(endline_cfg.color) == "string" and endline_cfg.color ~= "" and endline_cfg.color or nil

  if color then
    pcall(vim.api.nvim_set_hl, 0, group, { fg = color, nocombine = true })
  elseif group ~= "Comment" and vim.fn.hlexists(group) == 0 then
    pcall(vim.api.nvim_set_hl, 0, group, { link = "Comment", default = true })
  end

  local markers = {
    lf = type(endline_cfg.lf) == "string" and endline_cfg.lf or "LF",
    crlf = type(endline_cfg.crlf) == "string" and endline_cfg.crlf or "CRLF",
    cr = type(endline_cfg.cr) == "string" and endline_cfg.cr or "CR",
  }

  local line_count = vim.api.nvim_buf_line_count(bufnr)
  for line_index = 1, line_count do
    local ending = endline_map[line_index]
    local marker = markers[ending]
    if type(marker) == "string" and marker ~= "" then
      pcall(vim.api.nvim_buf_set_extmark, bufnr, endline_render_ns, line_index - 1, -1, {
        virt_text = { { " " .. marker, group } },
        virt_text_pos = "eol",
        hl_mode = "combine",
        priority = 130,
      })
    end
  end
end

local function clear_diff_window_state(winid)
  if type(winid) ~= "number" or winid < 1 or not vim.api.nvim_win_is_valid(winid) then
    return
  end

  pcall(vim.api.nvim_set_option_value, "diff", false, { win = winid })
  pcall(vim.api.nvim_set_option_value, "scrollbind", false, { win = winid })
  pcall(vim.api.nvim_set_option_value, "cursorbind", false, { win = winid })
end

local function apply_diff_window_sync(base_win, head_win)
  for _, winid in ipairs({ base_win, head_win }) do
    if type(winid) == "number" and winid > 0 and vim.api.nvim_win_is_valid(winid) then
      pcall(vim.api.nvim_set_option_value, "scrollbind", true, { win = winid })
      pcall(vim.api.nvim_set_option_value, "cursorbind", true, { win = winid })
    end
  end
end

local function image_placeholder_reason(reason)
  local normalized = type(reason) == "string" and reason or ""
  if normalized == "backend-unavailable" then
    return "snacks.image not available in this session"
  end
  if normalized == "terminal-or-format-unsupported" then
    return "terminal backend does not support this image format"
  end
  if normalized == "too-large" then
    return "image exceeds configured max_bytes"
  end
  if normalized == "disabled" then
    return "image previews disabled by configuration"
  end
  if normalized == "unsupported-backend" then
    return "configured image backend is not supported"
  end
  if normalized == "missing-bytes" then
    return "unable to decode image bytes from GitHub contents API"
  end
  if normalized == "not-image" then
    return "file is not recognized as a supported image"
  end
  if normalized ~= "" then
    return normalized
  end
  return "preview unavailable"
end

local function refresh_image_placeholder(bufnr, path, side, status, asset, image_options, reason)
  if type(bufnr) ~= "number" or bufnr < 1 or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  local lines = image_renderer.build_placeholder_lines({
    path = path,
    side = side,
    status = status,
    size = type(asset) == "table" and asset.size or nil,
    sha = type(asset) == "table" and asset.sha or nil,
    show_metadata = type(image_options) == "table" and image_options.show_metadata ~= false,
    reason = reason,
  })
  set_buffer_content(bufnr, lines)
  vim.b[bufnr].gh_pr_image_reason = reason
end

local function render_image_in_window(bufnr, winid, details, pr, side, status, asset, image_options)
  if type(bufnr) ~= "number" or bufnr < 1 or not vim.api.nvim_buf_is_valid(bufnr) then
    return false, "invalid-buffer"
  end

  local repository = resolve_base_repository(details)
  local repo_name = repository and repository.full_name or (vim.b[bufnr].gh_pr_repo or "")
  local cache_path = nil
  if type(asset) == "table" and type(asset.bytes) == "string" and asset.bytes ~= "" then
    local ensured, ensure_err = image_renderer.ensure_cache({
      repository = repo_name,
      pr_number = pr.number,
      side = side,
      path = asset.path,
      sha = asset.sha,
      size = asset.size,
      bytes = asset.bytes,
      images = image_options,
    })
    if ensured then
      cache_path = ensured
      vim.b[bufnr].gh_pr_image_cache_path = ensured
    elseif ensure_err then
      vim.b[bufnr].gh_pr_image_cache_path = nil
    end
  end
  local ok_render, render_err, meta = image_renderer.render({
    bufnr = bufnr,
    winid = winid,
    repository = repo_name,
    pr_number = pr.number,
    side = side,
    asset = asset,
    images = image_options,
  })

  if ok_render then
    if type(meta) == "table" and type(meta.cache_path) == "string" then
      vim.b[bufnr].gh_pr_image_cache_path = meta.cache_path
    elseif cache_path then
      vim.b[bufnr].gh_pr_image_cache_path = cache_path
    end
    vim.b[bufnr].gh_pr_image_reason = "rendered"
    vim.b[bufnr].gh_pr_image_fallback = false
    vim.b[bufnr].gh_pr_image_fallback_notified_reason = nil
    return true, nil
  end

  local message = image_placeholder_reason(render_err)
  refresh_image_placeholder(
    bufnr,
    type(asset) == "table" and asset.path or vim.b[bufnr].gh_pr_path,
    side,
    status,
    asset,
    image_options,
    message
  )
  vim.b[bufnr].gh_pr_image_fallback = true
  if vim.b[bufnr].gh_pr_image_fallback_notified_reason ~= message then
    vim.b[bufnr].gh_pr_image_fallback_notified_reason = message
    local ok_actions, actions = pcall(require, "gh-pr.actions")
    if ok_actions and type(actions.on_image_render_fallback) == "function" then
      pcall(actions.on_image_render_fallback, bufnr, message)
    end
  end
  return false, message
end

local function build_binary_preview_payload(data, current_side, display_path, reason)
  current_side = current_side == "base" and "base" or "head"
  local non_text_opts = resolve_non_text_options()
  local base_present = data.file_mode ~= "added_single"
  local head_present = data.file_mode ~= "removed_single"
  local base_entry = build_asset_side_entry("base", data.base_path, data.base_asset, base_present, "binary")
  local head_entry = build_asset_side_entry("head", data.head_path, data.head_asset, head_present, "binary")
  local lines, action_lines = build_asset_card_lines({
    asset_kind = "binary",
    current_side = current_side,
    display_path = normalize_asset_path(display_path or data.head_path or data.base_path),
    status = data.status,
    reason = reason,
    show_metadata = non_text_opts.show_metadata,
    base_entry = base_entry,
    head_entry = head_entry,
  })
  return {
    asset_kind = "binary",
    preview_lines = lines,
    asset_actions = action_lines,
    base_preview_entry = base_entry,
    head_preview_entry = head_entry,
  }
end

function M.open_original(details, pr, file, opts)
  opts = opts or {}
  local data, err = read_base_and_head(details, pr, file)
  if not data then
    return nil, err
  end

  local canonical_path = normalize_path(file.path or file.filename)
  local mode = data.file_mode == "added_single" and "added_single" or (data.file_mode == "removed_single" and "removed_single" or "diff_pair")
  local kind = mode == "added_single" and "head" or "base"
  local comment_ctx = data.is_non_text and nil or build_comment_ctx(opts.line_comments, kind == "head" and "head" or "base", {
    data.base_path,
    data.head_path,
    file.path,
    file.filename,
    file.previousFilename,
    file.previous_filename,
  })
  local display_path = kind == "head" and data.head_path or data.base_path
  local content = kind == "head" and data.head_content or data.base_content
  local asset = kind == "head" and data.head_asset or data.base_asset
  local binary_preview = data.asset_kind == "asset" and build_binary_preview_payload(data, kind, display_path, "") or nil
  local existing = resolve_existing_buffer(data.repo, pr.number, canonical_path, kind)
  if existing then
    focus_existing_buffer(existing)
  end
  local buf = open_buffer(content, display_path, kind, details, pr, data.repo, comment_ctx, canonical_path, {
    existing_bufnr = existing,
    file_mode = mode,
    asset_kind = data.asset_kind == "asset" and "binary" or (data.is_image and "image" or nil),
    image_side = kind,
    image_asset = asset,
    image_reason = "",
    file_status = data.status,
    images = data.image_options,
    image_base_path = data.base_path,
    image_head_path = data.head_path,
    preview_lines = binary_preview and binary_preview.preview_lines or nil,
    asset_actions = binary_preview and binary_preview.asset_actions or nil,
    base_preview_entry = binary_preview and binary_preview.base_preview_entry or nil,
    head_preview_entry = binary_preview and binary_preview.head_preview_entry or nil,
    pr_url = type(details.url) == "string" and details.url or (type(pr.url) == "string" and pr.url or ""),
  })
  vim.api.nvim_win_set_buf(0, buf)
  if data.is_image then
    render_image_in_window(buf, vim.api.nvim_get_current_win(), details, pr, kind, data.status, asset, data.image_options)
  end
  return buf, nil
end

function M.open_modified(details, pr, file, opts)
  opts = opts or {}
  local data, err = read_base_and_head(details, pr, file)
  if not data then
    return nil, err
  end

  local canonical_path = normalize_path(file.path or file.filename)
  local mode = data.file_mode == "added_single" and "added_single" or (data.file_mode == "removed_single" and "removed_single" or "diff_pair")
  local kind = mode == "removed_single" and "base" or "head"
  local comment_ctx = data.is_non_text and nil or build_comment_ctx(opts.line_comments, kind == "base" and "base" or "head", {
    data.head_path,
    data.base_path,
    file.path,
    file.filename,
    file.previousFilename,
    file.previous_filename,
  })
  local display_path = kind == "base" and data.base_path or data.head_path
  local content = kind == "base" and data.base_content or data.head_content
  local asset = kind == "base" and data.base_asset or data.head_asset
  local binary_preview = data.asset_kind == "asset" and build_binary_preview_payload(data, kind, display_path, "") or nil
  local existing = resolve_existing_buffer(data.repo, pr.number, canonical_path, kind)
  if existing then
    focus_existing_buffer(existing)
  end
  local buf = open_buffer(content, display_path, kind, details, pr, data.repo, comment_ctx, canonical_path, {
    existing_bufnr = existing,
    file_mode = mode,
    asset_kind = data.asset_kind == "asset" and "binary" or (data.is_image and "image" or nil),
    image_side = kind,
    image_asset = asset,
    image_reason = "",
    file_status = data.status,
    images = data.image_options,
    image_base_path = data.base_path,
    image_head_path = data.head_path,
    preview_lines = binary_preview and binary_preview.preview_lines or nil,
    asset_actions = binary_preview and binary_preview.asset_actions or nil,
    base_preview_entry = binary_preview and binary_preview.base_preview_entry or nil,
    head_preview_entry = binary_preview and binary_preview.head_preview_entry or nil,
    pr_url = type(details.url) == "string" and details.url or (type(pr.url) == "string" and pr.url or ""),
  })
  vim.api.nvim_win_set_buf(0, buf)
  if data.is_image then
    render_image_in_window(buf, vim.api.nvim_get_current_win(), details, pr, kind, data.status, asset, data.image_options)
  end
  return buf, nil
end

function M.open_diff(details, pr, file, opts)
  opts = opts or {}
  local data, err = read_base_and_head(details, pr, file)
  if not data then
    return nil, err
  end

  local diff_view = M.resolve_diff_view_options(opts)
  local mode = normalize_diff_mode(diff_view.mode, "vertical")
  local render_mode = (data.is_image and mode == "unified") and "vertical" or mode
  local canonical_path = normalize_path(file.path or file.filename)
  if canonical_path == "" then
    return nil, "Unable to resolve file path"
  end

  if data.file_mode == "added_single" or data.file_mode == "removed_single" then
    local single_kind = data.file_mode == "added_single" and "head" or "base"
    local single_content = single_kind == "head" and (data.head_content or "") or (data.base_content or "")
    local single_path = single_kind == "head" and (data.head_path or canonical_path) or (data.base_path or canonical_path)
    local single_asset = single_kind == "head" and data.head_asset or data.base_asset
    local single_comment_ctx = data.is_non_text and nil or build_comment_ctx(opts.line_comments, single_kind == "head" and "head" or "base", {
      data.head_path,
      data.base_path,
      file.path,
      file.filename,
      file.previousFilename,
      file.previous_filename,
    })
    local existing_single = resolve_existing_buffer(data.repo, pr.number, canonical_path, single_kind)
    local target_win = nil

    if existing_single and focus_existing_buffer(existing_single) then
      target_win = vim.api.nvim_get_current_win()
    else
      target_win = prepare_diff_workspace(opts.new_tab)
    end

    if not target_win or not vim.api.nvim_win_is_valid(target_win) then
      return nil, "Unable to prepare diff workspace"
    end

    local binary_preview = data.asset_kind == "asset" and build_binary_preview_payload(data, single_kind, single_path, "") or nil
    local single_buf = open_buffer(
      single_content,
      single_path,
      single_kind,
      details,
      pr,
      data.repo,
      single_comment_ctx,
      canonical_path,
      {
        existing_bufnr = existing_single,
        file_mode = data.file_mode,
        asset_kind = data.asset_kind == "asset" and "binary" or (data.is_image and "image" or nil),
        image_side = single_kind,
        image_asset = single_asset,
        image_reason = "",
        file_status = data.status,
        images = data.image_options,
        image_base_path = data.base_path,
        image_head_path = data.head_path,
        preview_lines = binary_preview and binary_preview.preview_lines or nil,
        asset_actions = binary_preview and binary_preview.asset_actions or nil,
        base_preview_entry = binary_preview and binary_preview.base_preview_entry or nil,
        head_preview_entry = binary_preview and binary_preview.head_preview_entry or nil,
        pr_url = type(details.url) == "string" and details.url or (type(pr.url) == "string" and pr.url or ""),
      }
    )

    clear_diff_window_state(target_win)
    vim.api.nvim_win_set_buf(target_win, single_buf)
    if data.is_image then
      render_image_in_window(single_buf, target_win, details, pr, single_kind, data.status, single_asset, data.image_options)
      apply_window_whitespace_render(target_win, false)
      apply_window_endline_render(target_win, false)
    elseif data.asset_kind == "asset" then
      apply_window_whitespace_render(target_win, false)
      apply_window_endline_render(target_win, false)
    else
      apply_window_whitespace_render(target_win, diff_view.render_whitespace)
      apply_window_endline_render(target_win, diff_view.render_endlines)
    end
    pcall(vim.api.nvim_set_current_win, target_win)
    return {
      single_buf = single_buf,
      mode = render_mode,
      file_mode = data.file_mode,
    }, nil
  end

  if data.asset_kind == "asset" then
    local existing_unified = resolve_existing_buffer(data.repo, pr.number, canonical_path, "unified")
    local target_win = nil
    if existing_unified and focus_existing_buffer(existing_unified) then
      target_win = vim.api.nvim_get_current_win()
    else
      target_win = prepare_diff_workspace(opts.new_tab)
    end

    if not target_win or not vim.api.nvim_win_is_valid(target_win) then
      return nil, "Unable to prepare diff workspace"
    end

    local display_path = data.head_path or data.base_path or canonical_path
    local binary_preview = build_binary_preview_payload(data, "head", display_path, "")
    local unified_buf = open_buffer(
      "",
      display_path,
      "unified",
      details,
      pr,
      data.repo,
      nil,
      canonical_path,
      {
        existing_bufnr = existing_unified,
        filetype = "markdown",
        file_mode = "unified",
        asset_kind = "binary",
        image_side = "head",
        image_reason = "",
        file_status = data.status,
        images = data.image_options,
        image_base_path = data.base_path,
        image_head_path = data.head_path,
        preview_lines = binary_preview.preview_lines,
        asset_actions = binary_preview.asset_actions,
        base_preview_entry = binary_preview.base_preview_entry,
        head_preview_entry = binary_preview.head_preview_entry,
        pr_url = type(details.url) == "string" and details.url or (type(pr.url) == "string" and pr.url or ""),
      }
    )
    clear_diff_window_state(target_win)
    vim.api.nvim_win_set_buf(target_win, unified_buf)
    apply_window_whitespace_render(target_win, false)
    apply_window_endline_render(target_win, false)
    pcall(vim.api.nvim_set_current_win, target_win)
    return {
      unified_buf = unified_buf,
      mode = render_mode,
      file_mode = data.file_mode,
    }, nil
  end

  if render_mode == "unified" then
    local existing_unified = resolve_existing_buffer(data.repo, pr.number, canonical_path, "unified")
    local target_win = nil
    if existing_unified and focus_existing_buffer(existing_unified) then
      target_win = vim.api.nvim_get_current_win()
    else
      target_win = prepare_diff_workspace(opts.new_tab)
    end

    if not target_win or not vim.api.nvim_win_is_valid(target_win) then
      return nil, "Unable to prepare diff workspace"
    end

    local unified_content, highlights, line_map = build_unified_diff_text(
      data.base_content or "",
      data.head_content or "",
      diff_view.ignore_whitespace
    )
    local display_path = data.head_path or data.base_path or canonical_path
    local unified_buf = open_buffer(
      unified_content,
      display_path,
      "unified",
      details,
      pr,
      data.repo,
      nil,
      canonical_path,
      {
        existing_bufnr = existing_unified,
        filetype = "diff",
        line_highlights = highlights,
        unified_line_map = line_map,
        file_mode = "unified",
      }
    )
    clear_diff_window_state(target_win)
    vim.api.nvim_win_set_buf(target_win, unified_buf)
    apply_window_whitespace_render(target_win, diff_view.render_whitespace)
    apply_window_endline_render(target_win, diff_view.render_endlines)
    pcall(vim.api.nvim_set_current_win, target_win)
    return { unified_buf = unified_buf, mode = render_mode }, nil
  end

  local existing_base = resolve_existing_buffer(data.repo, pr.number, canonical_path, "base")
  local existing_head = resolve_existing_buffer(data.repo, pr.number, canonical_path, "head")
  local target_win = nil

  if existing_base and focus_existing_buffer(existing_base) then
    target_win = vim.api.nvim_get_current_win()
  elseif existing_head and focus_existing_buffer(existing_head) then
    target_win = vim.api.nvim_get_current_win()
  else
    target_win = prepare_diff_workspace(opts.new_tab)
  end

  if not target_win or not vim.api.nvim_win_is_valid(target_win) then
    return nil, "Unable to prepare diff workspace"
  end

  pcall(vim.api.nvim_set_current_win, target_win)
  local base_comment_ctx = data.is_non_text and nil or build_comment_ctx(opts.line_comments, "base", {
    data.base_path,
    data.head_path,
    file.path,
    file.filename,
    file.previousFilename,
    file.previous_filename,
  })
  local base_buf = open_buffer(
    data.base_content,
    data.base_path,
    "base",
    details,
    pr,
    data.repo,
    base_comment_ctx,
      canonical_path,
      {
        existing_bufnr = existing_base,
        file_mode = "diff_pair",
        asset_kind = data.is_image and "image" or nil,
        image_side = "base",
        image_asset = data.base_asset,
        image_reason = "",
      file_status = data.status,
      images = data.image_options,
      image_base_path = data.base_path,
      image_head_path = data.head_path,
      pr_url = type(details.url) == "string" and details.url or (type(pr.url) == "string" and pr.url or ""),
    }
  )
  vim.api.nvim_win_set_buf(target_win, base_buf)

  local head_win = nil
  if existing_head then
    local current_tab = vim.api.nvim_win_get_tabpage(target_win)
    local existing_head_window = find_window_for_buffer(existing_head, current_tab)
    if existing_head_window and existing_head_window.winid ~= target_win then
      head_win = existing_head_window.winid
      pcall(vim.api.nvim_win_close, head_win, true)
      head_win = nil
    end
  end

  if not head_win then
    pcall(vim.api.nvim_set_current_win, target_win)
    if render_mode == "horizontal" then
      vim.cmd("belowright split")
    else
      vim.cmd("vsplit")
    end
    head_win = vim.api.nvim_get_current_win()
  end

  local head_comment_ctx = data.is_non_text and nil or build_comment_ctx(opts.line_comments, "head", {
    data.head_path,
    data.base_path,
    file.path,
    file.filename,
    file.previousFilename,
    file.previous_filename,
  })
  local head_buf = open_buffer(
    data.head_content,
    data.head_path,
    "head",
    details,
    pr,
    data.repo,
    head_comment_ctx,
      canonical_path,
      {
        existing_bufnr = existing_head,
        file_mode = "diff_pair",
        asset_kind = data.is_image and "image" or nil,
        image_side = "head",
        image_asset = data.head_asset,
        image_reason = "",
      file_status = data.status,
      images = data.image_options,
      image_base_path = data.base_path,
      image_head_path = data.head_path,
      pr_url = type(details.url) == "string" and details.url or (type(pr.url) == "string" and pr.url or ""),
    }
  )
  vim.api.nvim_win_set_buf(head_win, head_buf)

  if data.is_image then
    clear_diff_window_state(target_win)
    clear_diff_window_state(head_win)
    render_image_in_window(base_buf, target_win, details, pr, "base", data.status, data.base_asset, data.image_options)
    render_image_in_window(head_buf, head_win, details, pr, "head", data.status, data.head_asset, data.image_options)
    apply_window_whitespace_render(target_win, false)
    apply_window_whitespace_render(head_win, false)
    apply_window_endline_render(target_win, false)
    apply_window_endline_render(head_win, false)
  else
    pcall(vim.api.nvim_set_current_win, target_win)
    vim.cmd("diffthis")
    pcall(vim.api.nvim_set_current_win, head_win)
    vim.cmd("diffthis")
    apply_window_diffopt(target_win, diff_view.ignore_whitespace)
    apply_window_diffopt(head_win, diff_view.ignore_whitespace)
    apply_window_whitespace_render(target_win, diff_view.render_whitespace)
    apply_window_whitespace_render(head_win, diff_view.render_whitespace)
    apply_window_endline_render(target_win, diff_view.render_endlines)
    apply_window_endline_render(head_win, diff_view.render_endlines)
    apply_diff_window_sync(target_win, head_win)
  end
  pcall(vim.api.nvim_set_current_win, target_win)

  return { base_buf = base_buf, head_buf = head_buf, mode = render_mode, file_mode = "diff_pair" }, nil
end

function M.open_commit_patch(details, pr, commit, opts)
  opts = opts or {}
  local content, path, err = build_commit_patch_text(commit)
  if not content then
    return nil, err
  end

  local repo = resolve_base_repository(details)
  local canonical_path = normalize_path(path)
  local existing_patch = resolve_existing_buffer(repo, pr.number, canonical_path, "patch")

  if existing_patch and focus_existing_buffer(existing_patch) then
    -- keep current window
  elseif opts.new_tab ~= false then
    vim.cmd("tabnew")
  end

  local patch_buf = open_buffer(content, path, "patch", details, pr, repo, nil, canonical_path, {
    existing_bufnr = existing_patch,
  })
  vim.b[patch_buf].gh_pr_commit_oid = commit.oid
  vim.b[patch_buf].gh_pr_commit_url = commit.url
  vim.b[patch_buf].gh_pr_commit_headline = commit.headline
  vim.api.nvim_win_set_buf(0, patch_buf)
  return patch_buf, nil
end

local function find_file_in_details(details, path)
  local target = normalize_path(path)
  if target == "" then
    return nil
  end

  for _, file in ipairs(type(details.files) == "table" and details.files or {}) do
    if normalize_path(file.path) == target
      or normalize_path(file.filename) == target
      or normalize_path(file.previousFilename) == target
      or normalize_path(file.previous_filename) == target then
      return file
    end
  end

  return nil
end

local function safe_set_buffer_name(bufnr, name)
  if type(name) ~= "string" or name == "" then
    return false
  end

  local current_name = vim.api.nvim_buf_get_name(bufnr)
  if current_name == name then
    return true
  end

  local existing = vim.fn.bufnr(name)
  if type(existing) == "number" and existing > 0 and existing ~= bufnr and vim.api.nvim_buf_is_valid(existing) then
    return false
  end

  local ok = pcall(vim.api.nvim_buf_set_name, bufnr, name)
  return ok
end

local function update_virtual_buffer(bufnr, details, number, kind, path)
  local file = find_file_in_details(details, path)
  if not file then
    return false, "missing-file"
  end

  local pr = { number = number }
  local data, err = read_base_and_head(details, pr, file)
  if not data then
    return false, err
  end

  local repository = data.repo or resolve_base_repository(details)
  local pr_url = type(details) == "table" and type(details.url) == "string" and details.url or ""
  if pr_url ~= "" then
    pr_url = pr_url:gsub("/+$", "")
  end
  local pr_files_url = pr_url ~= "" and (pr_url:find("/files$", 1, true) and pr_url or (pr_url .. "/files")) or ""
  local next_path
  local content
  local image_asset = nil
  local image_side = kind
  local is_image_buffer = false
  local line_highlights = nil
  local unified_line_map = nil
  local endline_map = nil
  local file_mode = data.file_mode == "added_single" and "added_single"
    or (data.file_mode == "removed_single" and "removed_single" or "diff_pair")
  if kind == "base" then
    if file_mode == "added_single" then
      next_path = data.head_path
      content = data.head_content or ""
      image_asset = data.head_asset
      image_side = "head"
    else
      next_path = data.base_path
      content = data.base_content or ""
      image_asset = data.base_asset
      image_side = "base"
    end
  elseif kind == "unified" then
    next_path = data.head_path or data.base_path
    if data.is_image then
      content = ""
      image_asset = data.head_asset.is_image and data.head_asset or data.base_asset
      image_side = image_asset == data.base_asset and "base" or "head"
      is_image_buffer = true
      file_mode = "unified"
    else
      local diff_view = M.resolve_diff_view_options()
      content, line_highlights, unified_line_map =
        build_unified_diff_text(data.base_content or "", data.head_content or "", diff_view.ignore_whitespace)
      file_mode = "unified"
    end
  else
    if file_mode == "removed_single" then
      next_path = data.base_path
      content = data.base_content or ""
      image_asset = data.base_asset
      image_side = "base"
    else
      next_path = data.head_path
      content = data.head_content or ""
      image_asset = data.head_asset
      image_side = "head"
    end
  end

  if data.asset_kind == "asset" then
    local preview_file_mode = kind == "unified" and "unified" or file_mode
    local binary_preview = build_binary_preview_payload(data, image_side, next_path, "")
    open_buffer("", next_path, kind, details, pr, repository, nil, canonical_path, {
      existing_bufnr = bufnr,
      filetype = "markdown",
      file_mode = preview_file_mode,
      asset_kind = "binary",
      image_side = image_side,
      image_reason = "",
      file_status = data.status,
      images = data.image_options,
      image_base_path = data.base_path,
      image_head_path = data.head_path,
      preview_lines = binary_preview.preview_lines,
      asset_actions = binary_preview.asset_actions,
      base_preview_entry = binary_preview.base_preview_entry,
      head_preview_entry = binary_preview.head_preview_entry,
      pr_url = pr_url,
    })
    for _, win in ipairs(windows_showing_buffer(bufnr)) do
      clear_diff_window_state(win.winid)
      apply_window_whitespace_render(win.winid, false)
      apply_window_endline_render(win.winid, false)
    end
    return true, nil
  end

  if not is_image_buffer then
    is_image_buffer = data.is_image and type(image_asset) == "table" and image_asset.is_image == true
  end

  if type(next_path) ~= "string" or next_path == "" then
    return false, "missing-file"
  end

  local lines
  if is_image_buffer then
    lines = image_renderer.build_placeholder_lines({
      path = next_path,
      side = image_side,
      status = data.status,
      size = type(image_asset) == "table" and image_asset.size or nil,
      sha = type(image_asset) == "table" and image_asset.sha or nil,
      show_metadata = type(data.image_options) == "table" and data.image_options.show_metadata ~= false,
      reason = "",
    })
  else
    lines, endline_map = split_buffer_text_with_endings(content or "")
  end
  set_buffer_content(bufnr, lines)
  apply_line_highlights(bufnr, is_image_buffer and nil or line_highlights)

  local filetype = is_image_buffer and "markdown" or (kind == "unified" and "diff" or resolve_path_filetype(next_path))
  vim.api.nvim_buf_set_option(bufnr, "filetype", filetype)
  vim.b[bufnr].gh_pr_path = next_path
  local canonical_path = normalize_path(file.path or file.filename)
  vim.b[bufnr].gh_pr_file_path = canonical_path ~= "" and canonical_path or nil
  vim.b[bufnr].gh_pr_file_mode = file_mode
  vim.b[bufnr].gh_pr_diff_backend = "virtual"
  vim.b[bufnr].gh_pr_is_image = is_image_buffer
  vim.b[bufnr].gh_pr_image_side = is_image_buffer and image_side or nil
  vim.b[bufnr].gh_pr_image_status = is_image_buffer and data.status or nil
  vim.b[bufnr].gh_pr_image_reason = is_image_buffer and "" or nil
  vim.b[bufnr].gh_pr_image_cache_path = nil
  vim.b[bufnr].gh_pr_pr_url = pr_url ~= "" and pr_url or nil
  vim.b[bufnr].gh_pr_pr_files_url = pr_files_url ~= "" and pr_files_url or nil
  vim.b[bufnr].gh_pr_image_base_path = is_image_buffer and data.base_path or nil
  vim.b[bufnr].gh_pr_image_head_path = is_image_buffer and data.head_path or nil
  vim.b[bufnr].gh_pr_image_size = is_image_buffer and type(image_asset) == "table" and tonumber(image_asset.size or 0) or nil
  vim.b[bufnr].gh_pr_image_sha = is_image_buffer and type(image_asset) == "table" and image_asset.sha or nil
  vim.b[bufnr].gh_pr_image_ext = is_image_buffer and type(image_asset) == "table" and image_asset.ext or nil
  vim.b[bufnr].gh_pr_image_fallback = is_image_buffer and false or nil
  vim.b[bufnr].gh_pr_image_fallback_notified_reason = nil
  vim.b[bufnr].gh_pr_unified_line_map = nil
  vim.b[bufnr].gh_pr_endline_map = is_image_buffer and nil or endline_map
  if (not is_image_buffer) and kind == "unified" and type(unified_line_map) == "table" then
    vim.b[bufnr].gh_pr_unified_line_map = unified_line_map
    apply_unified_syntax_highlights(bufnr, canonical_path ~= "" and canonical_path or next_path, unified_line_map)
  else
    clear_extmark_namespaces(bufnr, { "unified_syntax" })
  end

  apply_buffer_mode_cleanup(bufnr, {
    is_image = is_image_buffer,
    images = data.image_options,
  })

  if is_image_buffer then
    for _, win in ipairs(windows_showing_buffer(bufnr)) do
      render_image_in_window(bufnr, win.winid, details, pr, image_side, data.status, image_asset, data.image_options)
    end
  else
    local diff_view = M.resolve_diff_view_options()
    for _, win in ipairs(windows_showing_buffer(bufnr)) do
      apply_window_whitespace_render(win.winid, diff_view.render_whitespace)
      apply_window_endline_render(win.winid, diff_view.render_endlines)
    end
  end

  if repository then
    vim.b[bufnr].gh_pr_repo = repository.full_name
    local uri_path = canonical_path ~= "" and canonical_path or next_path
    local uri = virtual_uri(kind, repository, number, uri_path)
    safe_set_buffer_name(bufnr, uri)
  end

  return true, nil
end

local function remove_buffer(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
end

function M.sync_visible_pr_buffers(details_by_pr, opts)
  opts = opts or {}
  local repository_filter = type(opts.repository) == "string" and opts.repository or nil
  local removed = {}

  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_is_loaded(bufnr) then
      local number = vim.b[bufnr].gh_pr_number
      local kind = vim.b[bufnr].gh_pr_file_kind
      local path = vim.b[bufnr].gh_pr_path
      local repository = vim.b[bufnr].gh_pr_repo

      if type(number) == "number"
        and (kind == "base" or kind == "head" or kind == "unified")
        and type(path) == "string"
        and path ~= "" then
        if not repository_filter or repository_filter == repository then
          local details = details_by_pr[tostring(number)]
          if type(details) == "table" then
            local updated, update_err = update_virtual_buffer(bufnr, details, number, kind, path)
            if not updated and update_err == "missing-file" then
              removed[#removed + 1] = string.format("PR #%d %s", number, path)
              remove_buffer(bufnr)
            end
          end
        end
      end
    end
  end

  if #removed > 0 then
    vim.notify(
      string.format("gh-pr: closed %d virtual buffer(s) because files were removed from the PR", #removed),
      vim.log.levels.INFO
    )
  end
end

function M.load_remote_file_pair(details, file)
  return read_base_and_head(details, nil, file)
end

function M.load_remote_file_pair_async(details, file, callback)
  return read_base_and_head_async(details, nil, file, callback)
end

return M
