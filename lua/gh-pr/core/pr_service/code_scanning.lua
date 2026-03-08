local M = {}

local function normalize_string(ctx, value, fallback)
  if type(ctx.normalize_string) == "function" then
    return ctx.normalize_string(value, fallback)
  end
  if type(value) == "string" and value ~= "" then
    return value
  end
  return fallback or ""
end

local function clamp_positive(ctx, value, fallback, max_value)
  if type(ctx.clamp_positive) == "function" then
    return ctx.clamp_positive(value, fallback, max_value)
  end

  local number = tonumber(value) or tonumber(fallback) or 1
  number = math.max(1, math.floor(number))
  if tonumber(max_value) and number > tonumber(max_value) then
    number = tonumber(max_value)
  end
  return number
end

local function normalize_repository(input, ctx)
  if type(ctx.normalize_repository_from_input) == "function" then
    local repository = ctx.normalize_repository_from_input(input)
    if repository then
      return repository
    end
  end

  if type(input) == "table" then
    if type(input.owner) == "string" and input.owner ~= "" and type(input.name) == "string" and input.name ~= "" then
      return {
        owner = input.owner,
        name = input.name,
        full_name = input.full_name or (input.owner .. "/" .. input.name),
      }
    end

    if type(input.nameWithOwner) == "string" and input.nameWithOwner ~= "" then
      local owner, name = input.nameWithOwner:match("^([^/]+)/(.+)$")
      if owner and name then
        return {
          owner = owner,
          name = name,
          full_name = input.nameWithOwner,
        }
      end
    end

    if type(input.full_name) == "string" and input.full_name ~= "" then
      local owner, name = input.full_name:match("^([^/]+)/(.+)$")
      if owner and name then
        return {
          owner = owner,
          name = name,
          full_name = input.full_name,
        }
      end
    end
  end

  if type(input) == "string" and input ~= "" then
    local owner, name = input:match("^([^/]+)/(.+)$")
    if owner and name then
      return {
        owner = owner,
        name = name,
        full_name = owner .. "/" .. name,
      }
    end
  end

  return nil
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
  local severity = type(value) == "string" and value:lower() or ""
  if severity == "critical" or severity == "high" or severity == "medium" or severity == "low" then
    return severity
  end
  if severity == "error" then
    return "high"
  end
  if severity == "warning" then
    return "medium"
  end
  if severity == "note" or severity == "notice" then
    return "low"
  end
  return "low"
end

local function normalize_message_text(value)
  if type(value) == "table" then
    return type(value.text) == "string" and value.text or ""
  end
  return type(value) == "string" and value or ""
end

local function resolve_repository(opts, ctx)
  opts = type(opts) == "table" and opts or {}
  local details = type(opts.details) == "table" and opts.details or nil
  local candidates = {
    opts.repository,
    type(details) == "table" and details.baseRepository or nil,
    type(details) == "table" and details.headRepository or nil,
  }

  for _, candidate in ipairs(candidates) do
    local repository = normalize_repository(candidate, ctx)
    if repository then
      return repository, nil
    end
  end

  return ctx.resolve_repository()
end

local function classify_unavailable_error(err)
  local message = type(err) == "string" and err or ""
  local lowered = message:lower()
  if lowered:find("code scanning is not enabled", 1, true)
    or lowered:find("advanced security must be enabled", 1, true)
    or lowered:find("resource not accessible", 1, true)
    or lowered:find("not found", 1, true)
    or lowered:find("404", 1, true) then
    return true, message ~= "" and message or "Code scanning is unavailable for this repository"
  end
  return false, message
end

local function code_scanning_endpoint(repository, number, page, per_page, state)
  return string.format(
    "repos/%s/%s/code-scanning/alerts?pr=%d&state=%s&page=%d&per_page=%d",
    repository.owner,
    repository.name,
    tonumber(number) or 0,
    state,
    page,
    per_page
  )
end

