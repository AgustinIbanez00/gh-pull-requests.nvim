local NonTextPreview = {
  menu_state = nil,
}

local config = require("gh-pr.config")
local coerce = require("gh-pr.core.coerce")
local gh = require("gh-pr.gh")
local image_metadata = require("gh-pr.image_metadata")
local image_renderer = require("gh-pr.image_renderer")
local notify = require("gh-pr.core.notify")
local repository = require("gh-pr.core.repository")
local review_context = require("gh-pr.core.review_context")
local state = require("gh-pr.state")
local url_open = require("gh-pr.url_open")
local virtual_files = require("gh-pr.virtual_files")
local uv = vim.uv or vim.loop

local non_text_preview = NonTextPreview
local positive_integer = coerce.positive_integer
local safe_string = coerce.safe_string

local runtime = {
  diff_view_shortcuts = nil,
  resolve_active_pr = nil,
}

local function notify_error(err)
  if err then
    notify.error(err)
  end
end

local function notify_info(message)
  notify.info(message)
end

local function notify_warn(message)
  notify.warn(message)
end

local function normalize_path(path)
  return review_context.normalize_path(path)
end

local function is_valid_buf(bufnr)
  return type(bufnr) == "number" and bufnr > 0 and vim.api.nvim_buf_is_valid(bufnr)
end

local function is_valid_win(winid)
  return type(winid) == "number" and winid > 0 and vim.api.nvim_win_is_valid(winid)
end

local function sanitize_modal_window(winid)
  if not is_valid_win(winid) then
    return
  end
  vim.api.nvim_set_option_value("number", false, { win = winid })
  vim.api.nvim_set_option_value("relativenumber", false, { win = winid })
  vim.api.nvim_set_option_value("signcolumn", "no", { win = winid })
  vim.api.nvim_set_option_value("foldcolumn", "0", { win = winid })
end

local function diff_view_shortcuts(...)
  local resolver = runtime.diff_view_shortcuts
  if type(resolver) ~= "function" then
    error("gh-pr.actions.non_text_preview is not registered: missing diff_view_shortcuts")
  end
  return resolver(...)
end

local function resolve_active_pr(...)
  local resolver = runtime.resolve_active_pr
  if type(resolver) ~= "function" then
    error("gh-pr.actions.non_text_preview is not registered: missing resolve_active_pr")
  end
  return resolver(...)
end
local local_open_policy_values = {
  disabled = true,
  reveal_only = true,
  system = true,
}

local dangerous_local_open_extensions = {
  app = true,
  bat = true,
  cmd = true,
  com = true,
  command = true,
  cpl = true,
  desktop = true,
  exe = true,
  hta = true,
  inf = true,
  ins = true,
  isp = true,
  jar = true,
  js = true,
  jse = true,
  lnk = true,
  msc = true,
  msi = true,
  msp = true,
  mst = true,
  pif = true,
  ps1 = true,
  ps1xml = true,
  psd1 = true,
  psm1 = true,
  reg = true,
  scf = true,
  scr = true,
  sh = true,
  url = true,
  vb = true,
  vbe = true,
  vbs = true,
  wsf = true,
  wsh = true,
}

local function normalize_local_open_policy(value, fallback)
  local policy = type(value) == "string" and value:lower() or fallback or "disabled"
  if local_open_policy_values[policy] then
    return policy
  end
  return fallback or "disabled"
end

local function target_extension(target)
  local ext = type(target) == "string" and target:match("%.([^.\\/]+)$") or nil
  if type(ext) ~= "string" then
    return ""
  end
  return ext:lower()
end

local function effective_local_open_policy(policy, target)
  local normalized = normalize_local_open_policy(policy, "disabled")
  if normalized ~= "system" then
    return normalized
  end

  local ext = target_extension(target)
  if ext ~= "" and dangerous_local_open_extensions[ext] then
    return "reveal_only"
  end

  return normalized
end

local function local_open_action_label(policy, target)
  local effective = effective_local_open_policy(policy, target)
  if effective == "reveal_only" then
    return "reveal local"
  end
  return "open local"
end

local function local_open_action_phrase(policy, target)
  local effective = effective_local_open_policy(policy, target)
  if effective == "reveal_only" then
    return "reveal locally"
  end
  return "open locally"
end

non_text_preview.dangerous_local_open_extensions = vim.deepcopy(dangerous_local_open_extensions)
non_text_preview.normalize_local_open_policy = normalize_local_open_policy
non_text_preview.effective_local_open_policy = effective_local_open_policy
non_text_preview.action_labels = {
  metadata = "Show metadata/actions in buffer",
  open_local_current = "Open current revision locally",
  open_local_both = "Open both revisions locally",
  open_github = "Open GitHub PR file view",
}

non_text_preview.reveal_action_labels = {
  open_local_current = "Reveal current revision locally",
  open_local_both = "Reveal both revisions locally",
}

non_text_preview.action_order = {
  "open_local_current",
  "open_local_both",
  "open_github",
  "metadata",
}

function non_text_preview.is_valid_image_action(action)
  return action == "metadata" or action == "open_local_current" or action == "open_local_both" or action == "open_github"
end

function non_text_preview.normalize_image_action(action, fallback)
  local value = type(action) == "string" and action:lower() or ""
  if non_text_preview.is_valid_image_action(value) then
    return value
  end
  local default_value = type(fallback) == "string" and fallback:lower() or "metadata"
  if non_text_preview.is_valid_image_action(default_value) then
    return default_value
  end
  return "metadata"
end

function non_text_preview.action_label(action, opts)
  local normalized = non_text_preview.normalize_image_action(action, "metadata")
  if normalized == "open_local_current" or normalized == "open_local_both" then
    local policy = nil
    if type(opts) == "table" then
      policy = opts.fallback_open_local or opts.open_local
    end
    local normalized_policy = normalize_local_open_policy(policy, "disabled")
    if normalized_policy == "disabled" then
      return (non_text_preview.action_labels[normalized] or normalized) .. " (disabled)"
    end
    if normalized_policy == "reveal_only" then
      return non_text_preview.reveal_action_labels[normalized] or non_text_preview.action_labels[normalized] or normalized
    end
  end
  return non_text_preview.action_labels[normalized] or normalized
end

