local M = {}
local utils = require("gh-pr.utils")

local reviewed = {}

-- Fetch open pull requests for the authenticated user using the `gh` CLI.
-- Returns an array of tables with fields: number, title, reviewDecision,
-- reviewRequests (array), reviews (array).
-- Requires the GitHub CLI to be installed and authenticated.
local function read_gh_json(cmd)
        if not utils.ensure_git_repo() then
                return {}
        end
        utils.debug("Running: " .. table.concat(cmd, " "))
        local output = vim.fn.system(cmd)
        if vim.v.shell_error ~= 0 then
                utils.debug("Command failed: " .. output)
                vim.notify("gh command failed: " .. output, vim.log.levels.ERROR)
                return {}
        end
        local ok, decoded = pcall(vim.json.decode, output)
        if not ok then
                utils.debug("Failed to parse output: " .. output)
                vim.notify("failed to parse gh output: " .. output, vim.log.levels.ERROR)
                return {}
        end
        return decoded
end

---Fetch open pull requests authored by the authenticated user.
---@return table[] pull_requests
function M.fetch()
        local cmd = {
                "gh",
                "pr",
                "list",
                "--state",
                "open",
                "--author",
                "@me",
                "--json",
                "number,title,reviewRequests,reviews",
        }
        local prs = read_gh_json(cmd)
	for _, pr in ipairs(prs) do
		pr.reviewDecision = M.compute_review_decision(pr)
	end
	return prs
end

---Fetch open pull requests that request a review from the authenticated user.
---@return table[] pull_requests
function M.fetch_assigned()
        local cmd = {
                "gh",
                "pr",
                "list",
                "--state",
                "open",
                "--search",
                "review-requested:@me",
                "--json",
                "number,title,reviewRequests,reviews",
        }
        local prs = read_gh_json(cmd)
        for _, pr in ipairs(prs) do
                pr.reviewDecision = M.compute_review_decision(pr)
        end
        return prs
end

---Fetch all open pull requests for the current repository.
---@return table[] pull_requests
function M.fetch_all()
        local cmd = {
                "gh",
                "pr",
                "list",
                "--state",
                "open",
                "--json",
                "number,title,reviewRequests,reviews",
        }
        local prs = read_gh_json(cmd)
        for _, pr in ipairs(prs) do
                pr.reviewDecision = M.compute_review_decision(pr)
        end
        return prs
end

---Infer the overall review decision for a pull request.
---@param pr table
---@return string
function M.compute_review_decision(pr)
	local by_login = {}
	for _, review in ipairs(pr.reviews or {}) do
		if review.author and review.author.login then
			by_login[review.author.login] = review.state
		end
	end
	for _, state in pairs(by_login) do
		if state == "CHANGES_REQUESTED" then
			return "CHANGES_REQUESTED"
		end
	end
	local approved = false
	for _, state in pairs(by_login) do
		if state == "APPROVED" then
			approved = true
		end
	end
	if not approved or #(pr.reviewRequests or {}) > 0 then
		return "REVIEW_REQUIRED"
	end
	return "APPROVED"
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
			local state = by_login[login] or "PENDING"
			table.insert(parts, string.format("%s(%s)", login, state))
		end
	end
	return table.concat(parts, ", ")
end

---Fetch detailed information for a pull request, including changed files and
---repository/branch references.
---@param number integer
---@return table
function M.fetch_details(number)
	local fields = table.concat({
                "files",
                "baseRefName",
                "headRefName",
                "headRepository",
        }, ",")
        local cmd = { "gh", "pr", "view", tostring(number), "--json", fields }
        return read_gh_json(cmd)
end

local has_vim_base64, vim_base64 = pcall(require, "vim.base64")

local function decode_base64(data)
        if has_vim_base64 then
                return vim_base64.decode(data)
        end
        if vim.fn.executable("base64") == 1 then
                local decoded = vim.fn.system({ "base64", "--decode" }, data)
                if vim.v.shell_error == 0 then
                        return decoded
                end
                utils.debug("base64 command failed: " .. decoded)
        else
                utils.debug("'base64' executable not found")
        end
        return ""
