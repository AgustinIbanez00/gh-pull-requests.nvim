local M = {}
local utils = require("gh-pr.utils")
local config = require("gh-pr.config")

local reviewed = {}
local cached_user

local function read_gh_json(cmd)
        if not utils.ensure_git_repo() then
                return {}
        end
        local output = vim.fn.system(cmd)
        if vim.v.shell_error ~= 0 then
                vim.notify("gh command failed: " .. output, vim.log.levels.ERROR)
                return {}
        end
        local ok, decoded = pcall(vim.json.decode, output)
        if not ok then
                vim.notify("failed to parse gh output: " .. output, vim.log.levels.ERROR)
                return {}
        end
        return decoded
end

local function normalized_repo(owner, name)
        owner = owner or ""
        name = name or ""
        local full_name = ""
        if owner ~= "" and name ~= "" then
                full_name = owner .. "/" .. name
        end
        return { owner = owner, name = name, full_name = full_name }
end

local function parse_repo(repo)
        if not repo then
                return normalized_repo("", "")
        end
        if type(repo) == "string" then
                local owner, name = repo:match("([^/]+)/([^/]+)")
                return normalized_repo(owner, name)
        end
        local owner = repo.owner
        if type(owner) == "table" then
                owner = owner.login or owner.name or owner.slug or owner.userLogin or owner.id
        end
        if type(owner) ~= "string" then
                owner = repo.ownerLogin or repo.login or ""
        end
        local name = repo.name or repo.repo or repo.repository or repo.project or ""
        if (not owner or owner == "" or not name or name == "") and repo.nameWithOwner then
                local repo_owner, repo_name = repo.nameWithOwner:match("([^/]+)/([^/]+)")
                owner = owner ~= "" and owner or repo_owner or ""
                name = name ~= "" and name or repo_name or ""
        end
        if (not owner or owner == "" or not name or name == "") and repo.full_name then
                local repo_owner, repo_name = repo.full_name:match("([^/]+)/([^/]+)")
                owner = owner ~= "" and owner or repo_owner or ""
                name = name ~= "" and name or repo_name or ""
        end
        return normalized_repo(owner, name)
end

local function current_repo()
        local url = vim.fn.system({ "git", "remote", "get-url", "origin" })
        if vim.v.shell_error ~= 0 then
                return normalized_repo("", "")
        end
        url = vim.trim(url)
        local owner, name = url:match("[/:]([^/]+)/([^/]+)%.git$")
        if not owner or not name then
                owner, name = url:match("[/:]([^/]+)/([^/]+)$")
                if name then
                        name = name:gsub("%.git$", "")
                end
        end
        return normalized_repo(owner, name)
end

local function current_user()
        if cached_user ~= nil then
                return cached_user
        end
        local output = vim.fn.system({ "gh", "api", "user", "--jq", ".login" })
        if vim.v.shell_error ~= 0 then
                vim.notify("failed to determine GitHub user: " .. output, vim.log.levels.WARN)
                cached_user = ""
                return cached_user
        end
        cached_user = vim.trim(output)
        return cached_user
end

local function apply_placeholders(value)
        if type(value) ~= "string" then
                return ""
        end
        local repo = current_repo()
        local replacements = {
                owner = repo.owner or "",
                repository = repo.name or "",
                repo = repo.name or "",
                user = current_user(),
        }
        return (value:gsub("%${(.-)}", function(key)
                return replacements[key] or ""
        end))
end

local function append_option(cmd, flag, value)
        if not value or value == "" then
                return
        end
        table.insert(cmd, flag)
        table.insert(cmd, tostring(value))
end

local function extend_args(cmd, args)
        if type(args) ~= "table" then
                return
        end
        for _, arg in ipairs(args) do
                if type(arg) == "string" then
                        table.insert(cmd, apply_placeholders(arg))
                else
                        table.insert(cmd, arg)
                end
        end
end

local function normalize_nodes(collection)
        if not collection then
                return {}
        end
        if vim.tbl_islist(collection) then
                return collection
        end
        if type(collection) == "table" then
                if collection.nodes and vim.tbl_islist(collection.nodes) then
                        return collection.nodes
                end
                if collection.edges and vim.tbl_islist(collection.edges) then
                        local nodes = {}
                        for _, edge in ipairs(collection.edges) do
                                if type(edge) == "table" and edge.node then
                                        table.insert(nodes, edge.node)
                                end
                        end
                        return nodes
                end
        end
        return {}
end

local function normalize_review_requests(collection)
        local requests = normalize_nodes(collection)
        for _, req in ipairs(requests) do
                if type(req) == "table" then
                        if not req.login and type(req.requestedReviewer) == "table" then
                                req.login = req.requestedReviewer.login or req.requestedReviewer.slug or req.requestedReviewer.name
                        end
                end
        end
        return requests
end

local function normalize_reviews(collection)
        return normalize_nodes(collection)
end

