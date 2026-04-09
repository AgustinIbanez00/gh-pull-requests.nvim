local M = {}

local gh = require("gh-pr.gh")

local function normalize_opts(opts)
  return type(opts) == "table" and opts or {}
end

local function command_opts(opts)
  opts = normalize_opts(opts)
  return {
    cwd = type(opts.cwd) == "string" and opts.cwd ~= "" and opts.cwd or nil,
    timeout_ms = opts.timeout_ms,
    stdin = opts.stdin,
  }
end

local function parse_remote_url(url)
  if not url or url == "" then
    return nil
  end

  local owner, repo = url:match("github%.com[:/](.+)/(.+)%.git$")
  if not owner then
    owner, repo = url:match("github%.com[:/](.+)/(.+)$")
  end

  if not owner or not repo then
    return nil
  end

  repo = repo:gsub("%.git$", "")

  if owner == "" or repo == "" then
    return nil
  end

  return {
    owner = owner,
    name = repo,
  }
end

function M.in_git_repo(opts)
  local output = gh.run_command({ "git", "rev-parse", "--is-inside-work-tree" }, command_opts(opts))
  return output and vim.trim(output) == "true"
end

function M.in_git_repo_async(opts, callback)
  callback = type(callback) == "function" and callback or function() end
  gh.run_command_async({ "git", "rev-parse", "--is-inside-work-tree" }, command_opts(opts), function(output, err)
    if not output then
      callback(false, err)
      return
    end

    callback(vim.trim(output) == "true", nil)
  end)
end

function M.ensure_git_repo(opts)
  if not M.in_git_repo(opts) then
    vim.notify("gh-pr requires a git repository", vim.log.levels.ERROR)
    return false
  end

  return true
end

function M.git_root(opts)
  local output, err = gh.run_command({ "git", "rev-parse", "--show-toplevel" }, command_opts(opts))
  if not output then
    return nil, err
  end

  return vim.trim(output), nil
end

function M.git_root_async(opts, callback)
  callback = type(callback) == "function" and callback or function() end
  gh.run_command_async({ "git", "rev-parse", "--show-toplevel" }, command_opts(opts), function(output, err)
    if not output then
      callback(nil, err)
      return
    end

    callback(vim.trim(output), nil)
  end)
end

function M.current_branch(opts)
  local output, err = gh.run_command({ "git", "branch", "--show-current" }, command_opts(opts))
  if not output then
    return nil, err
  end

  local branch = vim.trim(output)
  if branch == "" then
    return nil, "Detached HEAD or current branch is unavailable"
  end

  return branch, nil
end

function M.current_branch_async(opts, callback)
  callback = type(callback) == "function" and callback or function() end
  gh.run_command_async({ "git", "branch", "--show-current" }, command_opts(opts), function(output, err)
    if not output then
      callback(nil, err)
      return
    end

    local branch = vim.trim(output)
    if branch == "" then
      callback(nil, "Detached HEAD or current branch is unavailable")
      return
    end

    callback(branch, nil)
  end)
end

function M.resolve_repository(remotes, opts)
  remotes = remotes or { "origin", "upstream" }

  for _, remote in ipairs(remotes) do
    local url = gh.run_command({ "git", "remote", "get-url", remote }, command_opts(opts))
    if url then
      local parsed = parse_remote_url(vim.trim(url))
      if parsed then
        parsed.remote = remote
        parsed.full_name = parsed.owner .. "/" .. parsed.name
        return parsed, nil
      end
    end
  end

  return nil, "Failed to resolve GitHub repository from configured remotes"
end

function M.resolve_repository_async(remotes, opts, callback)
  remotes = remotes or { "origin", "upstream" }
  opts = command_opts(opts)
  callback = type(callback) == "function" and callback or function() end

  local index = 1

  local function next_remote()
    local remote = remotes[index]
    if type(remote) ~= "string" or remote == "" then
      callback(nil, "Failed to resolve GitHub repository from configured remotes")
      return
    end

    gh.run_command_async({ "git", "remote", "get-url", remote }, opts, function(url)
      if url then
        local parsed = parse_remote_url(vim.trim(url))
        if parsed then
          parsed.remote = remote
          parsed.full_name = parsed.owner .. "/" .. parsed.name
          callback(parsed, nil)
          return
        end
      end

      index = index + 1
      next_remote()
    end)
  end

  next_remote()
end

function M.probe_workspace_async(opts, callback)
  opts = normalize_opts(opts)
  callback = type(callback) == "function" and callback or function() end

  local cwd = type(opts.cwd) == "string" and opts.cwd ~= "" and opts.cwd or vim.fn.getcwd()
  local gate = type(opts.gate) == "string" and opts.gate or "github_repo"
  local remotes = type(opts.remotes) == "table" and opts.remotes or { "origin", "upstream" }

  M.in_git_repo_async({ cwd = cwd }, function(is_git, git_err)
    if not is_git then
      callback({
        cwd = cwd,
        eligible = false,
        status = "not_git",
        error = git_err,
      })
      return
    end

    M.git_root_async({ cwd = cwd }, function(root, root_err)
      if not root then
        callback({
          cwd = cwd,
          eligible = false,
          status = "error",
          error = root_err,
        })
        return
      end

      if gate == "git_repo" then
        callback({
          cwd = cwd,
          git_root = root,
          eligible = true,
          status = "eligible",
        })
        return
      end

      M.resolve_repository_async(remotes, { cwd = root }, function(repository, repo_err)
        if not repository then
          callback({
            cwd = cwd,
            git_root = root,
            eligible = false,
            status = "no_github_remote",
            error = repo_err,
          })
          return
        end

        callback({
          cwd = cwd,
          git_root = root,
          repository = repository,
          eligible = true,
          status = "eligible",
        })
      end)
    end)
  end)
end

return M
