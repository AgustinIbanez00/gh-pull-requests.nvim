local M = {
  name = "gh_pr",
  display_name = "GH PR",
}

local cache_store = require("gh-pr.cache_store")
local config = require("gh-pr.config")
local follow = require("gh-pr.neotree.follow")
local path_tree = require("gh-pr.path_tree")
local pr_service = require("gh-pr.pr_service")
local repo = require("gh-pr.repo")
local runtime_state = require("gh-pr.state")
local virtual_files = require("gh-pr.virtual_files")

local renderer = require("neo-tree.ui.renderer")

local runtime_cache = {
  repos = {},
  last_prune_at = 0,
}

local DEFAULT_RENDERERS = {
  folder = {
    { "indent", with_expanders = true },
    { "kind_icon" },
    { "container", width = "100%", content = { { "name", zindex = 10 } } },
  },
  query = {
    { "indent", with_expanders = true },
    { "kind_icon" },
    { "container", width = "100%", content = { { "name", zindex = 10 } } },
  },
  pr = {
    { "indent", with_expanders = true },
    { "kind_icon" },
    { "container", width = "100%", content = { { "name", zindex = 10 } } },
  },
  files = {
    { "indent", with_expanders = true },
    { "kind_icon" },
    { "container", width = "100%", content = { { "name", zindex = 10 } } },
  },
  directory = {
    { "indent", with_expanders = true },
    { "kind_icon" },
    { "container", width = "100%", content = { { "name", zindex = 10 } } },
  },
  overview = {
    { "indent", with_expanders = false },
    { "kind_icon" },
    { "container", width = "100%", content = { { "name", zindex = 10 } } },
  },
  file = {
    { "indent", with_expanders = false },
    { "kind_icon" },
    { "container", width = "100%", content = { { "name", zindex = 10 } } },
  },
  message = {
    { "indent", with_markers = false, with_expanders = false },
    { "kind_icon" },
    { "name", highlight = "NeoTreeMessage" },
  },
}

local function now_seconds()
  return os.time()
end

local function cache_options()
  local options = (config.get() or {}).cache or {}
  local gh_pr_options = type(options.gh_pr) == "table" and options.gh_pr or {}
  return gh_pr_options
end

local function cache_enabled()
  return cache_options().enabled ~= false
end

local function make_repo_key(repository, git_root)
  if type(repository) ~= "table" or type(repository.full_name) ~= "string" then
    return nil
  end

  local root = type(git_root) == "string" and git_root or ""
  return repository.full_name .. "::" .. root
end

local function resolve_repo_context()
  local repository, repository_err = pr_service.resolve_repository()
  if not repository then
    return nil, repository_err
  end

  local git_root, git_root_err = repo.git_root()
  if not git_root then
    git_root = vim.fn.getcwd()
    if git_root_err then
      vim.schedule(function()
        vim.notify("gh-pr cache root fallback: " .. tostring(git_root_err), vim.log.levels.DEBUG)
      end)
    end
  end

  local key = make_repo_key(repository, git_root)
  if not key then
    return nil, "Unable to build cache key for repository"
  end

  return {
    key = key,
    repository = repository,
    git_root = git_root,
  }, nil
end

local function session_is_stale(session)
  local options = cache_options()
  local max_cache_age = tonumber(options.max_cache_age_seconds) or 0
  local updated_at = tonumber(session.updated_at) or 0

  if session.last_error and not vim.tbl_isempty(session.query_results or {}) then
    return true
  end

  if updated_at <= 0 then
    return not vim.tbl_isempty(session.query_results or {})
  end

  if max_cache_age > 0 and (now_seconds() - updated_at) > max_cache_age then
    return true
  end

  return false
end

