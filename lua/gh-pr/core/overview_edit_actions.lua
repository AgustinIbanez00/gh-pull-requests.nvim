local M = {}

local overview_edit_labels = {
  edit_title = "Edit title",
  edit_body = "Edit description",
  edit_labels = "Edit labels",
  edit_reviewers = "Edit reviewers",
  edit_assignees = "Edit assignees",
  edit_milestone = "Edit milestone",
  change_state = "Change state",
  change_draft = "Change draft status",
}

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

local function normalize_string(value)
  if type(value) ~= "string" then
    return ""
  end
  return vim.trim(value)
end

local function normalize_key(value)
  return normalize_string(value):lower()
end

local function parse_csv_items(value)
  if type(value) ~= "string" then
    return {}
  end

  local items = {}
  local seen = {}
  for _, raw in ipairs(vim.split(value, ",", { plain = true })) do
    local item = normalize_string(raw)
    if item ~= "" then
      local key = normalize_key(item)
      if key ~= "" and not seen[key] then
        seen[key] = true
        items[#items + 1] = item
      end
    end
  end

  return items
end

local function summarize_list(items, empty_label)
  items = type(items) == "table" and items or {}
  if vim.tbl_isempty(items) then
    return empty_label or "(none)"
  end

  if #items <= 5 then
    return table.concat(items, ", ")
  end

  local preview = {}
  for index = 1, 4 do
    preview[#preview + 1] = items[index]
  end
  preview[#preview + 1] = string.format("+%d more", #items - 4)
  return table.concat(preview, ", ")
end

local function summarize_text(value, max_length)
  local text = normalize_string(value)
  if text == "" then
    return "(empty)"
  end

  text = text:gsub("\n", " ")
  local limit = positive_integer(max_length, 80)
  if #text > limit then
    return text:sub(1, limit - 3) .. "..."
  end
  return text
end

local function extract_name(item)
  if type(item) == "string" then
    return normalize_string(item)
  end

  if type(item) ~= "table" then
    return ""
  end

  if type(item.login) == "string" and item.login ~= "" then
    return normalize_string(item.login)
  end

  if type(item.slug) == "string" and item.slug ~= "" then
    if type(item.organization) == "table" and type(item.organization.login) == "string" and item.organization.login ~= "" then
      return normalize_string(item.organization.login .. "/" .. item.slug)
    end
    return normalize_string(item.slug)
  end

  if type(item.name) == "string" and item.name ~= "" then
    return normalize_string(item.name)
  end

  if type(item.requestedReviewer) == "table" then
    return extract_name(item.requestedReviewer)
  end

  if type(item.user) == "table" then
    return extract_name(item.user)
  end

  if type(item.team) == "table" then
    return extract_name(item.team)
  end

  return ""
end

local function normalize_items(items)
  local result = {}
  local seen = {}

  for _, item in ipairs(type(items) == "table" and items or {}) do
    local name = extract_name(item)
    if name ~= "" then
      local key = normalize_key(name)
      if key ~= "" and not seen[key] then
        seen[key] = true
        result[#result + 1] = name
      end
    end
  end

  return result
end

local function compute_replacement_diff(current_items, desired_items)
  local current = {}
  local desired = {}
  local add = {}
  local remove = {}

  for _, item in ipairs(current_items) do
    local key = normalize_key(item)
    if key ~= "" then
      current[key] = item
    end
  end

  for _, item in ipairs(desired_items) do
    local key = normalize_key(item)
    if key ~= "" and not desired[key] then
      desired[key] = item
      if not current[key] then
        add[#add + 1] = item
      end
    end
  end

  for _, item in ipairs(current_items) do
    local key = normalize_key(item)
    if key ~= "" and not desired[key] then
      remove[#remove + 1] = item
    end
  end

  return add, remove
end

local function current_milestone(details)
  if type(details.milestone) == "table" and type(details.milestone.title) == "string" then
    return normalize_string(details.milestone.title)
  end
  return ""
end

local function current_labels(details)
  return normalize_items(details.labels)
end

local function current_reviewers(details)
  return normalize_items(details.reviewRequests)
end

local function current_assignees(details)
  return normalize_items(details.assignees)
end

local function normalize_values_list(values)
  local result = {}
  local seen = {}
  for _, value in ipairs(type(values) == "table" and values or {}) do
    local text = normalize_string(value)
    local key = normalize_key(text)
    if text ~= "" and key ~= "" and not seen[key] then
      seen[key] = true
      result[#result + 1] = text
    end
  end
  return result
end

local function normalize_reviewer_identity(value)
  local text = normalize_string(value)
  if text == "" then
    return ""
  end

  text = text:gsub("^%s+", ""):gsub("%s+$", "")
  text = text:gsub("^@", "")
  text = text:gsub("%s+%([Tt][Ee][Aa][Mm]%)$", "")
  text = text:gsub("^%s+", ""):gsub("%s+$", "")
  return text
end

local function normalize_reviewer_values(values)
  local result = {}
  local seen = {}
  for _, value in ipairs(type(values) == "table" and values or {}) do
    local normalized = normalize_reviewer_identity(value)
    local key = normalize_key(normalized)
    if normalized ~= "" and key ~= "" and not seen[key] then
      seen[key] = true
      result[#result + 1] = normalized
    end
  end
  return result
end

local function build_title_edit(choice, details, ctx)
  local next_title = normalize_string(choice)
  local current_title = normalize_string(details.title)
  if next_title == "" then
    return nil, "Title cannot be empty", false
  end
  if next_title == current_title then
    return nil, "No changes detected for title", true
  end

  return {
    summary = string.format("title: %s", summarize_text(next_title, 80)),
    success = "Title updated",
    run = function(pr_number)
      return ctx.pr_service.edit(pr_number, { title = next_title })
    end,
  }, nil, false
end

local function build_body_edit(choice, details, ctx)
  local next_body = type(choice) == "string" and choice or ""
  local current_body = type(details.body) == "string" and details.body or ""
  if next_body == current_body then
    return nil, "No changes detected for description", true
  end

  local summary
  if normalize_string(next_body) == "" then
    summary = "description: clear"
  else
    summary = string.format("description: %s", summarize_text(next_body, 80))
  end

  return {
    summary = summary,
    success = "Description updated",
    run = function(pr_number)
      return ctx.pr_service.edit(pr_number, { body = next_body })
    end,
  }, nil, false
end

local function build_milestone_edit(choice, details, ctx)
  local next_milestone = normalize_string(choice)
  local current_value = current_milestone(details)
  if next_milestone == current_value then
    return nil, "No changes detected for milestone", true
  end

  if next_milestone == "" then
    if current_value == "" then
      return nil, "No changes detected for milestone", true
    end

    return {
      summary = "milestone: remove",
      success = "Milestone removed",
      run = function(pr_number)
        return ctx.pr_service.edit(pr_number, { remove_milestone = true })
      end,
    }, nil, false
  end

  return {
    summary = string.format("milestone: %s", summarize_text(next_milestone, 60)),
    success = "Milestone updated",
    run = function(pr_number)
      return ctx.pr_service.edit(pr_number, { milestone = next_milestone })
    end,
  }, nil, false
end

local function build_list_edit_from_values(kind, desired_values, current_values, ctx)
  local desired = normalize_values_list(desired_values)
  local current = normalize_values_list(current_values)
  if kind == "edit_reviewers" then
    desired = normalize_reviewer_values(desired)
    current = normalize_reviewer_values(current)
  end

  local add, remove = compute_replacement_diff(current, desired)

  if vim.tbl_isempty(add) and vim.tbl_isempty(remove) then
    return nil, "No changes detected", true
  end

  local summary = string.format(
    "final: [%s] | add: [%s] | remove: [%s]",
    summarize_list(desired),
    summarize_list(add),
    summarize_list(remove)
  )

  local operations = {}
  local success

  if kind == "edit_labels" then
    operations.add_labels = add
    operations.remove_labels = remove
    success = "Labels updated"
  elseif kind == "edit_reviewers" then
    operations.add_reviewers = add
    operations.remove_reviewers = remove
    success = "Reviewers updated"
  elseif kind == "edit_assignees" then
    operations.add_assignees = add
    operations.remove_assignees = remove
    success = "Assignees updated"
  else
    return nil, "Unsupported list edit action", false
  end

  return {
    summary = summary,
    success = success,
    run = function(pr_number)
      return ctx.pr_service.edit(pr_number, operations)
    end,
  }, nil, false
end

local function build_list_edit(kind, choice, current_values, ctx)
  local desired = parse_csv_items(type(choice) == "string" and choice or "")
  return build_list_edit_from_values(kind, desired, current_values, ctx)
end

local function build_state_change(choice, details, ctx)
  local target = normalize_key(choice)
  if target ~= "open" and target ~= "closed" then
    return nil, "Invalid state selection", false
  end

  local current = normalize_key(details.state)
  if current == target then
    return nil, "No changes detected for PR state", true
  end

  local before_state = (current ~= "" and current or "unknown"):upper()
  local after_state = target:upper()
  return {
    summary = string.format("state: %s -> %s", before_state, after_state),
    success = string.format("PR state changed to %s", after_state),
    run = function(pr_number)
      return ctx.pr_service.change_state(pr_number, target)
    end,
  }, nil, false
end

local function build_draft_change(choice, details, ctx)
  local target = normalize_key(choice)
  if target ~= "ready" and target ~= "draft" then
    return nil, "Invalid draft status selection", false
  end

  local current = details.isDraft == true and "draft" or "ready"
  if current == target then
    return nil, "No changes detected for draft status", true
  end

  return {
    summary = string.format("draft status: %s -> %s", current:upper(), target:upper()),
    success = string.format("Draft status changed to %s", target:upper()),
    run = function(pr_number)
      return ctx.pr_service.change_draft(pr_number, target)
    end,
  }, nil, false
end

local function build_overview_edit_operation(kind, choice, details, ctx)
  if kind == "edit_title" then
    return build_title_edit(choice, details, ctx)
  end
  if kind == "edit_body" then
    return build_body_edit(choice, details, ctx)
  end
  if kind == "edit_milestone" then
    return build_milestone_edit(choice, details, ctx)
  end
  if kind == "edit_labels" then
    if type(choice) == "table" then
      return build_list_edit_from_values(kind, choice, current_labels(details), ctx)
    end
    return build_list_edit(kind, choice, current_labels(details), ctx)
  end
  if kind == "edit_reviewers" then
    if type(choice) == "table" then
      return build_list_edit_from_values(kind, choice, current_reviewers(details), ctx)
    end
    return build_list_edit(kind, choice, current_reviewers(details), ctx)
  end
  if kind == "edit_assignees" then
    return build_list_edit(kind, choice, current_assignees(details), ctx)
  end
  if kind == "change_state" then
    return build_state_change(choice, details, ctx)
  end
  if kind == "change_draft" then
    return build_draft_change(choice, details, ctx)
  end

  return nil, "Unsupported overview edit action", false
end

local function capture_overview_context(ctx)
  local bufnr = vim.api.nvim_get_current_buf()
  if not ctx.is_valid_buf(bufnr) then
    return nil
  end

  local number = vim.b[bufnr].gh_pr_number
  if type(number) ~= "number" then
    return nil
  end

  local context = {
    bufnr = bufnr,
    pr_number = number,
    overview_ui = vim.b[bufnr].gh_pr_overview_ui,
    overview_session = tonumber(vim.b[bufnr].gh_pr_overview_session),
  }

  local winid = vim.fn.bufwinid(bufnr)
  if ctx.is_valid_win(winid) then
    context.winid = winid
    local ok, cursor = pcall(vim.api.nvim_win_get_cursor, winid)
    if ok and type(cursor) == "table" and type(cursor[1]) == "number" then
      context.cursor_line = math.max(1, math.floor(cursor[1]))
    end
  end

  local limits = vim.b[bufnr].gh_pr_overview_limits
  if type(limits) == "table" then
    context.overview_limits = vim.deepcopy(limits)
  end

  return context
end

local function refresh_overview_after_edit(pr_number, context, ctx)
  local options = {
    refresh = true,
    session_id = type(context) == "table" and context.overview_session or nil,
  }

  if type(pr_number) ~= "number" then
    return
  end

  if type(context) == "table" and type(context.overview_limits) == "table" then
    options.overview_limits = context.overview_limits
  end

  local ok, err = pcall(ctx.open_overview, pr_number, options)
  if not ok then
    ctx.notify_warn("Overview updated remotely, but local refresh failed: " .. tostring(err))
  end
end

function M.label_for(kind)
  return overview_edit_labels[kind]
end

function M.run(kind, payload, ctx)
  local label = M.label_for(kind)
  if not label then
    return ctx.notify_warn("Unsupported overview edit action")
  end

  local overview_context = capture_overview_context(ctx)
  local target_number = overview_context and overview_context.pr_number or nil
  local pr, details, err = ctx.resolve_active_pr(target_number)
  if not pr then
    return ctx.notify_error(err)
  end

  ctx.ui.pick(kind, payload, pr, details, label, function(choice)
    if choice == false then
      return
    end

    if choice == nil then
      ctx.notify_info(label .. " cancelled")
      return
    end

    local operation, build_err, noop = build_overview_edit_operation(kind, choice, details, ctx)
    if noop then
      ctx.notify_info(build_err or "No changes detected")
      return
    end
    if not operation then
      ctx.notify_error(build_err)
      return
    end

    ctx.ui.confirm(pr.number, label, operation.summary or "", function(confirmed)
      if not confirmed then
        ctx.notify_info(label .. " cancelled")
        return
      end

      local ok, op_err = operation.run(pr.number)
      if not ok then
        ctx.notify_error(op_err)
        return
      end

      ctx.notify_info(operation.success or (label .. " completed"))
      refresh_overview_after_edit(pr.number, overview_context, ctx)
      ctx.refresh_pr_sources_after_state_change({ force = true })
    end)
  end)
end

return M
