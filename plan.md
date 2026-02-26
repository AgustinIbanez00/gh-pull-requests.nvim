# Plan de desarrollo: comentarios inline en buffers `MODIFIED`

Fecha: 2026-02-24
Repositorio: `gh-pull-requests.nvim`
Objetivo: permitir crear comentarios de review inline (línea/rango) desde buffers virtuales del PR, con editor flotante, confirmación y flujo de review pendiente.

## Estado general

- [x] 1. Investigación de API real (GitHub CLI + API)
- [x] 2. Diseño funcional del flujo end-to-end
- [x] 3. Implementación backend (`pr_service`)
- [x] 4. Implementación UI/acciones (`actions`, `virtual_files`)
- [x] 5. Comandos públicos (`plugin`, `init`)
- [x] 6. Refresco inmediato de comentarios/indicadores
- [x] 7. Documentación
- [ ] 8. Verificación final

## Tareas detalladas y subtareas

### 1) Investigación de API real (GitHub) [x]

- [x] 1.1 Listar PRs abiertos del repo de prueba `AgustinIbanez00/MiddleAmbientesQA`.
- [x] 1.2 Crear review pendiente de prueba y validar respuesta (`state = PENDING`).
- [x] 1.3 Probar endpoint REST `.../reviews/{id}/comments` y confirmar que no aplica (404).
- [x] 1.4 Probar endpoint REST `.../pulls/{n}/comments` con payload moderno y validar incompatibilidades para este flujo.
- [x] 1.5 Probar GraphQL `addPullRequestReviewThread` con `pullRequestId`, `path`, `line`, `body` y validar creación exitosa de thread inline.
- [x] 1.6 Conclusión técnica: priorizar GraphQL para comentarios inline (single/range), y mantener submit/discard de review pendiente por endpoints dedicados.

Notas de la prueba:
- Se creó un review pendiente de prueba y se obtuvo `id` válido.
- `addPullRequestReviewThread` devolvió `thread.id` válido, confirmando viabilidad para inline comments.

### 2) Diseño funcional del flujo [x]

- [x] 2.1 Definir comportamiento de `gc` en buffer `head` (`MODIFIED`) para modo normal y visual.
- [x] 2.2 Resolver extracción robusta de rango desde selección `v`/`V` (`'<`, `'>`).
- [x] 2.3 Definir política para buffer `base`/`patch` (mensaje claro de no soportado o fallback).
- [x] 2.4 Definir confirmación final antes de crear comentario.
- [x] 2.5 Definir UX de éxito/error y refresco del contexto de comentarios.

### 3) Backend `pr_service.lua` [x]

- [x] 3.1 Añadir resolución de `pullRequestId` y metadata necesaria del PR activo.
- [x] 3.2 Implementar helper para encontrar review pendiente del usuario actual.
- [x] 3.3 Implementar creación de review pendiente cuando no exista.
- [x] 3.4 Implementar creación de comentario inline single-line (GraphQL).
- [x] 3.5 Implementar creación de comentario inline multi-line/range (GraphQL con `startLine`/`line` y sides).
- [x] 3.6 Implementar submit de review pendiente con eventos:
- [x] 3.6.1 `COMMENT`
- [x] 3.6.2 `APPROVE`
- [x] 3.6.3 `REQUEST_CHANGES`
- [x] 3.7 Implementar discard/delete de review pendiente.
- [x] 3.8 Normalizar errores de API para mensajes útiles en Neovim.

### 4) UI/acciones `actions.lua` + `virtual_files.lua` [x]

- [x] 4.1 Crear módulo `comment_composer.lua` (ventana flotante editable, multilinea).
- [x] 4.2 Keymaps del composer (`<C-s>` confirmar, `q`/`<Esc>` cancelar, opcional `:wq` estilo modal).
- [x] 4.3 Integrar `gc` en buffer de diff para abrir composer con contexto de línea/rango.
- [x] 4.4 Implementar confirmación previa al submit (selector confirm/cancel).
- [x] 4.5 Integrar shortcuts de review pendiente en buffer diff:
- [x] 4.5.1 `,rs` submit comment review
- [x] 4.5.2 `,ra` approve
- [x] 4.5.3 `,rr` request changes
- [x] 4.5.4 `,rd` discard pending review
- [x] 4.6 Manejar foco/retorno de ventana correctamente al cerrar composer.

