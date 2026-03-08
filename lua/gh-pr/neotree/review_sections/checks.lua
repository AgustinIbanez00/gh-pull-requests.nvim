local M = {}

local function sanitize_node_id_component(value)
  local raw = type(value) == "string" and value or tostring(value or "")
  raw = raw:gsub("[^%w%-%._]", "_")
  if raw == "" then
    return "item"
  end
  return raw
end

local function safe_string(value, fallback)
  if type(value) == "string" and value ~= "" then
    return value
  end
  return fallback or ""
end

local function normalize_path(path)
  if type(path) ~= "string" then
    return ""
  end
  return path:gsub("\\", "/"):gsub("/+", "/"):gsub("^/", ""):gsub("/$", "")
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
  if type(check.workflowName) == "string" and check.workflowName ~= "" then
    return check.workflowName
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

local function normalize_check_level(level)
  local value = type(level) == "string" and level:lower() or "notice"
  if value ~= "failure" and value ~= "warning" then
    value = "notice"
  end
  return value
end

local function check_key(check)
  local name = normalize_check_name(check)
  local url = normalize_check_url(check)
  local raw_id = tonumber(type(check) == "table" and (check.checkRunId or check.check_run_id or check.databaseId) or nil)
  if raw_id then
    return string.format("run:%d", raw_id)
  end
  return sanitize_node_id_component(name) .. ":" .. sanitize_node_id_component(url)
end

local function compact_annotation_title(annotation)
  local title = safe_string(annotation.title, "")
  if title == "" then
    title = safe_string(safe_string(annotation.message, ""):match("([^\r\n]+)"), "Annotation")
  end
  return title
end

local function annotation_label(annotation)
  local level = normalize_check_level(annotation.annotation_level)
  local prefix = level == "failure" and "FAIL" or (level == "warning" and "WARN" or "NOTE")
  local start_line = tonumber(annotation.start_line) or 0
  local end_line = tonumber(annotation.end_line) or start_line
  local line_label = start_line > 0 and (start_line == end_line and ("L" .. start_line) or string.format("L%d-L%d", start_line, end_line)) or "L?"
  return string.format("[%s] %s %s", prefix, line_label, compact_annotation_title(annotation))
end

local function resolved_repository(details)
  if type(details) ~= "table" then
    return nil
  end

  if type(details.headRepository) == "table" and type(details.headRepository.nameWithOwner) == "string"
    and details.headRepository.nameWithOwner ~= "" then
    return details.headRepository.nameWithOwner
  end

  if type(details.baseRepository) == "table" and type(details.baseRepository.nameWithOwner) == "string"
    and details.baseRepository.nameWithOwner ~= "" then
    return details.baseRepository.nameWithOwner
  end

  return nil
end

local function session_annotation_entry(session, key)
  if type(session) ~= "table" or type(session.check_annotations_by_key) ~= "table" then
    return nil
  end
  return session.check_annotations_by_key[key]
end

local function details_link_node(pr, details, check, base_id)
  local url = normalize_check_url(check)
  if url == "" then
    return nil
  end

  return {
    id = base_id .. ":details",
    name = "Open check details",
    type = "file",
    extra = {
      kind = "check_details_link",
      check_url = url,
      pr = pr,
      details = details,
      check = check,
      check_key = check_key(check),
    },
  }
end

local function message_child(id, text, pr, details, extra)
  return {
    id = id,
    name = text,
    type = "message",
    extra = vim.tbl_extend("force", {
      kind = "message",
      pr = pr,
      details = details,
    }, type(extra) == "table" and extra or {}),
  }
end

