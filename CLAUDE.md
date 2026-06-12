# CLAUDE.md

Contexto operativo para Claude Code sobre `gh-pull-requests.nvim`. Este archivo refleja el
**estado actual del repo**. Si modificas algo que cambie las secciones 3, 4, 6, 7 u 8,
actualizá este archivo en el mismo cambio.

Reglas y convenciones de estilo / refactor viven en `AGENTS.md` (no se duplican aquí).
Documentación de usuario vive en `README.md` y `doc/gh-pr.txt`.

## 1. Propósito

Plugin de Neovim que ofrece un workflow GitHub Pull Request estilo VSCode encima del CLI `gh`.

## 2. Stack y requisitos

- Lua, Neovim ≥ 0.9 (0.10+ recomendado para `vim.system` / `vim.ui.open`)
- `gh` autenticado (`gh auth login`) y working dir dentro de un repo git
- Dependencia obligatoria: `MeanderingProgrammer/render-markdown.nvim`
- Opcionales:
  - `nvim-neo-tree/neo-tree.nvim` — UI primaria (sources `gh_pr*`)
  - `nvim-telescope/telescope.nvim` — fallback / pickers
  - `esmuellert/codediff.nvim` — backend principal de diffs
  - `folke/snacks.nvim` — overview interactivo
  - `MunifTanjim/nui.nvim`, `nvim-tree/nvim-web-devicons`, `nvim-lua/plenary.nvim`

## 3. Layout del repositorio

