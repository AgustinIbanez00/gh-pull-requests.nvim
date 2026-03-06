local M = {}

local config = require("gh-pr.config")
local codediff = require("gh-pr.integrations.codediff")

local sessions = {}
local active_reviews = {}

local function safe_string(value)
  return type(value) == "string" and value or ""
end

local function debug_enabled()
  local plugin_config = type(config.get()) == "table" and config.get() or {}
  local diff_view = type(plugin_config.diff_view) == "table" and plugin_config.diff_view or {}
  local debug = type(diff_view.debug) == "table" and diff_view.debug or {}
  return debug.codediff_failures == true
end

local function notify_debug(message, level)
  if not debug_enabled() then
    return
  end

  local text = safe_string(message)
  if text == "" then
    return
  end

  vim.notify("[gh-pr debug] " .. vim.trim(text), level or vim.log.levels.INFO)
end

local function normalize_path(path)
  if type(path) ~= "string" then
    return ""
  end

  return path:gsub("\\", "/"):gsub("/+", "/"):gsub("^/", ""):gsub("/$", "")
end

local function sha256(value)
  local ok, digest = pcall(vim.fn.sha256, tostring(value))
  if ok and type(digest) == "string" and digest ~= "" then
    return digest
  end
  return tostring(value)
end

local function extract_repository(repo)
  repo = type(repo) == "table" and repo or {}
  local full_name = safe_string(repo.nameWithOwner)
  if full_name ~= "" then
    return full_name
  end

  local owner = type(repo.owner) == "table" and safe_string(repo.owner.login) or safe_string(repo.owner)
  local name = safe_string(repo.name)
  if owner ~= "" and name ~= "" then
    return owner .. "/" .. name
  end

  return ""
end

local function resolve_repository(details)
  details = type(details) == "table" and details or {}
  local repository = extract_repository(details.baseRepository)
  if repository ~= "" then
    return repository
  end
  return extract_repository(details.headRepository)
end

local function prefetch_config()
  local plugin_config = type(config.get()) == "table" and config.get() or {}
  local diff_view = type(plugin_config.diff_view) == "table" and plugin_config.diff_view or {}
  local prefetch = type(diff_view.prefetch) == "table" and diff_view.prefetch or {}
  return {
    enabled = prefetch.enabled ~= false,
    concurrency = math.max(1, math.floor(tonumber(prefetch.concurrency) or 4)),
    text_extensions = type(prefetch.text_extensions) == "table" and prefetch.text_extensions or {},
  }
end

local function allowed_extension_set(prefetch)
  local allowed = {}
  for _, ext in ipairs(type(prefetch.text_extensions) == "table" and prefetch.text_extensions or {}) do
    local normalized = safe_string(ext):lower():gsub("^%.+", "")
    if normalized ~= "" then
      allowed[normalized] = true
    end
  end
  return allowed
end

local function file_path(file)
  file = type(file) == "table" and file or {}
  local path = safe_string(file.path)
  if path == "" then
    path = safe_string(file.filename)
  end
  if path == "" then
    path = safe_string(file.previous_filename)
  end
  if path == "" then
    path = safe_string(file.previousFilename)
  end
  return normalize_path(path)
end

local function file_extension(path)
  local ext = normalize_path(path):match("%.([^.]+)$")
  if type(ext) ~= "string" then
    return ""
  end
  return ext:lower()
end

local function candidate_signature(file)
  file = type(file) == "table" and file or {}
  return sha256(table.concat({
    normalize_path(file.path or file.filename),
    normalize_path(file.previous_filename or file.previousFilename),
    safe_string(file.status):lower(),
    tostring(tonumber(file.additions) or 0),
    tostring(tonumber(file.deletions) or 0),
    safe_string(file.patch),
  }, "|"))
end

local function collect_candidates(details, prefetch)
  local allowed = allowed_extension_set(prefetch)
  local candidates = {}
  local seen = {}

  for _, file in ipairs(type(details) == "table" and type(details.files) == "table" and details.files or {}) do
    local path = file_path(file)
    local ext = file_extension(path)
    local key = candidate_signature(file)
    if path ~= "" and ext ~= "" and allowed[ext] and not seen[key] then
      seen[key] = true
      candidates[#candidates + 1] = {
        key = key,
        path = path,
        ext = ext,
        file = file,
      }
    end
  end

  return candidates
end

local function session_key(repository, pr_number)
  return table.concat({ repository, tostring(pr_number) }, "#")
end

local function session_is_active(session)
  if type(session) ~= "table" then
    return false
  end
  return active_reviews[session.repository] == session.key
end

local function error_message(err)
  if type(err) == "table" then
    local message = safe_string(err.message)
    if message ~= "" then
      return message
    end
    message = safe_string(err.error)
    if message ~= "" then
      return message
    end
    return "unknown error"
  end

  local message = safe_string(err)
  if message ~= "" then
    return message
  end

  return "unknown error"
end

local function summarize_failures(session)
  local report = type(session) == "table" and session.report or nil
  if type(report) ~= "table" or tonumber(report.failed) == nil or report.failed < 1 then
    return
  end

  local summary = string.format(
    "gh-pr prefetch failed for %d file(s) in PR #%d",
    report.failed,
    session.pr_number
  )
  if type(report.messages) == "table" and #report.messages > 0 then
    summary = summary .. ": " .. table.concat(report.messages, " | ")
  end
  vim.notify(summary, vim.log.levels.WARN)
