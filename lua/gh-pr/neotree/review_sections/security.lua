local M = {}

local SEVERITY_ORDER = {
  critical = 1,
  high = 2,
  medium = 3,
  low = 4,
}

local function safe_string(value, fallback)
  if type(value) == "string" and value ~= "" then
    return value
  end
  return fallback or ""
end

local function sanitize_node_id_component(value)
  local raw = type(value) == "string" and value or tostring(value or "")
  raw = raw:gsub("[^%w%-%._]", "_")
  if raw == "" then
    return "item"
  end
  return raw
end

local function normalize_path(path)
  if type(path) ~= "string" then
    return ""
  end
  return path:gsub("\\", "/"):gsub("/+", "/"):gsub("^/", ""):gsub("/$", "")
end

local function normalize_line(value)
  local number = tonumber(value)
  if not number then
    return 0
  end
  number = math.floor(number)
  if number < 1 then
    return 0
  end
  return number
end

local function normalize_severity(value)
  local severity = type(value) == "string" and value:lower() or "low"
  if severity == "critical" or severity == "high" or severity == "medium" or severity == "low" then
    return severity
  end
  if severity == "moderate" or severity == "warning" then
    return "medium"
  end
  if severity == "error" then
    return "high"
  end
  return "low"
end

local function normalize_change_type(value)
  local change = type(value) == "string" and value:lower() or "changed"
  if change == "" then
    return "changed"
  end
  return change
end

local function message_node(id, text, pr, details, extra)
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

local function details_files(details)
  return type(details) == "table" and type(details.files) == "table" and details.files or {}
end

local function resolve_file(details, path)
  local target = normalize_path(path)
  if target == "" then
    return nil
  end

  for _, file in ipairs(details_files(details)) do
    local file_path = normalize_path(type(file) == "table" and (file.path or file.filename) or "")
    local previous_path = normalize_path(type(file) == "table" and (file.previous_filename or file.previousFilename) or "")
    if file_path == target or previous_path == target then
      return file
    end
  end

  return nil
end

local function root_entry(session, key)
  local cache = type(session) == "table" and type(session.security_cache) == "table" and session.security_cache or nil
  if type(cache) ~= "table" then
    return nil
  end
  local entry = cache[key]
  return type(entry) == "table" and entry or nil
end

local function alert_sort(left, right)
  local left_severity = SEVERITY_ORDER[normalize_severity(left.severity)] or 99
  local right_severity = SEVERITY_ORDER[normalize_severity(right.severity)] or 99
  if left_severity ~= right_severity then
    return left_severity < right_severity
  end

  local left_line = normalize_line(left.start_line)
  local right_line = normalize_line(right.start_line)
  if left_line ~= right_line then
    return left_line < right_line
  end

  return safe_string(left.rule_name, "") < safe_string(right.rule_name, "")
end

local function vulnerability_sort(left, right)
  local left_severity = SEVERITY_ORDER[normalize_severity(left.severity)] or 99
  local right_severity = SEVERITY_ORDER[normalize_severity(right.severity)] or 99
  if left_severity ~= right_severity then
    return left_severity < right_severity
  end
  return safe_string(left.summary, "") < safe_string(right.summary, "")
end

local function highest_vulnerability_severity(vulnerabilities)
  local highest = nil
  for _, vulnerability in ipairs(type(vulnerabilities) == "table" and vulnerabilities or {}) do
    local severity = normalize_severity(vulnerability.severity)
    if not highest or (SEVERITY_ORDER[severity] or 99) < (SEVERITY_ORDER[highest] or 99) then
      highest = severity
    end
  end
  return highest or "low"
end

local function dependency_label(change)
  local name = safe_string(change.package_name, "dependency")
  local current_version = safe_string(change.current_version, "")
  local previous_version = safe_string(change.previous_version, "")
  local version_label = ""
  if previous_version ~= "" and current_version ~= "" then
    version_label = string.format(" %s -> %s", previous_version, current_version)
  elseif current_version ~= "" then
    version_label = " " .. current_version
  elseif previous_version ~= "" then
    version_label = " " .. previous_version
  end

  local change_type = normalize_change_type(change.change_type)
  local text = string.format("%s%s [%s]", name, version_label, change_type)
  local vulnerability_count = #(type(change.vulnerabilities) == "table" and change.vulnerabilities or {})
  if vulnerability_count > 0 then
    text = string.format("%s [%d vulns]", text, vulnerability_count)
  end
  return text
end

local function alert_label(alert)
  local severity = normalize_severity(alert.severity):upper()
  local start_line = normalize_line(alert.start_line)
  local end_line = normalize_line(alert.end_line)
  local line_label = "L?"
  if start_line > 0 then
    if end_line > 0 and end_line ~= start_line then
      line_label = string.format("L%d-L%d", start_line, end_line)
    else
      line_label = "L" .. tostring(start_line)
    end
  end

  local title = safe_string(alert.rule_name, "")
  if title == "" then
    title = safe_string(safe_string(alert.message, ""):match("([^\r\n]+)"), "Security alert")
  end
  return string.format("[%s] %s %s", severity, line_label, title)
