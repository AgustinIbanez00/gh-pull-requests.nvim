local M = {}

local function normalize_string(value)
  if type(value) ~= "string" then
    return ""
  end
  return vim.trim(value)
end

local function normalize_key(value)
  return normalize_string(value):lower()
end

local function normalize_bool(value)
  return value == true
end

local function normalize_list(values)
  local result = {}
  local seen = {}

  for _, value in ipairs(type(values) == "table" and values or {}) do
    local text = normalize_string(value)
    local key = normalize_key(text)
    if text ~= "" and key ~= "" and not seen[key] then
      seen[key] = true
      result[#result + 1] = text
    end
  end

  return result
end

local function split_lines(output)
  local lines = {}
  if type(output) ~= "string" or output == "" then
    return lines
  end

  for _, line in ipairs(vim.split(output, "\n", { plain = true })) do
    local text = normalize_string(line)
    if text ~= "" then
      lines[#lines + 1] = text
    end
  end
  return lines
end

local function run_git_lines(gh, args, opts)
  opts = type(opts) == "table" and opts or {}
  local command = { "git" }
  vim.list_extend(command, args)

  local output, err = gh.run_command(command, {
    cwd = opts.cwd,
    timeout_ms = opts.timeout_ms,
  })
  if not output then
    return nil, err
  end

  return split_lines(output), nil
end

local function strip_remote_prefix(ref)
  ref = normalize_string(ref)
  if ref == "" or ref:match("/HEAD$") then
    return ""
  end

  local branch = ref:match("^[^/]+/(.+)$")
  return normalize_string(branch or ref)
end

local function remote_has_head(remote_branches, head)
  local normalized_head = normalize_string(head)
  if normalized_head == "" then
    return false
  end

  for _, remote_branch in ipairs(type(remote_branches) == "table" and remote_branches or {}) do
    local remote = normalize_string(remote_branch)
    if remote == normalized_head or strip_remote_prefix(remote) == normalized_head then
      return true
    end
  end

  return false
end

local function append_unique_branch(target, seen, branch, opts)
  branch = normalize_string(branch)
  if branch == "" then
    return
  end

  local key = normalize_key(branch)
  if key == "" or seen[key] then
    return
  end

  seen[key] = true
  opts = type(opts) == "table" and opts or {}
  target[#target + 1] = {
    value = branch,
    label = branch,
    current = opts.current == true,
    base = opts.base == true,
    remote_available = opts.remote_available == true,
    remote_ref = normalize_string(opts.remote_ref),
  }
end

function M.normalize_list(values)
  return normalize_list(values)
end

function M.new_state(context)
  context = type(context) == "table" and context or {}
  return {
    title = "",
    body = "",
    head = normalize_string(context.current_branch),
    base = normalize_string(context.default_branch),
    labels = {},
    reviewers = {},
    draft = false,
  }
end

function M.remote_has_head(remote_branches, head)
  return remote_has_head(remote_branches, head)
end

function M.build_head_candidates(context)
  context = type(context) == "table" and context or {}
  local current = normalize_string(context.current_branch)
  local base = normalize_string(context.default_branch)
  local remote_branches = type(context.remote_branches) == "table" and context.remote_branches or {}
  local local_branches = type(context.local_branches) == "table" and context.local_branches or {}
  local candidates = {}
  local seen = {}

  if current ~= "" then
    append_unique_branch(candidates, seen, current, {
      current = true,
      base = current == base,
      remote_available = remote_has_head(remote_branches, current),
    })
  end

  for _, branch in ipairs(local_branches) do
    append_unique_branch(candidates, seen, branch, {
      current = branch == current,
      base = branch == base,
      remote_available = remote_has_head(remote_branches, branch),
    })
  end

  for _, remote_ref in ipairs(remote_branches) do
    local branch = strip_remote_prefix(remote_ref)
    append_unique_branch(candidates, seen, branch, {
      current = branch == current,
      base = branch == base,
      remote_available = branch ~= "",
      remote_ref = remote_ref,
    })
  end

  table.sort(candidates, function(left, right)
    if left.current ~= right.current then
      return left.current == true
    end
    if left.remote_available ~= right.remote_available then
      return left.remote_available == true
    end
    if left.base ~= right.base then
      return left.base ~= true
    end
    return normalize_key(left.value) < normalize_key(right.value)
  end)

  return candidates
end

function M.resolve_default_branch(ctx)
  ctx = type(ctx) == "table" and ctx or {}
  local branch = normalize_string(ctx.default_branch)
  if branch ~= "" then
    return branch, nil
  end

  local repository = ctx.repository
  if type(repository) ~= "table" or normalize_string(repository.full_name) == "" then
    return nil, "Unable to resolve repository default branch: missing repository"
  end

  local gh = ctx.gh or require("gh-pr.gh")
  local payload, err = gh.run_json({
    "repo",
    "view",
    repository.full_name,
    "--json",
    "defaultBranchRef",
  }, {
    cwd = ctx.cwd,
    timeout_ms = ctx.timeout_ms,
  })
  if not payload then
    return nil, err
  end

  local default = type(payload.defaultBranchRef) == "table" and normalize_string(payload.defaultBranchRef.name) or ""
  if default == "" then
    return nil, "Unable to resolve repository default branch from GitHub"
  end

  return default, nil
end

function M.resolve_context(ctx)
  ctx = type(ctx) == "table" and ctx or {}
  local repo = ctx.repo or require("gh-pr.repo")
  local pr_service = ctx.pr_service or require("gh-pr.pr_service")
  local gh = ctx.gh or require("gh-pr.gh")

  local repository = ctx.repository
  if type(repository) ~= "table" then
    local repo_err
    repository, repo_err = pr_service.resolve_repository()
    if not repository then
      return nil, repo_err
    end
  end

  local git_root = normalize_string(ctx.git_root)
  if git_root == "" then
    local root_err
    git_root, root_err = repo.git_root({ cwd = ctx.cwd })
    if not git_root then
      return nil, root_err
    end
  end

  local current_branch = normalize_string(ctx.current_branch)
  if current_branch == "" then
    local branch_err
    current_branch, branch_err = repo.current_branch({ cwd = git_root })
    if not current_branch then
      return nil, branch_err
    end
  end

  local default_branch, default_err = M.resolve_default_branch({
    gh = gh,
    repository = repository,
    cwd = git_root,
    default_branch = ctx.default_branch,
    timeout_ms = ctx.timeout_ms,
  })
  if not default_branch then
    return nil, default_err
  end

  local local_branches = ctx.local_branches
  if type(local_branches) ~= "table" then
    local branches_err
    local_branches, branches_err = run_git_lines(gh, {
      "for-each-ref",
      "--format=%(refname:short)",
      "refs/heads",
    }, {
      cwd = git_root,
      timeout_ms = ctx.timeout_ms,
    })
    if not local_branches then
      return nil, branches_err
    end
  end

  local remote_branches = ctx.remote_branches
  if type(remote_branches) ~= "table" then
    local remote_err
    remote_branches, remote_err = run_git_lines(gh, {
      "for-each-ref",
      "--format=%(refname:short)",
      "refs/remotes",
    }, {
      cwd = git_root,
      timeout_ms = ctx.timeout_ms,
    })
    if not remote_branches then
      return nil, remote_err
    end
  end

  return {
    repository = repository,
    git_root = git_root,
    current_branch = current_branch,
    default_branch = default_branch,
    local_branches = local_branches,
    remote_branches = remote_branches,
    head_candidates = M.build_head_candidates({
      current_branch = current_branch,
      default_branch = default_branch,
      local_branches = local_branches,
      remote_branches = remote_branches,
    }),
  }, nil
end

function M.validate_head(state, context)
  state = type(state) == "table" and state or {}
  context = type(context) == "table" and context or {}
  local head = normalize_string(state.head)
  local base = normalize_string(state.base ~= nil and state.base or context.default_branch)

  if head == "" then
    return nil, "Head branch is required", "head"
  end
  if base == "" then
    return nil, "Base branch is required", "base"
  end
  if head == base then
    return nil, string.format("Head branch '%s' matches the base branch. Select a pushed feature branch.", head), "head"
  end
  if not remote_has_head(context.remote_branches, head) then
    return nil, string.format("Head branch '%s' is not available on any remote. Push it first, then retry PR creation.", head), "head"
  end

  return true, nil, nil
end

function M.validate_state(state, context)
  state = type(state) == "table" and state or {}

  if normalize_string(state.title) == "" then
    return nil, "Title is required", "title"
  end

  local ok, err, field = M.validate_head(state, context)
  if not ok then
    return nil, err, field
  end

  return true, nil, nil
end

function M.build_create_command(state)
  state = type(state) == "table" and state or {}
  local args = {
    "pr",
    "create",
    "--title",
    normalize_string(state.title),
    "--body-file",
    "-",
    "--head",
    normalize_string(state.head),
    "--base",
    normalize_string(state.base),
  }

  for _, label in ipairs(normalize_list(state.labels)) do
    args[#args + 1] = "--label"
    args[#args + 1] = label
  end

  for _, reviewer in ipairs(normalize_list(state.reviewers)) do
    args[#args + 1] = "--reviewer"
    args[#args + 1] = reviewer
  end

  if normalize_bool(state.draft) then
    args[#args + 1] = "--draft"
  end

  return {
    args = args,
    stdin = type(state.body) == "string" and state.body or "",
  }
end

function M.parse_created_pr(output)
  local text = type(output) == "string" and output or ""
  local url = text:match("(https://github%.com/[%w%._%-]+/[%w%._%-]+/pull/%d+)")
  local number = url and tonumber(url:match("/pull/(%d+)$")) or nil

  if not url then
    number = tonumber(text:match("[Pp][Rr]%s*#?(%d+)"))
  end

  return {
    output = text,
    url = url,
    number = number,
  }
end

function M.summary_lines(state, context)
  state = type(state) == "table" and state or {}
  context = type(context) == "table" and context or {}
  local labels = normalize_list(state.labels)
  local reviewers = normalize_list(state.reviewers)
  local repository = type(context.repository) == "table" and normalize_string(context.repository.full_name) or ""

  local function list_summary(items)
    if vim.tbl_isempty(items) then
      return "(none)"
    end
    return table.concat(items, ", ")
  end

  local body = normalize_string(state.body)
  if body ~= "" then
    body = body:gsub("\n", " ")
    if #body > 80 then
      body = body:sub(1, 77) .. "..."
    end
  else
    body = "(empty)"
  end

  local lines = {}
  if repository ~= "" then
    lines[#lines + 1] = "Repository: " .. repository
  end
  lines[#lines + 1] = "Title: " .. (normalize_string(state.title) ~= "" and normalize_string(state.title) or "(missing)")
  lines[#lines + 1] = "Description: " .. body
  lines[#lines + 1] = "Head: " .. (normalize_string(state.head) ~= "" and normalize_string(state.head) or "(missing)")
  lines[#lines + 1] = "Base: " .. (normalize_string(state.base) ~= "" and normalize_string(state.base) or "(missing)")
  lines[#lines + 1] = "Labels: " .. list_summary(labels)
  lines[#lines + 1] = "Reviewers: " .. list_summary(reviewers)
  lines[#lines + 1] = "Draft: " .. (state.draft == true and "yes" or "no")
  return lines
end

function M.submit(state, context, callback)
  callback = type(callback) == "function" and callback or function() end
  context = type(context) == "table" and context or {}
  local ok, validation_err = M.validate_state(state, context)
  if not ok then
    callback(nil, validation_err)
    return
  end

  local gh = context.gh or require("gh-pr.gh")
  local command = M.build_create_command(state)
  gh.run_async(command.args, {
    cwd = context.git_root,
    stdin = command.stdin,
  }, function(output, err)
    if not output then
      callback(nil, err)
      return
    end

    callback(M.parse_created_pr(output), nil)
  end)
end

return M
