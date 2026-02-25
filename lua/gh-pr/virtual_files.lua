local M = {}

local config = require("gh-pr.config")
local gh = require("gh-pr.gh")
local line_comments = require("gh-pr.line_comments")
local state = require("gh-pr.state")

local base64_chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local unified_highlight_ns = vim.api.nvim_create_namespace("gh-pr-unified-diff")

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

local function fetch_content(repository, ref, path)
  if not repository or not ref or not path then
    return "", "Missing repository/ref/path to fetch content"
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
    return "", err
  end

  if payload.encoding ~= "base64" then
    return "", nil
  end

  return decode_base64(payload.content), nil
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
  vim.api.nvim_buf_set_option(bufnr, "modifiable", false)
  if was_readonly then
    vim.api.nvim_buf_set_option(bufnr, "readonly", true)
  end
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
  return {
    mode = normalize_diff_mode(options.mode, "vertical"),
    ignore_whitespace = options.ignore_whitespace == true,
    shortcuts = type(options.shortcuts) == "table" and options.shortcuts or {},
  }
end

local function resolve_diff_view_shortcuts()
  local configured = resolve_configured_diff_view()
  local shortcuts = configured.shortcuts
  return {
    toggle_whitespace = type(shortcuts.toggle_whitespace) == "string" and shortcuts.toggle_whitespace or ",dw",
    cycle_mode = type(shortcuts.cycle_mode) == "string" and shortcuts.cycle_mode or ",dm",
    set_vertical = type(shortcuts.set_vertical) == "string" and shortcuts.set_vertical or ",dv",
    set_horizontal = type(shortcuts.set_horizontal) == "string" and shortcuts.set_horizontal or ",dh",
    set_unified = type(shortcuts.set_unified) == "string" and shortcuts.set_unified or ",du",
  }
end

function M.resolve_diff_view_options(overrides)
  local configured = resolve_configured_diff_view()
  local persisted = type(state.get_diff_view_prefs) == "function" and state.get_diff_view_prefs() or {}
  local options = vim.tbl_deep_extend("force", configured, type(persisted) == "table" and persisted or {})
  options.mode = normalize_diff_mode(options.mode, configured.mode)
  options.ignore_whitespace = options.ignore_whitespace == true

  if type(overrides) == "table" then
    if overrides.view_mode ~= nil then
      options.mode = normalize_diff_mode(overrides.view_mode, options.mode)
    end
    if type(overrides.ignore_whitespace) == "boolean" then
      options.ignore_whitespace = overrides.ignore_whitespace
    end
  end

  return options
end

