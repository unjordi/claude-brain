---
name: reubicar-master
description: >-
  Muda una sesión master COMPLETA de Claude Code a CUALQUIER repo destino SIN dejar nada a medias —
  transcript re-anclado + cwd reescrito, cerebro del master migrado por su canal correcto, opcional
  RENOMBRE del master, y slug global + TODAS las referencias (masters.json target y name por-id,
  alias, symlink `memory`) corregidas de forma ATÓMICA, residuo QUIRÚRGICO barrido y doc=realidad.
  El destino es un PARÁMETRO (`$DST_REPO`), no una constante: sirve igual para `cortex`, `axon` o el
  repo que sea, y el corte de qué viaja versionado se calibra según la VISIBILIDAD REAL del destino
  (pública o privada), verificada en runtime. Úsala cuando: un `--resume` cae en un folder muerto; un
  master quedó "a medias" (residuo + resume roto, anti-ejemplo helios-selene); o un master debe mudarse
  al repo que de verdad es su casa, sin lobotomizarlo, sin fuga ni duplicado divergente. Hermana de
  `claude-proyecto-autocontenido` (esa define DÓNDE vive el cerebro; ésta lo MUEVE de casa).
---

# reubicar-master — mudar un brain-master COMPLETO a su nueva casa (sin lobotomía, sin tail, sin fuga)

## Answer-first: qué hace y cómo, en una frase
Re-ancla una sesión master **cerrada** al repo destino que se le indique (transcript + cwd + slug global
+ masters.json target/name + alias + symlink `memory`), migrando **el cerebro del master** clasificado en
**3 tiers** por su canal correcto — **atómicamente** (move + fix de referencias en el MISMO bloque) y
**quirúrgicamente** (sin tocar el symlink `memory` de un slug compartido por cientos de sesiones). El
destino y el nombre del master son PARÁMETROS. El sello de LISTO es la **QA funcional del humano**, no el
verde técnico.

## Cuándo usarla · Cuándo NO
**SÍ:**
- Mudar un master al repo que de verdad es su casa (la que declara su `CLAUDE.local.md`), en vez del repo
  donde el cwd lo ancló por accidente histórico. Casos reales: los brain-master anclados en
  `plantilladotnet` — `cortex-master` (Mac) mudándose a `cortex`, `axon-master` (Cachy) a `axon`.
- Un `claude --resume <id>` que reanuda en un folder que ya no es la casa del master ("folder muerto").
- Un master que quedó a medias tras un intento previo (residuo en el slug viejo + resume roto = el
  anti-ejemplo **helios-selene**).
- Un master que además cambió de IDENTIDAD/nombre (p. ej. `claude-brain-cachy-master` → `axon-master`):
  el renombre de `masters.json` + alias va en el mismo bloque atómico que el move (S4).

**NO es:**
- Un mover-sesiones genérico entre proyectos cualesquiera (para eso está `session-move.js` directo, o el
  menú "Mover a…" del widget). Esta skill es para un **master** (persiste/viaja) con **cerebro** detrás.
- Limpiar sesiones stale/muertas (otra misión, fuera de alcance).
- Tocar `brain/` de cortex (es el PRODUCTO que viaja a los clones; leerlo es lícito, mutarlo desde
  una pasada de reubicación **jamás** — regla dura del `CLAUDE.local.md`).
- Una ruta "solo reorganizar sin mover el cwd": **DESCARTADA por el humano** (00-decisiones). El requisito
  es el move COMPLETO (route b FULL). Bajar el alcance NO es una opción de esta skill.

## Invariantes que NUNCA viola (los cuatro candados)
1. **NO-LOBOTOMÍA** — el master despierta en el destino con su cerebro del-master COMPLETO. `G-PARITY`
   (por CONTENIDO, `diff -q`) bloquea hasta cumplirlo.
2. **NO-SELF-MOVE-EN-VIVO** — nunca mueve un `.jsonl` reciente ni la sesión propia. `G-LIVENESS` bloquea
   por **mtime** + self-check + cita humana. `session-move.js:77` unlinkea sin preguntar → mover una viva
   parte el transcript.
3. **NO-TAIL** — re-ancla + corrige TODAS las referencias (masters.json por-id, alias, slug) en un bloque
   ininterrumpido, respaldado y re-entrante (efectivamente todo-o-nada por recuperación, NO atómico de FS — ver §8),
   barre residuo quirúrgico y deja doc=realidad. El tail es lo que a helios-selene le faltó.
4. **NO-FUGA / NO-DUPLICADO** — nada del template .NET entra **versionado** a un repo público; lo sensible
   viaja por canal gitignored per-máquina; `brain/` no se toca.

---

## 1 · La resolución template-vs-personal (el problema difícil, resuelto SIN downgrade)

El miedo a la "media lobotomía" nace de una premisa falsa: que "cerebro del master" = "los 18 skills + 31
memorias que se ven parado en plantilladotnet". **No lo es.** Esos skills son .NET (el PRODUCTO de la
plantilla del equipo, autocargados solo porque el cwd era la plantilla); el oficio del master es MANTENER
el cerebro. Se clasifica por **PROPIEDAD** y cada tier viaja por su canal:

| TIER | Qué es | Canal | Va al destino |
|---|---|---|---|
| **T1 — cerebro personal PÚBLICO-SEGURO** | memorias de mantener-el-cerebro, genéricas/compartibles (`handoff-peer-claudes-conciso.md`, `plan-molde-cerebros.md`, `diseno-unificar-cerebro.md`, …). Skills: NINGUNO viaja (las 4 de mantenimiento — `agregar-hook-cerebro`, `cortex-widget`, `cambiar-icono`, `publicar-widget` — YA viven en `cortex/.claude/skills`; las ~35 transversales son GLOBAL y se auto-cargan solas) | **versionado por PR** (merge dedup por CONTENIDO en `$DST/memory`) | **SÍ** |
| **T2 — cerebro personal SENSIBLE** | identidad y autorizaciones (`conocimiento-propio.local.md`, `autorizaciones-vigentes.local.md`, y el `CLAUDE.local.md` de la raíz) | **bundle en Drive** (gitignored) — git NO los propaga | **SÍ, gitignored per-máquina** |
| **T3 — PRODUCTO de la plantilla .NET** | los 18 skills .NET + memorias de plantilla/proyecto (`_PROTOCOLO.md`, `flujo-de-trabajo.md`, `decisiones-infra.md`, `release-develop-main.md`, `modulo-notificaciones.md`, `lecciones-migracion-cps.md`, `estado-proyecto.md`, `bitacora.md`, `entorno-maquina.md`, …) | **SE QUEDA en plantilladotnet** | **NO** |

