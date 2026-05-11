vim.opt.rtp:append(".")
vim.cmd("runtime plugin/gh-pr.lua")

require("gh-pr").setup({
  ui = {
    use_neotree = false,
    telescope_fallback = false,
  },
  diff_view = {
    prefetch = {
      enabled = true,
      concurrency = 2,
      text_extensions = { "lua", ".md" },
    },
    non_text = {
      enabled = true,
      auto_preview = true,
      show_metadata = true,
    },
  },
})

do
  local cfg = require("gh-pr.config").get()
  local prefetch = cfg.diff_view.prefetch or {}
  local pr_explorer = cfg.diff_view.pr_explorer or {}
  local comments_panel = cfg.diff_view.comments_panel or {}
  local changes_panel = cfg.diff_view.changes_panel or {}
  local non_text = cfg.diff_view.non_text or {}
  local cache = cfg.cache or {}
  local follow_current_file = cfg.follow_current_file or {}
  local follow_sources = follow_current_file.sources or {}
  local neotree_sources = ((cfg.ui or {}).neotree_sources or {})
  local my_pr_source = neotree_sources.my_pr or {}
  local overview_activity = (((cfg.overview or {}).panes or {}).activity or {})
  local overview_threads = overview_activity.threads or {}
  local overview_thread_diff = overview_threads.diff or {}
  local pr_service = require("gh-pr.pr_service")
  local virtual_files = require("gh-pr.virtual_files")
  local actions = require("gh-pr.actions")
  local ok_annotations = pcall(require, "gh-pr.check_annotations")
  local ok_security_annotations = pcall(require, "gh-pr.security_annotations")
  local ok_security_section = pcall(require, "gh-pr.neotree.review_sections.security")

  assert(vim.fn.exists(":GhPrOpen") == 2, "Missing :GhPrOpen command")
  assert(vim.fn.exists(":GhPrReviewRefresh") == 2, "Missing :GhPrReviewRefresh command")
  assert(vim.fn.exists(":GhPrMyPr") == 2, "Missing :GhPrMyPr command")
  assert(vim.fn.exists(":GhPrMyPR") == 2, "Missing :GhPrMyPR alias")
  assert(vim.fn.exists(":GhPRReviewRefresh") == 2, "Missing :GhPRReviewRefresh alias")
  assert(vim.fn.exists(":GhPrToggleChangesPanel") == 2, "Missing :GhPrToggleChangesPanel command")
  assert(vim.fn.maparg("<Plug>(gh-pr-open)", "n") ~= "", "Missing <Plug>(gh-pr-open)")
  assert(vim.fn.maparg("<Plug>(gh-pr-review-refresh)", "n") ~= "", "Missing <Plug>(gh-pr-review-refresh)")
  assert(vim.fn.maparg("<Plug>(gh-pr-my-pr)", "n") ~= "", "Missing <Plug>(gh-pr-my-pr)")
  assert(vim.fn.maparg("<Plug>(gh-pr-toggle-changes-panel)", "n") ~= "",
    "Missing <Plug>(gh-pr-toggle-changes-panel)")
  assert(prefetch.enabled == true, "Missing diff_view.prefetch.enabled")
  assert(prefetch.concurrency == 2, "Missing diff_view.prefetch.concurrency")
  assert(prefetch.text_extensions[1] == "lua" and prefetch.text_extensions[2] == "md",
    "Missing diff_view.prefetch.text_extensions")
  assert(pr_explorer.enabled == true, "Missing diff_view.pr_explorer.enabled")
  assert(comments_panel.position == "bottom", "Missing diff_view.comments_panel.position default")
  assert(changes_panel.enabled == true and changes_panel.auto_open == true,
    "Missing diff_view.changes_panel enabled/auto_open defaults")
  assert(changes_panel.position == "right" and changes_panel.width == 34,
    "Missing diff_view.changes_panel position/width defaults")
  assert(non_text.enabled == true, "Missing diff_view.non_text.enabled")
  assert(non_text.auto_preview == true, "Missing diff_view.non_text.auto_preview")
  assert(non_text.show_metadata == true, "Missing diff_view.non_text.show_metadata")
  assert(overview_threads.collapse_resolved == true, "Missing overview activity collapse_resolved default")
  assert(overview_threads.collapse_outdated == true, "Missing overview activity collapse_outdated default")
  assert(overview_threads.separator_char == "─", "Missing overview activity separator_char default")
  assert(overview_threads.reply_indent == 2, "Missing overview activity reply_indent default")
  assert(overview_thread_diff.enabled == true, "Missing overview activity diff.enabled default")
  assert(overview_thread_diff.style == "snippet", "Missing overview activity diff.style default")
  assert(overview_thread_diff.context_before == 2 and overview_thread_diff.context_after == 2,
    "Missing overview activity diff context defaults")
  assert(overview_thread_diff.max_lines == 12, "Missing overview activity diff.max_lines default")
  assert(type(require("gh-pr").open_my_pr_tree) == "function", "Missing open_my_pr_tree facade")
  assert(type(require("gh-pr").toggle_changes_panel) == "function", "Missing toggle_changes_panel facade")
  assert(type(cache.gh_my_pr) == "table" and cache.gh_my_pr.enabled == true, "Missing cache.gh_my_pr.enabled")
  assert(cache.gh_my_pr.ttl_seconds == 30, "Missing cache.gh_my_pr.ttl_seconds default")
  assert(cache.gh_my_pr.max_cache_age_seconds == 300, "Missing cache.gh_my_pr.max_cache_age_seconds default")
  assert(cache.gh_my_pr.auto_refresh_when_focused == true, "Missing cache.gh_my_pr.auto_refresh_when_focused")
  assert(cache.gh_my_pr.show_stale_badge == true, "Missing cache.gh_my_pr.show_stale_badge")
  assert(cache.gh_my_pr.sync_visible_buffers == true, "Missing cache.gh_my_pr.sync_visible_buffers")
  assert(follow_sources.my_pr == true, "Missing follow_current_file.sources.my_pr default")
  assert(my_pr_source.auto_register == true, "Missing ui.neotree_sources.my_pr.auto_register")
  assert(my_pr_source.gate == "github_repo", "Missing ui.neotree_sources.my_pr.gate")
  assert(my_pr_source.workspace == "cwd", "Missing ui.neotree_sources.my_pr.workspace")
  assert(type(virtual_files.classify_file) == "function", "Missing virtual_files.classify_file")
  assert(virtual_files.classify_file({ path = "a.png", patch = "" }) == "image", "Expected image classification")
  assert(virtual_files.classify_file({ path = "a.zip", patch = "" }) == "asset", "Expected asset classification")
  assert(virtual_files.classify_file({ path = "a.lua", patch = "" }) == "text", "Expected text classification")
  assert(type(actions.run_non_text_default_action) == "function", "Missing actions.run_non_text_default_action")
  assert(type(actions.open_non_text_actions_menu) == "function", "Missing actions.open_non_text_actions_menu")
  assert(type(actions.run_non_text_action_at_cursor) == "function", "Missing actions.run_non_text_action_at_cursor")
  assert(type(actions.open_security_alert_location) == "function", "Missing actions.open_security_alert_location")
  assert(type(pr_service.reply_to_review_thread) == "function", "Missing pr_service.reply_to_review_thread")
  assert(type(pr_service.resolve_review_thread) == "function", "Missing pr_service.resolve_review_thread")
  assert(type(pr_service.unresolve_review_thread) == "function", "Missing pr_service.unresolve_review_thread")
  assert(type(pr_service.update_review_comment) == "function", "Missing pr_service.update_review_comment")
  assert(type(pr_service.delete_review_comment) == "function", "Missing pr_service.delete_review_comment")
  assert(type(pr_service.set_review_comment_reaction) == "function", "Missing pr_service.set_review_comment_reaction")
  assert(type(pr_service.fetch_review_threads_with_pending) == "function",
    "Missing pr_service.fetch_review_threads_with_pending")
  assert(type(pr_service.fetch_review_threads_with_pending_async) == "function",
    "Missing pr_service.fetch_review_threads_with_pending_async")
  assert(type(pr_service.fetch_viewed_files) == "function", "Missing pr_service.fetch_viewed_files")
  assert(type(pr_service.fetch_viewed_files_async) == "function", "Missing pr_service.fetch_viewed_files_async")
  assert(type(pr_service.set_files_viewed) == "function", "Missing pr_service.set_files_viewed")
  assert(type(pr_service.fetch_check_annotations) == "function", "Missing pr_service.fetch_check_annotations")
  assert(type(pr_service.fetch_check_annotations_async) == "function",
    "Missing pr_service.fetch_check_annotations_async")
  assert(type(pr_service.fetch_code_scanning_alerts) == "function", "Missing pr_service.fetch_code_scanning_alerts")
  assert(type(pr_service.fetch_code_scanning_alerts_async) == "function",
    "Missing pr_service.fetch_code_scanning_alerts_async")
  assert(type(pr_service.fetch_dependency_review) == "function", "Missing pr_service.fetch_dependency_review")
  assert(type(pr_service.fetch_dependency_review_async) == "function",
    "Missing pr_service.fetch_dependency_review_async")
  assert(type(pr_service.find_pr_for_branch) == "function", "Missing pr_service.find_pr_for_branch")
  assert(type(pr_service.find_pr_for_branch_async) == "function", "Missing pr_service.find_pr_for_branch_async")
  assert(ok_annotations == true, "Missing gh-pr.check_annotations module")
  assert(ok_security_annotations == true, "Missing gh-pr.security_annotations module")
  assert(ok_security_section == true, "Missing gh-pr.neotree.review_sections.security module")

  local ok, health = pcall(require, "gh-pr.health")
  assert(ok and type(health.check) == "function", "Missing gh-pr health check entrypoint")
end

do
  local runtime = require("gh-pr.core.runtime")
  local codediff = require("gh-pr.integrations.codediff")
  local virtual_files = require("gh-pr.virtual_files")
  local helpers = codediff._temp_buffer_helpers or {}
  local virtual_helpers = virtual_files._diff_view_helpers or {}

  assert(type(helpers.mark_codediff_temp_buffer) == "function",
    "Missing codediff transient buffer helper")
  assert(type(virtual_helpers.mark_transient_buffer) == "function",
    "Missing virtual transient buffer helper")

  local cache_root = table.concat({ vim.fn.stdpath("cache"), "gh-pr", "codediff", "pairs", "smoke", "Example.cs" }, "/")
  local codediff_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(codediff_buf, cache_root)
  assert(helpers.mark_codediff_temp_buffer(codediff_buf) == true,
    "codediff cache buffer should be marked as transient")
  assert(vim.b[codediff_buf].gh_pr_lsp_exclude == true,
    "codediff cache buffer should opt out of external LSP/workspace resolution")
  assert(vim.b[codediff_buf].gh_pr_transient_diff_buffer == true,
    "codediff cache buffer should expose the transient diff marker")
  assert(vim.b[codediff_buf].gh_pr_codediff_temp == true,
    "codediff cache buffer should expose the codediff temp marker")

  local local_head_path = table.concat({ vim.fn.stdpath("cache"), "gh-pr-local-head-smoke.cs" }, "/")
  local local_head_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(local_head_buf, local_head_path)
  assert(helpers.mark_codediff_temp_buffer(local_head_buf) == false,
    "real file buffers should not be marked as codediff temp buffers by default")
  assert(vim.b[local_head_buf].gh_pr_lsp_exclude ~= true,
    "real file buffers should keep LSP eligibility by default")

  local virtual_diff_buf = vim.api.nvim_create_buf(false, true)
  virtual_helpers.mark_transient_buffer(virtual_diff_buf)
  assert(vim.b[virtual_diff_buf].gh_pr_lsp_exclude == true,
    "virtual diff buffers should opt out of external LSP/workspace resolution")
  assert(vim.b[virtual_diff_buf].gh_pr_transient_diff_buffer == true,
    "virtual diff buffers should expose the transient diff marker")

  runtime.ensure_initialized()
  local ghpr_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(ghpr_buf, "ghpr://review/321/src/Example.cs")
  vim.api.nvim_set_current_buf(ghpr_buf)
  vim.api.nvim_exec_autocmds("BufEnter", {
    buffer = ghpr_buf,
    modeline = false,
  })
  assert(vim.b[ghpr_buf].gh_pr_lsp_exclude == true,
    "ghpr URI buffers should opt out of external LSP/workspace resolution")
end

do
  local cfg = require("gh-pr.config").get()
  local actions = require("gh-pr.actions")
  local url_open = require("gh-pr.url_open")
  local helpers = actions._open_target_helpers or {}

  assert(((cfg.overview or {}).markdown or {}).link_preview_open_local == "disabled",
    "Missing secure overview.markdown.link_preview_open_local default")
  assert((((cfg.diff_view or {}).images or {}).fallback_open_local) == "disabled",
    "Missing secure diff_view.images.fallback_open_local default")
  assert(type(helpers.normalize_local_open_policy) == "function"
      and helpers.normalize_local_open_policy("reveal_only", "disabled") == "reveal_only",
    "Missing local-open policy sanitizer")
  assert(type(helpers.effective_local_open_policy) == "function"
      and helpers.effective_local_open_policy("system", "dangerous.cmd") == "reveal_only",
    "Dangerous local extensions must downgrade to reveal_only")
  assert(type(helpers.resolve_attachment_filename) == "function"
      and helpers.resolve_attachment_filename("https://objects.githubusercontent.com/?download=1", "evil.cmd", {
        md = true,
      }) == "attachment.bin",
    "Attachment filename fallback must not trust dangerous labels")

  local ok_url, ok_err = url_open._normalize_url("https://example.com/path")
  assert(ok_url == "https://example.com/path" and ok_err == nil, "normalize_url should keep valid https URLs")

  local _, scheme_err = url_open._normalize_url("file:///tmp/test")
  assert(type(scheme_err) == "string" and scheme_err:find("Only http/https", 1, true) ~= nil,
    "normalize_url should reject file://")

  local _, whitespace_err = url_open._normalize_url("https://example.com/a b")
  assert(type(whitespace_err) == "string" and whitespace_err:find("unsupported whitespace", 1, true) ~= nil,
    "normalize_url should reject whitespace")
end

do
  local render = require("gh-pr.ui.overview.render")
  local activity_opts = render.sanitize_activity_opts({})
  assert(activity_opts.threads.diff.enabled == true, "Render activity opts should keep thread diff enabled by default")
  assert(activity_opts.threads.collapse_resolved == true, "Render activity opts should collapse resolved threads by default")

  local payloads = render.render({
    model = {
      number = 42,
      title = "Embedded Activity Smoke",
      description = "PR description line",
      summary = {
        state = "OPEN",
        review_decision = "REVIEW_REQUIRED",
        author = "octocat",
        head_ref = "feature/overview",
        base_ref = "main",
        additions = 3,
        deletions = 1,
        files_changed = 2,
        updated_at = "2026-03-16T10:00:00Z",
        merge_state = "clean",
        mergeable = "MERGEABLE",
      },
      people = {
        review_requests = {},
        assignees = {},
        labels = {},
      },
      timeline = {
        items = {
          {
            kind = "comment",
            author = "octocat",
            body = "Looks good",
            created_at = "2026-03-16T10:05:00Z",
          },
        },
      },
      comments = { total = 1 },
      reviews = { total = 0 },
      threads = { total = 0 },
      commits = { total = 0 },
      pr_changes = { total = 0 },
    },
    show = {
      timeline = true,
      comments = true,
      reviews = true,
      threads = true,
      commits = true,
      pr_changes = true,
    },
    activity = activity_opts,
    theme = {},
    date_format = "%Y-%m-%d %H:%M",
  })

  assert(payloads.activity == nil, "Overview render should not expose a standalone activity pane payload")

  local description_line = nil
  local activity_line = nil
  for index, line in ipairs(payloads.summary.lines or {}) do
    if not description_line and line:find("## Description", 1, true) then
      description_line = index
    end
    if not activity_line and line == "# Activity" then
      activity_line = index
    end
  end

  assert(type(description_line) == "number", "Overview summary payload should include the description heading")
  assert(type(activity_line) == "number" and activity_line > description_line,
    "Activity section should render after the description inside the summary pane")
  assert(payloads.meta and payloads.meta.lines and payloads.meta.lines[1] == "# Collaboration",
    "Overview should keep a dedicated collaboration pane payload")
