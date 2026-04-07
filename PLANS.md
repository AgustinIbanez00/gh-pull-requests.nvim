# Overview Thread Cards Wave

## Status
- Completed: `Summary > Activity` review threads now render as collapsible cards with separators instead of header-only rows.
- Completed: open threads render expanded by default, while resolved/outdated threads render collapsed by default and can be toggled with `<CR>`.
- Completed: expanded thread cards now render per-comment bodies, reply indentation, and inline `diff` snippets focused on the commented lines.
- Completed: `D` on embedded overview thread headers now opens the existing thread diff/workspace flow while preserving lowercase `d` for review state changes.
- Completed: config/docs/smoke coverage updated for `overview.panes.activity.threads.*` and the `show_code_context` compatibility alias.
- Completed: repo validation passes: `git diff --check`, headless smoke, Neo-tree lazy smoke, and helptags.

## Acceptance Criteria
- Embedded overview activity threads render with visible separators between thread cards and between comments inside an expanded thread.
- Open threads are expanded by default; resolved/outdated threads are collapsed by default until toggled.
- Replies inside a thread are indented more than the first comment.
- Each expanded comment block can render an inline `diff` snippet from `diff_hunk`, focused around the commented lines.
- `<CR>` on an embedded activity thread header toggles the fold instead of opening the diff directly.
- `D` on an embedded activity thread header still opens the existing compare diff/workspace flow.
- README and vimdoc describe the new config and interaction model.

# Overview Two-Pane UX Wave

## Status
- Completed: overview panes now render as two real windows, with `Activity` embedded below PR description in `Summary`.
- Completed: pane navigation/help/docs updated to remove standalone `Activity` pane focus and describe the new two-pane layout.
- Completed: smoke coverage now asserts the embedded activity render shape, and repo validation equivalents pass (`headless_smoke`, Neo-tree lazy smoke, helptags).

## Acceptance Criteria
- Opening overview creates two panes: left `Summary` with embedded `Activity`, right `Collaboration`.
- `Collaboration` keeps its existing content and actions unchanged.
- `gr` still loads more activity from the overview while `Activity` renders immediately after PR description.
- Standalone `Activity` focus mappings are removed from active pane keymaps; legacy focus-role requests for `activity` degrade to `summary`.
- Repo validation passes: `git diff --check`, headless smoke, Neo-tree lazy smoke, and helptags.

# Security Hardening Wave

## Status
- Completed: external opener hardening for markdown link preview and non-text local asset access.
- Completed: secure defaults for `overview.markdown.link_preview_open_local` and `diff_view.images.fallback_open_local`.
- Completed: docs and smoke coverage updates for the new local-open policy.

## Acceptance Criteria
- `file://` and other non-`http(s)` links remain rejected by markdown preview/browser-open helpers.
- URL fallback no longer uses `cmd.exe /c start` on Windows.
- Local attachment opening defaults to `disabled`, with opt-in `reveal_only` or `system`.
- Dangerous local extensions are never opened via OS handler; they downgrade to reveal-only behavior.
- Attachment filename fallback no longer trusts an arbitrary markdown label to create an executable extension.
- Repo validation passes: headless smoke, Neo-tree lazy smoke, and helptags.

# Review File Badges Wave

## Status
- Completed: shared review-context helper for canonical repo/path resolution.
- Completed: `PR Review -> Files` canonicalization for comments and viewed badges, including rename handling.
- Completed: targeted smoke coverage for rename, repo-key mismatch, and path normalization.
- Completed: repo validation passes: headless smoke, Neo-tree lazy smoke, and helptags.

## Acceptance Criteria
- `PR Review -> Files` keeps the existing `M/A/D/R/C` badge behavior.
- Comment badges (`xN`) count comments for the canonical current file path, including comments/threads attached to `previousFilename`.
- Viewed badges use the repository key resolved from PR details, with the local repo only as fallback.
- Path normalization is consistent across `files.lua`, `actions.lua`, `state.lua`, and viewed-state syncing.
- Repo validation passes: headless smoke, Neo-tree lazy smoke, and helptags.

# Tooling / CI Wave

## Status
- Completed: GitHub Actions CI workflow runs the repo validation entrypoint on push to `main` and on pull requests.
- Completed: CI installs Neovim and `luacheck` before running validation.
- Completed: CI keeps smoke and helptags as blocking checks and runs `luacheck` as an advisory step until the warning baseline is reduced.
- Completed: README validation docs now describe the local/CI parity.

