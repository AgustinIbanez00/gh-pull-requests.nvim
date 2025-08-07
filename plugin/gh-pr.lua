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

vim.api.nvim_create_user_command("GhPrNextChange", function()
        require("gh-pr.pulls").next_change()
end, {})

vim.api.nvim_create_user_command("GhPrPrevChange", function()
        require("gh-pr.pulls").prev_change()
end, {})

local map = vim.keymap.set
map("n", "<leader>ghl", "<cmd>GhPrList<CR>", { desc = "List pull requests" })
map("n", "<leader>ght", "<cmd>GhPrToggleReviewed<CR>", { desc = "Toggle reviewed" })
map("n", "<leader>ghn", "<cmd>GhPrNextChange<CR>", { desc = "Next diff change" })
map("n", "<leader>ghp", "<cmd>GhPrPrevChange<CR>", { desc = "Previous diff change" })