local function normalize_pr(pr, repo_override, query_label)
        pr.reviewRequests = normalize_review_requests(pr.reviewRequests)
        pr.reviews = normalize_reviews(pr.reviews)
        if repo_override and (repo_override.owner ~= "" or repo_override.name ~= "") then
                pr.repository = normalized_repo(repo_override.owner, repo_override.name)
        else
                pr.repository = parse_repo(pr.repository)
        end
        pr.query_label = query_label
        if not pr.reviewDecision or pr.reviewDecision == vim.NIL then
                pr.reviewDecision = M.compute_review_decision(pr)
        end
        return pr
end

local function normalize_query_definition(def)
        if type(def) == "string" then
                def = { query = def }
        else
                def = vim.deepcopy(def)
        end
        def.label = def.label or def.name or "Pull Requests"
        def.query = def.query or def.search or def.q or "default"
        return def
end

local function fetch_default(def)
        local fields = def.fields or { "number", "title", "reviewDecision", "reviewRequests", "reviews" }
        local cmd = { "gh", "pr", "list", "--json", table.concat(fields, ",") }
        append_option(cmd, "--state", def.state or "open")
        append_option(cmd, "--limit", def.limit)
        if def.author then
                append_option(cmd, "--author", apply_placeholders(def.author))
        end
        extend_args(cmd, def.args)
        local prs = read_gh_json(cmd)
        local repo = current_repo()
        local results = {}
        for _, pr in ipairs(prs) do
                table.insert(results, normalize_pr(pr, repo, def.label))
        end
        return results
end

local function fetch_with_search(def)
        local search = vim.trim(apply_placeholders(def.query))
        if search == "" then
                return {}
        end
        local fields = def.fields or { "number", "title", "reviewDecision", "reviewRequests", "reviews", "repository" }
        local cmd = { "gh", "search", "prs", "--json", table.concat(fields, ",") }
        append_option(cmd, "--limit", def.limit)
        append_option(cmd, "--sort", def.sort)
        append_option(cmd, "--order", def.order)
        extend_args(cmd, def.args)
        if search:match("^%s*-") then
                table.insert(cmd, "--")
        end
        table.insert(cmd, search)
        local prs = read_gh_json(cmd)
        local results = {}
        for _, pr in ipairs(prs) do
                table.insert(results, normalize_pr(pr, nil, def.label))
        end
        return results
end

---Fetch pull requests according to configured queries.
---@return table[] groups Array of tables { label, definition, pull_requests }
function M.fetch_by_query()
        local groups = {}
        local opts = config.get()
        for _, definition in ipairs(opts.queries or {}) do
                local def = normalize_query_definition(definition)
                local list
                if def.query == "default" then
                        list = fetch_default(def)
                else
                        list = fetch_with_search(def)
                end
                table.insert(groups, {
                        label = def.label,
                        definition = def,
                        pull_requests = list,
                })
        end
        return groups
end

---Fetch pull requests combining all configured queries.
---@return table[]
function M.fetch()
        local groups = M.fetch_by_query()
        local aggregated = {}
        for _, group in ipairs(groups) do
                for _, pr in ipairs(group.pull_requests or {}) do
                        table.insert(aggregated, pr)
                end
        end
        return aggregated
end

---Fetch detailed information for a pull request, including changed files.
---@param pr table
---@return table
function M.fetch_details(pr)
        if not pr then
                return {}
        end
        local repo = pr.repository or current_repo()
        local fields = table.concat({
                "files",
                "baseRefName",
                "headRefName",
                "headRepository",
                "reviewThreads",
                "comments",
        }, ",")
        local cmd = { "gh", "pr", "view", tostring(pr.number), "--json", fields }
        if repo.owner ~= "" and repo.name ~= "" then
                table.insert(cmd, "--repo")
                table.insert(cmd, string.format("%s/%s", repo.owner, repo.name))
        end
        local details = read_gh_json(cmd)
        details.baseRepository = normalized_repo(repo.owner, repo.name)
        if details.headRepository then
                details.headRepository = parse_repo(details.headRepository)
        end
        details.files = normalize_nodes(details.files)
        details.reviewThreads = normalize_nodes(details.reviewThreads)
        for _, thread in ipairs(details.reviewThreads or {}) do
                thread.comments = normalize_nodes(thread.comments)
        end
        details.comments = normalize_nodes(details.comments)
        return details
end

local function decode_base64(data)
        local decoded = vim.fn.system({ "base64", "--decode" }, data)
        if vim.v.shell_error ~= 0 then
                return ""
        end
        return decoded
end

local function file_content(repo, ref, path)
        local owner = repo.owner or ""
        local name = repo.name or ""
        if owner == "" or name == "" then
                return ""
        end
        local api = string.format("repos/%s/%s/contents/%s?ref=%s", owner, name, path, ref)
        local data = read_gh_json({ "gh", "api", api })
        return decode_base64(data.content or "")
end

---Open a diff view for a file from the pull request.
---@param pr table
---@param details table Output of fetch_details
---@param file table File information from the PR
local comment_highlight_namespace = vim.api.nvim_create_namespace("gh-pr-comment-target")
local comment_highlight_defined = false

local function ensure_comment_highlight()
        if comment_highlight_defined then
                return
        end
        comment_highlight_defined = true
        local ok = pcall(vim.api.nvim_set_hl, 0, "GhPRCommentTarget", { link = "Search" })
        if not ok then
                vim.api.nvim_set_hl(0, "GhPRCommentTarget", { fg = "#FFFF00", bg = "#5F005F" })
        end
