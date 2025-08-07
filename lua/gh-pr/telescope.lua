local M = {}

local pulls = require("gh-pr.pulls")

local function make_display(pr)
	local reviewers = pulls.reviewer_summary(pr)
	local decision = pr.reviewDecision or "UNKNOWN"
	return string.format("#%d %s [%s] %s", pr.number, pr.title, decision, reviewers)
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
			prompt_title = "My Pull Requests",
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
					local details = pulls.fetch_details(selection.value.number)
					local files = details.files or {}
					if vim.tbl_isempty(files) then
						vim.notify("no files in pull request", vim.log.levels.WARN)
						return
					end
					pickers
						.new({}, {
							prompt_title = "Changed Files",
							finder = finders.new_table({
								results = files,
								entry_maker = function(f)
									return { value = f, display = f.path or f.filename, ordinal = f.path or f.filename }
								end,
							}),
							sorter = conf.generic_sorter({}),
							attach_mappings = function(fbuf, fmap)
								local function select_file()
									local fsel = action_state.get_selected_entry()
									actions.close(fbuf)
									if fsel and fsel.value then
										pulls.open_file_diff(details, fsel.value)
									end
								end
								fmap("i", "<CR>", select_file)
								fmap("n", "<CR>", select_file)
								return true
							end,
						})
						:find()
				end
				map("i", "<CR>", select_pr)
				map("n", "<CR>", select_pr)
				return true
			end,
		})
		:find()
end

return M
