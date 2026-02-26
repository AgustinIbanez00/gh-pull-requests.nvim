if vim.g.loaded_gh_pr then
  return
end
vim.g.loaded_gh_pr = true

require("gh-pr").setup()

vim.api.nvim_create_user_command("GhPrOpen", function()
  require("gh-pr").open_pull_requests()
end, { desc = "Open GitHub pull request view" })

vim.api.nvim_create_user_command("GhPrList", function()
  require("gh-pr.telescope").pull_requests()
end, { desc = "List pull requests using Telescope" })

vim.api.nvim_create_user_command("GhPrComments", function(command)
  require("gh-pr").open_comments(command.args ~= "" and command.args or nil)
end, { nargs = "?", desc = "Open PR Review source (Comments section)" })

vim.api.nvim_create_user_command("GhPrStartReview", function(command)
  require("gh-pr").start_review(command.args ~= "" and command.args or nil)
end, { nargs = "?", desc = "Start PR review flow and open PR Review source" })

vim.api.nvim_create_user_command("GhPrReviewTree", function()
  require("gh-pr").open_review_tree({ toggle = true })
end, { desc = "Toggle PR Review source" })

vim.api.nvim_create_user_command("GhPrRefresh", function()
  require("gh-pr").refresh()
end, { desc = "Refresh pull request data" })

vim.api.nvim_create_user_command("GhPrOverview", function()
  require("gh-pr").open_overview()
end, { desc = "Open active pull request overview" })

vim.api.nvim_create_user_command("GhPrOverviewRefresh", function()
  require("gh-pr").refresh_overview()
end, { desc = "Refresh active pull request overview buffer" })

vim.api.nvim_create_user_command("GhPrOverviewMore", function(command)
  local section = command.fargs[1]
  local count = command.fargs[2] ~= nil and tonumber(command.fargs[2]) or nil
  require("gh-pr").overview_more(section, count)
end, {
  nargs = "+",
  complete = function(arg_lead, cmd_line)
    local parts = vim.split(cmd_line, "%s+", { trimempty = true })
    if #parts <= 2 then
      local sections = { "checks", "commits", "comments", "reviews", "threads" }
      local matches = {}
      for _, section in ipairs(sections) do
        if arg_lead == "" or section:sub(1, #arg_lead) == arg_lead then
          matches[#matches + 1] = section
        end
      end
      return matches
    end
    return {}
  end,
  desc = "Load more items in current overview section",
})

vim.api.nvim_create_user_command("GhPrCheckout", function(command)
  require("gh-pr").checkout(command.args ~= "" and command.args or nil)
end, { nargs = "?", desc = "Checkout pull request branch" })

vim.api.nvim_create_user_command("GhPrOpenDiff", function()
  require("gh-pr").open_diff()
end, { desc = "Open active file diff" })

vim.api.nvim_create_user_command("GhPrOpenOriginal", function()
  require("gh-pr").open_original()
end, { desc = "Open active file base version" })

vim.api.nvim_create_user_command("GhPrOpenModified", function()
  require("gh-pr").open_modified()
end, { desc = "Open active file head version" })

vim.api.nvim_create_user_command("GhPrOpenCommitPatch", function()
  require("gh-pr").open_commit_patch()
end, { desc = "Open selected commit patch in virtual buffer" })

vim.api.nvim_create_user_command("GhPrToggleReviewed", function()
  require("gh-pr").toggle_reviewed()
end, { desc = "Toggle viewed state for active PR file" })

vim.api.nvim_create_user_command("GhPrNextChange", function()
  require("gh-pr").next_change()
end, { desc = "Jump to next diff change" })

vim.api.nvim_create_user_command("GhPrPrevChange", function()
  require("gh-pr").prev_change()
end, { desc = "Jump to previous diff change" })

vim.api.nvim_create_user_command("GhPrApprove", function()
  require("gh-pr").approve()
end, { desc = "Approve active pull request (message + confirm)" })

vim.api.nvim_create_user_command("GhPrRequestChanges", function()
  require("gh-pr").request_changes()
end, { desc = "Request changes on active pull request (message + confirm)" })

vim.api.nvim_create_user_command("GhPrComment", function()
  require("gh-pr").comment()
end, { desc = "Submit general comment review (message + confirm)" })

vim.api.nvim_create_user_command("GhPrReviewSubmit", function()
  require("gh-pr").review_submit_pending()
end, { desc = "Submit pending review as comment (message + confirm)" })

vim.api.nvim_create_user_command("GhPrReviewApprove", function()
  require("gh-pr").review_approve_pending()
end, { desc = "Submit pending review as approve (message + confirm)" })

vim.api.nvim_create_user_command("GhPrReviewRequestChanges", function()
  require("gh-pr").review_request_changes_pending()
end, { desc = "Submit pending review as request changes (message + confirm)" })

vim.api.nvim_create_user_command("GhPrReviewDiscard", function()
  require("gh-pr").review_discard_pending()
end, { desc = "Discard current pending review (confirm)" })

vim.api.nvim_create_user_command("GhPrMerge", function(command)
  local method = command.args ~= "" and command.args or "merge"
  require("gh-pr").merge(method)
end, {
  nargs = "?",
  complete = function()
    return { "merge", "squash", "rebase" }
  end,
  desc = "Merge active pull request",
})

vim.api.nvim_create_user_command("GhPrQueryAdd", function()
  require("gh-pr").add_query()
end, { desc = "Add pull request query" })

vim.api.nvim_create_user_command("GhPrQueryEdit", function()
  require("gh-pr").edit_query()
end, { desc = "Edit pull request query" })

vim.api.nvim_create_user_command("GhPrQueryDelete", function()
  require("gh-pr").delete_query()
end, { desc = "Delete pull request query" })

local map = vim.keymap.set
map("n", "<leader>gho", "<cmd>GhPrOpen<cr>", { desc = "Open PR tree" })
map("n", "<leader>ghl", "<cmd>GhPrList<cr>", { desc = "List PRs (Telescope)" })
map("n", "<leader>ghm", "<cmd>GhPrComments<cr>", { desc = "Open PR comments tree" })
map("n", "<leader>ghr", "<cmd>GhPrRefresh<cr>", { desc = "Refresh PR data" })
map("n", "<leader>ghv", "<cmd>GhPrOverview<cr>", { desc = "Open PR overview" })
map("n", "<leader>ghc", "<cmd>GhPrCheckout<cr>", { desc = "Checkout PR" })
map("n", "<leader>ghd", "<cmd>GhPrOpenDiff<cr>", { desc = "Open PR file diff" })
map("n", "<leader>ghx", "<cmd>GhPrReviewTree<cr>", { desc = "Toggle PR Review source" })
map("n", "<leader>ght", "<cmd>GhPrToggleReviewed<cr>", { desc = "Toggle viewed" })
map("n", "<leader>ghn", "<cmd>GhPrNextChange<cr>", { desc = "Next diff change" })
map("n", "<leader>ghp", "<cmd>GhPrPrevChange<cr>", { desc = "Previous diff change" })
