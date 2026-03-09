# gh-pull-requests.nvim

A GitHub Pull Request workflow for Neovim (VSCode-like), powered by the GitHub CLI (`gh`).

[![Neovim](https://img.shields.io/badge/Neovim-0.9%2B-57A143?logo=neovim&logoColor=white)](#requirements)
[![License](https://img.shields.io/badge/License-MIT-yellow.svg)](./LICENSE)
[![Release](https://img.shields.io/github/v/release/agustinibanez/gh-pull-requests.nvim)](https://github.com/agustinibanez/gh-pull-requests.nvim/releases)
[![CI](https://github.com/AgustinIbanez00/gh-pull-requests.nvim/actions/workflows/ci.yml/badge.svg)](https://github.com/AgustinIbanez00/gh-pull-requests.nvim/actions/workflows/ci.yml)
[![Last Commit](https://img.shields.io/github/last-commit/agustinibanez/gh-pull-requests.nvim)](https://github.com/agustinibanez/gh-pull-requests.nvim/commits/main)
[![Stars](https://img.shields.io/github/stars/agustinibanez/gh-pull-requests.nvim?style=social)](https://github.com/agustinibanez/gh-pull-requests.nvim/stargazers)
[![Validation](https://img.shields.io/badge/Validation-scripts%2Fvalidate.ps1-blue)](#validation)

Quick links: [Installation](#installation) · [Quick Start](#quick-start) · [Commands](#commands) · [Keymaps](#keymaps) · [Query Placeholders](#query-placeholders)

## Table of Contents

- [Features](#features)
- [Requirements](#requirements)
- [Validation](#validation)
- [Installation](#installation)
- [Quick Start](#quick-start)
- [Query Placeholders](#query-placeholders)
- [Commands](#commands)
- [Keymaps](#keymaps)
- [Troubleshooting](#troubleshooting)
- [Consolidated architecture](#consolidated-architecture)
- [Migration notes (legacy overview path removal)](#migration-notes-legacy-overview-path-removal)
- [Neo-tree source](#neo-tree-source)
- [Highlights](#highlights)
- [Notes](#notes)

## Features

### 📂 PR Discovery

- Query-based PR lists grouped by folders.
- Neo-tree source (`gh_pr`) as primary UI, with Telescope fallback.
- Query expansion with placeholders (`${user}`, `${owner}`, `${repository}`, `@org`).

### 🧠 Review Workspace

- Dedicated review workspace source (`gh_pr_review`) with sections: Overview, Labels, Files, Reviewers, Commits, Checks, Security, Comments, Drafts.
- Start review flow from PR nodes (`r`) with optional GitHub pending-review creation.
- Review actions: approve, request changes, comment, merge (`merge/squash/rebase`).

### 📝 Overview + Activity

- Multi-pane overview (Summary + Activity + Collaboration).
- Overview panes open in a dedicated tabpage using normal windows (not fullscreen float popups).
- Summary embeds a chronological activity stream (comments, reviews, commits, thread comments, PR state changes).
- Open commit diffs from overview without checkout (`codediff` backend).

### 🧩 Diff + File UX

- `codediff.nvim` backend for PR file diffs, commit diffs and thread/comment location navigation.
- No-fetch strategy for file diffs: content is downloaded from GitHub and opened through temporary files.
- Session prompt fallback to legacy virtual backend when `codediff` is missing/fails.
- Unified non-text preview for images and generic binary assets in review flows.

### ⚙️ Reliability + State

- Viewed/unviewed state synced from GitHub when available, with local fallback persisted in `stdpath("state")`.
- Cache persisted per source/repo key.
- Headless smoke + helptags validation script (`scripts/validate.ps1`).

<details>
<summary>More feature details</summary>

- Pull request overview interactive tabs UI (Snacks-based) with inline markdown rendering in PR description, link label rendering, and link preview support.
- Open commit diffs directly from Overview > Commits (`codediff`, no checkout).
- PR Review > Commits supports per-commit file browsing and opens commit-scoped diffs (`parent[1] -> commit`).
- Configurable path rendering in `Files` and `Comments` trees (`compact`, `tree`, `flat`).
- Comments view migrated into PR Review > Comments (Problems-like navigation and preview preserved).
- PR checkout via `gh pr checkout`.

</details>

## Requirements

- Neovim >= 0.9 (0.10+ recommended for `vim.system` / `vim.ui.open` support)
- GitHub CLI (`gh`) installed and authenticated (`gh auth login`)
- Run inside a git repository
- [render-markdown.nvim](https://github.com/MeanderingProgrammer/render-markdown.nvim) installed

Optional:

- [neo-tree.nvim](https://github.com/nvim-neo-tree/neo-tree.nvim) (primary UI)
- [telescope.nvim](https://github.com/nvim-telescope/telescope.nvim) (fallback UI)
- [codediff.nvim](https://github.com/esmuellert/codediff.nvim) (primary diff backend; without it gh-pr can use session fallback to legacy virtual buffers)
- [snacks.nvim](https://github.com/folke/snacks.nvim) (required for interactive PR overview)

## Validation

Run the repo-local CI-like validation command:

```powershell
pwsh -File scripts/validate.ps1
```

This command runs headless smoke checks and helptags generation in one step.
The same entrypoint is used by GitHub Actions CI on every push to `main` and on pull requests.
It now includes:

- command and entrypoint smoke (`scripts/headless_smoke.ps1`)
- Neo-tree lazy/gating smoke (`scripts/neotree_lazy_smoke.ps1`)
- `:helptags doc` validation

Optional checks:

```powershell
pwsh -File scripts/validate.ps1 -WithLuacheck -WithCheckHealth
```

Validation prerequisites:

- `pwsh` and `nvim` available in `PATH`
- `luacheck` only when `-WithLuacheck` is used locally or in CI
- `gh auth login` recommended when `-WithCheckHealth` is used

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
    "MeanderingProgrammer/render-markdown.nvim",
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
    pr_review = {
      files = {
        flat = false, -- PR Review > Files list mode (no folder tree)
      },
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
        show_authors = true, -- when true multiline labels include author: "💬 Lx/N @user"
        max_authors = 2, -- max authors shown before "+N"
        position = "eol", -- "eol" | "inline"
      },
      comments_tree = {
        auto_open_thread_popup = true,
        preview = {
          keymap = "p",
          position = "right", -- currently right only
          keep_focus = true,
        },
        thread_popup = {
          enabled = true,
          width_ratio = 0.62,
          height_ratio = 0.55,
          min_width = 80,
          min_height = 12,
          max_width = 140,
          max_height = 40,
          border = "rounded",
          wrap = true,
          enter = true,
          position = "cursor", -- "cursor" | "editor"
        },
      },
      reactions = {
        render = "emoji", -- "emoji" | "text"
        viewer_marker = "*", -- appended when the viewer already reacted
        picker = {
          position = "cursor", -- "cursor" | "editor" | "preview_window"
          border = "rounded",
          enter = true,
          width = 56,
          height = 10,
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
      tabs = { "summary", "checks", "commits", "files" }, -- legacy timeline/comments/reviews/threads map to summary
      expand_step = 20,
      date_format = "%Y-%m-%d %H:%M",
      window = {
        enabled = true,
        border = "rounded",
        width_ratio = 0.9,
        height_ratio = 0.9,
        min_width = 110,
        min_height = 30,
        max_width = 220,
        max_height = 80,
        backdrop = 0,
        enter = true,
      },
      panes = {
        layout = {
          sidebar_width_ratio = 0.34, -- right panel width ratio
          summary_height_ratio = 0.38, -- top-left panel height ratio
          gap = 1, -- compatibility spacing option for pane layout
          min_left_width = 58,
          min_sidebar_width = 30,
          min_summary_height = 10,
          min_activity_height = 12,
        },
        activity = {
          visual_style = "minimal", -- "minimal" | "classic"
          max_body_lines = 8, -- max body lines per event/comment block
          max_events = 120, -- max rendered timeline events in activity pane
          show_code_context = true, -- render diffHunk snippet in thread blocks
        },
        keymaps = {
          cycle_next = "<Tab>",
          cycle_prev = "<S-Tab>",
          focus_summary = "g1",
          focus_activity = "g2",
          focus_meta = "g3",
          help = "?",
          focus_left = "<C-h>",
          focus_down = "<C-j>",
          focus_up = "<C-k>",
          focus_right = "<C-l>",
        },
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
        mode = "full", -- "full" (native markdown buffer) | "legacy" (provider-based markdown renderer)
        provider = "render-markdown", -- required dependency; "builtin" is still available as fallback
        max_lines = 500,
        code_block_border = false,
        github_style = true, -- GitHub-like markdown structure in Summary/Activity
        github_style_separators = "rules", -- currently "rules"
        diff_gutter = "none", -- default clean diff block; "old_new_code" is deprecated and mapped to "none"
        link_preview_keymap = "gp",
        link_preview_max_bytes = 10485760, -- 10 MiB
        link_preview_renderable_extensions = { "txt", "md", "markdown", "json", "yaml", "yml", "csv", "log" },
        link_preview_disallowed_extensions = { "zip" },
        link_preview_open_local = "disabled", -- "disabled" | "reveal_only" | "system"
      },
      thread_snippet = {
        context_before = 5, -- lines above focused comment line
        context_after = 5, -- lines below focused comment line
      },
      thread_fix_diff = {
        enabled = true,
        show_action_line = true, -- compatibility toggle for legacy explicit action line
        keymap = "gf", -- compatibility key (default activity flow uses <CR> contextual menu)
        inline = true, -- compatibility for inline patch consumers; overview default opens diff buffer
        context_before = 5, -- lines above focused fix line in latest commit patch
        context_after = 5, -- lines below focused fix line in latest commit patch
        fallback_to_buffer = true, -- fallback to legacy diff buffer if inline patch is unavailable
      },
      max_items = {
        checks = 10,
        commits = 10,
        timeline = 30,
        comments = 30,
        reviews = 30,
        threads = 30,
      },
      show = {
        checks = true,
        commits = true,
        timeline = true,
        comments = true,
        reviews = true,
        threads = true,
        pr_changes = true, -- show PR metadata/state change events inside Summary > Activity
        labels = true,
      },
    },
    overview_v2 = {
      enabled = false, -- deprecated alias; use `overview` / `overview.panes` instead
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
    follow_current_file = {
      enabled = true,
      debounce_ms = 60,
      sources = {
        pr = true,
        pr_review = true,
      },
    },
    diff_view = {
      mode = "vertical", -- "vertical" | "horizontal" | "unified"
      ignore_whitespace = false,
      render_whitespace = true,
      render_endlines = false, -- render LF/CRLF/CR markers at EOL
      debug = {
        codediff_failures = false, -- when true, show debug notifications for codediff errors/fallback decisions and review prefetch activity
      },
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
        toggle_whitespace = "", -- removed default mapping (legacy virtual-only feature)
        toggle_render_whitespace = "",
        toggle_render_endlines = "",
        cycle_mode = "",
        set_vertical = "",
        set_horizontal = "",
        set_unified = "",
        submit_pending_comment = "<localleader>rc",
        submit_pending_approve = "<localleader>ra",
        submit_pending_request_changes = "<localleader>rr",
        discard_pending_review = "<localleader>rd",
        toggle_review_tree = "<localleader>rx",
        toggle_comments_panel = "<localleader>dc",
        image_default_action = "<localleader>io",
        image_fallback_menu = "<localleader>im",
        show_open_hint = true, -- show one-time "how to close diff" hint per diff buffer
      },
      comments_panel = {
        enabled = true,
        auto_open = "if_comments", -- current diff file only; "if_comments" | "never" | "always" (also accepts true => "if_comments", false => "never")
        position = "bottom", -- "bottom" | "right" for the temporary Neo-tree diff comments source
        height_ratio = 0.28, -- bottom Neo-tree diff comments pane height (also used by the legacy fallback panel)
        min_height = 8, -- bottom Neo-tree diff comments pane minimum height
        max_height = 18, -- bottom Neo-tree diff comments pane maximum height
        follow_cursor = true,
        show_resolved = true,
        show_outdated = true,
        close_with_dq = true,
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
        fallback_open_local = "disabled", -- "disabled" | "reveal_only" | "system"
        fallback_github_target = "pr_files", -- "pr_files" | "pr"
        show_metadata = true,
        metadata_resolution_strategy = "hybrid", -- "internal" | "external" | "hybrid"
        metadata_external_command = { "magick", "identify", "-format", "%w %h", "{file}" },
        max_bytes = 25 * 1024 * 1024,
      },
      non_text = {
        enabled = true,
        auto_preview = true, -- image and generic asset files bypass codediff fallback prompts
        show_metadata = true, -- render metadata/action cards for non-text preview buffers
      },
      prefetch = {
        enabled = true,
        concurrency = 4,
        text_extensions = { "lua", "md", "json", "yml", "yaml", "toml", "ts", "tsx", "js", "css", "html", "xml", "sh", "ps1", "sql", "txt", "log", "csv" },
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
      neotree_sources = {
        pr = {
          auto_register = true,
          gate = "github_repo", -- "github_repo" | "git_repo" | "manual"
          workspace = "cwd", -- "cwd" | "buffer_repo" | "neotree_root"
        },
      },
    },
    mappings = {
      global = {
        enabled = false, -- disabled by default (opt-in)
        keys = {
          open = "<leader>gho",
          list = "<leader>ghl",
          comments = "<leader>ghm",
          refresh = "<leader>ghr",
          overview = "<leader>ghv",
          checkout = "<leader>ghc",
          open_diff = "<leader>ghd",
          review_tree = "<leader>ghx",
          toggle_reviewed = "<leader>ght",
          next_change = "<leader>ghn",
          prev_change = "<leader>ghp",
        },
      },
    },
  },
}
```

## Quick Start

1. Authenticate once with GitHub CLI:

```bash
gh auth login
```

2. Open any local Git repository in Neovim.
3. Run:

```vim
:GhPrOpen
```

By default, the Neo-tree `PR` source appears only after gh-pr confirms that the current workspace (`cwd`) is a git repository with a GitHub remote.

Tip: if you prefer explicit review flow from a selected PR, use `:GhPrStartReview`.

## Query placeholders

`queries[*].query` supports runtime placeholders:

| Placeholder | Resolves to | Example |
| --- | --- | --- |
| `${user}` | Current authenticated GitHub login | `is:open author:${user}` |
| `${owner}` | Owner of the repository resolved from configured remotes | `is:open repo:${owner}/my-repo` |
| `${repository}` | Repository name resolved from configured remotes | `is:open repo:my-org/${repository}` |
| `@org` | Alias for current repository owner | `is:open org:@org review-requested:@me` |

Scope behavior:

- If query contains neither `repo:` nor `org:`, gh-pr appends `repo:<owner>/<repo>`.
- If query already contains `repo:` or `org:`, gh-pr does not append `repo:`.

Examples:

- `is:open review-requested:@me org:@org`
- `is:open author:${user} org:@org`

## Troubleshooting

| Symptom | Check | Fix |
| --- | --- | --- |
| No PRs are shown | Are you in a git repo? | Open a repository and run `:GhPrOpen` again. |
| `PR` source tab is missing in Neo-tree | Does the current workspace have a GitHub remote? | Default `ui.neotree_sources.pr.gate = "github_repo"` hides `gh_pr` outside GitHub repos. Use a GitHub checkout, switch `workspace`, or set `gate = "git_repo"` / `manual`. |
| `gh` errors / auth failures | `gh auth status` | Run `gh auth login` and retry. |
| Neo-tree source not opening | Neo-tree installed and configured? | Use fallback `:GhPrTelescope` or install/enable Neo-tree dependency. |
| Docs/commands seem out of sync | Health + validation | Run `:checkhealth gh-pr` and `pwsh -File scripts/validate.ps1`. |

## Consolidated architecture

- Lazy entrypoint: `plugin/gh-pr.lua` (commands + `<Plug>` wiring only).
- Public facade: `lua/gh-pr/init.lua`.
- Config/state normalization: `lua/gh-pr/config.lua`.
- Command specs: `lua/gh-pr/commands.lua`.
- Mapping specs: `lua/gh-pr/mappings.lua`.
- Core domains: `lua/gh-pr/core/*` (including overview/diff/review action modules).
- UI domains: `lua/gh-pr/ui/*` (overview panes under `lua/gh-pr/ui/overview/*`).
- Optional adapters: `lua/gh-pr/integrations/*`.
- Health checks: `lua/gh-pr/health.lua`.

## Migration notes (legacy overview path removal)

If you have custom code requiring internal `overview_v2*` modules, migrate to the
consolidated paths:

| Removed internal module path | New canonical module path |
| --- | --- |
| `gh-pr.overview_v2_runtime` | `gh-pr.ui.overview.runtime` |
| `gh-pr.overview_v2_layout` | `gh-pr.ui.overview.layout` |
| `gh-pr.overview_v2_render` | `gh-pr.ui.overview.render` |
| `gh-pr.overview_v2_keymaps` | `gh-pr.ui.overview.keymaps` |

Compatibility aliases kept for user-facing behavior:

- `:GhPrOverviewV2` -> `:GhPrOverview`.
- `:GhPrOverviewV2Refresh` -> `:GhPrOverviewRefresh`.
- `setup({ overview_v2 = ... })` is still accepted, mapped to `overview` / `overview.panes`, and warns once as deprecated.
- `require("gh-pr").open_overview_v2()` and `require("gh-pr").refresh_overview_v2()` still dispatch to canonical overview actions.

## Commands

| Command | Description | Typical use |
| --- | --- | --- |
| `:GhPrOpen` | Focus/open PR UI (idempotent; Neo-tree first, Telescope fallback) | Start or refocus a PR browsing session |
| `:GhPrStartReview [number]` | Start review flow for selected PR | Enter review workspace quickly and warm textual diffs in background |
| `:GhPrReviewTree` | Toggle PR Review source | Jump between list and review tree |
| `:GhPrOverview` | Open active PR overview panes | Inspect summary/activity/collaboration |
| `:GhPrOpenDiff` | Open selected file diff or non-text preview | Review code and assets |
| `:GhPrOpenCommitPatch` | Open selected commit diff in codediff | Inspect commit-level changes |
| `:GhPrToggleReviewed` | Toggle viewed state | Track reviewed files |
| `:GhPrRefresh` | Refresh data | Sync UI with latest PR state |
| `:GhPRReviewRefresh` / `:GhPrReviewRefresh` | Force background refresh of active PR Review | Refresh stale review tree |
| `:GhPrMerge [merge|squash|rebase]` | Merge active PR | Complete review flow |
| `:GhPrQueryAdd` / `:GhPrQueryEdit` / `:GhPrQueryDelete` | Manage saved PR queries | Customize PR inbox filters |

<details>
<summary>Full command reference</summary>

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
- `:GhPrOverview` open active PR overview panes (Summary/Activity/Collaboration).
- `:GhPrOverviewV2` alias of `:GhPrOverview` (kept for compatibility).
- `:GhPrOverviewRefresh` refresh active overview panes.
- `:GhPrOverviewV2Refresh` alias of `:GhPrOverviewRefresh` (kept for compatibility).
- `:GhPrOverviewMore <checks|commits|comments|reviews|threads> [count]` load more section items.
- `:GhPrCheckout [number]` checkout PR branch.
- `:GhPrOpenDiff` open selected file in codediff for text, or dedicated gh-pr preview for non-text.
- `:GhPrOpenOriginal` open selected file and focus base side in codediff when possible, or dedicated base-side preview for non-text.
- `:GhPrOpenModified` open selected file and focus head side in codediff when possible, or dedicated head-side preview for non-text.
- `:GhPrOpenCommitPatch` open selected commit diff in codediff.
- `:GhPrToggleReviewed` toggle viewed state (GitHub when available, local fallback otherwise).
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

</details>

## Keymaps

Top-level mappings are exposed through `<Plug>` and global `<leader>` mappings are disabled by default.

### `<Plug>` mapping API

| Mapping | Action |
| --- | --- |
| `<Plug>(gh-pr-open)` | Open PR UI |
| `<Plug>(gh-pr-list)` | Open Telescope PR list |
| `<Plug>(gh-pr-comments)` | Open PR comments tree |
| `<Plug>(gh-pr-start-review)` | Start PR review flow |
| `<Plug>(gh-pr-review-tree)` | Toggle PR Review source |
| `<Plug>(gh-pr-refresh)` | Refresh PR data |
| `<Plug>(gh-pr-review-refresh)` | Force refresh PR Review data |
| `<Plug>(gh-pr-overview)` | Open PR overview |
| `<Plug>(gh-pr-overview-refresh)` | Refresh PR overview |
| `<Plug>(gh-pr-checkout)` | Checkout PR branch |
| `<Plug>(gh-pr-open-diff)` | Open PR file diff |
| `<Plug>(gh-pr-open-original)` / `<Plug>(gh-pr-open-modified)` | Open base/head version |
| `<Plug>(gh-pr-open-commit-patch)` | Open selected commit patch |
| `<Plug>(gh-pr-toggle-reviewed)` | Toggle viewed state |
| `<Plug>(gh-pr-next-change)` / `<Plug>(gh-pr-prev-change)` | Jump diff hunks |
| `<Plug>(gh-pr-approve)` / `<Plug>(gh-pr-request-changes)` / `<Plug>(gh-pr-comment)` | Review decisions |
| `<Plug>(gh-pr-review-submit)` / `<Plug>(gh-pr-review-approve)` / `<Plug>(gh-pr-review-request-changes)` / `<Plug>(gh-pr-review-discard)` | Pending review workflow |
| `<Plug>(gh-pr-merge)` | Merge active PR |

Example user mappings:

```lua
vim.keymap.set("n", "<leader>gho", "<Plug>(gh-pr-open)", { remap = true, silent = true, desc = "Open PR UI" })
vim.keymap.set("n", "<leader>ghl", "<Plug>(gh-pr-list)", { remap = true, silent = true, desc = "List PRs" })
```

Enable legacy-style global defaults (opt-in):

```lua
require("gh-pr").setup({
  mappings = {
    global = {
      enabled = true,
    },
  },
})
```

### Shortcut tables (at a glance)

#### Neo-tree `gh_pr` source

| Key | Action |
| --- | --- |
| `r` | Start review flow for selected PR |
| `ra` / `rc` / `rr` / `rd` | Approve / comment / request changes / discard |
| `m` | Open merge flow |
| `b` | Open selected PR in browser |
| `k` | Checkout selected PR |

#### Overview buffer

| Key | Action |
| --- | --- |
| `a` / `d` / `c` / `m` / `k` / `b` | Review + merge + checkout + browser actions |
| `R` | Refresh overview |
| `gp` | Preview markdown link under cursor (description) |
| `<CR>` on metadata rows | Edit title / description / state / draft / labels / reviewers / assignees / milestone |
| `<CR>` on `## Description` | Edit description in multiline composer |
| `<CR>` on description link line | Preview attachment or confirm-open link (multiple links => selector) |
| `<CR>` on thread header | Open thread evolution diff (comment commit -> latest file) |
| `gr` | Load more activity |
| `D` / `O` / `M` | Open diff / original / modified |

#### Diff buffer (`<localleader>` namespace)

| Key | Action |
| --- | --- |
| `<localleader>dr` | Refresh current diff buffer |
| `<localleader>dq` / `<localleader>dQ` | Quick close / close and open review |
| `<localleader>dn` / `<localleader>dp` | Next / previous diff change |
| `<localleader>df` / `<localleader>dF` | Next / previous file |
| `<localleader>dv` / `<localleader>dV` | Next / previous reviewed file |
| `<localleader>ic` / `<localleader>is` | Inline comment / inline suggestion |
| `<localleader>ra` / `<localleader>rc` / `<localleader>rr` / `<localleader>rd` | Pending review actions |
| `<localleader>rx` | Toggle PR Review source |

<details>
<summary>Detailed keymap behavior and edge cases</summary>

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
- `/` in `gh_pr_review` filters `Files` by path substring for the current session.
- `z/` clears the current `Files` path filter.
- `zs` selects a `Files` status filter (`all/modified/added/deleted/renamed/copied`).
- `ze` filters `Files` by extension.
- `zn` toggles `Files` no-extension filter.
- `z.` toggles `Files` dotfiles-only filter.
- `zu` toggles `Files` unviewed-only filter.
- `zw` toggles `Files` viewed-only filter.
- `zh` toggles `Files` hide-viewed for the current session.
- `zd` toggles `Files` hide-deleted for the current session.
- `zr` resets all session file filters.
- `gh_pr` and `gh_pr_review` do not bind `<space>` by default (keeps `<leader>` available when `mapleader = " "`).
- `gh_pr` and `gh_pr_review` prioritize PR-specific mappings over generic Neo-tree filesystem mappings.
- Opening `Overview` from Neo-tree reuses/focuses existing overview session for that PR and triggers silent background refresh.

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
- `<CR>` open selected row action
- `<CR>` on metadata rows edits title/description/state/draft/labels/reviewers/assignees/milestone
- `<CR>` on `## Description` heading opens a large multiline composer preloaded with current body (`<C-s>` submit, `q`/`<Esc>` cancel)
- `<CR>` on a description body line with a single markdown/http(s) link opens preview/link action for that link
- `<CR>` on a description body line with multiple links opens a selector menu first
- state row uses direct toggle (`open`/`closed`) with confirmation
- draft row uses direct toggle (`ready`/`draft`) with confirmation
- `<CR>` on `Commits` opens commit diff details in codediff (or legacy virtual fallback if selected for this session)
- `<CR>` on `Summary > Activity` thread headers opens evolution diff for that thread file (comment commit -> latest file)
- `gp` preview markdown link under cursor in PR description
- `gr` load more for current section tab (`Summary` loads more Activity)
- `D` open diff for selected row (file or commit)
- `O` open original file for selected file row
- `M` open modified file for selected file row
- Every overview edit asks confirmation before execution and refreshes the overview on success.
- In multi-select edits (`labels/reviewers`), unselected current items are removed.
- In `overview.markdown.mode = "full"`, PR description keeps raw markdown and fenced blocks (including `diff`) use native markdown syntax highlighting.
- In `overview.markdown.mode = "legacy"`, markdown renderer is selected by `overview.markdown.provider` (`render-markdown`/`builtin`).
- `overview.markdown.github_style = true` applies GitHub-like markdown structure in `Summary` (headings + separators for Activity/threads).
- `overview.markdown.diff_gutter = "none"` keeps thread snippets and markdown `diff` blocks clean (no per-line numbering).
- Markdown links in description can be previewed with `gp` or directly with `<CR>` on the link line.
- `<CR>` priority in description: heading edits body; link lines preview/open links.
- Link preview download is only used for GitHub attachments; non-attachment links prompt `open link` / `cancel` and open in browser when confirmed.
- Local attachment opening is disabled by default. Use `overview.markdown.link_preview_open_local = "reveal_only"` to reveal cached files safely, or `"system"` to opt into opening non-dangerous local files with the OS handler.
- If browser open fails for a description/check/commit URL action, gh-pr now shows an explicit error notification with the opener failure reason.
- Renderable GitHub attachments open in a full-screen readonly preview tab (`q` / `<Esc>` closes).
- Overview markdown normalizes CRLF/LF line endings to avoid `^M` artifacts on Windows.
- PR metadata (`state/review/merge/branches/stats`) is rendered globally at the top for all tabs.
- `Summary` no longer renders the old `Actions` block.
- `Summary > Activity` includes commit upload events and PR change events (labels/review requests/assignees/milestones/title/base-ref/draft/ready/close/reopen/merge/force-push).
- Commit events in `Summary > Activity` can be opened with `<CR>` to view commit diff.
- `Summary > Activity` thread rows are rendered header-only for low-noise navigation.
- `<CR>` on a thread header opens compare diff from the thread comment commit to the latest file version in the PR.
- If inline patch resolution fails, `overview.thread_fix_diff.fallback_to_buffer = true` falls back to legacy diff buffers.
- `,x` toggle PR Review source while staying in review flow.
- gh-pr UI windows (overview panes, popups and composer) force `nospell` without affecting regular file buffers.

Inside overview panes (`:GhPrOverview`, alias `:GhPrOverviewV2`):
- Panes are rendered in one dedicated tabpage with three normal windows (Summary/Activity/Collaboration).
- `a`/`d`/`c`/`m`/`k`/`b` keep the same review/browser actions.
- `<CR>` executes the action under cursor in the focused pane.
- `<CR>` on metadata rows handles PR edits contextually (title/description/state/draft/labels/reviewers/assignees/milestone).
- `<CR>` on `## Description` heading opens multiline composer (preloaded text, `<C-s>` submit, `q`/`<Esc>` cancel).
- `<CR>` on description link lines previews GitHub attachments or confirms browser-open for non-attachment links (multiple links => selector).
- `<CR>` on `Activity` thread headers opens compare diff from the thread comment commit to the latest file version.
- `gr` loads more activity events.
- `?` opens floating shortcuts help.
- `<Tab>` / `<S-Tab>` cycle panes.
- `g1` / `g2` / `g3` focus Summary / Activity / Collaboration.
- `<C-h>`/`<C-j>`/`<C-k>`/`<C-l>` switch focus between Summary/Activity/Collaboration panes.
- `<C-w>w` / `<C-w>W` cycle panes, `<C-w>h/j/k/l` focus Summary/Activity/Summary/Collaboration.

Diff backend behavior:
- gh-pr uses `codediff.nvim` as the primary backend for `Files`, `Commits`, overview diff actions, and comment/thread location opens.
- For PR/commit file diffs, gh-pr downloads base/head content from GitHub and opens codediff without git fetch.
- Starting or refreshing an active PR review warms textual PR file pairs in the background under the codediff temp cache, so later diff opens reuse local temp files.
- Diffs opened by gh-pr in codediff are forced to side-by-side layout.
- codediff windows opened by gh-pr force `number = true` and `relativenumber = true`.
- codediff temp buffers opened by gh-pr are forced readonly/non-modifiable (`nomodified`, `noswapfile`) to avoid save prompts on exit.
- gh-pr read-only URI buffers (`ghpr://...`, including virtual fallback diffs/overview preview surfaces) are kept `nomodified` via write guards + runtime safety-net to avoid accidental save prompts on exit.
- Text files open in codediff; image and generic binary/non-renderable files bypass codediff fallback prompts and open dedicated gh-pr non-text preview buffers.
- If codediff is unavailable or fails, gh-pr prompts once per session to decide whether to use legacy virtual fallback backend.
- If fallback is rejected, diff open actions return explicit errors.
- Inline comments/suggestions and diff comments panel are available in codediff file diffs (`head` side for inline actions).
- When Neo-tree is available, `<localleader>dc` opens a temporary bottom comments tree scoped to the current diff file (`thread -> comment`) and isolated from the other Neo-tree sources; set `diff_view.comments_panel.position = "right"` if you prefer a side pane. Otherwise gh-pr falls back to the legacy bottom panel.
- The diff comments UI renders lazily after codediff opens and only loads comments for the current file in the background.
- In codediff buffers, pressing `<CR>` on a commented line opens the existing line comments popup for that line.
- Inside line/thread comment popups, `r` opens a reply composer, `R` opens a quoted reply composer, `x` resolves/unresolves the selected thread, `e` edits your selected comment, `D` deletes it, and `+` / `-` open the emoji reactions picker for published comments. Draft comments in the current pending review support edit/delete but not reactions yet. Replies are added to the current pending review.
- Popup reaction summaries render emoji chips (`👍 2*`, `❤️ 1`, `🚀 3`) instead of raw GitHub enum names.
- The reactions picker opens as a dedicated two-row grid: quick reactions first, then the remaining reactions, with `h/j/k/l`, arrows, `<Tab>` / `<S-Tab>`, `<CR>`, `q`, and `<Esc>` support.
- `<localleader>dc` reports explicit errors when diff comments panel cannot be opened/refreshed.
- Line comment virtual text can show compact comment authors (`💬 @user1, @user2 +N`) in both codediff and virtual fallback buffers.
- Multiline review comments now mark the full line range (`startLine -> line`) in diff indicators.
- For multiline ranges longer than 200 lines, gh-pr marks the first 100 and last 100 lines.
- For a single multiline comment, each marked line shows progress label `💬 Lx/N` (and `@user` when `show_authors = true`).
- When a line has multiple comments, gh-pr shows compact overlap label `💬 N comments`.
- Legacy whitespace/layout toggle shortcuts are removed from defaults (`""`) and are only relevant in virtual fallback mode when explicitly mapped.
- Set `diff_view.debug.codediff_failures = true` to show reason/decision debug notifications for codediff failures, fallback routing, and review prefetch start/result events.

Inside legacy virtual file buffers (`GhPrOpenDiff`, `GhPrOpenOriginal`, `GhPrOpenModified`) when session fallback is active:
- all gh-pr diff actions are namespaced under `<localleader>` to avoid overriding native Neovim keys
- if `vim.g.maplocalleader` is unset, gh-pr uses `,` as fallback for diff-buffer shortcuts
- `<localleader>dk` show PR comments for the current line in a modal floating window (`base`/`head` views)
- `<localleader>dr` refresh current diff buffer from GitHub
- opening a diff shows a one-time hint with close shortcuts (`<localleader>dq` / `<localleader>dQ`)
- `<localleader>d?` show floating help with available PR diff shortcuts
- `<localleader>dq` quick close: in 2-way diff closes `modified/head`; in single-buffer view closes and opens `PR Review`
- `<localleader>dQ` close current diff view(s) and open/focus `PR Review`
- `<localleader>ic` add inline review comment at current line (`MODIFIED`/head or `unified`)
- visual `<localleader>ic` add inline review comment for selected line range (`v`/`V`, `MODIFIED`/head or `unified`)
- `<localleader>is` add inline suggestion comment at current line (`suggestion` template)
- visual `<localleader>is` add inline suggestion comment for selected line range (`v`/`V`)
- for `ADDED` files, `GhPrOpenDiff` opens a single MODIFIED buffer (no split/unified diff layout)
- virtual file content normalizes CRLF/LF/CR line endings, preventing `^M` artifacts
- non-text preview covers image files (`png/jpg/jpeg/gif/webp/bmp/svg`) and generic binary assets such as archives/media/documents
- image files render rich previews in virtual buffers when supported by `snacks.image`
- generic binary assets open readonly metadata/action cards with base/head sections when applicable
- for image files in `unified` mode, gh-pr forces split view (vertical/horizontal) instead of unified text diff
- in non-text preview buffers, line-comments popup, inline/suggestion actions, check annotation overlays, and diff comments tree auto-open are disabled
- in non-text preview buffers, `<localleader>io` runs the configured default preview action, `<localleader>im` opens the preview actions menu, and `<CR>` runs the action under cursor in metadata cards
- if image rendering is unavailable/unsupported, gh-pr stays in the same non-text preview flow and shows metadata/actions instead of dropping to codediff fallback prompts
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

Image rendering options (`diff_view.images`):
- `enabled` (`true`)
- `backend` (`"snacks"`)
- `formats` (`{ "png", "jpg", "jpeg", "gif", "webp", "bmp", "svg" }`)
- `cache_dir` (`nil` => `stdpath("cache")/gh-pr/images`)
- `fallback` (`"placeholder"`)
- `fallback_mode` (`"menu"`, also `"metadata_only"` / `"auto_local"` / `"auto_github"`)
- `fallback_default_action` (`"metadata"`, also `"open_local_current"` / `"open_local_both"` / `"open_github"`)
- `fallback_menu_keymap` (`"gf"`)
- `fallback_open_local` (`"disabled"`, also `"reveal_only"` / `"system"`)
- `fallback_github_target` (`"pr_files"`, also `"pr"`)
- `show_metadata` (`true`)
- `metadata_resolution_strategy` (`"hybrid"`, also `"internal"` / `"external"`)
- `metadata_external_command` (`{ "magick", "identify", "-format", "%w %h", "{file}" }`)
- `max_bytes` (`26214400`)

Non-text preview options (`diff_view.non_text`):
- `enabled` (`true`)
- `auto_preview` (`true`; image and generic binary files bypass codediff fallback prompts)
- `show_metadata` (`true`; render metadata/action cards for non-text preview buffers)

Inside `gh_pr_review` Neo-tree source:
- Root node shows active PR (`PR #N - title`) for current repository.
- Sections: `Overview`, `Labels`, `Files`, `Reviewers`, `Commits`, `Checks`, `Security`, `Comments`, `Drafts`.
- `Drafts` groups pending-review comments as `file -> thread -> draft comment` and opens the diff location for those draft items.
- `<CR>` actions:
  - `Overview` opens overview buffer
  - `Files` opens diffs
  - `Commits` expands selected commit and lists changed files
  - `Commit file` opens diff scoped to selected commit (`parent[1] -> commit`)
  - `Checks` lazy-loads annotations under `check -> file -> annotation`; pressing `<CR>` again toggles the subtree
  - `Check annotation` opens the PR diff on the modified side at the annotation line and paints that check's annotations over codediff
  - `Open check details` child keeps direct browser access to the check URL
  - `Security > Code scanning` lazy-loads `file -> alert`; pressing `<CR>` on an alert opens the modified-side diff at that line and paints loaded security findings for that file over codediff
  - `Security > Dependency review` lazy-loads `manifest -> dependency -> vulnerability`; pressing `<CR>` on a dependency without vulnerabilities opens the manifest diff, while vulnerability leaves open the advisory URL
- `Comments` keeps `Global` section (reviews, general comments, and orphan threads without file path)
- `Security` is fully lazy and split from `Checks`:
  - `Code scanning` loads classic GitHub code-scanning alerts for the PR only on demand
  - `Dependency review` loads dependency graph compare findings for the PR only on demand
  - unavailable/permission-limited repositories render `Unavailable: ...` instead of breaking the review tree
- `b` on security alert nodes opens the alert URL; `b` on dependency vulnerability nodes opens the advisory URL.
- `Global` includes review events, general PR comments, and orphan threads
- Thread nodes/items open file/line and thread popup when location exists
- Review/general comment nodes open timeline popup
- In `Files`, each file row uses right-aligned fixed indicators:
  - status letter (`A`/`M`/`D`/`R`/`C`) with status highlight,
  - viewed check icon (replaces textual `VIEWED`),
  - comment badge (`icon xN`) where `N` is total file comments (all states).
  - badges are rendered as one fixed right-side block to stay stable when toggling width (`e`) or resizing the Neo-tree window.
- In flat list mode (`zt`), each file row also shows muted parent-path context:
  - `filename.ext · path/to/parent`
  - long paths are compacted from the left (`…/Carpeta2/Carpeta3`).
- In `Files`, `zt` toggles a flat list mode (`no tree`) and persists globally.
- In `Files`, `/`, `z/`, `zs`, `ze`, `zn`, `z.`, `zu`, `zw`, `zh`, `zd`, and `zr` manage session-only path/status/extension/viewed/deleted filters.
- In `Files`, directory nodes show a yellow prefix `X/Y VIEWED` when at least one descendant file is viewed
  (counts are recursive and include subfolders).
- `v` on files toggles viewed state on GitHub when available and falls back to local state otherwise.
- Marking viewed/unviewed from `gh_pr_review` does not force-focus `gh_pr` panel.
- `R` forces a refresh from GitHub for the active review PR.
- `:GhPrOpenCommitPatch` opens selected commit diff in codediff (or virtual patch in session fallback backend).
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
- `zt` toggle `Files` list/tree mode (persisted globally).
- `zV` expand paths that contain viewed files.
- `zv` collapse paths that contain viewed files.
- `/` filter `Files` by path substring.
- `z/` clear `Files` path filter.
- `zs` select `Files` status filter.
- `ze` filter `Files` by extension.
- `zn` toggle `Files` no-extension filter.
- `z.` toggle `Files` dotfiles-only filter.
- `zu` toggle `Files` unviewed-only filter.
- `zw` toggle `Files` viewed-only filter.
- `zh` toggle `Files` hide-viewed filter.
- `zd` toggle `Files` hide-deleted filter.
- `zr` reset all session file filters.
- `zG` expand `Comments > Global` (including subgroups).
- `zg` collapse `Comments > Global` (including subgroups).

</details>

## Neo-tree source

The plugin exposes source modules:
- `gh_pr` (`lua/gh_pr.lua`)
- `gh_pr_review` (`lua/gh_pr_review.lua`)

`GhPrOpen` auto-manages `gh_pr` lazily:

- By default, `gh_pr` is auto-registered only when the current workspace passes an async Git probe and has a GitHub remote.
- `GhPrOpen` is idempotent: it focuses/shows `gh_pr` and does not toggle it closed on repeated calls.
- If the workspace probe is still running, `GhPrOpen` queues the open and completes it when the probe resolves.
- Registering `gh_pr` does not fetch PR data. The first fetch starts when Neo-tree navigates that source.
- `GhPrReviewTree` keeps toggle behavior for `gh_pr_review`.

Public config for PR source registration:

```lua
require("gh-pr").setup({
  ui = {
    neotree_sources = {
      pr = {
        auto_register = true,
        gate = "github_repo", -- "github_repo" | "git_repo" | "manual"
        workspace = "cwd", -- "cwd" | "buffer_repo" | "neotree_root"
      },
    },
  },
})
```

- `gate = "github_repo"` keeps `gh_pr` hidden unless the workspace resolves to a GitHub remote.
- `gate = "git_repo"` exposes `gh_pr` for any git repository.
- `gate = "manual"` disables auto-registration and preserves explicit source insertion only.
- `workspace = "cwd"` is the default. `buffer_repo` probes from the current buffer path, and `neotree_root` probes from the active Neo-tree root when available.

## Highlights

- Baseline `GhPr*` highlight groups are defined as links to standard Neovim groups.
- gh-pr re-applies those baseline links on every `ColorScheme` event.
- To override a group, set it in your own `ColorScheme` autocmd.

```lua
vim.api.nvim_create_autocmd("ColorScheme", {
  callback = function()
    vim.api.nvim_set_hl(0, "GhPrPrDraft", { link = "WarningMsg" })
    vim.api.nvim_set_hl(0, "GhPrOverviewBadge", { link = "StatusLine" })
  end,
})
```

## Notes

- Query definitions are persisted in `stdpath("state")/gh-pr/queries.json`.
- Viewed file state is persisted in `stdpath("state")/gh-pr/state.json`.
- Diff view preferences (`mode`, `ignore_whitespace`, `render_whitespace`, `render_endlines`) are persisted in `stdpath("state")/gh-pr/state.json`.
- Image fallback default action is persisted in `stdpath("state")/gh-pr/state.json`.
- PR Review Files mode (`tree/list`) is persisted in `stdpath("state")/gh-pr/state.json`.
- PR cache is persisted in `stdpath("state")/gh-pr/pr_cache.json`.
- Cache entries are scoped per source and repository key (`gh_pr` and `gh_pr_review`).
- File content is fetched from GitHub API through `gh api` and opened in readonly buffers.
- Read-only gh-pr UI buffers are kept `nomodified` and should not require save confirmation when closing Neovim.
- File open in PR views no longer falls back to patch (`@@`) buffers when content fetch fails; commit patch views remain explicit.
