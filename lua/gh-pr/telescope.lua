-- luacheck: max_line_length 200
local M = {}

local pulls = require("gh-pr.pulls")

local function build_tree(files)
        local root = { name = "", type = "dir", children = {} }
        for _, f in ipairs(files) do
                local path = f.path or f.filename or ""
                local parts = vim.split(path, "/", { plain = true })
                local node = root
                for i, part in ipairs(parts) do
                        if i == #parts then
                                table.insert(node.children, { name = part, type = "file", file = f })
                        else
                                local found
                                for _, child in ipairs(node.children) do
                                        if child.type == "dir" and child.name == part then
                                                found = child
                                                break
                                        end
                                end
                                if not found then
                                        found = { name = part, type = "dir", children = {} }
                                        table.insert(node.children, found)
                                end
                                node = found
                        end
                end
        end
        return root
end
local function make_display(pr)
        local reviewers = pulls.reviewer_summary(pr)
        local decision = pr.reviewDecision or "UNKNOWN"
        local segments = {}
        if pr.query_label and pr.query_label ~= "" then
                table.insert(segments, string.format("[%s]", pr.query_label))
        end
        local repo = pr.repository and pr.repository.full_name or ""
        local identifier = string.format("#%d", pr.number)
        if repo ~= "" then
                identifier = string.format("%s %s", repo, identifier)
        end
        table.insert(segments, identifier)
        table.insert(segments, pr.title)
        local display = table.concat(segments, " ")
        display = string.format("%s [%s]", display, decision)
        if reviewers ~= "" then
                display = string.format("%s %s", display, reviewers)
        end
        return display
end

function M.pull_requests()
	local ok, pickers = pcall(require, "telescope.pickers")
	if not ok then
		vim.notify("telescope.nvim is required", vim.log.levels.ERROR)
		return
	end
	local finders = require("telescope.finders")
	local conf = require("telescope.config").values
        local pulls_data = pulls.fetch()
        if vim.tbl_isempty(pulls_data) then
                return
        end
        pickers
                .new({}, {
                        prompt_title = "GitHub Pull Requests",
			finder = finders.new_table({
				results = pulls_data,
				entry_maker = function(pr)
					return {
						value = pr,
						display = make_display(pr),
						ordinal = pr.title,
					}
				end,
			}),
			sorter = conf.generic_sorter({}),
			attach_mappings = function(prompt_bufnr, map)
				local actions = require("telescope.actions")
				local action_state = require("telescope.actions.state")
				local function select_pr()
					local selection = action_state.get_selected_entry()
					actions.close(prompt_bufnr)
					if not (selection and selection.value) then
						return
					end
                                        local details = pulls.fetch_details(selection.value)
                                        local files = details.files or {}
                                        if vim.tbl_isempty(files) then
                                                vim.notify("no files in pull request", vim.log.levels.WARN)
                                                return
                                        end
                                        local tree = build_tree(files)
                                        local function browse(node, prefix)
                                                prefix = prefix or ""
                                                pickers
                                                        .new({}, {
                                                                prompt_title = prefix == "" and "Changed Files" or prefix,
                                                                finder = finders.new_table({
                                                                        results = node.children,
                                                                        entry_maker = function(item)
                                                                                local display = item.name
                                                                                if item.type == "dir" then
                                                                                        display = item.name .. "/"
                                                                                end
                                                                                return { value = item, display = display, ordinal = item.name }
                                                                        end,
                                                                }),
                                                                sorter = conf.generic_sorter({}),
                                                                attach_mappings = function(fbuf, fmap)
                                                                        local function select_entry()
                                                                                local sel = action_state.get_selected_entry()
                                                                                actions.close(fbuf)
                                                                                if not sel or not sel.value then
                                                                                        return
                                                                                end
                                                                                local item = sel.value
                                                                                if item.type == "dir" then
                                                                                        browse(item, prefix .. item.name .. "/")
                                                                                else
                                                                                        pulls.open_file_diff(selection.value, details, item.file)
                                                                                end
                                                                        end
                                                                        fmap("i", "<CR>", select_entry)
                                                                        fmap("n", "<CR>", select_entry)
                                                                        return true
                                                                end,
                                                        })
                                                        :find()
                                        end
                                        browse(tree, "")
                                end
                                map("i", "<CR>", select_pr)
                                map("n", "<CR>", select_pr)
                                return true
                        end,
		})
		:find()
end

return M
