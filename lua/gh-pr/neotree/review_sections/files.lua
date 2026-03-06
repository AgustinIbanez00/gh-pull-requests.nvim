local config = require("gh-pr.config")
local path_tree = require("gh-pr.path_tree")
local runtime_state = require("gh-pr.state")

local M = {}

local FILE_STATUS_MAP = {
  added = "added",
  modified = "modified",
  removed = "deleted",
  deleted = "deleted",
  renamed = "renamed",
  copied = "copied",
}

local function normalize_file_status(status)
  local normalized = type(status) == "string" and status:lower() or ""
  return FILE_STATUS_MAP[normalized] or "modified"
end

local function file_display_name(path)
  return path:match("[^/\\]+$") or path
end

local function parent_path_of_file(path)
  if type(path) ~= "string" then
    return ""
  end

  local normalized = path:gsub("\\", "/"):gsub("/+", "/")
  normalized = normalized:gsub("^/", ""):gsub("/$", "")
  if normalized == "" then
    return ""
  end

  local parent = normalized:match("^(.*)/[^/]+$")
  return type(parent) == "string" and parent or ""
end

local function normalize_tree_path(path)
  if type(path) ~= "string" then
    return ""
  end

  local normalized = path:gsub("\\", "/"):gsub("/+", "/")
  normalized = normalized:gsub("^/", ""):gsub("/$", "")
  return normalized
end

local function directory_path_of_file(path)
  local normalized = normalize_tree_path(path)
  if normalized == "" then
    return ""
  end

  local directory = normalized:match("^(.*)/[^/]+$")
  return type(directory) == "string" and directory or ""
end

local function add_directory_count(counts, directory_path, viewed)
  if type(counts) ~= "table" or type(directory_path) ~= "string" or directory_path == "" then
    return
  end

  local current = ""
  for segment in directory_path:gmatch("[^/]+") do
    current = current == "" and segment or (current .. "/" .. segment)
    local bucket = counts[current]
    if type(bucket) ~= "table" then
      bucket = { viewed = 0, total = 0 }
      counts[current] = bucket
    end
    bucket.total = (tonumber(bucket.total) or 0) + 1
    if viewed then
      bucket.viewed = (tonumber(bucket.viewed) or 0) + 1
    end
  end
end

local function resolve_thread_path(raw_thread)
  if type(raw_thread) ~= "table" then
    return ""
  end

  local path = type(raw_thread.path) == "string" and raw_thread.path or ""
  if path ~= "" then
    return path
  end

  for _, raw_comment in ipairs(type(raw_thread.comments) == "table" and raw_thread.comments or {}) do
    local comment_path = type(raw_comment.path) == "string" and raw_comment.path or ""
    if comment_path ~= "" then
      return comment_path
    end
  end

  return ""
end

local function resolve_comment_path(raw_comment, fallback_path)
  if type(raw_comment) ~= "table" then
    return type(fallback_path) == "string" and fallback_path or ""
  end

  local comment_path = type(raw_comment.path) == "string" and raw_comment.path or ""
  if comment_path ~= "" then
    return comment_path
  end

  return type(fallback_path) == "string" and fallback_path or ""
end

local function build_file_comment_counts(raw_threads)
  local counts = {}
  local seen_comment_ids_by_path = {}

  for thread_index, raw_thread in ipairs(type(raw_threads) == "table" and raw_threads or {}) do
    local normalized_thread_path = normalize_tree_path(resolve_thread_path(raw_thread))
    local comments = type(raw_thread) == "table" and type(raw_thread.comments) == "table" and raw_thread.comments or {}
    for comment_index, raw_comment in ipairs(comments) do
      local normalized_path = normalize_tree_path(resolve_comment_path(raw_comment, normalized_thread_path))
      if normalized_path ~= "" then
        seen_comment_ids_by_path[normalized_path] = seen_comment_ids_by_path[normalized_path] or {}
        local path_seen_ids = seen_comment_ids_by_path[normalized_path]
        local comment_id = type(raw_comment) == "table" and type(raw_comment.id) == "string" and raw_comment.id ~= ""
            and raw_comment.id
          or string.format("thread:%d:comment:%d:%s", thread_index, comment_index, normalized_path)
        if not path_seen_ids[comment_id] then
          path_seen_ids[comment_id] = true
          counts[normalized_path] = (tonumber(counts[normalized_path]) or 0) + 1
        end
      end
    end
  end

  return counts
