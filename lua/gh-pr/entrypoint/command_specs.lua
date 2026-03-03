local M = {}

local function optional_arg(command)
  if type(command.args) == "string" and command.args ~= "" then
    return command.args
  end
  return nil
end

local function complete_overview_more(arg_lead, cmd_line)
  local parts = vim.split(cmd_line, "%s+", { trimempty = true })
  if #parts > 2 then
    return {}
  end

  local sections = { "checks", "commits", "comments", "reviews", "threads" }
  local matches = {}
  for _, section in ipairs(sections) do
    if arg_lead == "" or section:sub(1, #arg_lead) == arg_lead then
      matches[#matches + 1] = section
    end
  end
  return matches
end

function M.build(call, command_no_args)
  return {
    { name = "GhPrOpen", callback = command_no_args("open_pull_requests"), opts = { desc = "Open GitHub pull request view" } },
    { name = "GhPrList", callback = command_no_args("list_pull_requests"), opts = { desc = "List pull requests using Telescope" } },
    { name = "GhPrTelescope", callback = command_no_args("open_telescope"), opts = { desc = "Open Telescope fallback query/PR picker" } },
    {
      name = "GhPrTelescopeActions",
      callback = command_no_args("open_telescope_actions"),
      opts = { desc = "Open Telescope contextual PR/Review actions" },
    },
    {
      name = "GhPrTelescopeReview",
      callback = command_no_args("open_telescope_review_actions"),
      opts = { desc = "Open Telescope PR Review actions" },
    },
    {
      name = "GhPrComments",
      callback = function(command)
        call("open_comments", optional_arg(command))
      end,
      opts = { nargs = "?", desc = "Open PR Review source (Comments section)" },
    },
    {
      name = "GhPrStartReview",
      callback = function(command)
        call("start_review", optional_arg(command))
      end,
      opts = { nargs = "?", desc = "Start PR review flow and open PR Review source" },
    },
    {
      name = "GhPrReviewTree",
      callback = function()
        call("open_review_tree", { toggle = true })
      end,
      opts = { desc = "Toggle PR Review source" },
    },
    { name = "GhPrRefresh", callback = command_no_args("refresh"), opts = { desc = "Refresh pull request data" } },
    {
      name = "GhPRReviewRefresh",
      callback = command_no_args("refresh_review"),
      opts = { desc = "Force refresh PR Review data (background)" },
    },
    {
      name = "GhPrReviewRefresh",
      callback = command_no_args("refresh_review"),
      opts = { desc = "Force refresh PR Review data (background)" },
    },
    { name = "GhPrOverview", callback = command_no_args("open_overview"), opts = { desc = "Open active pull request overview" } },
    {
      name = "GhPrOverviewV2",
      callback = command_no_args("open_overview_v2"),
      opts = { desc = "Open active pull request overview (V2 panes POC)" },
    },
    {
      name = "GhPrOverviewRefresh",
      callback = command_no_args("refresh_overview"),
      opts = { desc = "Refresh active pull request overview buffer" },
    },
    {
      name = "GhPrOverviewV2Refresh",
      callback = command_no_args("refresh_overview_v2"),
      opts = { desc = "Refresh active pull request overview V2 panes" },
    },
    {
      name = "GhPrOverviewMore",
      callback = function(command)
        local section = command.fargs[1]
        local count = command.fargs[2] ~= nil and tonumber(command.fargs[2]) or nil
        call("overview_more", section, count)
      end,
      opts = {
        nargs = "+",
        complete = complete_overview_more,
        desc = "Load more items in current overview section",
      },
    },
    {
      name = "GhPrCheckout",
      callback = function(command)
        call("checkout", optional_arg(command))
      end,
      opts = { nargs = "?", desc = "Checkout pull request branch" },
    },
    { name = "GhPrOpenDiff", callback = command_no_args("open_diff"), opts = { desc = "Open active file diff" } },
    { name = "GhPrOpenOriginal", callback = command_no_args("open_original"), opts = { desc = "Open active file base version" } },
    { name = "GhPrOpenModified", callback = command_no_args("open_modified"), opts = { desc = "Open active file head version" } },
    {
      name = "GhPrOpenCommitPatch",
      callback = command_no_args("open_commit_patch"),
      opts = { desc = "Open selected commit patch in virtual buffer" },
    },
    {
      name = "GhPrToggleReviewed",
      callback = command_no_args("toggle_reviewed"),
      opts = { desc = "Toggle viewed state for active PR file" },
    },
    { name = "GhPrNextChange", callback = command_no_args("next_change"), opts = { desc = "Jump to next diff change" } },
    { name = "GhPrPrevChange", callback = command_no_args("prev_change"), opts = { desc = "Jump to previous diff change" } },
    {
      name = "GhPrApprove",
      callback = command_no_args("approve"),
      opts = { desc = "Approve active pull request (message + confirm)" },
    },
    {
      name = "GhPrRequestChanges",
      callback = command_no_args("request_changes"),
      opts = { desc = "Request changes on active pull request (message + confirm)" },
    },
    {
      name = "GhPrComment",
      callback = command_no_args("comment"),
      opts = { desc = "Submit general comment review (message + confirm)" },
    },
    {
      name = "GhPrReviewSubmit",
      callback = command_no_args("review_submit_pending"),
      opts = { desc = "Submit pending review as comment (message + confirm)" },
    },
    {
      name = "GhPrReviewApprove",
      callback = command_no_args("review_approve_pending"),
      opts = { desc = "Submit pending review as approve (message + confirm)" },
    },
    {
      name = "GhPrReviewRequestChanges",
      callback = command_no_args("review_request_changes_pending"),
      opts = { desc = "Submit pending review as request changes (message + confirm)" },
    },
    {
      name = "GhPrReviewDiscard",
      callback = command_no_args("review_discard_pending"),
      opts = { desc = "Discard current pending review (confirm)" },
    },
    {
      name = "GhPrMerge",
      callback = function(command)
        local method = optional_arg(command) or "merge"
        call("merge", method)
      end,
      opts = {
        nargs = "?",
        complete = function()
          return { "merge", "squash", "rebase" }
        end,
        desc = "Merge active pull request",
      },
    },
    { name = "GhPrQueryAdd", callback = command_no_args("add_query"), opts = { desc = "Add pull request query" } },
    { name = "GhPrQueryEdit", callback = command_no_args("edit_query"), opts = { desc = "Edit pull request query" } },
    { name = "GhPrQueryDelete", callback = command_no_args("delete_query"), opts = { desc = "Delete pull request query" } },
  }
end

return M
