local M = {}

local COMPLETE_REVIEW_STATES = {
  APPROVED = true,
  CHANGES_REQUESTED = true,
  COMMENTED = true,
}

local function normalize_string(value)
  if type(value) ~= "string" then
    return ""
  end
  return vim.trim(value)
end

local function normalize_key(value)
  return normalize_string(value):lower()
end

local function normalize_review_state(state)
  local value = normalize_string(state):upper()
  if value == "APPROVED" or value == "PENDING" or value == "CHANGES_REQUESTED" or value == "COMMENTED" then
    return value
  end
  return nil
end

local function organization_login(entity)
  if type(entity) ~= "table" then
    return ""
  end

  if type(entity.organization) == "table" and type(entity.organization.login) == "string" then
    return normalize_string(entity.organization.login)
  end
  if type(entity.org) == "table" and type(entity.org.login) == "string" then
    return normalize_string(entity.org.login)
  end
  if type(entity.owner) == "table" and type(entity.owner.login) == "string" then
    return normalize_string(entity.owner.login)
  end

  return ""
end

local function extract_user_identity(entity)
  if type(entity) == "string" then
    local login = normalize_string(entity)
    if login ~= "" then
      return {
        kind = "user",
        identity = login,
        request_value = login,
        display_name = "@" .. login,
      }
    end
    return nil
  end

  if type(entity) ~= "table" then
    return nil
  end

  if type(entity.requestedReviewer) == "table" then
    local resolved = extract_user_identity(entity.requestedReviewer)
    if resolved then
      return resolved
    end
  end
  if type(entity.user) == "table" then
    local resolved = extract_user_identity(entity.user)
    if resolved then
      return resolved
    end
  end
  if type(entity.author) == "table" then
    local resolved = extract_user_identity(entity.author)
    if resolved then
      return resolved
    end
  end

  local login = normalize_string(entity.login)
  if login == "" then
    return nil
  end

  return {
    kind = "user",
    identity = login,
    request_value = login,
    display_name = "@" .. login,
  }
end

local function extract_team_identity(entity)
  if type(entity) ~= "table" then
    return nil
  end

  if type(entity.requestedReviewer) == "table" then
    local resolved = extract_team_identity(entity.requestedReviewer)
    if resolved then
      return resolved
    end
  end
  if type(entity.team) == "table" then
    local resolved = extract_team_identity(entity.team)
    if resolved then
      return resolved
    end
  end

  local slug = normalize_string(entity.slug)
  local org = organization_login(entity)
  local request_value = nil
  local display_name = ""

  if slug ~= "" and org ~= "" then
    request_value = org .. "/" .. slug
    display_name = request_value
  elseif slug ~= "" then
    display_name = slug
  end

  if display_name == "" then
    display_name = normalize_string(entity.name)
  end

  if display_name == "" then
    return nil
  end

  return {
    kind = "team",
    identity = request_value or display_name,
    request_value = request_value,
    display_name = display_name,
  }
end

local function extract_identity(entity)
  local user = extract_user_identity(entity)
  if user then
    return user
  end
  return extract_team_identity(entity)
end

local function reviewer_id(identity)
  if type(identity) ~= "table" then
    return ""
  end

  local kind = normalize_string(identity.kind)
  local key = normalize_key(identity.identity)
  if kind == "" or key == "" then
    return ""
  end

  return string.format("%s:%s", kind, key)
end

local function normalize_review_entry(review, sequence)
  review = type(review) == "table" and review or {}

  local identity = extract_identity(review.author or review.user or review.requestedReviewer or review)
  local state = normalize_review_state(review.state)
  local id = reviewer_id(identity)
  if not identity or not state or id == "" then
    return nil
  end

  local commit = type(review.commit) == "table" and normalize_string(review.commit.oid) or ""
  if commit == "" then
    commit = normalize_string(review.commit_oid)
  end

  return {
    id = id,
    kind = identity.kind,
    request_value = identity.request_value,
    display_name = identity.display_name,
    state = state,
    submitted_at = normalize_string(review.submittedAt or review.submitted_at),
    commit_oid = commit,
    sequence = tonumber(sequence) or 0,
  }
end

local function review_is_newer(candidate, current)
  if not current then
    return true
  end

  local candidate_time = normalize_string(candidate and candidate.submitted_at)
  local current_time = normalize_string(current and current.submitted_at)
  if candidate_time ~= "" and current_time ~= "" and candidate_time ~= current_time then
    return candidate_time > current_time
  end
  if candidate_time ~= "" and current_time == "" then
    return true
  end
  if candidate_time == "" and current_time ~= "" then
    return false
  end

  return (tonumber(candidate and candidate.sequence) or 0) >= (tonumber(current and current.sequence) or 0)
end

local function upsert_review(target, review)
  if not review or review.id == "" then
    return
  end

  local current = target[review.id]
  if review_is_newer(review, current) then
    target[review.id] = review
  end
end

local function upsert_request(target, entry)
  local identity = extract_identity(type(entry) == "table" and (entry.requestedReviewer or entry.team or entry.user or entry) or entry)
  local id = reviewer_id(identity)
  if not identity or id == "" then
    return
  end

  target[id] = {
    id = id,
    kind = identity.kind,
    request_value = identity.request_value,
    display_name = identity.display_name,
  }
