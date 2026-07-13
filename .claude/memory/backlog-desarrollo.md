# Backlog de desarrollo del widget

> Ideas de feature pedidas por unjordi, aún NO implementadas. Un ítem = un slice (ramita → MR →
> develop, squash). Al arrancar uno, muévelo a "en curso"; al cerrarlo con QA, bórralo de aquí y
> deja la huella en `bitacora.md`. Ordenado por lo más reciente arriba.

## [2026-07-12] Pain-points cosechados de los transcripts de cps (auditoría forense)
**Método (con autorización expresa de unjordi):** 4 agentes read-only barrieron los 11 transcripts de
cps (~35k líneas) por señales de falla (correcciones, reverts, huérfanos, FRENOs, reworks, bugs que el
QA humano cazó). 42 hallazgos crudos → los clusters de abajo. **Disciplina: [HECHO]=leído en el
transcript vs [INF]=inferido.** Cada uno lleva su casa (claude-brain hook/norma/skill · plantilla .NET ·
máquina). No son features del widget; son mejoras del CEREBRO. Un ítem = un slice futuro.

### A · Gobernanza de FAN-OUT / worktree / agentes (el cluster más grande — claude-brain)
- **A1. Agente escribió en el ÁRBOL PRINCIPAL → commit huérfano / HEAD reseteado** [HECHO] (2 incidentes; perdió horas de trabajo, recuperado por cherry-pick). → **PARCIALMENTE ABORDADO en #119** (regla dura de aislamiento + guard `proteger-arbol`). FALTA: check post-merge de huérfanos (`git fsck`/reflog); considerar un `worktree-guard` que bloquee un Task en background cuyo prompt apunte al repo principal sin `git worktree add`. **ALTA, recurrente.**
- **A2. Sub-agente ALUCINA que "dejó trabajo en background" y termina sin ejecutar nada** [HECHO] ("te aviso cuando termine" — no había hecho nada; los subagentes NO sobreviven a su turno). → inyectar en el prompt de TODO subagente: "eres TERMINAL, ejecuta el trabajo COMPLETO ahora, no puedes backgroundear ni esperar notificaciones"; el orquestador VERIFICA el repo read-only antes de creer el reporte. **ALTA, recurrente.**
- **A3. Deploy publicado DESDE el worktree de un agente (sin `appsettings.json` gitignored) → rompió app + login del usuario** [HECHO]. → regla dura: NUNCA publicar/deployar desde un worktree de agente; el deploy sale del clon principal tras `git pull`; pre-check si `pwd` contiene `.claude/worktrees/` + `dotnet publish`. **ALTA.**
- **A4. Orquestador "cruzó ramas debajo del agente"** (git checkout/build en el clon principal con agentes activos) [HECHO]. → con agentes activos, el orquestador no hace checkout/build en el clon principal (usa su propio worktree o espera). **MEDIA-ALTA.**
- **A5. Agentes devuelven STUB/plan en vez del trabajo real; briefs "a ciegas"** [HECHO]. → plantilla de prompt de delegación: "ENTREGA el artefacto ejecutado y verificado, NO un plan/stub; si no puedes, dilo"; el orquestador VALIDA el entregable (¿existe?, ¿compila?) antes de marcar hecho. **MEDIA, recurrente.**
- **A6. Mensajería orquestador↔subagente confusa** (una corrección se leyó como posible inyección) [INF]. → encabezado explícito de dirección en los mensajes de delegación (`[DE: orquestador → PARA: agente X]`). **MEDIA.**
- **A7. Implementación EN SERIE en vez de delegar** (el usuario tuvo que pedir que volviera a delegar) [HECHO]. → ya es norma; considerar señal más temprana (N ediciones seriadas sobre piezas independientes → autorecordatorio de fan-out). **MEDIA, recurrente.**
- **A8. Worktrees zombie + 2 convenciones** (`~/code/cps-wt-*` manual vs `.claude/worktrees/`) + cruft (`*.bak`, `.zip`) [HECHO/INF]. → unificar convención; que `limpiar-worktrees.sh` barra ambas; cruft al `.gitignore`. **BAJA.**

