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

local function url_encode(value)
  if type(value) ~= "string" then
    return ""
  end
  return (value:gsub("[^%w%-%._~]", function(char)
    return string.format("%%%02X", string.byte(char))
  end))
end

local function normalize_severity(value)
  local severity = type(value) == "string" and value:lower() or ""
  if severity == "critical" or severity == "high" or severity == "medium" or severity == "low" then
    return severity
  end
  if severity == "moderate" then
    return "medium"
  end
  if severity == "error" then
    return "high"
  end
  if severity == "warning" then
    return "medium"
  end
  return "low"
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
  if lowered:find("dependency graph is not enabled", 1, true)
    or lowered:find("dependency graph disabled", 1, true)
    or lowered:find("dependency review is not enabled", 1, true)
    or lowered:find("advanced security must be enabled", 1, true)
    or lowered:find("resource not accessible", 1, true)
    or lowered:find("not found", 1, true)
    or lowered:find("404", 1, true) then
    return true, message ~= "" and message or "Dependency review is unavailable for this repository"
  end
  return false, message
end

local function normalize_vulnerability(entry, ctx)
  entry = type(entry) == "table" and entry or {}
  local advisory_id = normalize_string(ctx, entry.advisory_ghsa_id or entry.advisoryGhsaId or entry.ghsa_id or entry.ghsa or entry.id, "")
  local summary = normalize_string(ctx, entry.advisory_summary or entry.summary or entry.description, "")
  if summary == "" and advisory_id ~= "" then
    summary = advisory_id
  end
  if summary == "" then
    summary = "Vulnerability"
  end

  return {
    advisory_id = advisory_id,
    summary = summary,
    severity = normalize_severity(entry.severity),
    advisory_url = normalize_string(ctx, entry.advisory_url or entry.url or entry.html_url, ""),
  }
end

local function infer_package_name(entry, ctx)
  local package_url = normalize_string(ctx, entry.package_url or entry.packageUrl, "")
  local package_name = normalize_string(ctx, entry.package_name or entry.packageName or entry.name, "")
  if package_name ~= "" then
    return package_name, package_url
  end

  if package_url ~= "" then
    local inferred = package_url:match("/([^/@]+)$") or package_url:match("/([^/@]+)@")
    if inferred and inferred ~= "" then
      return inferred, package_url
    end
  end

  return "dependency", package_url
end