## Acceptance Criteria
- GitHub Actions runs the same `scripts/validate.ps1` entrypoint used locally.
- CI covers headless smoke, Neo-tree lazy smoke, helptags, and `luacheck`.
- Lint visibility is preserved without blocking merges on the current historical warning baseline.
- Workflow uses read-only repository permissions and does not require extra secrets for default validation.

# PR Codediff Explorer Wave

## Status
- Completed: default-enabled `diff_view.pr_explorer.enabled` option for compatible PR text diffs.
- Completed: reusable local codediff explorer session for PR file opens, including file reselection without rebuilding per-file tabs.
- Completed: reuse of prefetched remote file pairs when materializing the local PR explorer snapshot.
- Completed: entering the PR codediff explorer no longer auto-opens the focused file; it now lands in navigation mode and waits for manual selection.
- Completed: `ADDED` files in the PR codediff explorer render as single-file content instead of a full-file green diff.
- Completed: smoke/docs updates for routing, config defaults, and the PR explorer behavior.
- Completed: repo validation passes: `git diff --check`, headless smoke + helptags, and Neo-tree lazy smoke.

## Acceptance Criteria
- Compatible PR text-file opens use a local codediff explorer session by default and keep later file switches local/reused.
- Entering the PR codediff explorer positions the cursor on the requested file without auto-opening its diff.
- Manual selection from the PR codediff explorer is the only moment a file diff/content view is opened.
- `ADDED` files open as single-file content in the PR codediff explorer, without rendering the entire file as green diff noise.
- `open_diff`, `open_original`, `open_modified`, diff reopen, and PR file navigation reuse the PR explorer session when codediff is eligible.
- Non-text files and virtual-only layouts keep the existing non-text/virtual fallback flows.
- Disabling `diff_view.pr_explorer.enabled` preserves the legacy per-file codediff path.
- Repo validation passes: `git diff --check`, headless smoke + helptags, and Neo-tree lazy smoke.

# Diff Comments Panel No-Focus Refresh Wave

## Status
- Completed: removed automatic comment-follow navigation from the legacy diff comments panel and the Neo-tree diff comments source.
- Completed: active diff comments panels now stay visible during file changes, immediately render `Loading comments for ...`, and refresh in place without changing code-window focus.
- Completed: legacy diff comments loading/error/empty states now render with a muted highlight instead of regular content styling.
- Completed: config/docs were updated so `diff_view.comments_panel.follow_cursor` remains accepted for compatibility but is documented as deprecated/no-op.
- Completed: repo validation passes: `git diff --check`, headless smoke, and `:helptags doc`.

## Acceptance Criteria
- Moving the cursor inside the diff comments panel does not move the diff cursor or jump to comment targets automatically.
- Pressing `<CR>` / explicit open actions still navigate to the selected comment target.
- If the diff comments panel is already open for a tab, switching files keeps it open and replaces its contents with a loading state for the new file before async refresh completes.
- Refreshing the visible Neo-tree diff comments source reuses the existing source window instead of reopening/focusing it.
- `diff_view.comments_panel.follow_cursor` remains accepted in config for backward compatibility but no longer changes runtime behavior.

# PR Codediff Explorer Position Memory Wave

## Status
- Completed: passive explorer selection replays (`no_jump`) no longer trigger gh-pr diff syncing or single-file rendering.
- Completed: PR codediff explorer sessions now remember the last diff position per file and restore it when that file is selected again.
- Completed: the last focused diff side is tracked separately from explorer focus so `Ctrl-W w` into the explorer does not lose the side/line context that should be restored later.
- Completed: smoke coverage now exercises passive replay, explicit manual selection, and per-file position restoration across repeated file switches.
- Completed: repo validation passes: `git diff --check`, headless smoke, and Neo-tree lazy smoke.

## Acceptance Criteria
- Moving focus into the PR explorer must not bounce back to the diff window unless the user explicitly selects a file.
- Passive explorer refreshes/replays must not consume pending focus, trigger gh-pr selection sync, or open/render added-file single views.
- Explicit file selection in the PR explorer must still open/sync the selected file as before.
- After visiting a PR explorer file, changing hunks/lines, and selecting another file, returning to the original file restores the closest remembered diff position for that file.
- Position memory is tracked per file inside the PR explorer session, so revisiting multiple files restores each file independently.
