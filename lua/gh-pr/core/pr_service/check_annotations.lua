local M = {}

local function normalize_string(ctx, value, fallback)
  if type(ctx.normalize_string) == "function" then
    return ctx.normalize_string(value, fallback)
  end
  if type(value) == "string" and value ~= "" then
    return value
  end
  return fallback or ""
end

local function normalize_path(path)
  if type(path) ~= "string" then
    return ""
  end
  return path:gsub("\\", "/"):gsub("/+", "/"):gsub("^/", ""):gsub("/$", "")
end

local function clamp_positive(ctx, value, fallback, max_value)
  if type(ctx.clamp_positive) == "function" then
    return ctx.clamp_positive(value, fallback, max_value)
  end

  local number = tonumber(value) or tonumber(fallback) or 1
  number = math.max(1, math.floor(number))
  if tonumber(max_value) and number > tonumber(max_value) then
    number = tonumber(max_value)
  end
  return number
end

local function normalize_repository(input, ctx)
  if type(ctx.normalize_repository_from_input) == "function" then
    local repository = ctx.normalize_repository_from_input(input)
    if repository then
      return repository
    end
  end

  if type(input) == "table" then
    if type(input.owner) == "string" and input.owner ~= "" and type(input.name) == "string" and input.name ~= "" then
      return {
        owner = input.owner,
        name = input.name,
        full_name = input.full_name or (input.owner .. "/" .. input.name),
      }
    end

    if type(input.full_name) == "string" and input.full_name ~= "" then
      local owner, name = input.full_name:match("^([^/]+)/(.+)$")
      if owner and name then
        return {
          owner = owner,
          name = name,
          full_name = input.full_name,
        }
      end
    end
  end

  if type(input) == "string" and input ~= "" then
    local owner, name = input:match("^([^/]+)/(.+)$")
    if owner and name then
      return {
        owner = owner,
        name = name,
        full_name = owner .. "/" .. name,
      }
    end
  end

  return nil
end

local function resolve_repository(check, opts, ctx)
  opts = type(opts) == "table" and opts or {}
  local candidates = {
    opts.head_repository,
    opts.repository,
    type(check) == "table" and check.repository or nil,
  }

  for _, candidate in ipairs(candidates) do
    local repository = normalize_repository(candidate, ctx)
    if repository then
      return repository, nil
    end
  end

  return ctx.resolve_repository()
end

local function normalize_check_name(ctx, check)
  if type(check) ~= "table" then
    return "check"
  end

  local name = normalize_string(ctx, check.name, check.context or "")
  if name == "" and type(check.workflowRun) == "table" and type(check.workflowRun.workflow) == "table" then
    name = normalize_string(ctx, check.workflowRun.workflow.name, "")
  end
  if name == "" then
    name = normalize_string(ctx, check.workflowName, "")
  end
  if name == "" then
    name = normalize_string(ctx, check.__typename, "check")
  end
  return name
end

local function normalize_match_name(value)
  if type(value) ~= "string" then
    return ""
  end

  return vim.trim(value):lower():gsub("%s+", " ")
end

local function normalize_positive_integer(value)
  local number = tonumber(value)
  if not number then
    return nil
  end

  number = math.floor(number)
  if number < 1 then
    return nil
  end

  return number
end

