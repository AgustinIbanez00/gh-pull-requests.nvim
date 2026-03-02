# gh-pull-requests.nvim

A Neovim plugin that brings a GitHub Pull Requests workflow (similar to VSCode) to Neovim, using `gh` CLI as backend.

## Features

- Query-based PR lists grouped by folders.
- Neo-tree source (`gh_pr`) as primary UI.
- Telescope fallback picker.
- Pull request overview interactive tabs UI (Snacks-based) with inline markdown rendering in PR description, link label rendering, and link preview support.
- Overview timeline tab that merges comments, reviews, and review-thread comments in chronological order.
- Open commit diffs directly from Overview > Commits (virtual patch buffers, no checkout).
- PR Review > Commits supports per-commit file browsing and opens commit-scoped diffs (`parent[1] -> commit`).
- Virtual readonly file buffers for base/head versions (no disk writes).
- Configurable diff rendering for changed files: vertical split, horizontal split, or unified inline.
- Toggle whitespace-sensitive vs whitespace-ignored diff rendering in file buffers.
- Image file preview in PR diffs (`png/jpg/jpeg/gif/webp/bmp/svg`) with configurable fallback actions (local open, GitHub compare URL, metadata diff text).
- Configurable path rendering in `Files` and `Comments` trees (`compact`, `tree`, `flat`).
- Line comment indicators in PR file buffers (signcolumn + virtual text).
- Floating modal popup with PR line comments on a configurable keymap in virtual PR buffers.
- Dedicated review workspace source (`gh_pr_review`) with sections: Overview, Labels, Files, Reviewers, Commits, Checks, Comments.
- Start review flow from PR source (`r`) with optional GitHub pending review creation ("started a review").
- Comments view migrated into PR Review > Comments (Problems-like navigation and preview preserved).
- PR checkout (`gh pr checkout`).
- Review actions:
  - approve
  - request changes
  - general comment
  - merge (merge/squash/rebase)
- Local viewed/unviewed file state persisted in `stdpath("state")`.

## Requirements

- Neovim >= 0.9
- GitHub CLI (`gh`) installed and authenticated (`gh auth login`)
- Run inside a git repository

Optional:

