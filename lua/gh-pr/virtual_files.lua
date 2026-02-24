local M = {}

local gh = require("gh-pr.gh")
local line_comments = require("gh-pr.line_comments")
local pr_service = require("gh-pr.pr_service")

local base64_chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

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
  vim.keymap.set("n", ",n", call_action("next_change"), vim.tbl_extend("force", opts, { desc = "Next PR change" }))
  vim.keymap.set("n", ",p", call_action("prev_change"), vim.tbl_extend("force", opts, { desc = "Previous PR change" }))
  vim.keymap.set("n", ",f", call_action("next_file"), vim.tbl_extend("force", opts, { desc = "Next PR file" }))
  vim.keymap.set("n", ",F", call_action("prev_file"), vim.tbl_extend("force", opts, { desc = "Previous PR file" }))
  vim.keymap.set("n", ",v", call_action("next_reviewed_file"), vim.tbl_extend("force", opts, { desc = "Next reviewed PR file" }))
  vim.keymap.set("n", ",V", call_action("prev_reviewed_file"), vim.tbl_extend("force", opts, { desc = "Previous reviewed PR file" }))
end

local function open_buffer(content, path, kind, details, pr, repo_override, comment_ctx)
  local repository = repo_override or resolve_base_repository(details)
  local buffer_name = repository and virtual_uri(kind, repository, pr.number, path) or nil

  local existing = nil
  if buffer_name then
    local found = vim.fn.bufnr(buffer_name)
    if type(found) == "number" and found > 0 and vim.api.nvim_buf_is_valid(found) then
      existing = found
    end
  end

  local bufnr = existing or vim.api.nvim_create_buf(true, true)
  local lines = vim.split(content, "\n", { plain = true })
  local ft = kind == "patch" and "diff" or (vim.filetype.match({ filename = path }) or "")

  set_buffer_content(bufnr, lines)

  vim.api.nvim_buf_set_option(bufnr, "buftype", "nofile")
  vim.api.nvim_buf_set_option(bufnr, "bufhidden", "wipe")
  vim.api.nvim_buf_set_option(bufnr, "swapfile", false)
  vim.api.nvim_buf_set_option(bufnr, "readonly", true)
  vim.api.nvim_buf_set_option(bufnr, "filetype", ft)

  if repository then
    if not existing then
      vim.api.nvim_buf_set_name(bufnr, buffer_name)
    end
    vim.b[bufnr].gh_pr_repo = repository.full_name
  end

  vim.b[bufnr].gh_pr_path = path
  vim.b[bufnr].gh_pr_number = pr.number
  vim.b[bufnr].gh_pr_file_kind = kind

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

local function patch_fallback(pr, path)
  local patch, err = pr_service.fetch_patch_for_file(pr.number, path)
  if not patch then
    return nil, err
  end
  return patch, nil
end

