local M = {}

local REVIEWER_SUMMARY_ORDER = { "APPROVED", "REQUEST_CHANGES", "PENDING", "COMMENTED" }
local CHECK_SUMMARY_ORDER = { "FAIL", "PENDING", "PASS" }

local function summary_count_parts(counts, preferred_order)
  local parts = {}
  local seen = {}
  local values = type(counts) == "table" and counts or {}

  for _, state in ipairs(type(preferred_order) == "table" and preferred_order or {}) do
    seen[state] = true
    local count = tonumber(values[state]) or 0
    if count > 0 then
      parts[#parts + 1] = string.format("%d %s", count, state)
    end
  end

  local extra_states = {}
  for state, value in pairs(values) do
    local count = tonumber(value) or 0
    if state ~= "" and not seen[state] and count > 0 then
      extra_states[#extra_states + 1] = state
    end
  end
  table.sort(extra_states)

  for _, state in ipairs(extra_states) do
    parts[#parts + 1] = string.format("%d %s", tonumber(values[state]) or 0, state)
  end

  return parts
end

local function title_with_summary(base_title, parts)
  local base = type(base_title) == "string" and base_title or ""
  local clean_parts = {}
  for _, part in ipairs(type(parts) == "table" and parts or {}) do
    if type(part) == "string" and part ~= "" then
      clean_parts[#clean_parts + 1] = part
    end
  end

  if vim.tbl_isempty(clean_parts) then
    return base
  end

  return string.format("%s %s", base, table.concat(clean_parts, " "))
end

local function summary_total_part(count, label)
  local value = tonumber(count) or 0
  if value < 1 then
    return nil
  end

  local text = type(label) == "string" and label or ""
  if text == "" then
    return tostring(value)
  end

  return string.format("%d %s", value, text)
end

function M.count_commit_entries(nodes)
  local total = 0
  for _, node in ipairs(type(nodes) == "table" and nodes or {}) do
    local extra = type(node) == "table" and type(node.extra) == "table" and node.extra or nil
    if extra and extra.kind == "commit" then
      total = total + 1
    end
  end
  return total
end

local function files_filter_parts(meta)
  local parts = {}
  local metadata = type(meta) == "table" and meta or {}
  local filters = type(metadata.filters) == "table" and metadata.filters or {}
  local shown_files = tonumber(metadata.shown_files)
  local total_files = tonumber(metadata.total_files)

  if shown_files and total_files and shown_files >= 0 and total_files > 0 and shown_files < total_files then
    parts[#parts + 1] = string.format("%d/%d shown", shown_files, total_files)
  end

  if type(filters.path_query) == "string" and filters.path_query ~= "" then
    parts[#parts + 1] = "path:" .. filters.path_query
  end

  if type(filters.status) == "string" and filters.status ~= "" and filters.status ~= "all" then
    parts[#parts + 1] = "status:" .. filters.status
  end

  if type(filters.extension) == "string" and filters.extension ~= "" then
    parts[#parts + 1] = "ext:" .. filters.extension
  end

  if filters.no_extension == true then
    parts[#parts + 1] = "no-ext"
  end

  if filters.dotfiles == true then
    parts[#parts + 1] = "dotfiles"
  end

  if type(filters.viewed_state) == "string" and filters.viewed_state ~= "" and filters.viewed_state ~= "all" then
    parts[#parts + 1] = "view:" .. filters.viewed_state
  end

  if filters.hide_viewed == true then
    parts[#parts + 1] = "hide:viewed"
  end

  if filters.hide_deleted == true then
    parts[#parts + 1] = "hide:deleted"
  end

  return parts
end

function M.files_title(viewed_files, total_files, meta)
  local total = tonumber(total_files) or 0
  local viewed = tonumber(viewed_files) or 0
  local parts = files_filter_parts(vim.tbl_extend("force", {}, type(meta) == "table" and meta or {}, {
    total_files = total,
  }))
  if total > 0 then
    parts[#parts + 1] = string.format("%d/%d viewed", viewed, total)
    return string.format("Files %s", table.concat(parts, " · "))
  end
  return "Files"
end

function M.reviewers_title(reviewer_states)
  return title_with_summary("Reviewers", summary_count_parts(reviewer_states, REVIEWER_SUMMARY_ORDER))
end

function M.commits_title(commits_total)
  return title_with_summary("Commits", { summary_total_part(commits_total) })
end

function M.checks_title(check_states)
  return title_with_summary("Checks", summary_count_parts(check_states, CHECK_SUMMARY_ORDER))
end

function M.security_title(summary)
  local title = type(summary) == "string" and summary or ""
  return title ~= "" and title or "Security"
end

function M.build_root_nodes(pr, details, sections)
  local payload = type(sections) == "table" and sections or {}
  local labels = payload.labels or {}
  local files = type(payload.files) == "table" and payload.files or {}
  local reviewers = type(payload.reviewers) == "table" and payload.reviewers or {}
  local commits = type(payload.commits) == "table" and payload.commits or {}
  local checks = type(payload.checks) == "table" and payload.checks or {}
  local security = type(payload.security) == "table" and payload.security or {}
  local comments = type(payload.comments) == "table" and payload.comments or {}
  local drafts = type(payload.drafts) == "table" and payload.drafts or {}

  return {
    {
      id = string.format("ghpr-review:%d:root", pr.number),
      name = string.format("PR #%d - %s", pr.number, pr.title or ""),
      type = "folder",
      extra = {
        kind = "root",
        pr = pr,
        details = details,
      },
      children = {
        {
          id = string.format("ghpr-review:%d:overview", pr.number),
          name = "Overview",
          type = "overview",
          extra = {
            kind = "overview",
            pr = pr,
            details = details,
          },
        },
        {
          id = string.format("ghpr-review:%d:labels", pr.number),
          name = "Labels",
          type = "directory",
          extra = {
            kind = "labels",
            pr = pr,
            details = details,
          },
          children = labels,
        },
        {
          id = string.format("ghpr-review:%d:files", pr.number),
          name = type(files.title) == "string" and files.title or "Files",
          type = "files",
          extra = {
            kind = "files",
            pr = pr,
            details = details,
          },
          children = files.children or {},
        },
        {
          id = string.format("ghpr-review:%d:reviewers", pr.number),
          name = type(reviewers.title) == "string" and reviewers.title or "Reviewers",
          type = "directory",
          extra = {
            kind = "reviewers",
            pr = pr,
            details = details,
          },
          children = reviewers.children or {},
        },
        {
          id = string.format("ghpr-review:%d:commits", pr.number),
          name = type(commits.title) == "string" and commits.title or "Commits",
          type = "directory",
          extra = {
            kind = "commits",
            pr = pr,
            details = details,
          },
          children = commits.children or {},
        },
        {
          id = string.format("ghpr-review:%d:checks", pr.number),
          name = type(checks.title) == "string" and checks.title or "Checks",
          type = "directory",
          extra = {
            kind = "checks",
            pr = pr,
            details = details,
          },
          children = checks.children or {},
        },
        {
          id = string.format("ghpr-review:%d:security", pr.number),
          name = type(security.title) == "string" and security.title or "Security",
          type = "directory",
          extra = {
            kind = "security",
            pr = pr,
            details = details,
          },
          children = security.children or {},
        },
        {
          id = string.format("ghpr-review:%d:comments", pr.number),
          name = type(comments.title) == "string" and comments.title or "Comments",
          type = "directory",
          extra = {
            kind = "comments",
            pr = pr,
            details = details,
          },
          children = comments.children or {},
        },
        {
          id = string.format("ghpr-review:%d:drafts", pr.number),
          name = type(drafts.title) == "string" and drafts.title or "Drafts",
          type = "directory",
          extra = {
            kind = "drafts",
            pr = pr,
            details = details,
          },
          children = drafts.children or {},
        },
      },
    },
  }
end

return M