end

local function item_label(item)
  item = type(item) == "table" and item or {}
  local path = normalize_path(item.path)
  if path ~= "" then
    return path
  end
  return safe_string(item.key, "<unknown>")
end

local function prune_map_to_targets(map, targets)
  map = type(map) == "table" and map or {}
  targets = type(targets) == "table" and targets or {}
  for key, _ in pairs(map) do
    if not targets[key] then
      map[key] = nil
    end
  end
end

local function prune_queue_to_targets(queue, targets)
  queue = type(queue) == "table" and queue or {}
  targets = type(targets) == "table" and targets or {}
  local filtered = {}
  for _, item in ipairs(queue) do
    if type(item) == "table" and targets[item.key] then
      filtered[#filtered + 1] = item
    end
  end
  return filtered
end

local function finish_if_idle(session)
  if type(session) ~= "table" or session.running > 0 or #session.queue > 0 then
    return
  end

  if session_is_active(session) then
    summarize_failures(session)
  end
  session.report = nil
end

local function pump(session)
  if type(session) ~= "table" then
    return
  end

  if not session_is_active(session) then
    session.queue = {}
    session.queued = {}
    finish_if_idle(session)
    return
  end

  while session.running < session.concurrency and #session.queue > 0 do
    local item = table.remove(session.queue, 1)
    session.queued[item.key] = nil
    session.inflight[item.key] = true
    session.running = session.running + 1

    notify_debug(string.format("prefetch start: PR #%d %s", session.pr_number, item_label(item)))

    codediff.prefetch_pr_file_pair({
      details = session.details,
      file = item.file,
    }, function(prepared, err)
      session.running = math.max(0, session.running - 1)
      session.inflight[item.key] = nil

      if prepared then
        session.completed[item.key] = true
        session.report.success = session.report.success + 1
        notify_debug(string.format("prefetch ok: PR #%d %s", session.pr_number, item_label(item)))
      elseif type(err) == "table" and err.requires_virtual == true then
        session.completed[item.key] = true
        session.report.skipped = session.report.skipped + 1
        notify_debug(
          string.format(
            "prefetch skipped: PR #%d %s (%s)",
            session.pr_number,
            item_label(item),
            error_message(err)
          ),
          vim.log.levels.INFO
        )
      else
        session.report.failed = session.report.failed + 1
        notify_debug(
          string.format(
            "prefetch failed: PR #%d %s (%s)",
            session.pr_number,
            item_label(item),
            error_message(err)
          ),
          vim.log.levels.WARN
        )
        if #session.report.messages < 3 then
          session.report.messages[#session.report.messages + 1] = error_message(err)
        end
      end

      pump(session)
      finish_if_idle(session)
    end)
  end

  finish_if_idle(session)
end

function M.prefetch_review(pr, details, opts)
  opts = type(opts) == "table" and opts or {}
  pr = type(pr) == "table" and pr or {}
  details = type(details) == "table" and details or {}

  local prefetch = prefetch_config()
  if not prefetch.enabled then
    notify_debug("prefetch skipped: feature disabled")
    return false, "disabled"
  end

  if not codediff.is_available() then
    notify_debug("prefetch skipped: codediff unavailable")
    return false, "codediff unavailable"
  end

  local repository = resolve_repository(details)
  local pr_number = tonumber(pr.number) or tonumber(details.number)
  if repository == "" or not pr_number then
    notify_debug("prefetch skipped: missing review context")
    return false, "missing review context"
  end

  local candidates = collect_candidates(details, prefetch)
  if vim.tbl_isempty(candidates) then
    notify_debug(string.format("prefetch skipped: PR #%d has no textual candidates", pr_number))
    return false, "no textual files"
  end

  local key = session_key(repository, pr_number)
  active_reviews[repository] = key

  local session = sessions[key]
  if type(session) ~= "table" then
    session = {
      key = key,
      repository = repository,
      pr_number = pr_number,
      concurrency = prefetch.concurrency,
      details = details,
      running = 0,
      queue = {},
      queued = {},
      inflight = {},
      completed = {},
      report = nil,
    }
    sessions[key] = session
  end

  session.pr_number = pr_number
  session.concurrency = prefetch.concurrency
  session.details = details
  session.report = session.report or {
    success = 0,
    skipped = 0,
    failed = 0,
    messages = {},
  }

  local target_keys = {}
  for _, item in ipairs(candidates) do
    target_keys[item.key] = true
  end

  prune_map_to_targets(session.completed, target_keys)
  prune_map_to_targets(session.queued, target_keys)
  prune_map_to_targets(session.inflight, target_keys)
  session.queue = prune_queue_to_targets(session.queue, target_keys)

  local enqueued = 0
  for _, item in ipairs(candidates) do
    if not session.completed[item.key] and not session.queued[item.key] and not session.inflight[item.key] then
      session.queue[#session.queue + 1] = item
      session.queued[item.key] = true
      enqueued = enqueued + 1
    end
  end

  if enqueued < 1 and session.running < 1 then
    session.report = nil
    notify_debug(string.format("prefetch up-to-date: PR #%d", pr_number))
    return false, "up-to-date"
  end

  notify_debug(
    string.format(
      "prefetch queued: PR #%d (%d file(s), concurrency=%d)",
      pr_number,
      enqueued,
      session.concurrency
    )
  )

  pump(session)
  return true, nil
end

return M