local function set_pr_buffer_keymaps(bufnr)
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
  vim.keymap.set("n", "gc", call_action("add_inline_comment"), vim.tbl_extend("force", opts, { desc = "Add inline PR comment" }))
  vim.keymap.set("x", "gc", call_action("add_inline_comment_visual"), vim.tbl_extend("force", opts, {
    desc = "Add inline PR comment for selection",
  }))
  vim.keymap.set(
    "n",
    "R",
    call_action("refresh_current_diff_buffer"),
    vim.tbl_extend("force", opts, { desc = "Refresh current diff from GitHub" })
  )
  vim.keymap.set("n", "q", call_action("close_quick"), vim.tbl_extend("force", opts, { desc = "Close quick diff view" }))
  vim.keymap.set(
    "n",
    "Q",
    call_action("close_all_and_open_review"),
    vim.tbl_extend("force", opts, { desc = "Close diff views and open PR Review" })
  )
  vim.keymap.set("n", "?", call_action("show_diff_shortcuts"), vim.tbl_extend("force", opts, { desc = "Show PR diff shortcuts" }))
  vim.keymap.set("n", ",n", call_action("next_change"), vim.tbl_extend("force", opts, { desc = "Next PR change" }))
  vim.keymap.set("n", ",p", call_action("prev_change"), vim.tbl_extend("force", opts, { desc = "Previous PR change" }))
  vim.keymap.set("n", ",f", call_action("next_file"), vim.tbl_extend("force", opts, { desc = "Next PR file" }))
  vim.keymap.set("n", ",F", call_action("prev_file"), vim.tbl_extend("force", opts, { desc = "Previous PR file" }))
  vim.keymap.set("n", ",v", call_action("next_reviewed_file"), vim.tbl_extend("force", opts, { desc = "Next reviewed PR file" }))
  vim.keymap.set("n", ",V", call_action("prev_reviewed_file"), vim.tbl_extend("force", opts, { desc = "Previous reviewed PR file" }))
  if diff_shortcuts.toggle_whitespace ~= "" then
    vim.keymap.set(
      "n",
      diff_shortcuts.toggle_whitespace,
      call_action("toggle_diff_whitespace"),
      vim.tbl_extend("force", opts, { desc = "Toggle whitespace diff mode" })
    )
  end
  if diff_shortcuts.cycle_mode ~= "" then
    vim.keymap.set(
      "n",
      diff_shortcuts.cycle_mode,
      call_action("cycle_diff_view_mode"),
      vim.tbl_extend("force", opts, { desc = "Cycle diff render mode" })
    )
  end
  if diff_shortcuts.set_vertical ~= "" then
    vim.keymap.set(
      "n",
      diff_shortcuts.set_vertical,
      call_action("set_diff_view_mode_vertical"),
      vim.tbl_extend("force", opts, { desc = "Set vertical diff mode" })
    )
  end
  if diff_shortcuts.set_horizontal ~= "" then
    vim.keymap.set(
      "n",
      diff_shortcuts.set_horizontal,
      call_action("set_diff_view_mode_horizontal"),
      vim.tbl_extend("force", opts, { desc = "Set horizontal diff mode" })
    )
  end
  if diff_shortcuts.set_unified ~= "" then
    vim.keymap.set(
      "n",
      diff_shortcuts.set_unified,
      call_action("set_diff_view_mode_unified"),
      vim.tbl_extend("force", opts, { desc = "Set unified diff mode" })
    )
  end
  vim.keymap.set(
    "n",
    ",rs",
    call_action("submit_pending_comment_review"),
    vim.tbl_extend("force", opts, { desc = "Submit pending comment review" })
  )
  vim.keymap.set(
    "n",
    ",ra",
    call_action("submit_pending_approve_review"),
    vim.tbl_extend("force", opts, { desc = "Submit pending approve review" })
  )
  vim.keymap.set(
    "n",
    ",rr",
    call_action("submit_pending_request_changes_review"),
    vim.tbl_extend("force", opts, { desc = "Submit pending request changes review" })
  )
  vim.keymap.set(
    "n",
    ",rd",
    call_action("discard_pending_review"),
    vim.tbl_extend("force", opts, { desc = "Discard pending review" })
  )
  vim.keymap.set(
    "n",
    ",x",
    call_action("toggle_review_tree"),
    vim.tbl_extend("force", opts, { desc = "Toggle PR Review source" })
  )
end

local function apply_line_highlights(bufnr, highlights)
  vim.api.nvim_buf_clear_namespace(bufnr, unified_highlight_ns, 0, -1)
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

local function open_buffer(content, path, kind, details, pr, repo_override, comment_ctx, canonical_path, buffer_opts)
  buffer_opts = type(buffer_opts) == "table" and buffer_opts or {}
  local repository = repo_override or resolve_base_repository(details)
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
  local lines = vim.split(content, "\n", { plain = true })
  local ft = type(buffer_opts.filetype) == "string" and buffer_opts.filetype
    or ((kind == "patch" or kind == "unified") and "diff" or (vim.filetype.match({ filename = path }) or ""))

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
  vim.b[bufnr].gh_pr_comment_side = nil
  vim.b[bufnr].gh_pr_unified_line_map = nil

  if type(comment_ctx) == "table" then
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

  if type(buffer_opts.unified_line_map) == "table" then
    vim.b[bufnr].gh_pr_unified_line_map = buffer_opts.unified_line_map
  end

  set_pr_buffer_keymaps(bufnr)

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