local function read_base_and_head(details, pr, file)
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

  if status ~= "added" then
    local fetch_base_err
    base_content, fetch_base_err = fetch_content(base_repository, details.baseRefName, base_path)
    if fetch_base_err then
      table.insert(errors, "base: " .. fetch_base_err)
    end
  end

  if status ~= "removed" then
    local fetch_head_err
    head_content, fetch_head_err = fetch_content(head_repository, details.headRefName, head_path)
    if fetch_head_err then
      table.insert(errors, "head: " .. fetch_head_err)
    end
  end

  if #errors > 0 then
    local patch_path = head_path or base_path
    local patch, patch_err = patch_fallback(pr, patch_path)
    if patch then
      return {
        patch_only = true,
        patch_content = patch,
        patch_path = patch_path,
        repo = base_repository,
      }, nil
    end

    return nil, string.format(
      "Failed to load file content (%s). Patch fallback failed: %s",
      table.concat(errors, " | "),
      patch_err or "unknown error"
    )
  end

  return {
    base_content = base_content or "",
    head_content = head_content or "",
    base_path = base_path,
    head_path = head_path,
    repo = base_repository,
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

function M.open_original(details, pr, file, opts)
  opts = opts or {}
  local data, err = read_base_and_head(details, pr, file)
  if not data then
    return nil, err
  end

  if data.patch_only then
    local patch_buf = open_buffer(data.patch_content, data.patch_path, "patch", details, pr, data.repo)
    vim.api.nvim_win_set_buf(0, patch_buf)
    return patch_buf, nil
  end

  local comment_ctx = build_comment_ctx(opts.line_comments, "base", {
    data.base_path,
    data.head_path,
    file.path,
    file.filename,
    file.previousFilename,
    file.previous_filename,
  })
  local buf = open_buffer(data.base_content, data.base_path, "base", details, pr, data.repo, comment_ctx)
  vim.api.nvim_win_set_buf(0, buf)
  return buf, nil
end

function M.open_modified(details, pr, file, opts)
  opts = opts or {}
  local data, err = read_base_and_head(details, pr, file)
  if not data then
    return nil, err
  end

  if data.patch_only then
    local patch_buf = open_buffer(data.patch_content, data.patch_path, "patch", details, pr, data.repo)
    vim.api.nvim_win_set_buf(0, patch_buf)
    return patch_buf, nil
  end

  local comment_ctx = build_comment_ctx(opts.line_comments, "head", {
    data.head_path,
    data.base_path,
    file.path,
    file.filename,
    file.previousFilename,
    file.previous_filename,
  })
  local buf = open_buffer(data.head_content, data.head_path, "head", details, pr, data.repo, comment_ctx)
  vim.api.nvim_win_set_buf(0, buf)
  return buf, nil
end

function M.open_diff(details, pr, file, opts)
  opts = opts or {}
  local data, err = read_base_and_head(details, pr, file)
  if not data then
    return nil, err
  end

  if data.patch_only then
    vim.cmd("tabnew")
    local patch_buf = open_buffer(data.patch_content, data.patch_path, "patch", details, pr, data.repo)
    vim.api.nvim_win_set_buf(0, patch_buf)
    return { patch_buf = patch_buf }, nil
  end

  vim.cmd("tabnew")
  local base_comment_ctx = build_comment_ctx(opts.line_comments, "base", {
    data.base_path,
    data.head_path,
    file.path,
    file.filename,
    file.previousFilename,
    file.previous_filename,
  })
  local base_buf = open_buffer(data.base_content, data.base_path, "base", details, pr, data.repo, base_comment_ctx)
  vim.api.nvim_win_set_buf(0, base_buf)

  vim.cmd("vsplit")
  local head_comment_ctx = build_comment_ctx(opts.line_comments, "head", {
    data.head_path,
    data.base_path,
    file.path,
    file.filename,
    file.previousFilename,
    file.previous_filename,
  })
  local head_buf = open_buffer(data.head_content, data.head_path, "head", details, pr, data.repo, head_comment_ctx)
  vim.api.nvim_win_set_buf(0, head_buf)

  vim.cmd("wincmd h")
  vim.cmd("diffthis")
  vim.cmd("wincmd l")
  vim.cmd("diffthis")

  return { base_buf = base_buf, head_buf = head_buf }, nil
end

function M.open_commit_patch(details, pr, commit, opts)
  opts = opts or {}
  local content, path, err = build_commit_patch_text(commit)
  if not content then
    return nil, err
  end

  if opts.new_tab ~= false then
    vim.cmd("tabnew")
  end

  local repo = resolve_base_repository(details)
  local patch_buf = open_buffer(content, path, "patch", details, pr, repo)
  vim.b[patch_buf].gh_pr_commit_oid = commit.oid
  vim.b[patch_buf].gh_pr_commit_url = commit.url
  vim.b[patch_buf].gh_pr_commit_headline = commit.headline
  vim.api.nvim_win_set_buf(0, patch_buf)
  return patch_buf, nil
end

return M