end

do
  local render = require("gh-pr.ui.overview.render")
  local activity = render.sanitize_activity_opts({})

  local function build_thread_event(thread_id, opts)
    opts = opts or {}
    return {
      id = string.format("thread:%s:%s", thread_id, opts.comment_id or "c1"),
      kind = "thread_comment",
      thread_id = thread_id,
      author = opts.author or "octocat",
      body = opts.body or "Comment body",
      diff_hunk = opts.diff_hunk or "@@ -10,3 +10,4 @@\n context one\n-context two\n+context two changed\n+context three\n",
      state = opts.state or "SUBMITTED",
      created_at = opts.created_at or "2026-03-16T10:05:00Z",
      url = opts.url or "https://example.com/comment",
      path = opts.path or "lua/gh-pr/example.lua",
      line = opts.line or 11,
      original_line = opts.original_line or 11,
      side = opts.side or "head",
      commit_oid = opts.commit_oid or "abc123",
      original_commit_oid = opts.original_commit_oid or "def456",
      is_resolved = opts.is_resolved == true,
      is_outdated = opts.is_outdated == true,
    }
  end

  local session = {
    model = {
      number = 42,
      title = "Thread cards",
      description = "PR description line",
      summary = {
        state = "OPEN",
        review_decision = "REVIEW_REQUIRED",
        author = "octocat",
        head_ref = "feature/overview",
        base_ref = "main",
        additions = 3,
        deletions = 1,
        files_changed = 2,
        updated_at = "2026-03-16T10:00:00Z",
        merge_state = "clean",
        mergeable = "MERGEABLE",
      },
      people = {
        review_requests = {},
        assignees = {},
      },
      labels = { items = {} },
      timeline = {
        items = {
          build_thread_event("thread-open", {
            body = "Primary comment body",
            line = 11,
            original_line = 10,
          }),
          build_thread_event("thread-open", {
            comment_id = "c2",
            author = "hubot",
            body = "Reply body",
            created_at = "2026-03-16T10:06:00Z",
            line = 12,
            original_line = 11,
          }),
          build_thread_event("thread-resolved", {
            comment_id = "c3",
            author = "reviewer",
            body = "Resolved body",
            is_resolved = true,
            line = 20,
            original_line = 20,
          }),
        },
      },
      comments = { total = 0 },
      reviews = { total = 0 },
      threads = { total = 2 },
      commits = { total = 0 },
      pr_changes = { total = 0 },
    },
    show = {
      timeline = true,
      comments = true,
      reviews = true,
      threads = true,
      commits = true,
      pr_changes = true,
    },
    activity = activity,
    activity_folds = {},
    theme = {},
    date_format = "%Y-%m-%d %H:%M",
  }

  local payloads = render.render(session)
  local summary_lines = payloads.summary.lines or {}
  local open_header = nil
  local resolved_header = nil
  local primary_body = nil
  local reply_line = nil
  local diff_fence = nil
  local resolved_body = nil

  for index, line in ipairs(summary_lines) do
    if line:find("%[%-%]%s+thread%s+lua/gh%-pr/example%.lua:11", 1) then
      open_header = index
    end
    if line:find("%[%+%]%s+thread%s+lua/gh%-pr/example%.lua:20%s+%[resolved%]", 1) then
      resolved_header = index
    end
    if line:find("Primary comment body", 1, true) then
      primary_body = index
    end
    if line:find("^%s+@hubot", 1) then
      reply_line = line
    end
    if line:find("```diff", 1, true) then
      diff_fence = index
    end
    if line:find("Resolved body", 1, true) then
      resolved_body = index
    end
  end

  assert(type(open_header) == "number", "Open thread header should render expanded by default")
  assert(type(resolved_header) == "number", "Resolved thread header should render collapsed by default")
  assert(type(primary_body) == "number" and primary_body > open_header, "Expanded thread should render comment body")
  assert(type(reply_line) == "string" and reply_line:find("^%s%s%s%s@hubot", 1) ~= nil,
    "Replies should render with additional indentation")
  assert(type(diff_fence) == "number" and diff_fence > open_header, "Expanded thread should render inline diff fence")
  assert(resolved_body == nil, "Collapsed resolved thread should hide comment body by default")
end

do
  local render = require("gh-pr.ui.overview.render")
  local runtime = require("gh-pr.ui.overview.runtime")
  local activity = render.sanitize_activity_opts({})
  local opened_payload = nil
  local session_id = runtime.open({
    number = 42,
    title = "Overview runtime thread toggle",
    description = "Runtime body",
    summary = {
      state = "OPEN",
      review_decision = "REVIEW_REQUIRED",
      author = "octocat",
      head_ref = "feature/runtime",
      base_ref = "main",
      additions = 1,
      deletions = 0,
      files_changed = 1,
      updated_at = "2026-03-16T10:00:00Z",
      merge_state = "clean",
      mergeable = "MERGEABLE",
    },
    people = {
      review_requests = {},
      assignees = {},
    },
    labels = { items = {} },
    timeline = {
      items = {
        {
          id = "thread:runtime:c1",
          kind = "thread_comment",
          thread_id = "runtime-thread",
          author = "reviewer",
          body = "Collapsed runtime body",
          diff_hunk = "@@ -2,2 +2,3 @@\n context\n-old line\n+new line\n+extra line\n",
          state = "SUBMITTED",
          created_at = "2026-03-16T10:05:00Z",
          url = "https://example.com/runtime-thread",
          path = "lua/gh-pr/runtime.lua",
          line = 3,
          original_line = 3,
          side = "head",
          commit_oid = "abc123",
          original_commit_oid = "def456",
          is_resolved = true,
          is_outdated = false,
        },
      },
    },
    comments = { total = 0 },
    reviews = { total = 0 },
    threads = { total = 1 },
    commits = { total = 0 },
    pr_changes = { total = 0 },
  }, {
    show = {
      timeline = true,
      comments = true,
      reviews = true,
      threads = true,
      commits = true,
      pr_changes = true,
    },
    activity = activity,
    theme = {},
    date_format = "%Y-%m-%d %H:%M",
    actions = {
      open_activity_thread_workspace = function(payload)
        opened_payload = payload
      end,
    },
  })

  assert(type(session_id) == "number", "Overview runtime should open session for thread toggle smoke")
  local summary_buf = vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(summary_buf, 0, -1, false)
  local header_line = nil
  for index, line in ipairs(lines) do
    if line:find("%[%+%]%s+thread%s+lua/gh%-pr/runtime%.lua:3%s+%[resolved%]", 1) then
      header_line = index
      break
    end
  end
  assert(type(header_line) == "number", "Runtime smoke should render collapsed thread header")
  assert(vim.fn.maparg("<CR>", "n", false, true).desc == "GH PR Overview: open selection or toggle thread",
    "Overview <CR> mapping should describe thread toggle behavior")
  assert(vim.fn.maparg("D", "n", false, true).desc == "GH PR Overview: open diff or secondary action",
    "Overview D mapping should describe diff behavior")

  vim.api.nvim_win_set_cursor(0, { header_line, 0 })
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "x", false)
  vim.wait(20)

  lines = vim.api.nvim_buf_get_lines(summary_buf, 0, -1, false)
  local expanded_header = lines[header_line] or ""
  local expanded_body = table.concat(lines, "\n")
  assert(expanded_header:find("%[%-%]") ~= nil, "Pressing <CR> on thread header should expand the thread")
  assert(expanded_body:find("Collapsed runtime body", 1, true) ~= nil,
    "Expanded runtime thread should render its body")

  vim.api.nvim_win_set_cursor(0, { header_line, 0 })
  vim.api.nvim_feedkeys("D", "x", false)
  vim.wait(20)

  assert(type(opened_payload) == "table" and opened_payload.thread_id == "runtime-thread",
    "Pressing D on thread header should open the thread diff/workspace")
  runtime.close(session_id)
end

