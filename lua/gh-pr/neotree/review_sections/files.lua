local config = require("gh-pr.config")
local path_tree = require("gh-pr.path_tree")
local runtime_state = require("gh-pr.state")

local M = {}

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

function M.build_nodes(pr, details, repo_full_name)
  local render_options = config.get_path_render("gh_pr")
  local hide_viewed = (config.get() or {}).hide_viewed_files == true
  local entries = {}
  local seen_paths = {}
  local directory_counts = {}
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
    mode = render_options.mode,
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
      return {
        id = string.format("ghpr-review:%d:file:%s", pr.number, path),
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

  return nodes, viewed_files, total_files
end

return M