### 5) Comandos públicos (`plugin/gh-pr.lua` + `lua/gh-pr/init.lua`) [x]

- [x] 5.1 Exponer `GhPrReviewSubmit`.
- [x] 5.2 Exponer `GhPrReviewApprove`.
- [x] 5.3 Exponer `GhPrReviewRequestChanges`.
- [x] 5.4 Exponer `GhPrReviewDiscard`.
- [x] 5.5 Conectar comandos con `actions` y mensajes de resultado.

### 6) Refresco inmediato de comentarios e indicadores [x]

- [x] 6.1 Tras crear comentario inline, recargar threads del PR activo.
- [x] 6.2 Recalcular índice de line comments y reaplicar markers/extmarks/signs al buffer actual.
- [x] 6.3 Validar que `K` muestre el nuevo comentario sin reabrir archivo.
- [ ] 6.4 Validar comportamiento cuando el thread queda en rango sin línea visible.

### 7) Documentación (`README.md`, `doc/gh-pr.txt`) [x]

- [x] 7.1 Documentar `gc` (normal + visual).
- [x] 7.2 Documentar shortcuts `,rs`, `,ra`, `,rr`, `,rd`.
- [x] 7.3 Documentar flujo: composer -> confirmación -> pending review.
- [x] 7.4 Documentar limitaciones conocidas por tipo de buffer/lado.

### 8) Verificación final [ ]

- [x] 8.1 `nvim --headless` para validar carga del plugin y comandos nuevos.
- [ ] 8.2 Smoke test manual en PR real:
- [ ] 8.2.1 Crear comentario single-line.
- [ ] 8.2.2 Crear comentario multi-line con selección visual.
- [ ] 8.2.3 Ver comentario con `K` y en `Comments PR`.
- [ ] 8.2.4 Submit/approve/request changes/discard desde shortcuts.
- [ ] 8.3 Limpiar artefactos de prueba (sin dejar review pendiente innecesaria).

## Criterios de aceptación

- [x] Se puede comentar línea/rango desde `MODIFIED` usando `gc`.
- [x] El comentario se escribe en un editor flotante navegable y multilinea.
- [x] Siempre hay confirmación antes de enviar.
- [x] Se soporta review pendiente con submit/approve/request changes/discard.
- [x] Los comentarios nuevos se reflejan en indicadores de línea y popup `K`.
- [x] Los comandos y keymaps quedan documentados.

---

# Plan de desarrollo: refresh de datos con `R` (PR Review + buffers diff)

Fecha: 2026-02-25
Objetivo: refrescar contra GitHub desde el source `PR Review` y desde buffers virtuales de diff, sincronizando cache/UI.

## Estado general

- [x] 1. Refresh forzado en source `PR Review`
- [x] 2. Keymap `R` en buffers de diff
- [x] 3. Acción de refresh en buffer de diff (re-fetch de GitHub)
- [x] 4. Sincronización de sources (`PR` y `PR Review`) luego de refrescar
- [x] 5. Manejo de errores cuando el archivo ya no existe en el PR
- [x] 6. Documentación de shortcuts/comportamiento
- [ ] 7. Smoke test manual en Neovim con repo real

## Tareas detalladas y subtareas

### 1) Refresh forzado en source `PR Review` [x]
- [x] 1.1 Reusar `request_refresh(state, { force = true })` en comando `refresh`.
- [x] 1.2 Mantener mapping `R` en source `gh_pr_review`.

### 2) Keymap `R` en buffers diff [x]
- [x] 2.1 Agregar binding `R` en `virtual_files.set_pr_buffer_keymaps`.
- [x] 2.2 Conectar binding a acción `actions.refresh_current_diff_buffer`.

### 3) Acción de refresh en diff buffer [x]
- [x] 3.1 Resolver PR/file actual desde buffer metadata (`gh_pr_number`, `gh_pr_file_path`, `gh_pr_path`).
- [x] 3.2 Forzar fetch de detalles (`resolve_active_pr(..., { refresh = true })`).
- [x] 3.3 Reabrir buffer según tipo (`base`, `head`, `patch`/commit patch).
- [x] 3.4 Restaurar cursor tras reapertura.