local function normalize_alert(alert, number, repository, ctx)
  local rule = type(alert) == "table" and type(alert.rule) == "table" and alert.rule or {}
  local tool = type(alert) == "table" and type(alert.tool) == "table" and alert.tool or {}
  local instance = type(alert) == "table" and type(alert.most_recent_instance) == "table" and alert.most_recent_instance or {}
  local location = type(instance.location) == "table" and instance.location or {}
  local message = normalize_message_text(instance.message)
  local description = normalize_string(ctx, rule.description, "")
  local title = description ~= "" and description or normalize_string(ctx, rule.id, "Code scanning alert")
  if message == "" then
    message = normalize_message_text(rule.full_description) or description
  end

  local severity = normalize_severity(
    rule.security_severity_level or rule.severity or type(instance.severity) == "string" and instance.severity or nil
  )

  local alert_number = tonumber(type(alert) == "table" and alert.number or nil) or 0
  local start_line = normalize_line(location.start_line or location.startLine or location.line)
  local end_line = normalize_line(location.end_line or location.endLine or location.start_line or location.line)
  if start_line > 0 and end_line > 0 and end_line < start_line then
    start_line, end_line = end_line, start_line
  end
  if start_line > 0 and end_line == 0 then
    end_line = start_line
  elseif end_line > 0 and start_line == 0 then
    start_line = end_line
  end

  return {
    number = alert_number,
    id = normalize_string(ctx, type(alert) == "table" and alert.id or "", ""),
    state = normalize_string(ctx, type(alert) == "table" and alert.state or "", "open"),
    rule_id = normalize_string(ctx, rule.id, ""),
    rule_name = title,
    tool_name = normalize_string(ctx, tool.name, ""),
    severity = severity,
    html_url = normalize_string(ctx, type(alert) == "table" and alert.html_url or "", ""),
    instances_url = normalize_string(ctx, type(alert) == "table" and alert.instances_url or "", ""),
    path = normalize_path(location.path),
    start_line = start_line,
    end_line = end_line,
    ref = normalize_string(ctx, type(instance) == "table" and instance.ref or "", ""),
    message = normalize_string(ctx, message, ""),
    description = description,
    raw_details = normalize_string(ctx, normalize_message_text(rule.full_description), ""),
    repository = repository.full_name,
    pr_number = tonumber(number) or 0,
  }
end

function M.fetch_code_scanning_alerts(number, opts, ctx)
  opts = type(opts) == "table" and opts or {}
  local repository, repo_err = resolve_repository(opts, ctx)
  if not repository then
    return nil, repo_err
  end

  local state = normalize_string(ctx, opts.state, "open"):lower()
  local per_page = clamp_positive(ctx, opts.per_page or 100, 100, 100)
  local max_pages = clamp_positive(ctx, opts.max_pages or 20, 20, 100)
  local alerts = {}

  for page = 1, max_pages do
    local payload, err = ctx.gh.run_json({ "api", code_scanning_endpoint(repository, number, page, per_page, state) })
    if not payload then
      local unavailable, message = classify_unavailable_error(err)
      if unavailable then
        return {
          pr_number = tonumber(number) or 0,
          repository = repository.full_name,
          alerts = {},
          unavailable = true,
          message = message,
        }, nil
      end
      return nil, err
    end
    if type(payload) ~= "table" then
      return nil, "Unexpected GitHub code scanning response format"
    end

    local count = 0
    for _, alert in ipairs(payload) do
      alerts[#alerts + 1] = normalize_alert(alert, number, repository, ctx)
      count = count + 1
    end

    if count < per_page then
      break
    end
  end

  return {
    pr_number = tonumber(number) or 0,
    repository = repository.full_name,
    alerts = alerts,
    unavailable = false,
    message = nil,
  }, nil
end

function M.fetch_code_scanning_alerts_async(number, opts, callback, ctx)
  opts = type(opts) == "table" and opts or {}
  callback = callback or function() end

  local repository, repo_err = resolve_repository(opts, ctx)
  if not repository then
    callback(nil, repo_err)
    return
  end

  local state = normalize_string(ctx, opts.state, "open"):lower()
  local per_page = clamp_positive(ctx, opts.per_page or 100, 100, 100)
  local max_pages = clamp_positive(ctx, opts.max_pages or 20, 20, 100)
  local alerts = {}

  local function load_page(page)
    if page > max_pages then
      callback({
        pr_number = tonumber(number) or 0,
        repository = repository.full_name,
        alerts = alerts,
        unavailable = false,
        message = nil,
      }, nil)
      return
    end

    ctx.gh.run_json_async({ "api", code_scanning_endpoint(repository, number, page, per_page, state) }, nil, function(payload, err)
      if not payload then
        local unavailable, message = classify_unavailable_error(err)
        if unavailable then
          callback({
            pr_number = tonumber(number) or 0,
            repository = repository.full_name,
            alerts = {},
            unavailable = true,
            message = message,
          }, nil)
          return
        end
        callback(nil, err)
        return
      end
      if type(payload) ~= "table" then
        callback(nil, "Unexpected GitHub code scanning response format")
        return
      end

      local count = 0
      for _, alert in ipairs(payload) do
        alerts[#alerts + 1] = normalize_alert(alert, number, repository, ctx)
        count = count + 1
      end

      if count < per_page then
        callback({
          pr_number = tonumber(number) or 0,
          repository = repository.full_name,
          alerts = alerts,
          unavailable = false,
          message = nil,
        }, nil)
        return
      end

      load_page(page + 1)
    end)
  end

  load_page(1)
end

return M
