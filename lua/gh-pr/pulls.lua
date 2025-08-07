local M = {}

-- Fetch open pull requests for the authenticated user using the `gh` CLI.
-- Returns an array of tables with fields: number, title, reviewDecision,
-- reviewRequests (array), reviews (array).
-- Requires the GitHub CLI to be installed and authenticated.
local function read_gh_json(cmd)
  local output = vim.fn.system(cmd)
  if vim.v.shell_error ~= 0 then
    vim.notify('gh command failed: ' .. output, vim.log.levels.ERROR)
    return {}
  end
  local ok, decoded = pcall(vim.json.decode, output)
  if not ok then
    vim.notify('failed to parse gh output: ' .. output, vim.log.levels.ERROR)
    return {}
  end
  return decoded
end

---Fetch open pull requests authored by the authenticated user.
---@return table[] pull_requests
function M.fetch()
  local cmd = {
    'gh', 'search', 'prs',
    '--state', 'open',
    '--author', '@me',
    '--json', 'number,title,reviewDecision,reviewRequests,reviews'
  }
  return read_gh_json(cmd)
end

---Compute reviewer states for a pull request.
---@param pr table
---@return string reviewer_summary
function M.reviewer_summary(pr)
  local by_login = {}
  for _, review in ipairs(pr.reviews or {}) do
    if review.author and review.author.login then
      by_login[review.author.login] = review.state
    end
  end
  local parts = {}
  for _, req in ipairs(pr.reviewRequests or {}) do
    local login = req.login or (req.requestedReviewer and req.requestedReviewer.login)
    if login then
      local state = by_login[login] or 'PENDING'
      table.insert(parts, string.format('%s(%s)', login, state))
    end
  end
  return table.concat(parts, ', ')
end

return M

