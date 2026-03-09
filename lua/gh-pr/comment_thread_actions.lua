local comment_composer = require("gh-pr.comment_composer")
local pr_service = require("gh-pr.pr_service")
local reaction_picker = require("gh-pr.ui.reaction_picker")
local reactions = require("gh-pr.reactions")

local M = {}

local function safe_string(value, fallback)
  if type(value) == "string" and value ~= "" then
    return value
  end
  return fallback or ""
end

local function positive_integer(value, fallback)
  local number = tonumber(value)
  if not number then
    return fallback
  end
  number = math.floor(number)
  if number < 1 then
    return fallback
  end
  return number
end

local function notify_info(message)
  vim.notify(message, vim.log.levels.INFO)
end

local function notify_error(message)
  if type(message) == "string" and message ~= "" then
    vim.notify(message, vim.log.levels.ERROR)
  end
end

local function summarize_body(body)
  local raw = type(body) == "string" and body or ""
  if raw == "" then
    return "(empty message)"
  end

  local first_line = vim.split(raw, "\n", { plain = true })[1] or ""
  first_line = vim.trim(first_line)
  if first_line == "" then
    return "(empty message)"
  end
  if #first_line > 70 then
    return first_line:sub(1, 67) .. "..."
  end
  return first_line
end

local function current_item_meta(item, ctx)
  local meta = type(item) == "table" and type(item.meta) == "table" and vim.deepcopy(item.meta) or {}
  ctx = type(ctx) == "table" and ctx or {}

  if meta.pr_number == nil then
    meta.pr_number = tonumber(ctx.pr_number)
  end
  if type(meta.thread_id) ~= "string" or meta.thread_id == "" then
    meta.thread_id = safe_string(ctx.thread_id, "")
  end
  if type(meta.path) ~= "string" or meta.path == "" then
    meta.path = safe_string(ctx.path, "")
  end
  if meta.line == nil then
    meta.line = positive_integer(ctx.line)
  end
  if meta.original_line == nil then
    meta.original_line = positive_integer(ctx.original_line)
  end
  if meta.thread_is_resolved == nil then
    meta.thread_is_resolved = ctx.thread_is_resolved == true
  end
  if meta.thread_is_outdated == nil then
    meta.thread_is_outdated = ctx.thread_is_outdated == true
  end
  if type(meta.comment_id) ~= "string" or meta.comment_id == "" then
    meta.comment_id = safe_string(type(item) == "table" and item.id or "", "")
  end
  if meta.comment_database_id == nil then
    meta.comment_database_id = tonumber(type(item) == "table" and item.database_id or nil)
      or tonumber(type(item) == "table" and item.comment_database_id or nil)
  end
  if type(meta.comment_author) ~= "string" or meta.comment_author == "" then
    meta.comment_author = safe_string(type(item) == "table" and item.author or "", "unknown")
  end
  if type(meta.comment_body) ~= "string" or meta.comment_body == "" then
    meta.comment_body = safe_string(type(item) == "table" and item.body or "", "")
  end
  if type(meta.comment_state) ~= "string" or meta.comment_state == "" then
    meta.comment_state = safe_string(type(item) == "table" and item.state or "", "")
  end
  if meta.comment_is_pending == nil then
    meta.comment_is_pending = safe_string(meta.comment_state, ""):upper() == "PENDING"
  end
  if meta.viewer_did_author == nil then
    meta.viewer_did_author = type(meta.comment_author) == "string"
      and type(ctx.author) == "string"
      and meta.comment_author == ctx.author
  end
  meta.comment_is_pending = meta.comment_is_pending == true
  meta.viewer_did_author = meta.viewer_did_author == true
  meta.reaction_groups = type(meta.reaction_groups) == "table" and vim.deepcopy(meta.reaction_groups) or {}

  return meta
end

