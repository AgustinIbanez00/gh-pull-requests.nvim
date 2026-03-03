local M = {}

local function sanitize_node_id_component(value)
  local raw = type(value) == "string" and value or tostring(value or "")
  raw = raw:gsub("[^%w%-%._]", "_")
  if raw == "" then
    return "item"
  end
  return raw
end

local function normalize_check_result(check)
  local status = type(check.status) == "string" and check.status:upper() or (type(check.state) == "string" and check.state:upper() or "")
  local conclusion = type(check.conclusion) == "string" and check.conclusion:upper() or ""

  if conclusion == "SUCCESS" then
    return "PASS"
  end
  if conclusion == "FAILURE" or conclusion == "TIMED_OUT" or conclusion == "CANCELLED" or conclusion == "ACTION_REQUIRED" then
    return "FAIL"
  end
  if status == "QUEUED" or status == "IN_PROGRESS" or status == "PENDING" or status == "EXPECTED" then
    return "PENDING"
  end
  if conclusion ~= "" then
    return conclusion
  end
  if status ~= "" then
    return status
  end
  return "UNKNOWN"
end

local function normalize_check_name(check)
  if type(check.name) == "string" and check.name ~= "" then
    return check.name
  end
  if type(check.context) == "string" and check.context ~= "" then
    return check.context
  end
  if type(check.workflowRun) == "table" and type(check.workflowRun.workflow) == "table"
    and type(check.workflowRun.workflow.name) == "string" and check.workflowRun.workflow.name ~= "" then
    return check.workflowRun.workflow.name
  end
  return "check"
end

local function normalize_check_url(check)
  if type(check.detailsUrl) == "string" and check.detailsUrl ~= "" then
    return check.detailsUrl
  end
  if type(check.targetUrl) == "string" and check.targetUrl ~= "" then
    return check.targetUrl
  end
  if type(check.url) == "string" and check.url ~= "" then
    return check.url
  end
  return ""
end

function M.build_nodes(pr, details)
  local nodes = {}
  local seen = {}
  for _, check in ipairs(type(details.statusCheckRollup) == "table" and details.statusCheckRollup or {}) do
    local name = normalize_check_name(check)
    local state = normalize_check_result(check)
    local url = normalize_check_url(check)
    local key = sanitize_node_id_component(name) .. ":" .. sanitize_node_id_component(url)
    local order = (seen[key] or 0) + 1
    seen[key] = order
    nodes[#nodes + 1] = {
      id = string.format("ghpr-review:%d:check:%s:%d", pr.number, key, order),
      name = string.format("[%s] %s", state, name),
      type = "file",
      extra = {
        kind = "check",
        check_state = state,
        check_url = url,
        pr = pr,
        details = details,
      },
    }
  end

  if vim.tbl_isempty(nodes) then
    return {
      {
        id = string.format("ghpr-review:%d:checks-empty", pr.number),
        name = "No checks found",
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

function M.collect_signature(details)
  local checks = type(details.statusCheckRollup) == "table" and details.statusCheckRollup or {}
  local entries = {}

  for _, check in ipairs(checks) do
    local name = normalize_check_name(check)
    local state = normalize_check_result(check)
    entries[#entries + 1] = string.format("%s=%s", sanitize_node_id_component(name), sanitize_node_id_component(state))
  end

  table.sort(entries)
  return {
    total = #entries,
    signature = table.concat(entries, "|"),
  }
end

function M.count_states(nodes)
  local counts = {}
  local total = 0
  for _, node in ipairs(type(nodes) == "table" and nodes or {}) do
    local extra = type(node) == "table" and type(node.extra) == "table" and node.extra or nil
    if extra and extra.kind == "check" then
      local state = type(extra.check_state) == "string" and extra.check_state:upper() or ""
      if state ~= "" then
        counts[state] = (tonumber(counts[state]) or 0) + 1
        total = total + 1
      end
    end
  end
  return counts, total
end

return M
