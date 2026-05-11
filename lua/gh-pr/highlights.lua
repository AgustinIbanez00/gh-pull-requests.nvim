local M = {}

local baseline_links = {
  { "GhPrPrDraft", "DiagnosticWarn" },
  { "GhPrPrAuthor", "Comment" },
  { "GhPrPrConflict", "DiagnosticError" },
  { "GhPrPrReviewPending", "DiagnosticWarn" },
  { "GhPrPrReviewApproved", "DiagnosticOk" },
  { "GhPrPrReviewChanges", "DiagnosticError" },
  { "GhPrCheckRunning", "DiagnosticWarn" },
  { "GhPrCheckSuccess", "DiagnosticOk" },
  { "GhPrCheckFailed", "DiagnosticError" },
  { "GhPrReviewerPending", "DiagnosticWarn" },
  { "GhPrReviewerApproved", "DiagnosticOk" },
  { "GhPrReviewerChanges", "DiagnosticError" },
  { "GhPrViewedBadge", "DiagnosticWarn" },
  { "GhPrFileStatusAdded", "DiffAdd" },
  { "GhPrFileStatusModified", "DiffChange" },
  { "GhPrFileStatusDeleted", "DiffDelete" },
  { "GhPrFileStatusRenamed", "Identifier" },
  { "GhPrFileStatusCopied", "Identifier" },
  { "GhPrFileViewedIndicator", "GhPrViewedBadge" },
  { "GhPrFileCommentsBadge", "Comment" },
  { "GhPrFilePathContext", "Comment" },
  { "GhPrLabelDefault", "Identifier" },
  { "GhPrCommentThreadResolved", "DiffAdd" },
  { "GhPrCommentThreadUnresolved", "DiagnosticWarn" },
  { "GhPrCommentThreadClosed", "Comment" },
  { "GhPrCommentReviewApproved", "DiagnosticOk" },
  { "GhPrCommentReviewChanges", "DiagnosticError" },
  { "GhPrCommentReviewCommented", "DiagnosticInfo" },
  { "GhPrCommentLineOpen", "DiffText" },
  { "GhPrCommentLineResolved", "DiffAdd" },
  { "GhPrCommentLineOutdated", "DiffChange" },
  { "GhPrCommentVirtOpen", "DiagnosticHint" },
  { "GhPrCommentVirtResolved", "DiffAdd" },
  { "GhPrCommentVirtOutdated", "WarningMsg" },
  { "GhPrCommentVirtAuthors", "Comment" },
  { "GhPrCheckAnnotationFail", "DiagnosticError" },
  { "GhPrCheckAnnotationWarn", "DiagnosticWarn" },
  { "GhPrCheckAnnotationNotice", "DiagnosticInfo" },
  { "GhPrCheckAnnotationVirtFail", "DiagnosticError" },
  { "GhPrCheckAnnotationVirtWarn", "DiagnosticWarn" },
  { "GhPrCheckAnnotationVirtNotice", "DiagnosticInfo" },
  { "GhPrSecurityAlertCritical", "DiagnosticError" },
  { "GhPrSecurityAlertHigh", "DiagnosticError" },
  { "GhPrSecurityAlertMedium", "DiagnosticWarn" },
  { "GhPrSecurityAlertLow", "DiagnosticInfo" },
  { "GhPrSecurityAlertVirtCritical", "DiagnosticError" },
  { "GhPrSecurityAlertVirtHigh", "DiagnosticError" },
  { "GhPrSecurityAlertVirtMedium", "DiagnosticWarn" },
  { "GhPrSecurityAlertVirtLow", "DiagnosticInfo" },
  { "GhPrOverviewTitle", "Title" },
  { "GhPrOverviewHeading", "Special" },
  { "GhPrOverviewMuted", "Comment" },
  { "GhPrOverviewTab", "Comment" },
  { "GhPrOverviewTabActive", "TabLineSel" },
  { "GhPrOverviewBranch", "Special" },
  { "GhPrOverviewBadge", "PmenuSel" },
  { "GhPrOverviewReviewer", "Directory" },
  { "GhPrOverviewReviewerApproved", "DiagnosticOk" },
  { "GhPrOverviewReviewerPending", "DiagnosticWarn" },
  { "GhPrOverviewReviewerChanges", "DiagnosticError" },
  { "GhPrOverviewReviewerCommented", "Comment" },
  { "GhPrOverviewAssignee", "Function" },
  { "GhPrOverviewActionKey", "Keyword" },
  { "GhPrOverviewActionText", "Normal" },
  { "GhPrOverviewStateOpen", "DiagnosticOk" },
  { "GhPrOverviewStateClosed", "DiagnosticError" },
  { "GhPrOverviewStateMerged", "DiagnosticInfo" },
  { "GhPrOverviewReviewApproved", "DiagnosticOk" },
  { "GhPrOverviewReviewChanges", "DiagnosticError" },
  { "GhPrOverviewReviewPending", "DiagnosticWarn" },
  { "GhPrOverviewCheckPass", "DiagnosticOk" },
  { "GhPrOverviewCheckFail", "DiagnosticError" },
  { "GhPrOverviewCheckPending", "DiagnosticWarn" },
  { "GhPrOverviewCheckNeutral", "DiagnosticInfo" },
  { "GhPrOverviewTimelineComment", "GhPrOverviewMuted" },
  { "GhPrOverviewTimelineReview", "GhPrOverviewMuted" },
  { "GhPrOverviewTimelineThread", "Identifier" },
  { "GhPrOverviewThreadCommentMeta", "Directory" },
  { "GhPrOverviewThreadSeparator", "GhPrOverviewMarkdownRule" },
  { "GhPrOverviewThreadCommentSeparator", "Comment" },
  { "GhPrOverviewThreadDiffSeparator", "GhPrOverviewMarkdownRule" },
  { "GhPrOverviewTimelineCommit", "GhPrOverviewMuted" },
  { "GhPrOverviewTimelinePrChange", "GhPrOverviewMuted" },
  { "GhPrOverviewMarkdownHeading", "Title" },
  { "GhPrOverviewMarkdownCode", "String" },
  { "GhPrOverviewMarkdownCodeFence", "SpecialComment" },
  { "GhPrOverviewMarkdownInlineCode", "String" },
  { "GhPrOverviewMarkdownQuote", "Comment" },
  { "GhPrOverviewMarkdownQuoteMarker", "SpecialChar" },
  { "GhPrOverviewMarkdownListMarker", "SpecialChar" },
  { "GhPrOverviewMarkdownLink", "Underlined" },
  { "GhPrOverviewMarkdownRule", "Comment" },
  { "GhPrDiffCommentsMuted", "Comment" },
  { "GhPrDiffChangesHeader", "Title" },
  { "GhPrDiffChangesMuted", "Comment" },
  { "GhPrDiffChangesAdd", "DiffAdd" },
  { "GhPrDiffChangesDelete", "DiffDelete" },
  { "GhPrDiffChangesLine", "Normal" },
  { "GhPrDiffWhitespace", "Whitespace" },
  { "GhPrDiffEndline", "Comment" },
}

local setup_done = false
local baseline_applied = false

function M.apply_baseline_links()
  for _, spec in ipairs(baseline_links) do
    local group = spec[1]
    local target = spec[2]
    pcall(vim.api.nvim_set_hl, 0, group, { default = true, link = target })
  end
  baseline_applied = true
end

function M.ensure_baseline_links()
  if baseline_applied then
    return
  end
  M.apply_baseline_links()
end

function M.setup()
  M.ensure_baseline_links()
  if not setup_done then
    setup_done = true
    local group = vim.api.nvim_create_augroup("GhPrHighlights", { clear = true })
    vim.api.nvim_create_autocmd("ColorScheme", {
      group = group,
      desc = "gh-pr: reapply default highlight links",
      callback = function()
        baseline_applied = false
        M.apply_baseline_links()
      end,
    })
  end
end

return M
