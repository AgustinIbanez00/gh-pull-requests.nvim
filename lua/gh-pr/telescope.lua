local M = {}

local actions = require("gh-pr.actions")
local pr_service = require("gh-pr.pr_service")
local runtime_state = require("gh-pr.state")

local function notify_error(message)
  vim.notify(message, vim.log.levels.ERROR)
end

local function notify_info(message)
  vim.notify(message, vim.log.levels.INFO)
end

local function telescope_modules()
  local ok, pickers = pcall(require, "telescope.pickers")
  if not ok then
    notify_error("telescope.nvim is required for Telescope fallback commands")
    return nil
  end

  return {
    pickers = pickers,
    finders = require("telescope.finders"),
    conf = require("telescope.config").values,
    actions = require("telescope.actions"),
    action_state = require("telescope.actions.state"),
  }
end

local function normalize_path(path)
  if type(path) ~= "string" then
    return ""
  end

  local normalized = path:gsub("\\", "/")
  normalized = normalized:gsub("/+", "/")
  normalized = normalized:gsub("^/", "")
  normalized = normalized:gsub("/$", "")
  return normalized
end

local function repository_full_name(details)
  local repository = type(details) == "table" and (details.baseRepository or details.headRepository) or nil
  if type(repository) ~= "table" then
    return ""
  end

  if type(repository.nameWithOwner) == "string" and repository.nameWithOwner ~= "" then
    return repository.nameWithOwner
  end

  local owner
  if type(repository.owner) == "table" then
    owner = repository.owner.login
  else
    owner = repository.owner
  end

  local name = repository.name
  if type(owner) ~= "string" or owner == "" or type(name) ~= "string" or name == "" then
    return ""
  end

  return owner .. "/" .. name
end

local function has_full_details(details)
  return type(details) == "table" and type(details.files) == "table"
end