local function build_annotation_children(pr, details, check, base_id, annotations)
  local grouped = {}
  local order = {}

  for index, annotation in ipairs(type(annotations) == "table" and annotations or {}) do
    local path = normalize_path(type(annotation) == "table" and annotation.path or "")
    local group_key = path ~= "" and path or "(unknown path)"
    if not grouped[group_key] then
      grouped[group_key] = {}
      order[#order + 1] = group_key
    end
    local entry = vim.deepcopy(annotation)
    entry.__index = index
    grouped[group_key][#grouped[group_key] + 1] = entry
  end

  table.sort(order)

  local file_nodes = {}
  local check_url = normalize_check_url(check)
  local repository = resolved_repository(details)

  for _, group_key in ipairs(order) do
    local items = grouped[group_key]
    table.sort(items, function(left, right)
      local left_line = tonumber(left.start_line) or 0
      local right_line = tonumber(right.start_line) or 0
      if left_line ~= right_line then
        return left_line < right_line
      end
      return (tonumber(left.__index) or 0) < (tonumber(right.__index) or 0)
    end)

    local file_id = base_id .. ":file:" .. sanitize_node_id_component(group_key)
    local children = {}
    for position, annotation in ipairs(items) do
      local path = normalize_path(annotation.path)
      local start_line = tonumber(annotation.start_line) or 0
      local end_line = tonumber(annotation.end_line) or start_line
      local annotation_id = table.concat({
        file_id,
        "annotation",
        sanitize_node_id_component(path ~= "" and path or "unknown"),
        tostring(start_line),
        tostring(end_line),
        tostring(position),
      }, ":")

      children[#children + 1] = {
        id = annotation_id,
        name = annotation_label(annotation),
        type = "file",
        extra = {
          kind = "check_annotation",
          pr = pr,
          details = details,
          check = check,
          check_key = check_key(check),
          check_url = check_url,
          repository = repository,
          annotation = vim.deepcopy(annotation),
          annotations = vim.deepcopy(annotations),
          path = path,
          target_path = path,
          target_line = start_line,
          target_end_line = end_line,
          annotation_level = normalize_check_level(annotation.annotation_level),
          can_open_diff = path ~= "" and start_line > 0,
        },
      }
    end

    file_nodes[#file_nodes + 1] = {
      id = file_id,
      name = string.format("%s (%d)", group_key, #children),
      type = "directory",
      path = group_key ~= "(unknown path)" and group_key or nil,
      extra = {
        kind = "check_annotation_file",
        pr = pr,
        details = details,
        check = check,
        check_key = check_key(check),
        file_path = group_key ~= "(unknown path)" and group_key or "",
      },
      children = children,
    }
  end

  return file_nodes
end

local function build_check_children(pr, details, check, session, base_id)
  local key = check_key(check)
  local children = {}
  local entry = session_annotation_entry(session, key)

  if type(entry) == "table" and entry.loading == true then
    children[#children + 1] = message_child(
      base_id .. ":loading",
      "Loading annotations...",
      pr,
      details,
      { check_key = key }
    )
  elseif type(entry) == "table" and type(entry.error) == "string" and entry.error ~= "" then
    children[#children + 1] = message_child(
      base_id .. ":error",
      "Unable to load annotations: " .. tostring(entry.error),
      pr,
      details,
      { check_key = key }
    )
  elseif type(entry) == "table" and entry.loaded == true then
    local annotations = type(entry.annotations) == "table" and entry.annotations or {}
    if vim.tbl_isempty(annotations) then
      children[#children + 1] = message_child(
        base_id .. ":empty",
        "No annotations",
        pr,
        details,
        { check_key = key }
      )
    else
      local file_nodes = build_annotation_children(pr, details, check, base_id, annotations)
      for _, node in ipairs(file_nodes) do
        children[#children + 1] = node
      end
    end
  end

  local link_node = details_link_node(pr, details, check, base_id)
  if link_node then
    children[#children + 1] = link_node
  end

  return children
end

function M.build_nodes(pr, details, opts)
  opts = type(opts) == "table" and opts or {}
  local session = type(opts.session) == "table" and opts.session or nil
  local nodes = {}
  local seen = {}
  for _, check in ipairs(type(details.statusCheckRollup) == "table" and details.statusCheckRollup or {}) do
    local name = normalize_check_name(check)
    local state = normalize_check_result(check)
    local url = normalize_check_url(check)
    local key = check_key(check)
    local dedupe_key = sanitize_node_id_component(key)
    local order = (seen[dedupe_key] or 0) + 1
    seen[dedupe_key] = order
    local node_id = string.format("ghpr-review:%d:check:%s:%d", pr.number, dedupe_key, order)
    nodes[#nodes + 1] = {
      id = node_id,
      name = string.format("[%s] %s", state, name),
      type = "directory",
      extra = {
        kind = "check",
        check_state = state,
        check_url = url,
        check = check,
        check_key = key,
        pr = pr,
        details = details,
      },
      children = build_check_children(pr, details, check, session, node_id),
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