end

function M.build(details)
  details = type(details) == "table" and details or {}

  local head_ref_oid = normalize_string(details.headRefOid)
  local pending_map = {}
  local latest_reviews = {}
  local fallback_reviews = {}

  for _, request in ipairs(type(details.reviewRequests) == "table" and details.reviewRequests or {}) do
    upsert_request(pending_map, request)
  end

  local sequence = 0
  for _, review in ipairs(type(details.latestReviews) == "table" and details.latestReviews or {}) do
    sequence = sequence + 1
    upsert_review(latest_reviews, normalize_review_entry(review, sequence))
  end
  for _, review in ipairs(type(details.reviews) == "table" and details.reviews or {}) do
    sequence = sequence + 1
    upsert_review(fallback_reviews, normalize_review_entry(review, sequence))
  end

  local reviewer_ids = {}
  local seen = {}
  local function add_reviewer_id(id)
    if type(id) ~= "string" or id == "" or seen[id] then
      return
    end
    seen[id] = true
    reviewer_ids[#reviewer_ids + 1] = id
  end

  for id in pairs(pending_map) do
    add_reviewer_id(id)
  end
  for id in pairs(latest_reviews) do
    add_reviewer_id(id)
  end
  for id in pairs(fallback_reviews) do
    add_reviewer_id(id)
  end

  local reviewers = {}
  for _, id in ipairs(reviewer_ids) do
    local pending = pending_map[id]
    local latest_review = latest_reviews[id] or fallback_reviews[id]
    local display_name = normalize_string(type(pending) == "table" and pending.display_name or "")
    if display_name == "" then
      display_name = normalize_string(type(latest_review) == "table" and latest_review.display_name or "")
    end

    local request_value = type(pending) == "table" and pending.request_value or nil
    if request_value == nil and type(latest_review) == "table" then
      request_value = latest_review.request_value
    end

    local kind = normalize_string(type(pending) == "table" and pending.kind or "")
    if kind == "" then
      kind = normalize_string(type(latest_review) == "table" and latest_review.kind or "")
    end

    local state = "PENDING"
    if not pending and type(latest_review) == "table" and normalize_review_state(latest_review.state) then
      state = latest_review.state
    end

    local can_rerequest = false
    if not pending
      and type(latest_review) == "table"
      and COMPLETE_REVIEW_STATES[normalize_string(latest_review.state):upper()]
      and type(request_value) == "string"
      and request_value ~= "" then
      can_rerequest = true
      local review_commit_oid = normalize_string(latest_review.commit_oid)
      if head_ref_oid ~= "" and review_commit_oid ~= "" then
        can_rerequest = head_ref_oid ~= review_commit_oid
      end
    end

    if display_name ~= "" then
      reviewers[#reviewers + 1] = {
        id = id,
        display_name = display_name,
        request_value = request_value,
        kind = kind == "team" and "team" or "user",
        state = state,
        is_pending = pending ~= nil,
        latest_review_commit_oid = type(latest_review) == "table" and latest_review.commit_oid or "",
        latest_review_submitted_at = type(latest_review) == "table" and latest_review.submitted_at or "",
        can_rerequest = can_rerequest,
      }
    end
  end

  table.sort(reviewers, function(left, right)
    local left_kind = left.kind == "user" and 1 or 2
    local right_kind = right.kind == "user" and 1 or 2
    if left_kind ~= right_kind then
      return left_kind < right_kind
    end
    local left_name = normalize_key(left.display_name)
    local right_name = normalize_key(right.display_name)
    if left_name ~= right_name then
      return left_name < right_name
    end
    return normalize_key(left.id) < normalize_key(right.id)
  end)

  return reviewers
end

function M.count_states(reviewers)
  local counts = {}
  local total = 0

  for _, reviewer in ipairs(type(reviewers) == "table" and reviewers or {}) do
    local state = normalize_review_state(type(reviewer) == "table" and reviewer.state or nil)
    if state then
      if state == "CHANGES_REQUESTED" then
        counts.REQUEST_CHANGES = (tonumber(counts.REQUEST_CHANGES) or 0) + 1
      else
        counts[state] = (tonumber(counts[state]) or 0) + 1
      end
      total = total + 1
    end
  end

  return counts, total
end

function M.find(reviewers, payload)
  reviewers = type(reviewers) == "table" and reviewers or {}
  payload = type(payload) == "table" and payload or {}

  local target_id = normalize_key(payload.id)
  local request_value = normalize_key(payload.request_value)
  local display_name = normalize_key(payload.display_name)

  for _, reviewer in ipairs(reviewers) do
    local candidate_id = normalize_key(type(reviewer) == "table" and reviewer.id or nil)
    local candidate_value = normalize_key(type(reviewer) == "table" and reviewer.request_value or nil)
    local candidate_name = normalize_key(type(reviewer) == "table" and reviewer.display_name or nil)

    if target_id ~= "" and candidate_id == target_id then
      return reviewer
    end
    if request_value ~= "" and candidate_value == request_value then
      return reviewer
    end
    if display_name ~= "" and candidate_name == display_name then
      return reviewer
    end
  end

  return nil
end

return M