```
plugin/gh-pr.lua              Entrypoint mínimo (lazy-by-design): commands + <Plug> + autocmds
lua/gh-pr/init.lua            Facade público: require("gh-pr").<method>(...)
lua/gh-pr/config.lua          Defaults + deep merge + validación
lua/gh-pr/commands.lua        Handlers de comandos auxiliares (queries, etc.)
lua/gh-pr/mappings.lua        Mappings opt-in / por-buffer
lua/gh-pr/state.lua           Estado runtime (active PR, viewed files, etc.)
lua/gh-pr/health.lua          :checkhealth gh-pr
lua/gh-pr/highlights.lua      Grupos GhPr* linkeados; reaplicados en ColorScheme
lua/gh-pr/utils.lua           Utilidades genéricas
lua/gh-pr/url_open.lua        Apertura de URLs (vim.ui.open + fallbacks)
lua/gh-pr/repo.lua            Helpers de repo git/remote
lua/gh-pr/gh.lua              Wrapper de bajo nivel sobre el CLI `gh`
lua/gh-pr/pr_service.lua      Servicio principal de PR (alto nivel, > 80 KB)
lua/gh-pr/queries.lua         Persistencia/manejo de queries de PR
lua/gh-pr/cache_store.lua     Caché por source/repo persistente en stdpath("state")
lua/gh-pr/comment_*.lua       Popups, threads, composer, acciones de comentarios
lua/gh-pr/diff_*.lua          Shortcuts y panel de diff
lua/gh-pr/check_annotations.lua, security_annotations.lua  Anotaciones GitHub
lua/gh-pr/image_*.lua         Render / metadata de imágenes en preview
lua/gh-pr/multi_select.lua    Selector multi-item para acciones bulk
lua/gh-pr/overview_*.lua      Estilos y utilidades del overview
lua/gh-pr/path_tree.lua       Construcción de árboles de paths (compact/tree/flat)
lua/gh-pr/pulls.lua           Helpers de listado
lua/gh-pr/reactions.lua       Reacciones de issues/PRs
lua/gh-pr/telescope.lua       Picker fallback (alto nivel)
lua/gh-pr/thread_popup.lua    Popup de thread completo
lua/gh-pr/line_comments.lua   Comentarios inline (signs, virtual text, popup)
lua/gh-pr/virtual_files.lua   Backend legacy de buffers virtuales (fallback de codediff)
lua/gh-pr/diff_comments_panel.lua Panel nofile legacy de comentarios (fallback sin neo-tree)
lua/gh-pr/diff_review_active_hunk.lua Autocmd CursorMoved → resalta hunk activo en gh_pr_diff_review

lua/gh-pr/entrypoint/         Specs declarativas que `plugin/gh-pr.lua` consume
  command_specs.lua           Tabla de :Gh* commands
  plug_specs.lua              Tabla de <Plug>(gh-pr-*) mappings
  autocmd_specs.lua           Autocmds neo-tree (FileType, DirChanged, Buf/Win/Focus)

lua/gh-pr/core/               Lógica de dominio
  activity.lua                Indicador de actividad centrado (ventana flotante) para llamadas bloqueantes a GitHub
  logger.lua                  Logger a disco por canal (lua/codediff/github/general) en stdpath("state")/gh-pr/logs
  runtime.lua                 ensure_initialized, auto-refresh timer, follow-current-file
  repository.lua              Resolución de repo activo
  notify.lua                  Helpers de vim.notify
  coerce.lua                  Coerciones de tipos
  diff_view.lua, diff_actions.lua, diff_hunks.lua  Helpers de diff
  overview_actions.lua, overview_edit_actions.lua, review_actions.lua
  review_context.lua          Estado de review activo
  review_prefetch.lua         Prefetch en background
  pr_service/                 Submódulos de pr_service.lua
    overview_model.lua        Modelo de overview (summary + activity)
    threads.lua               Hilos de review
    timeline.lua              Stream de actividad cronológico
    viewed_files.lua          Sync de viewed/unviewed con GitHub + persistencia local
    check_annotations.lua, code_scanning.lua, dependency_review.lua

lua/gh-pr/ui/
  reaction_picker.lua         Picker de reacciones
  overview/
    layout.lua                Layout (tabs)
    render.lua                Render del overview (~55 KB)
    runtime.lua               Runtime del overview
    keymaps.lua               Keymaps del overview
    edit_picker.lua           Picker de edición

lua/gh-pr/integrations/       Adaptadores opcionales (pcall(require))
  codediff.lua                Backend principal de diffs (~50 KB)
  neotree.lua                 Open/refresh sources, focus events
  neotree_fast_event.lua      Eventos rápidos de neo-tree
  telescope.lua               Open pull_requests / contextual / review actions

lua/gh-pr/actions.lua         Tabla de acciones públicas (~63 KB)
lua/gh-pr/actions/
  file_diff.lua               Apertura de diff de archivo
  thread_diff.lua             Diff con threads
  navigation.lua              next/prev change
  non_text_preview.lua        Preview unificado de imágenes/binarios
  review.lua                  Approve / request changes / comment / merge

lua/gh-pr/neotree/            Integración con neo-tree
  registry.lua                Registry runtime de sources por nombre
  source_entry.lua            Entry de source `gh_pr`
  source.lua                  Implementación de `gh_pr`
  review_source_entry.lua, review_source.lua          `gh_pr_review` (~68 KB)
  review_commands.lua         Comandos del PR Review tree
  comments_source_entry.lua, comments_source.lua      `gh_pr_comments`
  comments_commands.lua
  diff_comments_source_entry.lua, diff_comments_source.lua  `gh_pr_diff_comments` (legacy)
  diff_comments_commands.lua
  diff_review_source_entry.lua, diff_review_source.lua  `gh_pr_diff_review` (hunks + threads unificados)
  diff_review_commands.lua    Comandos del panel de review de diff
  my_pr_source_entry.lua, my_pr_source.lua            `gh_my_pr`
  components.lua              Componentes compartidos del árbol
  commands.lua                Comandos compartidos
  follow.lua                  Follow-current-file
  review_sections/            Secciones del review tree
    overview.lua, files.lua, reviewers.lua, drafts.lua,
    comments.lua, checks.lua, security.lua

lua/gh_pr.lua                 Shim top-level: neo-tree hace require("gh_pr")
lua/gh_my_pr.lua              Shim top-level para source `gh_my_pr`
lua/gh_pr_review.lua          Shim top-level para source `gh_pr_review`
lua/gh_pr_comments.lua        Shim top-level para source `gh_pr_comments`
lua/gh_pr_diff_review.lua     Shim top-level para source `gh_pr_diff_review`

doc/gh-pr.txt + doc/tags      Vimdoc
scripts/                      validate.ps1 + smokes (Lua y PowerShell) + code-scanner.py
assets/screenshots/           Capturas para README
.github/workflows/            CI (replica validate.ps1 + luacheck advisorio)
AGENTS.md                     Working agreements (reglas de estilo/arquitectura/refactor)
README.md                     Documentación de usuario
.luacheckrc                   Config luacheck
```

## 4. Sources neo-tree

Cada source tiene un shim top-level (`lua/<name>.lua`) que neo-tree espera vía
`require("<name>")`. No borrar los shims: son la API pública hacia neo-tree.