### 1.0 · El corte NO depende del destino, pero SU RAZÓN SÍ — verifica la visibilidad, no la asumas
**El resultado es el mismo con cualquier destino: T1∪T2 viajan, T3 se queda.** Lo que cambia con la
visibilidad del destino es POR QUÉ, y eso importa porque una skill que da la razón equivocada se aplica mal
la próxima vez. **Verifica la visibilidad en runtime — nunca la asumas:**
```bash
DST_PRIVADO=$(gh repo view "$(git -C "$DST_REPO" remote get-url origin | sed -E 's#.*[:/]([^/]+/[^/]+)(\.git)?$#\1#')" --json isPrivate -q .isPrivate 2>/dev/null || echo unknown)
echo "destino privado: $DST_PRIVADO"   # unknown ⇒ trátalo como PÚBLICO (conservador)
```
| Destino | Riesgo de commitear T3 | Riesgo de commitear T2 |
|---|---|---|
| **PÚBLICO** (p. ej. `cortex` [verificado 2026-09-08: `isPrivate=false`]) | **FUGA** del template del equipo **+ duplicado divergente** | **FUGA de identidad y autorizaciones** |
| **PRIVADO** (p. ej. `axon` [verificado 2026-09-08: `isPrivate=true`]) | **duplicado divergente** — el riesgo de fuga baja, el de drift NO: T3 es producto VIVO de otro repo, y una copia se desincroniza igual | sigue **gitignored**: un repo privado puede volverse público, y las autorizaciones no pertenecen a git en ningún caso |

**La trampa a evitar:** concluir "el destino es privado ⇒ me puedo llevar T3". **NO.** El motivo dominante
para dejar T3 nunca fue solo la fuga: es que T3 es el PRODUCTO VIVO de otro repo y una copia **driftea**.
La visibilidad solo decide cuán catastrófico es equivocarse, no si es correcto.

**Resultado del corte, con cualquier destino:**
- **El destino** queda con el master + su cerebro COMPLETO (T1∪T2 + las GLOBAL que ya viajan), **sin** los
  skills .NET. Cero lobotomía.
