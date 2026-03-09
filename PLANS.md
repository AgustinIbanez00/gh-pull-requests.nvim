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
- Completed: repo validation passes: headless smoke, Neo-tree lazy smoke, and helptags.
- Pending: targeted smoke coverage for rename, repo-key mismatch, and path normalization.

## Acceptance Criteria
- `PR Review -> Files` keeps the existing `M/A/D/R/C` badge behavior.
- Comment badges (`xN`) count comments for the canonical current file path, including comments/threads attached to `previousFilename`.
- Viewed badges use the repository key resolved from PR details, with the local repo only as fallback.
- Path normalization is consistent across `files.lua`, `actions.lua`, `state.lua`, and viewed-state syncing.
- Repo validation passes: headless smoke, Neo-tree lazy smoke, and helptags.