local function normalize_dependency_change(entry, number, repository, compare_basehead, ctx)
  entry = type(entry) == "table" and entry or {}
  local package_name, package_url = infer_package_name(entry, ctx)
  local vulnerabilities = {}
  for _, vulnerability in ipairs(type(entry.vulnerabilities) == "table" and entry.vulnerabilities or {}) do
    vulnerabilities[#vulnerabilities + 1] = normalize_vulnerability(vulnerability, ctx)
  end

  return {
    manifest_path = normalize_path(entry.manifest_path or entry.manifest or entry.file_path or entry.filePath),
    ecosystem = normalize_string(ctx, entry.ecosystem, ""),
    package_name = package_name,
    change_type = normalize_string(ctx, entry.change_type or entry.changeType, "changed"),
    current_version = normalize_string(ctx, entry.current_version or entry.version or entry.current_requirement or entry.requirement, ""),
    previous_version = normalize_string(ctx, entry.previous_version or entry.previousVersion or entry.previous_requirement, ""),
    scope = normalize_string(ctx, entry.scope, ""),
    license = normalize_string(ctx, entry.license, ""),
    package_url = package_url,
    vulnerabilities = vulnerabilities,
    vulnerable = not vim.tbl_isempty(vulnerabilities),
    repository = repository.full_name,
    pr_number = tonumber(number) or 0,
    compare_basehead = compare_basehead,
  }
end

local function compare_head_qualifier(base_repository, head_repository, details)
  local base_ref = type(details) == "table" and details.baseRefName or nil
  local head_ref = type(details) == "table" and details.headRefName or nil
  if type(base_ref) ~= "string" or base_ref == "" or type(head_ref) ~= "string" or head_ref == "" then
    return nil, "Missing base/head refs for dependency review compare"
  end

  if not head_repository or head_repository.full_name == base_repository.full_name then
    return string.format("%s...%s", base_ref, head_ref), nil
  end

  return string.format("%s:%s...%s:%s", base_repository.owner, base_ref, head_repository.owner, head_ref), nil
end

local function dependency_compare_endpoint(repository, compare_basehead)
  return string.format(
    "repos/%s/%s/dependency-graph/compare/%s",
    repository.owner,
    repository.name,
    url_encode(compare_basehead)
  )
end

function M.fetch_dependency_review(number, opts, ctx)
  opts = type(opts) == "table" and opts or {}
  local details = type(opts.details) == "table" and opts.details or nil
  if type(details) ~= "table" then
    return nil, "Missing pull request details for dependency review"
  end

  local repository, repo_err = resolve_repository(opts, ctx)
  if not repository then
    return nil, repo_err
  end

  local head_repository = normalize_repository(opts.head_repository or details.headRepository, ctx) or repository
  local compare_basehead, compare_err = compare_head_qualifier(repository, head_repository, details)
  if not compare_basehead then
    return nil, compare_err
  end

  local payload, err = ctx.gh.run_json({ "api", dependency_compare_endpoint(repository, compare_basehead) })
  if not payload then
    local unavailable, message = classify_unavailable_error(err)
    if unavailable then
      return {
        pr_number = tonumber(number) or 0,
        repository = repository.full_name,
        compare_basehead = compare_basehead,
        changes = {},
        unavailable = true,
        message = message,
      }, nil
    end
    return nil, err
  end
  if type(payload) ~= "table" then
    return nil, "Unexpected GitHub dependency review response format"
  end

  local changes = {}
  local vulnerable_count = 0
  for _, entry in ipairs(payload) do
    local normalized = normalize_dependency_change(entry, number, repository, compare_basehead, ctx)
    if normalized.vulnerable then
      vulnerable_count = vulnerable_count + 1
    end
    changes[#changes + 1] = normalized
  end

  table.sort(changes, function(left, right)
    local left_manifest = type(left.manifest_path) == "string" and left.manifest_path or ""
    local right_manifest = type(right.manifest_path) == "string" and right.manifest_path or ""
    if left_manifest ~= right_manifest then
      return left_manifest < right_manifest
    end
    if left.vulnerable ~= right.vulnerable then
      return left.vulnerable == true
    end
    return (left.package_name or "") < (right.package_name or "")
  end)

  return {
    pr_number = tonumber(number) or 0,
    repository = repository.full_name,
    compare_basehead = compare_basehead,
    changes = changes,
    vulnerable_count = vulnerable_count,
    unavailable = false,
    message = nil,
  }, nil
end

function M.fetch_dependency_review_async(number, opts, callback, ctx)
  opts = type(opts) == "table" and opts or {}
  callback = callback or function() end

  local details = type(opts.details) == "table" and opts.details or nil
  if type(details) ~= "table" then
    callback(nil, "Missing pull request details for dependency review")
    return
  end

  local repository, repo_err = resolve_repository(opts, ctx)
  if not repository then
    callback(nil, repo_err)
    return
  end

  local head_repository = normalize_repository(opts.head_repository or details.headRepository, ctx) or repository
  local compare_basehead, compare_err = compare_head_qualifier(repository, head_repository, details)
  if not compare_basehead then
    callback(nil, compare_err)
    return
  end

  ctx.gh.run_json_async({ "api", dependency_compare_endpoint(repository, compare_basehead) }, nil, function(payload, err)
    if not payload then
      local unavailable, message = classify_unavailable_error(err)
      if unavailable then
        callback({
          pr_number = tonumber(number) or 0,
          repository = repository.full_name,
          compare_basehead = compare_basehead,
          changes = {},
          vulnerable_count = 0,
          unavailable = true,
          message = message,
        }, nil)
        return
      end
      callback(nil, err)
      return
    end
    if type(payload) ~= "table" then
      callback(nil, "Unexpected GitHub dependency review response format")
      return
    end

    local changes = {}
    local vulnerable_count = 0
    for _, entry in ipairs(payload) do
      local normalized = normalize_dependency_change(entry, number, repository, compare_basehead, ctx)
      if normalized.vulnerable then
        vulnerable_count = vulnerable_count + 1
      end
      changes[#changes + 1] = normalized
    end

    table.sort(changes, function(left, right)
      local left_manifest = type(left.manifest_path) == "string" and left.manifest_path or ""
      local right_manifest = type(right.manifest_path) == "string" and right.manifest_path or ""
      if left_manifest ~= right_manifest then
        return left_manifest < right_manifest
      end
      if left.vulnerable ~= right.vulnerable then
        return left.vulnerable == true
      end
      return (left.package_name or "") < (right.package_name or "")
    end)

    callback({
      pr_number = tonumber(number) or 0,
      repository = repository.full_name,
      compare_basehead = compare_basehead,
      changes = changes,
      vulnerable_count = vulnerable_count,
      unavailable = false,
      message = nil,
    }, nil)
  end)
end

return M