- **El origen** (`plantilladotnet`) queda íntegro y canónico como plantilla .NET. Nadie la vacía.
- Cero fuga, cero duplicado. Ambos extremos enteros. **Esto NO es hacer menos: es la descomposición
  correcta.** El skill PROPONE este corte; el humano lo confirma (Decisión #2), pero el corte no baja alcance.

### 1.0.1 · Si el destino YA tiene su cerebro canonizado, S1 es un no-op — detéctalo, no lo rehagas
Un destino puede llegar con el trabajo de S1 ya hecho por fuera (su `.claude/memory/` ya tiene índice
`MEMORY.md` y las memorias del master ya copiadas). **Detéctalo por postcondición y sáltate S1**, en vez de
re-copiar y ensuciar el diff:
```bash
[ -f "$DST/memory/MEMORY.md" ] && echo "destino con índice: S1 puede ser no-op (verifica con G-PARITY)"
```
Precedente real: `axon` se canonizó el 2026-09-08 ANTES de la mudanza (índice nuevo, memorias del harness
trackeadas, personales en `.local.md`) — cuando la mudanza corra, S1 ya estará satisfecho y solo hay que
comprobar G-PARITY.

### 1.1 · Escape-hatch T3 (opt-in, Decisión #3) — overlay GITIGNORED, nunca versionado
Si el humano QUIERE que el master conserve acceso vivo a los skills .NET en su nueva casa **sin filtrarlos**:
copiarlos a `cortex/.claude/skills/` en local **y** añadir el patrón al `.gitignore` del destino, p. ej.:
```bash
grep -qxF '.claude/skills/_plantilla-*/' "$DST_REPO/.gitignore" || printf '%s\n' '.claude/skills/_plantilla-*/' >> "$DST_REPO/.gitignore"
# copiar cada skill .NET bajo un prefijo que calce el patrón ignorado, p.ej. .claude/skills/_plantilla-instanciar-proyecto/
```
Presentes-pero-no-commiteados → cero lobotomía + cero fuga. **Default: NO** (T3 se queda en plantilladotnet).

---

## 2 · Variables base (poblar una vez; el resto de la skill las reutiliza)
> **Nada de esto es constante.** `SRC_REPO`, `DST_REPO`, `MASTER_NAME`, `MASTER_NAME_NUEVO` y
> `MEMORIAS_T1` son **PARÁMETROS que se pueblan en runtime** (Decisiones #0–#2 de §7). Los valores de
> ejemplo abajo son eso, ejemplos — cámbialos. `BIN` sí es fijo: los scripts de sesión viven en `cortex`
> sea cual sea el destino.

```bash
set -euo pipefail
# ── PARÁMETROS (poblar en runtime — Decisiones #0/#1/#2) ─────────────────────────────
SRC_REPO="$HOME/code/plantilladotnet"        # ej.: donde el cwd ancló al master por accidente
DST_REPO=""                                  # ← Decisión #0: la casa REAL (ej. $HOME/code/cortex, $HOME/code/axon)
MASTER_NAME=""                               # ← nombre ACTUAL en masters.json (ej. claude-brain-cachy-master)
MASTER_NAME_NUEVO=""                         # ← Decisión #0b: nombre nuevo, o "" si no se renombra (ej. axon-master)
ID=""                                        # ← Decisión #1: el <id> vigente (ver G-ID)
MEMORIAS_T1=""                               # ← Decisión #2: memorias del-master que viajan versionadas
# ── DERIVADAS / FIJAS ───────────────────────────────────────────────────────────────
[ -n "$DST_REPO" ] && [ -n "$MASTER_NAME" ] || { echo "Faltan parámetros: DST_REPO y MASTER_NAME"; exit 1; }
[ -d "$DST_REPO/.git" ] || { echo "DST_REPO no es un repo git: $DST_REPO"; exit 1; }
SRC="$SRC_REPO/.claude"
DST="$DST_REPO/.claude"
BIN="$HOME/code/cortex/bin"                  # session-move/import/export.js + session-lib.js — SIEMPRE en cortex
[ -f "$BIN/session-move.js" ] || { echo "No encuentro los scripts de sesión en $BIN"; exit 1; }
DRIVE="${CLAUDE_SESSIONS_DRIVE:-/run/media/unjordi/SteamAndFiles/GoogleDrive/claude-sessions}"
GLOBAL_MEM="$HOME/.claude/projects/$(printf '%s' "$HOME" | sed 's/[^a-zA-Z0-9]/-/g')/memory"   # cerebro de MÁQUINA
OLD_SLUG="$(printf '%s' "$SRC_REPO" | sed 's/[^a-zA-Z0-9]/-/g')"   # ojo: suele ser COMPARTIDO por cientos de sesiones
NEW_SLUG="$(printf '%s' "$DST_REPO" | sed 's/[^a-zA-Z0-9]/-/g')"
JSONL="$HOME/.claude/projects/$OLD_SLUG/$ID.jsonl"
NEW_JSONL="$HOME/.claude/projects/$NEW_SLUG/$ID.jsonl"
MJ="$DRIVE/masters.json"
# T2 es FIJO (identidad + autorizaciones); T3 nunca viaja versionado (§1.0).
T2_LOCAL="conocimiento-propio.local.md autorizaciones-vigentes.local.md"   # en .claude/memory/
T2_ROOT="CLAUDE.local.md"                                                   # en la raíz del repo
```
**Ejemplo poblado** (la mudanza de `axon-master`, pendiente al 2026-09-08):
```bash
DST_REPO="$HOME/code/axon"; MASTER_NAME="claude-brain-cachy-master"; MASTER_NAME_NUEVO="axon-master"
MEMORIAS_T1="handoff-peer-claudes-conciso.md plan-molde-cerebros.md diseno-unificar-cerebro.md"
```
> **Nota de ejecución (una sola shell):** los bloques de esta skill comparten las *Variables base* y las
> postcondiciones recomputan lo que necesitan inline (p. ej. S3 recalcula el mtime desde `$JSONL`, no de
> una var de un bloque previo). Aun así, **corre los bloques en la MISMA shell** (o **re-declara las
> Variables base** al abrir una nueva) para que `$ID`, `$OLD_SLUG`, `$DST_REPO`, etc. persistan.

---

## 3 · GATES DUROS (NINGUNA mutación DESTRUCTIVA / del transcript antes de que pasen)

> **Alcance del "preflight":** G-ID y G-GITIGNORE se satisfacen antes de tocar nada. **G-LIVENESS** gatea
> específicamente el move DESTRUCTIVO (S3 export-first / S4) — por eso el flujo §5 corre el prep
> NO-destructivo (S1 commitea un PR, S2 crea un bundle; ninguno toca el `.jsonl` objetivo) ANTES de él.
> **G-PARITY NO es un gate pass-before-mutation:** es una POSTCONDICIÓN de S1–S3 que se DEFINE aquí pero se
> EVALÚA después de migrar (por eso antes de migrar es esperable que falle).

### G-SELF-MOVE · check TEMPRANO de auto-movimiento (antes de cualquier otro gate)
Si la sesión que EJECUTA el skill es la que se quiere mover, aborta de inmediato con un mensaje claro (el
self-check también vive en G-LIVENESS, pero aquí es lo PRIMERO y explica la salida — no un fallo a media corrida):
```bash
[ "$ID" = "${CLAUDE_SESSION_ID:-}" ] && { echo "BLOQUEO: No puedes mover la sesión que EJECUTA el skill; ciérrala y dispárala desde la OTRA máquina o un shell plano (ver la danza §6)"; exit 1; }
```

### G-ID · resolver el `<id>` vigente (masters.json tiene DUPLICADOS por nombre)
[verificado] dos `claude-brain-cachy-master` (`7a6960de`, `9cbc2856`) y dos `claude-brain-master`
(`761c82d9`, `1dd207df`), todos con target `code/plantilladotnet`. `session-lib.findSession` devuelve
DETERMINISTA el de **mtime más reciente** (desempate alfabético por slug, `session-lib.js:49`) → con id
duplicado elige el más nuevo, que con duplicados suele ser el vivo. Aun así el gate NO desaparece: ahora es
una **CONFIRMACIÓN** — el humano confirma que el `<id>` auto-seleccionado por mtime es el que quiere mover,
lo CITA textual y puebla `ID=`.
```bash
grep -n '"id"\|"name"' "$MJ"                     # listar candidatos para que el humano elija
[ -n "$ID" ] || { echo "G-ID: falta el <id> vigente (Decisión #1)"; exit 1; }
```

### G-LIVENESS · la sesión objetivo está CERRADA — por **mtime que BLOQUEA** (NO `fuser`/`lsof`)
Gatea el move DESTRUCTIVO (S3+); el prep NO-destructivo S1/S2 corre antes que él (ver nota de §3).
`fuser`/`lsof` sobre el `.jsonl` es **falso-negativo**: Claude Code appendea-y-cierra el fd, no lo sostiene
→ inútil como prueba de "cerrada". Sirve solo como señal EXTRA (si da positivo, seguro está viva). La
prueba de CERRADA = **mtime frío + self-check + cita humana + sin lock de export**:
```bash
LIVE_MIN="${REUBICAR_LIVE_MIN:-15}"
[ "$ID" = "${CLAUDE_SESSION_ID:-}" ] && { echo "BLOQUEO: es la sesión propia (self-move imposible)"; exit 1; }
now=$(date +%s); mt=$(stat -c %Y "$JSONL" 2>/dev/null || stat -f %m "$JSONL" 2>/dev/null || echo 0)
age=$(( (now - mt) / 60 ))
[ "$mt" -gt 0 ] || { echo "BLOQUEO: no puedo leer mtime de $JSONL"; exit 1; }
[ "$age" -lt "$LIVE_MIN" ] && { echo "BLOQUEO: .jsonl tocado hace ${age}m (<${LIVE_MIN}) ⇒ presunta VIVA"; exit 1; }
[ -f "$DRIVE/.export-$ID.lock" ] && { echo "BLOQUEO: auto-export detached en vuelo (el hook exporta en background)"; exit 1; }
```
+ **CITA HUMANA obligatoria** (gate, no la infiere el skill): *"la sesión `<id>` en `<máquina>` está
CERRADA"*. En cross-máquina el mtime se chequea en el host remoto (`ssh <host> "stat -c %Y <jsonl>"`).
> **Consecuencia clave:** la sesión que EJECUTA esta skill NO puede moverse a sí misma (mtime caliente +
> self-check). Por eso el move de cada master lo dispara **el OTRO** — ver la danza §6.

### G-GITIGNORE · BLINDAR el `.gitignore` del destino ANTES de depositar nada sensible
Un destino cuyo `.gitignore` no cubra el `CLAUDE.local.md` de la raíz dejaría lo sensible TRACKEADO = fuga
[verificado en `cortex`; **compruébalo en TU destino**, no lo asumas]. Se blinda ANTES de tocar T2 — y aplica
igual si el destino es privado (§1.0: un privado puede volverse público):
```bash
for pat in 'CLAUDE.local.md' '.claude/memory/*.local.md' '.claude/settings.local.json'; do
  grep -qxF "$pat" "$DST_REPO/.gitignore" || printf '%s\n' "$pat" >> "$DST_REPO/.gitignore"
done
git -C "$DST_REPO" check-ignore CLAUDE.local.md \
    .claude/memory/conocimiento-propio.local.md \
    .claude/memory/autorizaciones-vigentes.local.md \
  || { echo "G-GITIGNORE: alguno NO quedó ignorado ⇒ ABORTA (riesgo de fuga)"; exit 1; }

# Verificar que NO estén YA trackeados (añadir a .gitignore NO des-trackea archivos ya en el índice)
if git -C "$DST_REPO" ls-files --error-unmatch CLAUDE.local.md .claude/memory/*.local.md 2>/dev/null; then
  echo "G-GITIGNORE: sensible YA trackeado ⇒ git rm --cached antes"; exit 1
fi
```

### G-PARITY · POSTCONDICIÓN (de S1–S3), no gate preflight · el destino tendrá el cerebro-del-master COMPLETO — por CONTENIDO (`diff -q`)
No se mide "18 vs 4 skills" (mezcla plantilla con master). Se mide que **lo clasificado del-master**
(T1∪T2) esté idéntico en el destino:
```bash
fail=0
for m in $MEMORIAS_T1 $T2_LOCAL; do
  diff -q "$SRC/memory/$m" "$DST/memory/$m" >/dev/null 2>&1 || { echo "PARIDAD ROTA / FALTA: $m"; fail=1; }
done
diff -q "$SRC_REPO/$T2_ROOT" "$DST_REPO/$T2_ROOT" >/dev/null 2>&1 || { echo "PARIDAD ROTA: $T2_ROOT"; fail=1; }
[ "$fail" -eq 0 ] || { echo "G-PARITY: BLOQUEA hasta migrar (S2/S3)"; exit 1; }
[ -d "$DST_REPO/brain" ] || { echo "G-PARITY: falta brain/ en destino (¿repo equivocado?)"; exit 1; }   # y JAMÁS se muta
```
(Se DEFINE aquí pero se EVALÚA como postcondición tras S3, NO como gate pass-before-mutation; antes de migrar es esperable que falle. El check `diff -q` de arriba es su definición.)

---

## 4 · MÁQUINA DE ESTADOS (INV: NADA A MEDIAS — re-entrante, postcondición verificada por paso)
Al invocarse, **detecta el estado por sus postcondiciones y CONTINÚA** (no reinicia, no deja tail). Backup
del `.jsonl` antes de toda mutación (lo hace `session-move.js:62-66` solo; en modo import, respáldalo tú).

| Estado | Garantiza | Detector (postcondición) |
|---|---|---|
| **S0** reconstituido | Gate R hecho (lo que "sí iba" en plantilladotnet regresó del slug global) | memorias confirmadas presentes en `$SRC/memory`; `MEMORY.md`↔archivos cuadra |
| **S1** T1 migrado (PR) | T1 versionado, merge dedup por CONTENIDO | `diff -q` T1 = idéntico en `$DST/memory` |
| **S2** T2 empacado | bundle sensible en Drive | `$DRIVE/$ID.brain-local.tgz` existe |
| **S3** export-first | `.gz` de Drive ≥ la sesión (post-cierre) | `stat -c %Y "$DRIVE/$ID.jsonl.gz"` ≥ mtime `.jsonl` |
| **S4** re-anclado ATÓMICO | jsonl en slug nuevo + cwd único + target por-id + alias, en UN bloque | grep cwd único = destino; `.jsonl` viejo ausente; `jq` target = nuevo |
| **S5** saneado | T2 depositado gitignored; residuo quirúrgico; symlink `memory` verificado | T2 presente e ignorado; sin `.jsonl` viejo; symlink compartido intacto |
| **S6** doc=realidad + QA | commit del versionable + docs; QA humano | dashboard/estado al día; humano confirmó resume |

### S0 · Reconstituir el cerebro canónico de plantilladotnet (Gate R — que el ORIGEN tampoco quede a medias)
La consolidación rig-master (2026-08-02) se llevó memorias del proyecto al slug global de MÁQUINA. Regresan
las que sean del **proyecto/plantilla** (NO lo de máquina: kde/nvidia/kernel/openrgb se quedan global).
Descubrimiento (no bulk — el humano clasifica, anti-confabulación):
```bash
grep -rilE 'plantilladotnet|\.NET|blazor|dapper|EF Core|webapi|migracion-ef' "$GLOBAL_MEM/" | sort
BK="$HOME/.claude/reubicar-backups/$(date +%s)"; mkdir -p "$BK"; /bin/cp -a "$SRC/memory" "$BK/memory.src.bak"
MEMORIAS_REGRESAN=""     # ← poblar con lo que el humano confirme (Decisión #4); vacío ⇒ no-op verificado
for m in $MEMORIAS_REGRESAN; do [ -e "$SRC/memory/$m" ] || /bin/cp -f "$GLOBAL_MEM/$m" "$SRC/memory/$m"; done
# re-indexar $SRC/memory/MEMORY.md; diff -q antes de descartar copias del global (a .trash/, NUNCA rm a ciegas)
```
**Honestidad:** hoy NO hay lista confirmada de "memorias de plantilladotnet dejadas en el global"; el grep
es el MÉTODO, la clasificación la hace el humano. **Postcondición S0:** `MEMORY.md`↔archivos cuadra; escaneo
de secretos limpio.

### S1 · Migrar T1 (versionado, por PR — como rig-master, repo compartido)
```bash
cd "$DST_REPO"; git checkout develop && git pull --ff-only
git checkout -b "docs/reubicar-$MASTER_NAME"
# escaneo de secretos ANTES de commitear lo que se co-ubica:
if grep -rinE 'pass(word|wd)?|secret|token|api[_-]?key|credential|\.env\b' \
  $(for m in $MEMORIAS_T1; do echo "$SRC/memory/$m"; done); then
  echo "BLOQUEO: Secreto detectado en T1. NO commitear a repo público."
  exit 1
fi
for m in $MEMORIAS_T1; do
  if [ -e "$DST/memory/$m" ] && ! diff -q "$SRC/memory/$m" "$DST/memory/$m" >/dev/null 2>&1; then
    echo "CONFLICTO $m: existe distinto en destino → reconciliar con humano (no piso)"
  else
    /bin/cp -f "$SRC/memory/$m" "$DST/memory/$m"
  fi
done
# indexar cada uno en $DST/memory/MEMORY.md (doc=realidad; editar, no duplicar líneas)
git add .claude/memory/*.md .claude/memory/MEMORY.md .gitignore
git status --short .claude | grep -iE 'local|\.jsonl|sessions' && { echo "ABORT: algo sensible staged"; exit 1; } || true
git commit -m "docs(cerebro): traslada el cerebro personal del $MASTER_NAME a este repo"
```
Lo SENSIBLE (T2) NO va aquí — va por S2/S5. **Postcondición S1:** `diff -q` T1 idéntico en `$DST`.

### S2 · Empacar T2 (gitignored) para viajar cross-máquina
```bash
tmp2=$(mktemp -d)
for m in $T2_LOCAL; do [ -f "$SRC/memory/$m" ] && /bin/cp -a "$SRC/memory/$m" "$tmp2/"; done
[ -f "$SRC_REPO/$T2_ROOT" ] && /bin/cp -a "$SRC_REPO/$T2_ROOT" "$tmp2/$T2_ROOT"
tar -C "$tmp2" -czf "$DRIVE/$ID.brain-local.tgz" .
/bin/rm -rf "$tmp2"
test -f "$DRIVE/$ID.brain-local.tgz"                                    # postcondición S2
```

### S3 · EXPORT-FIRST (el `.gz` de Drive ≥ la sesión; antídoto a `seed --force`)
`seed.sh --force` pasa `--force` a import **sin freshness** → un `.gz` viejo pisaría lo bueno; y el hook
`exportar-sesion-master.sh:144` **solo AÑADE** ids, **nunca actualiza target**. Con la sesión CERRADA
(G-LIVENESS pasó) se re-exporta fresco ANTES de mover:
```bash
tmpe=$(mktemp -d)
node "$BIN/session-export.js" "$ID" --repo "$tmpe" --name "$MASTER_NAME" --force
/bin/cp -f "$tmpe/.claude/sessions/$ID.jsonl.gz"  "$DRIVE/"
/bin/cp -f "$tmpe/.claude/sessions/$ID.meta.json" "$DRIVE/"
/bin/rm -rf "$tmpe"
# postcondición S3:
[ "$(stat -c %Y "$DRIVE/$ID.jsonl.gz")" -ge "$(stat -c %Y "$JSONL" 2>/dev/null || echo 0)" ] || echo "S3: .gz no es ≥ sesión"
```

### S4 · RE-ANCLAR + FIX TARGET + ALIAS — bloque uninterrumpido (ATÓMICO-en-la-práctica)
El move y el fix de `masters.json` van en el MISMO bloque, sin ventana para que un `seed`/`sync` re-siembre
al slug viejo (= reencarnar helios-selene). **LOCAL** (mismo host, caso Cachy) → `session-move.js` (mueve,
reescribe cwd de TODAS las líneas, respalda, **aborta si colisiona** `session-move.js:60`). **CROSS-MÁQUINA**
→ `session-import.js` desde el `.gz` (re-deriva el slug local y hace el swap `/home`↔`/Users` solo,
`session-import.js:61,73`).
```bash
# 1) mover (local): jsonl → slug nuevo, cwd reescrito a $DST_REPO, backup, origen unlinkeado, aborta si colisiona
node "$BIN/session-move.js" "$ID" --to-cwd "$DST_REPO"          # {ok, fromSlug, toSlug, cwdRewritten, backup, lines}
# 2) verificar re-anclaje ANTES de tocar referencias/residuo:
[ -f "$NEW_JSONL" ] || { echo "ABORTO: no se creó $NEW_JSONL"; exit 1; }
uniqcwd=$(grep -o '"cwd":"[^"]*"' "$NEW_JSONL" | sort -u)
[ "$uniqcwd" = "\"cwd\":\"$DST_REPO\"" ] || { echo "ABORTO: cwd no uniforme: $uniqcwd"; exit 1; }
# 3) INMEDIATAMENTE corregir masters.json target POR-ID — y el NAME si hay renombre (mktemp, sin sponge):
NOMBRE_FINAL="${MASTER_NAME_NUEVO:-$MASTER_NAME}"
tmpm=$(mktemp)
jq --arg id "$ID" --arg t "${DST_REPO#$HOME/}" --arg n "$NOMBRE_FINAL" \
   '(.masters[] | select(.id==$id)) |= (.target = $t | .name = $n)' "$MJ" > "$tmpm" && /bin/mv -f "$tmpm" "$MJ"
# 4) alias legible REAL con el nombre FINAL (usa la lib, no editar a mano):
node -e 'require(process.argv[1]).writeAlias(process.argv[2],process.argv[3])' \
  "$BIN/session-lib.js" "$ID" "$NOMBRE_FINAL"
# 5) si hubo RENOMBRE, retirar el alias VIEJO para que no queden dos apuntando al mismo id:
if [ -n "$MASTER_NAME_NUEVO" ] && [ "$MASTER_NAME_NUEVO" != "$MASTER_NAME" ]; then
  find "$HOME/.claude" "$DRIVE" -maxdepth 2 -name "*$MASTER_NAME*" -type l -print   # revisar y retirar a mano
  echo "RECORDATORIO: el nombre VIEJO ($MASTER_NAME) puede seguir citado en el cerebro del master"
  echo "  → grep -rl '$MASTER_NAME' \"$DST/memory\" \"$DST_REPO/CLAUDE.local.md\"  (doc=realidad, S6)"
fi
```

> **El RENOMBRE es parte del mismo bloque atómico, no un paso aparte.** Un master cuyo `target` se movió
> pero cuyo `name` sigue siendo el viejo es la misma clase de tail que `helios-selene`: las referencias
> quedan a medias y la siguiente herramienta que lea `masters.json` (o el humano) verá una identidad que ya
> no existe. Caso real: `claude-brain-cachy-master` → `axon-master`, decidido el 2026-08-22, con
> `masters.json` todavía diciendo el nombre viejo semanas después porque el renombre no tenía dueño.
**Postcondiciones S4:** `find ~/.claude/projects -name "$ID.jsonl"` = **exactamente 1** (el nuevo); cwd
único = `$DST_REPO`; `jq -r --arg id "$ID" '.masters[]|select(.id==$id).target' "$MJ"` = `${DST_REPO#$HOME/}`;
`jq -r --arg id "$ID" '.masters[]|select(.id==$id).name' "$MJ"` = `$NOMBRE_FINAL`; alias puesto (y el viejo
retirado si hubo renombre).

### S5 · Depositar T2 + barrido QUIRÚRGICO + symlink verificado
```bash
# depositar el cerebro sensible en el destino (gitignored por G-GITIGNORE):
tar -C "$DST/memory" -xzf "$DRIVE/$ID.brain-local.tgz"
[ -f "$DST/memory/$T2_ROOT" ] && /bin/mv -f "$DST/memory/$T2_ROOT" "$DST_REPO/$T2_ROOT"   # CLAUDE.local.md va a la RAÍZ
git -C "$DST_REPO" status --porcelain | grep -iE 'local\.md|CLAUDE\.local' && { echo "FUGA: sensible visible a git"; exit 1; } || true
# doc=realidad de la identidad: "corro desde plantilladotnet (mi base)" ya es FALSO → revisar a ojo tras editar:
#   conocimiento-propio.local.md del DESTINO: "corro desde <destino> (mi nueva base), antes desde <origen>"
#   y si hubo RENOMBRE, la identidad del master también cambia ahí y en CLAUDE.local.md
# BARRIDO QUIRÚRGICO del slug COMPARTIDO (~130 sesiones): SOLO el <id>.jsonl. El move local ya lo unlinkeó;
# esto es defensivo/idempotente (por si quedó copia o se vino de import). NUNCA el symlink 'memory'.
[ -f "$HOME/.claude/projects/$OLD_SLUG/$ID.jsonl" ] && /bin/rm -f "$HOME/.claude/projects/$OLD_SLUG/$ID.jsonl"
find "$HOME/.claude/projects/$OLD_SLUG" -maxdepth 1 -name memory -type l   # VERIFICAR que el symlink compartido SIGUE vivo
# symlink 'memory' del slug NUEVO → debe apuntar al cerebro COMPLETO del DESTINO:
readlink "$HOME/.claude/projects/$NEW_SLUG/memory"     # esperado: $DST/memory
find -L "$DST" -type l                                 # sin symlinks rotos; si faltara: bash "$DST_REPO/bootstrap-claude.sh"
```

### S6 · doc=realidad + commit + QA FUNCIONAL (humano = sello LISTO)
- **MR de T1 → develop en PREVIEW** (repo compartido): con OK EXPLÍCITO de unjordi y `--squash` (lo exigen
  `confirmar-merge-develop`/`merge-squash-guard`). **NUNCA `--auto-merge`** — integridad de guardarraíles.
  Sin OK, queda en la mini-develop (Decisión #5). Solo lo versionable (T1 + gitignore); jamás
  `.jsonl`/`*.local.md`/`brain/`.
- Actualizar: **dashboard global** (Mapa: el master ahora vive en `${DST_REPO#$HOME/}` + bitácora fechada
  con `>>`), `estado-proyecto.md`, y el `CLAUDE.local.md`/README de plantilladotnet si mencionaba al master
  como residente. **Registrar la RUEDA** (el TAIL que a helios-selene le faltó).
- **LISTO = QA del humano.** `claude --resume $ID` parado en `$DST_REPO`; confirmar: (a) reanuda sin
  folder muerto; (b) identidad cargada (conocimiento-propio re-inyectado por `aviso-drift-cerebro`);
  (c) las skills del destino + las GLOBAL aparecen; (d) las memorias-del-master (T1∪T2) están;
  (e) `masters.json` con el **target Y el name** correctos, y el alias apuntando al nombre final. **Verde técnico ≠ LISTO. No se declara a ciegas.**

---

## 5 · Resumen del flujo (una máquina)
`S0 canónico-origen → G-GITIGNORE → S1 T1(PR) → S2 T2-bundle → G-LIVENESS(cerrada) → S3 export-first →
S4 {move + target-fix + alias} uninterrumpido → G-PARITY → S5 {deposita T2 + residuo quirúrgico + symlink} →
S6 doc + QA-humano.` Re-entrante: cada S deja postcondición verificable; una corrida a medias se reanuda
desde el primer S cuya postcondición falle.

---

## 6 · Guion CROSS-MÁQUINA — la danza SSH cruzada (UX HEADLINE, lo que pidió el humano)

Requisito textual del humano: *"muevas al gemelo por ssh y luego pedirle a él que te mueva."* La clave que
rompe el huevo-y-gallina: **nadie se auto-mueve** (G-LIVENESS lo impide en vivo) → **cada máquina dispara el
move del OTRO master, que está CERRADO**. SSH es el **plano de control** (dispara el move remoto); **Drive es
el plano de datos** (transporta el `.gz` + el bundle T2); **git-PR** lleva T1. El transcript de cada master
ya es LOCAL a su máquina — SSH no transporta el `.jsonl`, solo ORDENA el move allá.

**Preflight SSH:** `ssh -o BatchMode=yes -o ConnectTimeout=8 unjordi@macbook-pro-de-unjordi.local 'echo ok'`
(key-auth + mDNS) + verificar `node` y el `$DST_REPO` remoto (y que `~/code/cortex/bin` exista allá: los
scripts de sesión viven en cortex sea cual sea el destino).

> **Los gemelos NO tienen por qué ir al MISMO destino.** La danza no consolida: solo resuelve el
> huevo-y-gallina de que nadie puede auto-moverse. Cada master declara SU `DST_REPO` (Decisión #0) y puede
> además renombrarse (#0b). Estado real al 2026-09-08: el gemelo Mac ya opera como **`cortex-master`** con
> casa en `cortex`; el de Cachy va a **`axon`** y se renombra a **`axon-master`**. Destinos distintos, misma
> coreografía.

**Coreografía (genérica — A y B son los dos masters; cada uno con su propio `DST_REPO`):**
1. **Preparar (la sesión VIVA — solo lo NO-destructivo):** G-ID / S0 / G-GITIGNORE / S1 (T1 por PR, o
   detectar que el destino ya está canonizado y es no-op, §1.0.1) / S2 (bundle T2). Una sesión viva NO se
   mueve a sí misma (G-LIVENESS: mtime caliente).
2. **El humano CIERRA a A.** Desde la otra máquina, por SSH, **B** (o un shell plano) corre S3–S6 para el
   `<id-A>` apuntando al `DST_REPO` **de A**. Cross-máquina se usa `session-import.js --repo <DST_REPO-de-A>`
   (re-deriva el slug local y hace el swap `/home`↔`/Users` solo). La identidad T2 de A viaja por su bundle
   de Drive; T1 le llega con `git pull` del PR mergeado.
3. **El humano resume A** en su nueva casa → A vivo con cerebro completo. QA (§S6).
4. **El humano CIERRA a B.** Ahora **A** (vivo en su casa nueva) corre por SSH S3–S6 para `<id-B>` apuntando
   al `DST_REPO` **de B**. **Así cada uno mueve al otro** — ninguno se auto-mueve.
5. **El humano resume B** en su casa → cerebro completo. QA (§S6) en cada máquina.

**Si solo hay UN master que mudar** (no hay gemelo disponible, o el otro ya está en su casa): no hace falta
SSH ni danza. El humano CIERRA la sesión y corre S3–S6 desde un **shell plano** en la misma máquina, o desde
una sesión de Claude DISTINTA (que no es la que se mueve, así que G-LIVENESS la deja). Es el caso de la
mudanza pendiente de `axon-master`: el gemelo ya está en cortex, así que basta un operador local.

**Cómo sobrevive el orquestador a su propia reubicación:** la sesión viva orquesta el move del OTRO; NO
puede ejecutar el suyo (debe estar cerrada) → lo ejecuta el otro master, un shell plano o una sesión
distinta. "Sobrevive" reapareciendo con `claude --resume` desde el slug nuevo.

### 6.1 · Handoff script escrito a DISCO — EJECUTABLE, no un stub
El skill ESCRIBE el guion del paso destructivo a `$DRIVE/handoff-$ID.sh` para que **otra persona u otra
sesión lo corra tal cual**, con la sesión objetivo cerrada. Sobrevive compactaciones porque vive en disco.

> **Regla dura: el handoff se escribe COMPLETO y EJECUTABLE.** Un handoff que solo dice "(ver SKILL §4)"
> obliga a quien lo corre a reconstruir los pasos destructivos a mano — justo lo que la skill existe para
> evitar. Si no puedes escribir un paso, escribe el `echo` que lo pide y un `exit 1`, nunca un comentario
> que finge que está resuelto.

El script re-declara sus propias variables (no hereda nada), re-verifica G-LIVENESS **él mismo** (quien lo
corre puede hacerlo horas después) y para en el primer fallo. Plantilla:

```bash
cat > "$DRIVE/handoff-$ID.sh" <<HANDOFF
#!/usr/bin/env bash
# handoff reubicar-master: $MASTER_NAME ($ID) → ${DST_REPO}${MASTER_NAME_NUEVO:+  (renombre a $MASTER_NAME_NUEVO)}
# CORRER con la sesión CERRADA, desde un shell plano o una sesión de Claude DISTINTA.
# Generado $(date -Iseconds) por reubicar-master. Idempotente y re-entrante: cada paso verifica antes de mutar.
set -euo pipefail
ID="$ID"; MASTER_NAME="$MASTER_NAME"; NOMBRE_FINAL="${MASTER_NAME_NUEVO:-$MASTER_NAME}"
SRC_REPO="$SRC_REPO"; DST_REPO="$DST_REPO"
DST="\$DST_REPO/.claude"; BIN="\$HOME/code/cortex/bin"
DRIVE="$DRIVE"; MJ="\$DRIVE/masters.json"
OLD_SLUG="$OLD_SLUG"; NEW_SLUG="$NEW_SLUG"
JSONL="\$HOME/.claude/projects/\$OLD_SLUG/\$ID.jsonl"
NEW_JSONL="\$HOME/.claude/projects/\$NEW_SLUG/\$ID.jsonl"
T2_LOCAL="$T2_LOCAL"; T2_ROOT="$T2_ROOT"

echo "── G-LIVENESS (re-verificado AQUÍ, no heredado) ──"
[ "\$ID" = "\${CLAUDE_SESSION_ID:-}" ] && { echo "BLOQUEO: es la sesión que ejecuta"; exit 1; }
if [ -f "\$JSONL" ]; then
  age=\$(( ( \$(date +%s) - \$(stat -c %Y "\$JSONL") ) / 60 ))
  [ "\$age" -lt "\${REUBICAR_LIVE_MIN:-15}" ] && { echo "BLOQUEO: .jsonl tocado hace \${age}m ⇒ presunta VIVA"; exit 1; }
  echo "  ok: frío hace \${age}m"
else
  [ -f "\$NEW_JSONL" ] && echo "  (ya movido: reanudando desde S5)" || { echo "BLOQUEO: no encuentro el .jsonl"; exit 1; }
fi
[ -f "\$DRIVE/.export-\$ID.lock" ] && { echo "BLOQUEO: auto-export en vuelo"; exit 1; }

echo "── S3 export-first ──"
if [ -f "\$JSONL" ]; then
  tmpe=\$(mktemp -d)
  node "\$BIN/session-export.js" "\$ID" --repo "\$tmpe" --name "\$NOMBRE_FINAL" --force
  /bin/cp -f "\$tmpe/.claude/sessions/\$ID.jsonl.gz" "\$tmpe/.claude/sessions/\$ID.meta.json" "\$DRIVE/"
  /bin/rm -rf "\$tmpe"
  [ "\$(stat -c %Y "\$DRIVE/\$ID.jsonl.gz")" -ge "\$(stat -c %Y "\$JSONL")" ] || { echo "S3: .gz no es >= sesión"; exit 1; }
fi

echo "── S4 move + target + name + alias (BLOQUE ININTERRUMPIDO) ──"
if [ -f "\$JSONL" ]; then node "\$BIN/session-move.js" "\$ID" --to-cwd "\$DST_REPO"; fi
[ -f "\$NEW_JSONL" ] || { echo "ABORTO: no se creó \$NEW_JSONL"; exit 1; }
uniqcwd=\$(grep -o '"cwd":"[^"]*"' "\$NEW_JSONL" | sort -u)
[ "\$uniqcwd" = "\"cwd\":\"\$DST_REPO\"" ] || { echo "ABORTO: cwd no uniforme: \$uniqcwd"; exit 1; }
tmpm=\$(mktemp)
jq --arg id "\$ID" --arg t "\${DST_REPO#\$HOME/}" --arg n "\$NOMBRE_FINAL" \\
   '(.masters[] | select(.id==\$id)) |= (.target = \$t | .name = \$n)' "\$MJ" > "\$tmpm" && /bin/mv -f "\$tmpm" "\$MJ"
node -e 'require(process.argv[1]).writeAlias(process.argv[2],process.argv[3])' "\$BIN/session-lib.js" "\$ID" "\$NOMBRE_FINAL"

echo "── S5 depositar T2 + barrido quirúrgico + symlink ──"
[ -f "\$DRIVE/\$ID.brain-local.tgz" ] && tar -C "\$DST/memory" -xzf "\$DRIVE/\$ID.brain-local.tgz"
[ -f "\$DST/memory/\$T2_ROOT" ] && /bin/mv -f "\$DST/memory/\$T2_ROOT" "\$DST_REPO/\$T2_ROOT"
git -C "\$DST_REPO" status --porcelain | grep -iE 'local\.md|CLAUDE\.local' && { echo "FUGA: sensible visible a git"; exit 1; } || true
[ -f "\$HOME/.claude/projects/\$OLD_SLUG/\$ID.jsonl" ] && /bin/rm -f "\$HOME/.claude/projects/\$OLD_SLUG/\$ID.jsonl"
find "\$HOME/.claude/projects/\$OLD_SLUG" -maxdepth 1 -name memory -type l | grep -q . \\
  && echo "  ok: symlink 'memory' del slug COMPARTIDO intacto" || echo "  ⚠️ el slug viejo ya no tiene symlink 'memory' (revisar)"
[ -L "\$HOME/.claude/projects/\$NEW_SLUG/memory" ] || ln -s "\$DST/memory" "\$HOME/.claude/projects/\$NEW_SLUG/memory"
readlink "\$HOME/.claude/projects/\$NEW_SLUG/memory"

echo "── POSTCONDICIONES ──"
n=\$(find "\$HOME/.claude/projects" -name "\$ID.jsonl" | wc -l); [ "\$n" -eq 1 ] || { echo "ABORTO: \$n copias del .jsonl"; exit 1; }
jq -r --arg id "\$ID" '.masters[]|select(.id==\$id)|"target=\(.target) name=\(.name)"' "\$MJ"
echo
echo "✅ Move hecho. FALTA (humano): claude --resume \$ID parado en \$DST_REPO y QA §S6 —"
echo "   identidad cargada, skills visibles, memorias T1∪T2 presentes, masters.json y alias correctos."
HANDOFF
chmod +x "$DRIVE/handoff-$ID.sh"
bash -n "$DRIVE/handoff-$ID.sh" && echo "sintaxis del handoff OK"    # gate: nunca dejes un handoff que no parsea
```
**Postcondición de §6.1:** `bash -n` pasa y el script NO contiene la cadena `ver SKILL §` como sustituto de
un paso. Un handoff que no se puede correr no es un handoff.

### 6.2 · Fallback SIN SSH (Drive caído o sin mDNS/key-auth)
Consolidar Mac↔Cachy sin una sola llamada SSH: en CADA máquina, un operador local (sesión fresca o shell
plano) corre S3–S6 para SU master cerrado, importando del `.gz` local de Drive; T1 por `git pull` del PR;
T2 por el bundle Drive. **SSH no exime G-LIVENESS.** Si aparece un `masters (1).json` (copia-en-conflicto de
Drive), reconciliar a mano ANTES de correr (Decisión #6) — masters.json es UN archivo compartido, edición
por-id serializada, nunca en ambas máquinas dentro de la ventana de sync.

---

## 7 · Decisiones del HUMANO (acotadas — se preguntan en RUNTIME, no se asumen)
0. **`DST_REPO` — la casa destino.** No hay default: la skill NO asume `cortex` ni ningún otro. Se pregunta,
   y se verifica que sea un repo git y cuál es su visibilidad real (§1.0).
0b. **¿Se RENOMBRA el master?** (`MASTER_NAME_NUEVO`) — si la identidad cambió junto con la casa. Vacío = no
   se renombra. El renombre va en el bloque atómico de S4, nunca después.
1. **`<id>` vigente** de cada máquina (duplicados en masters.json).
2. **Frontera T1↔T3** — el skill propone el corte del §1; el humano confirma qué memorias son del-master
   (viajan) vs de-la-plantilla (se quedan). NO baja alcance: mueve TODO lo del master.
3. **Escape-hatch T3** (§1.1): ¿el master conserva acceso vivo a los skills .NET vía overlay gitignored?
   Default NO.
4. **Set de reconstitución (S0)** — qué memorias del slug global "sí iban" a plantilladotnet.
5. **PR de T1 → develop** (con OK explícito + squash, sin auto-merge) o queda en la mini-develop.
6. **Copia-en-conflicto de Drive** (`masters (1).json`) si aparece.
+ **Cita de liveness** ("sesión `<id>` en `<máquina>` cerrada") — gate G-LIVENESS, no lo asume el skill.

## 8 · Modos de fallo → mitigación (tabla de defensa)
| Fallo | Causa | Mitigación |
|---|---|---|
| Lobotomía del master | mover cwd sin llevar T1∪T2 | G-PARITY por CONTENIDO (`diff -q`) bloquea |
| Lobotomía parcial en Mac | `*.local.md` no viaja por git | bundle T2 por Drive; depósito gitignored en cada máquina |
| Fuga del template .NET | commitear T3/skills a repo público (NO gitignored) | T3 se queda; `git ls-files .claude/skills` vacío; overlay solo si opt-in |
| Transcript vivo partido | unlink de sesión viva (`session-move.js:77`) | G-LIVENESS: mtime-bloquea + self-check + cita (no `fuser`) |
| Reencarnar helios-selene | fix de target NO atómico con el move | move + `jq` target por-id + `writeAlias` en el MISMO bloque (S4) |
| Rollback por `seed --force` | `.gz` viejo + target viejo | export-first (S3) con sesión cerrada + target atómico (S4) |
| Borrar symlink `memory` compartido | barrido no-quirúrgico en slug de ~130 sesiones | barrer SOLO `<id>.jsonl`; verificar que el symlink sigue vivo |
| Conflicto Drive de masters.json | edición concurrente de UN archivo | edición por-id serializada; vigilar `masters (1).json` |
| Move NO atómico (a medias) | `session-move.js` hace copy-a-slug-nuevo + unlink-viejo (no es un rename atómico) | respaldado (backup `session-move.js:62-66`) + aborta-si-colisiona (`:60`) + máquina de estados re-entrante: la postcondición S4 detecta un estado a medias y reanuda |
| Backups sin poda | `session-move.js` respalda sin límite | anotar poda de `~/.claude/session-move-backups/` |
| **Identidad a medias** (target movido, `name` viejo) | el renombre del master no iba en el bloque atómico | S4 fija `target` **y** `name` en el mismo `jq`, reescribe el alias con el nombre final y lista el alias viejo para retirarlo |
| **Destino asumido** (`cortex` por default) | la skill traía el destino hardcodeado en las variables base | `DST_REPO` es Decisión #0 sin default; se aborta si viene vacío o no es un repo git |
| **"Es privado, me llevo T3"** | leer el candado NO-FUGA como si la fuga fuera el único motivo | §1.0: el motivo dominante es el **duplicado divergente**, que no depende de la visibilidad |
| **Handoff inservible** | el guion a disco era un stub con "(ver SKILL §4)" | §6.1 exige script completo + `bash -n` verde como postcondición |

## 9 · Pendientes DELEGADOS al brain (fuera del skill)
- Freshness-check en `seed.sh --force` (hoy pisa con `.gz` viejo).
- Que el auto-registro del hook ACTUALICE `target` de un id ya presente (hoy solo añade, `exportar-sesion-master.sh:144`).
- Poda de `~/.claude/session-move-backups/` (se acumulan `.jsonl` de cientos de MB).
- Lock/actualización atómica de masters.json junto al move (hoy hay micro-ventana entre el move y el `jq` del target → un proceso externo podría leer el target viejo).
- Que `exportar-sesion-master.sh` reconozca un **renombre** (hoy el auto-registro ni actualiza `target` ni
  `name`: solo añade ids nuevos → un master renombrado reaparece con el nombre viejo si algo re-siembra).
- `findSession` podría desempatar por `lastActivity`/nº-líneas y no solo por `mtime` (edge: un backup viejo restaurado con `mtime` nuevo se elegiría siendo contenido antiguo).
