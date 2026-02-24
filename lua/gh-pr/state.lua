local M = {}

local state = {
  active = {
    pr = nil,
    details = nil,
    file = nil,
  },
  viewed = {},
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

local function state_file_path()
  return joinpath(vim.fn.stdpath("state"), "gh-pr", "state.json")
end

local function ensure_state_dir()
  local dir = dirname(state_file_path())
  if dir and dir ~= "" then
    vim.fn.mkdir(dir, "p")
  end
end

local function load_persisted_state()
  local path = state_file_path()
  if vim.fn.filereadable(path) ~= 1 then
    return
  end

  local lines = vim.fn.readfile(path)
  local content = table.concat(lines, "\n")
  if content == "" then
    return
  end

  local ok, decoded = pcall(vim.json.decode, content)
  if not ok or type(decoded) ~= "table" then
    return
  end

  if type(decoded.viewed) == "table" then
    state.viewed = decoded.viewed
  end
end

local function save_persisted_state()
  ensure_state_dir()
  local path = state_file_path()
  local encoded = vim.json.encode({ viewed = state.viewed })
  vim.fn.writefile(vim.split(encoded, "\n", { plain = true }), path)
end

local function get_pr_bucket(repo_full_name, pr_number)
  if type(repo_full_name) ~= "string" or repo_full_name == "" then
    return nil
  end

  if type(pr_number) ~= "number" then
    return nil
  end

  local repo_bucket = state.viewed[repo_full_name]
  if type(repo_bucket) ~= "table" then
    return nil
  end

  local pr_bucket = repo_bucket[tostring(pr_number)]
  if type(pr_bucket) ~= "table" then
    return nil
  end

  return pr_bucket
end

local function ensure_pr_bucket(repo_full_name, pr_number)
  if type(repo_full_name) ~= "string" or repo_full_name == "" then
    return nil
  end

  if type(pr_number) ~= "number" then
    return nil
  end

  state.viewed[repo_full_name] = state.viewed[repo_full_name] or {}
  state.viewed[repo_full_name][tostring(pr_number)] = state.viewed[repo_full_name][tostring(pr_number)] or {}
  return state.viewed[repo_full_name][tostring(pr_number)]
end

function M.setup()
  load_persisted_state()
end

function M.set_active_pr(pr, details)
  state.active.pr = pr
  state.active.details = details
  state.active.file = nil
end

function M.set_active_file(file)
  state.active.file = file
end

function M.get_active_pr()
  return state.active.pr, state.active.details
end

function M.get_active_file()
  return state.active.file
end

function M.clear_active()
  state.active.pr = nil
  state.active.details = nil
  state.active.file = nil
end

function M.is_viewed(repo_full_name, pr_number, path)
  if type(path) ~= "string" or path == "" then
    return false
  end

  local pr_bucket = get_pr_bucket(repo_full_name, pr_number)
  if not pr_bucket then
    return false
  end

  return pr_bucket[path] == true
end

function M.set_viewed(repo_full_name, pr_number, path, viewed)
  if type(path) ~= "string" or path == "" then
    return false
  end

  local pr_bucket = ensure_pr_bucket(repo_full_name, pr_number)
  if not pr_bucket then
    return false
  end

  if viewed then
    pr_bucket[path] = true
  else
    pr_bucket[path] = nil
  end

  save_persisted_state()
  return true
end

function M.toggle_viewed(repo_full_name, pr_number, path)
  local viewed = M.is_viewed(repo_full_name, pr_number, path)
  M.set_viewed(repo_full_name, pr_number, path, not viewed)
  return not viewed
end

function M.reset_pr_viewed(repo_full_name, pr_number)
  if type(repo_full_name) ~= "string" or repo_full_name == "" or type(pr_number) ~= "number" then
    return false
  end

  if not state.viewed[repo_full_name] then
    return false
  end

  state.viewed[repo_full_name][tostring(pr_number)] = {}
  save_persisted_state()
  return true
end

return M