### 4) Sincronización de fuentes [x]
- [x] 4.1 Extender helper de refresh para aceptar `opts.force`.
- [x] 4.2 Propagar refresh a `gh_pr` y `gh_pr_review` + `manager.refresh`.

### 5) Errores y edge cases [x]
- [x] 5.1 Notificar cuando el archivo desaparece del PR.
- [x] 5.2 Refrescar árbol igualmente ante error para limpiar estado visual.
- [x] 5.3 Corregir bug de orden de declaración (`normalize_path`) en `actions.lua`.

### 6) Documentación [x]
- [x] 6.1 README: incluir `R` en shortcuts de diff.
- [x] 6.2 `doc/gh-pr.txt`: describir `R` en `:GhPrOpenDiff`.

### 7) Verificación final [ ]
- [x] 7.1 Validación de carga headless de módulos clave (`actions`, `virtual_files`).
- [ ] 7.2 Prueba manual en Neovim con repo real y GitHub:
- [ ] 7.2.1 `R` en `PR Review` refresca nodos.
- [ ] 7.2.2 `R` en `head/base/patch` refresca contenido del buffer.

---

# Plan de desarrollo: validación previa de `gc` por modo de diff

Fecha: 2026-02-25
Objetivo: soportar comentarios inline en `head` y `unified` con validación previa para bloquear ubicaciones inválidas antes del composer.

## Estado general

- [x] 1. Confirmar restricción funcional de GitHub (comentarios fuera de hunk no válidos)
- [x] 2. Implementar validación para buffers `MODIFIED`/head
- [x] 3. Implementar validación para buffers `unified`
- [x] 4. Integrar validación antes de abrir composer (`gc`)
- [x] 5. Persistir metadata de líneas unified para mapear render->head
- [x] 6. Actualizar documentación de shortcuts/comportamiento
- [ ] 7. Smoke test manual contra PR real

## Tareas detalladas y subtareas

### 1) Confirmación de restricciones de GitHub [x]
- [x] 1.1 Validar regla: comentarios inline deben estar dentro del alcance de cambios/hunks.
- [x] 1.2 Definir política UX: bloquear temprano con mensaje claro.

### 2) Validación para `MODIFIED`/head [x]
- [x] 2.1 Parsear patch (`@@ -a,b +c,d @@`) para construir mapa de líneas válidas del lado head.
- [x] 2.2 Soportar línea única y rango visual (`v`/`V`).
- [x] 2.3 Bloquear comentario si cualquier línea cae fuera del mapa válido.

### 3) Validación para `unified` [x]
- [x] 3.1 Guardar `gh_pr_unified_line_map` por línea renderizada.
- [x] 3.2 Permitir comentario solo cuando la selección cae en líneas `+`.
- [x] 3.3 Exigir continuidad en rangos y mapear a líneas reales `head`.

### 4) Integración en acción `gc` [x]
- [x] 4.1 Resolver target (`path`, `line`, `start_line`) según modo actual.
- [x] 4.2 Ejecutar validación previa antes de abrir composer.
- [x] 4.3 Mantener confirmación final antes de enviar comentario a review pendiente.

### 5) Metadata unified en buffers virtuales [x]
- [x] 5.1 Extender generación de unified para devolver `line_map`.
- [x] 5.2 Persistir `line_map` al abrir y refrescar buffer unified.
- [x] 5.3 Mantener highlights `DiffAdd`/`DiffDelete` en contenido renderizado.

### 6) Documentación [x]
- [x] 6.1 README: actualizar `gc` para `head` + `unified`.
- [x] 6.2 Help doc (`doc/gh-pr.txt`): documentar restricciones por modo.

### 7) Verificación final [ ]
- [x] 7.1 Carga headless de módulos (`actions`, `virtual_files`) sin errores.
- [ ] 7.2 Prueba manual en repo real:
- [ ] 7.2.1 `gc` válido en `head` (línea y rango).
- [ ] 7.2.2 `gc` inválido fuera de hunk en `head` (bloqueo previo).
- [ ] 7.2.3 `gc` válido sobre `+` en `unified`.
- [ ] 7.2.4 `gc` inválido sobre `context`/`-` en `unified`.

