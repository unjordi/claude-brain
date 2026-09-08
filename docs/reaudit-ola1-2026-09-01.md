# Re-auditoría OLA1 + prep OLA2 — ciclo brain-widget (cortex)

> Dictamen READ-ONLY · 2026-09-01 · repo `unjordi/cortex` · `develop` @ `5771fbc`
> Auditor: Ingeniería de Calidad (continuación de `docs/auditoria-ciclo-brain-widget-2026-08-29.md`,
> cuya base era `main` @ `472e9c7`). NO se modificó código; única escritura permitida, este archivo.
> Commits verificados: `cd8a467` (#341, resolve_brain_dir) y `5771fbc` (#342, escape discoverable).

---

## 1. Verificación OLA1

### 1.1 `resolve_brain_dir()` compartida (#341) — ✅ CONFIRMADO

- **Función única**, definida en `brain/hooks/drift-cerebro-comun.sh:49-56`, orden
  `$CLAUDE_BRAIN_DIR` (si existe como dir) → `~/.cortex` → `~/.claude-brain` → default `~/.cortex`.
  Fail-open (siempre imprime algo, nunca aborta).
- **Barrido de `grep -rn 'CLAUDE_BRAIN_DIR:-' brain/`** encontró 4 hits residuales, TODOS legítimos
  (fallback-del-fallback, no ruta primaria):
  - `brain/hooks/verificar-cerebro.sh:35` — dentro de un `else` que solo corre si
    `drift-cerebro-comun.sh` no está presente junto al script (línea 30-36).
  - `brain/hooks/proteger-fuente-cerebro.sh:48` — mismo patrón (línea 43-49).
  - `brain/hooks/exportar-sesion-master.sh:113` — mismo patrón (línea 108-114).
  - `brain/sesiones-master/install-hook.sh:28` — mismo patrón (línea 23-29).
  En los 4 casos, la ruta primaria (`if [ -f "$SELFDIR/drift-cerebro-comun.sh" ]`) llama
  `resolve_brain_dir()`; el hardcode viejo solo sobrevive como red de seguridad si la lib faltara
  (caso raro, documentado inline). **Ningún sitio quedó sin migrar.** Cero regresión de la asimetría
  bash-vs-widget que motivó C2.
- `bash -n` limpio en los 6 archivos tocados (`drift-cerebro-comun.sh`, `aviso-drift-cerebro.sh`,
  `verificar-cerebro.sh`, `proteger-fuente-cerebro.sh`, `exportar-sesion-master.sh`,
  `sesiones-master/install-hook.sh`) — reverificado, coincide con lo que registró la bitácora.

### 1.2 Nudge de `aviso-drift-cerebro.sh` — ✅ CONFIRMADO local, sin red

- Bloque `MIGRACION_WARN` en `brain/hooks/aviso-drift-cerebro.sh:130-151`: la detección es
  **exclusivamente** `[ -d "$HOME/.claude-brain/.git" ] && [ ! -d "$HOME/.cortex" ]` (línea 146) —
  dos `test -d`, cero `git fetch`/`curl`/llamada de red. El `curl -fsSL …bootstrap.sh | bash` de la
  línea 148 aparece **solo como texto** dentro del string `MIGRACION_WARN` que se imprime; no se
  ejecuta ningún subproceso ahí.
- **Throttle correcto y aislado**: stamp propio `$stampdir/.migracion-limbo` (línea 139), ventana fija
  de 86400s (~1×/día), **independiente** de `AVISO_DRIFT_HORAS`/`horas` (que gobierna el throttle
  per-repo y el de skills-global). Los tres throttles (per-repo, skills-global, migración) usan
  stamps distintos y no se pisan.
- **Fail-open confirmado**: el chequeo entero está envuelto en `if [ "$mig_skip" = 0 ]` y nunca hace
  `exit` distinto de 0; si `$HOME` no es escribible, `mkdir -p`/`printf … > stamp` fallan con `|| true`
  (línea 109, 150) sin abortar el hook.
- El único `git` que corre en TODO el archivo (vía `drift_chequea_repo` → `sincronizar-cerebro.sh`, y
  el check `git -C "$BRAIN_DIR" rev-list --count HEAD..origin/main` en
  `drift-cerebro-comun.sh:139`) opera sobre **refs YA locales** — no hace `fetch`, solo compara lo que
  ya existe en el repo local. Sin llamada de red en todo el hook.

### 1.3 Mensajes de los 3 widgets (#342) — ✅ CONFIRMADO, sin regresión de update

- **macOS** (`macos/Sources/Cortex/Updater.swift:33-48`): `bootstrapOneLiner` = el curl exacto;
  `manualUpdateHint` compone `"tu clon: <ruta descubierta>"` + el one-liner; se usa en el `guard`
  de `runUpdate()` (línea 145-148, antes `"actualiza a mano: git pull && ./install.sh"`, ahora
  `message = manualUpdateHint`). `PopoverView.swift:1035` (label corto "actualiza con bootstrap.sh")
  y `:1046-1048` (tooltip: describe el flujo real cuando `canSelfUpdate` y usa `manualUpdateHint`
  cuando no) — coherente.
- **Linux** (`src/plasmoid/contents/ui/main.qml:1101-1112` constante+hint, `:1139-1150`
  `resolveRepoPath` ahora emite 2 líneas — auto-update-path y discovered-path —, `:1160-1163`
  `runUpdate()` usa `updManualHint`, `:2146-2163` label/tooltip). Mismo patrón que macOS.
- **Windows** (`windows/src/Cortex/Updater.cs:51-67` constante+hint+discovery, `:277`
  `Message = ManualUpdateHint`; `windows/src/Cortex/PopupForm.cs:1250` label corto "actualiza con
  bootstrap.ps1"). One-liner correcto para PowerShell (`irm …bootstrap.ps1 | iex`), distinto del de
  mac/Linux (`curl …bootstrap.sh | bash`) — **correcto**, cada OS su propio bootstrap.
- **Orden de discovery consistente en los 3 OS**: para el mensaje "a mano" prefieren el nombre VIEJO
  primero (`~/.claude-brain` / `claude-brain-repo`) como señal de "quedaste en el rename", luego el
  canónico — igual en Swift (`:75-85`), QML (`:1148` segundo loop) y C# (`:134-146`). Para el path que
  SÍ habilita auto-update, los 3 prefieren el canónico primero (`~/.cortex`) — también consistente
  entre sí (no hay asimetría cruzada nueva).
- **Sin regresión de update**: diff de `5771fbc` revisado línea por línea en los 5 archivos — solo
  agrega propiedades/funciones de mensaje y discovery; `resolveClonePath`/`canSelfUpdate`/`check()`/
  el cuerpo de `runUpdate()` que hace `git fetch`+`merge --ff-only`+relanzar **no se tocaron** (mismo
  patrón en los 3 OS). El commit message de `5771fbc` lo declara explícito ("Solo mensajes/discovery,
  no toca la lógica de update") y el diff lo corrobora.

**Veredicto OLA1: los 3 puntos CONFIRMADOS, sin regresión. Listo para considerarse cerrada.**

---

## 2. Targets OLA2 — confirmados con file:línea ACTUAL

### C3 — `.brain-version` regresa al curar — SIGUE SIN ARREGLAR

- **Ubicación actual**: `brain/install-brain.sh:245-249` (bloque completo `238-252`).
  ```
  245: if [ -f "$SCRIPT_DIR/VERSION" ]; then
  246:   PREFIJO="$(head -1 "$SCRIPT_DIR/VERSION" | tr -d '[:space:]')"
  247:   COUNT="$(git -C "$SCRIPT_DIR" rev-list --count HEAD 2>/dev/null || echo 0)"
  248:   { echo "$PREFIJO.$COUNT"; date +%Y-%m-%d; } > "$CLAUDE_DIR/.brain-version"
  ```
  Sin cambios respecto al hallazgo original (antes en `install-brain.sh:245-252` sobre `main`
  @472e9c7; el número de línea coincide porque OLA1 no tocó este archivo).
- **Confirmado el mecanismo del bug**: cuando "Curar cerebro global" corre el `install-brain.sh`
  empaquetado en el `.app`/bundle (`SCRIPT_DIR` = `…/Cortex Widget.app/Contents/Resources/brain`, NO
  es un repo git), `git -C "$SCRIPT_DIR" rev-list --count HEAD` falla → `COUNT=0` → se estampa
  `"$PREFIJO.0"` con la fecha de HOY, **regresando** el sello real (p. ej. `0.2.351` → `0.2.0`) y
  mintiendo sobre "0 commits instalados hoy".
- **Fix propuesto**: resolver el clon REAL con la misma `resolve_brain_dir()` de OLA1 (ya disponible
  en `brain/hooks/drift-cerebro-comun.sh`, solo falta sourcearla o reimplementar el 3-way fallback
  aquí) y contar commits ahí en vez de en `$SCRIPT_DIR`:
  ```bash
  _bdir="${CLAUDE_BRAIN_DIR:-}"
  [ -d "$_bdir" ] || _bdir="$HOME/.cortex"
  [ -d "$_bdir" ] || _bdir="$HOME/.claude-brain"
  [ -d "$_bdir/.git" ] || _bdir="$SCRIPT_DIR"   # último recurso: el propio SCRIPT_DIR si es repo
  if [ -d "$_bdir/.git" ]; then
    COUNT="$(git -C "$_bdir" rev-list --count HEAD 2>/dev/null || echo 0)"
  else
    # SCRIPT_DIR no es git Y no hay clon real: NO re-estampar (conservar sello previo) en vez de
    # escribir "$PREFIJO.0" — evita la regresión.
    if [ -f "$CLAUDE_DIR/.brain-version" ]; then
      echo "warn: no pude determinar el commit-count real (bundle sin git); conservo el sello previo"
      COUNT=""  # bandera para saltar el re-estampado más abajo
    else
      COUNT=0   # primera instalación: no hay sello previo que proteger
    fi
  fi
  ```
  Alternativa más simple (menos líneas, mismo efecto): si `git -C "$SCRIPT_DIR" rev-list --count HEAD`
  falla (bundle no-git), **no reescribir** `$CLAUDE_DIR/.brain-version` en absoluto — dejar el sello
  que ya había. Es el fix que el propio audit original sugería como opción B y es el que menos
  superficie nueva introduce (no depende de que `resolve_brain_dir` esté disponible desde este script).

### U3 — `merge --ff-only` en el widget vs `checkout -B` en bootstrap — SIGUE SIN ARREGLAR

- **macOS**: `macos/Sources/Cortex/Updater.swift:161` —
  `+ "cd $DIR && git fetch origin --quiet && git merge --ff-only origin/main "`
- **Linux**: `src/plasmoid/contents/ui/main.qml:1174` —
  `+ "cd $DIR && git fetch origin --quiet && git merge --ff-only origin/main && bash $DIR/install.sh"`
  (y el tooltip en `:2161` describe textualmente el mismo `merge --ff-only`).
- **Windows**: `windows/src/Cortex/Updater.cs:294` —
  `"git -C $repo merge --ff-only origin/main\n" +` (segunda ocurrencia informativa en `:336`, mismo
  patrón en un mensaje de ayuda).
- **bootstrap.sh:84** — `git -C "$DIR" checkout -B main origin/main` (fuerza-alinea, descarta
  cualquier rama/commit local divergente). Confirmado que sigue siendo la única vía que garantiza
  convergencia; los 3 widgets **no** lo espejan.
- **Fix propuesto** (mismo para los 3 OS, aplicar tras OLA1 porque ahora el clon SÍ se resuelve bien
  en más máquinas y este bug se volverá más visible): reemplazar el `fetch && merge --ff-only` por el
  mismo patrón de `bootstrap.sh` — `git fetch origin --quiet && git checkout -B main origin/main` — o,
  si se quiere conservar trabajo local no comprometido en vez de descartarlo a ciegas, **detectar el
  fallo del ff-only y hacer surface** del motivo real antes de fallback a `checkout -B` (p. ej. si
  `merge --ff-only` falla, correr `git status --porcelain` y `git rev-parse --abbrev-ref HEAD`; si hay
  cambios sucios, avisar "tu clon tiene cambios locales, revísalos" en vez del genérico "el update no
  completó" a los 60s). Dado que este clon es un artefacto de infraestructura (no un checkout de
  desarrollo del usuario), la opción más simple y consistente con `bootstrap.sh` es alinear force
  (`checkout -B`) directamente — el usuario no debería tener trabajo propio en `~/.cortex`.

### C4 — staleness del asset precompilado — SIGUE SIN ARREGLAR (con matiz: Windows ya tiene una mitigación PARCIAL preexistente)

- **macOS**: `macos/install.sh:274-291` — bloque "1) Preferimos BAJAR el .app precompilado…"; baja
  `APP_ASSET_URL` (línea 35, release `macos-latest`) sin comparar ningún sha contra el clon. El
  `version.json` que trae el `.app` lo hornea `macos/make-app.sh` (línea 38: `_sha=$(git rev-parse
  --short HEAD)`) **en CI**, así que es honesto sobre lo que CI construyó — pero si CI va detrás del
  `origin/main` recién alcanzado por el `git merge --ff-only` del widget (§U3), el `.app` instalado
  queda desalineado del clon avanzado, y `.brain-version` (cuenta de commits del CLON, ver C3) diverge
  aún más de `version.json` (del ASSET). Ningún chequeo `build-sha(asset)==HEAD(clon)` existe hoy.
- **Windows**: `windows/install.ps1:108-130` — **YA EXISTE** una mitigación (preexistente, commit
  `cf0a5285` del 2026-07-31, ANTERIOR a la auditoría original y NO tocada por OLA1): tras bajar el exe
  precompilado, lee el `build-sha:` del cuerpo del release `windows-latest` vía la API de GitHub
  (línea 120-122) y, si difiere del `HEAD` del clon, **estampa el sha efectivo del asset** (no el HEAD)
  en `version.json` — línea 124 `$effSha = $m.Groups[1].Value` — y solo **avisa** (línea 126,
  `Write-Host "==> OJO: el asset … va detras de main…"`). Esto evita la MENTIRA (nunca declara "al
  día" un asset viejo — el `Updater.cs.check()` seguirá viendo `updateAvailable=true` hasta que CI
  alcance), pero **no** hace el fallback a compilar-desde-fuente que el hallazgo original recomendaba:
  si el runner de CI se cae o tarda, la máquina queda con `updateAvailable=true` indefinidamente, sin
  ninguna acción in-app que lo resuelva (mismo síntoma residual que C1, en miniatura). El auditor
  original YA había leído este archivo (está en su Anexo) y aun así clasificó C4 como abierto — el
  chequeo de honestidad no cierra el hallazgo, solo lo hace menos dañino.
- **Fix propuesto** (para los 3 OS, alineando a lo que Windows ya hace parcialmente):
  1. Generalizar el patrón de Windows a macOS: en `macos/install.sh`, tras bajar el `.app`, leer el
     `build-sha:` del cuerpo del release `macos-latest` (mismo mecanismo que ya usa
     `release-macos.yml:41` para su propio skip-si-ya-construido) y compararlo contra
     `git -C "$ROOT" rev-parse HEAD`; si difiere, avisar igual que Windows (no hace falta re-estampar
     nada porque el `.app` ya trae su propio `version.json` honesto horneado en CI).
  2. **Cerrar la ventana real** (lo que Windows tampoco hace): cuando el CALLER es el propio widget
     (`runUpdate()`/`OnUpdateClick`, no un `install.sh` manual) y detecta que el asset descargado
     está detrás del `HEAD` recién alcanzado por el `git merge`/`checkout -B` de §U3, pasar `--build`
     automáticamente (macOS: requiere Xcode CLT, hoy opcional; Windows: requiere .NET SDK, mismo
     trade-off) en vez de conformarse con avisar — o, más barato, reintentar la descarga del asset
     con un backoff corto (30-60s) antes de rendirse, dado que `release-macos.yml`/`release-windows`
     reconstruyen en cada push y el asset suele aparecer en 1-2 min.
  3. Linux **no aplica** (ya compila `git ff + install.sh` desde fuente, confirmado en el audit
     original y sin cambios en OLA1) — cero acción ahí.

---

## 3. Nuevos hallazgos (introducidos por OLA1 o no cubiertos por el audit original)

- **[BAJO] Sin cobertura en `test-brain.sh` para `resolve_brain_dir()`.** `brain/test-brain.sh` (4900+
  líneas, con baterías deterministas para `drift_skills_global` — p. ej. la función `skg()` en
  `:2546` que fija `HOME`/`CLAUDE_BRAIN_DIR` para testear esa otra función de la misma lib) **no tiene
  ningún test** que ejercite las 3 ramas de `resolve_brain_dir()` (env var presente/ausente, `~/.cortex`
  existe/no, fallback a `~/.claude-brain`, default final). Confirmado con
  `grep -n "resolve_brain_dir" brain/test-brain.sh` → cero resultados. No es una regresión (la función
  es nueva de OLA1), pero es una función CRÍTICA (todo el tooling bash del cerebro depende de ella
  ahora) sin red de pruebas determinista — el patrón ya existe en el mismo archivo para
  `drift_skills_global`, así que agregar 4-5 casos (`HOME` hermético + combinaciones de dirs
  presentes) es mecánico y barato. *Rec:* agregar antes de OLA2, ya que C3/U3/C4 seguirán apoyándose
  en esta función o en su mismo patrón.
- **[INFO] Ningún archivo de backlog durable (`estado-proyecto.md`) menciona OLA1/OLA2/OLA3.** El
  único registro vivo del plan de olas es la bitácora (`bitacora.md`, líneas finales, con la entrada
  "Falta re-auditar + OLA2/3" del 2026-09-01) y el propio doc de auditoría original. No es una mentira
  de doc (la bitácora es honesta y está al día), pero si `estado-proyecto.md` es la fuente de verdad
  de "qué sigue" en este repo, OLA2/OLA3 deberían aparecer ahí como ítems del backlog — hoy solo viven
  narrados en docs/bitácora. Sugerido para cuando se cierre esta re-auditoría: sembrar 3 líneas en
  `estado-proyecto.md` (C3/U3/C4) citando este archivo.
- **Sin hallazgos de severidad ALTA/CRÍTICA introducidos por OLA1.** El diff de ambos commits
  (`cd8a467`, `5771fbc`) es aditivo y quirúrgico: 0 líneas de lógica de update/fetch/merge tocadas, 0
  archivos fuera del alcance declarado en los commit messages, mensajes de commit honestos sobre el
  alcance ("Solo mensajes/discovery, no toca la lógica de update").

---

## Resumen de estado para el orquestador

| Ítem | Estado |
|---|---|
| OLA1 · #341 resolve_brain_dir | ✅ integrado limpio, sin sitios sin migrar |
| OLA1 · #341 nudge SessionStart | ✅ local, throttle correcto, fail-open |
| OLA1 · #342 mensajes 3 widgets | ✅ correctos y coherentes, sin regresión de update |
| OLA2 · C3 `.brain-version` | 🔴 confirmado sin arreglar, fix acotado a `install-brain.sh:245-249` |
| OLA2 · U3 `ff-only` vs bootstrap | 🔴 confirmado sin arreglar en los 3 OS, fix acotado por archivo |
| OLA2 · C4 staleness del asset | 🔴 confirmado sin arreglar; Windows ya tiene mitigación PARCIAL (honestidad, no fallback) desde antes de la auditoría original |
| Nuevos hallazgos | 1 BAJO (cobertura de test) + 1 INFO (backlog no reflejado) — nada ALTO/CRÍTICO |