local function shortcut_footer_lines(meta)
  local parts = {}

  if type(meta) ~= "table" then
    return {
      "q close",
    }
  end

  parts[#parts + 1] = "r reply"
  parts[#parts + 1] = "R quote"

  if safe_string(meta.thread_id, "") ~= "" then
    parts[#parts + 1] = string.format("x %s", meta.thread_is_resolved == true and "unresolve" or "resolve")
  end
  if meta.viewer_did_author == true then
    parts[#parts + 1] = "e edit"
    if meta.comment_is_pending ~= true then
      parts[#parts + 1] = "D delete"
    end
  end
  if meta.comment_is_pending ~= true then
    parts[#parts + 1] = "+/- reactions"
  end
  parts[#parts + 1] = "q close"

  return {
    table.concat(parts, "  "),
  }
end

local function location_label(meta)
  local path = safe_string(meta.path, "?")
  local line = positive_integer(meta.line)
  local original_line = positive_integer(meta.original_line)
  local target = line or original_line
  if target then
    return string.format("%s:%d", path, target)
  end
  return path
end

local function quote_initial_lines(meta)
  local body = safe_string(meta.comment_body, "")
  local lines = vim.split(body, "\n", { plain = true })
  if vim.tbl_isempty(lines) then
    lines = { "" }
  end

  local initial = {}
  for _, line in ipairs(lines) do
    initial[#initial + 1] = "> " .. line
  end
  initial[#initial + 1] = ""
  return initial
end

local function confirm(prompt, callback)
  vim.ui.select({ "confirm", "cancel" }, {
    prompt = prompt,
  }, function(choice)
    callback(choice == "confirm")
  end)
end

local function refresh_after_mutation(pr_number, details)
  local ok_actions, actions = pcall(require, "gh-pr.actions")
  if ok_actions and type(actions.refresh_after_thread_popup_mutation) == "function" then
    actions.refresh_after_thread_popup_mutation(pr_number, details, {
      force = true,
    })
  end
end

local function open_reply_composer(ctx, meta, initial_lines)
  local pr_number = tonumber(meta.pr_number or ctx.pr_number)
  if not pr_number then
    notify_error("Unable to resolve PR number for thread reply")
    return
  end

  local thread_id = safe_string(meta.thread_id, "")
  if thread_id == "" then
    notify_error("Unable to resolve review thread id for reply")
    return
  end

  local location = location_label(meta)
  local author = safe_string(meta.comment_author, "unknown")

  comment_composer.open({
    title = string.format("PR #%d reply on %s", pr_number, location),
    filetype = "markdown",
    border = "rounded",
    initial_lines = type(initial_lines) == "table" and initial_lines or { "" },
    enter = true,
    on_cancel = function()
      notify_info("Thread reply cancelled")
    end,
    on_submit = function(text)
      local message = vim.trim(type(text) == "string" and text or "")
      if message == "" then
        notify_info("Thread reply cancelled (empty message)")
        return
      end

      confirm(string.format(
        "Add reply to pending review on PR #%d at %s? Message: %s",
        pr_number,
        location,
        summarize_body(message)
      ), function(confirmed)
        if not confirmed then
          notify_info("Thread reply cancelled")
          return
        end

        local ok, reply_err = pr_service.reply_to_review_thread(pr_number, {
          thread_id = thread_id,
          body = message,
        })
        if not ok then
          notify_error(reply_err)
          return
        end

        notify_info(string.format("Reply to @%s added to pending review", author))
        if type(ctx.close_popup) == "function" then
          ctx.close_popup()
        end
        refresh_after_mutation(pr_number, ctx.details)
      end)
    end,
  })
end

local function toggle_thread_resolution(ctx, meta)
  local pr_number = tonumber(meta.pr_number or ctx.pr_number)
  if not pr_number then
    notify_error("Unable to resolve PR number for thread action")
    return
  end

  local thread_id = safe_string(meta.thread_id, "")
  if thread_id == "" then
    notify_error("Unable to resolve review thread id")
    return
  end

  local is_resolved = meta.thread_is_resolved == true
  local action_label = is_resolved and "Unresolve" or "Resolve"
  local location = location_label(meta)
  confirm(string.format("%s thread on PR #%d at %s?", action_label, pr_number, location), function(confirmed)
    if not confirmed then
      notify_info(string.format("%s thread cancelled", action_label))
      return
    end

    local ok, resolve_err
    if is_resolved then
      ok, resolve_err = pr_service.unresolve_review_thread(thread_id)
    else
      ok, resolve_err = pr_service.resolve_review_thread(thread_id)
    end

    if not ok then
      notify_error(resolve_err)
      return
    end

    notify_info(string.format("Thread %sd", is_resolved and "unresolve" or "resolve"))
    if type(ctx.close_popup) == "function" then
      ctx.close_popup()
    end
    refresh_after_mutation(pr_number, ctx.details)
  end)
end

local function open_edit_composer(ctx, meta)
  local comment_id = safe_string(meta.comment_id, "")
  if comment_id == "" then
    notify_error("Unable to resolve review comment id for edit")
    return
  end
  if meta.viewer_did_author ~= true then
    notify_info("Only your own review comments can be edited")
    return
  end

  comment_composer.open({
    title = string.format("Edit review comment on %s", location_label(meta)),
    filetype = "markdown",
    border = "rounded",
    initial_lines = vim.split(safe_string(meta.comment_body, ""), "\n", { plain = true }),
    enter = true,
    on_cancel = function()
      notify_info("Edit comment cancelled")
    end,
    on_submit = function(text)
      local message = vim.trim(type(text) == "string" and text or "")
      if message == "" then
        notify_info("Edit comment cancelled (empty message)")
        return
      end

      confirm(string.format("Update review comment on %s? Message: %s", location_label(meta), summarize_body(message)), function(confirmed)
        if not confirmed then
          notify_info("Edit comment cancelled")
          return
        end

        local ok, update_err = pr_service.update_review_comment(comment_id, message)
        if not ok then
          notify_error(update_err)
          return
        end

        notify_info("Review comment updated")
        if type(ctx.close_popup) == "function" then
          ctx.close_popup()
        end
        refresh_after_mutation(tonumber(meta.pr_number or ctx.pr_number), ctx.details)
      end)
    end,
  })
end

local function delete_comment(ctx, meta)
  local comment_id = safe_string(meta.comment_id, "")
  if comment_id == "" then
    notify_error("Unable to resolve review comment id")
    return
  end
  if meta.comment_is_pending == true then
    notify_info("Draft review comments cannot be deleted yet")
    return
  end
  if meta.viewer_did_author ~= true then
    notify_info("Only your own review comments can be deleted")
    return
  end

  confirm(string.format("Delete review comment on %s?", location_label(meta)), function(confirmed)
    if not confirmed then
      notify_info("Delete comment cancelled")
      return
    end

    local ok, delete_err = pr_service.delete_review_comment({
      comment_id = comment_id,
      comment_database_id = meta.comment_database_id,
    })
    if not ok then
      notify_error(delete_err)
      return
    end

    notify_info("Review comment deleted")
    if type(ctx.close_popup) == "function" then
      ctx.close_popup()
    end
    refresh_after_mutation(tonumber(meta.pr_number or ctx.pr_number), ctx.details)
  end)
end

local function pick_reaction(ctx, meta, enabled)
  local comment_id = safe_string(meta.comment_id, "")
  if comment_id == "" then
    notify_error("Unable to resolve review comment id for reactions")
    return
  end
  if meta.comment_is_pending == true then
    notify_info("Draft review comments do not support reactions yet")
    return
  end

  local open_ok, picker_or_err = reaction_picker.open({
    origin_bufnr = type(ctx.popup_bufnr) == "number" and ctx.popup_bufnr or ctx.origin_bufnr,
    anchor_win = type(ctx.popup_winid) == "number" and ctx.popup_winid or nil,
    mode = enabled == false and "remove" or "add",
    reaction_groups = meta.reaction_groups,
    on_select = function(choice)
      local content = type(choice) == "table" and safe_string(choice.content, "") or ""
      if content == "" then
        return
      end

      if enabled == false then
        local existing = reactions.reaction_group_by_content(meta.reaction_groups, content)
        if type(existing) ~= "table" or existing.viewer_has_reacted ~= true then
          notify_info("You do not have that reaction on this comment")
          return
        end
      end

      local ok, reaction_err = pr_service.set_review_comment_reaction(comment_id, content, enabled ~= false)
      if not ok then
        notify_error(reaction_err)
        return
      end

      notify_info(enabled == false and "Reaction removed" or "Reaction added")
      if type(ctx.close_popup) == "function" then
        ctx.close_popup()
      end
      refresh_after_mutation(tonumber(meta.pr_number or ctx.pr_number), ctx.details)
    end,
  })

  if open_ok ~= true then
    local message = type(picker_or_err) == "string" and picker_or_err or "Unable to open reaction picker"
    if enabled == false and message == "You do not have any reactions on this comment" then
      notify_info(message)
    else
      notify_error(message)
    end
  end
end

function M.build_popup_actions(ctx)
  ctx = type(ctx) == "table" and ctx or {}

  return {
    reply = function(item, popup_ctx)
      local meta = current_item_meta(item, ctx)
      local merged = vim.tbl_extend("force", {}, ctx, popup_ctx or {})
      open_reply_composer(merged, meta, { "" })
    end,
    quote = function(item, popup_ctx)
      local meta = current_item_meta(item, ctx)
      local merged = vim.tbl_extend("force", {}, ctx, popup_ctx or {})
      open_reply_composer(merged, meta, quote_initial_lines(meta))
    end,
    toggle_thread = function(item, popup_ctx)
      local meta = current_item_meta(item, ctx)
      local merged = vim.tbl_extend("force", {}, ctx, popup_ctx or {})
      toggle_thread_resolution(merged, meta)
    end,
    edit = function(item, popup_ctx)
      local meta = current_item_meta(item, ctx)
      local merged = vim.tbl_extend("force", {}, ctx, popup_ctx or {})
      open_edit_composer(merged, meta)
    end,
    delete = function(item, popup_ctx)
      local meta = current_item_meta(item, ctx)
      local merged = vim.tbl_extend("force", {}, ctx, popup_ctx or {})
      delete_comment(merged, meta)
    end,
    add_reaction = function(item, popup_ctx)
      local meta = current_item_meta(item, ctx)
      local merged = vim.tbl_extend("force", {}, ctx, popup_ctx or {})
      pick_reaction(merged, meta, true)
    end,
    remove_reaction = function(item, popup_ctx)
      local meta = current_item_meta(item, ctx)
      local merged = vim.tbl_extend("force", {}, ctx, popup_ctx or {})
      pick_reaction(merged, meta, false)
    end,
  }
end

function M.build_popup_footer_provider(ctx)
  ctx = type(ctx) == "table" and ctx or {}

  return function(item, popup_ctx)
    if type(item) ~= "table" then
      return shortcut_footer_lines(nil)
    end
    local merged = vim.tbl_extend("force", {}, ctx, popup_ctx or {})
    local meta = current_item_meta(item, merged)
    return shortcut_footer_lines(meta)
  end
end

return M