end

local function current_repo()
        local url = vim.fn.system({ "git", "remote", "get-url", "origin" })
        if vim.v.shell_error ~= 0 then
                return { owner = "", name = "" }
        end
        url = vim.trim(url)
        local owner, name = url:match("[/:]([^/]+)/([^/]+)%.git$")
        if not owner or not name then
                owner, name = url:match("[/:]([^/]+)/([^/]+)$")
                if name then
                        name = name:gsub("%.git$", "")
                end
        end
        return { owner = owner or "", name = name or "" }
end

local function file_content(repo, ref, path)
        local owner = repo.owner and repo.owner.login or repo.owner or ""
        local name = repo.name
        local api = string.format("repos/%s/%s/contents/%s", owner, name, path)
        local cmd = { "gh", "api", api, "--raw-field", "ref=" .. ref }
        local data = read_gh_json(cmd)
        return decode_base64(data.content or "")
end

---Open a diff view for a file from the pull request.
---@param details table Output of fetch_details
---@param file table File information from the PR
function M.open_file_diff(details, file)
        local path = file.path or file.filename
        if not path then
                return
        end
        local repo = current_repo()
        local left = file_content(repo, details.baseRefName, path)
        local right = file_content(details.headRepository, details.headRefName, path)
        local ft = vim.filetype.match({ filename = path }) or ""
        vim.cmd("tabnew")
        local buf_left = vim.api.nvim_get_current_buf()
        local win_left = vim.api.nvim_get_current_win()
	vim.api.nvim_buf_set_lines(buf_left, 0, -1, false, vim.split(left, "\n", { plain = true }))
	vim.api.nvim_buf_set_option(buf_left, "buftype", "nofile")
	vim.api.nvim_buf_set_option(buf_left, "bufhidden", "wipe")
	vim.api.nvim_buf_set_option(buf_left, "filetype", ft)
	vim.api.nvim_buf_set_name(buf_left, path .. " (base)")
        vim.b[buf_left].gh_pr_path = path
        vim.b[buf_left].gh_pr_reviewed = reviewed[path] or false
        local statusline = "%f %=%{b:gh_pr_reviewed and '[reviewed]' or '[unreviewed]'}"
        vim.api.nvim_win_set_option(win_left, "statusline", statusline)
        vim.cmd("vsplit")
        local win_right = vim.api.nvim_get_current_win()
        local buf_right = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_win_set_buf(win_right, buf_right)
        vim.api.nvim_buf_set_lines(buf_right, 0, -1, false, vim.split(right, "\n", { plain = true }))
	vim.api.nvim_buf_set_option(buf_right, "buftype", "nofile")
	vim.api.nvim_buf_set_option(buf_right, "bufhidden", "wipe")
	vim.api.nvim_buf_set_option(buf_right, "filetype", ft)
	vim.api.nvim_buf_set_name(buf_right, path .. " (PR)")
        vim.b[buf_right].gh_pr_path = path
        vim.b[buf_right].gh_pr_reviewed = reviewed[path] or false
        vim.api.nvim_win_set_option(win_right, "statusline", statusline)
	vim.cmd("wincmd h")
	vim.cmd("diffthis")
	vim.cmd("wincmd l")
	vim.cmd("diffthis")
end

function M.toggle_reviewed()
	local buf = vim.api.nvim_get_current_buf()
	local path = vim.b[buf].gh_pr_path
	if not path then
		return
	end
	reviewed[path] = not reviewed[path]
	for _, b in ipairs(vim.api.nvim_list_bufs()) do
		if vim.b[b].gh_pr_path == path then
			vim.b[b].gh_pr_reviewed = reviewed[path]
		end
	end
end

---Move to the next diff hunk when viewing a pull request file.
function M.next_change()
	if vim.wo.diff then
		vim.cmd("normal! ]c")
	end
end

---Move to the previous diff hunk when viewing a pull request file.
function M.prev_change()
	if vim.wo.diff then
		vim.cmd("normal! [c")
	end
end

return M