---

# Plan de desarrollo: mejoras PR Review (labels, files viewed, timeline mixto)

Fecha: 2026-02-25
Objetivo: mejorar el source `PR Review` con labels, progreso de archivos vistos y timeline unificado de comentarios/reviews.

## Estado general

- [x] 1. Añadir carpeta `Labels` con color por label
- [x] 2. Mostrar progreso `Files X/Y viewed`
- [x] 3. Mostrar badge `VIEWED` en archivos revisados
- [x] 4. Agregar shortcuts simples `g/S/A/C/D` en `PR Review`
- [x] 5. Unificar `Comments` (threads + comments globales + reviews) ordenados por fecha
- [x] 6. Soportar apertura de items globales/review en popup legible
- [ ] 7. Smoke test manual completo en Neovim contra GitHub real

## Tareas detalladas y subtareas

### 1) Labels [x]
- [x] 1.1 Construir nodos de labels desde `details.labels`.
- [x] 1.2 Renderizar color dinámico por `#RRGGBB`.
- [x] 1.3 Agregar carpeta `Labels` al árbol de `PR Review`.

### 2) Files viewed [x]
- [x] 2.1 Contar total de archivos únicos del PR.
- [x] 2.2 Contar archivos marcados como viewed en runtime state.
- [x] 2.3 Renderizar título `Files <viewed>/<total> viewed`.
- [x] 2.4 Renderizar badge `VIEWED` en amarillo al lado del archivo.

### 3) Shortcuts `PR Review` [x]
- [x] 3.1 `g`: crear comentario global asociado al archivo seleccionado (pending review).
- [x] 3.2 `S`: submit pending review como comment.
- [x] 3.3 `A`: submit pending review como approve.
- [x] 3.4 `C`: submit pending review como request changes.
- [x] 3.5 `D`: descartar pending review.

### 4) Timeline Comments mixto [x]
- [x] 4.1 Reemplazar vista solo de threads por timeline combinado.
- [x] 4.2 Incluir `thread comments` con navegación a archivo/línea.
- [x] 4.3 Incluir `comments` globales y `reviews` en el mismo flujo cronológico.
- [x] 4.4 Abrir items sin archivo en popup navegable (focus + `q` para cerrar).

### 5) Backend comentario global en pending review [x]
- [x] 5.1 Implementar `pr_service.add_pending_review_comment`.
- [x] 5.2 Confirmar antes de persistir comentario global de archivo.
- [x] 5.3 Refrescar source/cache tras agregar comentario.

### 6) Verificación [ ]
- [x] 6.1 Validación de carga de módulos con `nvim --headless`.
- [ ] 6.2 Pruebas manuales:
- [ ] 6.2.1 `Labels` con color correcto.
- [ ] 6.2.2 Contador `Files X/Y viewed` consistente al togglear viewed.
- [ ] 6.2.3 `g/S/A/C/D` funcionando en PR real.
- [ ] 6.2.4 `Comments` mostrando threads + global + reviews y abriendo popup/archivo según corresponda.

---

# Plan de desarrollo: edición multi-select de Labels/Reviewers en PR Review

Fecha: 2026-02-25  
Objetivo: editar labels y reviewers desde `PR Review` con selector múltiple y confirmación.

## Estado general

- [x] 1. Implementar UI multi-select navegable en ventana flotante
- [x] 2. Integrar edición multi-select en Overview (`el`/`er`)
- [x] 3. Integrar shortcuts `l`/`r` en source `gh_pr_review`
- [x] 4. Cargar labels de repositorio desde GitHub API
- [x] 5. Cargar reviewer candidates (users + teams) desde GitHub API
- [x] 6. Mantener semántica replacement (`deselect = remove`) + confirmación
- [x] 7. Refrescar `PR`/`PR Review`/Overview tras aplicar
- [ ] 8. Smoke test manual en Neovim contra PR real

## Tareas detalladas y subtareas

### 1) UI multi-select [x]
- [x] 1.1 Crear módulo `lua/gh-pr/multi_select.lua`.
- [x] 1.2 Keymaps: `<Space>` toggle, `a` all, `n` none, `<CR>` confirm, `q/<Esc>` cancel.
- [x] 1.3 Renderizado de labels con color por highlight dinámico.

