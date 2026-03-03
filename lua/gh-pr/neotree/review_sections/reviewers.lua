local M = {}

local function normalize_login(entry)
  if type(entry) == "table" then
    if type(entry.login) == "string" and entry.login ~= "" then
      return entry.login
    end
    if type(entry.author) == "table" and type(entry.author.login) == "string" and entry.author.login ~= "" then
      return entry.author.login
    end
    if type(entry.requestedReviewer) == "table" and type(entry.requestedReviewer.login) == "string"
      and entry.requestedReviewer.login ~= "" then
      return entry.requestedReviewer.login
    end
    if type(entry.user) == "table" and type(entry.user.login) == "string" and entry.user.login ~= "" then
      return entry.user.login
    end
  elseif type(entry) == "string" and entry ~= "" then
    return entry
  end
  return nil
end

local function reviewer_state_priority(state)
  local value = type(state) == "string" and state:upper() or ""
  if value == "CHANGES_REQUESTED" then
    return 4
  end
  if value == "APPROVED" then
    return 3
  end
  if value == "PENDING" then
    return 2
  end
  if value == "COMMENTED" then
    return 1
  end
  return 0
end

local function normalize_reviewer_state(state)
  local value = type(state) == "string" and state:upper() or ""
  if value == "CHANGES_REQUESTED" then
    return "CHANGES_REQUESTED"
  end
  if value == "APPROVED" then
    return "APPROVED"
  end
  if value == "PENDING" then
    return "PENDING"
  end
  if value == "COMMENTED" then
    return "COMMENTED"
  end
  return "PENDING"
end

local function normalize_summary_state_label(state)
  local value = type(state) == "string" and state:upper() or ""
  if value == "CHANGES_REQUESTED" then
    return "REQUEST_CHANGES"
  end
  return value
end

function M.build_nodes(pr, details)
  local map = {}

  local function upsert(login, state_value)
    if type(login) ~= "string" or login == "" then
      return
    end

    local incoming = normalize_reviewer_state(state_value)
    local incoming_priority = reviewer_state_priority(incoming)
    local current = map[login]
    if not current or incoming_priority >= reviewer_state_priority(current.state) then
      map[login] = {
        login = login,
        state = incoming,
      }
    end
  end

  for _, reviewer in ipairs(type(details.reviewRequests) == "table" and details.reviewRequests or {}) do
    upsert(normalize_login(reviewer), "PENDING")
  end

  for _, review in ipairs(type(details.latestReviews) == "table" and details.latestReviews or {}) do
    upsert(normalize_login(review.author), review.state)
  end

  for _, review in ipairs(type(details.reviews) == "table" and details.reviews or {}) do
    upsert(normalize_login(review.author), review.state)
  end

  local nodes = {}
  for _, item in pairs(map) do
    nodes[#nodes + 1] = {
      id = string.format("ghpr-review:%d:reviewer:%s", pr.number, item.login),
      name = string.format("@%s [%s]", item.login, item.state),
      type = "file",
      extra = {
        kind = "reviewer",
        reviewer_state = item.state,
        pr = pr,
        details = details,
      },
    }
  end

  table.sort(nodes, function(left, right)
    return left.name < right.name
  end)

  if vim.tbl_isempty(nodes) then
    return {
      {
        id = string.format("ghpr-review:%d:reviewers-empty", pr.number),
        name = "No reviewers found",
        type = "message",
        extra = {
          kind = "message",
          pr = pr,
          details = details,
        },
      },
    }
  end

  return nodes
end

function M.count_states(nodes)
  local counts = {}
  local total = 0
  for _, node in ipairs(type(nodes) == "table" and nodes or {}) do
    local extra = type(node) == "table" and type(node.extra) == "table" and node.extra or nil
    if extra and extra.kind == "reviewer" then
      local state = normalize_summary_state_label(extra.reviewer_state)
      if state ~= "" then
        counts[state] = (tonumber(counts[state]) or 0) + 1
        total = total + 1
      end
    end
  end
  return counts, total
end

return M