local function maybe_prune_persisted_cache()
  if not cache_enabled() then
    return
  end

  local options = cache_options()
  local max_age = tonumber(options.max_cache_age_seconds) or 0
  if max_age < 1 then
    return
  end

  local now = now_seconds()
  if runtime_cache.last_prune_at > 0 and (now - runtime_cache.last_prune_at) < 60 then
    return
  end

  runtime_cache.last_prune_at = now
  cache_store.prune(max_age, now)
end

local function dedupe_prs(prs)
  local result = {}
  local seen = {}
  for _, pr in ipairs(type(prs) == "table" and prs or {}) do
    local number = tonumber(type(pr) == "table" and pr.number or nil)
    local key = number and tostring(number) or nil
    if key and not seen[key] then
      seen[key] = true
      result[#result + 1] = pr
    end
  end
  return result
end

local function sanitize_query_results(results)
  local sanitized = {}
  for _, result in ipairs(type(results) == "table" and results or {}) do
    if type(result) == "table" and type(result.query) == "table" then
      sanitized[#sanitized + 1] = {
        query = result.query,
        error = result.error,
        prs = dedupe_prs(result.prs),
      }
    end
  end
  return sanitized
end

local function sanitize_details_map(details_by_pr)
  local sanitized = {}
  for number, details in pairs(type(details_by_pr) == "table" and details_by_pr or {}) do
    if type(details) == "table" then
      local files = {}
      local seen_paths = {}
      for _, file in ipairs(type(details.files) == "table" and details.files or {}) do
        local path = type(file) == "table" and (file.path or file.filename) or nil
        if type(path) == "string" and path ~= "" and not seen_paths[path] then
          seen_paths[path] = true
          files[#files + 1] = file
        end
      end
      details.files = files
      sanitized[tostring(number)] = details
    end
  end
  return sanitized
end

local function new_repo_session(repo_context)
  return {
    key = repo_context.key,
    repository = repo_context.repository,
    git_root = repo_context.git_root,
    query_results = {},
    details_by_pr = {},
    detail_errors = {},
    updated_at = 0,
    loading = false,
    inflight = false,
    pending_refresh = false,
    last_error = nil,
    stale = false,
    states = {},
    follow = {},
    loaded_from_disk = false,
  }
end

local function ensure_repo_session(repo_context)
  runtime_cache.repos[repo_context.key] = runtime_cache.repos[repo_context.key] or new_repo_session(repo_context)
  local session = runtime_cache.repos[repo_context.key]

  session.repository = repo_context.repository
  session.git_root = repo_context.git_root

  if cache_enabled() and not session.loaded_from_disk then
    maybe_prune_persisted_cache()
    local persisted = cache_store.get_repo(repo_context.key)
    if type(persisted) == "table" then
      session.query_results = sanitize_query_results(persisted.query_results)
      session.details_by_pr = sanitize_details_map(persisted.details_by_pr)
      session.updated_at = tonumber(persisted.updated_at) or 0
      session.stale = session_is_stale(session)
    end
    session.loaded_from_disk = true
  end

  return session
end

local function persist_session(repo_context, session)
  if not cache_enabled() then
    return
  end

  cache_store.set_repo(repo_context.key, {
    repository_full_name = repo_context.repository.full_name,
    git_root = repo_context.git_root,
    updated_at = session.updated_at,
    query_results = session.query_results,
    details_by_pr = session.details_by_pr,
  })
end

local function register_state(session, state)
  if type(state) ~= "table" then
    return
  end

  local key = tostring(state)
  session.states[key] = state
  state.gh_pr_repo_key = session.key
end

local function ensure_follow_state(session)
  if type(session.follow) ~= "table" then
    session.follow = {}
  end
  return session.follow
end

local function remember_revealed_node(session, node_id, context)
  local follow_state = ensure_follow_state(session)
  if type(node_id) == "string" and node_id ~= "" then
    follow_state.last_node_id = node_id
  end

  if type(context) == "table" then
    local pr_number = tonumber(context.pr_number)
    if pr_number then
      follow_state.last_pr = pr_number
    end

    local path = follow.normalize_path(context.path)
    if path ~= "" then
      follow_state.last_path = path
    end
  end
end

local function repository_full_name(details)
  local repository = details.baseRepository or details.headRepository
  if not repository then
    return ""
  end

  if type(repository.nameWithOwner) == "string" then
    return repository.nameWithOwner
  end

  local owner, parsed_name
  if type(repository.owner) == "table" then
    owner = repository.owner.login
  else
    owner = repository.owner
  end
  if not owner and type(repository.nameWithOwner) == "string" then
    owner, parsed_name = repository.nameWithOwner:match("^([^/]+)/(.+)$")
  end

  local name = repository.name or parsed_name
  if type(owner) ~= "string" or type(name) ~= "string" then
    return ""
  end

  return owner .. "/" .. name
end

local function apply_runtime_cache(session)
  local active_pr, active_details = runtime_state.get_active_pr()
  if not active_pr or not active_details then
    return
  end

  local active_repo = repository_full_name(active_details)
  if active_repo == "" then
    return
  end

  if active_repo ~= session.repository.full_name then
    return
  end

  session.details_by_pr[tostring(active_pr.number)] = active_details
end

local function status_prefix(status)
  local normalized = (status or ""):lower()
  if normalized == "added" then
    return "+"
  end
  if normalized == "removed" then
    return "-"
  end
  if normalized == "renamed" then
    return "R"
  end
  if normalized == "copied" then
    return "C"
  end
  return "M"
end

local function file_display_name(path, file, options)
  local base_name = path:match("[^/\\]+$") or path
  local include_status = options.show_status_prefix ~= false
  if include_status then
    return string.format("[%s] %s", status_prefix(file.status), base_name)
  end

  return base_name
end

local function collect_file_entries(pr, details)
  local entries = {}
  local seen_paths = {}
  local repo_full_name = repository_full_name(details)
  local hide_viewed = config.get().hide_viewed_files

  for _, file in ipairs(details.files or {}) do
    local path = file.path or file.filename
    if path and path ~= "" and not seen_paths[path] then
      seen_paths[path] = true
      if not (hide_viewed and runtime_state.is_viewed(repo_full_name, pr.number, path)) then
        entries[#entries + 1] = {
          path = path,
          payload = file,
        }
      end
    end
  end

  return entries, repo_full_name
end

local function build_file_nodes(id_prefix, pr, details)
  local render_options = config.get_path_render("gh_pr")
  local entries, repo_full_name = collect_file_entries(pr, details)

  return path_tree.build_nodes(entries, {
    mode = render_options.mode,
    separator = render_options.separator,
    create_directory_node = function(display_name, full_path)
      return {
        id = string.format("%s:dir:%s", id_prefix, full_path),
        name = display_name,
        type = "directory",
        children = {},
        extra = {
          kind = "directory",
          pr = pr,
          details = details,
        },
      }
    end,
    create_file_node = function(file_item)
      local path = file_item.path
      local file = file_item.payload
      return {
        id = string.format("%s:file:%s", id_prefix, path),
        name = file_display_name(path, file, render_options),
        type = "file",
        path = path,
        extra = {
          kind = "file",
          file = file,
          pr = pr,
          details = details,
          repo = repo_full_name,
        },
      }
    end,
  })
end

local function get_query_node(query, results, session, opts)
  opts = opts or {}
  local query_index = tonumber(opts.query_index) or 0
  local query_base_id = tostring(query.id or query.label or "query")
  local query_id = string.format("%s:%d", query_base_id, query_index)
  local query_prefix = string.format("query:%s", query_id)
  local children = {}

  if results.error then
    table.insert(children, {
      id = "query-error:" .. query_id,
      name = "Error: " .. results.error,
      type = "message",
      extra = { kind = "message" },
    })
  elseif vim.tbl_isempty(results.prs) then
    table.insert(children, {
      id = "query-empty:" .. query_id,
      name = "No pull requests",
      type = "message",
      extra = { kind = "message" },
    })
  else
    local seen_prs = {}
    for _, pr in ipairs(results.prs) do
      local number = tonumber(pr.number)
      if number and seen_prs[number] then
        goto continue
      end
      if number then
        seen_prs[number] = true
      end

      local pr_prefix = string.format("%s:pr:%d", query_prefix, pr.number)
      local details = session.details_by_pr[tostring(pr.number)]
      local detail_err = session.detail_errors[tostring(pr.number)]
      local pr_children = {
        {
          id = string.format("%s:overview", pr_prefix),
          name = "Overview",
          type = "overview",
          extra = {
            kind = "overview",
            pr = pr,
            details = details,
          },
        },
      }

      if details then
        local file_children = build_file_nodes(pr_prefix, pr, details)
        table.insert(pr_children, {
          id = string.format("%s:files", pr_prefix),
          name = "Files",
          type = "files",
          children = file_children,
          extra = {
            kind = "files",
            pr = pr,
            details = details,
          },
        })
      else
        local message = "Loading files..."
        if detail_err then
          message = "Unable to load files: " .. detail_err
        elseif not session.loading then
          message = "Files are not available yet"
        end

        table.insert(pr_children, {
          id = string.format("%s:error", pr_prefix),
          name = message,
          type = "message",
          extra = {
            kind = "message",
            pr = pr,
            details = nil,
          },
        })
      end

      table.insert(children, {
        id = pr_prefix,
        name = string.format("#%d %s", pr.number, pr.title),
        type = "pr",
        children = pr_children,
        extra = {
          kind = "pr",
          pr = pr,
          details = details,
        },
      })
      ::continue::
    end
  end

  local stale_suffix = ""
  if opts.show_stale_badge and session.stale then
    stale_suffix = " [cached]"
  end

  return {
    id = "query:" .. query_id,
    name = string.format("%s (%d)%s", query.label, #(results.prs or {}), stale_suffix),
    type = "query",
    children = children,
    extra = {
      kind = "query",
      query = query,
    },
  }
end

local function build_nodes(session)
  local query_results = type(session.query_results) == "table" and session.query_results or {}
  local folder_map = {}
  local nodes = {}
  local show_stale_badge = cache_options().show_stale_badge ~= false

  if session.last_error then
    table.insert(nodes, {
      id = "source-error:" .. session.key,
      name = "Refresh error: " .. tostring(session.last_error),
      type = "message",
      extra = { kind = "message" },
    })
  end

  if session.loading and vim.tbl_isempty(query_results) then
    table.insert(nodes, {
      id = "source-loading:" .. session.key,
      name = "Loading pull requests...",
      type = "message",
      extra = { kind = "message" },
    })
    return nodes
  end

  if session.stale and show_stale_badge then
    table.insert(nodes, {
      id = "source-stale:" .. session.key,
      name = "Showing cached pull requests while refreshing...",
      type = "message",
      extra = { kind = "message" },
    })
  end

  for index, result in ipairs(query_results) do
    local folder_name = result.query.folder or "General"
    folder_map[folder_name] = folder_map[folder_name] or {}
    table.insert(folder_map[folder_name], {
      index = index,
      result = result,
    })
  end

  local folders = vim.tbl_keys(folder_map)
  table.sort(folders)

  for _, folder_name in ipairs(folders) do
    local query_nodes = {}
    for _, item in ipairs(folder_map[folder_name]) do
      table.insert(query_nodes, get_query_node(item.result.query, item.result, session, {
        show_stale_badge = show_stale_badge,
        query_index = item.index,
      }))
    end

    table.sort(query_nodes, function(left, right)
      return left.name < right.name
    end)

    local folder_label = folder_name
    if show_stale_badge and session.stale then
      folder_label = folder_name .. " [cached]"
    end

    table.insert(nodes, {
      id = "folder:" .. folder_name,
      name = folder_label,
      type = "folder",
      children = query_nodes,
      extra = { kind = "folder" },
    })
  end

  if vim.tbl_isempty(nodes) then
    return {
      {
        id = "empty",
        name = "No queries configured",
        type = "message",
        extra = { kind = "message" },
      },
    }
  end

  return nodes
end

local function render_state(state, session)
  if type(state) ~= "table" then
    return false
  end

  local ok = pcall(renderer.show_nodes, build_nodes(session), state)
  return ok
end

local function render_repo_states(repo_key)
  local session = runtime_cache.repos[repo_key]
  if not session then
    return
  end

  for state_key, state in pairs(session.states) do
    if type(state) ~= "table" or state.gh_pr_repo_key ~= repo_key then
      session.states[state_key] = nil
      goto continue
    end

    local ok = render_state(state, session)
    if not ok then
      session.states[state_key] = nil
    end
    ::continue::
  end
end

local function collect_pr_numbers(query_results)
  local set = {}
  local ordered = {}

  for _, result in ipairs(type(query_results) == "table" and query_results or {}) do
    for _, pr in ipairs(type(result.prs) == "table" and result.prs or {}) do
      local number = tonumber(pr.number)
      if number and not set[number] then
        set[number] = true
        ordered[#ordered + 1] = number
      end
    end
  end

  table.sort(ordered)
  return ordered
end

local function allowed_numbers_from_results(query_results)
  local allowed = {}
  for _, result in ipairs(type(query_results) == "table" and query_results or {}) do
    for _, pr in ipairs(type(result.prs) == "table" and result.prs or {}) do
      local number = tonumber(pr.number)
      if number then
        allowed[tostring(number)] = true
      end
    end
  end
  return allowed
end

local function filter_details_map(details_by_pr, allowed)
  local filtered = {}
  for number, details in pairs(type(details_by_pr) == "table" and details_by_pr or {}) do
    local key = tostring(number)
    if allowed[key] and type(details) == "table" then
      filtered[key] = details
    end
  end
  return filtered
end

local function reveal_context_in_state(state, session, context)
  if type(state) ~= "table" or type(session) ~= "table" or type(context) ~= "table" then
    return false
  end

  local session_repo = type(session.repository) == "table" and session.repository.full_name or nil
  if type(context.repo) == "string" and context.repo ~= "" and type(session_repo) == "string" and context.repo ~= session_repo then
    return false
  end

  local pr_number = tonumber(context.pr_number)
  local target_path = follow.normalize_path(context.path)
  if not pr_number or target_path == "" then
    return false
  end

  local node = follow.find_file_node(state, function(entry)
    if entry.pr_number ~= pr_number then
      return false
    end
    if entry.path == target_path then
      return true
    end
    return entry.previous_path ~= "" and entry.previous_path == target_path
  end)
  if not node then
    return false
  end

  local focused, node_id = follow.focus_node_without_steal(state, node)
  if focused then
    remember_revealed_node(session, node_id, {
      pr_number = pr_number,
      path = target_path,
    })
  end

  return focused
end

local function reveal_last_node_in_state(state, session)
  if type(state) ~= "table" or type(session) ~= "table" then
    return false
  end

  local follow_state = ensure_follow_state(session)
  if type(follow_state.last_node_id) == "string" and follow_state.last_node_id ~= "" then
    local focused = select(1, follow.focus_node_without_steal(state, follow_state.last_node_id))
    if focused then
      return true
    end
  end

  local fallback_context = {
    pr_number = tonumber(follow_state.last_pr),
    path = follow_state.last_path,
    repo = type(session.repository) == "table" and session.repository.full_name or nil,
  }

  if fallback_context.pr_number and type(fallback_context.path) == "string" and fallback_context.path ~= "" then
    return reveal_context_in_state(state, session, fallback_context)
  end

  return false
end

local function follow_current_file_if_visible(_)
  local states = follow.visible_source_states("gh_pr")
  if vim.tbl_isempty(states) then
    return false
  end

  local context = follow.resolve_buffer_context()
  for _, state in ipairs(states) do
    local repo_key = type(state) == "table" and state.gh_pr_repo_key or nil
    local session = type(repo_key) == "string" and runtime_cache.repos[repo_key] or nil
    if session then
      local revealed = false
      if context then
        revealed = reveal_context_in_state(state, session, context)
      end
      if not revealed then
        reveal_last_node_in_state(state, session)
      end
    end
  end

  return true
end

local start_background_refresh

local function finish_refresh(repo_context, payload)
  local session = ensure_repo_session(repo_context)
  session.inflight = false
  session.loading = false

  if payload.error then
    session.last_error = payload.error
    session.stale = session_is_stale(session)
    render_repo_states(repo_context.key)
    if session.pending_refresh then
      session.pending_refresh = false
      start_background_refresh(repo_context, { force = true })
    end
    return
  end

  session.last_error = nil
  session.query_results = sanitize_query_results(payload.query_results)

  local allowed = allowed_numbers_from_results(payload.query_results)
  session.details_by_pr = sanitize_details_map(filter_details_map(payload.details_by_pr, allowed))
  session.detail_errors = type(payload.detail_errors) == "table" and payload.detail_errors or {}
  session.updated_at = now_seconds()

  apply_runtime_cache(session)
  session.stale = session_is_stale(session)
  persist_session(repo_context, session)
  render_repo_states(repo_context.key)
  follow_current_file_if_visible({ reason = "refresh" })

  if cache_options().sync_visible_buffers ~= false then
    virtual_files.sync_visible_pr_buffers(session.details_by_pr, {
      repository = repo_context.repository.full_name,
    })
  end

  if session.pending_refresh then
    session.pending_refresh = false
    start_background_refresh(repo_context, { force = true })
  end
end

start_background_refresh = function(repo_context, opts)
  opts = opts or {}
  local session = ensure_repo_session(repo_context)

  if session.inflight then
    if opts.force then
      session.pending_refresh = true
    end
    return false
  end

  local ttl = tonumber(cache_options().ttl_seconds) or 60
  local age = now_seconds() - (tonumber(session.updated_at) or 0)
  if not opts.force and session.updated_at > 0 and age < ttl and not session_is_stale(session) then
    return false
  end

  session.inflight = true
  session.loading = true
  session.stale = session_is_stale(session)
  render_repo_states(repo_context.key)

  pr_service.list_queries_with_results_async(function(query_results, query_err)
    if not query_results then
      finish_refresh(repo_context, { error = query_err or "Unable to fetch pull requests" })
      return
    end

    local numbers = collect_pr_numbers(query_results)
    local details_by_pr = vim.deepcopy(session.details_by_pr)
    local detail_errors = {}
    local index = 1

    local function next_detail()
      local number = numbers[index]
      if not number then
        finish_refresh(repo_context, {
          query_results = query_results,
          details_by_pr = details_by_pr,
          detail_errors = detail_errors,
        })
        return
      end

      pr_service.fetch_details_async(number, function(details, details_err)
        local key = tostring(number)
        if details then
          details_by_pr[key] = details
          detail_errors[key] = nil
        else
          detail_errors[key] = details_err or "Unable to fetch PR details"
        end

        index = index + 1
        next_detail()
      end)
    end

    next_detail()
  end, {
    repository = repo_context.repository,
  })

  return true
end

local function show_message(state, id, message)
  renderer.show_nodes({
    {
      id = id,
      name = message,
      type = "message",
      extra = { kind = "message" },
    },
  }, state)
end

M.navigate = function(state, path)
  if not repo.ensure_git_repo() then
    show_message(state, "not-git", "Open a git repository to use gh-pr")
    return
  end

  local repo_context, context_err = resolve_repo_context()
  if not repo_context then
    show_message(state, "repo-error", "Unable to resolve repository: " .. tostring(context_err))
    return
  end

  state.path = path or vim.fn.getcwd()
  local session = ensure_repo_session(repo_context)
  register_state(session, state)
  apply_runtime_cache(session)
  session.stale = session_is_stale(session)

  start_background_refresh(repo_context, { force = false })
  render_state(state, session)
  follow_current_file_if_visible({ reason = "navigate" })
end

function M.request_refresh(state, opts)
  opts = opts or {}
  if not repo.in_git_repo() then
    return false
  end

  local repo_context, context_err = resolve_repo_context()
  if not repo_context then
    if opts.notify_error ~= false then
      vim.notify("Unable to resolve repository: " .. tostring(context_err), vim.log.levels.ERROR)
    end
    return false
  end

  local session = ensure_repo_session(repo_context)
  if state then
    register_state(session, state)
  end

  return start_background_refresh(repo_context, {
    force = opts.force == true,
  })
end

function M.render_cached_states()
  for repo_key, _ in pairs(runtime_cache.repos) do
    render_repo_states(repo_key)
  end
end

function M.refresh_if_focused()
  local options = cache_options()
  if options.auto_refresh_when_focused == false then
    return
  end

  local winid = vim.api.nvim_get_current_win()
  if not winid or not vim.api.nvim_win_is_valid(winid) then
    return
  end

  local bufnr = vim.api.nvim_win_get_buf(winid)
  local filetype = vim.api.nvim_get_option_value("filetype", { buf = bufnr })
  if filetype ~= "neo-tree" then
    return
  end

  if vim.b[bufnr].neo_tree_source ~= "gh_pr" then
    return
  end

  local state = nil
  local manager_ok, manager = pcall(require, "neo-tree.sources.manager")
  if manager_ok and type(manager.get_state_for_window) == "function" then
    local ok, resolved_state = pcall(manager.get_state_for_window, winid)
    if ok then
      state = resolved_state
    end
  end

  M.request_refresh(state, { force = false, notify_error = false })
  follow_current_file_if_visible({ reason = "focused" })
end

function M.follow_current_file_if_visible(opts)
  return follow_current_file_if_visible(opts)
end

M.setup = function(source_config, _)
  local commands = require("gh-pr.neotree.commands")
  local components = require("gh-pr.neotree.components")
  source_config.commands = vim.tbl_deep_extend("force", source_config.commands or {}, commands)
  source_config.components = source_config.components or components
  source_config.renderers = vim.tbl_deep_extend("force", source_config.renderers or {}, DEFAULT_RENDERERS)

  source_config.window = source_config.window or {}
  source_config.window.mappings = source_config.window.mappings or {}

  local default_mappings = {
    ["<space>"] = "toggle_node",
    ["<CR>"] = "gh_pr_open",
    ["R"] = "refresh",
    ["o"] = "open_overview",
    ["C"] = "open_comments_tree",
    ["D"] = "open_diff",
    ["O"] = "open_original",
    ["M"] = "open_modified",
    ["r"] = "approve_review",
    ["a"] = "comment_review",
    ["d"] = "request_changes_review",
    ["m"] = "merge_pr",
    ["S"] = "start_review",
    ["c"] = "checkout_pr",
    ["p"] = "toggle_viewed",
    ["v"] = "toggle_viewed",
    ["A"] = "noop",
    ["x"] = "noop",
    ["y"] = "noop",
    ["<C-r>"] = "noop",
    ["s"] = "noop",
    ["t"] = "noop",
    ["w"] = "noop",
    ["e"] = "toggle_auto_expand_width",
    ["q"] = "close_window",
    ["?"] = "show_help",
    ["<"] = "prev_source",
    [">"] = "next_source",
  }

  source_config.window.mappings = vim.tbl_deep_extend("force", source_config.window.mappings, default_mappings)
end

return M
