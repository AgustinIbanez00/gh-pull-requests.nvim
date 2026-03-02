local M = {}

local state = {
  active = {
    pr = nil,
    details = nil,
    file = nil,
  },
  viewed = {},
  reviews = {},
  prefs = {
    diff_view = {
      mode = "vertical",
      ignore_whitespace = false,
      render_whitespace = true,
      render_endlines = false,
    },
    images = {
      fallback_default_action = "metadata",
    },
  },
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

  if type(decoded.prefs) == "table" then
    state.prefs = vim.tbl_deep_extend("force", state.prefs, decoded.prefs)
  end
end

local function save_persisted_state()
  ensure_state_dir()
  local path = state_file_path()
  local encoded = vim.json.encode({
    viewed = state.viewed,
    prefs = state.prefs,
  })
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

local function normalize_path(path)
  if type(path) ~= "string" then
    return ""
  end

  return path:gsub("\\", "/")
end

local function normalize_diff_mode(mode)
  if mode == "vertical" or mode == "horizontal" or mode == "unified" then
    return mode
  end

  return "vertical"
end

local function sanitize_diff_view_prefs(input)
  local result = {
    mode = "vertical",
    ignore_whitespace = false,
    render_whitespace = true,
    render_endlines = false,
  }

  if type(input) ~= "table" then
    return result
  end

  result.mode = normalize_diff_mode(input.mode)
  result.ignore_whitespace = input.ignore_whitespace == true
  result.render_whitespace = input.render_whitespace ~= false
  result.render_endlines = input.render_endlines == true
  return result
end

local function sanitize_image_prefs(input)
  local result = {
    fallback_default_action = "metadata",
  }

  if type(input) ~= "table" then
    return result
  end

  local action = type(input.fallback_default_action) == "string" and input.fallback_default_action:lower() or ""
  if action ~= "metadata" and action ~= "open_local_current" and action ~= "open_local_both" and action ~= "open_github" then
    action = "metadata"
  end
  result.fallback_default_action = action

  return result
end

function M.setup()
  load_persisted_state()
  state.prefs = state.prefs or {}
  state.prefs.diff_view = sanitize_diff_view_prefs(state.prefs.diff_view)
  state.prefs.images = sanitize_image_prefs(state.prefs.images)
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
  path = normalize_path(path)
  if path == "" then
    return false
  end

  local pr_bucket = get_pr_bucket(repo_full_name, pr_number)
  if not pr_bucket then
    return false
  end

  return pr_bucket[path] == true
end

function M.set_viewed(repo_full_name, pr_number, path, viewed)
  path = normalize_path(path)
  if path == "" then
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
  path = normalize_path(path)
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

function M.set_active_review(repo_full_name, pr, details)
  if type(repo_full_name) ~= "string" or repo_full_name == "" then
    return false
  end

  if type(pr) ~= "table" then
    return false
  end

  local number = tonumber(pr.number)
  if not number then
    return false
  end

  state.reviews[repo_full_name] = {
    pr = pr,
    details = details or pr,
    updated_at = os.time(),
  }
  return true
end

function M.get_active_review(repo_full_name)
  if type(repo_full_name) ~= "string" or repo_full_name == "" then
    return nil, nil
  end

  local review = state.reviews[repo_full_name]
  if type(review) ~= "table" then
    return nil, nil
  end

  return review.pr, review.details
end

function M.clear_active_review(repo_full_name)
  if type(repo_full_name) ~= "string" or repo_full_name == "" then
    return false
  end

  if state.reviews[repo_full_name] == nil then
    return false
  end

  state.reviews[repo_full_name] = nil
  return true
end

function M.get_diff_view_prefs()
  state.prefs = state.prefs or {}
  state.prefs.diff_view = sanitize_diff_view_prefs(state.prefs.diff_view)
  return vim.deepcopy(state.prefs.diff_view)
end

function M.set_diff_view_prefs(prefs)
  state.prefs = state.prefs or {}
  state.prefs.diff_view = sanitize_diff_view_prefs(prefs)
  save_persisted_state()
  return true
end

function M.update_diff_view_pref(key, value)
  local current = M.get_diff_view_prefs()
  current[key] = value
  return M.set_diff_view_prefs(current)
end

function M.get_image_prefs()
  state.prefs = state.prefs or {}
  state.prefs.images = sanitize_image_prefs(state.prefs.images)
  return vim.deepcopy(state.prefs.images)
end

function M.set_image_prefs(prefs)
  state.prefs = state.prefs or {}
  state.prefs.images = sanitize_image_prefs(prefs)
  save_persisted_state()
  return true
end

function M.update_image_pref(key, value)
  local current = M.get_image_prefs()
  current[key] = value
  return M.set_image_prefs(current)
end

return M