### 2) Integración en actions/overview [x]
- [x] 2.1 Reemplazar picker CSV en `edit_labels`/`edit_reviewers` por multi-select.
- [x] 2.2 Mantener input legacy para otros edits (`title/body/milestone/assignees`).
- [x] 2.3 Confirmar y aplicar con `pr_service.edit`.

### 3) Datos de GitHub [x]
- [x] 3.1 `pr_service.fetch_repo_labels` (paginado).
- [x] 3.2 `pr_service.fetch_reviewer_candidates` (users + teams, warning no bloqueante para teams).
- [x] 3.3 Caché corta en memoria (TTL 120s) por repositorio en `actions`.

### 4) PR Review shortcuts [x]
- [x] 4.1 Agregar comandos `edit_labels_multi` y `edit_reviewers_multi` en `review_commands`.
- [x] 4.2 Mapear `l`/`r` en `review_source`.

### 5) Documentación [x]
- [x] 5.1 README: actualizar atajos y semántica de remoción por deselección.
- [x] 5.2 `doc/gh-pr.txt`: actualizar overview y PR Review.

### 6) Verificación [ ]
- [x] 6.1 Carga headless de módulos actualizados.
- [x] 6.1.1 Smoke de API real (`fetch_repo_labels`/`fetch_reviewer_candidates`) sobre `AgustinIbanez00/MiddleAmbientesQA`.
- [x] 6.1.2 Normalización de reviewers robusta (`@login`, `org/team`, team suffix) validada en código.
- [ ] 6.2 Probar en PR real:
- [ ] 6.2.1 `l` edita labels en PR Review.
- [ ] 6.2.2 `r` edita reviewers (users + teams).
- [ ] 6.2.3 `el`/`er` en overview usan multi-select.

---

# Plan de desarrollo: rediseño de `PR Review > Comments` (árbol por archivo + global)

Fecha: 2026-02-25  
Objetivo: reemplazar la lista plana de timeline por un árbol UX que no muestre body en labels y cubra threads/reviews/comments.

## Estado general

- [x] 1. Reemplazar render plano por secciones `By File` + `Global`
- [x] 2. Agrupar threads por path/archivo (tree con carpetas y archivo expandible)
- [x] 3. Mostrar estado de thread en label (`[UNRESOLVED]`, `[RESOLVED]`, `[CLOSED]`)
- [x] 4. Mantener cobertura completa de eventos (threads + reviews + comments globales)
- [x] 5. Ajustar navegación `<CR>` para nuevos tipos de nodo
- [x] 6. Añadir iconos/highlights para nuevos nodos y estados
- [x] 7. Actualizar documentación (`README`, `doc/gh-pr.txt`)
- [ ] 8. Validación manual UX en Neovim con PR real

## Tareas detalladas y subtareas

### 1) Modelo y agrupación [x]
- [x] 1.1 Normalizar threads con metadata de estado, autor, fecha y target.
- [x] 1.2 Construir `By File` usando `path_tree`.
- [x] 1.3 Construir `Global` para reviews y comentarios generales.
- [x] 1.4 Evitar mostrar `body` del comentario en nombres de nodos.

### 2) Navegación y acciones [x]
- [x] 2.1 `comment_thread` / `comment_thread_item` abren archivo/línea + popup.
- [x] 2.2 Eventos globales abren popup timeline.
- [x] 2.3 Fallback a popup cuando no hay target navegable.

### 3) UI/estilos [x]
- [x] 3.1 Nuevo renderer `comment_file` (archivo expandible con icono de archivo).
- [x] 3.2 Iconos específicos para threads/reviews/comments.
- [x] 3.3 Highlights por estado de thread y estado de review.

### 4) Verificación [ ]
- [x] 4.1 Carga headless de módulos (`review_source`, `review_commands`, `components`).
- [ ] 4.2 Prueba manual:
- [ ] 4.2.1 Abrir `PR Review > Comments` y validar estructura `By File/Global`.
- [ ] 4.2.2 Verificar `<CR>` sobre thread, item de thread, review y comentario global.
- [ ] 4.2.3 Verificar colores de `[UNRESOLVED]/[RESOLVED]/[CLOSED]`.
