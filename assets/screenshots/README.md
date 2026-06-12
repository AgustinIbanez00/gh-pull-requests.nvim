# Screenshot Capture Guide

This directory is reserved for release screenshots used by the root README.
Capture real Neovim sessions from a non-sensitive repository so the images match the plugin's actual UI, theme, font, icon setup, and GitHub data flow.

## Target Files

| File | What to capture |
| --- | --- |
| `pr-list.png` | Neo-tree `gh_pr` source with PR rows and status badges. |
| `review-workspace.png` | `gh_pr_review` workspace with `Overview`, `Files`, `Checks`, `Comments`, and `Drafts` visible. |
| `overview.png` | `:GhPrOverview` with Summary + embedded Activity and Collaboration panes. |
| `codediff-explorer.png` | PR codediff explorer with a selected text file diff. |
| `thread-comments.png` | Thread/comment popup or diff comments panel in a PR diff. |
| `non-text-preview.png` | Optional image or binary preview buffer, if the release notes call it out. |

## Capture Checklist

- Use a public demo PR or sanitize private branch names, repo names, author names, paths, and comments before committing images.
- Use PNG for sharp terminal text; avoid JPEG compression.
- Keep a consistent terminal size, font, colorscheme, and icon setup across all images.
- Crop to the terminal window or relevant Neovim area only.
- Prefer 1400-1800 px width so GitHub renders the UI legibly in the README.
- Do not include credentials, tokens, internal URLs, private customer data, or local filesystem paths that should not be public.
- After adding images, embed only the most important 3-5 screenshots in the README and keep optional images behind a `<details>` block.