do
  local reviewer_model = require("gh-pr.core.reviewers")
  local reviewers = reviewer_model.build({
    headRefOid = "head-2",
    reviewRequests = {
      { login = "pending-user" },
      {
        requestedReviewer = {
          slug = "core",
          organization = { login = "acme" },
        },
      },
    },
    latestReviews = {
      {
        author = { login = "approved-user" },
        state = "APPROVED",
        submittedAt = "2026-03-16T10:00:00Z",
        commit = { oid = "head-1" },
      },
      {
        author = { login = "commented-user" },
        state = "COMMENTED",
        submittedAt = "2026-03-16T09:00:00Z",
        commit = { oid = "head-1" },
      },
    },
    reviews = {
      {
        author = { login = "approved-user" },
        state = "CHANGES_REQUESTED",
        submittedAt = "2026-03-15T10:00:00Z",
        commit = { oid = "head-0" },
      },
      {
        author = { login = "fallback-user" },
        state = "CHANGES_REQUESTED",
        submittedAt = "2026-03-14T10:00:00Z",
        commit = { oid = "head-0" },
      },
      {
        author = { login = "fallback-user" },
        state = "APPROVED",
        submittedAt = "2026-03-15T10:00:00Z",
        commit = { oid = "head-1" },
      },
      {
        author = { login = "stale-user" },
        state = "APPROVED",
        submittedAt = "2026-03-15T09:00:00Z",
        commit = { oid = "head-2" },
      },
      {
        author = { login = "ignored-user" },
        state = "DISMISSED",
        submittedAt = "2026-03-15T08:00:00Z",
        commit = { oid = "head-1" },
      },
    },
  })

  local by_name = {}
  for _, reviewer in ipairs(reviewers) do
    by_name[reviewer.display_name] = reviewer
  end

  assert(by_name["@approved-user"] and by_name["@approved-user"].state == "APPROVED",
    "Latest review state should win over older, more severe history")
  assert(by_name["@approved-user"].can_rerequest == true,
    "Completed user reviews should allow re-request after head movement")
  assert(by_name["@pending-user"] and by_name["@pending-user"].state == "PENDING",
    "Active review requests should render as pending")
  assert(by_name["@pending-user"].can_rerequest == false,
    "Pending reviewers should not allow re-request")
  assert(by_name["@commented-user"] and by_name["@commented-user"].state == "COMMENTED",
    "COMMENTED latest reviews should be preserved for UI state")
  assert(by_name["@fallback-user"] and by_name["@fallback-user"].state == "APPROVED",
    "Fallback review history should use the latest submitted review")
  assert(by_name["@stale-user"] and by_name["@stale-user"].can_rerequest == false,
    "Re-request should stay disabled when the latest reviewed commit matches head")
  assert(by_name["acme/core"] and by_name["acme/core"].kind == "team" and by_name["acme/core"].state == "PENDING",
    "Team review requests should stay visible with pending state")
  assert(by_name["acme/core"].request_value == "acme/core",
    "Team review requests should derive org/slug request values when available")

  local counts, total = reviewer_model.count_states(reviewers)
  assert(total == 6, "Reviewer helper should only expose supported reviewer states")
  assert((counts.APPROVED or 0) == 3 and (counts.PENDING or 0) == 2 and (counts.COMMENTED or 0) == 1,
    "Reviewer helper state counts should track approved/pending/commented reviewers")

  local neotree_reviewers = require("gh-pr.neotree.review_sections.reviewers")
  local nodes = neotree_reviewers.build_nodes({ number = 42 }, {
    headRefOid = "head-2",
    reviewRequests = {
      { login = "pending-user" },
    },
    latestReviews = {
      {
        author = { login = "approved-user" },
        state = "APPROVED",
        submittedAt = "2026-03-16T10:00:00Z",
      },
      {
        author = { login = "commented-user" },
        state = "COMMENTED",
        submittedAt = "2026-03-16T09:00:00Z",
      },
    },
    reviews = {
      {
        author = { login = "approved-user" },
        state = "CHANGES_REQUESTED",
        submittedAt = "2026-03-15T10:00:00Z",
      },
    },
  })
  local names = {}
  for _, node in ipairs(nodes) do
    names[#names + 1] = node.name
  end
  assert(table.concat(names, "\n"):find("@approved%-user %[APPROVED%]", 1) ~= nil,
    "Neo-tree reviewer nodes should use the shared latest-review semantics")
  assert(table.concat(names, "\n"):find("@commented%-user %[COMMENTED%]", 1) ~= nil,
    "Neo-tree reviewer nodes should keep COMMENTED reviewer state")
end

do
  local render = require("gh-pr.ui.overview.render")
  local payloads = render.render({
    model = {
      number = 42,
      title = "Reviewer rows",
      description = "PR description line",
      summary = {
        state = "OPEN",
        review_decision = "REVIEW_REQUIRED",
        author = "octocat",
        head_ref = "feature/reviewers",
        base_ref = "main",
        additions = 3,
        deletions = 1,
        files_changed = 2,
        updated_at = "2026-03-16T10:00:00Z",
        merge_state = "clean",
        mergeable = "MERGEABLE",
      },
      people = {
        review_requests = { "legacy-request" },
        reviewers = {
          {
            id = "user:approved-user",
            display_name = "@approved-user",
            request_value = "approved-user",
            kind = "user",
            state = "APPROVED",
            can_rerequest = true,
          },
          {
            id = "user:pending-user",
            display_name = "@pending-user",
            request_value = "pending-user",
            kind = "user",
            state = "PENDING",
            can_rerequest = false,
          },
          {
            id = "user:changes-user",
            display_name = "@changes-user",
            request_value = "changes-user",
            kind = "user",
            state = "CHANGES_REQUESTED",
            can_rerequest = true,
          },
          {
            id = "user:commented-user",
            display_name = "@commented-user",
            request_value = "commented-user",
            kind = "user",
            state = "COMMENTED",
            can_rerequest = true,
          },
        },
        assignees = {},
      },
      labels = { items = {} },
      comments = { total = 0 },
      reviews = { total = 0 },
      threads = { total = 0 },
      commits = { items = {}, total = 0 },
      timeline = { items = {} },
      pr_changes = { total = 0 },
    },
    show = {
      timeline = true,
      comments = true,
      reviews = true,
      threads = true,
      commits = true,
      pr_changes = true,
    },
    activity = render.sanitize_activity_opts({}),
    theme = {
      state_colors = true,
      labels = true,
      timeline_kinds = true,
    },
    date_format = "%Y-%m-%d %H:%M",
  })

  local lines = payloads.meta.lines or {}
  local actions = payloads.meta.actions or {}
  local highlights = payloads.meta.highlights or {}
  local approved_line = nil
  local pending_line = nil
  local changes_line = nil
  local commented_line = nil
  local heading_line = nil

  for index, line in ipairs(lines) do
    if line:find("^## Reviewers", 1) then
      heading_line = index
    elseif line:find("^%- @approved%-user %[APPROVED%]", 1) then
      approved_line = index
    elseif line:find("^%- @pending%-user %[PENDING%]", 1) then
      pending_line = index
    elseif line:find("^%- @changes%-user %[CHANGES_REQUESTED%]", 1) then
      changes_line = index
    elseif line:find("^%- @commented%-user %[COMMENTED%]", 1) then
      commented_line = index
    end
  end

  assert(type(heading_line) == "number" and actions[heading_line] and actions[heading_line].edit_kind == "edit_reviewers",
    "Reviewers heading should keep the edit action")
  assert(type(approved_line) == "number" and lines[approved_line]:find("re%-request", 1) ~= nil,
    "Actionable reviewer rows should show the re-request hint")
  assert(type(pending_line) == "number" and lines[pending_line]:find("re%-request", 1) == nil,
    "Non-actionable reviewer rows should hide the re-request hint")
  assert(actions[approved_line] and actions[approved_line].kind == "rerequest_reviewer",
    "Actionable reviewer rows should expose rerequest_reviewer actions")
  assert(actions[pending_line] == nil, "Pending reviewer rows should not expose a row action")
  assert(actions[changes_line] and actions[commented_line],
    "Completed non-pending reviewer rows should stay actionable")

  local function find_highlight(line, group)
    for _, item in ipairs(highlights) do
      if item.line == line and item.group == group then
        return item
      end
    end
    return nil
  end

  local approved_hl = find_highlight(approved_line, "GhPrOverviewReviewerApproved")
  local pending_hl = find_highlight(pending_line, "GhPrOverviewReviewerPending")
  local changes_hl = find_highlight(changes_line, "GhPrOverviewReviewerChanges")
  local commented_hl = find_highlight(commented_line, "GhPrOverviewReviewerCommented")
  assert(approved_hl and approved_hl.start_col > 0 and approved_hl.end_col > approved_hl.start_col,
    "Approved reviewer row should highlight only the state token")
  assert(pending_hl and changes_hl and commented_hl,
    "Reviewer rows should use dedicated state highlight groups")
end

do
  local runtime = require("gh-pr.ui.overview.runtime")
  local rerequested = {}
  local edit_calls = {}
  local session_id = runtime.open({
    number = 42,
    title = "Overview reviewer actions",
    description = "Runtime body",
    summary = {
      state = "OPEN",
      review_decision = "REVIEW_REQUIRED",
      author = "octocat",
      head_ref = "feature/runtime",
      base_ref = "main",
      additions = 1,
      deletions = 0,
      files_changed = 1,
      updated_at = "2026-03-16T10:00:00Z",
      merge_state = "clean",
      mergeable = "MERGEABLE",
    },
    people = {
      review_requests = {},
      reviewers = {
        {
          id = "user:approved-user",
          display_name = "@approved-user",
          request_value = "approved-user",
          kind = "user",
          state = "APPROVED",
          can_rerequest = true,
        },
        {
          id = "user:pending-user",
          display_name = "@pending-user",
          request_value = "pending-user",
          kind = "user",
          state = "PENDING",
          can_rerequest = false,
        },
      },
      assignees = {},
    },
    labels = { items = {} },
    timeline = { items = {} },
    comments = { total = 0 },
    reviews = { total = 0 },
    threads = { total = 0 },
    commits = { items = {}, total = 0 },
    pr_changes = { total = 0 },
  }, {
    focus_role = "meta",
    show = {
      timeline = true,
      comments = true,
      reviews = true,
      threads = true,
      commits = true,
      pr_changes = true,
    },
    activity = require("gh-pr.ui.overview.render").sanitize_activity_opts({}),
    theme = {},
    date_format = "%Y-%m-%d %H:%M",
    actions = {
      rerequest_reviewer = function(payload)
        rerequested[#rerequested + 1] = payload
      end,
      edit_stub = function(kind, payload)
        edit_calls[#edit_calls + 1] = { kind = kind, payload = payload }
      end,
    },
  })

  assert(type(session_id) == "number", "Overview runtime should open session for reviewer action smoke")
  local meta_buf = vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(meta_buf, 0, -1, false)
  local heading_line = nil
  local approved_line = nil
  local pending_line = nil
  for index, line in ipairs(lines) do
    if not heading_line and line:find("^## Reviewers", 1) then
      heading_line = index
    elseif not approved_line and line:find("^%- @approved%-user %[APPROVED%]", 1) then
      approved_line = index
    elseif not pending_line and line:find("^%- @pending%-user %[PENDING%]", 1) then
      pending_line = index
    end
  end

  assert(type(heading_line) == "number" and type(approved_line) == "number" and type(pending_line) == "number",
    "Reviewer runtime smoke should render heading and reviewer rows")

  vim.api.nvim_win_set_cursor(0, { approved_line, 0 })
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "x", false)
  vim.wait(20)
  assert(#rerequested == 1 and rerequested[1].request_value == "approved-user",
    "Pressing <CR> on an actionable reviewer should trigger the rerequest callback")

  vim.api.nvim_win_set_cursor(0, { pending_line, 0 })
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "x", false)
  vim.wait(20)
  assert(#rerequested == 1, "Pressing <CR> on a non-actionable reviewer should do nothing")

  vim.api.nvim_win_set_cursor(0, { heading_line, 0 })
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "x", false)
  vim.wait(20)
  assert(#edit_calls == 1 and edit_calls[1].kind == "edit_reviewers",
    "Pressing <CR> on the Reviewers heading should still open edit_reviewers")

  runtime.close(session_id)
end

do
  local popup = require("gh-pr.comment_popup")
  local comment_thread_actions = require("gh-pr.comment_thread_actions")
  local origin = vim.api.nvim_get_current_buf()
  local ctx = { thread_id = "t1", path = "lua/gh-pr/comment_popup.lua", line = 12 }
  local items = {
    {
      id = "c1",
      author = "user",
      body = "own published",
      meta = { thread_id = "t1", viewer_did_author = true, comment_is_pending = false, reaction_groups = {} },
    },
    {
      id = "c2",
      author = "other",
      body = "other pending",
      meta = {
        thread_id = "t1",
        viewer_did_author = false,
        comment_is_pending = true,
        thread_is_resolved = true,
        reaction_groups = {},
      },
    },
  }

  local ok = select(1, popup.open({
    origin_bufnr = origin,
    tag = "thread",
    title = "Smoke",
    items = items,
    actions = comment_thread_actions.build_popup_actions(ctx),
    footer_provider = comment_thread_actions.build_popup_footer_provider(ctx),
    enter = true,
    position = "editor",
  }))
  assert(ok == true, "Comment popup should open")

  local popup_buf = vim.api.nvim_get_current_buf()
  local popup_win = vim.api.nvim_get_current_win()
  assert(vim.b[popup_buf].gh_pr_popup_line_items[vim.api.nvim_win_get_cursor(popup_win)[1]] == 1,
    "Comment popup should start on first comment")

  local lines = vim.api.nvim_buf_get_lines(popup_buf, 0, -1, false)
  assert(lines[#lines] == "r reply  R quote  x resolve  e edit  D delete  +/- reactions  q close",
    "Own published comment should show all contextual actions")
  assert(vim.fn.maparg("r", "n", false, true).desc == "Reply to selected PR thread",
    "Missing popup reply mapping")
  assert(vim.fn.maparg("R", "n", false, true).desc == "Quote-reply to selected PR thread",
    "Missing popup quote mapping")
  assert(vim.fn.maparg("x", "n", false, true).desc == "Resolve or unresolve selected PR thread",
    "Missing popup resolve mapping")
  assert(vim.fn.maparg("e", "n", false, true).desc == "Edit selected PR comment",
    "Missing popup edit mapping")
  assert(vim.fn.maparg("D", "n", false, true).desc == "Delete selected PR comment",
    "Missing popup delete mapping")
  assert(vim.fn.maparg("+", "n", false, true).desc == "Add reaction to selected PR comment",
    "Missing popup reaction-add mapping")
  assert(vim.fn.maparg("-", "n", false, true).desc == "Remove reaction from selected PR comment",
    "Missing popup reaction-remove mapping")

  local other_line = vim.fn.search("@other", "nw")
  assert(other_line > 0, "Other comment line should exist")
  vim.api.nvim_win_set_cursor(popup_win, { other_line, 0 })
  vim.api.nvim_exec_autocmds("CursorMoved", { buffer = popup_buf, modeline = false })

  lines = vim.api.nvim_buf_get_lines(popup_buf, 0, -1, false)
  assert(lines[#lines] == "r reply  R quote  x unresolve  q close",
    "Other pending comment should hide owner-only actions and reactions")

  popup.close_for_origin(origin, "thread")

  local footer = comment_thread_actions.build_popup_footer_provider({ thread_id = "t1" })
  lines = footer({
    id = "c3",
    author = "user",
    body = "own pending",
    meta = { thread_id = "t1", viewer_did_author = true, comment_is_pending = true },
  }, {})
  assert(type(lines) == "table" and lines[1] == "r reply  R quote  x resolve  e edit  q close",
    "Own pending comment should hide delete and reactions while keeping edit")
end

do
  local cfg = require("gh-pr.config").get()
  local reactions_cfg = (cfg.line_comments or {}).reactions or {}
  local picker_cfg = (reactions_cfg.picker or {})
  local reactions = require("gh-pr.reactions")
  local picker = require("gh-pr.ui.reaction_picker")
  local summary = reactions.render_summary({
    { content = "THUMBS_UP", total_count = 2, viewer_has_reacted = true },
    { content = "HEART", total_count = 1, viewer_has_reacted = false },
  }, {
    render = reactions_cfg.render,
    viewer_marker = reactions_cfg.viewer_marker,
  })

  assert(reactions_cfg.render == "emoji", "Missing line_comments.reactions.render default")
  assert(reactions_cfg.viewer_marker == "*", "Missing line_comments.reactions.viewer_marker default")
  assert(picker_cfg.position == "cursor", "Missing line_comments.reactions.picker.position default")
  assert(picker_cfg.width == 56, "Missing line_comments.reactions.picker.width default")
  assert(picker_cfg.height == 10, "Missing line_comments.reactions.picker.height default")
  assert(summary:find("👍", 1, true) ~= nil and summary:find("THUMBS_UP", 1, true) == nil,
    "Reaction summary should render emoji labels")

  local sections = reactions.build_picker_sections({
    { content = "THUMBS_UP", total_count = 2, viewer_has_reacted = true },
    { content = "ROCKET", total_count = 1, viewer_has_reacted = true },
  }, { viewer_marker = "*" })
  assert(type(sections) == "table" and sections[1] and sections[1].items[1]
      and sections[1].items[1].content == "THUMBS_UP",
    "Reaction sections should start with quick reactions")

  local origin = vim.api.nvim_get_current_buf()
  local selected = nil
  local open_ok, handle = picker.open({
    origin_bufnr = origin,
    anchor_win = vim.api.nvim_get_current_win(),
    mode = "add",
    reaction_groups = {
      { content = "THUMBS_UP", total_count = 2, viewer_has_reacted = true },
      { content = "ROCKET", total_count = 1, viewer_has_reacted = true },
    },
    on_select = function(item)
      selected = item.content
    end,
  })
  assert(open_ok == true and type(handle) == "table", "Reaction picker should open")
  assert((picker.current_item(handle.bufnr) or {}).content == "THUMBS_UP",
    "Reaction picker should start on thumbs up")
  assert(picker.move(handle.bufnr, "right") == true, "Reaction picker should move right")
  assert((picker.current_item(handle.bufnr) or {}).content == "HEART",
    "Reaction picker should move across quick reactions")
  assert(picker.move(handle.bufnr, "down") == true, "Reaction picker should move down")
  assert((picker.current_item(handle.bufnr) or {}).content == "EYES",
    "Reaction picker should move into matching more-reactions column")
  assert(picker.confirm(handle.bufnr) == true and selected == "EYES",
    "Reaction picker should confirm selected reaction")

  local remove_selected = nil
  local remove_ok, remove_handle = picker.open({
    origin_bufnr = origin,
    mode = "remove",
    reaction_groups = {
      { content = "ROCKET", total_count = 3, viewer_has_reacted = true },
    },
    on_select = function(item)
      remove_selected = item.content
    end,
  })
  assert(remove_ok == true and type(remove_handle) == "table", "Reaction picker remove mode should open")
  assert((picker.current_item(remove_handle.bufnr) or {}).content == "ROCKET",
    "Reaction picker remove mode should keep reacted item")
  assert(picker.confirm(remove_handle.bufnr) == true and remove_selected == "ROCKET",
    "Reaction picker remove mode should confirm current reaction")

  local none_ok, none_err = picker.open({
    origin_bufnr = origin,
    mode = "remove",
    reaction_groups = {},
    on_select = function() end,
  })
  assert(none_ok == false and none_err == "You do not have any reactions on this comment",
    "Reaction picker should reject empty remove mode")
end

do
  local config_mod = require("gh-pr.config")
  local actions = require("gh-pr.actions")
  local diff_view = require("gh-pr.core.diff_view")
  local diff_shortcuts = require("gh-pr.diff_shortcuts")
  local state = require("gh-pr.state")
  local virtual_files = require("gh-pr.virtual_files")
  local helpers = actions._diff_view_helpers or {}
  local resolve_prefs = helpers.current_diff_view_preferences

  config_mod.setup({
    diff_view = {
      mode = "unified",
      ignore_whitespace = true,
      render_whitespace = false,
      render_endlines = true,
      shortcuts = {
        cycle_whitespace_mode = "<localleader>dw",
      },
    },
  })

  local compat_cfg = config_mod.get()
  assert(compat_cfg.diff_view.ignore_whitespace_mode == "trim",
    "Legacy ignore_whitespace=true should map to ignore_whitespace_mode=trim")
  assert(compat_cfg.diff_view.ignore_whitespace == true,
    "Legacy ignore_whitespace should remain enabled")
  assert(((compat_cfg.diff_view or {}).shortcuts or {}).cycle_whitespace_mode == "<localleader>dw",
    "Missing cycle_whitespace_mode shortcut config")
  assert(type(resolve_prefs) == "function", "Missing diff view preferences helper")

  state.clear_diff_view_prefs()
  local config_defaults = resolve_prefs()
  assert(config_defaults.mode == "unified"
      and config_defaults.ignore_whitespace_mode == "trim"
      and config_defaults.render_whitespace == false
      and config_defaults.render_endlines == true,
    "Config defaults should be used when diff prefs are not persisted")

  config_mod.setup({
    diff_view = {
      ignore_whitespace_mode = "all",
      shortcuts = {
        cycle_whitespace_mode = "<localleader>dw",
      },
    },
  })
  assert(config_mod.get().diff_view.ignore_whitespace_mode == "trim",
    "Legacy ignore_whitespace_mode=all should coerce to trim")

  state.set_diff_view_prefs({
    mode = "vertical",
    ignore_whitespace = false,
    render_whitespace = true,
    render_endlines = false,
  })
  assert(state.get_diff_view_prefs().ignore_whitespace_mode == "none",
    "State legacy boolean false should map to none")

  state.set_diff_view_prefs({
    mode = "vertical",
    ignore_whitespace_mode = "all",
    render_whitespace = true,
    render_endlines = false,
  })
  assert(state.get_diff_view_prefs().ignore_whitespace_mode == "trim",
    "Persisted whitespace mode all should coerce to trim")

  state.set_diff_view_prefs({
    mode = "horizontal",
    ignore_whitespace_mode = "eol",
    render_whitespace = true,
    render_endlines = false,
  })
  local persisted_precedence = resolve_prefs()
  assert(persisted_precedence.mode == "horizontal"
      and persisted_precedence.ignore_whitespace_mode == "eol"
      and persisted_precedence.render_whitespace == true
      and persisted_precedence.render_endlines == false,
    "Persisted diff prefs should override setup defaults")

  local one_shot = resolve_prefs({
    mode = "vertical",
    ignore_whitespace_mode = "trim",
    render_whitespace = false,
    render_endlines = true,
  })
  assert(one_shot.mode == "vertical"
      and one_shot.ignore_whitespace_mode == "trim"
      and one_shot.render_whitespace == false
      and one_shot.render_endlines == true,
    "One-shot diff overrides should win for the current resolution")
  local persisted_after_one_shot = state.get_diff_view_prefs()
  assert(persisted_after_one_shot.mode == "horizontal"
      and persisted_after_one_shot.ignore_whitespace_mode == "eol"
      and persisted_after_one_shot.render_whitespace == true
      and persisted_after_one_shot.render_endlines == false,
    "One-shot diff overrides should not persist to state")

  state.set_diff_view_prefs({
    mode = "vertical",
    ignore_whitespace_mode = "eol",
    render_whitespace = true,
    render_endlines = false,
    shortcuts = {
      cycle_mode = "ZZ",
    },
  })
  local prefs = state.get_diff_view_prefs()
  assert(prefs.ignore_whitespace_mode == "eol" and prefs.ignore_whitespace == true,
    "State should persist granular whitespace mode")
  assert(prefs.shortcuts == nil, "Diff shortcuts should not be read from or written to persisted diff prefs")
  local configured_shortcuts = diff_shortcuts.resolve(((config_mod.get() or {}).diff_view or {}).shortcuts)
  assert(configured_shortcuts.cycle_whitespace_mode == "<localleader>dw",
    "Diff shortcuts should continue resolving only from Lua config")

  local build = ((virtual_files._diff_view_helpers or {}).build_unified_diff_text)
  assert(type(build) == "function", "Missing unified diff helper")

  local strict = select(1, build("a\tb\n", "a b\n", "none"))
  assert(strict:find("- a\tb", 1, true) ~= nil and strict:find("+ a b", 1, true) ~= nil,
    "Strict mode should keep tab-vs-space changes")

  local trim = select(1, build("a\tb\n", "a b\n", "trim"))
  assert(trim:find("+ ", 1, true) == nil and trim:find("- ", 1, true) == nil,
    "Trim-whitespace mode should hide tab-vs-space changes")

  local eol = select(1, build("a \n", "a\n", "eol"))
  assert(eol:find("+ ", 1, true) == nil and eol:find("- ", 1, true) == nil,
    "EOL whitespace mode should hide trailing whitespace changes")

  local blank = select(1, build("a\n\nb\n", "a\nb\n", "blank_lines"))
  assert(blank:find("+ ", 1, true) == nil and blank:find("- ", 1, true) == nil,
    "Blank-lines mode should hide empty-line changes")

  assert(diff_view.supports_codediff_text_backend({
    mode = "vertical",
    ignore_whitespace_mode = "none",
  }) == true, "Vertical+none should remain codediff-compatible")
  assert(diff_view.supports_codediff_text_backend({
    mode = "vertical",
    ignore_whitespace_mode = "trim",
  }) == true, "Vertical+trim should remain codediff-compatible")
  assert(diff_view.supports_codediff_text_backend({
    mode = "unified",
    ignore_whitespace_mode = "none",
  }) == true, "Unified+none should remain codediff-compatible")
  assert(diff_view.supports_codediff_text_backend({
    mode = "unified",
    ignore_whitespace_mode = "trim",
  }) == true, "Unified+trim should remain codediff-compatible")
  assert(diff_view.supports_codediff_text_backend({
    mode = "horizontal",
    ignore_whitespace_mode = "none",
  }) == false, "Horizontal should force virtual backend")
  assert(diff_view.supports_codediff_text_backend({
    mode = "vertical",
    ignore_whitespace_mode = "eol",
  }) == false, "EOL whitespace mode should force virtual backend")
end

do
  local diff_hunks = require("gh-pr.core.diff_hunks")

  local codediff_hunks = diff_hunks.from_codediff_changes({
    {
      original = { start_line = 2, end_line = 4 },
      modified = { start_line = 2, end_line = 5 },
    },
    {
      original = { start_line = 8, end_line = 10 },
      modified = { start_line = 8, end_line = 8 },
    },
  })
  assert(#codediff_hunks == 2, "Codediff hunks should be built from change ranges")
  assert(codediff_hunks[1].added == 3 and codediff_hunks[1].deleted == 2,
    "Codediff modify hunk should keep add/delete counts")
  assert(codediff_hunks[2].target_side == "base" and codediff_hunks[2].deleted == 2,
    "Codediff delete-only hunk should target the base side")

  local unified_hunks = diff_hunks.from_unified_line_map({
    [1] = { kind = "context", head_line = 1, base_line = 1 },
    [2] = { kind = "delete", base_line = 2 },
    [3] = { kind = "add", head_line = 2 },
    [4] = { kind = "context", head_line = 3, base_line = 3 },
    [5] = { kind = "add", head_line = 4 },
  })
  assert(#unified_hunks == 2 and unified_hunks[1].target_side == "unified",
    "Unified line-map hunks should group adjacent changed render lines")
  assert(unified_hunks[1].added == 1 and unified_hunks[1].deleted == 1 and unified_hunks[1].target_line == 2,
    "Unified mixed hunk should track counts and render target line")

  local base_buf = vim.api.nvim_create_buf(false, true)
  local head_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(base_buf, 0, -1, false, { "one", "two", "three" })
  vim.api.nvim_buf_set_lines(head_buf, 0, -1, false, { "one", "TWO", "three", "four" })
  local buffer_hunks = diff_hunks.from_buffers(base_buf, head_buf)
  assert(#buffer_hunks >= 1, "Buffer hunks should be built with vim.diff")

  local added_hunks = diff_hunks.from_single_buffer(head_buf, "added_single")
  assert(#added_hunks == 1 and added_hunks[1].added == 4 and added_hunks[1].target_side == "head",
    "Added single-buffer hunk should cover the full head buffer")
  local removed_hunks = diff_hunks.from_single_buffer(base_buf, "removed_single")
  assert(#removed_hunks == 1 and removed_hunks[1].deleted == 3 and removed_hunks[1].target_side == "base",
    "Removed single-buffer hunk should cover the full base buffer")
end

do
  local config_mod = require("gh-pr.config")
  local actions = require("gh-pr.actions")
  local diff_shortcuts = require("gh-pr.diff_shortcuts")
  local virtual_files = require("gh-pr.virtual_files")
  local action_helpers = actions._diff_view_helpers or {}
  local virtual_helpers = virtual_files._diff_view_helpers or {}
  local original_maplocalleader = vim.g.maplocalleader
  local original_codediff_config = package.loaded["codediff.config"]

  vim.g.maplocalleader = nil
  local expanded_help = diff_shortcuts.expand_localleader({ help = "<localleader>?" })
  assert(expanded_help.help == ",?", "Diff shortcuts should keep ',' fallback when maplocalleader is unset")
  vim.g.maplocalleader = original_maplocalleader

  assert(diff_shortcuts.defaults.help == "<localleader>?"
      and diff_shortcuts.defaults.refresh == "<localleader>R"
      and diff_shortcuts.defaults.close_quick == "<localleader>q"
      and diff_shortcuts.defaults.close_all_open_review == "<localleader>Q",
    "Diff shortcut defaults should use the short <localleader> namespace")
  assert(diff_shortcuts.defaults.next_change == "<localleader>n"
      and diff_shortcuts.defaults.next_file == "<localleader>f"
      and diff_shortcuts.defaults.next_reviewed_file == "<localleader>v",
    "Diff navigation defaults should drop the legacy d-prefix")
  assert(diff_shortcuts.defaults.line_comments_popup == "<localleader>k"
      and diff_shortcuts.defaults.inline_comment == "<localleader>c"
      and diff_shortcuts.defaults.inline_suggestion == "<localleader>s"
      and diff_shortcuts.defaults.toggle_comments_panel == "<localleader>C"
      and diff_shortcuts.defaults.toggle_changes_panel == "<localleader>o",
    "Inline comment defaults should use the short localleader mappings")

  local duplicate_shortcuts, duplicate_diags = diff_shortcuts.resolve_effective({
    help = "<localleader>?",
    close_quick = "<localleader>?",
  }, {
    backend = "virtual",
  })
  assert(duplicate_shortcuts.close_quick ~= "" and duplicate_shortcuts.help == "",
    "Duplicate diff shortcuts should keep the first action and disable the later one")
  assert(#(duplicate_diags.duplicates or {}) == 1
      and duplicate_diags.duplicates[1].kept == "close_quick"
      and duplicate_diags.duplicates[1].skipped == "help",
    "Duplicate diff shortcut diagnostics should report kept/skipped actions")

  local reserved_shortcuts, reserved_diags = diff_shortcuts.resolve_effective({
    close_quick = "q",
    help = "g?",
  }, {
    backend = "codediff",
  })
  assert(reserved_shortcuts.close_quick == "" and reserved_shortcuts.help == "",
    "codediff-owned shortcuts should be omitted from gh-pr codediff buffers")
  assert(#(reserved_diags.reserved or {}) == 2,
    "codediff-owned shortcut conflicts should be reported")

  assert(type(virtual_helpers.set_pr_buffer_keymaps) == "function",
    "Missing virtual diff keymap helper")
  assert(type(action_helpers.apply_codediff_buffer_keymaps) == "function",
    "Missing codediff diff keymap helper")
  assert(type(action_helpers.diff_shortcut_lines) == "function",
    "Missing diff shortcut help helper")

  config_mod.setup({
    diff_view = {
      shortcuts = {
        cycle_whitespace_mode = "<localleader>dw",
      },
    },
  })

  local effective_defaults = diff_shortcuts.expand_localleader(diff_shortcuts.defaults)
  local legacy_defaults = diff_shortcuts.expand_localleader(diff_shortcuts.legacy_defaults)

  local virtual_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(virtual_buf)
  vim.b[virtual_buf].gh_pr_file_kind = "head"
  vim.b[virtual_buf].gh_pr_file_mode = "diff_pair"
  vim.b[virtual_buf].gh_pr_diff_backend = "virtual"
  vim.b[virtual_buf].gh_pr_number = 11
  vim.b[virtual_buf].gh_pr_path = "lua/gh-pr/actions.lua"
  virtual_helpers.set_pr_buffer_keymaps(virtual_buf, {
    is_non_text = false,
  })

  assert(vim.fn.maparg(effective_defaults.help, "n", false, true).desc == "Show PR diff shortcuts",
    "Virtual diff buffer should expose the short help mapping")
  assert(vim.fn.maparg(effective_defaults.close_quick, "n", false, true).desc == "Close quick diff view",
    "Virtual diff buffer should expose the short quick-close mapping")
  assert(vim.fn.maparg(effective_defaults.inline_comment, "n", false, true).desc == "Add inline PR comment",
    "Virtual diff buffer should expose the short inline-comment mapping")
  assert(vim.fn.maparg(effective_defaults.inline_comment, "x", false, true).desc == "Add inline PR comment for selection",
    "Virtual diff buffer should expose the short visual inline-comment mapping")
  assert(vim.fn.maparg(effective_defaults.toggle_comments_panel, "n", false, true).desc == "Toggle diff comments panel",
    "Virtual diff buffer should expose the short comments-panel mapping")
  assert(vim.fn.maparg(effective_defaults.toggle_changes_panel, "n", false, true).desc == "Toggle diff changes panel",
    "Virtual diff buffer should expose the short changes-panel mapping")
  assert(vim.fn.maparg(effective_defaults.line_comments_popup, "n", false, true).desc == "Show line comments popup",
    "Virtual diff buffer should expose the line-comments popup mapping")
  assert(vim.fn.maparg("<CR>", "n", false, true).desc == "Open line comments on commented lines",
    "Virtual diff buffer should expose the <CR> line-comments mapping")
  assert(vim.fn.maparg(legacy_defaults.help, "n") == ""
      and vim.fn.maparg(legacy_defaults.close_quick, "n") == ""
      and vim.fn.maparg(legacy_defaults.inline_comment, "n") == ""
      and vim.fn.maparg(legacy_defaults.inline_comment, "x") == ""
      and vim.fn.maparg(legacy_defaults.toggle_comments_panel, "n") == "",
    "Virtual diff buffer should remove legacy d-prefixed and ic/is/dc mappings")

  package.loaded["codediff.config"] = {
    options = {
      diff = {
        compute_moves = true,
      },
      keymaps = {
        view = {
          quit = "q",
          show_help = "g?",
          toggle_layout = "t",
          next_hunk = "]c",
          prev_hunk = "[c",
          diff_get = "do",
          diff_put = "dp",
          open_in_prev_tab = "gf",
          align_move = "gm",
        },
      },
    },
  }

  local codediff_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(codediff_buf)
  vim.b[codediff_buf].gh_pr_file_kind = "head"
  vim.b[codediff_buf].gh_pr_file_mode = "diff_pair"
  vim.b[codediff_buf].gh_pr_diff_backend = "codediff"
  vim.b[codediff_buf].gh_pr_codediff_layout = "side-by-side"
  vim.b[codediff_buf].gh_pr_number = 22
  vim.b[codediff_buf].gh_pr_path = "lua/gh-pr/actions.lua"
  action_helpers.apply_codediff_buffer_keymaps(codediff_buf)

  assert(vim.fn.maparg(effective_defaults.help, "n", false, true).desc == "GH PR: show diff shortcuts",
    "codediff buffer should expose the short gh-pr help mapping")
  assert(vim.fn.maparg(effective_defaults.close_quick, "n", false, true).desc == "GH PR: quick close",
    "codediff buffer should expose the short gh-pr quick-close mapping")
  assert(vim.fn.maparg(effective_defaults.toggle_changes_panel, "n", false, true).desc == "GH PR: toggle changes panel",
    "codediff buffer should expose the short gh-pr changes-panel mapping")
  assert(vim.fn.maparg("q", "n") == "" and vim.fn.maparg("g?", "n") == "",
    "gh-pr should not override native codediff q/g? mappings")

  local codediff_lines = table.concat(action_helpers.diff_shortcut_lines(codediff_buf), "\n")
  assert(codediff_lines:find("codediff native", 1, true) ~= nil,
    "codediff help should include a native codediff section")
  assert(codediff_lines:find("Toggle codediff layout (side-by-side <-> inline)", 1, true) ~= nil,
    "codediff help should mention the native t layout toggle")
  assert(codediff_lines:find("Horizontal split remains available only in the gh-pr virtual backend", 1, true) ~= nil,
    "codediff help should explain that horizontal layout stays virtual-only")

  local virtual_lines = table.concat(action_helpers.diff_shortcut_lines(virtual_buf), "\n")
  assert(virtual_lines:find("codediff native", 1, true) == nil,
    "Virtual diff help should not include the codediff-native section")
  assert(virtual_lines:find("Show line comments popup", 1, true) ~= nil
      and virtual_lines:find("Not available in unified mode", 1, true) == nil,
    "Virtual diff help should advertise line comments without the old unified restriction")

  local unified_virtual_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(unified_virtual_buf)
  vim.b[unified_virtual_buf].gh_pr_file_kind = "unified"
  vim.b[unified_virtual_buf].gh_pr_file_mode = "unified"
  vim.b[unified_virtual_buf].gh_pr_diff_backend = "virtual"
  vim.b[unified_virtual_buf].gh_pr_number = 12
  vim.b[unified_virtual_buf].gh_pr_path = "lua/gh-pr/actions.lua"
  virtual_helpers.set_pr_buffer_keymaps(unified_virtual_buf, {
    is_non_text = false,
  })
  assert(vim.fn.maparg(effective_defaults.line_comments_popup, "n", false, true).desc == "Show line comments popup",
    "Virtual unified buffer should expose the line-comments popup mapping")
  assert(vim.fn.maparg("<CR>", "n", false, true).desc == "Open line comments on commented lines",
    "Virtual unified buffer should expose the <CR> line-comments mapping")

  config_mod.setup({
    diff_view = {
      shortcuts = {
        close_quick = "q",
        help = "g?",
      },
    },
  })

  local codediff_conflict_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(codediff_conflict_buf)
  vim.b[codediff_conflict_buf].gh_pr_file_kind = "head"
  vim.b[codediff_conflict_buf].gh_pr_file_mode = "diff_pair"
  vim.b[codediff_conflict_buf].gh_pr_diff_backend = "codediff"
  vim.b[codediff_conflict_buf].gh_pr_codediff_layout = "side-by-side"
  action_helpers.apply_codediff_buffer_keymaps(codediff_conflict_buf)

  assert(vim.fn.maparg("q", "n") == "" and vim.fn.maparg("g?", "n") == "",
    "codediff-owned keys should remain unmapped by gh-pr even when configured explicitly")

  package.loaded["codediff.config"] = original_codediff_config
  config_mod.setup({
    diff_view = {
      shortcuts = {
        cycle_whitespace_mode = "<localleader>dw",
      },
    },
  })
end

do
  local config_mod = require("gh-pr.config")
  local comment_popup = require("gh-pr.comment_popup")
  local line_comments = require("gh-pr.line_comments")
  local actions = require("gh-pr.actions")
  local virtual_files = require("gh-pr.virtual_files")
  local action_helpers = actions._diff_view_helpers or {}
  local virtual_helpers = virtual_files._diff_view_helpers or {}

  config_mod.setup({
    line_comments = {
      enabled = true,
      keymap = "K",
      indicator_style = "sign_and_virtual_text",
      virtual_text = {
        enabled = true,
        show_authors = true,
      },
    },
  })

  local original_tab = vim.api.nvim_get_current_tabpage()
  local original_win = vim.api.nvim_get_current_win()
  local original_buf = vim.api.nvim_get_current_buf()
  vim.cmd("tabnew")
  local smoke_tab = vim.api.nvim_get_current_tabpage()
  local smoke_win = vim.api.nvim_get_current_win()

  local file_path = "lua/gh-pr/actions.lua"
  local comment_ctx = {
    index = {
      [file_path] = {
        base = {
          [2] = {
            {
              thread_id = "tb",
              comment_id = "cb",
              author = "base-user",
              body = "base comment",
              created_at = "2026-03-09T10:00:00Z",
              diff_side = "LEFT",
              original_line = 2,
            },
          },
        },
        head = {
          [2] = {
            {
              thread_id = "th",
              comment_id = "ch",
              author = "head-user",
              body = "head comment",
              created_at = "2026-03-09T10:01:00Z",
              diff_side = "RIGHT",
              line = 2,
            },
          },
          [3] = {
            {
              thread_id = "th2",
              comment_id = "ch2",
              author = "head-range",
              body = "head added line",
              created_at = "2026-03-09T10:02:00Z",
              diff_side = "RIGHT",
              line = 3,
            },
          },
        },
      },
    },
    side = "head",
    alternate_paths = {},
    keymap = "K",
    signs = {},
    max_popup_width = 90,
    max_popup_height = 18,
  }

  local original_codediff_lifecycle = package.loaded["codediff.ui.lifecycle"]
  local ok, err = pcall(function()
    local unified_render_map = virtual_helpers.build_unified_comment_line_map(comment_ctx, file_path, {
      [1] = { kind = "context", base_line = 2, head_line = 2 },
      [2] = { kind = "add", head_line = 3 },
    })
    assert(type(unified_render_map) == "table" and type(unified_render_map[1]) == "table" and #unified_render_map[1] == 2,
      "Virtual unified comment map should merge base/head comments on the same visible line")
    assert(type(unified_render_map[2]) == "table" and #unified_render_map[2] == 1,
      "Virtual unified comment map should preserve added-line head comments")

    local unified_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(unified_buf)
    vim.api.nvim_buf_set_lines(unified_buf, 0, -1, false, {
      "  shared context",
      "+ added line",
    })
    vim.b[unified_buf].gh_pr_file_kind = "unified"
    vim.b[unified_buf].gh_pr_number = 88
    vim.b[unified_buf].gh_pr_path = file_path
    line_comments.attach_to_buffer(unified_buf, {
      side = "head",
      render_line_map = unified_render_map,
      keymap = "K",
    })
    assert(type(vim.b[unified_buf].gh_pr_line_comments[1]) == "table" and #vim.b[unified_buf].gh_pr_line_comments[1] == 2,
      "Unified buffer should keep merged base/head comments on the visible context line")
    assert(line_comments.show_at_line(unified_buf, 1, { notify_empty = false }) == true,
      "Unified buffer should open the line comments popup")
    local unified_popup_buf = vim.api.nvim_get_current_buf()
    local unified_popup_lines = table.concat(vim.api.nvim_buf_get_lines(unified_popup_buf, 0, -1, false), "\n")
    assert(unified_popup_lines:find("B %[OPEN%] @base%-user %- 2026%-03%-09T10:00:00Z") ~= nil
        and unified_popup_lines:find("H %[OPEN%] @head%-user %- 2026%-03%-09T10:01:00Z") ~= nil,
      "Unified popup should distinguish base and head comments on the same visible line")
    comment_popup.close_for_origin(unified_buf, "line")

    local inline_base_buf = vim.api.nvim_create_buf(false, true)
    local inline_head_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(inline_base_buf, 0, -1, false, { "keep", "old", "tail" })
    vim.api.nvim_buf_set_lines(inline_head_buf, 0, -1, false, { "keep", "new", "tail" })

    local inline_render_map = action_helpers.build_codediff_inline_comment_line_map({
      base_buf = inline_base_buf,
      head_buf = inline_head_buf,
      diff_result = {
        changes = {
          {
            original = { start_line = 2, end_line = 3 },
            modified = { start_line = 2, end_line = 3 },
          },
        },
      },
    }, comment_ctx, file_path, file_path, {})
    assert(type(inline_render_map) == "table" and type(inline_render_map[2]) == "table" and #inline_render_map[2] == 2,
      "codediff inline comment map should project base/head comments onto the visible modified line")

    local rehydrate_session = {
      original_bufnr = inline_base_buf,
      modified_bufnr = inline_head_buf,
      original_win = smoke_win,
      modified_win = smoke_win,
      layout = "inline",
      stored_diff_result = {
        changes = {
          {
            original = { start_line = 2, end_line = 3 },
            modified = { start_line = 2, end_line = 3 },
          },
        },
      },
    }
    package.loaded["codediff.ui.lifecycle"] = {
      get_session = function()
        return rehydrate_session
      end,
    }

    local pr = {
      number = 88,
    }
    local details = {
      files = {
        {
          path = file_path,
          filename = file_path,
        },
      },
    }
    action_helpers.apply_codediff_open_result_context(pr, details, details.files[1], {
      mode = "file",
      tabpage = smoke_tab,
      base_buf = vim.api.nvim_create_buf(false, true),
      head_buf = vim.api.nvim_create_buf(false, true),
      base_win = smoke_win,
      head_win = smoke_win,
      base_path = file_path,
      head_path = file_path,
      file_mode = "diff_pair",
      layout = "side-by-side",
    }, {
      comments_ctx = comment_ctx,
    })
    action_helpers.rehydrate_codediff_file_runtime(smoke_tab)
    assert(vim.b[inline_head_buf].gh_pr_file_kind == "unified" and vim.b[inline_head_buf].gh_pr_codediff_layout == "inline",
      "codediff rehydrate should refresh metadata when the session switches to inline layout")
    assert(type(vim.b[inline_head_buf].gh_pr_line_comments[2]) == "table" and #vim.b[inline_head_buf].gh_pr_line_comments[2] == 2,
      "codediff rehydrate should restore merged inline comments on the visible modified line")
    assert(line_comments.show_at_line(inline_head_buf, 2, { notify_empty = false }) == true,
      "codediff inline buffer should open the line comments popup after rehydrate")
    local inline_popup_buf = vim.api.nvim_get_current_buf()
    local inline_popup_lines = table.concat(vim.api.nvim_buf_get_lines(inline_popup_buf, 0, -1, false), "\n")
    assert(inline_popup_lines:find("B %[OPEN%] @base%-user %- 2026%-03%-09T10:00:00Z") ~= nil
        and inline_popup_lines:find("H %[OPEN%] @head%-user %- 2026%-03%-09T10:01:00Z") ~= nil,
      "codediff inline popup should distinguish base and head comments after rehydrate")
    comment_popup.close_for_origin(inline_head_buf, "line")
  end)

  package.loaded["codediff.ui.lifecycle"] = original_codediff_lifecycle
  if vim.api.nvim_tabpage_is_valid(smoke_tab) then
    pcall(vim.cmd, "tabclose!")
  end
  if vim.api.nvim_tabpage_is_valid(original_tab) then
    pcall(vim.api.nvim_set_current_tabpage, original_tab)
  end
  if vim.api.nvim_win_is_valid(original_win) then
    pcall(vim.api.nvim_set_current_win, original_win)
  end
  if vim.api.nvim_buf_is_valid(original_buf) then
    pcall(vim.api.nvim_set_current_buf, original_buf)
  end
  assert(ok, err)
end

do
  local pr_service = require("gh-pr.pr_service")
  local gh = require("gh-pr.gh")
  local original_run = gh.run
  local original_run_json = gh.run_json
  local original_resolve = pr_service.resolve_repository
  local rest_args = nil

  gh.run = function(args)
    rest_args = vim.deepcopy(args)
    return "", nil
  end

  pr_service.resolve_repository = function()
    return {
      owner = "Middle-Sea",
      name = "MSBA-MSBA-test",
      full_name = "Middle-Sea/MSBA-MSBA-test",
    }, nil
  end

  local ok, err = pr_service.delete_review_comment({
    comment_id = "gid://review-comment",
    comment_database_id = 2892208391,
  })
  assert(ok == true and err == nil, "Delete review comment should use REST when database_id is present")
  assert(rest_args and rest_args[1] == "api" and rest_args[2] == "-X" and rest_args[3] == "DELETE"
      and rest_args[4] == "repos/Middle-Sea/MSBA-MSBA-test/pulls/comments/2892208391",
    "Delete review comment should target the pull comment REST endpoint")

  local gql_args = nil
  gh.run_json = function(args)
    gql_args = vim.deepcopy(args)
    return {
      data = {
        deletePullRequestReviewComment = {
          pullRequestReviewComment = { id = "gid://review-comment" },
        },
      },
    }, nil
  end

  ok, err = pr_service.delete_review_comment("gid://review-comment")
  assert(ok == true and err == nil, "Delete review comment should keep GraphQL fallback")
  assert(type(gql_args) == "table" and table.concat(gql_args, " "):find("deletePullRequestReviewComment", 1, true) ~= nil,
    "Delete review comment fallback should call the GraphQL mutation")

  gh.run = original_run
  gh.run_json = original_run_json
  pr_service.resolve_repository = original_resolve

  local drafts = require("gh-pr.neotree.review_sections.drafts")
  local nodes = drafts.build_nodes({ number = 42 }, {
    pending_review_loaded = true,
    pending_review_comments = {
      {
        id = "c1",
        thread_id = "t1",
        path = "lua/gh-pr/actions.lua",
        thread_path = "lua/gh-pr/actions.lua",
        line = 10,
        original_line = 10,
        thread_line = 10,
        thread_original_line = 10,
        body = "draft body",
        author = "reviewer",
        created_at = "2026-03-07T00:00:00Z",
        state = "PENDING",
      },
    },
  })
  assert(type(nodes) == "table" and nodes[1] and nodes[1].type == "comment_file",
    "Drafts section should group by file")
  assert(type(nodes[1].children) == "table" and nodes[1].children[1]
      and nodes[1].children[1].extra.kind == "comment_thread",
    "Drafts section should group by thread")
  assert(type(nodes[1].children[1].children) == "table" and nodes[1].children[1].children[1]
      and nodes[1].children[1].children[1].extra.kind == "comment_thread_item",
    "Drafts section should expose draft comments as navigable items")

  local actions = require("gh-pr.actions")
  local called = nil
  local original = actions.open_thread_comment_evolution_diff
  actions.open_thread_comment_evolution_diff = function(payload, opts)
    called = { payload = payload, opts = opts }
    return true
  end
  actions.open_overview_thread_workspace({
    pr_number = 123,
    path = "lua/gh-pr/actions.lua",
    comment_commit_oid = "abc",
  }, { new_tab = false })
  assert(called and called.payload and called.payload.path == "lua/gh-pr/actions.lua",
    "Overview thread action must delegate to evolution diff")
  actions.open_thread_comment_evolution_diff = original
end

do
  local config_mod = require("gh-pr.config")
  local state = require("gh-pr.state")
  local actions = require("gh-pr.actions")
  local codediff = require("gh-pr.integrations.codediff")
  local pr_service = require("gh-pr.pr_service")
  local repo_mod = require("gh-pr.repo")
  local virtual_files = require("gh-pr.virtual_files")
  local helpers = actions._diff_view_helpers or {}

  assert(type(helpers.resolve_requested_file_diff_backend) == "function",
    "Missing diff backend routing helper")

  config_mod.setup({
    line_comments = { enabled = false },
    diff_view = {
      comments_panel = { enabled = false },
      ignore_whitespace_mode = "none",
    },
  })

  local original_panel = package.loaded["gh-pr.diff_comments_panel"]
  package.loaded["gh-pr.diff_comments_panel"] = { sync_for_diff = function() end }

  local original_pr_explorer = codediff.open_pr_explorer_diff
  local original_codediff = codediff.open_pr_file_diff
  local original_virtual = virtual_files.open_diff
  local original_git_root = repo_mod.git_root
  local original_current_branch = repo_mod.current_branch
  local original_resolve_repository = repo_mod.resolve_repository
  local original_get_current_user_login = pr_service.get_current_user_login
  local calls = {}

  local last_open_result = nil
  local tmp_root = vim.fn.tempname()
  local local_file = tmp_root .. "/lua/gh-pr/actions.lua"
  vim.fn.mkdir(tmp_root .. "/lua/gh-pr", "p")
  vim.fn.writefile({ "local editable_head = true" }, local_file)

  local function make_open_result(opts)
    local base = vim.api.nvim_create_buf(false, true)
    local head = vim.api.nvim_create_buf(false, true)
    last_open_result = {
      mode = "file",
      base_buf = base,
      head_buf = head,
      base_win = vim.api.nvim_get_current_win(),
      head_win = vim.api.nvim_get_current_win(),
      base_path = "lua/gh-pr/actions.lua",
      head_path = "lua/gh-pr/actions.lua",
      file_mode = "diff_pair",
      layout = opts.layout == "unified" and "inline" or "side-by-side",
    }
    return last_open_result
  end

  codediff.open_pr_explorer_diff = function(opts)
    calls[#calls + 1] = { "pr_explorer", vim.deepcopy(opts) }
    local opened = {
      mode = "directory",
      tabpage = vim.api.nvim_get_current_tabpage(),
      layout = opts.layout == "unified" and "inline" or "side-by-side",
    }
    local selected_file = type(opts.file) == "table" and opts.file or {
      path = "lua/gh-pr/actions.lua",
      filename = "lua/gh-pr/actions.lua",
    }
    local selection_result = make_open_result(opts)
    if type(opts.on_selection) == "function" then
      opts.on_selection(selected_file, selection_result)
    end
    return opened, nil
  end

  codediff.open_pr_file_diff = function(opts)
    calls[#calls + 1] = { "codediff_file", vim.deepcopy(opts) }
    return make_open_result(opts), nil
  end

  virtual_files.open_diff = function(_, _, _, opts)
    calls[#calls + 1] = { "virtual", vim.deepcopy(opts) }
    return {
      base_buf = vim.api.nvim_get_current_buf(),
      head_buf = vim.api.nvim_get_current_buf(),
      mode = opts.view_mode or "vertical",
      file_mode = "diff_pair",
    }, nil
  end

  local pr = {
    number = 77,
    baseRefName = "main",
    headRefName = "feature",
    files = {
      {
        path = "lua/gh-pr/actions.lua",
        filename = "lua/gh-pr/actions.lua",
        patch = "@@ -1 +1 @@",
      },
    },
  }
  state.set_active_pr(pr, pr)
  state.set_diff_view_prefs({
    mode = "unified",
    ignore_whitespace_mode = "trim",
    render_whitespace = false,
    render_endlines = true,
  })

  assert(actions.open_diff(pr.files[1], { view_mode = "vertical", ignore_whitespace_mode = "none" }) == true,
    "Vertical+none PR file diff should open")
  assert(calls[1] and calls[1][1] == "pr_explorer",
    "Vertical+none PR file diff should prefer the PR codediff explorer")
  assert(calls[1][2].layout == "vertical" and calls[1][2].ignore_trim_whitespace ~= true,
    "Vertical+none PR file diff should open the PR codediff explorer side-by-side without trim ignore")
  local prefs_after_one_shot_open = state.get_diff_view_prefs()
  assert(prefs_after_one_shot_open.mode == "unified"
      and prefs_after_one_shot_open.ignore_whitespace_mode == "trim"
      and prefs_after_one_shot_open.render_whitespace == false
      and prefs_after_one_shot_open.render_endlines == true,
    "Per-open diff overrides should not persist to state.json")

  calls = {}
  assert(actions.open_diff(pr.files[1], { view_mode = "horizontal", ignore_whitespace_mode = "none" }) == true,
    "Horizontal PR file diff should open")
  assert(calls[1] and calls[1][1] == "virtual",
    "Horizontal PR file diff should use virtual backend")

  calls = {}
  assert(actions.open_diff(pr.files[1], { view_mode = "unified", ignore_whitespace_mode = "none" }) == true,
    "Unified PR file diff should open")
  assert(calls[1] and calls[1][1] == "pr_explorer",
    "Unified PR file diff should prefer the PR codediff explorer inline")
  assert(calls[1][2].layout == "unified" and calls[1][2].ignore_trim_whitespace ~= true,
    "Unified+none should pass unified layout without trim ignore")
  assert(last_open_result and vim.b[last_open_result.head_buf].gh_pr_file_kind == "unified"
      and vim.b[last_open_result.head_buf].gh_pr_codediff_layout == "inline",
    "Codediff unified head buffer should expose unified inline metadata")

  calls = {}
  assert(actions.open_diff(pr.files[1], { view_mode = "vertical", ignore_whitespace_mode = "trim" }) == true,
    "Trim-whitespace PR file diff should open")
  assert(calls[1] and calls[1][1] == "pr_explorer",
    "Trim-whitespace PR file diff should use the PR codediff explorer")
  assert(calls[1][2].layout == "vertical" and calls[1][2].ignore_trim_whitespace == true,
    "Vertical+trim should pass trim ignore to codediff")

  calls = {}
  assert(actions.open_diff(pr.files[1], { view_mode = "unified", ignore_whitespace_mode = "trim" }) == true,
    "Unified+trim PR file diff should open")
  assert(calls[1] and calls[1][1] == "pr_explorer",
    "Unified+trim PR file diff should use the PR codediff explorer")
  assert(calls[1][2].layout == "unified" and calls[1][2].ignore_trim_whitespace == true,
    "Unified+trim should pass inline layout and trim ignore to codediff")

  calls = {}
  assert(actions.open_diff(pr.files[1], { view_mode = "vertical", ignore_whitespace_mode = "eol" }) == true,
    "EOL-whitespace PR file diff should open")
  assert(calls[1] and calls[1][1] == "virtual",
    "EOL-whitespace PR file diff should use virtual backend")

  calls = {}
  assert(actions.open_diff(pr.files[1], { view_mode = "vertical", ignore_whitespace_mode = "blank_lines" }) == true,
    "Blank-lines PR file diff should open")
  assert(calls[1] and calls[1][1] == "virtual",
    "Blank-lines PR file diff should use virtual backend")

  repo_mod.git_root = function()
    return tmp_root, nil
  end
  repo_mod.current_branch = function()
    return "feature", nil
  end
  repo_mod.resolve_repository = function()
    return {
      owner = "owner",
      name = "repo",
      full_name = "owner/repo",
    }, nil
  end
  pr_service.get_current_user_login = function()
    return "me", nil
  end

  local review_source_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value("filetype", "neo-tree", { buf = review_source_buf })
  vim.b[review_source_buf].neo_tree_source = "gh_pr_review"
  vim.api.nvim_set_current_buf(review_source_buf)

  local own_review_pr = vim.deepcopy(pr)
  own_review_pr.author = { login = "me" }
  own_review_pr.headRepository = { nameWithOwner = "owner/repo" }
  own_review_pr.files[1].status = "modified"
  state.set_active_pr(own_review_pr, own_review_pr)

  calls = {}
  assert(actions.open_diff(own_review_pr.files[1], { view_mode = "vertical", ignore_whitespace_mode = "none" }) == true,
    "Own PR Review branch diff should open")
  assert(calls[1] and calls[1][1] == "codediff_file",
    "Own PR Review branch diff should bypass directory explorer for editable local head")
  assert(calls[1][2].local_head_path == local_file,
    "Own PR Review branch diff should pass local worktree head path")
  assert(calls[1][2].source_name == "gh_pr_review",
    "Own PR Review branch diff should preserve PR Review source metadata")

  repo_mod.current_branch = function()
    return "feature/other", nil
  end
  calls = {}
  assert(actions.open_diff(own_review_pr.files[1], { view_mode = "vertical", ignore_whitespace_mode = "none" }) == true,
    "Own PR Review diff on another branch should still open")
  assert(calls[1] and calls[1][1] == "pr_explorer",
    "Own PR Review diff on another branch should keep remote PR explorer")

  repo_mod.current_branch = function()
    return "feature", nil
  end
  local foreign_review_pr = vim.deepcopy(own_review_pr)
  foreign_review_pr.author = { login = "other" }
  state.set_active_pr(foreign_review_pr, foreign_review_pr)
  calls = {}
  assert(actions.open_diff(foreign_review_pr.files[1], { view_mode = "vertical", ignore_whitespace_mode = "none" }) == true,
    "Foreign PR Review branch diff should still open")
  assert(calls[1] and calls[1][1] == "pr_explorer",
    "Foreign PR Review branch diff must not use editable local head")

  own_review_pr.files[1].status = "removed"
  state.set_active_pr(own_review_pr, own_review_pr)
  calls = {}
  assert(actions.open_diff(own_review_pr.files[1], { view_mode = "vertical", ignore_whitespace_mode = "none" }) == true,
    "Removed own PR Review file should still open")
  assert(calls[1] and calls[1][1] == "pr_explorer",
    "Removed own PR Review file should not use local editable head")

  state.set_active_pr(pr, pr)

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(buf)
  vim.b[buf].gh_pr_file_kind = "head"
  vim.b[buf].gh_pr_number = 77
  vim.b[buf].gh_pr_path = "lua/gh-pr/actions.lua"
  vim.b[buf].gh_pr_file_path = "lua/gh-pr/actions.lua"
  vim.b[buf].gh_pr_file_mode = "diff_pair"
  vim.b[buf].gh_pr_diff_backend = "codediff"
  vim.b[buf].gh_pr_codediff_layout = "side-by-side"

  state.set_diff_view_prefs({
    mode = "vertical",
    ignore_whitespace_mode = "none",
    render_whitespace = true,
    render_endlines = false,
  })
  calls = {}
  actions.toggle_diff_whitespace()
  assert(calls[1] and calls[1][1] == "pr_explorer",
    "Toggling whitespace from strict should rerender with the PR codediff explorer when trim is supported")
  assert(calls[1][2].ignore_trim_whitespace == true,
    "Whitespace toggle should pass trim ignore to codediff")
  assert(state.get_diff_view_prefs().ignore_whitespace_mode == "trim",
    "Toggle whitespace should persist trim mode")

  state.set_diff_view_prefs({
    mode = "vertical",
    ignore_whitespace_mode = "trim",
    render_whitespace = true,
    render_endlines = false,
  })
  calls = {}
  actions.set_diff_view_mode("horizontal")
  assert(calls[1] and calls[1][1] == "virtual",
    "Switching to horizontal should rerender with virtual backend")

  state.set_diff_view_prefs({
    mode = "horizontal",
    ignore_whitespace_mode = "none",
    render_whitespace = true,
    render_endlines = false,
  })
  calls = {}
  actions.set_diff_view_mode("unified")
  assert(calls[1] and calls[1][1] == "pr_explorer",
    "Returning to unified+none should rerender with the PR codediff explorer")
  assert(calls[1][2].layout == "unified",
    "Returning to codediff should pass unified layout")

  codediff.open_pr_explorer_diff = original_pr_explorer
  codediff.open_pr_file_diff = original_codediff
  virtual_files.open_diff = original_virtual
  repo_mod.git_root = original_git_root
  repo_mod.current_branch = original_current_branch
  repo_mod.resolve_repository = original_resolve_repository
  pr_service.get_current_user_login = original_get_current_user_login
  vim.fn.delete(tmp_root, "rf")
  package.loaded["gh-pr.diff_comments_panel"] = original_panel
end

do
  local codediff = require("gh-pr.integrations.codediff")
  local virtual_files = require("gh-pr.virtual_files")

  local original_remote_pair_loader = virtual_files.load_remote_file_pair
  local original_remote_pair_loader_async = virtual_files.load_remote_file_pair_async
  local created_codediff_command = false
  if vim.fn.exists(":CodeDiff") ~= 2 then
    vim.api.nvim_create_user_command("CodeDiff", function() end, {})
    created_codediff_command = true
  end

  local sync_loads = 0
  local async_loads = 0
  virtual_files.load_remote_file_pair = function()
    sync_loads = sync_loads + 1
    return nil, "sync loader should not be used"
  end
  virtual_files.load_remote_file_pair_async = function(_, file, callback)
    async_loads = async_loads + 1
    vim.defer_fn(function()
      local path = file.path or file.filename
      callback({
        status = file.status or "modified",
        file_mode = file.status == "added" and "added_single" or "diff_pair",
        base_path = path,
        head_path = path,
        base_content = "base " .. path .. "\n",
        head_content = "head " .. path .. "\n",
      }, nil)
    end, 10)
  end

  local details = {
    baseRefName = "main",
    headRefName = "feature/async",
    files = {
      { path = "async/a.lua", filename = "async/a.lua", status = "modified" },
      { path = "async/b.lua", filename = "async/b.lua", status = "added" },
      { path = "async/c.lua", filename = "async/c.lua", status = "modified" },
    },
  }

  local not_ready = codediff.open_pr_explorer_diff({
    pr_number = 991,
    details = details,
    files = details.files,
    file = details.files[1],
    only_if_cached = true,
  })
  assert(not_ready == nil, "Cold PR explorer only_if_cached open should not build synchronously")
  assert(sync_loads == 0, "Cold PR explorer only_if_cached open must not call sync remote loader")

  local completed = false
  codediff.prepare_directory_snapshot_async({
    details = details,
    files = details.files,
    target_path = details.files[1].path,
    cache_scope = "async-smoke-991",
  }, function() end, function(prepared, err)
    assert(prepared ~= nil, err or "Async codediff snapshot should complete")
    assert(prepared.included == 3, "Async codediff snapshot should include all textual files")
    completed = true
  end)

  assert(completed == false, "Async codediff snapshot should not complete before yielding")
  assert(sync_loads == 0, "Async codediff snapshot must not call sync remote loader")

  vim.wait(500, function()
    return completed
  end)
  assert(completed == true, "Async codediff snapshot did not complete")
  assert(async_loads == 3, "Async codediff snapshot should load files through async loader")
  assert(sync_loads == 0, "Async codediff snapshot should keep sync loader unused")

  virtual_files.load_remote_file_pair = original_remote_pair_loader
  virtual_files.load_remote_file_pair_async = original_remote_pair_loader_async
  if created_codediff_command then
    pcall(vim.api.nvim_del_user_command, "CodeDiff")
  end
end

do
  local codediff = require("gh-pr.integrations.codediff")
  local virtual_files = require("gh-pr.virtual_files")

  local original_remote_pair_loader = virtual_files.load_remote_file_pair
  local original_codediff_config = package.loaded["codediff.config"]
  local original_codediff_view = package.loaded["codediff.ui.view"]
  local original_codediff_lifecycle = package.loaded["codediff.ui.lifecycle"]
  local original_codediff_dir = package.loaded["codediff.core.dir"]
  local original_side_by_side = package.loaded["codediff.ui.view.side_by_side"]
  local original_inline_view = package.loaded["codediff.ui.view.inline_view"]

  local created_codediff_command = false
  if vim.fn.exists(":CodeDiff") ~= 2 then
    vim.api.nvim_create_user_command("CodeDiff", function() end, {})
    created_codediff_command = true
  end

  local sessions = {}
  local explorers = {}
  local side_by_side_single_file_calls = {}
  local status_entries = {
    {
      path = "lua/new.lua",
      status = "A",
      group = "unstaged",
    },
    {
      path = "lua/other.lua",
      status = "A",
      group = "unstaged",
    },
  }

  local function build_file_content(prefix, total)
    local lines = {}
    for index = 1, total do
      lines[#lines + 1] = string.format("%s line %d", prefix, index)
    end
    return table.concat(lines, "\n") .. "\n"
  end

  local function ensure_modified_win(tabpage)
    local session = sessions[tabpage]
    local explorer = explorers[tabpage]
    if not session or not explorer then
      return nil
    end

    if type(session.modified_win) == "number"
      and session.modified_win > 0
      and vim.api.nvim_win_is_valid(session.modified_win)
      and session.modified_win ~= explorer.winid then
      return session.modified_win
    end

    pcall(vim.api.nvim_set_current_win, explorer.winid)
    vim.cmd("vsplit")
    session.modified_win = vim.api.nvim_get_current_win()
    return session.modified_win
  end

  local function mount_selected_file(tabpage, file_data, abs_path)
    local session = sessions[tabpage]
    local modified_win = ensure_modified_win(tabpage)
    local modified_bufnr = vim.fn.bufadd(abs_path)
    vim.fn.bufload(modified_bufnr)
    local original_bufnr = vim.api.nvim_create_buf(false, true)
    vim.bo[original_bufnr].buftype = "nofile"

    session.original_bufnr = original_bufnr
    session.modified_bufnr = modified_bufnr
    session.original_path = ""
    session.modified_path = abs_path
    session.original_revision = nil
    session.modified_revision = nil
    session.original_win = nil
    session.modified_win = modified_win

    vim.api.nvim_win_set_buf(modified_win, modified_bufnr)
    return {
      original_bufnr = original_bufnr,
      modified_bufnr = modified_bufnr,
      modified_win = modified_win,
      file_data = vim.deepcopy(file_data),
    }
  end

  package.loaded["codediff.config"] = {
    options = {
      diff = {
        layout = "side-by-side",
        ignore_trim_whitespace = false,
      },
    },
    setup = function(_) end,
  }

  package.loaded["codediff.ui.lifecycle"] = {
    get_session = function(tabpage)
      return sessions[tabpage]
    end,
    get_explorer = function(tabpage)
      return explorers[tabpage]
    end,
    update_layout = function(tabpage, layout)
      if sessions[tabpage] then
        sessions[tabpage].layout = layout
      end
      return true
    end,
    update_buffers = function(tabpage, original_bufnr, modified_bufnr)
      if sessions[tabpage] then
        sessions[tabpage].original_bufnr = original_bufnr
        sessions[tabpage].modified_bufnr = modified_bufnr
      end
      return true
    end,
    update_paths = function(tabpage, original_path, modified_path)
      if sessions[tabpage] then
        sessions[tabpage].original_path = original_path
        sessions[tabpage].modified_path = modified_path
      end
      return true
    end,
    update_revisions = function(tabpage, original_revision, modified_revision)
      if sessions[tabpage] then
        sessions[tabpage].original_revision = original_revision
        sessions[tabpage].modified_revision = modified_revision
      end
      return true
    end,
    update_diff_result = function(tabpage, diff_result)
      if sessions[tabpage] then
        sessions[tabpage].stored_diff_result = diff_result
      end
      return true
    end,
  }

  package.loaded["codediff.core.dir"] = {
    diff_directories = function(base_dir, head_dir)
      return {
        root1 = base_dir,
        root2 = head_dir,
        status_result = {
          conflicts = {},
          unstaged = vim.deepcopy(status_entries),
          staged = {},
        },
      }
    end,
  }

  package.loaded["codediff.ui.view.side_by_side"] = {
    show_untracked_file = function(tabpage, abs_path)
      side_by_side_single_file_calls[#side_by_side_single_file_calls + 1] = abs_path
      local current_selection = explorers[tabpage] and explorers[tabpage].current_selection or {
        path = "lua/new.lua",
        status = "A",
        group = "unstaged",
      }
      mount_selected_file(tabpage, current_selection, abs_path)
    end,
  }

  package.loaded["codediff.ui.view.inline_view"] = {
    show_single_file = function(tabpage, abs_path, opts)
      local load_bufnr = vim.fn.bufadd(abs_path)
      vim.fn.bufload(load_bufnr)
      local empty_buf = vim.api.nvim_create_buf(false, true)
      vim.bo[empty_buf].buftype = "nofile"

      local session = sessions[tabpage]
      session.original_bufnr = (opts and opts.side == "original") and load_bufnr or empty_buf
      session.modified_bufnr = (opts and opts.side == "original") and empty_buf or load_bufnr
      session.original_path = (opts and opts.side == "original") and abs_path or ""
      session.modified_path = (opts and opts.side == "original") and "" or abs_path
      session.original_revision = nil
      session.modified_revision = nil
      session.modified_win = session.modified_win or vim.api.nvim_get_current_win()
    end,
  }

  package.loaded["codediff.ui.view"] = {
    create = function(session_config)
      vim.cmd("tabnew")
      local tabpage = vim.api.nvim_get_current_tabpage()
      local winid = vim.api.nvim_get_current_win()
      local bufnr = vim.api.nvim_get_current_buf()

      sessions[tabpage] = {
        mode = "explorer",
        layout = session_config.layout or "side-by-side",
        original_bufnr = vim.api.nvim_create_buf(false, true),
        modified_bufnr = vim.api.nvim_create_buf(false, true),
        original_win = nil,
        modified_win = nil,
        root1 = session_config.original_path,
        root2 = session_config.modified_path,
        original_path = "",
        modified_path = "",
      }

      local selection = {
        path = session_config.explorer_data.focus_file or "lua/new.lua",
        status = "A",
        group = "unstaged",
      }

      local explorer = {
        bufnr = bufnr,
        winid = winid,
        tabpage = tabpage,
        status_result = session_config.explorer_data.status_result,
        current_selection = nil,
        current_file_path = nil,
        current_file_group = nil,
        tree = {
          get_node = function(_, line)
            local entry = status_entries[line]
            if entry then
              return {
                data = {
                  path = entry.path,
                  group = entry.group,
                },
              }
            end
            return nil
          end,
        },
      }

      explorer.clear_selection = function()
        explorer.current_selection = nil
        explorer.current_file_path = nil
        explorer.current_file_group = nil
      end

      explorer.on_file_select = function(file_data, _)
        explorer.current_selection = vim.deepcopy(file_data)
        explorer.current_file_path = file_data.path
        explorer.current_file_group = file_data.group

        local root2 = sessions[tabpage] and sessions[tabpage].root2 or ""
        local abs_path = vim.fs.joinpath(root2, file_data.path)
        mount_selected_file(tabpage, file_data, abs_path)
      end

      explorers[tabpage] = explorer

      vim.schedule(function()
        pcall(vim.api.nvim_win_set_cursor, winid, { 1, 0 })
        explorer.on_file_select(vim.deepcopy(selection), { force = true })
      end)
    end,
    toggle_layout = function()
      return true
    end,
  }

  virtual_files.load_remote_file_pair = function(_, file)
    local path = file.path or file.filename
    local head_content = path == "lua/other.lua"
        and build_file_content("other", 16)
      or build_file_content("new", 20)
    return {
      status = "added",
      file_mode = "added_single",
      base_path = path,
      head_path = path,
      base_content = "",
      head_content = head_content,
    }, nil
  end

  local selection_calls = {}
  local function record_selection(file, open_result)
    selection_calls[#selection_calls + 1] = {
      file = vim.deepcopy(file),
      open_result = vim.deepcopy(open_result),
    }

    if type(open_result) == "table" then
      if type(open_result.base_buf) == "number" and open_result.base_buf > 0 then
        vim.b[open_result.base_buf].gh_pr_path = file.path
        vim.b[open_result.base_buf].gh_pr_file_path = file.path
      end
      if type(open_result.head_buf) == "number" and open_result.head_buf > 0 then
        vim.b[open_result.head_buf].gh_pr_path = file.path
        vim.b[open_result.head_buf].gh_pr_file_path = file.path
      end
    end
  end

  local details = {
    baseRefName = "main",
    headRefName = "feature",
    files = {
      {
        path = "lua/new.lua",
        filename = "lua/new.lua",
        status = "added",
      },
      {
        path = "lua/other.lua",
        filename = "lua/other.lua",
        status = "added",
      },
    },
  }

  local opened, open_err = codediff.open_pr_explorer_diff({
    pr_number = 88,
    details = details,
    file = details.files[1],
    layout = "vertical",
    on_selection = record_selection,
  })
  assert(opened ~= nil, open_err or "PR explorer should open for added file smoke test")

  vim.wait(50)

  assert(#selection_calls == 0,
    "Opening the PR codediff explorer should not auto-select the focused file")

  local lifecycle = require("codediff.ui.lifecycle")
  local explorer = lifecycle.get_explorer(opened.tabpage)
  assert(type(explorer) == "table" and type(explorer.on_file_select) == "function",
    "PR explorer smoke test should expose the wrapped codediff explorer")

  local passive_calls_before = #selection_calls
  local passive_single_file_before = #side_by_side_single_file_calls
  explorer.on_file_select({
    path = "lua/new.lua",
    status = "A",
    group = "unstaged",
  }, { no_jump = true })

  vim.wait(50)

  assert(#selection_calls == passive_calls_before,
    "Passive PR explorer selection replay should not sync gh-pr")
  assert(#side_by_side_single_file_calls == passive_single_file_before,
    "Passive PR explorer selection replay should not trigger single-file rendering")

  explorer.on_file_select({
    path = "lua/new.lua",
    status = "A",
    group = "unstaged",
  }, { force = true })

  vim.wait(50, function()
    return #selection_calls == 1 and #side_by_side_single_file_calls == 1
  end)

  assert(#side_by_side_single_file_calls == 1,
    string.format(
      "Added PR explorer files should render as single-file content in side-by-side layout (got %d calls)",
      #side_by_side_single_file_calls
    ))
  assert(#selection_calls == 1 and selection_calls[1].open_result.file_mode == "added_single",
    "Added PR explorer selection should sync gh-pr as an added_single view")

  local active_session = lifecycle.get_session(opened.tabpage)
  assert(type(active_session) == "table" and vim.api.nvim_win_is_valid(active_session.modified_win),
    "PR explorer selection should expose a modified diff window")

  vim.api.nvim_set_current_win(active_session.modified_win)
  vim.api.nvim_win_set_cursor(active_session.modified_win, { 9, 0 })
  vim.api.nvim_set_current_win(explorer.winid)

  explorer.on_file_select({
    path = "lua/other.lua",
    status = "A",
    group = "unstaged",
  }, { force = true })

  vim.wait(50, function()
    return #selection_calls == 2
  end)

  active_session = lifecycle.get_session(opened.tabpage)
  assert(selection_calls[2].file.path == "lua/other.lua",
    "Selecting a second PR explorer file should sync gh-pr with that file")

  vim.api.nvim_set_current_win(active_session.modified_win)
  vim.api.nvim_win_set_cursor(active_session.modified_win, { 6, 0 })
  vim.api.nvim_set_current_win(explorer.winid)

  explorer.on_file_select({
    path = "lua/new.lua",
    status = "A",
    group = "unstaged",
  }, { force = true })

  vim.wait(50, function()
    return #selection_calls == 3
  end)

  active_session = lifecycle.get_session(opened.tabpage)
  local restored_cursor = vim.api.nvim_win_get_cursor(active_session.modified_win)
  assert(restored_cursor[1] == 9,
    "Re-selecting a visited PR explorer file should restore its previous modified-side line")

  vim.api.nvim_set_current_win(explorer.winid)
  explorer.on_file_select({
    path = "lua/other.lua",
    status = "A",
    group = "unstaged",
  }, { force = true })

  vim.wait(50, function()
    return #selection_calls == 4
  end)

  active_session = lifecycle.get_session(opened.tabpage)
  restored_cursor = vim.api.nvim_win_get_cursor(active_session.modified_win)
  assert(restored_cursor[1] == 6,
    "Each PR explorer file should keep its own remembered modified-side line")

  local reused_calls_before = #selection_calls
  local single_file_calls_before = #side_by_side_single_file_calls
  local reopened, reopen_err = codediff.open_pr_explorer_diff({
    pr_number = 88,
    details = details,
    file = details.files[1],
    layout = "vertical",
    on_selection = record_selection,
  })
  assert(reopened ~= nil, reopen_err or "PR explorer reuse smoke test should reopen the existing tab")

  vim.wait(50)

  assert(#selection_calls == reused_calls_before,
    "Reusing the PR codediff explorer should not auto-open the requested file")
  assert(#side_by_side_single_file_calls == single_file_calls_before,
    "Reusing the PR codediff explorer should not trigger single-file rendering until manual selection")

  virtual_files.load_remote_file_pair = original_remote_pair_loader
  package.loaded["codediff.config"] = original_codediff_config
  package.loaded["codediff.ui.view"] = original_codediff_view
  package.loaded["codediff.ui.lifecycle"] = original_codediff_lifecycle
  package.loaded["codediff.core.dir"] = original_codediff_dir
  package.loaded["codediff.ui.view.side_by_side"] = original_side_by_side
  package.loaded["codediff.ui.view.inline_view"] = original_inline_view

  if created_codediff_command then
    pcall(vim.api.nvim_del_user_command, "CodeDiff")
  end
end

do
  local config_mod = require("gh-pr.config")
  local panel = require("gh-pr.diff_comments_panel")
  local pr_service = require("gh-pr.pr_service")

  local original_tree_source = package.loaded["gh-pr.neotree.diff_comments_source"]
  local original_fetch_async = pr_service.fetch_review_threads_with_pending_async

  local pending_callback = nil

  local function find_panel_window()
    for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      local bufnr = vim.api.nvim_win_get_buf(winid)
      if vim.bo[bufnr].filetype == "gh_pr_diff_comments" then
        return winid, bufnr
      end
    end
    return nil, nil
  end

  package.loaded["gh-pr.neotree.diff_comments_source"] = {
    available = function()
      return false
    end,
  }

  pr_service.fetch_review_threads_with_pending_async = function(_, _, callback)
    pending_callback = callback
  end

  config_mod.setup({
    diff_view = {
      comments_panel = {
        enabled = true,
        auto_open = "always",
        follow_cursor = true,
      },
    },
  })

  vim.cmd("tabnew")
  local diff_buf = vim.api.nvim_get_current_buf()
  local diff_win = vim.api.nvim_get_current_win()
  vim.b[diff_buf].gh_pr_number = 501
  vim.b[diff_buf].gh_pr_file_kind = "head"
  vim.b[diff_buf].gh_pr_file_path = "lua/a.lua"
  vim.b[diff_buf].gh_pr_path = "lua/a.lua"

  local pr = { number = 501 }
  local details = {
    number = 501,
    files = {
      { path = "lua/a.lua", filename = "lua/a.lua" },
      { path = "lua/b.lua", filename = "lua/b.lua" },
    },
  }

  assert(panel.sync_for_diff({
    pr = pr,
    details = details,
    pr_number = 501,
    origin_win = diff_win,
    origin_buf = diff_buf,
    file_path = "lua/a.lua",
    file_kind = "head",
  }) == true, "Legacy diff comments panel should open for the active file")

  local panel_win, panel_buf = find_panel_window()
  assert(type(panel_win) == "number" and panel_win > 0 and panel_buf > 0,
    "Legacy diff comments panel should create a panel window")
  assert(vim.api.nvim_get_current_win() == diff_win,
    "Opening the legacy diff comments panel should keep focus in the diff window")

  local loading_lines = vim.api.nvim_buf_get_lines(panel_buf, 0, -1, false)
  assert(loading_lines[4] == "Loading comments for lua/a.lua...",
    "Legacy diff comments panel should render a loading message for the active file")
  local loading_marks = vim.api.nvim_buf_get_extmarks(panel_buf, -1, 0, -1, { details = true })
  local found_loading_highlight = false
  for _, mark in ipairs(loading_marks) do
    local row = mark[2]
    local details_mark = mark[4] or {}
    if row == 3 and details_mark.hl_group == "GhPrDiffCommentsMuted" then
      found_loading_highlight = true
      break
    end
  end
  assert(found_loading_highlight == true,
    "Legacy diff comments panel should mute the loading message line")

  pending_callback({
    {
      id = "thread-a",
      path = "lua/a.lua",
      line = 6,
      diffSide = "RIGHT",
      comments = {
        {
          id = "comment-a1",
          author = { login = "alice" },
          body = "first comment",
          createdAt = "2026-03-18T12:00:00Z",
          line = 6,
        },
      },
    },
  }, nil)

  vim.wait(50, function()
    local lines = vim.api.nvim_buf_get_lines(panel_buf, 0, -1, false)
    for _, line in ipairs(lines) do
      if line:find("@alice", 1, true) ~= nil then
        return true
      end
    end
    return false
  end)

  local comment_line = nil
  for index, line in ipairs(vim.api.nvim_buf_get_lines(panel_buf, 0, -1, false)) do
    if line:find("@alice", 1, true) ~= nil then
      comment_line = index
      break
    end
  end
  assert(type(comment_line) == "number" and comment_line > 0,
    "Legacy diff comments panel should render the fetched comment")

  local diff_cursor_before_follow = vim.api.nvim_win_get_cursor(diff_win)
  vim.api.nvim_set_current_win(panel_win)
  vim.api.nvim_win_set_cursor(panel_win, { comment_line, 0 })
  vim.api.nvim_exec_autocmds("CursorMoved", { buffer = panel_buf, modeline = false })
  assert(vim.api.nvim_get_current_win() == panel_win,
    "Moving inside the legacy diff comments panel should not steal focus away from the panel")
  assert(vim.deep_equal(vim.api.nvim_win_get_cursor(diff_win), diff_cursor_before_follow),
    "Moving inside the legacy diff comments panel should not move the diff cursor automatically")

  vim.api.nvim_set_current_win(diff_win)
  local diff_cursor_before_refresh = vim.api.nvim_win_get_cursor(diff_win)
  pending_callback = nil
  assert(panel.sync_for_diff({
    pr = pr,
    details = details,
    pr_number = 501,
    origin_win = diff_win,
    origin_buf = diff_buf,
    file_path = "lua/b.lua",
    file_kind = "head",
  }) == true, "Refreshing the legacy diff comments panel should keep the panel open")
  assert(vim.api.nvim_get_current_win() == diff_win,
    "Refreshing the legacy diff comments panel should not change the focused diff window")
  assert(panel.is_open_current_tab() == true,
    "Refreshing the legacy diff comments panel should keep it open")

  local refreshed_lines = vim.api.nvim_buf_get_lines(panel_buf, 0, -1, false)
  assert(refreshed_lines[4] == "Loading comments for lua/b.lua...",
    "Refreshing the legacy diff comments panel should immediately show loading for the new file")
  assert(vim.deep_equal(vim.api.nvim_win_get_cursor(diff_win), diff_cursor_before_refresh),
    "Refreshing the legacy diff comments panel should not move the diff cursor")

  panel.close_current_tab()
  pr_service.fetch_review_threads_with_pending_async = original_fetch_async
  package.loaded["gh-pr.neotree.diff_comments_source"] = original_tree_source
end

do
  local config_mod = require("gh-pr.config")
  local panel = require("gh-pr.diff_changes_panel")

  local function find_panel_window()
    for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      local bufnr = vim.api.nvim_win_get_buf(winid)
      if vim.bo[bufnr].filetype == "gh_pr_diff_changes" then
        return winid, bufnr
      end
    end
    return nil, nil
  end

  config_mod.setup({
    diff_view = {
      changes_panel = {
        enabled = true,
        auto_open = true,
        position = "right",
        width = 28,
        min_width = 20,
        max_width = 40,
      },
    },
  })

  vim.cmd("tabnew")
  local diff_buf = vim.api.nvim_get_current_buf()
  local diff_win = vim.api.nvim_get_current_win()
  vim.api.nvim_buf_set_lines(diff_buf, 0, -1, false, { "one", "two", "three", "four" })
  vim.b[diff_buf].gh_pr_number = 601
  vim.b[diff_buf].gh_pr_file_kind = "head"
  vim.b[diff_buf].gh_pr_file_path = "lua/changes.lua"
  vim.b[diff_buf].gh_pr_path = "lua/changes.lua"
  vim.b[diff_buf].gh_pr_diff_backend = "virtual"

  assert(panel.sync_for_diff({
    pr = { number = 601 },
    details = { number = 601 },
    pr_number = 601,
    origin_win = diff_win,
    origin_buf = diff_buf,
    file_path = "lua/changes.lua",
    file_kind = "head",
    hunks = {
      {
        index = 1,
        target_side = "head",
        target_line = 3,
        base_start = 3,
        head_start = 3,
        added = 2,
        deleted = 1,
      },
    },
  }) == true, "Diff changes panel should auto-open for navigable hunks")

  local panel_win, panel_buf = find_panel_window()
  assert(type(panel_win) == "number" and panel_win > 0 and type(panel_buf) == "number" and panel_buf > 0,
    "Diff changes panel should create a panel window")
  assert(vim.api.nvim_get_current_win() == diff_win,
    "Auto-opening the diff changes panel should keep focus in the diff window")
  assert(vim.bo[panel_buf].buftype == "nofile" and vim.bo[panel_buf].filetype == "gh_pr_diff_changes",
    "Diff changes panel should use nofile gh_pr_diff_changes buffers")
  local lines = vim.api.nvim_buf_get_lines(panel_buf, 0, -1, false)
  assert(lines[1] == "PR #601 changes" and lines[5]:find("+2", 1, true) ~= nil and lines[5]:find("-1", 1, true) ~= nil,
    "Diff changes panel should render PR/path header and hunk counts")

  vim.api.nvim_set_current_win(panel_win)
  vim.api.nvim_win_set_cursor(panel_win, { 5, 0 })
  local enter_map = vim.fn.maparg("<CR>", "n", false, true)
  assert(type(enter_map.callback) == "function", "Diff changes panel should map Enter")
  enter_map.callback()
  assert(vim.api.nvim_get_current_win() == diff_win and vim.api.nvim_win_get_cursor(diff_win)[1] == 3,
    "Pressing Enter in the diff changes panel should jump to the hunk")

  vim.api.nvim_set_current_win(panel_win)
  local close_map = vim.fn.maparg("q", "n", false, true)
  assert(type(close_map.callback) == "function", "Diff changes panel should map q")
  close_map.callback()
  assert(panel.is_open_current_tab() == false, "Closing the changes panel should remove the panel")

  assert(panel.sync_for_diff({
    pr = { number = 601 },
    details = { number = 601 },
    pr_number = 601,
    origin_win = diff_win,
    origin_buf = diff_buf,
    file_path = "lua/changes.lua",
    file_kind = "head",
    hunks = {
      { index = 1, target_side = "head", target_line = 2, added = 1, deleted = 0 },
    },
  }) == false, "Manual close should suppress later auto-open in the same tab")

  vim.api.nvim_set_current_win(diff_win)
  assert(panel.toggle({
    pr = { number = 601 },
    details = { number = 601 },
    pr_number = 601,
    origin_win = diff_win,
    origin_buf = diff_buf,
    file_path = "lua/changes.lua",
    file_kind = "head",
    hunks = {
      { index = 1, target_side = "head", target_line = 2, added = 1, deleted = 0 },
    },
  }) == true, "Manual toggle should reopen the changes panel")
  panel_win = find_panel_window()
  assert(vim.api.nvim_get_current_win() == panel_win,
    "Manual toggle should focus the diff changes panel")
  panel.close_current_tab()

  vim.api.nvim_set_current_win(diff_win)
  vim.b[diff_buf].gh_pr_is_non_text = true
  local non_text_opened = panel.sync_for_diff({
    pr = { number = 601 },
    details = { number = 601 },
    pr_number = 601,
    origin_win = diff_win,
    origin_buf = diff_buf,
    file_path = "lua/changes.lua",
    file_kind = "head",
    non_text = true,
    hunks = {
      { index = 1, target_side = "head", target_line = 2, added = 1, deleted = 0 },
    },
  })
  assert(non_text_opened == false and panel.is_open_current_tab() == false,
    "Non-text previews should not auto-open the diff changes panel")
  local toggled, toggle_err = panel.toggle({
    pr = { number = 601 },
    details = { number = 601 },
    pr_number = 601,
    origin_win = diff_win,
    origin_buf = diff_buf,
    file_path = "lua/changes.lua",
    file_kind = "head",
    non_text = true,
  })
  assert(toggled == nil and tostring(toggle_err):find("non%-text", 1) ~= nil,
    "Manual toggle on non-text previews should report that hunk navigation is unavailable")

  vim.b[diff_buf].gh_pr_is_non_text = false
  config_mod.setup({
    diff_view = {
      changes_panel = {
        enabled = false,
      },
    },
  })
  local disabled, disabled_err = panel.toggle({
    pr = { number = 601 },
    details = { number = 601 },
    pr_number = 601,
    origin_win = diff_win,
    origin_buf = diff_buf,
    file_path = "lua/changes.lua",
    file_kind = "head",
    hunks = {
      { index = 1, target_side = "head", target_line = 2, added = 1, deleted = 0 },
    },
  })
  assert(disabled == nil and tostring(disabled_err):find("disabled", 1, true) ~= nil,
    "Disabled diff changes panel config should block manual toggle")
end

do
  local config_mod = require("gh-pr.config")
  local pr_service = require("gh-pr.pr_service")

  local original_neotree_module = package.loaded["neo-tree"]
  local original_renderer = package.loaded["neo-tree.ui.renderer"]
  local original_integration = package.loaded["gh-pr.integrations.neotree"]
  local original_source = package.loaded["gh-pr.neotree.diff_comments_source"]
  local original_fetch_async = pr_service.fetch_review_threads_with_pending_async

  local open_source_calls = 0
  local close_source_calls = 0
  local pending_callback = nil
  local source_visible = false

  package.loaded["neo-tree"] = {}
  package.loaded["neo-tree.ui.renderer"] = {
    show_nodes = function(nodes, state)
      state.last_nodes = vim.deepcopy(nodes)
    end,
  }
  package.loaded["gh-pr.integrations.neotree"] = {
    is_source_visible = function()
      return source_visible
    end,
    open_source = function(_, _, _)
      open_source_calls = open_source_calls + 1
      return true
    end,
    close_source = function(_, _)
      close_source_calls = close_source_calls + 1
      return true
    end,
  }

  pr_service.fetch_review_threads_with_pending_async = function(_, _, callback)
    pending_callback = callback
  end

  package.loaded["gh-pr.neotree.diff_comments_source"] = nil
  local source = require("gh-pr.neotree.diff_comments_source")

  config_mod.setup({
    diff_view = {
      comments_panel = {
        enabled = true,
        auto_open = "always",
        follow_cursor = true,
      },
    },
  })

  vim.cmd("tabnew")
  local diff_buf = vim.api.nvim_get_current_buf()
  local diff_win = vim.api.nvim_get_current_win()
  vim.b[diff_buf].gh_pr_number = 777
  vim.b[diff_buf].gh_pr_file_kind = "head"
  vim.b[diff_buf].gh_pr_file_path = "lua/a.lua"
  vim.b[diff_buf].gh_pr_path = "lua/a.lua"

  local pr = { number = 777 }
  local details = {
    number = 777,
    files = {
      { path = "lua/a.lua", filename = "lua/a.lua" },
      { path = "lua/b.lua", filename = "lua/b.lua" },
    },
  }

  assert(source.sync_for_diff({
    pr = pr,
    details = details,
    pr_number = 777,
    origin_win = diff_win,
    origin_buf = diff_buf,
    file_path = "lua/a.lua",
    file_kind = "head",
  }) == true, "Neo-tree diff comments source should open when auto_open is always")
  assert(open_source_calls == 1,
    "Neo-tree diff comments source should open the source once for the initial file")

  vim.cmd("vsplit")
  local source_win = vim.api.nvim_get_current_win()
  local source_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(source_win, source_buf)
  vim.bo[source_buf].filetype = "neo-tree"
  vim.b[source_buf].neo_tree_source = "gh_pr_diff_comments"
  source_visible = true

  local state = {
    winid = source_win,
    path = vim.fn.getcwd(),
    tree = {
      get_node = function()
        return {
          id = "comment-node-1",
          extra = {
            kind = "comment",
            target = {
              path = "lua/a.lua",
              side = "head",
              line = 6,
            },
          },
        }
      end,
    },
  }

  source.navigate(state, vim.fn.getcwd())
  assert(type(state.last_nodes) == "table"
      and state.last_nodes[1]
      and state.last_nodes[1].children
      and state.last_nodes[1].children[1]
      and state.last_nodes[1].children[1].name == "Loading comments for lua/a.lua...",
    "Neo-tree diff comments source should render loading nodes for the initial file")

  local open_target_calls = 0
  local original_open_target = source.open_target
  source.open_target = function(...)
    open_target_calls = open_target_calls + 1
    return true
  end

  vim.api.nvim_set_current_win(source_win)
  vim.api.nvim_win_set_cursor(source_win, { 1, 0 })
  vim.api.nvim_exec_autocmds("CursorMoved", { buffer = source_buf, modeline = false })
  assert(open_target_calls == 0,
    "Moving inside the Neo-tree diff comments source should not auto-open or follow comment targets")

  vim.api.nvim_set_current_win(diff_win)
  local diff_cursor_before_refresh = vim.api.nvim_win_get_cursor(diff_win)
  pending_callback = nil
  assert(source.sync_for_diff({
    pr = pr,
    details = details,
    pr_number = 777,
    origin_win = diff_win,
    origin_buf = diff_buf,
    file_path = "lua/b.lua",
    file_kind = "head",
  }) == true, "Neo-tree diff comments source should refresh the visible source for the new file")
  assert(open_source_calls == 1 and close_source_calls == 0,
    "Refreshing the visible Neo-tree diff comments source should reuse the existing source window")
  assert(vim.api.nvim_get_current_win() == diff_win,
    "Refreshing the Neo-tree diff comments source should not change the focused diff window")
  assert(type(state.last_nodes) == "table"
      and state.last_nodes[1]
      and state.last_nodes[1].children
      and state.last_nodes[1].children[1]
      and state.last_nodes[1].children[1].name == "Loading comments for lua/b.lua...",
    "Refreshing the Neo-tree diff comments source should immediately show loading nodes for the new file")
  assert(vim.deep_equal(vim.api.nvim_win_get_cursor(diff_win), diff_cursor_before_refresh),
    "Refreshing the Neo-tree diff comments source should not move the diff cursor")

  source.open_target = original_open_target
  pr_service.fetch_review_threads_with_pending_async = original_fetch_async
  package.loaded["neo-tree"] = original_neotree_module
  package.loaded["neo-tree.ui.renderer"] = original_renderer
  package.loaded["gh-pr.integrations.neotree"] = original_integration
  package.loaded["gh-pr.neotree.diff_comments_source"] = original_source
end
