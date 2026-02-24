local M = {
  name = "gh_pr_comments",
  display_name = "GH Comments",
}

local actions = require("gh-pr.actions")
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
  pr_number = nil,
  details = nil,
  threads = nil,
}

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

local function load_threads(pr, options)
  if cache.pr_number == pr.number and type(cache.threads) == "table" then
    return cache.threads, nil
  end

  local threads, err = pr_service.fetch_review_threads(pr.number, {
    threads_first = 100,
    comments_first = 100,
  })
  if not threads then
    return nil, err
  end

  cache.pr_number = pr.number
  cache.threads = threads
  return threads, nil
end

local function file_node_id(pr_number, path)
  return string.format("ghpr-comments:%d:file:%s", pr_number, path)
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

local function build_nodes(pr, details, threads, options)
  local files = {}

  for _, thread in ipairs(type(threads) == "table" and threads or {}) do
    if keep_thread(thread, options) then
      local thread_path = type(thread.path) == "string" and thread.path or ""
      local thread_side = type(thread.diffSide) == "string" and thread.diffSide or ""
      local thread_head_line = first_positive_line(thread.line, thread.startLine)
      local thread_base_line = first_positive_line(thread.originalLine, thread.originalStartLine)

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
              is_resolved = thread.isResolved == true,
              is_outdated = thread.isOutdated == true,
            }

            local line_bucket = file_bucket.lines[line_key]
            line_bucket.comments[#line_bucket.comments + 1] = {
              id = comment.id,
              author = type(comment.author) == "table" and comment.author.login or "unknown",
              body = comment.body,
              created_at = comment.createdAt,
              url = comment.url,
              target = {
                pr = pr,
                details = details,
                path = path,
                side = side,
                line = head_line or line,
                original_line = base_line or line,
              },
              thread_flags = {
                is_resolved = thread.isResolved == true,
                is_outdated = thread.isOutdated == true,
              },
              fallback_index = index,
            }
          end
        end
      end
    end
  end

  local file_paths = vim.tbl_keys(files)
  table.sort(file_paths)
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
      children = {},
    },
  }

  local root = nodes[1]

  for _, path in ipairs(file_paths) do
    local line_buckets = {}
    for _, bucket in pairs(files[path].lines) do
      line_buckets[#line_buckets + 1] = bucket
    end
    table.sort(line_buckets, function(left, right)
      if left.line ~= right.line then
        return left.line < right.line
      end
      return left.side < right.side
    end)

    local file_node = {
      id = file_node_id(pr.number, path),
      name = path,
      type = "directory",
      path = path,
      extra = {
        kind = "file_group",
        pr = pr,
        details = details,
      },
      children = {},
    }

    for _, bucket in ipairs(line_buckets) do
      local status = bucket.is_resolved and "RESOLVED" or (bucket.is_outdated and "OUTDATED" or "OPEN")
      local line_node = {
        id = line_node_id(pr.number, path, bucket.side, bucket.line),
        name = string.format("L%d (%s) [%s] x%d", bucket.line, bucket.side, status, #bucket.comments),
        type = "directory",
        path = path,
        extra = {
          kind = "line",
          pr = pr,
          details = details,
          target = bucket.comments[1] and bucket.comments[1].target or nil,
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
        return normalize_comment_time(left_comment.created_at) < normalize_comment_time(right_comment.created_at)
      end)

      file_node.children[#file_node.children + 1] = line_node
    end

    root.children[#root.children + 1] = file_node
  end

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

  local options = (require("gh-pr.config").get() or {}).line_comments or {}
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

  local threads, threads_err = load_threads(pr, options)
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
  local options = (((require("gh-pr.config").get() or {}).line_comments or {}).comments_tree or {}).preview or {}
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
  cache.pr_number = nil
  cache.threads = nil
  cache.details = nil
end

return M
