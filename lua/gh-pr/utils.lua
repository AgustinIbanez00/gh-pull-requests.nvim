local M = {}

local repo = require("gh-pr.repo")

function M.in_git_repo()
  return repo.in_git_repo()
end

function M.ensure_git_repo()
  return repo.ensure_git_repo()
end

return M
