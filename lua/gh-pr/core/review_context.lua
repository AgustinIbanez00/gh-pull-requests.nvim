local M = {}

local function safe_string(value)
  if type(value) == "string" and value ~= "" then
    return value
  end
  return ""
end

function M.normalize_path(path)
  if type(path) ~= "string" then
    return ""
  end

  local normalized = path:gsub("\\", "/"):gsub("/+", "/")
  normalized = normalized:gsub("^/", ""):gsub("/$", "")
  return normalized
end

local function repository_name_with_owner(repository)
  repository = type(repository) == "table" and repository or {}

  local full_name = safe_string(repository.nameWithOwner)
  if full_name ~= "" then
    return full_name
  end

  local owner = type(repository.owner) == "table" and safe_string(repository.owner.login) or safe_string(repository.owner)
  local name = safe_string(repository.name)
  if owner ~= "" and name ~= "" then
    return owner .. "/" .. name
  end

  return ""
end

function M.resolve_repository_full_name(details, fallback_repo)
  details = type(details) == "table" and details or {}

  local base = repository_name_with_owner(details.baseRepository)
  if base ~= "" then
    return base
  end

  local head = repository_name_with_owner(details.headRepository)
  if head ~= "" then
    return head
  end

  return safe_string(fallback_repo)
end

function M.file_candidates(file)
  file = type(file) == "table" and file or {}

  local candidates = {}
  local seen = {}
  for _, candidate in ipairs({
    file.path,
    file.filename,
    file.previousFilename,
    file.previous_filename,
  }) do
    local normalized = M.normalize_path(candidate)
    if normalized ~= "" and not seen[normalized] then
      seen[normalized] = true
      candidates[#candidates + 1] = normalized
    end
  end

  return candidates
end

function M.file_canonical_path(file)
  local candidates = M.file_candidates(file)
  return candidates[1] or ""
end

function M.build_file_lookup(details)
  local lookup = {
    by_candidate = {},
    by_canonical = {},
    ordered_paths = {},
  }

  for _, file in ipairs(type(details) == "table" and type(details.files) == "table" and details.files or {}) do
    if type(file) == "table" then
      local canonical = M.file_canonical_path(file)
      if canonical ~= "" then
        if lookup.by_canonical[canonical] == nil then
          lookup.by_canonical[canonical] = file
          lookup.ordered_paths[#lookup.ordered_paths + 1] = canonical
        end

        if lookup.by_candidate[canonical] == nil then
          lookup.by_candidate[canonical] = canonical
        end

        for _, candidate in ipairs(M.file_candidates(file)) do
          if lookup.by_candidate[candidate] == nil then
            lookup.by_candidate[candidate] = canonical
          end
        end
      end
    end
  end

  return lookup
end

local function resolve_lookup(details, opts)
  if type(opts) == "table" and type(opts.lookup) == "table" then
    return opts.lookup
  end
  return M.build_file_lookup(details)
end

function M.resolve_canonical_file_path(details, path, opts)
  local normalized = M.normalize_path(path)
  if normalized == "" then
    return ""
  end

  local lookup = resolve_lookup(details, opts)
  if type(lookup.by_candidate) == "table" and type(lookup.by_candidate[normalized]) == "string" then
    return lookup.by_candidate[normalized]
  end

  return normalized
end

function M.find_file(details, path, opts)
  local normalized = M.normalize_path(path)
  if normalized == "" then
    return nil
  end

  local lookup = resolve_lookup(details, opts)
  local canonical = type(lookup.by_candidate) == "table" and lookup.by_candidate[normalized] or nil
  if type(canonical) ~= "string" or canonical == "" then
    canonical = normalized
  end

  if type(lookup.by_canonical) == "table" then
    return lookup.by_canonical[canonical]
  end

  return nil
end

return M