| Source name           | Shim                                                  | Propósito                                                     |
|-----------------------|--------------------------------------------------------|---------------------------------------------------------------|
| `gh_pr`               | `lua/gh_pr.lua`                                        | Listado/discovery de PRs por queries                          |
| `gh_pr_review`        | `lua/gh_pr_review.lua`                                 | Workspace de review activo (Overview/Files/Comments/etc.)     |
| `gh_my_pr`            | `lua/gh_my_pr.lua`                                     | Review del PR cuya HEAD branch coincide con la branch local   |
| `gh_pr_comments`      | `lua/gh_pr_comments.lua`                               | Comments view (legado/embed dentro de review)                 |
| `gh_pr_diff_review`   | `lua/gh_pr_diff_review.lua`                            | Panel unificado: Changes (hunks) + Comments (threads) del diff activo |
| `gh_pr_diff_comments` | *(sin shim top-level; legado)*                         | Panel legacy de comentarios sobre diffs                       |

`lua/gh-pr/neotree/registry.lua` mantiene los sources cargados:
`registry.get(name)` expone métodos como `request_refresh`, `is_focused`,
`follow_current_file_if_visible`, `invalidate_cache`.

## 5. Flujo de carga (lazy-by-design)

1. `plugin/gh-pr.lua` corre al startup. Sólo registra `:Gh*` commands, `<Plug>(gh-pr-*)` y los
   autocmds neo-tree desde las specs en `lua/gh-pr/entrypoint/`. **No hace `require` pesados.**
2. Cuando el usuario invoca un comando, llama `require("gh-pr").<method>` (facade en `init.lua`).
3. La primera invocación pasa por `with_runtime(...)` → `core.runtime.ensure_initialized`:
   verifica `render-markdown.nvim`, configura highlights, state, queries,
   arranca el timer de auto-refresh (`vim.uv` con `vim.schedule_wrap`) y registra autocmds:
   - `VimLeavePre` → para el timer
   - `BufEnter`/`WinEnter` → follow-current-file con debounce
   - `BufEnter`/`WinEnter`/`BufModifiedSet` → limpia `modified` en buffers `ghpr://` readonly
4. Heavy modules (`actions`, `pr_service`, `neotree.*`, `telescope`, `codediff`) se cargan
   diferidos dentro de los handlers; nunca en `plugin/`.

## 6. Comandos `:Gh*` principales

Declarados en `lua/gh-pr/entrypoint/command_specs.lua`. Los `<Plug>` espejo viven en
`plug_specs.lua`.

- **Discovery**: `GhPrOpen`, `GhPrList`, `GhPrTelescope`, `GhPrTelescopeActions`,
  `GhPrTelescopeReview`, `GhPrRefresh`
- **Review tree**: `GhPrReviewTree`, `GhPrMyPr` / `GhPrMyPR`, `GhPrComments [n]`,
  `GhPrStartReview [n]`, `GhPRReviewRefresh` / `GhPrReviewRefresh`
- **Overview**: `GhPrOverview`, `GhPrOverviewRefresh`,
  `GhPrOverviewMore <section> [count]` (sections: `checks|commits|comments|reviews|threads`)
- **Diff/file**: `GhPrOpenDiff`, `GhPrOpenOriginal`, `GhPrOpenModified`,
  `GhPrOpenCommitPatch`, `GhPrToggleReviewed`, `GhPrNextChange`, `GhPrPrevChange`
- **Review submit**: `GhPrApprove`, `GhPrRequestChanges`, `GhPrComment`,
  `GhPrReviewSubmit`, `GhPrReviewApprove`, `GhPrReviewRequestChanges`, `GhPrReviewDiscard`
- **Merge**: `GhPrMerge [merge|squash|rebase]` (default `merge`)
- **Checkout**: `GhPrCheckout [n]`
- **Queries**: `GhPrQueryAdd`, `GhPrQueryEdit`, `GhPrQueryDelete`,
  `GhPrQueriesPromptReset`, `GhPrQueriesReloadLua`
- **Logs**: `GhPrLogOpen [channel]`, `GhPrLogClear [channel]`, `GhPrLogLevel [level]`
  (channels: `lua|codediff|github|general`; levels: `error|warn|info|debug`)
- **Diff review panel**: `GhPrToggleReviewPanel`, `<Plug>(gh-pr-toggle-review-panel)`,
  buffer-local `diff_view.shortcuts.toggle_review_panel`
  (backward-compat alias: `GhPrToggleChangesPanel`, `M.toggle_changes_panel`)

## 7. Configuración

`require("gh-pr").setup(opts)` — sólo aplica config; el wiring pesado se difiere a la
primera invocación de un comando. Defaults completos en `lua/gh-pr/config.lua`. Bloques:

