local M = {}

local CACHE_VERSION = 1

local loaded = false
local store = {
  version = CACHE_VERSION,
  repos = {},
}

local function joinpath(...)
  if vim.fs and vim.fs.joinpath then
    return vim.fs.joinpath(...)
  end

  local separator = package.config:sub(1, 1)
  return table.concat({ ... }, separator)
end

local function dirname(path)
  if vim.fs and vim.fs.dirname then
    return vim.fs.dirname(path)
  end

  return path:match("^(.*)[/\\]") or ""
end

local function cache_file_path()
  return joinpath(vim.fn.stdpath("state"), "gh-pr", "pr_cache.json")
end

local function ensure_cache_dir()
  local dir = dirname(cache_file_path())
  if dir ~= "" then
    vim.fn.mkdir(dir, "p")
  end
end

local function normalize_query_results(raw_results)
  local result = {}
  for _, item in ipairs(type(raw_results) == "table" and raw_results or {}) do
    if type(item) == "table" and type(item.query) == "table" then
      result[#result + 1] = {
        query = item.query,
        error = type(item.error) == "string" and item.error or nil,
        prs = type(item.prs) == "table" and item.prs or {},
      }
    end
  end
  return result
end

local function normalize_details_by_pr(raw_details)
  local result = {}
  for key, value in pairs(type(raw_details) == "table" and raw_details or {}) do
    if type(value) == "table" then
      local number_key = tostring(key)
      result[number_key] = value
    end
  end
  return result
end

local function normalize_repo_entry(entry)
  if type(entry) ~= "table" then
    return nil
  end

  local updated_at = tonumber(entry.updated_at) or 0
  return {
    key = type(entry.key) == "string" and entry.key or "",
    repository_full_name = type(entry.repository_full_name) == "string" and entry.repository_full_name or "",
    git_root = type(entry.git_root) == "string" and entry.git_root or "",
    updated_at = updated_at,
    query_results = normalize_query_results(entry.query_results),
    details_by_pr = normalize_details_by_pr(entry.details_by_pr),
  }
end

local function normalize_store(decoded)
  local normalized = {
    version = CACHE_VERSION,
    repos = {},
  }

  if type(decoded) ~= "table" then
    return normalized
  end

  local repos = type(decoded.repos) == "table" and decoded.repos or {}
  for key, entry in pairs(repos) do
    if type(key) == "string" and key ~= "" then
      local normalized_entry = normalize_repo_entry(entry)
      if normalized_entry then
        normalized_entry.key = key
        normalized.repos[key] = normalized_entry
      end
    end
  end

  return normalized
end

local function load()
  if loaded then
    return
  end

  loaded = true
  local path = cache_file_path()
  if vim.fn.filereadable(path) ~= 1 then
    return
  end

  local content = table.concat(vim.fn.readfile(path), "\n")
  if content == "" then
    return
  end

  local ok, decoded = pcall(vim.json.decode, content)
  if not ok then
    return
  end

  store = normalize_store(decoded)
end

local function save()
  load()
  ensure_cache_dir()
  local path = cache_file_path()

  local ok, encoded = pcall(vim.json.encode, {
    version = CACHE_VERSION,
    repos = store.repos,
  })
  if not ok then
    return false
  end

  vim.fn.writefile(vim.split(encoded, "\n", { plain = true }), path)
  return true
end

function M.path()
  return cache_file_path()
end

function M.get_repo(key)
  load()
  if type(key) ~= "string" or key == "" then
    return nil
  end

  local entry = store.repos[key]
  if type(entry) ~= "table" then
    return nil
  end

  return vim.deepcopy(entry)
end

function M.set_repo(key, entry)
  load()
  if type(key) ~= "string" or key == "" then
    return false
  end

  local normalized = normalize_repo_entry(entry)
  if not normalized then
    return false
  end

  normalized.key = key
  store.repos[key] = normalized
  return save()
end

function M.delete_repo(key)
  load()
  if type(key) ~= "string" or key == "" then
    return false
  end

  if store.repos[key] == nil then
    return false
  end

  store.repos[key] = nil
  return save()
end

function M.prune(max_age_seconds, now_seconds)
  load()
  local max_age = tonumber(max_age_seconds) or 0
  if max_age < 1 then
    return false
  end

  local now = tonumber(now_seconds) or os.time()
  local changed = false
  for key, entry in pairs(store.repos) do
    local updated_at = tonumber(entry.updated_at) or 0
    if updated_at > 0 and (now - updated_at) > max_age then
      store.repos[key] = nil
      changed = true
    end
  end

  if changed then
    save()
  end

  return changed
end

return M
