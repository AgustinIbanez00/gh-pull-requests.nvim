local M = {
  name = "gh_pr_comments",
  display_name = "GH Comments",
}

local config = require("gh-pr.config")
local path_tree = require("gh-pr.path_tree")
local pr_service = require("gh-pr.pr_service")
local repo = require("gh-pr.repo")
local runtime_state = require("gh-pr.state")

local renderer = require("neo-tree.ui.renderer")

local DEFAULT_RENDERERS = {
  folder = {
    { "indent", with_expanders = true },
    { "kind_icon" },
    { "container", width = "100%", content = { { "name", zindex = 10 } } },
  },
  directory = {
    { "indent", with_expanders = true },
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

local cache = {
  key = nil,
  details = nil,
  threads = nil,
}

local function repository_name(details)
  local repository = type(details) == "table" and (details.baseRepository or details.headRepository) or nil
  if type(repository) ~= "table" then
    return ""
  end

  if type(repository.nameWithOwner) == "string" and repository.nameWithOwner ~= "" then
    return repository.nameWithOwner
  end

  local owner = type(repository.owner) == "table" and repository.owner.login or repository.owner
  local name = repository.name
  if type(owner) == "string" and owner ~= "" and type(name) == "string" and name ~= "" then
    return owner .. "/" .. name
  end

  return ""
end

local function cache_key(pr, details)
  local repo_name = repository_name(details)
  if repo_name == "" then
    return tostring(pr.number)
  end
  return string.format("%s:%s", repo_name, tostring(pr.number))
end

local function first_positive_line(...)
  for index = 1, select("#", ...) do
    local value = tonumber((select(index, ...)))
    if value and value > 0 then
      return math.floor(value)
    end
  end
  return nil
end

local function normalize_side(diff_side, head_line, base_line)
  local side = type(diff_side) == "string" and diff_side:upper() or ""
  if side == "LEFT" then
    return "base"
  end
  if side == "RIGHT" then
    return "head"
  end
  if head_line then
    return "head"
  end
  if base_line then
    return "base"
  end
  return "head"
end

local function body_preview(body)
  if type(body) ~= "string" or body == "" then
    return "(empty comment)"
  end

  local line = vim.split(body, "\n", { plain = true })[1] or ""
  line = vim.trim(line)
  if line == "" then
    return "(empty comment)"
  end

  if #line > 90 then
    return line:sub(1, 87) .. "..."
  end

  return line
end

local function keep_thread(thread, options)
  if type(thread) ~= "table" then
    return false
  end

  if thread.isResolved == true and options.show_resolved == false then
    return false
  end
  if thread.isOutdated == true and options.show_outdated == false then
    return false
  end

  return true
end

local function active_pr_context()
  local pr, details = runtime_state.get_active_pr()
  if pr and details then
    return pr, details, nil
  end

  local buffer_number = vim.b.gh_pr_number
  if type(buffer_number) == "number" then
    local fetched, err = pr_service.fetch_details(buffer_number)
    if not fetched then
      return nil, nil, err
    end
    runtime_state.set_active_pr(fetched, fetched)
    return fetched, fetched, nil
  end

  return nil, nil, "No active pull request. Open a PR file/overview first or run :GhPrComments <number>."
end

local function load_threads(pr, details, options)
  options = type(options) == "table" and options or {}
  local key = cache_key(pr, details)

  if type(options.threads) == "table" then
    cache.key = key
    cache.threads = options.threads
    return options.threads, nil
  end

  if key ~= "" and cache.key == key and type(cache.threads) == "table" then
    return cache.threads, nil
  end

  if options.allow_fetch == false then
    return {}, nil
  end

  local threads, err = pr_service.fetch_review_threads(pr.number, {
    threads_first = 100,
    comments_first = 100,
  })
  if not threads then
    return nil, err
  end

  cache.key = cache_key(pr, details)
  cache.threads = threads
  return threads, nil
end

local function file_node_id(pr_number, path)
  return string.format("ghpr-comments:%d:file:%s", pr_number, path)
end

local function directory_node_id(pr_number, path)
  return string.format("ghpr-comments:%d:dir:%s", pr_number, path)
end

local function line_node_id(pr_number, path, side, line)
  return string.format("ghpr-comments:%d:line:%s:%s:%d", pr_number, path, side, line)
end

local function comment_node_id(pr_number, comment_id, fallback_index)
  local id = type(comment_id) == "string" and comment_id ~= "" and comment_id or tostring(fallback_index)
  return string.format("ghpr-comments:%d:comment:%s", pr_number, id)
end

local function normalize_comment_time(created_at)
  if type(created_at) ~= "string" or created_at == "" then
    return "-"
  end
  return created_at:gsub("T", " "):gsub("Z", "")
end

local function sort_comments_by_time(comments)
  table.sort(comments, function(left, right)
    local left_key = normalize_comment_time(left.created_at) .. ":" .. (left.id or "")
    local right_key = normalize_comment_time(right.created_at) .. ":" .. (right.id or "")
    return left_key < right_key
  end)
end

local function sorted_line_buckets(line_map)
  local line_buckets = {}
  for _, bucket in pairs(line_map or {}) do
    line_buckets[#line_buckets + 1] = bucket
  end

  table.sort(line_buckets, function(left, right)
    if left.line ~= right.line then
      return left.line < right.line
    end
    return left.side < right.side
  end)

  return line_buckets
end

local function normalize_thread_comment(comment, fallback_index)
  local author = "unknown"
  if type(comment.author) == "table" and type(comment.author.login) == "string" and comment.author.login ~= "" then
    author = comment.author.login
  elseif type(comment.author) == "string" and comment.author ~= "" then
    author = comment.author
  end

  return {
    id = type(comment.id) == "string" and comment.id ~= "" and comment.id or tostring(fallback_index),
    author = author,
    body = type(comment.body) == "string" and comment.body or "",
    created_at = type(comment.createdAt) == "string" and comment.createdAt or (type(comment.created_at) == "string" and comment.created_at or ""),
    url = type(comment.url) == "string" and comment.url or "",
    state = type(comment.state) == "string" and comment.state or "",
    outdated = comment.outdated == true,
  }
end

local function normalize_thread_comments(thread)
  local items = {}
  for index, comment in ipairs(type(thread.comments) == "table" and thread.comments or {}) do
    items[#items + 1] = normalize_thread_comment(comment, index)
  end
  sort_comments_by_time(items)
  return items
end

local function normalize_line_bucket_comments(comments)
  local items = {}
  for index, comment in ipairs(type(comments) == "table" and comments or {}) do
    items[#items + 1] = {
      id = type(comment.id) == "string" and comment.id ~= "" and comment.id or tostring(index),
      author = type(comment.author) == "string" and comment.author ~= "" and comment.author or "unknown",
      body = type(comment.body) == "string" and comment.body or "",
      created_at = type(comment.created_at) == "string" and comment.created_at or "",
      url = type(comment.url) == "string" and comment.url or "",
      state = type(comment.state) == "string" and comment.state or "",
      outdated = comment.outdated == true,
    }
  end
  sort_comments_by_time(items)
  return items
end

local function line_bucket_target(pr, details, path, bucket, first_target)
  local line_comments = normalize_line_bucket_comments(bucket.comments)
  local line_value = tonumber((first_target and first_target.line) or bucket.line) or bucket.line
  local original_line_value = tonumber((first_target and first_target.original_line) or bucket.line) or bucket.line

  return {
    pr = pr,
    details = details,
    path = path,
    side = bucket.side,
    line = line_value,
    original_line = original_line_value,
    thread_id = string.format("line:%s:%s:%d", path, bucket.side, bucket.line),
    thread_comments = line_comments,
    selected_comment_id = line_comments[1] and line_comments[1].id or nil,
    thread_is_resolved = bucket.has_open ~= true and bucket.has_outdated ~= true,
    thread_is_outdated = bucket.has_open ~= true and bucket.has_outdated == true,
    line_comments = line_comments,
  }
end

local function build_line_nodes(pr, details, path, file_bucket)
  local nodes = {}
  local line_buckets = sorted_line_buckets(file_bucket and file_bucket.lines or {})

  for _, bucket in ipairs(line_buckets) do
    local status = bucket.has_open and "OPEN" or (bucket.has_outdated and "OUTDATED" or "RESOLVED")
    local first_target = bucket.comments[1] and bucket.comments[1].target or nil
    local line_node = {
      id = line_node_id(pr.number, path, bucket.side, bucket.line),
      name = string.format("L%d (%s) [%s] x%d", bucket.line, bucket.side, status, #bucket.comments),
      type = "directory",
      path = path,
      extra = {
        kind = "line",
        pr = pr,
        details = details,
        target = line_bucket_target(pr, details, path, bucket, first_target),
      },
      children = {},
    }

    for index, comment in ipairs(bucket.comments) do
      line_node.children[#line_node.children + 1] = {
        id = comment_node_id(pr.number, comment.id, index),
        name = string.format("@%s: %s", comment.author or "unknown", body_preview(comment.body)),
        type = "file",
        path = path,
        extra = {
          kind = "comment",
          pr = pr,
          details = details,
          target = comment.target,
          comment = comment,
        },
      }
    end

    table.sort(line_node.children, function(left, right)
      local left_comment = left.extra and left.extra.comment or {}
      local right_comment = right.extra and right.extra.comment or {}
      local left_key = normalize_comment_time(left_comment.created_at) .. ":" .. (left_comment.id or "")
      local right_key = normalize_comment_time(right_comment.created_at) .. ":" .. (right_comment.id or "")
      return left_key < right_key
    end)

    nodes[#nodes + 1] = line_node
  end

  return nodes
end

local function file_group_name(path, mode)
  if mode == "flat" then
    return path
  end
  return path:match("[^/\\]+$") or path
end

local function build_nodes(pr, details, threads, options)
  local files = {}

  for _, thread in ipairs(type(threads) == "table" and threads or {}) do
    if keep_thread(thread, options) then
      local thread_path = type(thread.path) == "string" and thread.path or ""
      local thread_side = type(thread.diffSide) == "string" and thread.diffSide or ""
      local thread_head_line = first_positive_line(thread.line, thread.startLine)
      local thread_base_line = first_positive_line(thread.originalLine, thread.originalStartLine)
      local thread_comments = normalize_thread_comments(thread)
      local thread_is_resolved = thread.isResolved == true
      local thread_is_outdated = thread.isOutdated == true

      for index, comment in ipairs(type(thread.comments) == "table" and thread.comments or {}) do
        local path = type(comment.path) == "string" and comment.path or thread_path
        if path ~= "" then
          local head_line = first_positive_line(comment.line, thread_head_line)
          local base_line = first_positive_line(comment.originalLine, thread_base_line)
          local side = normalize_side(thread_side, head_line, base_line)
          local line = side == "base" and (base_line or head_line) or (head_line or base_line)
          if line then
            files[path] = files[path] or { lines = {} }
            local file_bucket = files[path]
            local line_key = string.format("%s:%d", side, line)
            file_bucket.lines[line_key] = file_bucket.lines[line_key] or {
              side = side,
              line = line,
              comments = {},
              comment_keys = {},
              has_open = false,
              has_outdated = false,
            }

            local line_bucket = file_bucket.lines[line_key]
            if not thread_is_resolved and not thread_is_outdated then
              line_bucket.has_open = true
            end
            if thread_is_outdated then
              line_bucket.has_outdated = true
            end
            local dedupe_key = type(comment.id) == "string" and comment.id ~= ""
                and ("id:" .. comment.id)
              or table.concat({
                type(thread.id) == "string" and thread.id or "",
                type(comment.createdAt) == "string" and comment.createdAt or "",
                tostring(index),
                path,
                tostring(line),
              }, ":")

            if not line_bucket.comment_keys[dedupe_key] then
              line_bucket.comment_keys[dedupe_key] = true
              line_bucket.comments[#line_bucket.comments + 1] = {
              id = comment.id,
              author = type(comment.author) == "table" and comment.author.login or "unknown",
              body = comment.body,
              created_at = comment.createdAt,
              url = comment.url,
              state = comment.state,
              outdated = comment.outdated == true,
              thread_id = thread.id,
              target = {
                pr = pr,
                details = details,
                path = path,
                side = side,
                line = head_line or line,
                original_line = base_line or line,
                thread_id = thread.id,
                thread_comments = thread_comments,
                selected_comment_id = comment.id,
                thread_is_resolved = thread_is_resolved,
                thread_is_outdated = thread_is_outdated,
              },
              thread_flags = {
                is_resolved = thread_is_resolved,
                is_outdated = thread_is_outdated,
              },
              fallback_index = index,
            }
            end
          end
        end
      end
    end
  end

  local file_paths = vim.tbl_keys(files)
  if vim.tbl_isempty(file_paths) then
    return {
      {
        id = string.format("ghpr-comments:%d:empty", pr.number),
        name = "No comments found for current PR",
        type = "message",
        extra = {
          kind = "message",
          pr = pr,
          details = details,
        },
      },
    }
  end

  local render_options = config.get_path_render("gh_pr_comments")
  local entries = {}
  for _, path in ipairs(file_paths) do
    entries[#entries + 1] = {
      path = path,
      payload = {
        file_bucket = files[path],
      },
    }
  end

  local nodes = {
    {
      id = string.format("ghpr-comments:%d:root", pr.number),
      name = string.format("PR #%d - %s", pr.number, pr.title or ""),
      type = "folder",
      extra = {
        kind = "root",
        pr = pr,
        details = details,
      },
      children = path_tree.build_nodes(entries, {
        mode = render_options.mode,
        separator = render_options.separator,
        create_directory_node = function(display_name, full_path)
          return {
            id = directory_node_id(pr.number, full_path),
            name = display_name,
            type = "directory",
            path = full_path,
            extra = {
              kind = "directory",
              pr = pr,
              details = details,
            },
            children = {},
          }
        end,
        create_file_node = function(file_item, context)
          local path = file_item.path
          local file_bucket = file_item.payload.file_bucket
          return {
            id = file_node_id(pr.number, path),
            name = file_group_name(path, context and context.mode or render_options.mode),
            type = "directory",
            path = path,
            extra = {
              kind = "file_group",
              pr = pr,
              details = details,
            },
            children = build_line_nodes(pr, details, path, file_bucket),
          }
        end,
      }),
    },
  }

  return nodes
end

M.navigate = function(state, path)
  if not repo.ensure_git_repo() then
    renderer.show_nodes({
      {
        id = "ghpr-comments:not-git",
        name = "Open a git repository to use gh-pr comments",
        type = "message",
        extra = { kind = "message" },
      },
    }, state)
    return
  end

  local options = (config.get() or {}).line_comments or {}
  local pr, details, context_err = active_pr_context()
  if not pr or not details then
    renderer.show_nodes({
      {
        id = "ghpr-comments:no-context",
        name = context_err or "No active pull request",
        type = "message",
        extra = { kind = "message" },
      },
    }, state)
    return
  end

  local threads, threads_err = load_threads(pr, details, options)
  if not threads then
    renderer.show_nodes({
      {
        id = "ghpr-comments:error",
        name = "Unable to load PR comments: " .. tostring(threads_err),
        type = "message",
        extra = {
          kind = "message",
          pr = pr,
          details = details,
        },
      },
    }, state)
    return
  end

  state.path = path or vim.fn.getcwd()
  cache.details = details
  renderer.show_nodes(build_nodes(pr, details, threads, options), state)
end

M.setup = function(source_config, _)
  local commands = require("gh-pr.neotree.comments_commands")
  local components = require("gh-pr.neotree.components")
  local options = (((config.get() or {}).line_comments or {}).comments_tree or {}).preview or {}
  local preview_keymap = type(options.keymap) == "string" and options.keymap ~= "" and options.keymap or "p"
  source_config.commands = vim.tbl_deep_extend("force", source_config.commands or {}, commands)
  source_config.components = source_config.components or components
  source_config.renderers = vim.tbl_deep_extend("force", source_config.renderers or {}, DEFAULT_RENDERERS)

  source_config.window = source_config.window or {}
  source_config.window.mappings = source_config.window.mappings or {}

  local default_mappings = {
    ["<space>"] = "toggle_node",
    ["<CR>"] = "gh_pr_comments_open",
    ["o"] = "open_comment",
    [preview_keymap] = "preview_comment",
    ["R"] = "refresh",
    ["q"] = "close_window",
    ["?"] = "show_help",
    ["<"] = "prev_source",
    [">"] = "next_source",
    ["A"] = "noop",
    ["x"] = "noop",
    ["y"] = "noop",
    ["<C-r>"] = "noop",
    ["S"] = "noop",
    ["s"] = "noop",
    ["t"] = "noop",
    ["w"] = "noop",
    ["e"] = "noop",
  }

  source_config.window.mappings = vim.tbl_deep_extend("force", source_config.window.mappings, default_mappings)
end

M.invalidate_cache = function()
  cache.key = nil
  cache.threads = nil
  cache.details = nil
end

function M.build_section_nodes(pr, details, opts)
  opts = opts or {}
  local options = (config.get() or {}).line_comments or {}
  cache.details = details
  local threads, threads_err = load_threads(pr, details, options)
  if not threads then
    return nil, threads_err
  end

  local nodes = build_nodes(pr, details, threads, options)
  if opts.with_root == true then
    return nodes, nil
  end

  local root = nodes[1]
  if type(root) ~= "table" or type(root.children) ~= "table" then
    return {}, nil
  end

  return vim.deepcopy(root.children), nil
end

require("gh-pr.neotree.registry").register("gh_pr_comments", M)

return M