local function read_base_and_head(details, _, file)
  local base_repository = resolve_base_repository(details)
  local head_repository = resolve_head_repository(details, base_repository)

  if not base_repository then
    return nil, "Unable to resolve base repository"
  end

  local base_path, head_path = resolve_paths(file)
  if not head_path or head_path == "" then
    return nil, "Unable to resolve file path"
  end

  local status = (file.status or ""):lower()

  local base_content = ""
  local head_content = ""
  local errors = {}
  local file_mode = "diff_pair"
  local fetch_base_err = nil
  local fetch_head_err = nil

  if status ~= "added" then
    base_content, fetch_base_err = fetch_content(base_repository, details.baseRefName, base_path)
    if fetch_base_err then
      table.insert(errors, "base: " .. fetch_base_err)
    end
  end

  if status ~= "removed" then
    head_content, fetch_head_err = fetch_content(head_repository, details.headRefName, head_path)
    if fetch_head_err then
      table.insert(errors, "head: " .. fetch_head_err)
    end
  end

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

  return {
    base_content = base_content or "",
    head_content = head_content or "",
    base_path = base_path,
    head_path = head_path,
    repo = base_repository,
    file_mode = file_mode,
  }, nil
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
  local chunks = vim.split(text, "\n", { plain = true })
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
  local lines = vim.split(content or "", "\n", { plain = true })
  if #lines == 1 and lines[1] == "" then
    return {}
  end
  if #lines > 0 and lines[#lines] == "" then
    table.remove(lines, #lines)
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

function M.open_original(details, pr, file, opts)
  opts = opts or {}
  local data, err = read_base_and_head(details, pr, file)
  if not data then
    return nil, err
  end

  local canonical_path = normalize_path(file.path or file.filename)
  local mode = data.file_mode == "added_single" and "added_single" or (data.file_mode == "removed_single" and "removed_single" or "diff_pair")
  local kind = mode == "added_single" and "head" or "base"
  local comment_ctx = build_comment_ctx(opts.line_comments, kind == "head" and "head" or "base", {
    data.base_path,
    data.head_path,
    file.path,
    file.filename,
    file.previousFilename,
    file.previous_filename,
  })
  local display_path = kind == "head" and data.head_path or data.base_path
  local content = kind == "head" and data.head_content or data.base_content
  local existing = resolve_existing_buffer(data.repo, pr.number, canonical_path, kind)
  if existing then
    focus_existing_buffer(existing)
  end
  local buf = open_buffer(content, display_path, kind, details, pr, data.repo, comment_ctx, canonical_path, {
    existing_bufnr = existing,
    file_mode = mode,
  })
  vim.api.nvim_win_set_buf(0, buf)
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
  local comment_ctx = build_comment_ctx(opts.line_comments, kind == "base" and "base" or "head", {
    data.head_path,
    data.base_path,
    file.path,
    file.filename,
    file.previousFilename,
    file.previous_filename,
  })
  local display_path = kind == "base" and data.base_path or data.head_path
  local content = kind == "base" and data.base_content or data.head_content
  local existing = resolve_existing_buffer(data.repo, pr.number, canonical_path, kind)
  if existing then
    focus_existing_buffer(existing)
  end
  local buf = open_buffer(content, display_path, kind, details, pr, data.repo, comment_ctx, canonical_path, {
    existing_bufnr = existing,
    file_mode = mode,
  })
  vim.api.nvim_win_set_buf(0, buf)
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
  local canonical_path = normalize_path(file.path or file.filename)
  if canonical_path == "" then
    return nil, "Unable to resolve file path"
  end

  if data.file_mode == "added_single" or data.file_mode == "removed_single" then
    local single_kind = data.file_mode == "added_single" and "head" or "base"
    local single_content = single_kind == "head" and (data.head_content or "") or (data.base_content or "")
    local single_path = single_kind == "head" and (data.head_path or canonical_path) or (data.base_path or canonical_path)
    local single_comment_ctx = build_comment_ctx(opts.line_comments, single_kind == "head" and "head" or "base", {
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
      }
    )

    pcall(vim.api.nvim_set_option_value, "diff", false, { win = target_win })
    vim.api.nvim_win_set_buf(target_win, single_buf)
    pcall(vim.api.nvim_set_current_win, target_win)
    return {
      single_buf = single_buf,
      mode = mode,
      file_mode = data.file_mode,
    }, nil
  end

  if mode == "unified" then
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
    pcall(vim.api.nvim_set_option_value, "diff", false, { win = target_win })
    vim.api.nvim_win_set_buf(target_win, unified_buf)
    pcall(vim.api.nvim_set_current_win, target_win)
    return { unified_buf = unified_buf, mode = mode }, nil
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
  local base_comment_ctx = build_comment_ctx(opts.line_comments, "base", {
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
    }
  )
  vim.api.nvim_win_set_buf(target_win, base_buf)

  local head_win = nil
  if existing_head then
    local current_tab = vim.api.nvim_win_get_tabpage(target_win)
    local existing_head_window = find_window_for_buffer(existing_head, current_tab)
    if existing_head_window and existing_head_window.winid ~= target_win then
      head_win = existing_head_window.winid
    end
  end

  if not head_win then
    pcall(vim.api.nvim_set_current_win, target_win)
    if mode == "horizontal" then
      vim.cmd("belowright split")
    else
      vim.cmd("vsplit")
    end
    head_win = vim.api.nvim_get_current_win()
  end

  local head_comment_ctx = build_comment_ctx(opts.line_comments, "head", {
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
    }
  )
  vim.api.nvim_win_set_buf(head_win, head_buf)

  pcall(vim.api.nvim_set_current_win, target_win)
  vim.cmd("diffthis")
  pcall(vim.api.nvim_set_current_win, head_win)
  vim.cmd("diffthis")
  apply_window_diffopt(target_win, diff_view.ignore_whitespace)
  apply_window_diffopt(head_win, diff_view.ignore_whitespace)
  pcall(vim.api.nvim_set_current_win, target_win)

  return { base_buf = base_buf, head_buf = head_buf, mode = mode, file_mode = "diff_pair" }, nil
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
  local next_path
  local content
  local line_highlights = nil
  local unified_line_map = nil
  local file_mode = data.file_mode == "added_single" and "added_single"
    or (data.file_mode == "removed_single" and "removed_single" or "diff_pair")
  if kind == "base" then
    if file_mode == "added_single" then
      next_path = data.head_path
      content = data.head_content or ""
    else
      next_path = data.base_path
      content = data.base_content or ""
    end
  elseif kind == "unified" then
    local diff_view = M.resolve_diff_view_options()
    next_path = data.head_path or data.base_path
    content, line_highlights, unified_line_map =
      build_unified_diff_text(data.base_content or "", data.head_content or "", diff_view.ignore_whitespace)
    file_mode = "unified"
  else
    if file_mode == "removed_single" then
      next_path = data.base_path
      content = data.base_content or ""
    else
      next_path = data.head_path
      content = data.head_content or ""
    end
  end

  if type(next_path) ~= "string" or next_path == "" then
    return false, "missing-file"
  end

  local lines = vim.split(content, "\n", { plain = true })
  set_buffer_content(bufnr, lines)
  apply_line_highlights(bufnr, line_highlights)

  local filetype = kind == "unified" and "diff" or (vim.filetype.match({ filename = next_path }) or "")
  vim.api.nvim_buf_set_option(bufnr, "filetype", filetype)
  vim.b[bufnr].gh_pr_path = next_path
  local canonical_path = normalize_path(file.path or file.filename)
  vim.b[bufnr].gh_pr_file_path = canonical_path ~= "" and canonical_path or nil
  vim.b[bufnr].gh_pr_file_mode = file_mode
  vim.b[bufnr].gh_pr_unified_line_map = nil
  if kind == "unified" and type(unified_line_map) == "table" then
    vim.b[bufnr].gh_pr_unified_line_map = unified_line_map
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

return M