- `remotes` (default `{ "origin", "upstream" }`), `max_results`
- `file_list_layout` (`"tree" | "flat"`), `path_render` (`scope`, `mode`, `separator`,
  `show_status_prefix`)
- `pr_review.files.flat`, `hide_viewed_files`
- `line_comments`: `enabled`, `keymap`, `indicator_style`, `show_resolved`, `show_outdated`,
  `popup`, `virtual_text`, `comments_tree` (`preview`, `thread_popup`),
  `reactions`, `signs`
- `overview`: `ui` (`"snacks"`), `layout` (`"tabs"`), `expand_step`, `date_format`,
  `window`, `theme`, `markdown` (provider `render-markdown`, link preview, github_style)
- `log`: `enabled` (default `true`), `level` (`"error"|"warn"|"info"|"debug"`, default
  `"warn"`), `max_size_kb` (rotación por tamaño a `<channel>.log.old`, default `1024`).
  Archivos en `stdpath("state")/gh-pr/logs/{lua,codediff,github,general}.log`
- `cache.{gh_pr,gh_pr_review,gh_my_pr}`: `ttl_seconds`, `auto_refresh_when_focused`
- `follow_current_file`: `enabled`, `debounce_ms`,
  `sources.{pr,pr_review,my_pr}`
- `diff_view.review_panel`: `enabled`, `auto_open` (`"if_content"|"always"|"never"`),
  `position` (`"bottom"|"right"`), `height_ratio`, `min_height`, `max_height`,
  `show_resolved`, `show_outdated`, `close_with_dq`,
  `sections` (`changes`, `comments` — ambos `true` por default),
  `active_hunk_highlight` (`enabled`, `debounce_ms`)
  (backward-compat: `comments_panel` se migra automáticamente a `review_panel`)
- `ui.use_neotree`, `ui.telescope_fallback`

## 8. Convenciones internas

- Toda interacción con GitHub pasa por `lua/gh-pr/gh.lua` y `lua/gh-pr/pr_service.lua`
  (+ submódulos en `core/pr_service/`). Nuevas calls a `gh` van ahí, no dispersas.
- Highlights: nada hardcodeado. `highlights.lua` define grupos `GhPr*` con `link =`; se
  reaplican en autocmd `ColorScheme`.
- Buffers virtuales usan URI `ghpr://`. El runtime fuerza `readonly` y limpia `modified`
  automáticamente.
- En callbacks `vim.uv`/`vim.loop` no llames APIs no-fast: usá `vim.schedule_wrap`.
- Mappings: nunca globales por defecto. Exponer `<Plug>(gh-pr-*)` y `:Gh*`. Setear `desc`.
- Integraciones opcionales: `pcall(require, ...)` y degradación silenciosa. El autocmd
  spec usa `safe_neotree_callback` que aborta si `neo-tree` no está cargado.
- Cache persistente vive bajo `stdpath("state")` (`cache_store.lua`).
- Logging a disco va por `core/logger.lua` (canales `lua|codediff|github|general`). No
  escribas archivos de log ad-hoc: usá `logger.error/warn/info/debug(channel, msg)` con
  `pcall(require, ...)` desde módulos de bajo nivel. Errores de `gh` se loguean en `gh.lua`,
  errores Lua no atrapados de comandos en `init.lua` (`run_protected`), y todo `vim.notify`
  vía `core/notify.lua` se espeja al canal `general`.

## 9. Validación / smokes

Antes de cerrar cambios que toquen runtime, entrypoint, sources o UX:

- `pwsh -File scripts/validate.ps1` — smoke headless + helptags
- `pwsh -File scripts/validate.ps1 -WithLuacheck -WithCheckHealth` — extendido
- Smokes directos: `scripts/headless_smoke.{ps1,lua}`,
  `scripts/neotree_lazy_smoke.{ps1,lua}`

CI (`.github/workflows/ci.yml`) corre `validate.ps1` + `luacheck` advisorio en cada push a
`main` y en PRs.

## 10. Notas operativas para Claude

- Mantener la "lazy-by-design": al tocar `plugin/gh-pr.lua` o `init.lua`, no introducir
  `require()` pesados al startup.
- Si agregás/renombrás un módulo, actualizá la sección 3. Si es un source neo-tree,
  también la sección 4 (incluyendo el shim en `lua/`).
- Si agregás/quitás un comando, actualizá la sección 6 reflejando lo que hay en
  `entrypoint/command_specs.lua`.
- Si cambian defaults o se agregan claves nuevas, actualizá la sección 7 contra
  `config.lua`.
- Reglas de estilo/refactor que no estén acá: ver `AGENTS.md`.
