local M = {}

local multi_select = require("gh-pr.multi_select")

local selector_cache = {
  labels = {},
  reviewers = {},
}

local function cache_now()
  return os.time()
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

local function current_labels(details)
  return normalize_items(details.labels)
end

local function current_reviewers(details)
  return normalize_items(details.reviewRequests)
end

local function cache_key_for_repo(details, ctx)
  local repository = ctx.normalize_repository(details)
  return type(repository) == "string" and repository ~= "" and repository or "__unknown__"
end

local function cache_get(bucket, key, ttl_seconds)
  local entry = selector_cache[bucket] and selector_cache[bucket][key] or nil
  if type(entry) ~= "table" then
    return nil
  end
  local age = cache_now() - (tonumber(entry.timestamp) or 0)
  if age > ttl_seconds then
    selector_cache[bucket][key] = nil
    return nil
  end
  return vim.deepcopy(entry.value)
end

local function cache_put(bucket, key, value)
  selector_cache[bucket] = selector_cache[bucket] or {}
  selector_cache[bucket][key] = {
    timestamp = cache_now(),
    value = vim.deepcopy(value),
  }
end

local function load_label_candidates(details, ctx)
  local key = cache_key_for_repo(details, ctx)
  local cached = cache_get("labels", key, 120)
  if cached then
    return cached, nil
  end

  local labels, labels_err = ctx.pr_service.fetch_repo_labels({
    repository = key ~= "__unknown__" and key or nil,
    per_page = 100,
    max_pages = 20,
  })
  if not labels then
    return nil, labels_err
  end

  cache_put("labels", key, labels)
  return labels, nil
end

local function load_reviewer_candidates(details, ctx)
  local key = cache_key_for_repo(details, ctx)
  local cached = cache_get("reviewers", key, 120)
  if cached then
    return cached, nil
  end

  local candidates, candidates_err = ctx.pr_service.fetch_reviewer_candidates({
    repository = key ~= "__unknown__" and key or nil,
    per_page = 100,
    max_pages = 20,
  })
  if not candidates then
    return nil, candidates_err
  end

  cache_put("reviewers", key, candidates)
  return candidates, nil
end

local function open_label_multi_select(pr, details, ctx, callback)
  local labels, labels_err = load_label_candidates(details, ctx)
  if not labels then
    ctx.notify_error("Unable to load repository labels: " .. tostring(labels_err))
    callback(false)
    return
  end

  local current = current_labels(details)
  local selected = {}
  for _, value in ipairs(current) do
    selected[normalize_key(value)] = true
  end

  local items = {}
  local seen = {}
  for _, label in ipairs(labels) do
    local name = normalize_string(label.name)
    local key = normalize_key(name)
    if name ~= "" and key ~= "" and not seen[key] then
      seen[key] = true
      items[#items + 1] = {
        id = name,
        value = name,
        label = name,
        description = normalize_string(label.description),
        color = normalize_string(label.color),
        kind = "label",
        selected = selected[key] == true,
      }
    end
  end

  for _, current_name in ipairs(current) do
    local key = normalize_key(current_name)
    if key ~= "" and not seen[key] then
      seen[key] = true
      items[#items + 1] = {
        id = current_name,
        value = current_name,
        label = current_name,
        description = "",
        color = "",
        kind = "label",
        selected = true,
      }
    end
  end

  table.sort(items, function(left, right)
    return normalize_key(left.label) < normalize_key(right.label)
  end)

  multi_select.open({
    title = string.format("PR #%d - Edit labels", pr.number),
    items = items,
    on_confirm = function(values)
      callback(values)
    end,
    on_cancel = function()
      callback(nil)
    end,
  })
end

local function open_reviewer_multi_select(pr, details, ctx, callback)
  local candidates, candidates_err = load_reviewer_candidates(details, ctx)
  if not candidates then
    ctx.notify_error("Unable to load reviewer candidates: " .. tostring(candidates_err))
    callback(false)
    return
  end

  for _, warning in ipairs(type(candidates.warnings) == "table" and candidates.warnings or {}) do
    ctx.notify_warn(warning)
  end

  local current = current_reviewers(details)
  local selected = {}
  for _, value in ipairs(current) do
    selected[normalize_key(value)] = true
  end

  local items = {}
  local seen = {}
  for _, candidate in ipairs(type(candidates.merged) == "table" and candidates.merged or {}) do
    local value = normalize_string(candidate.value)
    local key = normalize_key(value)
    if value ~= "" and key ~= "" and not seen[key] then
      seen[key] = true
      items[#items + 1] = {
        id = value,
        value = value,
        label = normalize_string(candidate.display) ~= "" and normalize_string(candidate.display) or value,
        description = "",
        kind = normalize_string(candidate.kind) == "team" and "team" or "user",
        selected = selected[key] == true,
      }
    end
  end

  for _, current_value in ipairs(current) do
    local key = normalize_key(current_value)
    if key ~= "" and not seen[key] then
      seen[key] = true
      local is_team = current_value:find("/", 1, true) ~= nil
      items[#items + 1] = {
        id = current_value,
        value = current_value,
        label = "@" .. current_value,
        description = "",
        kind = is_team and "team" or "user",
        selected = true,
      }
    end
  end

  table.sort(items, function(left, right)
    if left.kind ~= right.kind then
      local left_order = left.kind == "user" and 1 or 2
      local right_order = right.kind == "user" and 1 or 2
      return left_order < right_order
    end
    return normalize_key(left.value) < normalize_key(right.value)
  end)

  multi_select.open({
    title = string.format("PR #%d - Edit reviewers", pr.number),
    items = items,
    on_confirm = function(values)
      callback(values)
    end,
    on_cancel = function()
      callback(nil)
    end,
  })
end

function M.pick(kind, payload, pr, details, action_label, ctx, callback)
  payload = type(payload) == "table" and payload or {}

  if kind == "edit_labels" then
    return open_label_multi_select(pr, details, ctx, callback)
  end

  if kind == "edit_reviewers" then
    return open_reviewer_multi_select(pr, details, ctx, callback)
  end

  if kind == "change_state" then
    vim.ui.select({ "open", "closed" }, {
      prompt = "Target state:",
    }, function(choice)
      callback(choice)
    end)
    return
  end

  if kind == "change_draft" then
    vim.ui.select({ "ready", "draft" }, {
      prompt = "Target draft status:",
    }, function(choice)
      callback(choice)
    end)
    return
  end

  local default_value = payload.current
  if type(default_value) ~= "string" then
    default_value = ""
  end

  local prompt = string.format("%s: ", action_label or "Edit")
  vim.ui.input({
    prompt = prompt,
    default = default_value,
  }, function(input)
    callback(input)
  end)
end

function M.confirm(pr_number, action_label, summary, callback)
  local prompt = string.format(
    "Apply %s on PR #%d? %s",
    action_label,
    pr_number,
    summary
  )

  vim.ui.select({ "confirm", "cancel" }, {
    prompt = prompt,
  }, function(choice)
    callback(choice == "confirm")
  end)
end

return M
