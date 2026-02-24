local M = {
  name = "gh_pr",
  display_name = "GH PR",
}

local config = require("gh-pr.config")
local pr_service = require("gh-pr.pr_service")
local repo = require("gh-pr.repo")
local runtime_state = require("gh-pr.state")

local renderer = require("neo-tree.ui.renderer")
local manager = require("neo-tree.sources.manager")

local cache = {
  details_by_pr = {},
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

local function add_file_node(list, id_prefix, path, file, pr, details)
  local repo_full_name = repository_full_name(details)
  if config.get().hide_viewed_files and runtime_state.is_viewed(repo_full_name, pr.number, path) then
    return
  end

  table.insert(list, {
    id = string.format("%s:file:%s", id_prefix, path),
    name = string.format("[%s] %s", status_prefix(file.status), (path:match("[^/\\]+$") or path)),
    type = "file",
    path = path,
    extra = {
      kind = "file",
      file = file,
      pr = pr,
      details = details,
      repo = repo_full_name,
    },
  })
end

local function build_flat_file_nodes(id_prefix, pr, details)
  local nodes = {}

  for _, file in ipairs(details.files or {}) do
    local path = file.path or file.filename
    if path and path ~= "" then
      add_file_node(nodes, id_prefix, path, file, pr, details)
    end
  end

  table.sort(nodes, function(a, b)
    return a.path < b.path
  end)

  return nodes
end

local function ensure_directory(parent, id_prefix, prefix, name, pr, details)
  parent._dir_index = parent._dir_index or {}

  if parent._dir_index[name] then
    return parent._dir_index[name]
  end

  local directory = {
    id = string.format("%s:dir:%s%s", id_prefix, prefix, name),
    name = name,
    type = "directory",
    children = {},
    extra = {
      kind = "directory",
      pr = pr,
      details = details,
    },
  }

  table.insert(parent.children, directory)
  parent._dir_index[name] = directory
  return directory
end

local function finalize_directories(node)
  node._dir_index = nil
  for _, child in ipairs(node.children or {}) do
    if child.type == "directory" then
      finalize_directories(child)
    end
  end

  table.sort(node.children, function(left, right)
    if left.type ~= right.type then
      return left.type == "directory"
    end
    return left.name < right.name
  end)
end

local function build_tree_file_nodes(id_prefix, pr, details)
  local root = {
    id = string.format("%s:files-root", id_prefix),
    name = "files-root",
    type = "directory",
    children = {},
  }

  for _, file in ipairs(details.files or {}) do
    local path = file.path or file.filename
    if path and path ~= "" then
      local repo_full_name = repository_full_name(details)
      if not (config.get().hide_viewed_files and runtime_state.is_viewed(repo_full_name, pr.number, path)) then
        local parts = vim.split(path, "/", { plain = true })
        local current = root
        local prefix = ""

        for index, part in ipairs(parts) do
          if index == #parts then
            local node = {
              id = string.format("%s:file:%s", id_prefix, path),
              name = string.format("[%s] %s", status_prefix(file.status), part),
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
            table.insert(current.children, node)
          else
            current = ensure_directory(current, id_prefix, prefix, part, pr, details)
            prefix = prefix .. part .. "/"
          end
        end
      end
    end
  end

  finalize_directories(root)
  return root.children
end

local function build_file_nodes(id_prefix, pr, details)
  if config.get().file_list_layout == "flat" then
    return build_flat_file_nodes(id_prefix, pr, details)
  end

  return build_tree_file_nodes(id_prefix, pr, details)
end

local function get_details(pr)
  local key = tostring(pr.number)
  if cache.details_by_pr[key] then
    return cache.details_by_pr[key], nil
  end

  local details, err = pr_service.fetch_details(pr.number)
  if not details then
    return nil, err
  end

  cache.details_by_pr[key] = details
  return details, nil
end

local function get_query_node(query, results)
  local query_prefix = string.format("query:%s", query.id or query.label)
  local children = {}

  if results.error then
    table.insert(children, {
      id = "query-error:" .. query.id,
      name = "Error: " .. results.error,
      type = "message",
      extra = { kind = "message" },
    })
  elseif vim.tbl_isempty(results.prs) then
    table.insert(children, {
      id = "query-empty:" .. query.id,
      name = "No pull requests",
      type = "message",
      extra = { kind = "message" },
    })
  else
    for _, pr in ipairs(results.prs) do
      local pr_prefix = string.format("%s:pr:%d", query_prefix, pr.number)
      local details, err = get_details(pr)
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
        table.insert(pr_children, {
          id = string.format("%s:error", pr_prefix),
          name = "Unable to load files: " .. (err or "unknown error"),
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
    end
  end

  return {
    id = "query:" .. query.id,
    name = string.format("%s (%d)", query.label, #(results.prs or {})),
    type = "query",
    children = children,
    extra = {
      kind = "query",
      query = query,
    },
  }
end

local function build_nodes()
  local query_results = pr_service.list_queries_with_results()
  local folder_map = {}

  for _, result in ipairs(query_results) do
    local folder_name = result.query.folder or "General"
    folder_map[folder_name] = folder_map[folder_name] or {}
    table.insert(folder_map[folder_name], result)
  end

  local folders = vim.tbl_keys(folder_map)
  table.sort(folders)

  local nodes = {}
  for _, folder_name in ipairs(folders) do
    local query_nodes = {}
    for _, result in ipairs(folder_map[folder_name]) do
      table.insert(query_nodes, get_query_node(result.query, result))
    end

    table.sort(query_nodes, function(left, right)
      return left.name < right.name
    end)

    table.insert(nodes, {
      id = "folder:" .. folder_name,
      name = folder_name,
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

local function apply_runtime_cache()
  local active_pr, active_details = runtime_state.get_active_pr()
  if active_pr and active_details then
    cache.details_by_pr[tostring(active_pr.number)] = active_details
  end
end

M.navigate = function(state, path)
  if not repo.ensure_git_repo() then
    renderer.show_nodes({
      {
        id = "not-git",
        name = "Open a git repository to use gh-pr",
        type = "message",
        extra = { kind = "message" },
      },
    }, state)
    return
  end

  state.path = path or vim.fn.getcwd()
  apply_runtime_cache()
  renderer.show_nodes(build_nodes(), state)
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
    ["c"] = "checkout_pr",
    ["p"] = "toggle_viewed",
    ["v"] = "toggle_viewed",
    ["A"] = "noop",
    ["x"] = "noop",
    ["y"] = "noop",
    ["<C-r>"] = "noop",
    ["S"] = "noop",
    ["s"] = "noop",
    ["t"] = "noop",
    ["w"] = "noop",
    ["e"] = "noop",
    ["q"] = "close_window",
    ["?"] = "show_help",
    ["<"] = "prev_source",
    [">"] = "next_source",
  }

  source_config.window.mappings = vim.tbl_deep_extend("force", source_config.window.mappings, default_mappings)
end

return M
