local M = {}
local config = require("gh-pr.config")

function M.debug(msg)
        if config.debug then
                vim.notify(msg, vim.log.levels.DEBUG)
        end
end

---Check if the current working directory is inside a git repository.
---@return boolean
function M.in_git_repo()
	local output = vim.fn.system({ "git", "rev-parse", "--is-inside-work-tree" })
	return vim.v.shell_error == 0 and vim.trim(output) == "true"
end

---Ensure the plugin is executed inside a git repository.
---@return boolean ok
function M.ensure_git_repo()
	if M.in_git_repo() then
		return true
	end
	vim.notify("gh-pr requires a git repository", vim.log.levels.ERROR)
	return false
end

return M
