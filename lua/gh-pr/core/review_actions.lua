local M = {}
local activity = require("gh-pr.core.activity")

local function pending_review_defaults()
  return {
    approve = "",
    request_changes = "Requested changes from Neovim",
    comment = "",
  }
end

function M.submit_pending_review(event, ctx)
  local pr, details, err = ctx.resolve_active_pr()
  if not pr then
    return ctx.notify_error(err)
  end

  local label = ctx.review_event_label(event)
  if not label then
    return ctx.notify_error("Unsupported review event")
  end

  local defaults = pending_review_defaults()
  ctx.prompt_review_body(defaults[event] or "", function(body, input_cancelled)
    if input_cancelled then
      ctx.notify_info("Pending review submission cancelled")
      return
    end

    ctx.confirm_review_submission(event, pr.number, body, function(confirmed)
      if not confirmed then
        ctx.notify_info("Pending review submission cancelled")
        return
      end

      local ev_label = event == "approve" and "approval"
        or event == "request_changes" and "review"
        or "comment"
      local handle = activity.begin("Submitting " .. ev_label .. "...")
      vim.cmd("redraw")
      local ok, review_err = ctx.pr_service.submit_pending_review(pr.number, event, body)
      activity.done(handle)
      if not ok then
        ctx.notify_error(review_err)
        return
      end

      ctx.notify_info(string.format("Pending %s review submitted for PR #%d", label, pr.number))
      ctx.refresh_line_comments_for_pr(pr.number, details)
      ctx.refresh_pr_sources({ force = true })
    end)
  end)
end

function M.submit_pending_comment_review(ctx)
  M.submit_pending_review("comment", ctx)
end

function M.submit_pending_approve_review(ctx)
  M.submit_pending_review("approve", ctx)
end

function M.submit_pending_request_changes_review(ctx)
  M.submit_pending_review("request_changes", ctx)
end

function M.discard_pending_review(ctx)
  local pr, _, err = ctx.resolve_active_pr()
  if not pr then
    return ctx.notify_error(err)
  end

  vim.ui.select({ "confirm", "cancel" }, {
    prompt = string.format("Discard pending review for PR #%d?", pr.number),
  }, function(choice)
    if choice ~= "confirm" then
      ctx.notify_info("Discard pending review cancelled")
      return
    end

    local handle = activity.begin("Discarding pending review...")
    vim.cmd("redraw")
    local ok, discard_err = ctx.pr_service.discard_pending_review(pr.number)
    activity.done(handle)
    if not ok then
      ctx.notify_error(discard_err)
      return
    end

    ctx.notify_info(string.format("Pending review discarded for PR #%d", pr.number))
    ctx.refresh_pr_sources({ force = true })
  end)
end

return M