- [neo-tree.nvim](https://github.com/nvim-neo-tree/neo-tree.nvim) (primary UI)
- [telescope.nvim](https://github.com/nvim-telescope/telescope.nvim) (fallback UI)
- [snacks.nvim](https://github.com/folke/snacks.nvim) (required for interactive PR overview)

## Installation

### lazy.nvim

```lua
{
  "agustinibanez/gh-pull-requests.nvim",
  dependencies = {
    "nvim-lua/plenary.nvim",
    "nvim-neo-tree/neo-tree.nvim",
    "nvim-telescope/telescope.nvim",
    "nvim-tree/nvim-web-devicons",
    "MunifTanjim/nui.nvim",
    "folke/snacks.nvim",
  },
  opts = {
    remotes = { "origin", "upstream" },
    file_list_layout = "tree", -- legacy fallback for gh_pr ("tree" | "flat")
    path_render = {
      scope = "both", -- "both" | "files" | "comments"
      mode = "compact", -- "compact" | "tree" | "flat"
      separator = "/", -- visual separator for compact directories
      show_status_prefix = true, -- show [M]/[A]/... in Files nodes
    },
    hide_viewed_files = false,
    line_comments = {
      enabled = true,
      keymap = "K",
      indicator_style = "sign_and_virtual_text", -- "sign_and_highlight" | "sign_only" | "highlight_only" | "sign_and_virtual_text" | "virtual_text_only"
      show_resolved = true,
      show_outdated = true,
      max_popup_width = 90,
      max_popup_height = 18,
      popup = {
        enter = true, -- modal by default
        position = "cursor", -- "cursor" | "editor" | "preview_window"
        border = "rounded",
        wrap = true,
        close_on_move = true, -- applies when enter = false
        max_width = 90,
        max_height = 18,
      },
      virtual_text = {
        enabled = true,
        prefix = "C",
        show_count = true,
        position = "eol", -- "eol" | "inline"
      },
      comments_tree = {
        preview = {
          keymap = "p",
          position = "right", -- currently right only
          keep_focus = true,
        },
      },
      signs = {
        open = "C>",
        resolved = "C=",
        outdated = "C~",
      },
    },
    overview = {
      ui = "snacks",
      layout = "tabs",
      tabs = { "summary", "checks", "commits", "timeline", "files" },
      expand_step = 20,
      date_format = "%Y-%m-%d %H:%M",
      window = {
        enabled = true,
        border = "rounded",
        width_ratio = 0.88,
        height_ratio = 0.88,
        min_width = 100,
        min_height = 28,
        max_width = 180,
        max_height = 60,
        backdrop = 0,
        enter = true,
      },
      theme = {
        state_colors = true,
        checks_colors = true,
        labels = true,
        reviewers = true,
        timeline_kinds = true,
      },
      markdown = {
        enabled = true,
        provider = "auto", -- "auto" | "builtin" | "render-markdown" | "markview"
        max_lines = 500,
        code_block_border = false,
        link_preview_keymap = "gp",
        link_preview_max_bytes = 10485760, -- 10 MiB
        link_preview_renderable_extensions = { "txt", "md", "markdown", "json", "yaml", "yml", "csv", "log" },
        link_preview_disallowed_extensions = { "zip" },
        link_preview_open_local = "system",
      },
      max_items = {
        checks = 10,
        commits = 10,
        timeline = 30,
      },
      show = {
        checks = true,
        commits = true,
        timeline = true,
        labels = true,
      },
    },
    cache = {
      gh_pr = {
        enabled = true,
        ttl_seconds = 60,
        auto_refresh_when_focused = true,
        max_cache_age_seconds = 900,
        show_stale_badge = true,
        sync_visible_buffers = true,
      },
      gh_pr_review = {
        enabled = true,
        ttl_seconds = 60,
        auto_refresh_when_focused = true,
        max_cache_age_seconds = 900,
        show_stale_badge = true,
        sync_visible_buffers = true,
      },
    },
    diff_view = {
      mode = "vertical", -- "vertical" | "horizontal" | "unified"
      ignore_whitespace = false,
      render_whitespace = true,
      render_endlines = false, -- render LF/CRLF/CR markers at EOL
      whitespace = {
        tab = ">-", -- symbol for leading/trailing tabs
        space = ".", -- symbol for leading spaces
        trail = "~", -- optional: symbol for trailing spaces
        nbsp = "+", -- optional: non-breaking space symbol
        color = nil, -- optional: e.g. "#7f8ea3"
        highlight_group = "GhPrDiffWhitespace", -- optional: custom highlight group
      },
      endlines = {
        lf = "LF",
        crlf = "CRLF",
        cr = "CR",
        color = "#d16969",
        highlight_group = "GhPrDiffEndline",
      },
      shortcuts = {
        -- <localleader> uses vim.g.maplocalleader; if unset, gh-pr falls back to ","
        inline_comment = "<localleader>ic",
        inline_suggestion = "<localleader>is",
        line_comments_popup = "<localleader>dk",
        refresh = "<localleader>dr",
        close_quick = "<localleader>dq",
        close_all_open_review = "<localleader>dQ",
        help = "<localleader>d?",
        next_change = "<localleader>dn",
        prev_change = "<localleader>dp",
        next_file = "<localleader>df",
        prev_file = "<localleader>dF",
        next_reviewed_file = "<localleader>dv",
        prev_reviewed_file = "<localleader>dV",
        toggle_whitespace = "<localleader>tw",
        toggle_render_whitespace = "<localleader>ts",
        toggle_render_endlines = "<localleader>te",
        cycle_mode = "<localleader>mm",
        set_vertical = "<localleader>mv",
        set_horizontal = "<localleader>mh",
        set_unified = "<localleader>mu",
        submit_pending_comment = "<localleader>rc",
        submit_pending_approve = "<localleader>ra",
        submit_pending_request_changes = "<localleader>rr",
        discard_pending_review = "<localleader>rd",
        toggle_review_tree = "<localleader>rx",
        image_default_action = "<localleader>io",
        image_fallback_menu = "<localleader>im",
        show_open_hint = true, -- show one-time "how to close diff" hint per diff buffer
      },
      images = {
        enabled = true,
        backend = "snacks", -- currently only snacks.image
        formats = { "png", "jpg", "jpeg", "gif", "webp", "bmp", "svg" },
        cache_dir = nil, -- defaults to stdpath("cache") .. "/gh-pr/images"
        fallback = "placeholder",
        fallback_mode = "menu", -- "menu" | "metadata_only" | "auto_local" | "auto_github"
        fallback_default_action = "metadata", -- "metadata" | "open_local_current" | "open_local_both" | "open_github"
        fallback_menu_keymap = "gf", -- legacy hint used in some fallback messages
        fallback_open_local = "system", -- currently only "system"
        fallback_github_target = "pr_files", -- "pr_files" | "pr"
        show_metadata = true,
        metadata_resolution_strategy = "hybrid", -- "internal" | "external" | "hybrid"
        metadata_external_command = { "magick", "identify", "-format", "%w %h", "{file}" },
        max_bytes = 25 * 1024 * 1024,
      },
    },
    queries = {
      { folder = "Inbox", label = "Waiting For My Review", query = "is:open review-requested:@me" },
      { folder = "Inbox", label = "Assigned To Me", query = "is:open assignee:@me" },
      { folder = "Mine", label = "Created By Me", query = "is:open author:@me" },
      { folder = "All", label = "All Open", query = "is:open" },
    },
    ui = {
      use_neotree = true,
      telescope_fallback = true,
    },
  },
}
```

## Commands

- `:GhPrOpen` open PR UI (Neo-tree first, Telescope fallback).
- `:GhPrList` open Telescope query/PR picker.
- `:GhPrTelescope` open Telescope query/PR picker (fallback entrypoint).
- `:GhPrTelescopeActions` open contextual Telescope actions (active Review -> active PR -> PR list).
- `:GhPrTelescopeReview` open Telescope actions for the active PR Review context.
- `:GhPrComments [number]` open PR Review source focused on current/selected PR review context.
- `:GhPrStartReview [number]` start review flow for selected PR.
- `:GhPrReviewTree` toggle PR Review source.
- `:GhPrRefresh` refresh data.
- `:GhPRReviewRefresh` force refresh active PR Review data in background (alias: `:GhPrReviewRefresh`).
- `:GhPrOverview` open active PR overview interactive tabs buffer (requires `snacks.nvim`).
- `:GhPrOverviewRefresh` refresh active PR overview buffer in place.
- `:GhPrOverviewMore <checks|commits|timeline> [count]` load more section items.
- `:GhPrCheckout [number]` checkout PR branch.
- `:GhPrOpenDiff` open selected file in virtual base/head diff.
- `:GhPrOpenOriginal` open base version buffer.
- `:GhPrOpenModified` open head version buffer.
- `:GhPrOpenCommitPatch` open selected commit patch in virtual buffer.
- `:GhPrToggleReviewed` toggle local viewed state.
- `:GhPrNextChange` jump to next diff hunk.
- `:GhPrPrevChange` jump to previous diff hunk.
- `:GhPrApprove` prompt review message and confirm before submit.
- `:GhPrRequestChanges` prompt review message and confirm before submit.
- `:GhPrComment` prompt review message and confirm before submit.
- `:GhPrReviewSubmit` submit current pending review as comment (message + confirm).
- `:GhPrReviewApprove` submit current pending review as approve (message + confirm).
- `:GhPrReviewRequestChanges` submit current pending review as request changes (message + confirm).
- `:GhPrReviewDiscard` discard current pending review (confirm).
- `:GhPrMerge [merge|squash|rebase]` merge active PR.
- `:GhPrQueryAdd` add query.
- `:GhPrQueryEdit` edit query.
- `:GhPrQueryDelete` delete query.

## Default keymaps

- `<leader>gho` open PR UI.
- `<leader>ghl` open Telescope list.
- `<leader>ghm` open PR comments tree.
- `<leader>ghx` toggle PR Review source.
- `<leader>ghr` refresh.
- `<leader>ghv` PR overview.
- `<leader>ghc` checkout.
- `<leader>ghd` open diff.
- `gh_pr` source PR nodes expose only one child section: `Overview` (no `Files` subtree).
- `r` in `gh_pr` Neo-tree source starts review for selected PR.
- `ra` in `gh_pr` Neo-tree source submits approve review flow.
- `rc` in `gh_pr` Neo-tree source submits comment review flow.
- `rr` in `gh_pr` Neo-tree source submits request-changes review flow.
- `rd` in `gh_pr` Neo-tree source discards pending review.
- `m` in `gh_pr` Neo-tree source opens merge flow.
- `b` in `gh_pr` Neo-tree source opens selected PR in browser (PR nodes only).
- `k` in `gh_pr` Neo-tree source checks out selected PR.
- `gh_pr` PR rows show `[DRAFT]` suffix (and draft highlight) when PR is draft.
- `r` only prompts `Notify GitHub that review started...` when PR is not yours, you are requested reviewer, and you do not already have a pending review.
- `b` in `gh_pr_review` Neo-tree source opens selected PR in browser (PR context nodes only).
- `T` in `gh_pr_review` Neo-tree source opens Telescope actions scoped to Review context.
- `r` in `gh_pr_review` starts review flow.
- `ra`/`rc`/`rr`/`rd` in `gh_pr_review` submit/discard pending review.
- `a` in `gh_pr_review` edits assignees, `l` edits labels, `u` edits reviewers.
- `c` in `gh_pr_review` publishes a regular PR comment (`gh pr comment`).
- `gh_pr` and `gh_pr_review` do not bind `<space>` by default (keeps `<leader>` available when `mapleader = " "`).
- `gh_pr` and `gh_pr_review` prioritize PR-specific mappings over generic Neo-tree filesystem mappings.
- `<leader>ght` toggle viewed.
- `<leader>ghn` next diff hunk.
- `<leader>ghp` previous diff hunk.

Inside the overview buffer:
- `a` approve review
- `d` request changes
- `c` comment review
- `m` merge
- `k` checkout branch
- `R` refresh overview
- `b` open PR in browser
- `C` open `Comments PR` tree for the current PR
- `q` close overview
- `H` / `L` previous/next tab
- `1..9` jump to tab
- `et` edit title
- `eb` edit description
- `el` edit labels (multi-select, replacement mode)
- `er` edit reviewers (multi-select, replacement mode; users + teams)
- `ea` edit assignees (comma-separated, replacement mode)
- `em` edit milestone (empty input removes milestone)
- `es` change state (`open`/`closed`)
- `ed` toggle draft status (`ready`/`draft`)
- `<CR>` open selected row action
- `<CR>` on `Commits` opens commit diff details in a virtual patch buffer
- `gp` preview markdown link under cursor in PR description
- `gr` load more for current section tab
- `D` open diff for selected row (file or commit)
- `O` open original file for selected file row
- `M` open modified file for selected file row
- Every overview edit asks confirmation before execution and refreshes the overview on success.
- In multi-select edits (`labels/reviewers`), unselected current items are removed.
- Markdown links in description render as labels (instead of raw markdown) and can be previewed with `gp`.
- Link preview download is only used for GitHub attachments; non-attachment links prompt `open link` / `cancel` and open in browser when confirmed.
- Overview markdown normalizes CRLF/LF line endings to avoid `^M` artifacts on Windows.
- PR metadata (`state/review/merge/branches/stats`) is rendered globally at the top for all tabs.
- `Summary` no longer renders the old `Actions` block.
- `,x` toggle PR Review source while staying in review flow.

Inside PR virtual file buffers (`GhPrOpenDiff`, `GhPrOpenOriginal`, `GhPrOpenModified`):
- all gh-pr diff actions are namespaced under `<localleader>` to avoid overriding native Neovim keys
- if `vim.g.maplocalleader` is unset, gh-pr uses `,` as fallback for diff-buffer shortcuts
- `<localleader>dk` show PR comments for the current line in a modal floating window (`base`/`head` views)
- `<localleader>dr` refresh current diff buffer from GitHub
- opening a diff shows a one-time hint with close shortcuts (`<localleader>dq` / `<localleader>dQ`)
- `<localleader>d?` show floating help with available PR diff shortcuts
- `<localleader>dq` quick close: in 2-way diff closes `modified/head`; in single-buffer view closes and opens `PR Review`
- `<localleader>dQ` close current diff view(s) and open/focus `PR Review`
- `<localleader>tw` toggle whitespace diff mode (ignored/strict)
- `<localleader>ts` toggle leading/trailing whitespace/tab symbol rendering
- `<localleader>te` toggle endline rendering (`LF`/`CRLF`/`CR`)
- `<localleader>mm` cycle diff mode (`vertical` -> `horizontal` -> `unified`)
- `<localleader>mv` force vertical split mode
- `<localleader>mh` force horizontal split mode
- `<localleader>mu` force unified mode (single virtual diff buffer)
- `<localleader>ic` add inline review comment at current line (`MODIFIED`/head or `unified`)
- visual `<localleader>ic` add inline review comment for selected line range (`v`/`V`, `MODIFIED`/head or `unified`)
- `<localleader>is` add inline suggestion comment at current line (`suggestion` template)
- visual `<localleader>is` add inline suggestion comment for selected line range (`v`/`V`)
- for `ADDED` files, `GhPrOpenDiff` opens a single MODIFIED buffer (no split/unified diff layout)
- virtual file content normalizes CRLF/LF/CR line endings, preventing `^M` artifacts
- for image files (`png/jpg/jpeg/gif/webp/bmp/svg`), previews are rendered in virtual buffers when supported by `snacks.image`
- for image files in `unified` mode, plugin forces split view (vertical/horizontal) instead of unified text diff
- for image files, line-comments popup and inline/suggestion/hunk shortcuts (`<localleader>dk`, `<localleader>ic`, `<localleader>is`, `<localleader>dn`, `<localleader>dp`, `<localleader>te`) are disabled
- for image files, `<localleader>io` runs the configured default fallback action and `<localleader>im` opens fallback actions menu
- if image render backend is unavailable/unsupported, gh-pr opens the image fallback menu (configurable), can open local cached files, open GitHub compare URL, and can render metadata diff text (resolution/size/sha)
- in `ADDED` single-buffer mode, `<localleader>ic` is allowed on any line/range
- inline comments are pre-validated before opening the composer:
  - `MODIFIED`/head must be inside PR diff hunks
  - `unified` is limited to added (`+`) lines in the diff
- inline comment editor uses `<C-s>` to submit draft and `q`/`<Esc>` to cancel
- `<localleader>dn` next diff change
- `<localleader>dp` previous diff change
- `<localleader>df` next file in PR
- `<localleader>dF` previous file in PR
- `<localleader>dv` next reviewed file in PR
- `<localleader>dV` previous reviewed file in PR
- file navigation shortcuts always reopen the full diff view using the active render mode (`vertical`/`horizontal`/`unified`)
- `<localleader>rc` submit pending review as comment
- `<localleader>ra` submit pending review as approve
- `<localleader>rr` submit pending review as request changes
- `<localleader>rd` discard pending review
- `<localleader>rx` toggle PR Review source

Image diff rendering options (`diff_view.images`):
- `enabled` (`true`)
- `backend` (`"snacks"`)
- `formats` (`{ "png", "jpg", "jpeg", "gif", "webp", "bmp", "svg" }`)
- `cache_dir` (`nil` => `stdpath("cache")/gh-pr/images`)
- `fallback` (`"placeholder"`)
- `fallback_mode` (`"menu"`, also `"metadata_only"` / `"auto_local"` / `"auto_github"`)
- `fallback_default_action` (`"metadata"`, also `"open_local_current"` / `"open_local_both"` / `"open_github"`)
- `fallback_menu_keymap` (`"gf"`)
- `fallback_open_local` (`"system"`)
- `fallback_github_target` (`"pr_files"`, also `"pr"`)
- `show_metadata` (`true`)
- `metadata_resolution_strategy` (`"hybrid"`, also `"internal"` / `"external"`)
- `metadata_external_command` (`{ "magick", "identify", "-format", "%w %h", "{file}" }`)
- `max_bytes` (`26214400`)

Inside `gh_pr_review` Neo-tree source:
- Root node shows active PR (`PR #N - title`) for current repository.
- Sections: `Overview`, `Labels`, `Files`, `Reviewers`, `Commits`, `Checks`, `Comments`.
- `<CR>` actions:
  - `Overview` opens overview buffer
  - `Files` opens diffs
  - `Commits` expands selected commit and lists changed files
  - `Commit file` opens diff scoped to selected commit (`parent[1] -> commit`)
  - `Checks` opens check URL
  - `Comments` is a tree with `By File` and `Global` sections
  - `By File` groups comment threads by path/file and thread labels show status badges
    (`[UNRESOLVED]`, `[RESOLVED]`, `[CLOSED]`)
- `Global` includes review events and general PR comments
- Thread nodes/items open file/line and thread popup when location exists
- Review/general comment nodes open timeline popup
- In `Files`, directory nodes show a yellow prefix `X/Y VIEWED` when at least one descendant file is viewed
  (counts are recursive and include subfolders).
- `v` on files toggles viewed state and refreshes PR state immediately.
- Marking viewed/unviewed from `gh_pr_review` does not force-focus `gh_pr` panel.
- `R` forces a refresh from GitHub for the active review PR.
- `:GhPrOpenCommitPatch` opens full patch for selected commit (command-only access).
- `r` re-runs start-review flow for selected PR context.
- `ra` submit pending review as approve.
- `rc` submit pending review as comment.
- `rr` submit pending review as request changes.
- `rd` discard pending review.
- `a` opens assignees edit dialog.
- `l` opens labels multi-select edit dialog.
- `u` opens reviewers multi-select edit dialog.
- `c` publish a regular PR comment (`gh pr comment`), outside pending review.
- `x` toggles PR Review source from current context.
- `zA` expand all review nodes.
- `za` collapse all review nodes.
- `zF` expand `Files` subtree.
- `zf` collapse `Files` subtree.
- `zV` expand paths that contain viewed files.
- `zv` collapse paths that contain viewed files.
- `zC` expand `Comments > By File`.
- `zc` collapse `Comments > By File`.
- `zG` expand `Comments > Global` (including subgroups).
- `zg` collapse `Comments > Global` (including subgroups).

## Neo-tree source

The plugin exposes source modules:
- `gh_pr` (`lua/gh_pr.lua`)
- `gh_pr_review` (`lua/gh_pr_review.lua`)

`GhPrOpen`, `GhPrStartReview`, and `GhPrReviewTree` auto-register required sources in Neo-tree config at runtime.

## Notes

- Query definitions are persisted in `stdpath("state")/gh-pr/queries.json`.
- Viewed file state is persisted in `stdpath("state")/gh-pr/state.json`.
- Diff view preferences (`mode`, `ignore_whitespace`, `render_whitespace`, `render_endlines`) are persisted in `stdpath("state")/gh-pr/state.json`.
- Image fallback default action is persisted in `stdpath("state")/gh-pr/state.json`.
- PR cache is persisted in `stdpath("state")/gh-pr/pr_cache.json`.
- Cache entries are scoped per source and repository key (`gh_pr` and `gh_pr_review`).
- File content is fetched from GitHub API through `gh api` and opened in readonly buffers.
- File open in PR views no longer falls back to patch (`@@`) buffers when content fetch fails; commit patch views remain explicit.