local function dedupe_files(files)
  local result = {}
  local seen = {}

  for _, file in ipairs(type(files) == "table" and files or {}) do
    local path = normalize_path(type(file) == "table" and (file.path or file.filename) or "")
    if path ~= "" and not seen[path] then
      seen[path] = true
      result[#result + 1] = file
    end
  end

  return result
end

local function status_prefix(status)
  local normalized = type(status) == "string" and status:lower() or ""
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

local function table_picker(modules, opts)
  opts = opts or {}

  modules.pickers
    .new({}, {
      prompt_title = opts.prompt_title or "gh-pr",
      finder = modules.finders.new_table({
        results = opts.results or {},
        entry_maker = opts.entry_maker,
      }),
      sorter = opts.sorter or modules.conf.generic_sorter({}),
      attach_mappings = function(prompt_bufnr, map)
        local function run_selected()
          local selection = modules.action_state.get_selected_entry()
          modules.actions.close(prompt_bufnr)
          if not selection or not selection.value then
            return
          end

          if type(opts.on_select) == "function" then
            opts.on_select(selection.value)
          end
        end

        map("i", "<CR>", run_selected)
        map("n", "<CR>", run_selected)
        return true
      end,
    })
    :find()
end

local function load_details(number, opts)
  opts = opts or {}
  local target = tonumber(number)
  if not target then
    return nil, nil, "No pull request number provided"
  end

  local active_pr, active_details = runtime_state.get_active_pr()
  if active_pr and tonumber(active_pr.number) == target and has_full_details(active_details) and opts.refresh ~= true then
    actions.set_active_pr(active_pr, active_details)
    return active_pr, active_details, nil
  end

  local details, err = pr_service.fetch_details(target)
  if not details then
    return nil, nil, err
  end

  actions.set_active_pr(details, details)
  return details, details, nil
end

local function resolve_active_pr_context(opts)
  opts = opts or {}

  if type(opts.pr) == "table" and type(opts.details) == "table" then
    actions.set_active_pr(opts.pr, opts.details)
    return opts.pr, opts.details, nil
  end

  local number = tonumber(opts.number)
  if number then
    return load_details(number, { refresh = opts.refresh == true })
  end

  local active_pr, active_details = runtime_state.get_active_pr()
  if type(active_pr) == "table" and tonumber(active_pr.number) then
    if has_full_details(active_details) and opts.refresh ~= true then
      actions.set_active_pr(active_pr, active_details)
      return active_pr, active_details, nil
    end
    return load_details(active_pr.number, { refresh = true })
  end

  return nil, nil, "No active pull request selected"
end

local function resolve_active_review_context(opts)
  opts = opts or {}

  if tonumber(opts.number) then
    local pr, details, err = load_details(opts.number, { refresh = opts.refresh == true })
    if not pr then
      return nil, nil, err
    end

    local ok, review_err = actions.set_active_review(pr, details)
    if not ok then
      return nil, nil, review_err
    end

    return pr, details, nil
  end

  local repository, _ = pr_service.resolve_repository()
  if type(repository) == "table" and type(repository.full_name) == "string" and repository.full_name ~= "" then
    local review_pr, _ = runtime_state.get_active_review(repository.full_name)
    if type(review_pr) == "table" and tonumber(review_pr.number) then
      local pr, details, err = load_details(review_pr.number, { refresh = opts.refresh == true })
      if not pr then
        return nil, nil, err
      end

      local ok, review_err = actions.set_active_review(pr, details)
      if not ok then
        return nil, nil, review_err
      end

      return pr, details, nil
    end
  end

  return nil, nil, "No active review for this repository. Start a review first."
end

local function build_action(id, label, run, opts)
  opts = opts or {}
  return {
    id = id,
    label = label,
    enabled = opts.enabled ~= false,
    reason = opts.reason,
    run = run,
  }
end

local function action_entry_display(item)
  if item.enabled ~= false then
    return item.label
  end

  local reason = type(item.reason) == "string" and item.reason ~= "" and item.reason or "not available"
  return string.format("%s [disabled: %s]", item.label, reason)
end

local function run_action(item)
  if item.enabled == false then
    local reason = type(item.reason) == "string" and item.reason ~= "" and item.reason or "Action not available"
    notify_info(reason)
    return
  end

  local ok, err = pcall(item.run)
  if not ok then
    notify_error("Action failed: " .. tostring(err))
  end
end

local function select_action_picker(modules, prompt_title, items)
  table_picker(modules, {
    prompt_title = prompt_title,
    results = items,
    entry_maker = function(item)
      local display = action_entry_display(item)
      return {
        value = item,
        display = display,
        ordinal = display,
      }
    end,
    on_select = run_action,
  })
end

local function select_file_picker(modules, details, opts)
  opts = opts or {}
  local files = dedupe_files(details.files)
  if vim.tbl_isempty(files) then
    notify_info(opts.empty_message or "No files available in this pull request")
    return
  end

  local pr_number = tonumber(details.number) or 0
  local repository = repository_full_name(details)

  table_picker(modules, {
    prompt_title = opts.prompt_title or string.format("PR #%d Files", pr_number),
    results = files,
    entry_maker = function(file)
      local path = normalize_path(file.path or file.filename)
      local status = status_prefix(file.status)
      local viewed = repository ~= "" and pr_number > 0 and runtime_state.is_viewed(repository, pr_number, path)
      local viewed_suffix = viewed and " [viewed]" or ""
      local display = string.format("[%s] %s%s", status, path, viewed_suffix)
      return {
        value = file,
        display = display,
        ordinal = display,
      }
    end,
    on_select = function(file)
      opts.on_select(file)
    end,
  })
end

local function commit_context(commit)
  commit = type(commit) == "table" and commit or {}
  local oid = type(commit.oid) == "string" and commit.oid or ""
  return {
    oid = oid,
    parent_oid = type(commit.parent_oid) == "string" and commit.parent_oid or "",
    headline = type(commit.messageHeadline) == "string" and commit.messageHeadline
      or (type(commit.headline) == "string" and commit.headline or ""),
    body = type(commit.messageBody) == "string" and commit.messageBody
      or (type(commit.body) == "string" and commit.body or ""),
    url = type(commit.url) == "string" and commit.url or "",
  }
end

local function commit_label(commit)
  local oid = type(commit.oid) == "string" and commit.oid or ""
  local short = oid ~= "" and oid:sub(1, 8) or "????????"
  local headline = type(commit.messageHeadline) == "string" and commit.messageHeadline
    or (type(commit.headline) == "string" and commit.headline or "(no title)")
  return string.format("%s %s", short, headline)
end

local function select_commit_picker(modules, details, opts)
  opts = opts or {}
  local commits = type(details.commits) == "table" and details.commits or {}
  if vim.tbl_isempty(commits) then
    notify_info("No commits in this pull request")
    return
  end

  table_picker(modules, {
    prompt_title = opts.prompt_title or string.format("PR #%d Commits", tonumber(details.number) or 0),
    results = commits,
    entry_maker = function(commit)
      local display = commit_label(commit)
      return {
        value = commit,
        display = display,
        ordinal = display,
      }
    end,
    on_select = function(commit)
      opts.on_select(commit_context(commit), commit)
    end,
  })
end

local function select_commit_file_picker(modules, details)
  select_commit_picker(modules, details, {
    prompt_title = string.format("PR #%d Commit Files", tonumber(details.number) or 0),
    on_select = function(commit)
      if type(commit.oid) ~= "string" or commit.oid == "" then
        notify_error("Selected commit has no oid")
        return
      end

      local commit_details, commit_err = pr_service.fetch_commit_details(tonumber(details.number), commit.oid, {
        repository = repository_full_name(details),
      })
      if not commit_details then
        notify_error(commit_err or "Unable to load commit files")
        return
      end

      local files = dedupe_files(commit_details.files)
      if vim.tbl_isempty(files) then
        notify_info("No files in selected commit")
        return
      end

      table_picker(modules, {
        prompt_title = string.format("%s files", commit_label(commit_details)),
        results = files,
        entry_maker = function(file)
          local path = normalize_path(file.path or file.filename)
          local status = status_prefix(file.status)
          local display = string.format("[%s] %s", status, path)
          return {
            value = file,
            display = display,
            ordinal = display,
          }
        end,
        on_select = function(file)
          actions.open_commit_file_diff(commit, file)
        end,
      })
    end,
  })
end

local function timeline_kind_label(item)
  if type(item) ~= "table" then
    return "COMMENT"
  end

  if item.kind == "commit" then
    return "COMMIT"
  end
  if item.kind == "pr_change" then
    return "PR CHANGE"
  end
  if item.kind == "thread_comment" then
    return "THREAD"
  end
  if item.kind == "review" then
    local state = type(item.state) == "string" and item.state:upper() or "COMMENTED"
    return "REVIEW " .. state
  end

  return "COMMENT"
end

local function timeline_location(item)
  if type(item) ~= "table" then
    return ""
  end

  local path = type(item.path) == "string" and item.path or ""
  local line = tonumber(item.line) or tonumber(item.original_line)
  if path ~= "" and line and line > 0 then
    return string.format("%s:%d", path, line)
  end
  return path
end

local function timeline_body_preview(item)
  local body = type(item) == "table" and type(item.body) == "string" and item.body or ""
  if type(item) == "table" and type(item.kind) == "string" and item.kind == "commit" and body == "" then
    body = type(item.headline) == "string" and item.headline or ""
  end
  if type(item) == "table" and type(item.kind) == "string" and item.kind == "pr_change" and body == "" then
    local summary = type(item.change_summary) == "string" and item.change_summary or ""
    local details = type(item.change_details) == "string" and item.change_details or ""
    body = summary
    if body ~= "" and details ~= "" then
      body = body .. " - " .. details
    elseif body == "" then
      body = details
    end
  end
  local first = vim.split(body, "\n", { plain = true })[1] or ""
  first = vim.trim(first)
  if first == "" then
    return "(empty)"
  end
  if #first > 70 then
    return first:sub(1, 67) .. "..."
  end
  return first
end

local function timeline_items_for_details(details)
  local threads, thread_err = pr_service.fetch_review_threads(tonumber(details.number), {
    threads_first = 100,
    comments_first = 100,
  })
  if not threads then
    threads = {}
  end

  local pr_change_events, pr_change_err = pr_service.fetch_pr_change_events(tonumber(details.number), {
    repository = repository_full_name(details),
    pr_url = type(details.url) == "string" and details.url or "",
    max_items = 400,
    max_pages = 5,
  })
  if not pr_change_events then
    pr_change_events = {}
  end

  local model = pr_service.build_overview_model(details, threads, {
    checks = 20,
    commits = 50,
    timeline = 200,
    comments = 200,
    reviews = 200,
    threads = 200,
  }, {
    repository = repository_full_name(details),
    thread_error = thread_err,
    pr_change_events = pr_change_events,
    pr_change_error = pr_change_err,
  })

  local warnings = {}
  if type(thread_err) == "string" and thread_err ~= "" then
    warnings[#warnings + 1] = "thread fetch error: " .. thread_err
  end
  if type(pr_change_err) == "string" and pr_change_err ~= "" then
    warnings[#warnings + 1] = "pr-change fetch error: " .. pr_change_err
  end

  return type(model.timeline) == "table" and model.timeline.items or {}, table.concat(warnings, "; ")
end

local function open_timeline_item(details, item)
  actions.set_active_pr(details, details)

  if item.kind == "thread_comment" and type(item.target) == "table" then
    actions.open_comment_location(item.target, {
      open_thread_popup = true,
      popup_mode = "open",
      focus_thread_popup = true,
    })
    return
  end

  actions.open_timeline_item(item, {
    pr = details,
    details = details,
    origin_bufnr = vim.api.nvim_get_current_buf(),
  })
end

local function select_timeline_picker(modules, details)
  local items, thread_err = timeline_items_for_details(details)
  if vim.tbl_isempty(items) then
    local message = "No timeline items available for this pull request"
    if type(thread_err) == "string" and thread_err ~= "" then
      message = message .. " (thread fetch error: " .. thread_err .. ")"
    end
    notify_info(message)
    return
  end

  table_picker(modules, {
    prompt_title = string.format("PR #%d Timeline", tonumber(details.number) or 0),
    results = items,
    entry_maker = function(item)
      local author = type(item.author) == "string" and item.author ~= "" and item.author or "unknown"
      local location = timeline_location(item)
      local location_part = location ~= "" and (" @ " .. location) or ""
      local display = string.format("[%s] @%s%s - %s", timeline_kind_label(item), author, location_part, timeline_body_preview(item))
      return {
        value = item,
        display = display,
        ordinal = display,
      }
    end,
    on_select = function(item)
      open_timeline_item(details, item)
    end,
  })
end

local function select_merge_method_picker(modules)
  table_picker(modules, {
    prompt_title = "Select merge method",
    results = {
      { id = "merge", label = "Merge commit" },
      { id = "squash", label = "Squash" },
      { id = "rebase", label = "Rebase" },
    },
    entry_maker = function(item)
      return {
        value = item,
        display = item.label,
        ordinal = item.label,
      }
    end,
    on_select = function(item)
      actions.merge(item.id)
    end,
  })
end

local function current_buffer_inline_capability()
  local bufnr = vim.api.nvim_get_current_buf()
  if vim.b[bufnr].gh_pr_is_image == true then
    return false, "Inline comments are not supported on image diffs"
  end

  local kind = type(vim.b[bufnr].gh_pr_file_kind) == "string" and vim.b[bufnr].gh_pr_file_kind or ""
  if kind ~= "head" and kind ~= "unified" then
    return false, "Open a PR diff buffer (MODIFIED/head or unified) first"
  end

  return true, nil
end

local function current_active_review_for(details)
  local repository = repository_full_name(details)
  if repository == "" then
    local resolved, _ = pr_service.resolve_repository()
    repository = type(resolved) == "table" and resolved.full_name or ""
  end

  if repository == "" then
    return nil
  end

  local review_pr, _ = runtime_state.get_active_review(repository)
  return review_pr
end

local function open_review_actions_picker(modules, pr, details)
  actions.set_active_pr(pr, details)
  actions.set_active_review(pr, details)

  local inline_enabled, inline_reason = current_buffer_inline_capability()

  local items = {
    build_action("overview", "Open overview", function()
      actions.open_overview(pr.number)
    end),
    build_action("browser", "Open PR in browser", function()
      actions.open_overview_url(pr.number)
    end),
    build_action("files_diff", "Browse files: open diff", function()
      select_file_picker(modules, details, {
        prompt_title = string.format("PR #%d files (diff)", pr.number),
        on_select = function(file)
          actions.open_diff(file)
        end,
      })
    end),
    build_action("files_original", "Browse files: open original", function()
      select_file_picker(modules, details, {
        prompt_title = string.format("PR #%d files (original)", pr.number),
        on_select = function(file)
          actions.open_original(file)
        end,
      })
    end),
    build_action("files_modified", "Browse files: open modified", function()
      select_file_picker(modules, details, {
        prompt_title = string.format("PR #%d files (modified)", pr.number),
        on_select = function(file)
          actions.open_modified(file)
        end,
      })
    end),
    build_action("files_toggle_viewed", "Browse files: toggle viewed", function()
      select_file_picker(modules, details, {
        prompt_title = string.format("PR #%d files (toggle viewed)", pr.number),
        on_select = function(file)
          actions.mark_file_viewed(file, nil)
        end,
      })
    end),
    build_action("files_comment_global", "Browse files: add global file comment", function()
      select_file_picker(modules, details, {
        prompt_title = string.format("PR #%d files (global comment)", pr.number),
        on_select = function(file)
          actions.add_file_global_comment(file)
        end,
      })
    end),
    build_action("timeline", "Browse timeline/comments", function()
      select_timeline_picker(modules, details)
    end),
    build_action("commits_patch", "Browse commits: open patch", function()
      select_commit_picker(modules, details, {
        on_select = function(commit)
          actions.open_commit_diff(commit)
        end,
      })
    end),
    build_action("commits_files", "Browse commits: open commit file diff", function()
      select_commit_file_picker(modules, details)
    end),
    build_action("comment_pr", "Publish PR comment", function()
      actions.comment_pr()
    end),
    build_action("edit_labels", "Edit labels", function()
      actions.overview_edit_stub("edit_labels", {})
    end),
    build_action("edit_reviewers", "Edit reviewers", function()
      actions.overview_edit_stub("edit_reviewers", {})
    end),
    build_action("inline_comment", "Add inline comment at cursor (current diff)", function()
      actions.add_inline_comment()
    end, {
      enabled = inline_enabled,
      reason = inline_reason,
    }),
    build_action("inline_suggestion", "Add inline suggestion at cursor (current diff)", function()
      actions.add_inline_suggestion()
    end, {
      enabled = inline_enabled,
      reason = inline_reason,
    }),
    build_action("pending_comment", "Submit pending review as comment", function()
      actions.submit_pending_comment_review()
    end),
    build_action("pending_approve", "Submit pending review as approve", function()
      actions.submit_pending_approve_review()
    end),
    build_action("pending_request_changes", "Submit pending review as request changes", function()
      actions.submit_pending_request_changes_review()
    end),
    build_action("pending_discard", "Discard pending review", function()
      actions.discard_pending_review()
    end),
    build_action("checkout", "Checkout PR branch", function()
      actions.checkout(pr.number)
    end),
    build_action("merge", "Merge PR (select method)", function()
      select_merge_method_picker(modules)
    end),
    build_action("refresh_review", "Refresh PR Review cache and tree", function()
      local ok, gh_pr = pcall(require, "gh-pr")
      if not ok or type(gh_pr.refresh_review) ~= "function" then
        notify_error("Unable to run GhPRReviewRefresh")
        return
      end
      gh_pr.refresh_review()
    end),
    build_action("refresh_pr", "Refresh PR details", function()
      local next_pr, next_details, err = load_details(pr.number, { refresh = true })
      if not next_pr then
        notify_error(err)
        return
      end

      local ok, review_err = actions.set_active_review(next_pr, next_details)
      if not ok then
        notify_error(review_err)
        return
      end

      notify_info(string.format("Refreshed PR #%d details", pr.number))
    end),
  }

  select_action_picker(modules, string.format("PR #%d Review Actions", pr.number), items)
end

local function open_pr_actions_picker(modules, pr, details)
  actions.set_active_pr(pr, details)

  local active_review_pr = current_active_review_for(details)
  local review_enabled = type(active_review_pr) == "table" and tonumber(active_review_pr.number) == tonumber(pr.number)

  local items = {
    build_action("overview", "Open overview", function()
      actions.open_overview(pr.number)
    end),
    build_action("browser", "Open PR in browser", function()
      actions.open_overview_url(pr.number)
    end),
    build_action("files_diff", "Browse files: open diff", function()
      select_file_picker(modules, details, {
        prompt_title = string.format("PR #%d files (diff)", pr.number),
        on_select = function(file)
          actions.open_diff(file)
        end,
      })
    end),
    build_action("files_original", "Browse files: open original", function()
      select_file_picker(modules, details, {
        prompt_title = string.format("PR #%d files (original)", pr.number),
        on_select = function(file)
          actions.open_original(file)
        end,
      })
    end),
    build_action("files_modified", "Browse files: open modified", function()
      select_file_picker(modules, details, {
        prompt_title = string.format("PR #%d files (modified)", pr.number),
        on_select = function(file)
          actions.open_modified(file)
        end,
      })
    end),
    build_action("files_toggle_viewed", "Browse files: toggle viewed", function()
      select_file_picker(modules, details, {
        prompt_title = string.format("PR #%d files (toggle viewed)", pr.number),
        on_select = function(file)
          actions.mark_file_viewed(file, nil)
        end,
      })
    end),
    build_action("files_comment_global", "Browse files: add global file comment", function()
      select_file_picker(modules, details, {
        prompt_title = string.format("PR #%d files (global comment)", pr.number),
        on_select = function(file)
          actions.add_file_global_comment(file)
        end,
      })
    end),
    build_action("timeline", "Browse timeline/comments", function()
      select_timeline_picker(modules, details)
    end),
    build_action("commits_patch", "Browse commits: open patch", function()
      select_commit_picker(modules, details, {
        on_select = function(commit)
          actions.open_commit_diff(commit)
        end,
      })
    end),
    build_action("commits_files", "Browse commits: open commit file diff", function()
      select_commit_file_picker(modules, details)
    end),
    build_action("checkout", "Checkout PR branch", function()
      actions.checkout(pr.number)
    end),
    build_action("start_review", "Start review", function()
      actions.start_review(pr.number)
    end),
    build_action("review_actions", "Open review actions", function()
      open_review_actions_picker(modules, pr, details)
    end, {
      enabled = review_enabled,
      reason = "No active review for this PR. Run 'Start review' first.",
    }),
    build_action("comment_pr", "Publish PR comment", function()
      actions.comment_pr()
    end),
    build_action("review_comment", "Submit review: comment", function()
      actions.review("comment")
    end),
    build_action("review_approve", "Submit review: approve", function()
      actions.review("approve")
    end),
    build_action("review_request_changes", "Submit review: request changes", function()
      actions.review("request_changes")
    end),
    build_action("pending_comment", "Submit pending review as comment", function()
      actions.submit_pending_comment_review()
    end),
    build_action("pending_approve", "Submit pending review as approve", function()
      actions.submit_pending_approve_review()
    end),
    build_action("pending_request_changes", "Submit pending review as request changes", function()
      actions.submit_pending_request_changes_review()
    end),
    build_action("pending_discard", "Discard pending review", function()
      actions.discard_pending_review()
    end),
    build_action("merge", "Merge PR (select method)", function()
      select_merge_method_picker(modules)
    end),
    build_action("edit_labels", "Edit labels", function()
      actions.overview_edit_stub("edit_labels", {})
    end),
    build_action("edit_reviewers", "Edit reviewers", function()
      actions.overview_edit_stub("edit_reviewers", {})
    end),
    build_action("refresh_pr", "Refresh PR details", function()
      local _, _, err = load_details(pr.number, { refresh = true })
      if err then
        notify_error(err)
        return
      end
      notify_info(string.format("Refreshed PR #%d details", pr.number))
    end),
  }

  select_action_picker(modules, string.format("PR #%d Actions", pr.number), items)
end

local function select_pr_action_picker(modules, pr)
  local details, err = pr_service.fetch_details(pr.number)
  if not details then
    notify_error(err)
    return
  end

  actions.set_active_pr(details, details)
  open_pr_actions_picker(modules, details, details)
end

local function select_pr_picker(modules, query_result)
  table_picker(modules, {
    prompt_title = query_result.query.label,
    results = query_result.prs,
    entry_maker = function(pr)
      local decision = type(pr.reviewDecision) == "string" and pr.reviewDecision or "REVIEW_REQUIRED"
      local state = type(pr.state) == "string" and pr.state or "UNKNOWN"
      local draft = pr.isDraft == true and " [draft]" or ""
      local display = string.format("#%d [%s|%s]%s %s", pr.number, state, decision, draft, pr.title)
      return {
        value = pr,
        display = display,
        ordinal = display,
      }
    end,
    on_select = function(pr)
      select_pr_action_picker(modules, pr)
    end,
  })
end

function M.pull_requests()
  local modules = telescope_modules()
  if not modules then
    return
  end

  local query_results = pr_service.list_queries_with_results()

  table_picker(modules, {
    prompt_title = "PR Queries",
    results = query_results,
    entry_maker = function(result)
      local count = #(result.prs or {})
      local suffix = result.error and " [error]" or ""
      local label = string.format("%s/%s (%d)%s", result.query.folder, result.query.label, count, suffix)
      return {
        value = result,
        display = label,
        ordinal = label,
      }
    end,
    on_select = function(result)
      if result.error then
        notify_error(result.error)
        return
      end

      select_pr_picker(modules, result)
    end,
  })
end

function M.open_pr_actions(opts)
  opts = type(opts) == "table" and opts or {}
  local modules = telescope_modules()
  if not modules then
    return
  end

  local pr, details, err = resolve_active_pr_context(opts)
  if not pr then
    notify_info(err)
    M.pull_requests()
    return
  end

  open_pr_actions_picker(modules, pr, details)
end

function M.open_review_actions(opts)
  opts = type(opts) == "table" and opts or {}
  local modules = telescope_modules()
  if not modules then
    return
  end

  local pr, details, err = resolve_active_review_context(opts)
  if not pr then
    notify_error(err)
    return
  end

  open_review_actions_picker(modules, pr, details)
end

function M.open_context_actions(opts)
  opts = type(opts) == "table" and opts or {}

  if opts.review_only == true then
    M.open_review_actions(opts)
    return
  end

  local pr, details, review_err = resolve_active_review_context({ refresh = opts.refresh == true })
  if pr and details then
    local modules = telescope_modules()
    if not modules then
      return
    end
    open_review_actions_picker(modules, pr, details)
    return
  end

  local active_pr, active_details, pr_err = resolve_active_pr_context({ refresh = opts.refresh == true })
  if active_pr and active_details then
    local modules = telescope_modules()
    if not modules then
      return
    end
    open_pr_actions_picker(modules, active_pr, active_details)
    return
  end

  if type(review_err) == "string" and review_err ~= "" then
    notify_info(review_err)
  elseif type(pr_err) == "string" and pr_err ~= "" then
    notify_info(pr_err)
  end

  M.pull_requests()
end

M.pr_actions = M.open_pr_actions
M.review_actions = M.open_review_actions
M.context_actions = M.open_context_actions

return M