local function add_unique_number(target, seen, value)
  local number = normalize_positive_integer(value)
  if not number then
    return
  end

  if seen[number] then
    return
  end

  seen[number] = true
  target[#target + 1] = number
end

local function add_unique_string(target, seen, value)
  local text = type(value) == "string" and vim.trim(value) or ""
  if text == "" or seen[text] then
    return
  end

  seen[text] = true
  target[#target + 1] = text
end

local function url_run_id_candidates(url)
  local candidates = {}
  local seen = {}
  local source = type(url) == "string" and url or ""
  if source == "" then
    return candidates
  end

  for _, pattern in ipairs({
    "/check%-runs/(%d+)",
    "[?&]check_run_id=(%d+)",
    "/runs/(%d+)",
  }) do
    for value in source:gmatch(pattern) do
      add_unique_number(candidates, seen, value)
    end
  end

  return candidates
end

local function collect_candidate_run_ids(check)
  local candidates = {}
  local seen = {}
  if type(check) ~= "table" then
    return candidates
  end

  for _, value in ipairs({
    check.check_run_id,
    check.checkRunId,
    check.check_run_database_id,
    check.checkRunDatabaseId,
    check.databaseId,
    check.run_id,
    check.runId,
  }) do
    add_unique_number(candidates, seen, value)
  end

  for _, key in ipairs({ "id", "node_id" }) do
    local raw = check[key]
    if type(raw) == "string" and raw:match("^%d+$") then
      add_unique_number(candidates, seen, raw)
    end
  end

  for _, url in ipairs({
    check.detailsUrl,
    check.details_url,
    check.targetUrl,
    check.target_url,
    check.url,
  }) do
    for _, value in ipairs(url_run_id_candidates(url)) do
      add_unique_number(candidates, seen, value)
    end
  end

  return candidates
end

local function collect_candidate_refs(check, opts, ctx)
  opts = type(opts) == "table" and opts or {}
  local details = type(opts.details) == "table" and opts.details or {}
  local refs = {}
  local seen = {}

  add_unique_string(refs, seen, normalize_string(ctx, opts.head_sha, ""))
  add_unique_string(refs, seen, normalize_string(ctx, check and check.head_sha, ""))
  add_unique_string(refs, seen, normalize_string(ctx, details.headRefOid, ""))

  if type(details.commits) == "table" then
    for _, commit in ipairs(details.commits) do
      add_unique_string(refs, seen, normalize_string(ctx, type(commit) == "table" and commit.oid or "", ""))
    end
  end
  return refs
end

local function normalize_annotation_level(ctx, value)
  local level = normalize_string(ctx, value, "notice"):lower()
  if level ~= "failure" and level ~= "warning" then
    level = "notice"
  end
  return level
end

local function normalize_annotation_entry(entry, check_name, run_id, ctx)
  local path = normalize_path(type(entry) == "table" and entry.path or "")
  local start_line = normalize_positive_integer(type(entry) == "table" and (entry.start_line or entry.startLine or entry.line) or nil)
  local end_line = normalize_positive_integer(type(entry) == "table" and (entry.end_line or entry.endLine or entry.start_line or entry.startLine or entry.line) or nil)
  if start_line and end_line and end_line < start_line then
    start_line, end_line = end_line, start_line
  end
  if start_line and not end_line then
    end_line = start_line
  elseif end_line and not start_line then
    start_line = end_line
  end

  local message = normalize_string(ctx, type(entry) == "table" and entry.message or "", "")
  local title = normalize_string(ctx, type(entry) == "table" and entry.title or "", "")
  if title == "" then
    title = message:match("([^\r\n]+)") or ""
  end
  if title == "" then
    title = "Annotation"
  end

  return {
    path = path,
    start_line = start_line or 0,
    end_line = end_line or start_line or 0,
    annotation_level = normalize_annotation_level(ctx, type(entry) == "table" and entry.annotation_level or nil),
    title = title,
    message = message,
    raw_details = normalize_string(ctx, type(entry) == "table" and entry.raw_details or "", ""),
    blob_href = normalize_string(ctx, type(entry) == "table" and (entry.blob_href or entry.blobHref or entry.details_url or entry.html_url) or "", ""),
    check_name = check_name,
    check_run_id = run_id,
  }
end

local function annotation_page_endpoint(repository, run_id, page, per_page)
  return string.format(
    "repos/%s/%s/check-runs/%d/annotations?per_page=%d&page=%d",
    repository.owner,
    repository.name,
    run_id,
    per_page,
    page
  )
end

local function check_runs_endpoint(repository, ref, page, per_page)
  return string.format(
    "repos/%s/%s/commits/%s/check-runs?per_page=%d&page=%d",
    repository.owner,
    repository.name,
    ref,
    per_page,
    page
  )
end

local function fetch_annotations_for_run_id(repository, run_id, check_name, opts, ctx)
  local per_page = clamp_positive(ctx, type(opts) == "table" and opts.per_page or 100, 100, 100)
  local max_pages = clamp_positive(ctx, type(opts) == "table" and opts.max_pages or 20, 20, 100)
  local annotations = {}

  for page = 1, max_pages do
    local payload, err = ctx.gh.run_json({ "api", annotation_page_endpoint(repository, run_id, page, per_page) })
    if not payload then
      return nil, err
    end
    if type(payload) ~= "table" then
      return nil, "Unexpected GitHub annotations response format"
    end

    local count = 0
    for _, item in ipairs(payload) do
      annotations[#annotations + 1] = normalize_annotation_entry(item, check_name, run_id, ctx)
      count = count + 1
    end

    if count < per_page then
      break
    end
  end

  return annotations, nil
end

local function fetch_annotations_for_run_id_async(repository, run_id, check_name, opts, callback, ctx)
  callback = callback or function() end
  local per_page = clamp_positive(ctx, type(opts) == "table" and opts.per_page or 100, 100, 100)
  local max_pages = clamp_positive(ctx, type(opts) == "table" and opts.max_pages or 20, 20, 100)
  local annotations = {}

  local function load_page(page)
    if page > max_pages then
      callback(annotations, nil)
      return
    end

    ctx.gh.run_json_async({ "api", annotation_page_endpoint(repository, run_id, page, per_page) }, nil, function(payload, err)
      if not payload then
        callback(nil, err)
        return
      end
      if type(payload) ~= "table" then
        callback(nil, "Unexpected GitHub annotations response format")
        return
      end

      local count = 0
      for _, item in ipairs(payload) do
        annotations[#annotations + 1] = normalize_annotation_entry(item, check_name, run_id, ctx)
        count = count + 1
      end

      if count < per_page then
        callback(annotations, nil)
        return
      end

      load_page(page + 1)
    end)
  end

  load_page(1)
end

local function list_check_runs_for_ref(repository, ref, opts, ctx)
  local per_page = clamp_positive(ctx, type(opts) == "table" and opts.per_page or 100, 100, 100)
  local max_pages = clamp_positive(ctx, type(opts) == "table" and opts.max_pages or 10, 10, 100)
  local runs = {}

  for page = 1, max_pages do
    local payload, err = ctx.gh.run_json({ "api", check_runs_endpoint(repository, ref, page, per_page) })
    if not payload then
      return nil, err
    end

    local items = type(payload) == "table" and payload.check_runs or nil
    if type(items) ~= "table" then
      return nil, "Unexpected GitHub check-runs response format"
    end

    local count = 0
    for _, run in ipairs(items) do
      runs[#runs + 1] = run
      count = count + 1
    end

    if count < per_page then
      break
    end
  end

  return runs, nil
end

local function list_check_runs_for_ref_async(repository, ref, opts, callback, ctx)
  callback = callback or function() end
  local per_page = clamp_positive(ctx, type(opts) == "table" and opts.per_page or 100, 100, 100)
  local max_pages = clamp_positive(ctx, type(opts) == "table" and opts.max_pages or 10, 10, 100)
  local runs = {}

  local function load_page(page)
    if page > max_pages then
      callback(runs, nil)
      return
    end

    ctx.gh.run_json_async({ "api", check_runs_endpoint(repository, ref, page, per_page) }, nil, function(payload, err)
      if not payload then
        callback(nil, err)
        return
      end

      local items = type(payload) == "table" and payload.check_runs or nil
      if type(items) ~= "table" then
        callback(nil, "Unexpected GitHub check-runs response format")
        return
      end

      local count = 0
      for _, run in ipairs(items) do
        runs[#runs + 1] = run
        count = count + 1
      end

      if count < per_page then
        callback(runs, nil)
        return
      end

      load_page(page + 1)
    end)
  end

  load_page(1)
end

local function run_matches_check(run, check, ctx)
  if type(run) ~= "table" then
    return false
  end

  local desired_name = normalize_match_name(normalize_check_name(ctx, check))
  local run_name = normalize_match_name(type(run.name) == "string" and run.name or "")
  if desired_name ~= "" and run_name ~= "" and desired_name == run_name then
    return true
  end

  local desired_url = normalize_string(ctx, type(check) == "table" and (check.detailsUrl or check.targetUrl or check.url) or "", "")
  local details_url = normalize_string(ctx, run.details_url, run.html_url or "")
  if desired_url ~= "" and details_url ~= "" and desired_url == details_url then
    return true
  end

  return false
end

local function resolve_check_run_via_listing(repository, check, opts, ctx)
  local refs = collect_candidate_refs(check, opts, ctx)
  if vim.tbl_isempty(refs) then
    return nil, "Unable to resolve a commit reference for this check"
  end

  for _, ref in ipairs(refs) do
    local runs, err = list_check_runs_for_ref(repository, ref, opts, ctx)
    if runs then
      for _, run in ipairs(runs) do
        if run_matches_check(run, check, ctx) then
          local run_id = normalize_positive_integer(run.id)
          if run_id then
            return run_id, nil
          end
        end
      end
    elseif type(err) == "string" and err ~= "" then
      return nil, err
    end
  end

  return nil, "Unable to resolve check run annotations for this check"
end

local function resolve_check_run_via_listing_async(repository, check, opts, callback, ctx)
  callback = callback or function() end
  local refs = collect_candidate_refs(check, opts, ctx)
  if vim.tbl_isempty(refs) then
    callback(nil, "Unable to resolve a commit reference for this check")
    return
  end

  local function load_ref(index)
    local ref = refs[index]
    if not ref then
      callback(nil, "Unable to resolve check run annotations for this check")
      return
    end

    list_check_runs_for_ref_async(repository, ref, opts, function(runs, err)
      if not runs then
        callback(nil, err)
        return
      end

      for _, run in ipairs(runs) do
        if run_matches_check(run, check, ctx) then
          local run_id = normalize_positive_integer(run.id)
          if run_id then
            callback(run_id, nil)
            return
          end
        end
      end

      load_ref(index + 1)
    end, ctx)
  end

  load_ref(1)
end

function M.fetch_check_annotations(number, check, opts, ctx)
  if type(check) ~= "table" then
    return nil, "Missing check metadata for annotation lookup"
  end

  local repository, repo_err = resolve_repository(check, opts, ctx)
  if not repository then
    return nil, repo_err
  end

  local check_name = normalize_check_name(ctx, check)
  local last_error = nil

  for _, run_id in ipairs(collect_candidate_run_ids(check)) do
    local annotations, err = fetch_annotations_for_run_id(repository, run_id, check_name, opts, ctx)
    if annotations then
      return {
        pr_number = tonumber(number) or 0,
        repository = repository.full_name,
        check_name = check_name,
        check_run_id = run_id,
        annotations = annotations,
      }, nil
    end
    last_error = err or last_error
  end

  local resolved_run_id, resolve_err = resolve_check_run_via_listing(repository, check, opts, ctx)
  if not resolved_run_id then
    return nil, resolve_err or last_error
  end

  local annotations, err = fetch_annotations_for_run_id(repository, resolved_run_id, check_name, opts, ctx)
  if not annotations then
    return nil, err or last_error
  end

  return {
    pr_number = tonumber(number) or 0,
    repository = repository.full_name,
    check_name = check_name,
    check_run_id = resolved_run_id,
    annotations = annotations,
  }, nil
end

function M.fetch_check_annotations_async(number, check, opts, callback, ctx)
  callback = callback or function() end
  if type(check) ~= "table" then
    callback(nil, "Missing check metadata for annotation lookup")
    return
  end

  local repository, repo_err = resolve_repository(check, opts, ctx)
  if not repository then
    callback(nil, repo_err)
    return
  end

  local check_name = normalize_check_name(ctx, check)
  local candidates = collect_candidate_run_ids(check)
  local last_error = nil

  local function resolve_via_listing()
    resolve_check_run_via_listing_async(repository, check, opts, function(resolved_run_id, resolve_err)
      if not resolved_run_id then
        callback(nil, resolve_err or last_error)
        return
      end

      fetch_annotations_for_run_id_async(repository, resolved_run_id, check_name, opts, function(annotations, err)
        if not annotations then
          callback(nil, err or last_error)
          return
        end

        callback({
          pr_number = tonumber(number) or 0,
          repository = repository.full_name,
          check_name = check_name,
          check_run_id = resolved_run_id,
          annotations = annotations,
        }, nil)
      end, ctx)
    end, ctx)
  end

  local function try_candidate(index)
    local run_id = candidates[index]
    if not run_id then
      resolve_via_listing()
      return
    end

    fetch_annotations_for_run_id_async(repository, run_id, check_name, opts, function(annotations, err)
      if annotations then
        callback({
          pr_number = tonumber(number) or 0,
          repository = repository.full_name,
          check_name = check_name,
          check_run_id = run_id,
          annotations = annotations,
        }, nil)
        return
      end

      last_error = err or last_error
      try_candidate(index + 1)
    end, ctx)
  end

  try_candidate(1)
end

return M