function non_text_preview.image_diff_options()
  local diff_view = (config.get() or {}).diff_view or {}
  local images = type(diff_view.images) == "table" and diff_view.images or {}
  local external_command = {}
  for _, token in ipairs(type(images.metadata_external_command) == "table" and images.metadata_external_command or {}) do
    if type(token) == "string" and token ~= "" then
      external_command[#external_command + 1] = token
    end
  end
  if vim.tbl_isempty(external_command) then
    external_command = { "magick", "identify", "-format", "%w %h", "{file}" }
  end

  return {
    fallback_mode = type(images.fallback_mode) == "string" and images.fallback_mode:lower() or "menu",
    fallback_default_action = non_text_preview.normalize_image_action(images.fallback_default_action, "metadata"),
    fallback_menu_keymap = type(images.fallback_menu_keymap) == "string" and images.fallback_menu_keymap or "gf",
    fallback_open_local = normalize_local_open_policy(images.fallback_open_local, "disabled"),
    fallback_github_target = type(images.fallback_github_target) == "string"
        and images.fallback_github_target:lower()
      or "pr_files",
    metadata_resolution_strategy = type(images.metadata_resolution_strategy) == "string"
        and images.metadata_resolution_strategy:lower()
      or "hybrid",
    metadata_external_command = external_command,
  }
end

function non_text_preview.options()
  local diff_view = (config.get() or {}).diff_view or {}
  local non_text = type(diff_view.non_text) == "table" and diff_view.non_text or {}
  return {
    enabled = non_text.enabled ~= false,
    auto_preview = non_text.auto_preview ~= false,
    show_metadata = non_text.show_metadata ~= false,
  }
end

function non_text_preview.resolve_default_action(images_cfg)
  local fallback = type(images_cfg) == "table" and images_cfg.fallback_default_action or "metadata"
  local action = non_text_preview.normalize_image_action(fallback, "metadata")
  if type(state.get_image_prefs) == "function" then
    local prefs = state.get_image_prefs()
    if type(prefs) == "table" then
      action = non_text_preview.normalize_image_action(prefs.fallback_default_action, action)
    end
  end
  if (action == "open_local_current" or action == "open_local_both")
    and normalize_local_open_policy(type(images_cfg) == "table" and images_cfg.fallback_open_local or nil, "disabled") == "disabled" then
    return "metadata"
  end
  return action
end

function non_text_preview.persist_default_action(action)
  local normalized = non_text_preview.normalize_image_action(action, "metadata")
  if type(state.update_image_pref) == "function" then
    state.update_image_pref("fallback_default_action", normalized)
    return true
  end
  if type(state.set_image_prefs) == "function" then
    local current = type(state.get_image_prefs) == "function" and state.get_image_prefs() or {}
    current.fallback_default_action = normalized
    state.set_image_prefs(current)
    return true
  end
  return false
end

function non_text_preview.classify_target(file)
  local non_text = non_text_preview.options()
  if non_text.enabled ~= true or non_text.auto_preview ~= true then
    return "text"
  end
  if type(virtual_files.classify_file) ~= "function" then
    return "text"
  end
  local kind = virtual_files.classify_file(file)
  if kind == "image" or kind == "asset" then
    return kind
  end
  return "text"
end

function non_text_preview.file_uses_non_text_preview(file)
  local kind = non_text_preview.classify_target(file)
  return kind == "image" or kind == "asset", kind
end

local function file_readable(path)
  return type(path) == "string" and path ~= "" and vim.fn.filereadable(path) == 1
end

local function trim_trailing_slash(url)
  if type(url) ~= "string" then
    return ""
  end
  return url:gsub("/+$", "")
end

function non_text_preview.current_side(ctx)
  local side = type(ctx.side) == "string" and ctx.side or ""
  if side == "base" or side == "head" then
    return side
  end
  if ctx.status == "removed" then
    return "base"
  end
  return "head"
end

function non_text_preview.side_present_for_status(status, side)
  if status == "added" and side == "base" then
    return false
  end
  if status == "removed" and side == "head" then
    return false
  end
  return true
end

function non_text_preview.path_for_side(ctx, side)
  local side_path = ""
  if side == "base" then
    side_path = normalize_path(ctx.base_path or "")
  elseif side == "head" then
    side_path = normalize_path(ctx.head_path or "")
  end
  if side_path ~= "" then
    return side_path
  end
  return normalize_path(ctx.file_path or ctx.path or "")
end

local function parse_repo_full_name(full_name)
  return repository.parse_full_name(full_name)
end

local function extract_repo_info(repo)
  return repository.parse(repo)
end

function non_text_preview.resolve_side_repository(details, side, fallback_full_name)
  local base_repo = extract_repo_info(type(details) == "table" and details.baseRepository or nil)
  local head_repo = extract_repo_info(type(details) == "table" and details.headRepository or nil) or base_repo
  if side == "base" then
    return base_repo or head_repo or parse_repo_full_name(fallback_full_name)
  end
  return head_repo or base_repo or parse_repo_full_name(fallback_full_name)
end

function non_text_preview.resolve_buffer_context(bufnr)
  bufnr = type(bufnr) == "number" and bufnr or vim.api.nvim_get_current_buf()
  if not is_valid_buf(bufnr) then
    return nil, "Invalid buffer"
  end
  local is_image = vim.b[bufnr].gh_pr_is_image == true
  local is_non_text = vim.b[bufnr].gh_pr_is_non_text == true or is_image
  if not is_non_text then
    return nil, "Current buffer is not a non-text diff buffer"
  end

  local number = tonumber(vim.b[bufnr].gh_pr_number)
  if not number then
    return nil, "Unable to resolve pull request number for non-text buffer"
  end

  local preview = type(vim.b[bufnr].gh_pr_asset_preview) == "table" and vim.deepcopy(vim.b[bufnr].gh_pr_asset_preview) or {}
  local asset_kind = type(preview.asset_kind) == "string" and preview.asset_kind
    or (type(vim.b[bufnr].gh_pr_asset_kind) == "string" and vim.b[bufnr].gh_pr_asset_kind or (is_image and "image" or "binary"))
  if asset_kind ~= "image" and asset_kind ~= "binary" then
    asset_kind = is_image and "image" or "binary"
  end

  local status = type(vim.b[bufnr].gh_pr_asset_status) == "string"
      and vim.b[bufnr].gh_pr_asset_status:lower()
    or (type(vim.b[bufnr].gh_pr_image_status) == "string" and vim.b[bufnr].gh_pr_image_status:lower() or "")
  local current_side = type(vim.b[bufnr].gh_pr_asset_side) == "string" and vim.b[bufnr].gh_pr_asset_side
    or (type(vim.b[bufnr].gh_pr_image_side) == "string" and vim.b[bufnr].gh_pr_image_side or "")

  local function ensure_preview_side(side)
    local entry = type(preview[side]) == "table" and preview[side] or {}
    local image_path = side == "base" and vim.b[bufnr].gh_pr_image_base_path or vim.b[bufnr].gh_pr_image_head_path
    local default_path = normalize_path(type(entry.path) == "string" and entry.path ~= "" and entry.path or image_path or "")
    local present = entry.present
    if type(present) ~= "boolean" then
      present = non_text_preview.side_present_for_status(status, side)
    end
    entry.side = side
    entry.present = present
    entry.path = default_path
    entry.size = tonumber(entry.size) or ((side == current_side) and (tonumber(vim.b[bufnr].gh_pr_image_size) or 0) or 0)
    entry.sha = type(entry.sha) == "string" and entry.sha or ((side == current_side) and safe_string(vim.b[bufnr].gh_pr_image_sha) or "")
    entry.ext = type(entry.ext) == "string" and entry.ext or ((side == current_side) and safe_string(vim.b[bufnr].gh_pr_image_ext):lower() or "")
    entry.cache_path = type(entry.cache_path) == "string" and entry.cache_path or ((side == current_side) and safe_string(vim.b[bufnr].gh_pr_image_cache_path) or "")
    preview[side] = entry
    return entry
  end

  local base_entry = ensure_preview_side("base")
  local head_entry = ensure_preview_side("head")

  return {
    bufnr = bufnr,
    number = number,
    asset_kind = asset_kind,
    is_image = asset_kind == "image",
    is_non_text = true,
    repo = type(vim.b[bufnr].gh_pr_repo) == "string" and vim.b[bufnr].gh_pr_repo or "",
    kind = type(vim.b[bufnr].gh_pr_file_kind) == "string" and vim.b[bufnr].gh_pr_file_kind or "",
    file_path = normalize_path(vim.b[bufnr].gh_pr_file_path or ""),
    path = normalize_path(vim.b[bufnr].gh_pr_path or ""),
    side = current_side,
    status = status,
    reason = type(vim.b[bufnr].gh_pr_image_reason) == "string" and vim.b[bufnr].gh_pr_image_reason
      or (type(preview.reason) == "string" and preview.reason or ""),
    pr_url = trim_trailing_slash(vim.b[bufnr].gh_pr_pr_url),
    pr_files_url = trim_trailing_slash(vim.b[bufnr].gh_pr_pr_files_url),
    base_path = base_entry.path,
    head_path = head_entry.path,
    cache_path = type(vim.b[bufnr].gh_pr_image_cache_path) == "string" and vim.b[bufnr].gh_pr_image_cache_path or "",
    size = tonumber(vim.b[bufnr].gh_pr_image_size) or 0,
    sha = type(vim.b[bufnr].gh_pr_image_sha) == "string" and vim.b[bufnr].gh_pr_image_sha or "",
    ext = type(vim.b[bufnr].gh_pr_image_ext) == "string" and vim.b[bufnr].gh_pr_image_ext:lower() or "",
    preview = preview,
  }, nil
end

function non_text_preview.resolve_image_buffer_context(bufnr)
  local ctx, err = non_text_preview.resolve_buffer_context(bufnr)
  if not ctx then
    return nil, err
  end
  if ctx.asset_kind ~= "image" then
    return nil, "Current buffer is not an image diff buffer"
  end
  return ctx, nil
end

function non_text_preview.find_cached_image_asset(ctx, side)
  if side == ctx.side and file_readable(ctx.cache_path) then
    return {
      side = side,
      path = non_text_preview.path_for_side(ctx, side),
      cache_path = ctx.cache_path,
      size = ctx.size,
      sha = ctx.sha,
      ext = ctx.ext,
    }
  end

  local target_path = normalize_path(ctx.file_path ~= "" and ctx.file_path or ctx.path)
  for _, candidate in ipairs(vim.api.nvim_list_bufs()) do
    if candidate ~= ctx.bufnr and is_valid_buf(candidate) and vim.b[candidate].gh_pr_is_image == true then
      local candidate_number = tonumber(vim.b[candidate].gh_pr_number)
      local candidate_side = type(vim.b[candidate].gh_pr_image_side) == "string"
          and vim.b[candidate].gh_pr_image_side
        or (type(vim.b[candidate].gh_pr_file_kind) == "string" and vim.b[candidate].gh_pr_file_kind or "")
      local candidate_path = normalize_path(vim.b[candidate].gh_pr_file_path or vim.b[candidate].gh_pr_path or "")
      local same_number = candidate_number == ctx.number
      local same_path = target_path == "" or candidate_path == "" or candidate_path == target_path
      local cache_path = type(vim.b[candidate].gh_pr_image_cache_path) == "string" and vim.b[candidate].gh_pr_image_cache_path or ""
      if same_number and same_path and candidate_side == side and file_readable(cache_path) then
        return {
          side = side,
          path = normalize_path(side == "base" and (vim.b[candidate].gh_pr_image_base_path or vim.b[candidate].gh_pr_path or "")
            or (vim.b[candidate].gh_pr_image_head_path or vim.b[candidate].gh_pr_path or "")),
          cache_path = cache_path,
          size = tonumber(vim.b[candidate].gh_pr_image_size) or 0,
          sha = type(vim.b[candidate].gh_pr_image_sha) == "string" and vim.b[candidate].gh_pr_image_sha or "",
          ext = type(vim.b[candidate].gh_pr_image_ext) == "string" and vim.b[candidate].gh_pr_image_ext:lower() or "",
        }
      end
    end
  end

  return nil
end

function non_text_preview.fetch_and_cache_image_asset(details, ctx, side, images_cfg)
  local side_path = non_text_preview.path_for_side(ctx, side)
  if side_path == "" then
    return nil, string.format("Missing %s image path", side)
  end

  local side_ref = side == "base" and details.baseRefName or details.headRefName
  if type(side_ref) ~= "string" or side_ref == "" then
    return nil, string.format("Missing %s ref for pull request", side)
  end

  local repository = non_text_preview.resolve_side_repository(details, side, ctx.repo)
  if not repository then
    return nil, string.format("Unable to resolve %s repository", side)
  end

  local api = string.format(
    "repos/%s/%s/contents/%s?ref=%s",
    repository.owner,
    repository.name,
    encode_path(side_path),
    url_encode(side_ref)
  )
  local payload, payload_err = gh.run_json({ "api", api })
  if not payload then
    return nil, payload_err
  end

  local encoding = type(payload.encoding) == "string" and payload.encoding or ""
  local content = type(payload.content) == "string" and payload.content or ""
  if encoding ~= "base64" or content == "" then
    return nil, string.format("Unable to decode %s image bytes from GitHub contents API", side)
  end

  local bytes = decode_base64(content)
  if bytes == "" then
    return nil, string.format("Unable to decode %s image bytes from base64 payload", side)
  end

  local size = tonumber(payload.size) or #bytes
  local sha = type(payload.sha) == "string" and payload.sha or ""
  local ext = normalize_path(side_path):match("%.([^.]+)$")
  ext = type(ext) == "string" and ext:lower() or ""

  local cache_path, cache_err = image_renderer.ensure_cache({
    repository = repository.full_name,
    pr_number = ctx.number,
    side = side,
    path = side_path,
    sha = sha,
    size = size,
    bytes = bytes,
    images = images_cfg,
  })
  if not cache_path then
    return nil, cache_err
  end

  return {
    side = side,
    path = side_path,
    cache_path = cache_path,
    size = size,
    sha = sha,
    ext = ext,
  }, nil
end

function non_text_preview.ensure_image_side_asset(ctx, side, images_cfg)
  if not non_text_preview.side_present_for_status(ctx.status, side) then
    return {
      side = side,
      present = false,
      path = non_text_preview.path_for_side(ctx, side),
    }, nil
  end

  local cached = non_text_preview.find_cached_image_asset(ctx, side)
  if cached then
    cached.present = true
    return cached, nil
  end

  local _, details, details_err = resolve_active_pr(ctx.number, { refresh = false })
  if not details then
    return nil, details_err
  end

  local fetched, fetch_err = non_text_preview.fetch_and_cache_image_asset(details, ctx, side, images_cfg)
  if not fetched then
    return nil, fetch_err
  end

  fetched.present = true
  if side == ctx.side and is_valid_buf(ctx.bufnr) then
    vim.b[ctx.bufnr].gh_pr_image_cache_path = fetched.cache_path
    vim.b[ctx.bufnr].gh_pr_image_size = tonumber(fetched.size) or 0
    vim.b[ctx.bufnr].gh_pr_image_sha = fetched.sha
    vim.b[ctx.bufnr].gh_pr_image_ext = fetched.ext
  end
  return fetched, nil
end

function non_text_preview.cached_binary_side_asset(ctx, side)
  local entry = type(ctx.preview) == "table" and type(ctx.preview[side]) == "table" and ctx.preview[side] or nil
  if entry and file_readable(entry.cache_path) then
    return {
      side = side,
      present = entry.present ~= false,
      path = entry.path,
      cache_path = entry.cache_path,
      size = tonumber(entry.size) or 0,
      sha = type(entry.sha) == "string" and entry.sha or "",
      ext = type(entry.ext) == "string" and entry.ext or "",
    }
  end

  local target_path = normalize_path(ctx.file_path ~= "" and ctx.file_path or ctx.path)
  for _, candidate in ipairs(vim.api.nvim_list_bufs()) do
    if candidate ~= ctx.bufnr
      and is_valid_buf(candidate)
      and vim.b[candidate].gh_pr_is_non_text == true
      and vim.b[candidate].gh_pr_asset_kind == "binary" then
      local candidate_number = tonumber(vim.b[candidate].gh_pr_number)
      local candidate_path = normalize_path(vim.b[candidate].gh_pr_file_path or vim.b[candidate].gh_pr_path or "")
      if candidate_number == ctx.number and (candidate_path == "" or target_path == "" or candidate_path == target_path) then
        local preview = type(vim.b[candidate].gh_pr_asset_preview) == "table" and vim.b[candidate].gh_pr_asset_preview or {}
        local side_entry = type(preview[side]) == "table" and preview[side] or nil
        if side_entry and file_readable(side_entry.cache_path) then
          return {
            side = side,
            present = side_entry.present ~= false,
            path = normalize_path(side_entry.path),
            cache_path = side_entry.cache_path,
            size = tonumber(side_entry.size) or 0,
            sha = type(side_entry.sha) == "string" and side_entry.sha or "",
            ext = type(side_entry.ext) == "string" and side_entry.ext or "",
          }
        end
      end
    end
  end

  return nil
end

function non_text_preview.binary_asset_cache_path(ctx, side, path, sha)
  local repo_slug = sanitize_filename(ctx.repo ~= "" and ctx.repo or ("pr-" .. tostring(ctx.number)))
  local filename = sanitize_filename((path:match("([^/]+)$") or (side .. "-asset")))
  local cache_root = joinpath(vim.fn.stdpath("cache"), "gh-pr", "assets", repo_slug, tostring(ctx.number))
  if not non_text_preview.ensure_dir(cache_root) then
    return nil, "Unable to prepare binary asset cache directory"
  end
  local hash = type(sha) == "string" and sha ~= "" and sha:sub(1, 12) or "unknown"
  return joinpath(cache_root, string.format("%s-%s-%s", side, hash, filename)), nil
end

function non_text_preview.fetch_and_cache_binary_asset(details, ctx, side)
  local side_path = non_text_preview.path_for_side(ctx, side)
  if side_path == "" then
    return nil, string.format("Missing %s asset path", side)
  end

  local side_ref = side == "base" and details.baseRefName or details.headRefName
  if type(side_ref) ~= "string" or side_ref == "" then
    return nil, string.format("Missing %s ref for pull request", side)
  end

  local repository = non_text_preview.resolve_side_repository(details, side, ctx.repo)
  if not repository then
    return nil, string.format("Unable to resolve %s repository", side)
  end

  local api = string.format(
    "repos/%s/%s/contents/%s?ref=%s",
    repository.owner,
    repository.name,
    encode_path(side_path),
    url_encode(side_ref)
  )
  local payload, payload_err = gh.run_json({ "api", api })
  if not payload then
    return nil, payload_err
  end

  local encoding = type(payload.encoding) == "string" and payload.encoding or ""
  local content = type(payload.content) == "string" and payload.content or ""
  if encoding ~= "base64" or content == "" then
    return nil, string.format("Unable to decode %s asset bytes from GitHub contents API", side)
  end

  local bytes = non_text_preview.decode_base64(content)
  if bytes == "" then
    return nil, string.format("Unable to decode %s asset bytes from base64 payload", side)
  end

  local size = tonumber(payload.size) or #bytes
  local sha = type(payload.sha) == "string" and payload.sha or ""
  local ext = normalize_path(side_path):match("%.([^.]+)$")
  ext = type(ext) == "string" and ext:lower() or ""
  local cache_path, cache_err = non_text_preview.binary_asset_cache_path(ctx, side, side_path, sha)
  if not cache_path then
    return nil, cache_err
  end
  local ok_write, write_err = non_text_preview.write_binary_file(cache_path, bytes)
  if not ok_write then
    return nil, write_err
  end
  return {
    side = side,
    present = true,
    path = side_path,
    cache_path = cache_path,
    size = size,
    sha = sha,
    ext = ext,
  }, nil
end

function non_text_preview.ensure_binary_side_asset(ctx, side)
  if not non_text_preview.side_present_for_status(ctx.status, side) then
    return {
      side = side,
      present = false,
      path = non_text_preview.path_for_side(ctx, side),
    }, nil
  end

  local cached = non_text_preview.cached_binary_side_asset(ctx, side)
  if cached then
    return cached, nil
  end

  local _, details, details_err = resolve_active_pr(ctx.number, { refresh = false })
  if not details then
    return nil, details_err
  end

  local fetched, fetch_err = non_text_preview.fetch_and_cache_binary_asset(details, ctx, side)
  if not fetched then
    return nil, fetch_err
  end

  if is_valid_buf(ctx.bufnr) then
    local preview = type(vim.b[ctx.bufnr].gh_pr_asset_preview) == "table" and vim.deepcopy(vim.b[ctx.bufnr].gh_pr_asset_preview) or {}
    local entry = type(preview[side]) == "table" and preview[side] or {}
    entry.present = true
    entry.path = fetched.path
    entry.cache_path = fetched.cache_path
    entry.size = fetched.size
    entry.sha = fetched.sha
    entry.ext = fetched.ext
    preview[side] = entry
    vim.b[ctx.bufnr].gh_pr_asset_preview = preview
  end
  return fetched, nil
end

function non_text_preview.ensure_side_asset(ctx, side, images_cfg)
  if ctx.asset_kind == "image" then
    return non_text_preview.ensure_image_side_asset(ctx, side, images_cfg)
  end
  return non_text_preview.ensure_binary_side_asset(ctx, side)
end

local function try_detached_command(command)
  local executable = type(command) == "table" and command[1] or nil
  if type(executable) ~= "string" or executable == "" then
    return false, "invalid command"
  end
  if vim.fn.executable(executable) ~= 1 then
    return false, executable .. " is unavailable"
  end

  local ok_job, jobid = pcall(vim.fn.jobstart, command, { detach = true })
  if ok_job and type(jobid) == "number" and jobid > 0 then
    return true, nil
  end
  return false, executable .. " failed to start"
end

local function local_target_directory(target)
  if type(target) ~= "string" or target == "" then
    return ""
  end
  if vim.fn.isdirectory(target) == 1 then
    return target
  end
  if vim.fs and type(vim.fs.dirname) == "function" then
    return vim.fs.dirname(target) or ""
  end
  return target:match("^(.*)[/\\][^/\\]+$") or ""
end

local function try_local_system_open(target)
  local ui_err = nil
  if vim.ui and type(vim.ui.open) == "function" then
    local ok, open_result, open_err = pcall(vim.ui.open, target)
    if ok then
      if open_result ~= false and not (open_result == nil and type(open_err) == "string" and open_err ~= "") then
        return true, nil
      end
      ui_err = type(open_err) == "string" and open_err ~= "" and open_err or "vim.ui.open returned without opening target"
    else
      ui_err = tostring(open_result)
    end
  else
    ui_err = "vim.ui.open is unavailable in this Neovim build"
  end

  local is_windows = vim.fn.has("win32") == 1 or vim.fn.has("win64") == 1
  local is_mac = vim.fn.has("mac") == 1 or vim.fn.has("macunix") == 1
  local commands = {}
  if is_windows then
    commands = {
      { "rundll32", "url.dll,FileProtocolHandler", target },
      { "explorer.exe", target },
    }
  elseif is_mac then
    commands = {
      { "open", target },
    }
  else
    commands = {
      { "xdg-open", target },
    }
  end

  local errors = {}
  for _, command in ipairs(commands) do
    local ok_open, open_err = try_detached_command(command)
    if ok_open then
      return true, nil
    end
    if type(open_err) == "string" and open_err ~= "" then
      errors[#errors + 1] = open_err
    end
  end

  if type(ui_err) == "string" and ui_err ~= "" then
    table.insert(errors, 1, "vim.ui.open failed: " .. ui_err)
  end
  if vim.tbl_isempty(errors) then
    return false, "Unable to open target using system opener"
  end
  return false, table.concat(errors, " | ")
end

local function try_reveal_local_target(target)
  local is_windows = vim.fn.has("win32") == 1 or vim.fn.has("win64") == 1
  local is_mac = vim.fn.has("mac") == 1 or vim.fn.has("macunix") == 1
  local directory = local_target_directory(target)
  local commands = {}

  if is_windows then
    commands = {
      { "explorer.exe", "/select," .. target },
    }
    if directory ~= "" and directory ~= target then
      commands[#commands + 1] = { "explorer.exe", directory }
    end
  elseif is_mac then
    commands = {
      { "open", "-R", target },
    }
    if directory ~= "" and directory ~= target then
      commands[#commands + 1] = { "open", directory }
    end
  elseif directory ~= "" then
    commands = {
      { "xdg-open", directory },
    }
  else
    commands = {
      { "xdg-open", target },
    }
  end

  local errors = {}
  for _, command in ipairs(commands) do
    local ok_reveal, reveal_err = try_detached_command(command)
    if ok_reveal then
      return true, nil
    end
    if type(reveal_err) == "string" and reveal_err ~= "" then
      errors[#errors + 1] = reveal_err
    end
  end

  if vim.tbl_isempty(errors) then
    return false, "Unable to reveal local target"
  end
  return false, table.concat(errors, " | ")
end

local function ensure_open_target(target, label, opts)
  opts = type(opts) == "table" and opts or {}
  if type(target) ~= "string" or target == "" then
    return false, string.format("Missing %s target", label)
  end

  local is_url = target:match("^https?://") ~= nil
  if is_url then
    return url_open.open(target, {
      notify_error = false,
    })
  end

  local policy = normalize_local_open_policy(opts.open_local, "disabled")
  local effective_policy = effective_local_open_policy(policy, target)
  local policy_key = safe_string(opts.open_local_key, "local opener policy")
  if effective_policy == "disabled" then
    return false, string.format("Opening local targets is disabled by `%s`", policy_key)
  end
  if effective_policy == "reveal_only" then
    return try_reveal_local_target(target)
  end
  return try_local_system_open(target)
end

local function joinpath(...)
  if vim.fs and vim.fs.joinpath then
    return vim.fs.joinpath(...)
  end
  local separator = package.config:sub(1, 1)
  return table.concat({ ... }, separator)
end

local function url_decode(value)
  if type(value) ~= "string" then
    return ""
  end
  return (value:gsub("%%(%x%x)", function(hex)
    return string.char(tonumber(hex, 16))
  end))
end

local function sanitize_filename(value)
  local name = type(value) == "string" and value or ""
  name = url_decode(name)
  name = name:gsub("[<>:\"/\\|%?%*]", "_")
  name = name:gsub("[%c]", "_")
  name = name:gsub("^%s+", "")
  name = name:gsub("%s+$", "")
  if name == "" then
    name = "attachment"
  end
  if #name > 120 then
    local ext = name:match("(%.[^.]+)$")
    if type(ext) == "string" and ext ~= "" and #ext < 40 then
      local head = name:sub(1, 120 - #ext)
      name = head .. ext
    else
      name = name:sub(1, 120)
    end
  end
  return name
end

non_text_preview.base64_chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

function non_text_preview.decode_base64_fallback(data)
  data = (data or ""):gsub("[^" .. non_text_preview.base64_chars .. "=]", "")
  return (data:gsub(".", function(char)
    if char == "=" then
      return ""
    end
    local index = non_text_preview.base64_chars:find(char, 1, true)
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

function non_text_preview.decode_base64(data)
  local normalized = type(data) == "string" and data:gsub("\n", "") or ""
  if normalized == "" then
    return ""
  end
  if vim.base64 and type(vim.base64.decode) == "function" then
    local ok, decoded = pcall(vim.base64.decode, normalized)
    if ok and type(decoded) == "string" then
      return decoded
    end
  end
  return non_text_preview.decode_base64_fallback(normalized)
end

function non_text_preview.ensure_dir(path)
  if type(path) ~= "string" or path == "" then
    return false
  end
  vim.fn.mkdir(path, "p")
  return vim.fn.isdirectory(path) == 1
end

function non_text_preview.write_binary_file(path, bytes)
  if type(path) ~= "string" or path == "" then
    return false, "Missing cache path"
  end
  local parent = path:match("^(.*)[/\\][^/\\]+$") or ""
  if parent ~= "" and not non_text_preview.ensure_dir(parent) then
    return false, "Unable to prepare asset cache directory"
  end
  local fd, open_err = uv.fs_open(path, "w", 438)
  if not fd then
    return false, tostring(open_err or "Unable to open asset cache file")
  end
  local ok_write, write_err = uv.fs_write(fd, bytes or "", 0)
  uv.fs_close(fd)
  if not ok_write then
    return false, tostring(write_err or "Unable to write asset cache file")
  end
  return true, nil
end

local function extension_from_name(name)
  local ext = type(name) == "string" and name:match("%.([^.]+)$") or nil
  if type(ext) ~= "string" then
    return ""
  end
  return ext:lower()
end

local function filename_from_url(url)
  if type(url) ~= "string" then
    return ""
  end
  local path = url:match("^https?://[^/]+(/[^?#]*)") or ""
  local name = path:match("([^/]+)$") or ""
  if name == "" then
    return ""
  end
  return sanitize_filename(name)
end

local function resolve_attachment_filename(url, label, allowed_fallback_extensions)
  local filename = filename_from_url(url)
  if filename ~= "" then
    return filename
  end

  local fallback = sanitize_filename(type(label) == "string" and label or "")
  if fallback == "" then
    return "attachment.bin"
  end

  local ext = extension_from_name(fallback)
  if ext ~= "" and type(allowed_fallback_extensions) == "table" and allowed_fallback_extensions[ext] then
    return fallback
  end

  return "attachment.bin"
end

local function list_to_set(list)
  local set = {}
  for _, value in ipairs(type(list) == "table" and list or {}) do
    if type(value) == "string" and value ~= "" then
      set[value] = true
    end
  end
  return set
end

local function normalize_extension_list(values, fallback)
  local source = type(values) == "table" and values or fallback
  local normalized = {}
  local seen = {}
  for _, value in ipairs(source) do
    if type(value) == "string" and value ~= "" then
      local ext = value:lower():gsub("^%.+", "")
      if ext ~= "" and not seen[ext] then
        seen[ext] = true
        normalized[#normalized + 1] = ext
      end
    end
  end
  if vim.tbl_isempty(normalized) then
    return vim.deepcopy(fallback)
  end
  return normalized
end

local function overview_markdown_link_preview_options()
  local markdown = (((config.get() or {}).overview or {}).markdown or {})
  local renderable = normalize_extension_list(
    markdown.link_preview_renderable_extensions,
    { "txt", "md", "markdown", "json", "yaml", "yml", "csv", "log" }
  )
  local disallowed = normalize_extension_list(markdown.link_preview_disallowed_extensions, { "zip" })

  local max_bytes = positive_integer(markdown.link_preview_max_bytes, 10485760)
  if max_bytes < 1024 then
    max_bytes = 10485760
  end

  return {
    keymap = type(markdown.link_preview_keymap) == "string" and markdown.link_preview_keymap or "gp",
    max_bytes = max_bytes,
    open_local = normalize_local_open_policy(markdown.link_preview_open_local, "disabled"),
    renderable_extensions = renderable,
    disallowed_extensions = disallowed,
    renderable_set = list_to_set(renderable),
    disallowed_set = list_to_set(disallowed),
  }
end

local function build_overview_link_temp_path(filename)
  local root = joinpath(vim.fn.stdpath("cache"), "gh-pr", "overview-links")
  local created = vim.fn.mkdir(root, "p")
  if created == 0 and vim.fn.isdirectory(root) ~= 1 then
    return nil, "Unable to prepare overview link preview cache directory"
  end

  local suffix = string.format("%d-%d", os.time(), math.floor((uv.hrtime and uv.hrtime() or 0) % 100000))
  return joinpath(root, suffix .. "-" .. sanitize_filename(filename)), nil
end

local function read_file_bytes(path)
  local fd, open_err = uv.fs_open(path, "r", 438)
  if not fd then
    return nil, tostring(open_err or "Unable to open downloaded file")
  end

  local stat, stat_err = uv.fs_fstat(fd)
  if not stat then
    uv.fs_close(fd)
    return nil, tostring(stat_err or "Unable to inspect downloaded file")
  end

  local size = tonumber(stat.size) or 0
  local data = size > 0 and uv.fs_read(fd, size, 0) or ""
  uv.fs_close(fd)
  if type(data) ~= "string" then
    return nil, "Unable to read downloaded file bytes"
  end

  return data, nil
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
  for index = 1, #sample do
    local byte = sample:byte(index)
    if byte < 9 or (byte > 13 and byte < 32) then
      invalid = invalid + 1
    end
  end

  return invalid > 0 and (invalid / #sample) > 0.12
end

local function filetype_for_extension(ext)
  if ext == "md" or ext == "markdown" then
    return "markdown"
  end
  if ext == "json" then
    return "json"
  end
  if ext == "yaml" or ext == "yml" then
    return "yaml"
  end
  if ext == "csv" then
    return "csv"
  end
  if ext == "log" or ext == "txt" then
    return "text"
  end
  return "text"
end

local function looks_like_json(content)
  if type(content) ~= "string" then
    return false
  end
  local trimmed = vim.trim(content)
  if trimmed == "" then
    return false
  end

  local first = trimmed:sub(1, 1)
  local last = trimmed:sub(-1)
  if not ((first == "{" and last == "}") or (first == "[" and last == "]")) then
    return false
  end

  local ok, _ = pcall(vim.json.decode, trimmed)
  return ok
end

local function detect_preview_filetype(filename, content)
  if vim.filetype and type(vim.filetype.match) == "function" then
    local ok, detected = pcall(vim.filetype.match, {
      filename = filename,
    })
    if ok and type(detected) == "string" and detected ~= "" then
      return detected
    end
  end

  local ext = extension_from_name(filename)
  local fallback = filetype_for_extension(ext)
  if fallback == "text" and looks_like_json(content) then
    return "json"
  end
  return fallback
end

local function open_overview_link_preview_window(opts)
  local filename = sanitize_filename(type(opts.filename) == "string" and opts.filename or "attachment")
  local content = type(opts.content) == "string" and opts.content or ""
  content = content:gsub("\r\n", "\n"):gsub("\r", "\n")
  local preview_filetype = detect_preview_filetype(filename, content)
  local lines = vim.split(content, "\n", { plain = true })
  if vim.tbl_isempty(lines) then
    lines = { "" }
  end

  local bufnr = vim.api.nvim_create_buf(false, true)
  local name = string.format("ghpr://overview/link-preview/%d/%s", tonumber(os.time()) or 0, filename)
  pcall(vim.api.nvim_buf_set_name, bufnr, name)
  vim.api.nvim_set_option_value("buftype", "nofile", { buf = bufnr })
  vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = bufnr })
  vim.api.nvim_set_option_value("swapfile", false, { buf = bufnr })
  vim.api.nvim_set_option_value("modifiable", true, { buf = bufnr })
  vim.api.nvim_set_option_value("readonly", false, { buf = bufnr })
  vim.bo[bufnr].filetype = preview_filetype
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.api.nvim_set_option_value("modifiable", false, { buf = bufnr })
  vim.api.nvim_set_option_value("readonly", true, { buf = bufnr })
  pcall(vim.api.nvim_set_option_value, "modified", false, { buf = bufnr })

  local ok_tab, tab_err = pcall(vim.cmd, "tabnew")
  if not ok_tab then
    return false, "Unable to open preview tab: " .. tostring(tab_err)
  end

  local tabpage = vim.api.nvim_get_current_tabpage()
  local winid = vim.api.nvim_get_current_win()
  if not is_valid_win(winid) then
    return false, "Unable to resolve preview window"
  end

  pcall(vim.api.nvim_win_set_buf, winid, bufnr)
  sanitize_modal_window(winid)
  vim.api.nvim_set_option_value("number", true, { win = winid })
  vim.api.nvim_set_option_value("relativenumber", false, { win = winid })
  vim.api.nvim_set_option_value("signcolumn", "no", { win = winid })
  vim.api.nvim_set_option_value("wrap", true, { win = winid })
  vim.api.nvim_set_option_value("linebreak", true, { win = winid })
  vim.api.nvim_set_option_value("cursorline", true, { win = winid })
  vim.api.nvim_set_option_value("spell", false, { win = winid })
  if type(preview_filetype) == "string" and preview_filetype ~= "" and preview_filetype ~= "text" then
    pcall(vim.api.nvim_set_option_value, "syntax", preview_filetype, { win = winid })
  end

  local function close_preview_tab()
    if vim.api.nvim_get_current_tabpage() ~= tabpage and vim.api.nvim_tabpage_is_valid(tabpage) then
      pcall(vim.api.nvim_set_current_tabpage, tabpage)
    end
    if vim.api.nvim_tabpage_is_valid(tabpage) then
      pcall(vim.cmd, "tabclose")
    elseif is_valid_buf(bufnr) then
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end
  end

  local key_opts = { buffer = bufnr, silent = true, nowait = true }
  vim.keymap.set("n", "q", close_preview_tab, vim.tbl_extend("force", key_opts, { desc = "Close PR link preview" }))
  vim.keymap.set("n", "<Esc>", close_preview_tab, vim.tbl_extend("force", key_opts, { desc = "Close PR link preview" }))
  pcall(vim.api.nvim_win_set_cursor, winid, { 1, 0 })

  return true, nil
end

local function select_open_local(prompt, callback, confirm_item)
  local function normalize_confirm_label(value)
    if type(value) ~= "string" then
      return ""
    end
    return vim.trim(value):lower()
  end

  local function did_confirm_select_choice(choice, confirm_label)
    local normalized_confirm = normalize_confirm_label(confirm_label)
    if normalized_confirm == "" then
      return false
    end

    if type(choice) == "string" then
      return normalize_confirm_label(choice) == normalized_confirm
    end

    if type(choice) == "number" then
      return choice == 1
    end

    if type(choice) == "table" then
      local candidate_keys = { "value", "text", "label", "name", "id", 1 }
      for _, key in ipairs(candidate_keys) do
        local value = choice[key]
        if type(value) == "string" and normalize_confirm_label(value) == normalized_confirm then
          return true
        end
      end

      local index = tonumber(choice.idx) or tonumber(choice.index)
      if index == 1 then
        return true
      end
    end

    return false
  end

  callback = callback or function() end
  local confirm_label = type(confirm_item) == "string" and confirm_item ~= "" and confirm_item or "open local"
  if vim.ui and type(vim.ui.select) == "function" then
    vim.ui.select({ confirm_label, "cancel" }, {
      prompt = prompt,
      format_item = function(item)
        return item
      end,
    }, function(choice)
      vim.schedule(function()
        callback(did_confirm_select_choice(choice, confirm_label))
      end)
    end)
    return
  end

  local choice = vim.fn.confirm(prompt, "&" .. confirm_label .. "\n&Cancel", 2)
  callback(choice == 1)
end

local gh_auth_token_cache = {
  attempted = false,
  token = nil,
}

local function url_host(url)
  if type(url) ~= "string" then
    return ""
  end
  local host = url:match("^https?://([^/%?#]+)") or ""
  return host:lower()
end

local function is_github_attachment_url(url)
  local host = url_host(url)
  local path = type(url) == "string" and (url:match("^https?://[^/]+(/[^?#]*)") or "") or ""

  if host == "github.com" then
    return path:match("^/user%-attachments/files/") ~= nil
      or path:match("^/user%-attachments/assets/") ~= nil
  end

  if host == "objects.githubusercontent.com" then
    return true
  end

  if host == "user-images.githubusercontent.com" or host == "private-user-images.githubusercontent.com" then
    return true
  end

  if host:match("%.githubusercontent%.com$") ~= nil then
    return path:match("/user%-attachments/") ~= nil
      or path:match("github%-production%-user%-asset") ~= nil
      or path:match("github%-production%-release%-asset") ~= nil
  end

  return false
end

local function resolve_gh_auth_token()
  if gh_auth_token_cache.attempted then
    return gh_auth_token_cache.token
  end

  gh_auth_token_cache.attempted = true
  local output, err = gh.run_command({ "gh", "auth", "token" })
  if not output then
    notify_warn("Unable to resolve gh auth token for link download: " .. tostring(err))
    gh_auth_token_cache.token = nil
    return nil
  end

  local token = vim.trim(output)
  if token == "" then
    gh_auth_token_cache.token = nil
    return nil
  end

  gh_auth_token_cache.token = token
  return token
end

local function downloader_command(url, output_path)
  local auth_token = nil
  if is_github_attachment_url(url) then
    auth_token = resolve_gh_auth_token()
  end

  if vim.fn.executable("curl") == 1 then
    local command = {
      "curl",
      "-L",
      "--fail",
      "--silent",
      "--show-error",
    }
    if type(auth_token) == "string" and auth_token ~= "" then
      command[#command + 1] = "--header"
      command[#command + 1] = "Authorization: Bearer " .. auth_token
      command[#command + 1] = "--header"
      command[#command + 1] = "Accept: application/octet-stream"
    end
    command[#command + 1] = "--output"
    command[#command + 1] = output_path
    command[#command + 1] = url
    return command, nil
  end

  if vim.fn.executable("wget") == 1 then
    local command = { "wget", "-q" }
    if type(auth_token) == "string" and auth_token ~= "" then
      command[#command + 1] = "--header=Authorization: Bearer " .. auth_token
      command[#command + 1] = "--header=Accept: application/octet-stream"
    end
    command[#command + 1] = "-O"
    command[#command + 1] = output_path
    command[#command + 1] = url
    return command, nil
  end

  local is_windows = vim.fn.has("win32") == 1 or vim.fn.has("win64") == 1
  if is_windows and vim.fn.executable("pwsh") == 1 then
    return {
      "pwsh",
      "-NoProfile",
      "-NonInteractive",
      "-Command",
      "$ProgressPreference='SilentlyContinue'; "
          .. "$headers=@{}; "
          .. "if ($args.Count -ge 3 -and $args[2] -ne '') { "
          .. "$headers['Authorization']='Bearer ' + $args[2]; "
          .. "$headers['Accept']='application/octet-stream' "
          .. "}; "
          .. "Invoke-WebRequest -UseBasicParsing -Headers $headers -Uri $args[0] -OutFile $args[1]",
      url,
      output_path,
      type(auth_token) == "string" and auth_token or "",
    }, nil
  end
  if is_windows and vim.fn.executable("powershell") == 1 then
    return {
      "powershell",
      "-NoProfile",
      "-NonInteractive",
      "-Command",
      "$ProgressPreference='SilentlyContinue'; "
          .. "$headers=@{}; "
          .. "if ($args.Count -ge 3 -and $args[2] -ne '') { "
          .. "$headers['Authorization']='Bearer ' + $args[2]; "
          .. "$headers['Accept']='application/octet-stream' "
          .. "}; "
          .. "Invoke-WebRequest -UseBasicParsing -Headers $headers -Uri $args[0] -OutFile $args[1]",
      url,
      output_path,
      type(auth_token) == "string" and auth_token or "",
    }, nil
  end

  return nil, "No supported downloader found (curl/wget/powershell)"
end

local function download_link_to_path_async(url, output_path, callback)
  callback = callback or function() end
  local command, cmd_err = downloader_command(url, output_path)
  if not command then
    callback(nil, cmd_err)
    return
  end

  gh.run_command_async(command, nil, function(_, run_err)
    if run_err then
      callback(nil, run_err)
      return
    end

    if vim.fn.filereadable(output_path) ~= 1 then
      callback(nil, "Downloaded file is unavailable on disk")
      return
    end

    callback(output_path, nil)
  end)
end

local function notify_local_open_unavailable(filename, reason, config_key, path)
  local location = type(path) == "string" and path ~= "" and ("\nCached at: " .. path) or ""
  notify_warn(string.format(
    "Preview unavailable for '%s' (%s). Local open is disabled by `%s`.%s",
    filename,
    reason,
    config_key,
    location
  ))
end

local function prompt_open_downloaded_file(path, filename, reason, open_local, open_local_key)
  local confirm_label = local_open_action_label(open_local, path)
  local prompt = string.format(
    "Preview unavailable for '%s' (%s). %s downloaded file locally?",
    filename,
    reason,
    confirm_label:gsub("^%l", string.upper)
  )
  select_open_local(prompt, function(should_open)
    if not should_open then
      return
    end
    local ok_open, open_err = ensure_open_target(path, "downloaded file", {
      open_local = open_local,
      open_local_key = open_local_key,
    })
    if not ok_open then
      notify_error("Unable to open downloaded file: " .. tostring(open_err))
    end
  end, confirm_label)
end

local function prompt_download_and_open_local(url, filename, reason, open_local, open_local_key)
  local confirm_label = local_open_action_label(open_local, filename)
  local prompt = string.format(
    "Cannot preview '%s' (%s). Download and %s?",
    filename,
    reason,
    local_open_action_phrase(open_local, filename)
  )
  select_open_local(prompt, function(should_open)
    if not should_open then
      return
    end

    local target_path, target_err = build_overview_link_temp_path(filename)
    if not target_path then
      notify_error(target_err)
      return
    end

    notify_info("Downloading link attachment for local access...")
    download_link_to_path_async(url, target_path, function(downloaded_path, download_err)
      if not downloaded_path then
        notify_error("Unable to download link: " .. tostring(download_err))
        return
      end
      local ok_open, open_err = ensure_open_target(downloaded_path, "downloaded file", {
        open_local = open_local,
        open_local_key = open_local_key,
      })
      if not ok_open then
        notify_error("Unable to open downloaded file: " .. tostring(open_err))
      end
    end)
  end, confirm_label)
end

local function overview_preview_markdown_link(action)
  local url = type(action) == "table" and type(action.url) == "string" and vim.trim(action.url) or ""
  if url == "" then
    return notify_error("Missing markdown link URL")
  end
  if not url:match("^https?://") then
    return notify_warn("Only http/https links can be previewed")
  end
  if not is_github_attachment_url(url) then
    local prompt = string.format(
      "This markdown link is not a GitHub attachment.\nOpen in browser?\n%s",
      url
    )
    select_open_local(prompt, function(should_open)
      if not should_open then
        return
      end

      local ok_open, open_err = ensure_open_target(url, "URL")
      if not ok_open then
        notify_error("Unable to open URL: " .. tostring(open_err))
      end
    end, "open link")
    return
  end

  local options = overview_markdown_link_preview_options()
  local action_label = type(action) == "table" and type(action.label) == "string" and action.label or ""
  local filename = resolve_attachment_filename(url, action_label, options.renderable_set)

  local extension = extension_from_name(filename)
  if extension ~= "" and options.disallowed_set[extension] then
    if options.open_local == "disabled" then
      notify_local_open_unavailable(
        filename,
        "extension ." .. extension .. " is not previewable",
        "overview.markdown.link_preview_open_local"
      )
      return
    end
    prompt_download_and_open_local(
      url,
      filename,
      "extension ." .. extension .. " is not previewable",
      options.open_local,
      "overview.markdown.link_preview_open_local"
    )
    return
  end
  if extension ~= "" and not options.renderable_set[extension] then
    if options.open_local == "disabled" then
      notify_local_open_unavailable(
        filename,
        "extension ." .. extension .. " is not configured as renderable",
        "overview.markdown.link_preview_open_local"
      )
      return
    end
    prompt_download_and_open_local(
      url,
      filename,
      "extension ." .. extension .. " is not configured as renderable",
      options.open_local,
      "overview.markdown.link_preview_open_local"
    )
    return
  end

  local target_path, target_err = build_overview_link_temp_path(filename)
  if not target_path then
    return notify_error(target_err)
  end

  notify_info("Downloading GitHub attachment for preview...")
  download_link_to_path_async(url, target_path, function(downloaded_path, download_err)
    if not downloaded_path then
      notify_error("Unable to download link: " .. tostring(download_err))
      return
    end

    local stat = uv.fs_stat(downloaded_path)
    local size = tonumber(stat and stat.size) or 0
    if size > options.max_bytes then
      if options.open_local == "disabled" then
        notify_local_open_unavailable(
          filename,
          string.format("file exceeds preview limit (%d > %d bytes)", size, options.max_bytes),
          "overview.markdown.link_preview_open_local",
          downloaded_path
        )
        return
      end
      prompt_open_downloaded_file(
        downloaded_path,
        filename,
        string.format("file exceeds preview limit (%d > %d bytes)", size, options.max_bytes),
        options.open_local,
        "overview.markdown.link_preview_open_local"
      )
      return
    end

    local bytes, read_err = read_file_bytes(downloaded_path)
    if not bytes then
      notify_error("Unable to inspect downloaded file: " .. tostring(read_err))
      return
    end

    if is_probably_binary(bytes) then
      if options.open_local == "disabled" then
        notify_local_open_unavailable(
          filename,
          "binary content is not renderable",
          "overview.markdown.link_preview_open_local",
          downloaded_path
        )
        return
      end
      prompt_open_downloaded_file(
        downloaded_path,
        filename,
        "binary content is not renderable",
        options.open_local,
        "overview.markdown.link_preview_open_local"
      )
      return
    end

    local ok_preview, preview_err = open_overview_link_preview_window({
      filename = filename,
      content = bytes,
    })
    if not ok_preview then
      notify_error("Unable to render link preview: " .. tostring(preview_err))
    end
  end)
end

local function resolve_image_compare_url(ctx, images_cfg)
  local pr_url = trim_trailing_slash(ctx.pr_url)
  local pr_files_url = trim_trailing_slash(ctx.pr_files_url)
  if pr_url == "" and type(ctx.repo) == "string" and ctx.repo ~= "" then
    pr_url = string.format("https://github.com/%s/pull/%d", ctx.repo, ctx.number)
  end
  if pr_files_url == "" and pr_url ~= "" then
    pr_files_url = pr_url:find("/files$", 1, true) and pr_url or (pr_url .. "/files")
  end

  if (type(images_cfg) == "table" and images_cfg.fallback_github_target == "pr") or pr_files_url == "" then
    return pr_url
  end

  local base = pr_files_url
  local anchor_path = normalize_path(ctx.file_path ~= "" and ctx.file_path or ctx.path)
  if anchor_path ~= "" and vim.fn.exists("*sha256") == 1 then
    local ok_hash, hash = pcall(vim.fn.sha256, anchor_path)
    if ok_hash and type(hash) == "string" and hash ~= "" then
      return base .. "#diff-" .. hash
    end
  end
  return base
end

local function write_readonly_buffer_lines(bufnr, lines, filetype)
  if not is_valid_buf(bufnr) then
    return false, "Invalid buffer"
  end

  local content = type(lines) == "table" and lines or { tostring(lines or "") }
  local view = vim.fn.winsaveview()
  pcall(vim.api.nvim_set_option_value, "readonly", false, { buf = bufnr })
  pcall(vim.api.nvim_set_option_value, "modifiable", true, { buf = bufnr })
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, content)
  if type(filetype) == "string" and filetype ~= "" then
    pcall(vim.api.nvim_set_option_value, "filetype", filetype, { buf = bufnr })
  end
  pcall(vim.api.nvim_set_option_value, "modifiable", false, { buf = bufnr })
  pcall(vim.api.nvim_set_option_value, "readonly", true, { buf = bufnr })
  pcall(vim.api.nvim_set_option_value, "modified", false, { buf = bufnr })
  pcall(vim.fn.winrestview, view)
  return true, nil
end

local function collect_image_metadata_for_side(ctx, side, images_cfg)
  local asset, asset_err = non_text_preview.ensure_image_side_asset(ctx, side, images_cfg)
  if not asset then
    return {
      side = side,
      present = non_text_preview.side_present_for_status(ctx.status, side),
      path = non_text_preview.path_for_side(ctx, side),
      error = tostring(asset_err or "Unable to load image asset"),
    }
  end
  if asset.present == false then
    return {
      side = side,
      present = false,
      path = asset.path,
    }
  end
  if not file_readable(asset.cache_path) then
    return {
      side = side,
      present = true,
      path = asset.path,
      error = "Cached image file is unavailable locally",
    }
  end

  local metadata = image_metadata.collect({
    path = asset.cache_path,
    ext = asset.ext,
    sha = asset.sha,
    size_bytes = asset.size,
    strategy = images_cfg.metadata_resolution_strategy,
    external_command = images_cfg.metadata_external_command,
  })
  metadata.side = side
  metadata.present = true
  metadata.path = asset.path
  metadata.local_path = asset.cache_path
  metadata.sha = type(metadata.sha) == "string" and metadata.sha or (asset.sha or "")
  metadata.size_bytes = tonumber(metadata.size_bytes) or tonumber(asset.size) or 0
  metadata.size_human = type(metadata.size_human) == "string" and metadata.size_human ~= ""
      and metadata.size_human
    or image_metadata.format_bytes(metadata.size_bytes)
  return metadata
end

local function append_side_metadata_lines(lines, prefix, label, entry)
  if not entry.present then
    lines[#lines + 1] = string.format("%s %s: (not present in this revision)", prefix, label)
    return
  end
  if type(entry.error) == "string" and entry.error ~= "" then
    lines[#lines + 1] = string.format("%s %s error: %s", prefix, label, entry.error)
    return
  end

  local sha = type(entry.sha) == "string" and entry.sha ~= "" and entry.sha:sub(1, 12) or "-"
  local bytes = tonumber(entry.size_bytes) or 0
  local size = type(entry.size_human) == "string" and entry.size_human ~= ""
      and entry.size_human
    or image_metadata.format_bytes(bytes)
  local resolution = type(entry.resolution) == "string" and entry.resolution ~= "" and entry.resolution or "unknown"
  local path = type(entry.path) == "string" and entry.path ~= "" and entry.path or "(unknown)"
  lines[#lines + 1] = string.format("%s %s path: %s", prefix, label, path)
  lines[#lines + 1] = string.format("%s %s resolution: %s", prefix, label, resolution)
  lines[#lines + 1] = string.format("%s %s size: %s (%d bytes)", prefix, label, size, bytes)
  lines[#lines + 1] = string.format("%s %s sha: %s", prefix, label, sha)
end

local function render_image_metadata_diff(bufnr, reason_override)
  local ctx, ctx_err = non_text_preview.resolve_buffer_context(bufnr)
  if not ctx then
    return false, ctx_err
  end
  if ctx.asset_kind ~= "image" then
    return true, nil
  end

  local images_cfg = non_text_preview.image_diff_options()
  local diff_shortcuts = diff_view_shortcuts()
  local default_action = non_text_preview.resolve_default_action(images_cfg)
  local compare_url = resolve_image_compare_url(ctx, images_cfg)
  local reason = type(reason_override) == "string" and reason_override ~= "" and reason_override or ctx.reason
  local default_key = type(diff_shortcuts.image_default_action) == "string" and diff_shortcuts.image_default_action or "<localleader>io"
  local fallback_key = type(diff_shortcuts.image_fallback_menu) == "string" and diff_shortcuts.image_fallback_menu
    or "<localleader>im"
  local base_meta = collect_image_metadata_for_side(ctx, "base", images_cfg)
  local head_meta = collect_image_metadata_for_side(ctx, "head", images_cfg)
  local display_path = ctx.file_path ~= "" and ctx.file_path or ctx.path

  local lines = {
    "gh-pr image metadata diff",
    "",
    string.format("path: %s", display_path ~= "" and display_path or "(unknown)"),
    string.format("status: %s", ctx.status ~= "" and ctx.status or "unknown"),
    string.format(
      "default action (%s): %s",
      default_key ~= "" and default_key or "<localleader>io",
      non_text_preview.action_label(default_action, images_cfg)
    ),
    string.format("fallback menu (%s): image actions", fallback_key ~= "" and fallback_key or "<localleader>im"),
  }
  if reason ~= "" then
    lines[#lines + 1] = string.format("render fallback reason: %s", reason)
  end
  if compare_url ~= "" then
    lines[#lines + 1] = string.format("github compare: %s", compare_url)
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "Image metadata"
  append_side_metadata_lines(lines, "-", "base", base_meta)
  append_side_metadata_lines(lines, "+", "head", head_meta)
  lines[#lines + 1] = ""
  lines[#lines + 1] = string.format(
    "Tip: use %s for default action or %s for fallback menu actions.",
    default_key ~= "" and default_key or "<localleader>io",
    fallback_key ~= "" and fallback_key or "<localleader>im"
  )

  image_renderer.clear(bufnr)
  local ok_write, write_err = write_readonly_buffer_lines(bufnr, lines, "diff")
  if not ok_write then
    return false, write_err
  end

  vim.b[bufnr].gh_pr_image_fallback = true
  if reason ~= "" then
    vim.b[bufnr].gh_pr_image_reason = reason
  end
  return true, nil
end

local function run_image_fallback_action(action, bufnr, opts)
  opts = type(opts) == "table" and opts or {}
  local ctx, ctx_err = non_text_preview.resolve_buffer_context(bufnr)
  if not ctx then
    return false, ctx_err
  end

  local images_cfg = non_text_preview.image_diff_options()
  local requested = non_text_preview.normalize_image_action(action, non_text_preview.resolve_default_action(images_cfg))
  local reason = type(opts.reason) == "string" and opts.reason ~= "" and opts.reason or ctx.reason

  if requested == "metadata" then
    if ctx.asset_kind ~= "image" then
      return true, nil
    end
    return render_image_metadata_diff(ctx.bufnr, reason)
  end

  if requested == "open_local_current" then
    local side = non_text_preview.current_side(ctx)
    local asset, asset_err = non_text_preview.ensure_side_asset(ctx, side, images_cfg)
    if not asset then
      return false, asset_err
    end
    if asset.present == false then
      return false, string.format("No %s revision exists for this pull request file state", side)
    end
    if not file_readable(asset.cache_path) then
      return false, "Unable to resolve a local asset file to open"
    end
    return ensure_open_target(asset.cache_path, "local asset", {
      open_local = images_cfg.fallback_open_local,
      open_local_key = "diff_view.images.fallback_open_local",
    })
  end

  if requested == "open_local_both" then
    local opened_paths = {}
    local opened_count = 0
    local errors = {}
    for _, side in ipairs({ "base", "head" }) do
      local asset, asset_err = non_text_preview.ensure_side_asset(ctx, side, images_cfg)
      if not asset then
        errors[#errors + 1] = string.format("%s: %s", side, tostring(asset_err))
      elseif asset.present and file_readable(asset.cache_path) then
        if not opened_paths[asset.cache_path] then
          local ok_open, open_err = ensure_open_target(asset.cache_path, side .. " asset", {
            open_local = images_cfg.fallback_open_local,
            open_local_key = "diff_view.images.fallback_open_local",
          })
          if ok_open then
            opened_paths[asset.cache_path] = true
            opened_count = opened_count + 1
          else
            errors[#errors + 1] = string.format("%s: %s", side, tostring(open_err))
          end
        end
      elseif asset.present then
        errors[#errors + 1] = string.format("%s: local cached file unavailable", side)
      end
    end

    if opened_count > 0 then
      return true, nil
    end
    if #errors > 0 then
      return false, table.concat(errors, " | ")
    end
    return false, "No local revisions available to open"
  end

  if requested == "open_github" then
    local url = resolve_image_compare_url(ctx, images_cfg)
    if url == "" then
      return false, "Unable to resolve GitHub URL for this file"
    end
    return ensure_open_target(url, "GitHub file URL")
  end

  return false, "Unsupported non-text preview action: " .. tostring(requested)
end

local function execute_image_fallback_action(action, bufnr, opts)
  opts = type(opts) == "table" and opts or {}
  local requested = non_text_preview.normalize_image_action(action, "metadata")
  local ok_action, action_err = run_image_fallback_action(requested, bufnr, opts)
  if ok_action then
    return true, nil
  end

  local should_fallback_to_metadata = opts.fallback_to_metadata ~= false and requested ~= "metadata"
  if should_fallback_to_metadata then
    local ok_metadata, metadata_err = run_image_fallback_action("metadata", bufnr, {
      reason = type(opts.reason) == "string" and opts.reason ~= "" and opts.reason or tostring(action_err or ""),
    })
    if ok_metadata then
      notify_warn(string.format(
        "Non-text preview action '%s' failed (%s). Rendered metadata preview instead.",
        requested,
        tostring(action_err)
      ))
      return true, nil
    end
    return false, tostring(action_err) .. " | metadata: " .. tostring(metadata_err)
  end

  return false, action_err
end

local function close_image_fallback_menu()
  if type(non_text_preview.menu_state) ~= "table" then
    non_text_preview.menu_state = nil
    return
  end

  local winid = non_text_preview.menu_state.winid
  non_text_preview.menu_state = nil
  if is_valid_win(winid) then
    pcall(vim.api.nvim_win_close, winid, true)
  end
end

local function current_menu_action(state_value)
  if type(state_value) ~= "table" or not is_valid_win(state_value.winid) then
    return nil
  end
  local cursor = vim.api.nvim_win_get_cursor(state_value.winid)
  return state_value.line_actions[cursor[1]]
end

local function run_menu_action(state_value, action, set_default)
  local action_id = non_text_preview.normalize_image_action(action, non_text_preview.resolve_default_action(non_text_preview.image_diff_options()))
  if set_default == true then
    non_text_preview.persist_default_action(action_id)
    notify_info("Non-text preview default action set to: " .. non_text_preview.action_label(action_id, non_text_preview.image_diff_options()))
  end

  local origin_winid = state_value.origin_winid
  local origin_bufnr = state_value.origin_bufnr
  close_image_fallback_menu()

  if is_valid_win(origin_winid) then
    pcall(vim.api.nvim_set_current_win, origin_winid)
  end
  local ok_action, action_err = execute_image_fallback_action(action_id, origin_bufnr, {
    fallback_to_metadata = true,
  })
  if not ok_action then
    notify_error(action_err)
  end
end

local function open_image_fallback_menu()
  local origin_bufnr = vim.api.nvim_get_current_buf()
  local ctx, ctx_err = non_text_preview.resolve_buffer_context(origin_bufnr)
  if not ctx then
    return notify_error(ctx_err)
  end

  local origin_winid = vim.api.nvim_get_current_win()
  close_image_fallback_menu()

  local images_cfg = non_text_preview.image_diff_options()
  local diff_shortcuts = diff_view_shortcuts()
  local default_action = non_text_preview.resolve_default_action(images_cfg)
  local default_key = type(diff_shortcuts.image_default_action) == "string" and diff_shortcuts.image_default_action or "<localleader>io"
  local fallback_key = type(diff_shortcuts.image_fallback_menu) == "string" and diff_shortcuts.image_fallback_menu
    or "<localleader>im"
  local reason = type(vim.b[origin_bufnr].gh_pr_image_reason) == "string" and vim.b[origin_bufnr].gh_pr_image_reason or ""
  local asset_label = ctx.asset_kind == "image" and "image" or "non-text"

  local lines = {
    string.format("gh-pr %s preview actions", asset_label),
    "Enter/1..4: run action | d: set default | s: set default + run | q: close",
    string.rep("=", 74),
    string.format("file: %s", ctx.file_path ~= "" and ctx.file_path or ctx.path),
    string.format("status: %s", ctx.status ~= "" and ctx.status or "unknown"),
    string.format(
      "default (%s): %s",
      default_key ~= "" and default_key or "<localleader>io",
      non_text_preview.action_label(default_action, images_cfg)
    ),
    string.format("menu keymap: %s", fallback_key ~= "" and fallback_key or "<localleader>im"),
  }
  if reason ~= "" then
    lines[#lines + 1] = "reason: " .. reason
  end
  lines[#lines + 1] = ""

  local line_actions = {}
  for index, action in ipairs(non_text_preview.action_order) do
    local marker = action == default_action and "*" or " "
    lines[#lines + 1] = string.format("%d. [%s] %s", index, marker, non_text_preview.action_label(action, images_cfg))
    line_actions[#lines] = action
  end

  local width = 72
  for _, line in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(line) + 2)
  end
  width = math.min(width, math.max(56, vim.o.columns - 6))
  local height = math.min(#lines + 1, math.max(10, vim.o.lines - vim.o.cmdheight - 4))
  local row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1)
  local col = math.max(0, math.floor((vim.o.columns - width) / 2))

  local menu_buf = vim.api.nvim_create_buf(false, true)
  local menu_win = vim.api.nvim_open_win(menu_buf, true, {
    relative = "editor",
    row = row,
    col = col,
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    title = asset_label == "image" and "Image Preview" or "Non-Text Preview",
    title_pos = "center",
    noautocmd = true,
  })

  sanitize_modal_window(menu_win)
  vim.api.nvim_buf_set_option(menu_buf, "buftype", "nofile")
  vim.api.nvim_buf_set_option(menu_buf, "bufhidden", "wipe")
  vim.api.nvim_buf_set_option(menu_buf, "swapfile", false)
  vim.api.nvim_buf_set_option(menu_buf, "modifiable", true)
  vim.api.nvim_buf_set_option(menu_buf, "filetype", "markdown")
  vim.api.nvim_buf_set_lines(menu_buf, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(menu_buf, "modifiable", false)
  pcall(vim.api.nvim_set_option_value, "modified", false, { buf = menu_buf })

  vim.api.nvim_win_set_option(menu_win, "number", false)
  vim.api.nvim_win_set_option(menu_win, "relativenumber", false)
  vim.api.nvim_win_set_option(menu_win, "cursorline", true)
  vim.api.nvim_win_set_option(menu_win, "wrap", false)
  vim.api.nvim_win_set_option(menu_win, "signcolumn", "no")
  vim.api.nvim_win_set_option(menu_win, "winhl", "NormalFloat:NormalFloat,FloatBorder:FloatBorder")

  non_text_preview.menu_state = {
    bufnr = menu_buf,
    winid = menu_win,
    origin_winid = origin_winid,
    origin_bufnr = origin_bufnr,
    line_actions = line_actions,
    first_action_line = #lines - #non_text_preview.action_order + 1,
  }

  local keymap_opts = {
    buffer = menu_buf,
    silent = true,
    nowait = true,
  }

  vim.keymap.set("n", "q", close_image_fallback_menu, vim.tbl_extend("force", keymap_opts, { desc = "Close image fallback menu" }))
  vim.keymap.set("n", "<Esc>", close_image_fallback_menu, vim.tbl_extend("force", keymap_opts, { desc = "Close image fallback menu" }))
  vim.keymap.set("n", "<CR>", function()
    local active = non_text_preview.menu_state
    local action = current_menu_action(active)
    if action then
      run_menu_action(active, action, false)
    end
  end, vim.tbl_extend("force", keymap_opts, { desc = "Run selected image fallback action" }))
  vim.keymap.set("n", "d", function()
    local active = non_text_preview.menu_state
    local action = current_menu_action(active)
    if action then
      non_text_preview.persist_default_action(action)
      notify_info("Non-text preview default action set to: " .. non_text_preview.action_label(action, non_text_preview.image_diff_options()))
      local origin_winid = active.origin_winid
      close_image_fallback_menu()
      if is_valid_win(origin_winid) then
        pcall(vim.api.nvim_set_current_win, origin_winid)
      end
      open_image_fallback_menu()
    end
  end, vim.tbl_extend("force", keymap_opts, { desc = "Set selected action as default" }))
  vim.keymap.set("n", "s", function()
    local active = non_text_preview.menu_state
    local action = current_menu_action(active)
    if action then
      run_menu_action(active, action, true)
    end
  end, vim.tbl_extend("force", keymap_opts, { desc = "Set selected action as default and run it" }))

  for index, action in ipairs(non_text_preview.action_order) do
    local action_id = action
    vim.keymap.set("n", tostring(index), function()
      local active = non_text_preview.menu_state
      if active then
        run_menu_action(active, action_id, false)
      end
    end, vim.tbl_extend("force", keymap_opts, { desc = "Run image fallback action " .. tostring(index) }))
  end

  vim.api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(menu_win),
    once = true,
    callback = function()
      non_text_preview.menu_state = nil
    end,
  })

  pcall(vim.api.nvim_win_set_cursor, menu_win, { non_text_preview.menu_state.first_action_line, 0 })
end

local function run_image_fallback_default_action()
  local bufnr = vim.api.nvim_get_current_buf()
  local _, ctx_err = non_text_preview.resolve_buffer_context(bufnr)
  if ctx_err then
    return notify_error(ctx_err)
  end

  local images_cfg = non_text_preview.image_diff_options()
  local action = non_text_preview.resolve_default_action(images_cfg)
  local ok_action, action_err = execute_image_fallback_action(action, bufnr, {
    fallback_to_metadata = true,
  })
  if not ok_action then
    notify_error(action_err)
  end
end

local function run_non_text_default_action()
  return run_image_fallback_default_action()
end

local function open_non_text_actions_menu()
  return open_image_fallback_menu()
end

local function run_non_text_action_at_cursor()
  local bufnr = vim.api.nvim_get_current_buf()
  local ctx, ctx_err = non_text_preview.resolve_buffer_context(bufnr)
  if not ctx then
    return notify_error(ctx_err)
  end

  local line = vim.api.nvim_win_get_cursor(0)[1]
  local actions = type(vim.b[bufnr].gh_pr_asset_actions) == "table" and vim.b[bufnr].gh_pr_asset_actions or {}
  local action = actions[line]
  if type(action) ~= "string" or action == "" then
    return
  end

  local ok_action, action_err = execute_image_fallback_action(action, bufnr, {
    fallback_to_metadata = ctx.asset_kind == "image",
  })
  if not ok_action then
    notify_error(action_err)
  end
end

local function on_image_render_fallback(bufnr, reason)
  local ctx, ctx_err = non_text_preview.resolve_image_buffer_context(bufnr)
  if not ctx then
    return notify_warn(ctx_err)
  end

  local images_cfg = non_text_preview.image_diff_options()
  local mode = images_cfg.fallback_mode
  if mode ~= "menu" and mode ~= "metadata_only" and mode ~= "auto_local" and mode ~= "auto_github" then
    mode = "menu"
  end
  if mode == "auto_local" and normalize_local_open_policy(images_cfg.fallback_open_local, "disabled") == "disabled" then
    mode = "metadata_only"
  end

  if type(reason) == "string" and reason ~= "" then
    vim.b[ctx.bufnr].gh_pr_image_reason = reason
  end

  if mode == "metadata_only" then
    local ok_action, action_err = execute_image_fallback_action("metadata", bufnr, {
      fallback_to_metadata = false,
      reason = reason,
    })
    if not ok_action then
      notify_warn("Unable to render image metadata fallback: " .. tostring(action_err))
    end
    return
  end

  if mode == "auto_local" then
    local preferred = non_text_preview.resolve_default_action(images_cfg)
    if preferred ~= "open_local_current" and preferred ~= "open_local_both" then
      preferred = "open_local_current"
    end
    local ok_action, action_err = execute_image_fallback_action(preferred, bufnr, {
      fallback_to_metadata = true,
      reason = reason,
    })
    if not ok_action then
        notify_warn("Non-text preview auto-local failed: " .. tostring(action_err))
    end
    return
  end

  if mode == "auto_github" then
    local ok_action, action_err = execute_image_fallback_action("open_github", bufnr, {
      fallback_to_metadata = true,
      reason = reason,
    })
    if not ok_action then
        notify_warn("Non-text preview auto-github failed: " .. tostring(action_err))
    end
    return
  end

  local diff_shortcuts = diff_view_shortcuts()
  local default_action = non_text_preview.resolve_default_action(images_cfg)
  local default_key = type(diff_shortcuts.image_default_action) == "string" and diff_shortcuts.image_default_action or "<localleader>io"
  local fallback_key = type(diff_shortcuts.image_fallback_menu) == "string" and diff_shortcuts.image_fallback_menu
    or "<localleader>im"
  if vim.api.nvim_get_current_buf() == bufnr then
    notify_warn(string.format(
      "Image render fallback: %s. Press %s for '%s' or %s for the fallback menu.",
      type(reason) == "string" and reason ~= "" and reason or "preview unavailable",
      default_key ~= "" and default_key or "<localleader>io",
      default_action,
      fallback_key ~= "" and fallback_key or "<localleader>im"
    ))
    open_image_fallback_menu()
  end
end

function NonTextPreview.register(M, ctx)
  runtime.diff_view_shortcuts = type(ctx) == "table" and ctx.diff_view_shortcuts or nil
  runtime.resolve_active_pr = type(ctx) == "table" and ctx.resolve_active_pr or nil

  M.overview_preview_markdown_link = overview_preview_markdown_link
  M.open_image_fallback_menu = open_image_fallback_menu
  M.run_image_fallback_default_action = run_image_fallback_default_action
  M.run_non_text_default_action = run_non_text_default_action
  M.open_non_text_actions_menu = open_non_text_actions_menu
  M.run_non_text_action_at_cursor = run_non_text_action_at_cursor
  M.on_image_render_fallback = on_image_render_fallback
end

non_text_preview.resolve_attachment_filename = resolve_attachment_filename

return NonTextPreview
