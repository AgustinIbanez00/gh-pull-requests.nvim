# gh-pull-requests.nvim

A GitHub Pull Request workflow for Neovim (VSCode-like), powered by the GitHub CLI (`gh`).

[![Neovim](https://img.shields.io/badge/Neovim-0.9%2B-57A143?logo=neovim&logoColor=white)](#requirements)
[![License](https://img.shields.io/badge/License-MIT-yellow.svg)](./LICENSE)
[![Release](https://img.shields.io/github/v/release/AgustinIbanez00/gh-pull-requests.nvim)](https://github.com/AgustinIbanez00/gh-pull-requests.nvim/releases)
[![CI](https://github.com/AgustinIbanez00/gh-pull-requests.nvim/actions/workflows/ci.yml/badge.svg)](https://github.com/AgustinIbanez00/gh-pull-requests.nvim/actions/workflows/ci.yml)
[![Last Commit](https://img.shields.io/github/last-commit/AgustinIbanez00/gh-pull-requests.nvim)](https://github.com/AgustinIbanez00/gh-pull-requests.nvim/commits/main)
[![Stars](https://img.shields.io/github/stars/AgustinIbanez00/gh-pull-requests.nvim?style=social)](https://github.com/AgustinIbanez00/gh-pull-requests.nvim/stargazers)
[![Validation](https://img.shields.io/badge/Validation-scripts%2Fvalidate.ps1-blue)](#validation)

Quick links: [Installation](#installation) · [Quick Start](#quick-start) · [Commands](#commands) · [Keymaps](#keymaps) · [Query Placeholders](#query-placeholders)

## Table of Contents

- [Features](#features)
- [Screenshots](#screenshots)
- [Requirements](#requirements)
- [Validation](#validation)
- [Installation](#installation)
- [Quick Start](#quick-start)
- [Query Placeholders](#query-placeholders)
- [Commands](#commands)
- [Keymaps](#keymaps)
- [Troubleshooting](#troubleshooting)
- [Consolidated architecture](#consolidated-architecture)
- [Neo-tree source](#neo-tree-source)
- [Highlights](#highlights)
- [Notes](#notes)
- [Overview API](#overview-api)
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
- Branch-aware personal review source (`gh_my_pr`) that appears only when the current local branch matches a PR head in the same repository.
- Start review flow from PR nodes (`r`) with optional GitHub pending-review creation.
- Review actions: approve, request changes, comment, merge (`merge/squash/rebase`).

### 📝 Overview + Activity

- Two-pane overview (Summary + embedded Activity, plus Collaboration).
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
- PR Review > Commits opens the same full commit diff explorer as Overview (`codediff`, no checkout).
- Configurable path rendering in `Files` and `Comments` trees (`compact`, `tree`, `flat`).
- Comments view migrated into PR Review > Comments (Problems-like navigation and preview preserved).
- PR checkout via `gh pr checkout`.

</details>

## Screenshots

Release screenshot assets should live under [`assets/screenshots/`](assets/screenshots/).
Use the tracked [screenshot capture guide](assets/screenshots/README.md) to keep filenames, scope, and privacy checks consistent before embedding PNGs in this section.

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
GitHub Actions CI uses the same validation entrypoint on every push to `main` and on pull requests, and runs `luacheck` as a separate advisory step while the repo still carries a historical warning baseline.
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
- `luacheck` only when `-WithLuacheck` is used locally; CI runs it separately as an advisory step
- `gh auth login` recommended when `-WithCheckHealth` is used

## Installation

### lazy.nvim

```lua
{
  "AgustinIbanez00/gh-pull-requests.nvim",
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
          gap = 1, -- compatibility spacing option for pane layout
          min_left_width = 58,
          min_sidebar_width = 30,
        },
        activity = {
          visual_style = "minimal", -- "minimal" | "classic"
          max_body_lines = 8, -- max body lines per event/comment block
          max_events = 120, -- max rendered timeline events in embedded activity stream
          show_code_context = true, -- compatibility alias for threads.diff.enabled
          threads = {
            collapse_resolved = true, -- resolved threads start collapsed
            collapse_outdated = true, -- outdated threads start collapsed
            separator_char = "─", -- repeated between thread cards
            separator_length = 54,
            reply_indent = 2, -- extra spaces for replies inside a thread
            diff = {
              enabled = true, -- render inline diff snippets per comment
              style = "snippet", -- currently "snippet"
              context_before = 2,
              context_after = 2,
              max_lines = 12,
              separator_char = "─",
              separator_length = 38,
            },
          },
        },
        keymaps = {
          cycle_next = "<Tab>",
          cycle_prev = "<S-Tab>",
          focus_summary = "g1",
          focus_meta = "g3",
          help = "?",
          focus_left = "<C-h>",
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
        pr_changes = true, -- show PR metadata/state change events inside the embedded Summary activity stream
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
      gh_my_pr = {
        enabled = true,
        ttl_seconds = 30,
        auto_refresh_when_focused = true,
        max_cache_age_seconds = 300,
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
        my_pr = true,
      },
    },
    diff_view = {
      mode = "vertical", -- "vertical" | "horizontal" | "unified"
      ignore_whitespace_mode = "none", -- "none" | "trim" | "eol" | "blank_lines"
      ignore_whitespace = false, -- deprecated alias: true -> "trim", false -> "none"
      render_whitespace = true,
      render_endlines = false, -- render LF/CRLF/CR markers at EOL
      debug = {
        codediff_failures = false, -- when true, show debug notifications for codediff errors/fallback decisions and review prefetch activity
      },
      pr_explorer = {
        enabled = true, -- reuse a local codediff explorer for compatible PR file diffs
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
        inline_comment = "<localleader>c",
        inline_suggestion = "<localleader>s",
        line_comments_popup = "<localleader>k",
        refresh = "<localleader>R",
        close_quick = "<localleader>q",
        close_all_open_review = "<localleader>Q",
        help = "<localleader>?",
        next_change = "<localleader>n",
        prev_change = "<localleader>p",
        next_file = "<localleader>f",
        prev_file = "<localleader>F",
        next_reviewed_file = "<localleader>v",
        prev_reviewed_file = "<localleader>V",
        toggle_whitespace = "", -- quick toggle between "none" and "trim"
        cycle_whitespace_mode = "",
        toggle_render_whitespace = "", -- virtual diff backend only
        toggle_render_endlines = "", -- virtual diff backend only
        cycle_mode = "",
        set_vertical = "",
        set_horizontal = "",
        set_unified = "",
        submit_pending_comment = "<localleader>rc",
        submit_pending_approve = "<localleader>ra",
        submit_pending_request_changes = "<localleader>rr",
        discard_pending_review = "<localleader>rd",
        toggle_review_tree = "<localleader>rx",
        toggle_comments_panel = "<localleader>C",
        toggle_changes_panel = "<localleader>o",
        image_default_action = "<localleader>io",
        image_fallback_menu = "<localleader>im",
        show_open_hint = true, -- show one-time "how to close diff" hint per diff buffer
      },
      changes_panel = {
        enabled = true,
        auto_open = true, -- opens beside textual PR file diffs without stealing focus
        position = "right", -- "right" | "left"
        width = 34,
        min_width = 24,
        max_width = 50,
      },
      comments_panel = {
        enabled = true,
        auto_open = "if_comments", -- current diff file only; "if_comments" | "never" | "always" (also accepts true => "if_comments", false => "never")
        position = "bottom", -- "bottom" | "right" for the temporary Neo-tree diff comments source
        height_ratio = 0.28, -- bottom Neo-tree diff comments pane height (also used by the legacy fallback panel)
        min_height = 8, -- bottom Neo-tree diff comments pane minimum height
        max_height = 18, -- bottom Neo-tree diff comments pane maximum height
        follow_cursor = false, -- deprecated/no-op; comment navigation now only happens on explicit open actions
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
        my_pr = {
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
| Opening PR diffs triggers unrelated C#/Roslyn/LSP work | Does the other plugin respect `b:gh_pr_lsp_exclude` / `b:gh_pr_codediff_temp`? | Skip `ghpr://...` buffers and codediff cache snapshots from workspace/LSP resolution. |
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

## Overview API

Use the canonical `overview` configuration table, `:GhPrOverview` command,
and `require("gh-pr").open_overview()` facade. The overview implementation
lives under `lua/gh-pr/ui/overview/*`.

## Commands

| Command | Description | Typical use |
| --- | --- | --- |
| `:GhPrOpen` | Focus/open PR UI (idempotent; Neo-tree first, Telescope fallback) | Start or refocus a PR browsing session |
| `:GhPrStartReview [number]` | Start review flow for selected PR | Enter review workspace quickly and warm textual diffs in background |
| `:GhPrReviewTree` | Toggle PR Review source | Jump between list and review tree |
| `:GhPrMyPr` / `:GhPrMyPR` | Open current-branch personal PR source | Review your own branch-matched PR with local editable diffs |
| `:GhPrOverview` | Open active PR overview panes | Inspect summary/activity and collaboration |
| `:GhPrOpenDiff` | Open selected file diff or non-text preview | Review code and assets |
| `:GhPrOpenCommitPatch` | Open selected commit diff in codediff | Inspect commit-level changes |
| `:GhPrToggleReviewed` | Toggle viewed state | Track reviewed files |
| `:GhPrToggleChangesPanel` | Toggle current diff hunk panel | Navigate file changes from a side pane |
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
- `:GhPrOverview` open active PR overview panes (Summary + Activity / Collaboration).
- `:GhPrOverviewRefresh` refresh active overview panes.
- `:GhPrOverviewMore <checks|commits|comments|reviews|threads> [count]` load more section items.
- `:GhPrMyPr` open `My PR` source for the current branch when it matches a PR in the current repository.
- `:GhPrMyPR` alias for `:GhPrMyPr`.
- `:GhPrCheckout [number]` checkout PR branch.
- `:GhPrOpenDiff` open selected file in codediff for text, or dedicated gh-pr preview for non-text.
- `:GhPrOpenOriginal` open selected file and focus base side in codediff when possible, or dedicated base-side preview for non-text.
- `:GhPrOpenModified` open selected file and focus head side in codediff when possible, or dedicated head-side preview for non-text.
- `:GhPrOpenCommitPatch` open selected commit diff in codediff.
- `:GhPrToggleReviewed` toggle viewed state (GitHub when available, local fallback otherwise).
- `:GhPrNextChange` jump to next diff hunk.
- `:GhPrPrevChange` jump to previous diff hunk.
- `:GhPrToggleChangesPanel` toggle the side panel for current file hunks.
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
| `<Plug>(gh-pr-my-pr)` | Open My PR source |
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
| `<Plug>(gh-pr-toggle-changes-panel)` | Toggle current diff hunk panel |
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
| `<CR>` on actionable reviewer row | Re-request review when `· <CR> re-request` is visible |
| `<CR>` on `## Description` | Edit description in multiline composer |
| `<CR>` on description link line | Preview attachment or confirm-open link (multiple links => selector) |
| `<CR>` on thread header | Open thread evolution diff (comment commit -> latest file) |
| `gr` | Load more activity |
| `D` / `O` / `M` | Open diff / original / modified |

#### Diff buffer (`<localleader>` namespace)

| Key | Action |
| --- | --- |
| `<localleader>R` | Refresh current diff buffer |
| `<localleader>q` / `<localleader>Q` | Quick close / close and open review |
| `<localleader>n` / `<localleader>p` | Next / previous diff change |
| `<localleader>f` / `<localleader>F` | Next / previous file |
| `<localleader>v` / `<localleader>V` | Next / previous reviewed file |
| `<localleader>k` / `<localleader>C` | Line comments popup / comments panel |
| `<localleader>c` / `<localleader>s` | Inline comment / inline suggestion |
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
- `gh_pr` PR rows keep `#number + title` as the primary text and move metadata into a right-aligned badge cluster.
- that cluster uses compact tokens such as `@author`, `DRAFT`, `RUN`/`OK`/`FAIL`, `CONFLICT`, `REQ`/`PEND`, and `APP<n>` when detailed PR metadata is available.
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
- `gh_my_pr` reuses the same sections and mappings as `gh_pr_review`, but it only appears when the current local branch matches a PR head in the same repository.
- In `gh_my_pr > Files`, codediff opens the GitHub base side against the real local worktree file on the modified side, so the right-hand buffer stays editable.
- `gh_pr_review > Files` uses the same local editable head behavior when the active review PR is authored by the current GitHub user and the checkout is on that PR's head branch.
- `gh_pr`, `gh_pr_review`, and `gh_my_pr` do not bind `<space>` by default (keeps `<leader>` available when `mapleader = " "`).
- `gh_pr`, `gh_pr_review`, and `gh_my_pr` prioritize PR-specific mappings over generic Neo-tree filesystem mappings.
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
- `Collaboration > Reviewers` shows per-reviewer rows such as `@user [APPROVED]` and `org/team [PENDING]`.
- reviewer state prefers current pending requests, then `latestReviews`, then `reviews` ordered by `submittedAt`; it does not use the old "most severe historical state" rule.
- reviewer rows only expose `· <CR> re-request` when that reviewer is currently eligible for a GitHub re-request.
- `<CR>` on `## Description` heading opens a large multiline composer preloaded with current body (`<C-s>` submit, `q`/`<Esc>` cancel)
- `<CR>` on a description body line with a single markdown/http(s) link opens preview/link action for that link
- `<CR>` on a description body line with multiple links opens a selector menu first
- state row uses direct toggle (`open`/`closed`) with confirmation
- draft row uses direct toggle (`ready`/`draft`) with confirmation
- `<CR>` on `Commits` opens the full commit diff in codediff (or legacy virtual fallback if selected for this session)
- `<CR>` on `Summary > Activity` thread headers toggles collapsed/expanded state
- `gp` preview markdown link under cursor in PR description
- `gr` load more for current section tab (`Summary` loads more Activity)
- `D` open diff or secondary action for the selected row
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
- `Summary > Activity` threads render as collapsible cards with separators, reply indentation, and inline `diff` snippets focused on the commented lines.
- Open threads render expanded by default; resolved and outdated threads render collapsed by default.
- `<CR>` on a thread header toggles the fold, and `D` opens the thread diff/workspace directly.
- If inline patch resolution fails, `overview.thread_fix_diff.fallback_to_buffer = true` falls back to legacy diff buffers.
- `,x` toggle PR Review source while staying in review flow.
- gh-pr UI windows (overview panes, popups and composer) force `nospell` without affecting regular file buffers.

Inside overview panes (`:GhPrOverview`):
- Panes are rendered in one dedicated tabpage with two normal windows (Summary+Activity/Collaboration).
- `a`/`d`/`c`/`m`/`k`/`b` keep the same review/browser actions.
- `<CR>` toggles embedded activity thread headers and keeps the previous open/edit behavior for the rest of the rows.
- `D` opens the diff or secondary action for the selected embedded activity item.
- `<CR>` executes the action under cursor in the focused pane when the row is not a thread header.
- `<CR>` on metadata rows handles PR edits contextually (title/description/state/draft/labels/reviewers/assignees/milestone).
- `<CR>` on `## Description` heading opens multiline composer (preloaded text, `<C-s>` submit, `q`/`<Esc>` cancel).
- `<CR>` on description link lines previews GitHub attachments or confirms browser-open for non-attachment links (multiple links => selector).
- `gr` loads more activity events inside `Summary`.
- `?` opens floating shortcuts help.
- `<Tab>` / `<S-Tab>` cycle panes.
- `g1` / `g3` focus Summary / Collaboration.
- `<C-h>` / `<C-l>` switch focus between Summary / Collaboration panes.
- `<C-w>w` / `<C-w>W` cycle panes, `<C-w>h/l` focus Summary/Collaboration.

Diff backend behavior:
- gh-pr uses `codediff.nvim` as the primary backend for `Files`, `Commits`, overview diff actions, and comment/thread location opens.
- For PR/commit file diffs, gh-pr downloads base/head content from GitHub and opens codediff without git fetch.
- Starting or refreshing an active PR review warms textual PR file pairs in the background under the codediff temp cache, so later diff opens reuse local temp files.
- With `diff_view.pr_explorer.enabled = true` (default), compatible PR text-file opens reuse a local codediff explorer session for the active PR snapshot, so later file switches stay local and faster.
- On a cold PR explorer cache, gh-pr opens the selected file first and prepares the full PR explorer snapshot in the background with lightweight progress notifications. When the snapshot is ready, the next compatible file open reuses the explorer without stealing focus.
- Text PR/commit file diffs stay in codediff whenever `diff_view.mode` is `vertical` or `unified` and `diff_view.ignore_whitespace_mode` is `none` or `trim` (or the legacy `ignore_whitespace = true|false` alias mapped to `trim|none`).
- `vertical + none|trim` opens codediff side-by-side, `unified + none|trim` opens codediff inline, and `horizontal` or whitespace modes `eol` / `blank_lines` are rendered through gh-pr's virtual diff backend.
- PR explorer mode applies only to compatible textual PR files; image/binary files and virtual-only layouts still use the existing non-text or virtual fallback paths.
- Legacy persisted/configured `ignore_whitespace_mode = "all"` is coerced to `trim` on load so older state keeps working without silently falling back to `none`.
- `render_whitespace` and `render_endlines` remain virtual-backend-only markers; codediff buffers show that those markers are unavailable there.
- codediff windows opened by gh-pr force `number = true` and `relativenumber = true`.
- codediff temp buffers opened by gh-pr are forced readonly/non-modifiable (`nomodified`, `noswapfile`) to avoid save prompts on exit.
- transient diff buffers also set `b:gh_pr_lsp_exclude = true` and `b:gh_pr_transient_diff_buffer = true`; codediff cache snapshots additionally set `b:gh_pr_codediff_temp = true` so external LSP/workspace resolvers can skip them safely.
- gh-pr read-only URI buffers (`ghpr://...`, including virtual fallback diffs/overview preview surfaces) are kept `nomodified` via write guards + runtime safety-net to avoid accidental save prompts on exit.
- Image and generic binary/non-renderable files bypass codediff fallback prompts and open dedicated gh-pr non-text preview buffers.
- If codediff is unavailable or fails for a codediff-eligible diff, gh-pr prompts once per session to decide whether to use the virtual fallback backend for the rest of the session.
- If fallback is rejected, diff open actions return explicit errors.
- Neovim 0.10+ is recommended for non-blocking codediff GitHub fetches through `vim.system`; on older Neovim versions the compatibility fallback may still block while shelling out to `gh`.
- Inline comments/suggestions and diff comments panel are available in codediff file diffs; codediff inline/unified buffers use the modified side for inline actions.
- Line comment indicators/authors are rendered in codediff side-by-side, codediff inline, and gh-pr virtual unified text diffs.
- When Neo-tree is available, `<localleader>C` opens a temporary bottom comments tree scoped to the current diff file (`thread -> comment`) and isolated from the other Neo-tree sources; set `diff_view.comments_panel.position = "right"` if you prefer a side pane. Otherwise gh-pr falls back to the legacy bottom panel.
- The diff comments UI renders lazily after codediff opens and only loads comments for the current file in the background. If the panel is already open, gh-pr keeps it visible, shows a muted `Loading comments for ...` state for the new file, and refreshes it without moving focus or following comment nodes automatically.
- `<localleader>o` toggles a nofile side panel listing hunks for the active textual PR file diff. Auto-open is enabled by default, does not steal focus, and manual close suppresses auto-open in that tab until toggled again. Non-text previews do not auto-open the panel.
- In codediff and virtual text diff buffers, pressing `<CR>` on a commented line opens the existing line comments popup for that line.
- Inside line/thread comment popups, `r` opens a reply composer, `R` opens a quoted reply composer, `x` resolves/unresolves the selected thread, `e` edits your selected comment, `D` deletes it, and `+` / `-` open the emoji reactions picker for published comments. Draft comments in the current pending review support edit/delete but not reactions yet. Replies are added to the current pending review.
- Popup reaction summaries render emoji chips (`👍 2*`, `❤️ 1`, `🚀 3`) instead of raw GitHub enum names.
- The reactions picker opens as a dedicated two-row grid: quick reactions first, then the remaining reactions, with `h/j/k/l`, arrows, `<Tab>` / `<S-Tab>`, `<CR>`, `q`, and `<Esc>` support.
- `<localleader>C` reports explicit errors when diff comments panel cannot be opened/refreshed.
- Line comment virtual text can show compact comment authors (`💬 @user1, @user2 +N`) in codediff and virtual text diff buffers, including unified views.
- Multiline review comments now mark the full line range (`startLine -> line`) in diff indicators.
- For multiline ranges longer than 200 lines, gh-pr marks the first 100 and last 100 lines.
- For a single multiline comment, each marked line shows progress label `💬 Lx/N` (and `@user` when `show_authors = true`).
- When a line has multiple comments, gh-pr shows compact overlap label `💬 N comments`.
- Whitespace/layout shortcuts are removed from defaults (`""`) and only activate when you map them explicitly; render markers (`toggle_render_whitespace`, `toggle_render_endlines`) apply only in the virtual diff backend.
- Set `diff_view.debug.codediff_failures = true` to show reason/decision debug notifications for codediff failures, fallback routing, and review prefetch start/result events.

Inside gh-pr virtual diff buffers (`GhPrOpenDiff`, `GhPrOpenOriginal`, `GhPrOpenModified`) when hybrid routing or session fallback selects the virtual backend:
- all gh-pr diff actions stay under a short `<localleader>` namespace to avoid overriding native Neovim keys
- if `vim.g.maplocalleader` is unset, gh-pr uses `,` as fallback for diff-buffer shortcuts
- `<localleader>k` shows PR comments for the current line in a modal floating window (`base`/`head` views)
- `<localleader>R` refreshes the current diff buffer from GitHub
- opening a diff shows a one-time hint with close shortcuts (`<localleader>q` / `<localleader>Q`)
- `<localleader>?` shows floating help with available PR diff shortcuts
- `<localleader>q` quick close: in 2-way diff closes `modified/head`; in single-buffer view closes and opens `PR Review`
- `<localleader>Q` closes current diff view(s) and opens/focuses `PR Review`
- `<localleader>C` toggles the diff comments panel
- `<localleader>o` toggles the diff changes panel
- `<localleader>c` adds an inline review comment at current line (`MODIFIED`/head or `unified`)
- visual `<localleader>c` adds an inline review comment for the selected line range (`v`/`V`, `MODIFIED`/head or `unified`)
- `<localleader>s` adds an inline suggestion comment at current line (`suggestion` template)
- visual `<localleader>s` adds an inline suggestion comment for the selected line range (`v`/`V`)
- for `ADDED` files, `GhPrOpenDiff` opens a single MODIFIED buffer (no split/unified diff layout)
- virtual file content normalizes CRLF/LF/CR line endings, preventing `^M` artifacts
- non-text preview covers image files (`png/jpg/jpeg/gif/webp/bmp/svg`) and generic binary assets such as archives/media/documents
- image files render rich previews in virtual buffers when supported by `snacks.image`
- generic binary assets open readonly metadata/action cards with base/head sections when applicable
- for image files in `unified` mode, gh-pr forces split view (vertical/horizontal) instead of unified text diff
- in non-text preview buffers, line-comments popup, inline/suggestion actions, check annotation overlays, and diff comments tree auto-open are disabled
- in non-text preview buffers, `<localleader>io` runs the configured default preview action, `<localleader>im` opens the preview actions menu, and `<CR>` runs the action under cursor in metadata cards
- if image rendering is unavailable/unsupported, gh-pr stays in the same non-text preview flow and shows metadata/actions instead of dropping to codediff fallback prompts
- in `ADDED` single-buffer mode, `<localleader>c` is allowed on any line/range
- inline comments are pre-validated before opening the composer:
  - `MODIFIED`/head must be inside PR diff hunks
  - `unified` is limited to added (`+`) lines in the diff
- inline comment editor uses `<C-s>` to submit draft and `q`/`<Esc>` to cancel
- `<localleader>n` next diff change
- `<localleader>p` previous diff change
- `<localleader>f` next file in PR
- `<localleader>F` previous file in PR
- `<localleader>v` next reviewed file in PR
- `<localleader>V` previous reviewed file in PR
- file navigation shortcuts always reopen the full diff view using the active render mode (`vertical`/`horizontal`/`unified`)
- `<localleader>rc` submit pending review as comment
- `<localleader>ra` submit pending review as approve
- `<localleader>rr` submit pending review as request changes
- `<localleader>rd` discard pending review
- `<localleader>rx` toggle PR Review source
- codediff-backed file diffs keep native codediff keys such as `q`, `g?`, `t`, `]c`, `[c`, `do`, `dp`, and `gf`; gh-pr help also lists them, plus `gm` when codediff moved-code alignment is enabled
- in codediff-backed file diffs, native `q` closes the codediff tab while `<localleader>q` remains the gh-pr quick-close action
- `t` only toggles codediff between side-by-side and inline; horizontal split remains a gh-pr virtual-backend mode

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

Inside `gh_pr_review` and `gh_my_pr` Neo-tree review sources:
- Root node shows active PR (`PR #N - title`) for current repository.
- Sections: `Overview`, `Labels`, `Files`, `Reviewers`, `Commits`, `Checks`, `Security`, `Comments`, `Drafts`.
- `Drafts` groups pending-review comments as `file -> thread -> draft comment` and opens the diff location for those draft items.
- `<CR>` actions:
  - `Overview` opens overview buffer
  - `Files` opens diffs
  - `Commits` opens the full commit diff in codediff, matching Overview
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
- `gh_my_pr` differs only in how it is selected and how `Files` opens text diffs: it resolves the PR from the current branch automatically and uses the local worktree file as codediff head when possible.
- `gh_pr_review` also uses local editable head diffs for your own active review PR when your checkout is on the PR head branch.

</details>

## Neo-tree source

The plugin exposes source modules:
- `gh_pr` (`lua/gh_pr.lua`)
- `gh_pr_review` (`lua/gh_pr_review.lua`)
- `gh_my_pr` (`lua/gh_my_pr.lua`)

`GhPrOpen` auto-manages `gh_pr` lazily:

- By default, `gh_pr` is auto-registered only when the current workspace passes an async Git probe and has a GitHub remote.
- `GhPrOpen` is idempotent: it focuses/shows `gh_pr` and does not toggle it closed on repeated calls.
- If the workspace probe is still running, `GhPrOpen` queues the open and completes it when the probe resolves.
- Registering `gh_pr` does not fetch PR data. The first fetch starts when Neo-tree navigates that source.
- `GhPrReviewTree` keeps toggle behavior for `gh_pr_review`.
- `gh_my_pr` is auto-managed independently from `gh_pr`: it appears only when the current branch matches a PR head in the same repository, and it disappears again when that match no longer exists.
- `gh_my_pr` shares the same review UI as `gh_pr_review`, but `Files` opens text diffs against the local worktree file on the modified side, so the head buffer remains editable.

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
      my_pr = {
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
- `my_pr` uses the same gate/workspace options, but it still requires a GitHub repository and a current local branch that matches a PR head to become eligible.

## Highlights

- Baseline `GhPr*` highlight groups are defined as links to standard Neovim groups.
- gh-pr re-applies those baseline links on every `ColorScheme` event.
- Reviewer state tokens in `Overview > Collaboration` use `GhPrOverviewReviewerApproved`, `GhPrOverviewReviewerPending`, `GhPrOverviewReviewerChanges`, and `GhPrOverviewReviewerCommented`.
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
- Diff view preferences (`mode`, `ignore_whitespace_mode`, legacy `ignore_whitespace`, `render_whitespace`, `render_endlines`) are persisted in `stdpath("state")/gh-pr/state.json`.
- Image fallback default action is persisted in `stdpath("state")/gh-pr/state.json`.
- PR Review Files mode (`tree/list`) is persisted in `stdpath("state")/gh-pr/state.json`.
- PR cache is persisted in `stdpath("state")/gh-pr/pr_cache.json`.
- `setup({ diff_view = ... })` defines the default diff prefs; when `state.json` contains `prefs.diff_view`, those persisted runtime choices override the Lua defaults on later sessions.
- Per-open diff overrides do not rewrite `state.json`; only the runtime diff actions persist updated diff prefs.
- `diff_view.shortcuts.*` remain Lua-configured and opt-in; they are not read from or written to `state.json`.
- Cache entries are scoped per source and repository key (`gh_pr`, `gh_pr_review`, and `gh_my_pr`).
- File content is fetched from GitHub API through `gh api` and opened in readonly buffers, except `gh_my_pr > Files` where the modified side uses the local worktree file when available.
- Read-only gh-pr UI buffers are kept `nomodified` and should not require save confirmation when closing Neovim.
- File open in PR views no longer falls back to patch (`@@`) buffers when content fetch fails; commit patch views remain explicit.