### B · Definición de LISTO / QA visual / verde-técnico≠listo (claude-brain — dod-verificar, cerrar-slice)
- **B1. "LISTO/✅/cerrado/terminamos/🏁🎉" declarado sobre verde técnico, luego desmentido** [HECHO] — **el fallo MÁS repetido de todos los transcripts** (≥5 y ≥37 turnos en dos sesiones). → `dod-verificar` debe cubrir ese léxico de cierre INCLUSO embebido en tablas/listas de estatus (✅, "hecho", "quedó"), no solo el resumen final; el "✅" solo junto a evidencia citada, si no → "▹ en preview". **ALTA, la reina.**
- **B2. QA visual "a ciegas": se insinuó QA de Chrome sin haber visto la pantalla** [HECHO] ("pensé que habías hecho QA en chrome"; bugs ya resueltos reaparecieron). → para slice de UI, si Chrome MCP está desconectado → PROHIBIDO léxico de QA visual; un claim visual ("se ve", "como el mockup") sin una tool-call de screenshot en el turno → degradar a "verificado técnicamente, SIN QA visual". **ALTA, recurrente.**
- **B3. UI construida y DESPLEGADA con componente/paquete nuevo sin poder verla** [HECHO] (SfToolbar salió invisible). → avisar "esto NO lo pude ver" ANTES de desplegar/pushear; preferir el patrón ya probado antes que un widget no verificable. **ALTA, recurrente.**
- **B4. Migración declarada "terminada" sin auditoría de paridad** [HECHO] (el usuario forzó 3 auditorías que destaparon huecos). → en migraciones, la prueba acordada para declarar avance es una AUDITORÍA DE PARIDAD legado→nuevo, no build+tests. **ALTA.**

### C · Doc = realidad — encabezado "miente arriba" / estado bidireccional (claude-brain — cerrar-slice, retomar-trabajo)
- **C1. Doc de estado crónicamente stale; ENCABEZADO/resumen viejo mientras el cuerpo avanza** [HECHO] (el usuario detectó el desfase 3×; "abre con 'dos hitos cerrados'…"). → al tocar un doc, RELEER su encabezado/resumen (no solo appendear); `grep` de los términos del cambio para cazar filas-resumen; posible hook `doc-header-stale`. **ALTA, recurrente.**
- **C2. Estado mentía en AMBOS sentidos** (marcaba pendiente lo ya hecho Y hecho lo no verificado) [HECHO]. → norma "estado bidireccional"; `retomar-trabajo` con un diff doc↔código al retomar. **ALTA.**

### D · Deploy verificado + runtime-safe (claude-brain norma + plantilla skills)
- **D1. Deploy sirvió artefacto VIEJO sin verificar vs commit** [HECHO] (caché de capa Docker; `.dockerignore *.md` excluyó `AGENTS.md` y congeló pisa; `appsettings.json` sobrescrito post-publish → login 405). → paso `verify-deploy`: confirmar DENTRO del contenedor que el asset servido contiene un marcador del commit esperado ANTES de declarar desplegado; hornear `appsettings` antes del publish. **ALTA, recurrente.**
- **D2. Verde técnico ≠ runtime-safe: bugs a develop Y a pisa** [HECHO] (13.º parámetro rompió la firma Dapper → 500; `Ok(string)` text/plain colgó el diálogo; `GETDATE()` concatenado → 0 filas). → `cerrar-slice`: para cambios de API/DTO/repos, smoke E2E mínimo EN DOCKER que golpee el endpoint; `agregar-tests`: cambiar firma materializada por Dapper exige verificar el SELECT del read-repo. **ALTA, recurrente.**
- **D3. Seeding incompleto; solo `down -v && up --build` lo destapa** [HECHO] (features "migradas" sin datos se veían vacías). → norma: una feature migrada no es verificable sin su dato semilla; el smoke de cierre de migración SIEMPRE arranca desde cero (`down -v`). **MEDIA-ALTA, recurrente.**

### E · Decisión destructiva NO transitiva (claude-brain norma)
- **E1. Se aplanó el esquema de permisos jerárquico (meses de trabajo) amparado en un doc (AGENTS.md), sin marcarlo como pérdida** [HECHO] ("nos costó MESES… NECESITAMOS la jerarquía"). → norma dura: una decisión que ELIMINA funcionalidad/complejidad existente es DESTRUCTIVA y NO transitiva aunque un doc la respalde → se surface explícitamente como pérdida y se pide OK; check en `cerrar-slice`/plan cuando el diff borra entidades/tablas. **ALTA.**

