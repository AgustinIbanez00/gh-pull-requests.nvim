if vim.g.loaded_gh_pr then
	return
end
vim.g.loaded_gh_pr = true

require("gh-pr").setup()

vim.api.nvim_create_user_command("GhPrList", function()
	require("gh-pr").open_pull_requests()
end, {})

vim.api.nvim_create_user_command("GhPrToggleReviewed", function()
	require("gh-pr.pulls").toggle_reviewed()
end, {})
