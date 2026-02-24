# gh-pull-requests.nvim

A Neovim plugin that brings a GitHub Pull Requests workflow (similar to VSCode) to Neovim, using `gh` CLI as backend.

## Features

- Query-based PR lists grouped by folders.
- Neo-tree source (`gh_pr`) as primary UI.
- Telescope fallback picker.
- Pull request overview interactive tabs UI (Snacks-based) with inline markdown rendering in PR description.
- Overview timeline tab that merges comments, reviews, and review-thread comments in chronological order.
- Open commit diffs directly from Overview > Commits (virtual patch buffers, no checkout).
- Virtual readonly file buffers for base/head versions (no disk writes).
- Side-by-side diff view for changed files.
- Configurable path rendering in `Files` and `Comments` trees (`compact`, `tree`, `flat`).
- Line comment indicators in PR file buffers (signcolumn + virtual text).
- Floating modal popup with PR line comments on `K` in virtual PR buffers.
- Comments tree (`gh_pr_comments`) with Problems-like navigation and preview.
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
- `:GhPrComments [number]` open PR comments tree (Problems-like), with `p` preview and enter-to-open navigation.
- `:GhPrRefresh` refresh data.
- `:GhPrOverview` open active PR overview interactive tabs buffer (requires `snacks.nvim`).
- `:GhPrOverviewRefresh` refresh active PR overview buffer in place.
- `:GhPrOverviewMore <checks|commits|timeline> [count]` load more section items.
- `:GhPrCheckout [number]` checkout PR branch.
- `:GhPrOpenDiff` open selected file in virtual base/head diff.
- `:GhPrOpenOriginal` open base version buffer.
- `:GhPrOpenModified` open head version buffer.
- `:GhPrToggleReviewed` toggle local viewed state.
- `:GhPrNextChange` jump to next diff hunk.
- `:GhPrPrevChange` jump to previous diff hunk.
- `:GhPrApprove` prompt review message and confirm before submit.
- `:GhPrRequestChanges` prompt review message and confirm before submit.
- `:GhPrComment` prompt review message and confirm before submit.
- `:GhPrMerge [merge|squash|rebase]` merge active PR.
- `:GhPrQueryAdd` add query.
- `:GhPrQueryEdit` edit query.
- `:GhPrQueryDelete` delete query.

## Default keymaps

- `<leader>gho` open PR UI.
- `<leader>ghl` open Telescope list.
- `<leader>ghm` open PR comments tree.
- `<leader>ghr` refresh.
- `<leader>ghv` PR overview.
- `<leader>ghc` checkout.
- `<leader>ghd` open diff.
- `C` in `gh_pr` Neo-tree source opens PR comments tree.
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
- `o` open PR in browser
- `C` open `Comments PR` tree for the current PR
- `q` close overview
- `H` / `L` previous/next tab
- `1..9` jump to tab
- `et` edit title
- `eb` edit description
- `el` edit labels (comma-separated, replacement mode)
- `er` edit reviewers (comma-separated, replacement mode)
- `ea` edit assignees (comma-separated, replacement mode)
- `em` edit milestone (empty input removes milestone)
- `es` change state (`open`/`closed`)
- `ed` toggle draft status (`ready`/`draft`)
- `<CR>` open selected row action
- `<CR>` on `Commits` opens commit diff details in a virtual patch buffer
- `gr` load more for current section tab
- `D` open diff for selected row (file or commit)
- `O` open original file for selected file row
- `M` open modified file for selected file row
- Every overview edit asks confirmation before execution and refreshes the overview on success.

Inside PR virtual file buffers (`GhPrOpenDiff`, `GhPrOpenOriginal`, `GhPrOpenModified`):
- `K` show PR comments for the current line in a modal floating window
- `,n` next diff change
- `,p` previous diff change
- `,f` next file in PR
- `,F` previous file in PR
- `,v` next reviewed file in PR
- `,V` previous reviewed file in PR

Inside `gh_pr_comments` Neo-tree source:
- `<CR>` open comment location
- `o` open comment location
- `p` preview comment location in right split
- `R` refresh comments
- Long threads open a focused floating buffer; navigate with normal motions and close with `q`/`<Esc>`

## Neo-tree source

The plugin exposes a source module named `gh_pr` (`lua/gh_pr.lua`).
`GhPrOpen` auto-registers the source in Neo-tree config at runtime.

## Notes

- Query definitions are persisted in `stdpath("state")/gh-pr/queries.json`.
- Viewed file state is persisted in `stdpath("state")/gh-pr/state.json`.
- PR cache is persisted in `stdpath("state")/gh-pr/pr_cache.json`.
- File content is fetched from GitHub API through `gh api` and opened in readonly buffers.
