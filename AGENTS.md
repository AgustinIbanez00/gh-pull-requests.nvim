# AGENTS.md — Neovim plugin (Lua) working agreements

## Objective

Refactor/maintain this Neovim plugin to match modern best practices:

- Minimal startup cost (lazy-by-design, manager-agnostic)
- Clear modular architecture (responsibility + load-time)
- Non-intrusive UX (especially keymaps)
- Robust config (defaults + merge + validation)
- Optional integrations (pcall(require, ...))
- Strong docs (README + vimdoc doc/\*.txt)
- Incremental, reviewable changes with acceptance criteria

Codex reads AGENTS instructions in cascading order (global → repo root → deeper dirs).
Prefer small, durable rules here. If needed, add per-directory AGENTS.md.

## Neovim plugin architecture (must-follow)

### Lazy-by-design entrypoint

Use Neovim’s recommended mechanism:

- Keep `plugin/<name>.lua` SMALL: define commands/autocmds/<Plug> mappings only.
- Do NOT eagerly `require()` heavy modules there; defer `require()` inside callbacks.
  Neovim explicitly recommends this for implicit lazy-loading. :contentReference[oaicite:1]{index=1}

### Module boundaries (responsibility)

Prefer:

- `lua/<name>/init.lua` as public facade
- `lua/<name>/config.lua` defaults/merge/validate (+ types)
- `lua/<name>/commands.lua`, `autocmds.lua`, `mappings.lua`
- `lua/<name>/core/*.lua` domain logic
- `lua/<name>/ui/*.lua` UI & rendering
- `lua/<name>/integrations/*.lua` optional adapters
- `lua/<name>/health.lua` when diagnosing deps/config matters

## Keymaps policy (strict)

- Never create global default mappings that override the user.
- Expose actions through `<Plug>(...)` mappings and/or user commands.
- If providing defaults, make them opt-in or buffer-local; detect user mappings if relevant.
  The community best-practices explicitly recommend `<Plug>` mappings. :contentReference[oaicite:2]{index=2}

Always set `desc` for mappings.

## Config policy

- Defaults + deep merge (no ad-hoc mutation spread across modules).
- Validate types/fields early; produce clear, actionable errors.
- Keep `setup(opts)` = configuration only (avoid wiring heavy side-effects there).
- Keep backward compatibility when renaming options: support aliases + deprecation notice.

## Compatibility / minimum Neovim version

- Determine minimum supported Neovim version from:
  - APIs used (e.g., `vim.uv`, `vim.system`, `vim.fs`, etc.)
  - docs/README
- If `vim.uv` is used, remember its callback constraints:
  - Do NOT call non-fast `vim.api` inside `vim.uv` callbacks.
  - Use `vim.schedule()` / `vim.schedule_wrap()` to hop back to main loop. :contentReference[oaicite:3]{index=3}
- If you need backward compatibility for older Neovim:
  - Use guarded fallbacks (`vim.uv or vim.loop`) or feature checks.
  - If fallback is too costly, document a higher minimum version.

## Highlights & colors (plugin-friendly)

- Do NOT hardcode colors unless explicitly a “colorscheme plugin”.
- Define plugin highlight groups and LINK them to standard groups by default.
- Re-apply highlight links on `ColorScheme` autocmd (colorschemes overwrite groups).
  Example pattern: link groups via `nvim_set_hl(..., { link = "Statement" })`. :contentReference[oaicite:4]{index=4}
- Provide a documented way for users to override your groups.

## Namespaces, extmarks, buffer state

- Use a dedicated namespace created once via `nvim_create_namespace()` (idempotent by name).
  Namespaces are the standard way to manage highlights/virtual text/extmarks. :contentReference[oaicite:5]{index=5}
- Store per-buffer state keyed by bufnr; clean it up on `BufWipeout`/`BufUnload` if needed.
- For moving text, prefer extmarks and map extmark ids → your data for stable tracking. :contentReference[oaicite:6]{index=6}

## Optional dependencies / integrations

- Never hard-require other plugins.
- Use `pcall(require, ...)` and degrade gracefully if absent.
- Keep adapters in `lua/<name>/integrations/<target>.lua`.
- If using native packages: you may `packadd` an optional dependency when needed. :contentReference[oaicite:7]{index=7}

## UX & UI

- Prefer `vim.ui.select()` / `vim.ui.input()` for prompts to allow user backends.
- Notifications: use `vim.notify()` with levels; avoid noisy stack traces.
- Windows/floats should have predictable close keys (`q`/`<Esc>`) and avoid focus hijacking.

## Health checks

If there are external dependencies or complex setup, implement `:checkhealth` via a health module.

## Documentation requirements

### README.md must include

- What it does + usage overview
- Install examples (at least one manager + packpath note)
- Config options table + defaults
- Commands and `<Plug>` mappings (with user mapping examples)
- Troubleshooting + minimum Neovim version

### Vimdoc (`doc/<name>.txt`)

- Follow help-writing conventions and ensure `:helptags` works.
  Neovim documents help-writing and `:helptags`. :contentReference[oaicite:8]{index=8}

## Testing & smoke checks

- Prefer fast, headless checks where possible.
  Neovim supports `--headless` for scripting/tests. :contentReference[oaicite:9]{index=9}
- At minimum, provide:
  - formatting/lint if configured
  - headless smoke (load plugin, run 1–2 core commands)
  - `:helptags doc` validation step when doc changes

Before running commands, detect existing repo tooling (Makefile, justfile, scripts/, CI workflows) and follow it.

## Versioning / breaking changes

- Avoid breaking public API unless unavoidable.
- If breaking changes are required:
  - provide migration notes (README + CHANGELOG)
  - keep compatibility shims when feasible.

## Execution process (Waves)

Work in small waves:

- Wave 0: inventory + diagnosis + multi-plan (no code edits)
- Wave 1: startup/lazy + minimal entrypoint
- Wave 2: modularization
- Wave 3: keymaps/commands/UX polish
- Wave 4: docs + tooling/CI

Each wave must:

1. Gather evidence (rg/git ls-files/wc -l) before deep reading.
2. Propose 3 plans (conservative/balanced/aggressive).
3. Execute balanced unless it breaks compatibility.
4. Validate (quick checks).
5. Update `PLANS.md` with status + acceptance criteria.