### F · Scripts / bash / commits frágiles (claude-brain — afecta a los propios hooks)
- **F1. Comandos git encadenados en loops de espera en BACKGROUND (`pgrep`/`pkill`) se truncan → commits a medias** [HECHO] (≥4×). → no encadenar git dentro de loops de espera background; separar "esperar" (Monitor/until) de acciones git (foreground, atómicas). **MEDIA, recurrente.**
- **F2. Scripts usan features de bash 4+ en el bash 3.2 de macOS** [HECHO] (`${EXT^^}`). → los `.sh` del cerebro deben ser bash-3.2-safe (nada `${x^^}`/`mapfile`/`declare -A` sin guarda); lint en `nuevo-script`. Relevante porque ahí viven los hooks. **BAJA (pero clase que afecta a los hooks).**
- **F3. Archivo de mensaje de commit frágil** [HECHO] (escrito DENTRO del repo por error; reutilizó uno viejo → commit con mensaje desactualizado → `--amend`). → nombre único en /tmp o heredoc `-F /dev/stdin`, nunca dentro del repo. **MEDIA, recurrente.**
- **F4. `--no-verify` en TODOS los commits (42×)** [HECHO] → bypassa hooks de pre-commit. Revisar que no anule guardarraíles que se quieran server-side. **BAJA.**

### G · .NET / plantilla — cosechar a SUS skills (no al claude-brain genérico)
- **G1. Gotchas Blazor/MudBlazor/WASM re-descubiertos a ciegas** [HECHO]: `AuthorizeView` dentro de `MudDialog` no evalúa; `pt-4` en `MudMainContent` esconde contenido; `MudIconButton`+`MudTooltip` en `MudButtonGroup` invisible; ICU `es-MX`→"MXN"/"MX$" no "$"; `accept` de input file NO valida drag&drop; `*/` mal puesto en comentario CSS corta el archivo. → cosechar como "trampas conocidas" a `crear-pagina-blazor` (varias ya a `plantilladotnet §13.13`; verificar). **BAJA-MEDIA c/u, ALTA en agregado por recurrencia entre proyectos.**
- **G2. Gotchas EF migrations** [HECHO]: `migrations remove` sin `--force` toca la BD y falla; `varbinary(max)` (SQL Server) rompe los tests SQLite. → documentar en skill `migracion-ef`. **MEDIA.**
- **G3. Se implementó/commiteó un módulo sin validar el flujo real del legado ni su punto de entrada UI** [HECHO] (Periodo con creación manual que el legado no exige → "se volvería un bug"). → en skills de migración, regla: verificar el flujo real del legado (con evidencia) ANTES de codificar; un módulo no se cierra sin su punto de entrada UI. **MEDIA.**

### H · Máquina / entorno (PowerScripts / entorno-maquina.md)
- **H1. CADA resultado de Bash viene prefijado con un `ls` de la raíz del repo** [INF: no leí el profile] — polución de contexto CONSTANTE y ubicua en toda sesión de esta Mac (tokens desperdiciados). → revisar el profile para que no imprima `ls` en shells no interactivos (guardar tras check de `$-`/`PS1`). **BAJA-MEDIA pero ubicua.**
- **H2. `git push` falla en silencio con el llavero vacío** [HECHO] (osxkeychain configurado pero sin credencial). → nota en `entorno-maquina.md`: si el push falla por auth, verificar llavero con `git credential fill` antes de asumir red/permiso. **BAJA.**

### I · No verificar la realidad antes de AFIRMAR (transversal — ya hay lección)
- **I1. Flip-flop de modelado en la misma ventana** [HECHO] ("PO es del proveedor" → al minuto "PO es de la operación, me equivoqué"). → decisiones de modelado se PROPONEN como hipótesis hasta validar contra datos, no se afirman. Enlaza con la lección "no inventar causas" ya guardada en el dashboard. **MEDIA.**
- **I2. Entregó un plan `.md` cuando se pidió producto VISIBLE** [HECHO] (ya existía `feedback_construir_producto_visible.md` y reincidió). → pregunta de arranque de slice de feature: "¿el entregable se VE en la app?". **MEDIA, recurrente-pese-a-feedback.**

