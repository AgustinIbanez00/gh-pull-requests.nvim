local M = {}

local gh = require("gh-pr.gh")

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

function M.in_git_repo()
  local output = gh.run_command({ "git", "rev-parse", "--is-inside-work-tree" })
  return output and vim.trim(output) == "true"
end

function M.ensure_git_repo()
  if not M.in_git_repo() then
    vim.notify("gh-pr requires a git repository", vim.log.levels.ERROR)
    return false
  end

  return true
end

function M.git_root()
  local output, err = gh.run_command({ "git", "rev-parse", "--show-toplevel" })
  if not output then
    return nil, err
  end

  return vim.trim(output), nil
end

function M.resolve_repository(remotes)
  remotes = remotes or { "origin", "upstream" }

  for _, remote in ipairs(remotes) do
    local url = gh.run_command({ "git", "remote", "get-url", remote })
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

return M
