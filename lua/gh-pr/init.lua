local M = {}
local utils = require("gh-pr.utils")
local config = require("gh-pr.config")

---Setup gh-pr plugin.
---@param opts table|nil
function M.setup(opts)
        config.setup(opts or {})
end

---Open a picker displaying the user's open pull requests.
function M.open_pull_requests()
        if not utils.ensure_git_repo() then
                return
        end
        require("gh-pr.telescope").pull_requests()
end

---Open a tree view listing pull requests and their changed files.
function M.open_review_tree()
        if not utils.ensure_git_repo() then
                return
        end
        require("gh-pr.tree").open()
end

return M
