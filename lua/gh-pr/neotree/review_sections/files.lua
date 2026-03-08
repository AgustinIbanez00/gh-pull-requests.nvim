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

local VALID_FILTER_STATUS = {
  all = true,
  added = true,
  modified = true,
  deleted = true,
  renamed = true,
  copied = true,
}

local function normalize_file_status(status)
  local normalized = type(status) == "string" and status:lower() or ""
  return FILE_STATUS_MAP[normalized] or "modified"
end

local function sanitize_file_filters(input)
  local filters = type(input) == "table" and input or {}
  local path_query = type(filters.path_query) == "string" and vim.trim(filters.path_query):lower() or ""
  local status = type(filters.status) == "string" and filters.status:lower() or "all"
  if not VALID_FILTER_STATUS[status] then
    status = "all"
  end

  local result = {
    path_query = path_query,
    status = status,
    extension = type(filters.extension) == "string" and vim.trim(filters.extension):lower():gsub("^%.+", "") or "",
    no_extension = filters.no_extension == true,
    dotfiles = filters.dotfiles == true,
    viewed_state = (type(filters.viewed_state) == "string" and filters.viewed_state:lower() or "all"),
    hide_deleted = filters.hide_deleted == true,
  }
  if result.viewed_state ~= "viewed" and result.viewed_state ~= "unviewed" then
    result.viewed_state = "all"
  end

  if type(filters.hide_viewed) == "boolean" then
    result.hide_viewed = filters.hide_viewed
  else
    result.hide_viewed = nil
  end

  return result
end

local function filters_active(filters, configured_hide_viewed)
  filters = sanitize_file_filters(filters)
  local effective_hide_viewed = type(filters.hide_viewed) == "boolean" and filters.hide_viewed or configured_hide_viewed
  return filters.path_query ~= ""
    or filters.status ~= "all"
    or filters.extension ~= ""
    or filters.no_extension == true
    or filters.dotfiles == true
    or filters.viewed_state ~= "all"
    or filters.hide_deleted == true
    or effective_hide_viewed ~= configured_hide_viewed
end

local function path_extension(path)
  local filename = type(path) == "string" and (path:match("[^/\\]+$") or path) or ""
  local extension = filename:match("%.([^.]+)$")
  return type(extension) == "string" and extension:lower() or ""
end

local function is_dotfile(path)
  local filename = type(path) == "string" and (path:match("[^/\\]+$") or path) or ""
  return filename:sub(1, 1) == "." and filename ~= "." and filename ~= ".."
end

local function file_matches_filters(path, status, viewed, filters, hide_viewed)
  if hide_viewed and viewed == true then
    return false
  end

  if filters.hide_deleted == true and status == "deleted" then
    return false
  end

  if filters.status ~= "all" and status ~= filters.status then
    return false
  end

  if filters.viewed_state == "viewed" and viewed ~= true then
    return false
  end
  if filters.viewed_state == "unviewed" and viewed == true then
    return false
  end

  local extension = path_extension(path)
  if filters.extension ~= "" and extension ~= filters.extension then
    return false
  end
  if filters.no_extension == true and extension ~= "" then
    return false
  end
  if filters.dotfiles == true and not is_dotfile(path) then
    return false
  end

  if filters.path_query ~= "" then
    local candidate = type(path) == "string" and path:gsub("\\", "/"):gsub("/+", "/"):gsub("^/", ""):gsub("/$", ""):lower() or ""
    if not candidate:find(filters.path_query, 1, true) then
      return false
    end
  end

  return true
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

local function build_file_comment_counts(raw_threads, pending_comments)
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

  for index, raw_comment in ipairs(type(pending_comments) == "table" and pending_comments or {}) do
    local normalized_path = normalize_tree_path(type(raw_comment) == "table"
        and (raw_comment.path or raw_comment.thread_path)
      or nil)
    if normalized_path ~= "" then
      seen_comment_ids_by_path[normalized_path] = seen_comment_ids_by_path[normalized_path] or {}
      local path_seen_ids = seen_comment_ids_by_path[normalized_path]
      local comment_id = type(raw_comment) == "table" and type(raw_comment.id) == "string" and raw_comment.id ~= ""
          and raw_comment.id
        or string.format("pending:%d:%s", index, normalized_path)
      if not path_seen_ids[comment_id] then
        path_seen_ids[comment_id] = true
        counts[normalized_path] = (tonumber(counts[normalized_path]) or 0) + 1
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

function M.build_nodes(pr, details, repo_full_name, opts)
  local render_options = config.get_path_render("gh_pr")
  local resolved_mode = effective_review_files_mode(render_options.mode)
  local configured_hide_viewed = (config.get() or {}).hide_viewed_files == true
  local filters = sanitize_file_filters(type(opts) == "table" and opts.filters or nil)
  local hide_viewed = type(filters.hide_viewed) == "boolean" and filters.hide_viewed or configured_hide_viewed
  local entries = {}
  local seen_paths = {}
  local directory_counts = {}
  local file_comment_counts = build_file_comment_counts(
    type(details) == "table" and details.review_threads or nil,
    type(details) == "table" and details.pending_review_comments or nil
  )
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
      local normalized_status = normalize_file_status(file.status)
      if file_matches_filters(normalized_path, normalized_status, viewed, filters, hide_viewed) then
        entries[#entries + 1] = {
          path = normalized_path,
          payload = file,
          metadata = {
            file_status = normalized_status,
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
    local empty_name = "No files"
    if total_files > 0 and filters_active(filters, configured_hide_viewed) then
      empty_name = "No files match current filters"
    end
    return {
      {
        id = string.format("ghpr-review:%d:files-empty", pr.number),
        name = empty_name,
        type = "message",
        extra = {
          kind = "message",
          pr = pr,
          details = details,
        },
      },
    }, viewed_files, total_files, {
      shown_files = 0,
      filters = filters,
      filters_active = filters_active(filters, configured_hide_viewed),
    }
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

  return nodes, viewed_files, total_files, {
    shown_files = #entries,
    filters = filters,
    filters_active = filters_active(filters, configured_hide_viewed),
  }
end

return M