end

function M.open_file_diff(pr, details, file, opts)
        local path = file.path or file.filename
        if not path then
                return
        end
        local base_repo = details.baseRepository or pr.repository or current_repo()
        local head_repo = details.headRepository or base_repo
        local base_ref = details.baseRefName or ""
        local head_ref = details.headRefName or ""
        if base_ref == "" or head_ref == "" then
                vim.notify("missing ref information for pull request", vim.log.levels.WARN)
                return
        end
        opts = opts or {}
        local left = file_content(base_repo, base_ref, path)
        local right = file_content(head_repo, head_ref, path)
        local ft = vim.filetype.match({ filename = path }) or ""
        local statusline = "%f %=%{b:gh_pr_reviewed ? '[reviewed]' : '[unreviewed]'}"
        vim.cmd("tabnew")
        local win_left = vim.api.nvim_get_current_win()
        local buf_left = vim.api.nvim_get_current_buf()
        vim.api.nvim_buf_set_lines(buf_left, 0, -1, false, vim.split(left, "\n", { plain = true }))
        vim.api.nvim_buf_set_option(buf_left, "buftype", "nofile")
        vim.api.nvim_buf_set_option(buf_left, "bufhidden", "wipe")
        vim.api.nvim_buf_set_option(buf_left, "filetype", ft)
        vim.api.nvim_buf_set_name(buf_left, path .. " (base)")
        vim.b[buf_left].gh_pr_path = path
        vim.b[buf_left].gh_pr_reviewed = reviewed[path] or false
        vim.bo[buf_left].statusline = statusline
        vim.cmd("vsplit")
        local win_right = vim.api.nvim_get_current_win()
        local buf_right = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_win_set_buf(0, buf_right)
        vim.api.nvim_buf_set_lines(buf_right, 0, -1, false, vim.split(right, "\n", { plain = true }))
        vim.api.nvim_buf_set_option(buf_right, "buftype", "nofile")
        vim.api.nvim_buf_set_option(buf_right, "bufhidden", "wipe")
        vim.api.nvim_buf_set_option(buf_right, "filetype", ft)
        vim.api.nvim_buf_set_name(buf_right, path .. " (PR)")
        vim.b[buf_right].gh_pr_path = path
        vim.b[buf_right].gh_pr_reviewed = reviewed[path] or false
        vim.bo[buf_right].statusline = statusline
        vim.cmd("wincmd h")
        win_left = vim.api.nvim_get_current_win()
        vim.cmd("diffthis")
        vim.cmd("wincmd l")
        win_right = vim.api.nvim_get_current_win()
        vim.cmd("diffthis")
        local target_side = opts.side and string.upper(opts.side) or "RIGHT"
        if target_side ~= "LEFT" then
                target_side = "RIGHT"
        end
        local target_win = target_side == "LEFT" and win_left or win_right
        local target_buf = target_side == "LEFT" and buf_left or buf_right
        ensure_comment_highlight()
        vim.api.nvim_buf_clear_namespace(buf_left, comment_highlight_namespace, 0, -1)
        vim.api.nvim_buf_clear_namespace(buf_right, comment_highlight_namespace, 0, -1)
        local line = tonumber(opts.line)
        local range_start
        local range_finish
        if type(opts.range) == "table" then
                range_start = tonumber(opts.range.start or opts.range[1])
                range_finish = tonumber(opts.range.finish or opts.range[2])
        end
        if range_start and range_finish and range_start > range_finish then
                range_start, range_finish = range_finish, range_start
        end
        if not line and range_start then
                line = range_start
        end
        if range_start and range_finish then
                local max_line = vim.api.nvim_buf_line_count(target_buf)
                for row = range_start, range_finish do
                        if row >= 1 and row <= max_line then
                                vim.api.nvim_buf_add_highlight(
                                        target_buf,
                                        comment_highlight_namespace,
                                        "GhPRCommentTarget",
                                        row - 1,
                                        0,
                                        -1
                                )
                        end
                end
        elseif line then
                local max_line = vim.api.nvim_buf_line_count(target_buf)
                local row = math.min(math.max(line, 1), math.max(max_line, 1))
                vim.api.nvim_buf_add_highlight(
                        target_buf,
                        comment_highlight_namespace,
                        "GhPRCommentTarget",
                        row - 1,
                        0,
                        -1
                )
        end
        if line then
                local max_line = vim.api.nvim_buf_line_count(target_buf)
                local row = math.min(math.max(line, 1), math.max(max_line, 1))
                vim.api.nvim_set_current_win(target_win)
                vim.api.nvim_win_set_cursor(target_win, { row, 0 })
                vim.cmd("normal! zz")
        end
        if not line then
                vim.api.nvim_set_current_win(target_side == "LEFT" and win_left or win_right)
        end
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

function M.next_change()
        if vim.wo.diff then
                vim.cmd("normal! ]c")
        end
end

function M.prev_change()
        if vim.wo.diff then
                vim.cmd("normal! [c")
        end
end

return M
