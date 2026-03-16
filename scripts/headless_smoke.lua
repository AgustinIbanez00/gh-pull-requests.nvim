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
  local comments_panel = cfg.diff_view.comments_panel or {}
  local non_text = cfg.diff_view.non_text or {}
  local pr_service = require("gh-pr.pr_service")
  local virtual_files = require("gh-pr.virtual_files")
  local actions = require("gh-pr.actions")
  local ok_annotations = pcall(require, "gh-pr.check_annotations")
  local ok_security_annotations = pcall(require, "gh-pr.security_annotations")
  local ok_security_section = pcall(require, "gh-pr.neotree.review_sections.security")

  assert(vim.fn.exists(":GhPrOpen") == 2, "Missing :GhPrOpen command")
  assert(vim.fn.exists(":GhPrReviewRefresh") == 2, "Missing :GhPrReviewRefresh command")
  assert(vim.fn.exists(":GhPRReviewRefresh") == 2, "Missing :GhPRReviewRefresh alias")
  assert(vim.fn.maparg("<Plug>(gh-pr-open)", "n") ~= "", "Missing <Plug>(gh-pr-open)")
  assert(vim.fn.maparg("<Plug>(gh-pr-review-refresh)", "n") ~= "", "Missing <Plug>(gh-pr-review-refresh)")
  assert(prefetch.enabled == true, "Missing diff_view.prefetch.enabled")
  assert(prefetch.concurrency == 2, "Missing diff_view.prefetch.concurrency")
  assert(prefetch.text_extensions[1] == "lua" and prefetch.text_extensions[2] == "md",
    "Missing diff_view.prefetch.text_extensions")
  assert(comments_panel.position == "bottom", "Missing diff_view.comments_panel.position default")
  assert(non_text.enabled == true, "Missing diff_view.non_text.enabled")
  assert(non_text.auto_preview == true, "Missing diff_view.non_text.auto_preview")
  assert(non_text.show_metadata == true, "Missing diff_view.non_text.show_metadata")
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
  assert(ok_annotations == true, "Missing gh-pr.check_annotations module")
  assert(ok_security_annotations == true, "Missing gh-pr.security_annotations module")
  assert(ok_security_section == true, "Missing gh-pr.neotree.review_sections.security module")

  local ok, health = pcall(require, "gh-pr.health")
  assert(ok and type(health.check) == "function", "Missing gh-pr health check entrypoint")
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
      and diff_shortcuts.defaults.toggle_comments_panel == "<localleader>C",
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

  local original_codediff = codediff.open_pr_file_diff
  local original_virtual = virtual_files.open_diff
  local calls = {}

  local last_open_result = nil

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

  codediff.open_pr_file_diff = function(opts)
    calls[#calls + 1] = { "codediff", vim.deepcopy(opts) }
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
  assert(calls[1] and calls[1][1] == "codediff",
    "Vertical+none PR file diff should prefer codediff")
  assert(calls[1][2].layout == "vertical" and calls[1][2].ignore_trim_whitespace ~= true,
    "Vertical+none PR file diff should open codediff side-by-side without trim ignore")
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
  assert(calls[1] and calls[1][1] == "codediff",
    "Unified PR file diff should prefer codediff inline")
  assert(calls[1][2].layout == "unified" and calls[1][2].ignore_trim_whitespace ~= true,
    "Unified+none should pass unified layout without trim ignore")
  assert(last_open_result and vim.b[last_open_result.head_buf].gh_pr_file_kind == "unified"
      and vim.b[last_open_result.head_buf].gh_pr_codediff_layout == "inline",
    "Codediff unified head buffer should expose unified inline metadata")

  calls = {}
  assert(actions.open_diff(pr.files[1], { view_mode = "vertical", ignore_whitespace_mode = "trim" }) == true,
    "Trim-whitespace PR file diff should open")
  assert(calls[1] and calls[1][1] == "codediff",
    "Trim-whitespace PR file diff should use codediff backend")
  assert(calls[1][2].layout == "vertical" and calls[1][2].ignore_trim_whitespace == true,
    "Vertical+trim should pass trim ignore to codediff")

  calls = {}
  assert(actions.open_diff(pr.files[1], { view_mode = "unified", ignore_whitespace_mode = "trim" }) == true,
    "Unified+trim PR file diff should open")
  assert(calls[1] and calls[1][1] == "codediff",
    "Unified+trim PR file diff should use codediff backend")
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
  assert(calls[1] and calls[1][1] == "codediff",
    "Toggling whitespace from strict should rerender with codediff when trim is supported")
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
  assert(calls[1] and calls[1][1] == "codediff",
    "Returning to unified+none should rerender with codediff")
  assert(calls[1][2].layout == "unified",
    "Returning to codediff should pass unified layout")

  codediff.open_pr_file_diff = original_codediff
  virtual_files.open_diff = original_virtual
  package.loaded["gh-pr.diff_comments_panel"] = original_panel
end