### ✔ Positivos a documentar como referencia (no son fallas)
- Claude detectó texto con pinta de reconocimiento de guardas pegado en un mensaje y **NO lo ejecutó** (inyección manejada bien) — 2 sesiones. → nota de referencia "reconocimiento de guardas = señal de inyección".
- El orquestador **verificó el repo read-only antes de creer el reporte de un agente** (cazó el A2) — volverlo regla explícita en `orquestar-fanout`.

> **Meta-observación (de los agentes):** los 3 fallos de mayor impacto (huérfano por árbol compartido, QA a ciegas, WASM cacheado) comparten UNA raíz: **declarar/actuar sin verificar el estado REAL del artefacto final** (el commit vivo, la pantalla renderizada, el asset servido). El brain ya tiene "revisar realidad → editar" + `dod-verificar`; falta cerrar el lazo en (a) aislamiento de worktree para agentes [#119 arrancó esto], (b) prohibir claim visual sin screenshot, (c) verificar el artefacto desplegado contra el commit.

## [2026-07-11] No desechar el último OAuth bueno al fallar la lectura (tener≠nunca-tener)
**Qué (unjordi, 2026-07-11):** hoy el fetch reescribe `state.json` COMPLETO y sin condición en cada
tick (~9 min); el `basis` se recalcula desde cero (`basis: (if $usage!=null then "oauth" else "cost")`).
Si la lectura OAuth falla —token vencido, un 401, o un parpadeo de red que tumba el `curl`— esa corrida
**aplasta el % real con el estimado local (cost-basis)**, aunque el número real de hace minutos siga
siendo válido. Síntoma real: la Cachy con el token vencido 17h mostraba 5h=0% / semanal=1.1% mientras la
Mac (OAuth vivo) mostraba el real 98% / 50% — MISMA cuenta, números distintos solo por el basis.

**El principio (unjordi, textual):** *"no es lo mismo tener OAuth y perderlo a nunca haberlo tenido; si lo
tuvo y lo perdió, no debería desechar a lo wey."* → tres estados, no dos:
- **Nunca tuvo OAuth** (máquina fresca / sin login) → el estimado LOCAL (cost-basis) es lo mejor que hay. OK.
- **Tuvo OAuth y lo perdió, RECIENTE** (dentro de la ventana 5h/semanal) → **cargar hacia adelante el último
  % real marcado como STALE** (`basis:"oauth-stale"` + `stale_since`), NO aplastarlo con el estimado local.
- **Tuvo OAuth y lo perdió, VIEJO** (fuera de ventana → el número ya no significa) → degradar, pero aun así
  decir "último real: X% a las HH:MM, no puedo refrescar", nunca un 0% con cara de verdad.

**El patrón ya existe a medias:** líneas 42‑50 de `src/bin/claude-brain-fetch` YA cargan hacia adelante el
`resets_at` real del último OAuth cuando cae a fallback (un "próximo lunes" adivinado estaría mal). Solo hay
que **extender ese mismo mecanismo a los porcentajes** (y a `cost_usd`/`tokens`), con el timestamp de staleness.

**Unifica 3 cabos que salieron el mismo día** (NO tres ítems sueltos):
1. **No clobberear** el último-OAuth-bueno (este ítem, el núcleo).
2. **Auto-refresh del token**: el daemon podría refrescar con el `refresh_token` guardado (`claudeAiOauth.refreshToken`)
   en vez de esperar a que el humano abra `claude` — así una máquina inactiva no se queda ciega. (Evaluar riesgo:
   el CLI y Claude.app comparten el slot de credencial; un refresh a destiempo no debe pisar identidad — ya hay
   guard de account-mismatch.)
3. **Marcar visualmente** el modo stale/fallback en las 3 GUIs (⚠ / "estimado local" / "último real HH:MM")
   en vez de un número confiado. Un 0% confiado tapando un 98% real es la trampa de UX que hay que matar.

**Dónde toca:** `src/bin/claude-brain-fetch` + `macos/bin/claude-brain-fetch` (la lógica de basis + carry-forward);
Windows `QuotaService` (misma lógica en C#); el badge de estado en las 3 GUIs (Swift/QML/WinForms). **No urge**
(el caso se auto-cura al refrescar el token), pero es correctez de datos: el widget no debe mentir con cara de verdad.

## [2026-07-11] Arreglar el extractor de Chats (formato del app de escritorio cambió)
**Qué:** `bin/chats-extract.js` devuelve `[]` aunque el IndexedDB del app de escritorio TIENE datos
(~2.5 MB, app corriendo con chats activos) → la pestaña Chats se auto-oculta. El app de Claude **cambió
el formato de su cache** (update); el parser Snappy+V8/Blink de `chats-extract.js` ya no reconoce las
conversaciones. **NO es pérdida de datos** (los chats están en el app + claude.ai); es que nuestro lector
quedó desfasado. **Qué hacer:** re-ingeniería-inversa del nuevo formato (como el build original — un
snapshot del IndexedDB + inspeccionar el envelope/estructura) y actualizar `chats-extract.js`. Aplica a
las 3 plataformas (el extractor es compartido). **Fragilidad inherente:** leer un cache privado no
documentado se rompe con cada update del app → considerar si vale la pena mantenerlo vs. deprecar la
pestaña Chats. unjordi: al backlog, no urge (2026-07-11).

## [2026-07-10] Inicializar / reconciliar el cerebro GLOBAL + barrer todos los slugs desde el widget
**Qué:** una opción en la pestaña **Cerebro** (extiende la 🩹 curita, que hoy solo cura el cerebro
GLOBAL de la máquina) que:
1. **Inicializa/llena el dashboard-global** (`~/.claude/projects/<slug-del-HOME>/memory/dashboard_cerebro.md`)
   si falta o está vacío — sembrándolo de la plantilla (el bootstrap ya lo hace; esto lo EXPONE en el widget).
2. **Barre TODOS los slugs de proyecto** que el widget conoce y, para cada uno que mapee a un repo git,
   verifica/instala su cerebro: correr su `bootstrap-claude.sh` (instala los hooks GLOBALES de máquina +
   enlaza) y confirmar que su `.claude/` (hooks, settings.json, memoria) esté completo. **Reporta** cuáles
   repos les falta algo y ofrece arreglarlos.

**Por qué:** hoy no hay forma, desde el widget, de VER ni ARREGLAR el estado del cerebro de CADA proyecto
repartido por la máquina — solo del global. Al onboardear a un colega (caso Felipe, 2026-07-10) o al
retomar una máquina, se quiere un "reconciliar todo" de un clic.

**Matices / retos:**
- El widget ya conoce los slugs (`stats.projects` + `~/.claude/projects/<slug>/`), y el fetch ya
  normaliza slug → nombre de repo vía `~/.claude.json` (`.projects`). Reusar esa resolución para hallar
  la RUTA del repo de cada slug.
- **No silencioso:** no todo slug es un repo git clonable, y correr `bootstrap-claude.sh` en cada repo es
  invasivo → el patrón debe ser **detectar + reportar + ofrecer arreglar** (opt-in por repo), no auto-correr.
- Las versiones del cerebro entre repos pueden diferir (plantilla vs claude-brain) — reportar divergencias
  en vez de pisarlas a ciegas.
- **Dónde toca:** `BrainInspector`/`healBrain` de la pestaña Cerebro (macOS `PopoverView.swift`, Linux
  `main.qml`, Windows `PopupForm.cs`), + una pasada nueva que itere slugs→repos.

## HECHO (fuera del backlog) — 2026-07-11
- **Contexto al renombrar sesión (+ "Sugerir nombre")** y **Mover sesión entre slugs** →
  IMPLEMENTADOS en las 3 GUIs (#104/#106, en develop; `bin/sessions-extract.js` +summary/+slug y
  `bin/session-move.js`). QA visual parcial de unjordi (macOS). Detalle en `claude-quota-widget.md`
  (sección 2026-07-11) y bitácora del dashboard. Decisión del "cwd": el move SÍ reescribe el cwd
  interno (con respaldo) para que `--resume` quede coherente; no hay "memorias por-sesión" que mover.