end

local function configured_review_files_flat_mode()
  local options = config.get() or {}
  local pr_review = type(options.pr_review) == "table" and options.pr_review or {}
  local files = type(pr_review.files) == "table" and pr_review.files or {}
  return files.flat == true
end

local function effective_review_files_mode(default_mode)
  local persisted = type(runtime_state.get_pr_review_files_flat_pref) == "function"
      and runtime_state.get_pr_review_files_flat_pref()
    or nil
  local use_flat = type(persisted) == "boolean" and persisted or configured_review_files_flat_mode()
  if use_flat then
    return "flat"
  end
  return default_mode
end

function M.build_nodes(pr, details, repo_full_name)
  local render_options = config.get_path_render("gh_pr")
  local resolved_mode = effective_review_files_mode(render_options.mode)
  local hide_viewed = (config.get() or {}).hide_viewed_files == true
  local entries = {}
  local seen_paths = {}
  local directory_counts = {}
  local file_comment_counts = build_file_comment_counts(type(details) == "table" and details.review_threads or nil)
  local total_files = 0
  local viewed_files = 0

  for _, file in ipairs(type(details.files) == "table" and details.files or {}) do
    local path = file.path or file.filename
    if type(path) == "string" and path ~= "" then
      local normalized_path = normalize_tree_path(path)
      if normalized_path == "" or seen_paths[normalized_path] then
        goto continue
      end
      seen_paths[path] = true
      seen_paths[normalized_path] = true
      local viewed = runtime_state.is_viewed(repo_full_name, pr.number, normalized_path)
      add_directory_count(directory_counts, directory_path_of_file(normalized_path), viewed)
      total_files = total_files + 1
      if viewed then
        viewed_files = viewed_files + 1
      end
      if not (hide_viewed and viewed) then
        entries[#entries + 1] = {
          path = normalized_path,
          payload = file,
          metadata = {
            file_status = normalize_file_status(file.status),
            is_viewed = viewed == true,
            file_comment_count = tonumber(file_comment_counts[normalized_path]) or 0,
            open_thread_count = tonumber(file_comment_counts[normalized_path]) or 0,
          },
        }
      end
    end
    ::continue::
  end

  if vim.tbl_isempty(entries) then
    return {
      {
        id = string.format("ghpr-review:%d:files-empty", pr.number),
        name = "No files",
        type = "message",
        extra = {
          kind = "message",
          pr = pr,
          details = details,
        },
      },
    }, viewed_files, total_files
  end

  local nodes = path_tree.build_nodes(entries, {
    mode = resolved_mode,
    separator = render_options.separator,
    create_directory_node = function(display_name, full_path)
      local normalized_full_path = normalize_tree_path(full_path)
      local counts = directory_counts[normalized_full_path]
      local viewed = type(counts) == "table" and tonumber(counts.viewed) or nil
      local total = type(counts) == "table" and tonumber(counts.total) or nil
      return {
        id = string.format("ghpr-review:%d:file-dir:%s", pr.number, full_path),
        name = display_name,
        type = "directory",
        children = {},
        extra = {
          kind = "directory",
          path = normalized_full_path,
          pr = pr,
          details = details,
          repo = repo_full_name,
          viewed_counts = (viewed and total) and { viewed = viewed, total = total } or nil,
          show_viewed_prefix = viewed ~= nil and total ~= nil and total > 0 and viewed > 0,
        },
      }
    end,
    create_file_node = function(file_item)
      local path = file_item.path
      local file = file_item.payload
      local metadata = type(file_item.metadata) == "table" and file_item.metadata or {}
      return {
        id = string.format("ghpr-review:%d:file:%s", pr.number, path),
        name = file_display_name(path),
        type = "file",
        path = path,
        extra = {
          kind = "file",
          file = file,
          pr = pr,
          details = details,
          repo = repo_full_name,
          path_render_mode = resolved_mode,
          parent_path = parent_path_of_file(path),
          file_status = type(metadata.file_status) == "string" and metadata.file_status or "modified",
          is_viewed = metadata.is_viewed == true,
          file_comment_count = tonumber(metadata.file_comment_count) or 0,
          open_thread_count = tonumber(metadata.open_thread_count) or 0,
        },
      }
    end,
  })

  return nodes, viewed_files, total_files
end

return M