end

local function vulnerability_label(vulnerability)
  local advisory = safe_string(vulnerability.advisory_id, "")
  local summary = safe_string(vulnerability.summary, "Vulnerability")
  if advisory ~= "" then
    return string.format("%s %s", advisory, summary)
  end
  return summary
end

local function build_code_scanning_children(pr, details, entry, base_id)
  if type(entry) ~= "table" then
    return {
      message_node(base_id .. ":idle", "Press <CR> to load findings", pr, details),
    }
  end

  if entry.loading == true then
    return {
      message_node(base_id .. ":loading", "Loading...", pr, details, { kind = "security_loading" }),
    }
  end

  if entry.unavailable == true then
    return {
      message_node(base_id .. ":unavailable", "Unavailable: " .. safe_string(entry.message, "Security is unavailable"), pr, details, {
        kind = "security_unavailable",
      }),
    }
  end

  if type(entry.error) == "string" and entry.error ~= "" then
    return {
      message_node(base_id .. ":error", "Unable to load code scanning: " .. entry.error, pr, details),
    }
  end

  local alerts = type(entry.alerts) == "table" and vim.deepcopy(entry.alerts) or {}
  if vim.tbl_isempty(alerts) then
    return {
      message_node(base_id .. ":empty", "No findings", pr, details),
    }
  end

  local grouped = {}
  local order = {}
  for _, alert in ipairs(alerts) do
    local path = normalize_path(type(alert) == "table" and alert.path or "")
    local key = path ~= "" and path or "(unknown path)"
    if not grouped[key] then
      grouped[key] = {}
      order[#order + 1] = key
    end
    grouped[key][#grouped[key] + 1] = alert
  end
  table.sort(order)

  local children = {}
  for _, path_key in ipairs(order) do
    local path_alerts = grouped[path_key]
    table.sort(path_alerts, alert_sort)
    local file_children = {}
    local resolved_file = resolve_file(details, path_key)

    for index, alert in ipairs(path_alerts) do
      local start_line = normalize_line(alert.start_line)
      local end_line = normalize_line(alert.end_line)
      local alert_id = table.concat({
        base_id,
        "file",
        sanitize_node_id_component(path_key),
        "alert",
        tostring(start_line),
        tostring(index),
      }, ":")

      file_children[#file_children + 1] = {
        id = alert_id,
        name = alert_label(alert),
        type = "file",
        extra = {
          kind = "security_code_scanning_alert",
          pr = pr,
          details = details,
          alert = vim.deepcopy(alert),
          alerts = vim.deepcopy(path_alerts),
          alert_key = safe_string(alert.id, safe_string(alert.number, "")),
          alert_url = safe_string(alert.html_url, ""),
          target_path = normalize_path(alert.path),
          target_line = start_line > 0 and start_line or nil,
          target_end_line = end_line > 0 and end_line or nil,
          alert_severity = normalize_severity(alert.severity),
          can_open_diff = resolved_file ~= nil and start_line > 0,
          file = resolved_file,
        },
      }
    end

    children[#children + 1] = {
      id = table.concat({ base_id, "file", sanitize_node_id_component(path_key) }, ":"),
      name = string.format("%s (%d)", path_key, #file_children),
      type = "directory",
      path = path_key ~= "(unknown path)" and path_key or nil,
      extra = {
        kind = "security_code_scanning_file",
        pr = pr,
        details = details,
        file_path = path_key ~= "(unknown path)" and path_key or "",
      },
      children = file_children,
    }
  end

  return children
end

local function build_dependency_children(pr, details, entry, base_id)
  if type(entry) ~= "table" then
    return {
      message_node(base_id .. ":idle", "Press <CR> to load findings", pr, details),
    }
  end

  if entry.loading == true then
    return {
      message_node(base_id .. ":loading", "Loading...", pr, details, { kind = "security_loading" }),
    }
  end

  if entry.unavailable == true then
    return {
      message_node(base_id .. ":unavailable", "Unavailable: " .. safe_string(entry.message, "Security is unavailable"), pr, details, {
        kind = "security_unavailable",
      }),
    }
  end

  if type(entry.error) == "string" and entry.error ~= "" then
    return {
      message_node(base_id .. ":error", "Unable to load dependency review: " .. entry.error, pr, details),
    }
  end

  local changes = type(entry.changes) == "table" and vim.deepcopy(entry.changes) or {}
  if vim.tbl_isempty(changes) then
    return {
      message_node(base_id .. ":empty", "No findings", pr, details),
    }
  end

  local manifests = {}
  local order = {}
  for _, change in ipairs(changes) do
    local manifest_path = normalize_path(type(change) == "table" and change.manifest_path or "")
    local key = manifest_path ~= "" and manifest_path or "(unknown manifest)"
    if not manifests[key] then
      manifests[key] = {}
      order[#order + 1] = key
    end
    manifests[key][#manifests[key] + 1] = change
  end
  table.sort(order)

  local children = {}
  for _, manifest_key in ipairs(order) do
    local manifest_changes = manifests[manifest_key]
    table.sort(manifest_changes, function(left, right)
      if left.vulnerable ~= right.vulnerable then
        return left.vulnerable == true
      end
      return safe_string(left.package_name, "") < safe_string(right.package_name, "")
    end)

    local manifest_children = {}
    local manifest_file = resolve_file(details, manifest_key)
    for index, change in ipairs(manifest_changes) do
      local package_children = {}
      local vulnerabilities = type(change.vulnerabilities) == "table" and vim.deepcopy(change.vulnerabilities) or {}
      table.sort(vulnerabilities, vulnerability_sort)
      for vulnerability_index, vulnerability in ipairs(vulnerabilities) do
        package_children[#package_children + 1] = {
          id = table.concat({
            base_id,
            "manifest",
            sanitize_node_id_component(manifest_key),
            "package",
            sanitize_node_id_component(safe_string(change.package_name, "dependency")),
            "vulnerability",
            tostring(vulnerability_index),
          }, ":"),
          name = vulnerability_label(vulnerability),
          type = "file",
          extra = {
            kind = "security_dependency_vulnerability",
            pr = pr,
            details = details,
            dependency = vim.deepcopy(change),
            vulnerability = vim.deepcopy(vulnerability),
            advisory_url = safe_string(vulnerability.advisory_url, ""),
            security_severity = normalize_severity(vulnerability.severity),
          },
        }
      end

      manifest_children[#manifest_children + 1] = {
        id = table.concat({
          base_id,
          "manifest",
          sanitize_node_id_component(manifest_key),
          "package",
          sanitize_node_id_component(safe_string(change.package_name, "dependency")),
          tostring(index),
        }, ":"),
        name = dependency_label(change),
        type = type(package_children[1]) == "table" and "directory" or "file",
        extra = {
          kind = "security_dependency_package",
          pr = pr,
          details = details,
          dependency = vim.deepcopy(change),
          manifest_path = manifest_key ~= "(unknown manifest)" and manifest_key or "",
          file = manifest_file,
          vulnerability_count = #package_children,
          has_vulnerabilities = #package_children > 0,
          security_severity = #package_children > 0 and highest_vulnerability_severity(vulnerabilities) or nil,
        },
        children = package_children,
      }
    end

    children[#children + 1] = {
      id = table.concat({ base_id, "manifest", sanitize_node_id_component(manifest_key) }, ":"),
      name = string.format("%s (%d)", manifest_key, #manifest_children),
      type = "directory",
      path = manifest_key ~= "(unknown manifest)" and manifest_key or nil,
      extra = {
        kind = "security_dependency_manifest",
        pr = pr,
        details = details,
        manifest_path = manifest_key ~= "(unknown manifest)" and manifest_key or "",
        file = manifest_file,
      },
      children = manifest_children,
    }
  end

  return children
end

function M.build_section_title(session)
  local cache = type(session) == "table" and type(session.security_cache) == "table" and session.security_cache or {}
  local code_entry = type(cache.code_scanning) == "table" and cache.code_scanning or nil
  local dependency_entry = type(cache.dependency_review) == "table" and cache.dependency_review or nil
  local parts = {}

  local alert_count = code_entry and type(code_entry.alerts) == "table" and #code_entry.alerts or 0
  if alert_count > 0 then
    parts[#parts + 1] = string.format("%d alerts", alert_count)
  end

  local vulnerable_count = dependency_entry and tonumber(dependency_entry.vulnerable_count) or 0
  if vulnerable_count > 0 then
    parts[#parts + 1] = string.format("%d vulnerable", vulnerable_count)
  end

  if vim.tbl_isempty(parts) then
    return "Security"
  end
  return string.format("Security %s", table.concat(parts, " · "))
end

function M.build_nodes(pr, details, session)
  local code_entry = root_entry(session, "code_scanning")
  local dependency_entry = root_entry(session, "dependency_review")
  local code_title = "Code scanning"
  local dependency_title = "Dependency review"

  if type(code_entry) == "table" and code_entry.loaded == true then
    local alert_count = type(code_entry.alerts) == "table" and #code_entry.alerts or 0
    code_title = string.format("Code scanning (%d)", alert_count)
  end

  if type(dependency_entry) == "table" and dependency_entry.loaded == true then
    local vulnerable = tonumber(dependency_entry.vulnerable_count) or 0
    local changed = type(dependency_entry.changes) == "table" and #dependency_entry.changes or 0
    dependency_title = string.format("Dependency review (%d vulnerable / %d changed)", vulnerable, changed)
  end

  local code_id = string.format("ghpr-review:%d:security:code-scanning", pr.number)
  local dependency_id = string.format("ghpr-review:%d:security:dependency-review", pr.number)

  return {
    {
      id = code_id,
      name = code_title,
      type = "directory",
      extra = {
        kind = "security_code_scanning",
        pr = pr,
        details = details,
      },
      children = build_code_scanning_children(pr, details, code_entry, code_id),
    },
    {
      id = dependency_id,
      name = dependency_title,
      type = "directory",
      extra = {
        kind = "security_dependency_review",
        pr = pr,
        details = details,
      },
      children = build_dependency_children(pr, details, dependency_entry, dependency_id),
    },
  }
end

return M
