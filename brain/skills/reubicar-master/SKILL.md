---
name: reubicar-master
description: >-
  Muda una sesión master COMPLETA de Claude Code a CUALQUIER repo destino SIN dejar nada a medias —
  transcript re-anclado + cwd reescrito, cerebro del master migrado por su canal correcto, opcional
  RENOMBRE del master, y slug global + TODAS las referencias (masters.json target y name por-id, alias)
  corregidas en un bloque ININTERRUMPIDO con respaldo y punto-de-no-retorno explícito (todo-o-nada por
  RECUPERACIÓN, no atómico de filesystem), residuo QUIRÚRGICO barrido, cero symlinks nuevos y
  doc=realidad. Incluye G-QUIESCE (cero sesiones vivas, antes Y después) y S7 (re-verificar tras el QA,
  porque el QA es un resume y un resume MUTA). El destino es un PARÁMETRO (`$DST_REPO`), no una
  constante: sirve igual para `cortex`, `axon` o el repo que sea, y el corte de qué viaja versionado se
  calibra según la VISIBILIDAD REAL del destino, verificada en runtime. Úsala cuando: un `--resume` cae
  en un folder muerto; un master quedó "a medias" (residuo + resume roto, anti-ejemplo helios-selene); o
  un master debe mudarse al repo que de verdad es su casa, sin lobotomizarlo, sin fuga ni duplicado
  divergente. La maquinaria determinista vive en el script `reubicar-master.sh` que viene JUNTO a este
  skill (genera el handoff, lo verifica por contenido y da los tres comandos para correrlo); este
  documento es el contrato, las decisiones del humano y el porqué. Hermana de
  `claude-proyecto-autocontenido` (esa define DÓNDE vive el cerebro; ésta lo MUEVE de casa).
---

# reubicar-master — mudar un brain-master COMPLETO a su nueva casa (sin lobotomía, sin tail, sin fuga)

## Answer-first: qué hace y cómo, en una frase
Re-ancla una sesión master **cerrada** al repo destino que se le indique (transcript + cwd + slug global +
`masters.json` target/name + alias), migrando **el cerebro del master** clasificado en **4 tiers** por su
canal correcto — en un **bloque ininterrumpido con punto de no retorno explícito** (respaldo antes,
aserciones después, archivo de estado si algo revienta) y **quirúrgicamente** (sin tocar el `memory` de un
slug compartido por cientos de sesiones, y **sin crear ni un symlink nuevo**). El destino y el nombre del
master son PARÁMETROS. El sello de LISTO es la **QA funcional del humano**, no el verde técnico.

## La maquinaria es un SCRIPT · este documento es el porqué (lee esto antes de ejecutar nada)
**`reubicar-master.sh`, junto a este archivo, es el único ejecutable del skill.** Genera el handoff, lo
verifica y te da los tres comandos para correrlo:

```bash
reubicar-master.sh --id <uuid> --dst-repo <ruta> --master-name <nombre> [...] --dry
reubicar-master.sh verificar <handoff.sh>      # re-verificar uno que ya existe (viajó por Drive, etc.)
reubicar-master.sh --help
```

Este skill tuvo tres superficies que derivaban por separado —el cuerpo, la plantilla del handoff y los
metadatos— y los parches entraban en una y media. **Ya no.** El corte es POR NATURALEZA del paso, no por
comodidad:

- **MAQUINARIA DETERMINISTA → el script.** El PRELUDIO (§2: helpers portables, preflight y derivadas), el
  generador del handoff (§6.1), los pasos DESTRUCTIVOS (S3, S4, S5), S7 y el candado. No hay una sola
  copia de ese bash en markdown, y por tanto no hay nada que pueda derivar. Si buscas el comando exacto de
  un paso destructivo, está en el script y en el handoff que genera, **en ningún otro lugar**.
- **JUICIO → el cuerpo de este documento.** S0/S1/S2 (clasificar el cerebro en tiers, co-ubicar T1 por PR,
  empacar T2), las Decisiones de §7 y el QA de S6. Son pasos que exigen leer, decidir y curar: llevan bash
  de APOYO y postcondiciones declaradas, pero **quien los ejecuta es el modelo con el humano**, no un
  guion. Automatizarlos sería fingir que la clasificación de una memoria es mecánica.
- **El candado** (§6.1) verifica el handoff generado en TRES capas —preludio embebido byte a byte, pasos
  obligatorios en línea ejecutable, prohibiciones + sintaxis + LF— y falla CERRADO. Vigila que una edición
  futura no se lleve un paso sin notarlo: `bash -n` solo mide sintaxis, y un guion al que le falta un paso
  es sintácticamente perfecto. **No es una prueba de corrección:** eso lo hacen `_postcondiciones`
  (aserciones, en ejecución) y `REUBICAR_MODO=dry`.

> **Por qué dejó de ser markdown (2026-09-10, primera mudanza real).** El generador era un bloque que el
> operador tenía que extraer, poblar y correr DESPUÉS de sourcear el preludio en la MISMA shell —
> dependencias invisibles que el propio generador no verificaba. Un `source` dentro de un pipe (que no
> persiste) produjo un handoff sin preludio: 473 líneas, `bash -n` impecable, certificado «handoff OK» y
> muerto en `DST_CWD: unbound variable`. **Un artefacto que certifica lo que no verificó** — el mismo modo
> de falla que este skill existe para evitar, esta vez en su propio andamio. En un proceso el orden no se
> puede equivocar, y la capa 1 del candado lo exige por CONTENIDO.

## Plataformas, shell y requisitos (los tres OS son COIGUALES; los límites se declaran, no se ocultan)
| pieza | macOS | Linux | Windows / Git Bash |
|---|---|---|---|
| estado de verificación | **VERIFICADO** por ejecución en fixtures (macOS 26.6, CLI `2.1.236`) | idiomas GNU-nativos (rama primaria de cada helper) | **NO VERIFICADO en máquina real** — documentado y con preflight que aborta si falta el sustrato |
| `stat` | `-f %m` (rama BSD del helper `_mtime`) | `-c %Y` | incierto ⇒ el helper prueba las dos y **falla cerrado** si ninguna da un número |
| fecha legible de un epoch | `date -r N` | `date -d @N` | el helper prueba las dos |
| `find -printf` | **existe** en macOS 26 (verificado) — pero no se usa: el listado va por `_mtime` | existe | puede faltar ⇒ no se usa |
| `pgrep` | inservible aquí (ver §9, *"El gate de quiescencia no mide nada"*) ⇒ **no se usa** | existe | **no existe** ⇒ no se usa |
| detección de sesiones vivas | por **artefacto** (`mtime` de los `.jsonl`), no por proceso — la única señal que existe en los tres | idem | idem |
| `chmod 600` del transcript | real | real | **no-op sobre NTFS**: Git Bash no escribe ACLs ⇒ el paso 2c **avisa y degrada**, no finge |
| ruta del cwd / slug | realpath físico (`pwd -P`) | idem | la ruta NATIVA (`C:\...`) es la que el harness usa: el preludio resuelve con `pwd -P` (bash puro, no `node -e realpathSync`, que recibiría la ruta POSIX y la resolvería contra la unidad actual) y **luego** traduce con `cygpath -w`; los TRES slugs (origen, destino, `$HOME`) salen de la forma nativa |
| symlinks | no se crean (decisión humana) | idem | idem — y por eso el privilegio/Developer Mode de Windows **no es un requisito** |
| EOL del handoff | LF | LF | el generador fuerza LF (`tr -d '\r'`); si el guion viajó por Drive/Windows, normalízalo antes de correrlo (§6.1) |

**Shell: bash.** Todos los bloques asumen `bash` (el repo lo declara en su `README.md`: *"todo corre bajo
bash: macOS, Linux, Windows/Git Bash"*). El `set -euo pipefail` de este skill **no tiene la misma
semántica en zsh** (medido: el mismo bloque que aborta en bash 5.3 sigue de largo en zsh). Corre los
bloques como `bash -s <<'BLOQUE' … BLOQUE` o desde un `.sh`, **nunca pegados en una terminal zsh**.

**Herramientas obligatorias:** `bash`, `jq`, `node`, `git`, `tar`, `find`, `sort`, `grep`, `gzip`. El
preludio las verifica y **aborta con la lista de faltantes** en vez de descubrirlo a media mutación. En
Windows, `jq` **no viene con Git for Windows**: `cortex/bootstrap.ps1` lo instala (`jqlang.jq`) junto con
Git Bash y Node. `gh` es opcional (§1.0: sin `gh` la visibilidad queda `unknown` ⇒ se trata como PÚBLICA).

## Cuándo usarla · Cuándo NO
**SÍ:**
- Mudar un master al repo que de verdad es su casa (la que declara su `CLAUDE.local.md`), en vez del repo
  donde el cwd lo ancló por accidente histórico. Casos reales: los brain-master anclados en
  `plantilladotnet` — `cortex-master` (Mac) mudándose a `cortex`, `axon-master` (Cachy) a `axon`.
- Un `claude --resume <id>` que reanuda en un folder que ya no es la casa del master ("folder muerto").
- Un master que quedó a medias tras un intento previo (residuo en el slug viejo + resume roto = el
  anti-ejemplo **helios-selene**).
- Un master que además cambió de IDENTIDAD/nombre (p. ej. `claude-brain-cachy-master` → `axon-master`):
  el renombre de `masters.json` + alias va en el mismo bloque que el move (S4).

**NO es:**
- Un mover-sesiones genérico entre proyectos cualesquiera (para eso está `session-move.js` directo, o el
  menú "Mover a…" del widget). Esta skill es para un **master** (persiste/viaja) con **cerebro** detrás.
- Limpiar sesiones stale/muertas (otra misión, fuera de alcance).
- Tocar `brain/` de cortex (es el PRODUCTO que viaja a los clones; leerlo es lícito, mutarlo desde
  una pasada de reubicación **jamás** — regla dura del `CLAUDE.local.md`). Genérico: `$DST_PROTEGIDO`.
- Una ruta "solo reorganizar sin mover el cwd": **DESCARTADA por el humano** (00-decisiones). El requisito
  es el move COMPLETO (route b FULL). Bajar el alcance NO es una opción de esta skill.

## Invariantes que NUNCA viola (los cuatro candados)
1. **NO-LOBOTOMÍA** — el master despierta en el destino con su cerebro del-master COMPLETO, **incluido su
   CABLEADO** (T4: `settings.json` tier-`repo` + `settings.local.json`). `G-PARITY` mide **presencia y
   corrección EN EL DESTINO** (no igualdad con el origen: el cerebro del master a menudo nunca vivió en el
   origen) y bloquea hasta cumplirlo.
2. **NO-SELF-MOVE-EN-VIVO** — nunca mueve un `.jsonl` reciente ni la sesión propia. `G-SELF-MOVE` y
   `G-LIVENESS` **fallan cerrado**: si no pueden MEDIR quién ejecuta o qué tan fría está la sesión,
   **bloquean** (un gate que no puede medir no debe pasar). `session-move.js` → `main()` hace el
   `unlinkSync` del origen **sin preguntar** → mover una viva parte el transcript en dos.
3. **NO-TAIL** — re-ancla + corrige TODAS las referencias (masters.json por-id **con el lock del
   ecosistema**, alias, slug) en un bloque ininterrumpido, respaldado y re-entrante (**todo-o-nada por
   RECUPERACIÓN, NO atómico de FS** — ver §9), con **punto de no retorno explícito** y un **archivo de
   estado** (`$DRIVE/reubicar-<ID>.state`) para que una corrida cortada se reanude por estado y no por
   adivinanza. Barre residuo quirúrgico y deja doc=realidad. El tail es lo que a helios-selene le faltó.
4. **NO-FUGA / NO-DUPLICADO** — nada del template .NET entra **versionado** a un repo público; lo sensible
   viaja por canal gitignored per-máquina, verificado **archivo por archivo** (`check-ignore -q` uno a uno:
   `git check-ignore A B C` sale 0 si **cualquiera** matchea, así que en lote **no certifica nada**);
   `$DST_PROTEGIDO` no se toca.

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
| **T3 — PRODUCTO de la plantilla .NET** | los 18 skills .NET + memorias de plantilla/proyecto (`_PROTOCOLO.md`, `flujo-de-trabajo.md`, `decisiones-infra.md`, `release-develop-main.md`, `modulo-notificaciones.md`, `lecciones-migracion-cps.md`, `estado-proyecto.md`, `bitacora.md`, …) | **SE QUEDA en el origen** | **NO** |
| **T4 — CABLEADO de la sesión** | `.claude/settings.json` del destino (los hooks tier-`repo` **solo se cargan si la sesión INICIA en ese repo**) + `.claude/settings.local.json` per-máquina (de donde sale el `outputStyle`) | **el del DESTINO manda**; nada se copia del origen — se **VERIFICA** que el destino tenga los suyos | **SÍ (verificado, no copiado)** |

> **Por qué existe T4 (y no es un detalle):** ya está medido que una sesión no es su transcript. Son (a)
> transcript, (b) memorias del repo, (c) cableado de hooks, (d) config de sesión y (e) estado externo. Una
> mudanza anterior movió (a) y (b) y dejó (c) y (d): **el master corrió sin sus propios candados y sin su
> estilo de salida**. Medir "cerebro completo" solo con memorias y skills es medir dos quintos.

### 1.0 · El corte NO depende del destino, pero SU RAZÓN SÍ — verifica la visibilidad, no la asumas
**El resultado es el mismo con cualquier destino: T1∪T2 viajan, T3 se queda, T4 se verifica.** Lo que
cambia con la visibilidad del destino es POR QUÉ, y eso importa porque una skill que da la razón
equivocada se aplica mal la próxima vez. **Verifica la visibilidad en runtime — nunca la asumas:**
```bash
command -v gh >/dev/null 2>&1 || echo "AVISO: sin 'gh' ⇒ la visibilidad queda 'unknown' y se trata como PÚBLICA"
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
- **El destino** queda con el master + su cerebro COMPLETO (T1∪T2 + T4 verificado + las GLOBAL que ya
  viajan), **sin** los skills .NET. Cero lobotomía.
- **El origen** queda íntegro y canónico como plantilla .NET. Nadie la vacía.
- Cero fuga, cero duplicado. Ambos extremos enteros. **Esto NO es hacer menos: es la descomposición
  correcta.** El skill PROPONE este corte; el humano lo confirma (Decisión #2), pero el corte no baja alcance.

### 1.0.1 · Si el destino YA tiene su cerebro canonizado, S1 es un no-op — detéctalo, no lo rehagas
Un destino puede llegar con el trabajo de S1 ya hecho por fuera (su `.claude/memory/` ya tiene índice
`MEMORY.md` y las memorias del master ya copiadas). **Es el caso NORMAL, no la excepción.** Detéctalo por
postcondición y sáltate S1:
```bash
[ -f "$DST/memory/MEMORY.md" ] && echo "destino con índice: S1 puede ser no-op (verifica con G-PARITY)"
```
Precedente real: `axon` se canonizó el 2026-09-08 ANTES de la mudanza. **Corolario duro:** por eso
`G-PARITY` **no** puede medir `SRC == DST` — para esta clase el archivo simplemente no existe en el origen
y un `diff -q` fallaría siempre, bloqueando en falso justo cuando el destino está COMPLETO (y empujando al
operador a declarar el gate "trivialmente satisfecho", que es la ausencia del candado). Mide **presencia y
corrección en el DESTINO**. Y lo mismo aplica a S5: el bundle T2 puede no existir (`S2` fue no-op) → S5
**guarda** su `tar` en lugar de correrlo a ciegas (bsdtar avisa y sigue; GNU tar aborta: el mismo comando,
dos comportamientos opuestos y ninguno correcto).

### 1.0.2 · Lo que el move NO se lleva (decídelo a propósito, no por omisión)
- **`~/.claude/projects/<slug>/memory/`** — canal per-máquina del **SLUG**, no de la sesión: lo comparten
  todas las sesiones de ese slug. **No se mueve.** Si el master guardó algo SUYO ahí, se copia a mano al
  slug nuevo **como DIRECTORIO REAL** (nunca symlink) — Decisión #7. S5 lo detecta y lo avisa.
- **`~/.claude/tasks/<session-id>/`** (los TODOs) — indexados por **session-id**, que es estable a través
  del move ⇒ **sobreviven solos**. No hay nada que hacer.
- **`cleanupPeriodDays`** (default **30**) — Claude Code reapa transcripts viejos. Un master mudado y no
  resumido puede desaparecer del store local; la copia durable es el `.gz` del Drive (S3). Si el QA no va a
  ocurrir pronto, revisa el valor en `~/.claude/settings.json`.
- **El `customTitle` del transcript** — de ahí re-deriva el hook la identidad del master, y **exige que
  termine en `-master`**. Ver §7 #0b y el preflight del preludio.

### 1.1 · Escape-hatch T3 (opt-in, Decisión #3) — overlay GITIGNORED, nunca versionado
Si el humano QUIERE que el master conserve acceso vivo a los skills .NET en su nueva casa **sin filtrarlos**:
copiarlos a `$DST/skills/` en local **y** añadir el patrón al `.gitignore` del destino, p. ej.:
```bash
grep -qxF '.claude/skills/_plantilla-*/' "$DST_REPO/.gitignore" || printf '%s\n' '.claude/skills/_plantilla-*/' >> "$DST_REPO/.gitignore"
# copiar cada skill .NET bajo un prefijo que calce el patrón ignorado, p.ej. .claude/skills/_plantilla-instanciar-proyecto/
```
Presentes-pero-no-commiteados → cero lobotomía + cero fuga. **Default: NO** (T3 se queda en el origen).

---
## 2 · Parámetros + PRELUDIO (fuente única de helpers, preflight y derivadas)

> **Nada de esto es constante y ninguno tiene un default engañoso.** `SRC_REPO`, `DST_REPO`,
> `MASTER_NAME`, `MASTER_NAME_NUEVO`, `MEMORIAS_T1`, `DST_PROTEGIDO` y **`DRIVE`** son PARÁMETROS que se
> pueblan en runtime (Decisiones #0–#2 de §7). `DRIVE` **no tiene fallback**: un default que apunta a la
> ruta de OTRA máquina no ayuda, miente — y `CLAUDE_SESSIONS_DRIVE` vive en el bloque `env` de
> `~/.claude/settings.json`, así que **en el shell plano que este skill prescribe está VACÍA** (medido).
> `BIN` tampoco es fijo: se RESUELVE como lo hace `seed.sh` (`$HOME/.local/bin`, `$HOME/.cortex/bin`),
> porque "cortex produce los scripts" no significa "cortex está clonado en `~/code/cortex`".

### 2.1 · Los parámetros son FLAGS del script (§7: se preguntan al humano en RUNTIME)

```bash
# el ejemplo real: el master de cortex, 2026-09-10
reubicar-master.sh \
  --id 761c82d9-40fd-4fe2-9703-e3504b6f028f \
  --dst-repo "$HOME/code/cortex" \
  --master-name claude-brain-master \
  --nombre-nuevo cortex-master \
  --dst-protegido brain \
  --dry
```

| flag | Decisión de §7 | qué es, y por qué NO tiene default |
|---|---|---|
| `--id <uuid>` | #1 / G-ID | el `<id>` VIGENTE. `masters.json` tiene DUPLICADOS por nombre ⇒ el nombre no identifica. |
| `--dst-repo <ruta>` | #0 | la casa REAL. Un default apuntaría al repo de otra máquina: no ayuda, miente. |
| `--master-name <nombre>` | — | el nombre ACTUAL en `masters.json`. |
| `--nombre-nuevo <nombre>` | #0b | el renombre. **Debe terminar en `-master`** o `exportar-sesion-master.sh` deja de reconocer la sesión y el auto-export se APAGA (lo verifica el preludio). |
| `--src-repo <ruta>` | — | de dónde sale. Default `$HOME/code/plantilladotnet`: el caso típico de un cwd que ancló al master por accidente. |
| `--drive <ruta>` | — | la carpeta `claude-sessions` del Drive. Default `$CLAUDE_SESSIONS_DRIVE`, que **en un shell plano está VACÍA** (vive en el bloque `env` de `~/.claude/settings.json`) ⇒ el preludio aborta con la instrucción de exportarla. |
| `--dst-protegido <subdir>` | — | subdir del destino que JAMÁS se muta (`brain` en cortex). Vacío = ninguno: **`axon` no tiene `brain/`** y hardcodearlo abortaba con un diagnóstico FALSO. |
| `--t1 <memoria>` | #2 | memoria a co-ubicar. **REPETIBLE** — y es la única forma correcta: una cadena separada por espacios partiría un nombre CON espacio en dos. |
| `--t2-local <archivo>` · `--t2-root <archivo>` | — | los gitignored. Defaults: `conocimiento-propio.local.md` + `autorizaciones-vigentes.local.md`, y `CLAUDE.local.md` en la raíz (puede NO existir: S2/S5/G-PARITY lo contemplan). |
| `--dry` | — | tras generar, corre el `REUBICAR_MODO=dry`. **Úsalo siempre.** |

`BIN` no es un flag ni es fijo: el preludio lo RESUELVE como lo hace `seed.sh` (`$CORTEX_BIN`,
`$HOME/.local/bin`, `$HOME/.cortex/bin`, `$HOME/code/cortex/bin`), porque "cortex produce los scripts"
no significa "cortex está clonado en `~/code/cortex`". Cada flag tiene su variable de entorno equivalente
(`ID`, `DST_REPO`, …) y el flag gana; los ARRAYS solo por flag, porque un array no se exporta al entorno.

### 2.2 · El PRELUDIO — lo escribe y lo SOURCEA el script, en su propio proceso

`reubicar-master.sh` publica el preludio en `~/.claude/reubicar-preludio.sh` (temporal + `mv`, rename
atómico: es un archivo COMPARTIDO entre corridas y dos mudanzas casi simultáneas se pisarían), lo
`bash -n`-ea antes de publicarlo, y lo **sourcea en el MISMO proceso** que luego genera el handoff. De
ahí salen los helpers portables (`_mtime`/`_size`/`_perm`/`_real`/`_cwds`/`_slug`…), el preflight
(herramientas, plataforma, parámetros, Drive, BIN) y las DERIVADAS (`DST_CWD`, `OLD_SLUG`, `NEW_SLUG`,
`JSONL`, `TARGET`, `ST`…).

Lo consumen los DOS lados: el script lo sourcea y el handoff lo **CONCATENA textualmente** (§6.1). Es lo
que hace imposible que el generador y el guion ejecutable deriven por separado — la clase de falla
histórica de este skill — y el candado del §6.1 lo exige **byte a byte**, no de palabra.

> **Ya no hay «córrelo todo en la MISMA shell».** Cuando el preludio era un bloque de markdown que el
> operador tenía que sourcear a mano antes de otro bloque, ese orden invisible era el punto débil: un
> `source` dentro de un pipe (que no persiste, porque el pipe es un subshell) produjo un handoff **sin
> preludio** — 473 líneas, `bash -n` impecable, certificado «handoff OK» y muerto en `DST_CWD: unbound
> variable` al primer arranque (2026-09-10, primera mudanza real). En un proceso el orden no se puede
> equivocar. Los abortos del preludio son abortos DEL SCRIPT (fail-closed), no de tu terminal.

---

## 3 · GATES DUROS (ninguna mutación destructiva antes de que pasen · TODOS fallan CERRADO)

> **Alcance del "preflight":** `G-SELF-MOVE`, `G-ID` y `G-GITIGNORE` se satisfacen antes de tocar nada.
> `G-LIVENESS` y `G-QUIESCE` gatean el move DESTRUCTIVO (S3/S4) — por eso el flujo §5 corre el prep
> NO-destructivo (S1 commitea un PR, S2 crea un bundle; ninguno toca el `.jsonl` objetivo) ANTES de ellos,
> **y el handoff los RE-EVALÚA él mismo** (quien lo corre puede hacerlo horas después).
> `G-PARITY` **NO es un gate pass-before-mutation:** es una POSTCONDICIÓN de S1–S3 que se DEFINE aquí y se
> EVALÚA después de migrar.
>
> **Regla que gobierna a todos: un gate que no puede MEDIR no pasa, BLOQUEA.** Los tres modos de falla
> históricos de este skill fueron gates que no medían — uno comparaba contra una variable inexistente,
> otro contaba procesos con una bandera que en macOS mete a sus propios ancestros, y el tercero
> desaparecía en Windows dejando el pipeline en `wc -l` = 0. Todos "pasaban".

### G-SELF-MOVE · la sesión que ejecuta NO es la que se mueve (fail-CLOSED)
```bash
# La variable real es CLAUDE_CODE_SESSION_ID (verificado: su valor calza con el id de la sesión).
# `CLAUDE_SESSION_ID` NO EXISTE — el gate viejo comparaba contra la cadena vacía y por eso pasaba SIEMPRE.
if [ "${CLAUDECODE:-}" = "1" ] || [ -n "${CLAUDE_CODE_ENTRYPOINT:-}" ]; then
  YO="${CLAUDE_CODE_SESSION_ID:-${CLAUDE_SESSION_ID:-}}"
  if [ -z "$YO" ]; then
    echo "BLOQUEO G-SELF-MOVE (fail-closed): corro DENTRO de Claude Code y NO puedo leer mi session-id."
    echo "  Sin poder medirlo no puedo descartar que yo sea la sesión objetivo. Córrelo desde un SHELL PLANO."
    exit 1
  fi
  if [ "$YO" = "$ID" ]; then
    echo "BLOQUEO G-SELF-MOVE: no puedes mover la sesión que EJECUTA el skill (te partirías el transcript)."
    echo "  Ciérrala y dispárala desde la OTRA máquina, un shell plano o una sesión DISTINTA (danza §6)."
    exit 1
  fi
  echo "  ok G-SELF-MOVE: soy $YO, el objetivo es $ID"
else
  YO=""
  echo "  ok G-SELF-MOVE: shell plano (CLAUDECODE ausente) ⇒ no puedo ser la sesión objetivo"
fi
```

### G-ID · resolver el `<id>` vigente (masters.json tiene DUPLICADOS por nombre)
[verificado] dos `claude-brain-cachy-master` (`7a6960de`, `9cbc2856`) y dos `claude-brain-master`
(`761c82d9`, `1dd207df`), todos con target `code/plantilladotnet`. `session-lib.js` → `findSession()`
desempata por CONTENIDO en su `matches.sort()` — **timestamp más reciente de la cola → bytes → mtime → slug** (el `mtime` es el TERCER criterio, no el primero; ver la nota de §9.1 de por qué no se vuelve a él)
→ con id duplicado elige el más nuevo, que con duplicados suele ser el vivo. Aun así el gate NO desaparece:
es una **CONFIRMACIÓN** — el humano confirma que el `<id>` es el que quiere mover, lo CITA textual y puebla `ID=`.

⚠️ **Y el id VIVO puede NO estar en `masters.json` — no lo elijas de ahí a ciegas.** El registro lo
alimenta el hook de auto-export, y una sesión forkeada o muy reciente puede no haberse registrado nunca.
Si eliges el id desde `masters.json` sin cruzarlo contra los `.jsonl` reales, mueves una sesión MUERTA y
dejas la viva anclada en el origen. **Cruza siempre las dos fuentes** (listado portable en los 3 OS: usa
`_mtime`/`_fecha`/`_size` del preludio, **no** `find -printf` ni `date -d`, y **no** `wc -l`, que leería
cientos de MB por candidato):
```bash
echo "── candidatos REGISTRADOS ──"; jq -r '.masters[]|"  \(.id)  \(.name)  target=\(.target)"' "$MJ"
echo "── candidatos REALES en disco (slug del origen), por frescura ──"
for f in "$PROJ/$OLD_SLUG"/*.jsonl; do
  [ -f "$f" ] || continue
  printf '%s\t%s\t%s\n' "$(_mtime "$f")" "$(basename "$f" .jsonl)" "$(_size "$f")"
done | sort -rn | head -5 | while IFS="$(printf '\t')" read -r mt sid sz; do
  printf '  %s  %s  %s bytes\n' "$(_fecha "$mt")" "$sid" "$sz"
done
[ -n "$ID" ] || { echo "G-ID: falta el <id> vigente (Decisión #1)"; exit 1; }
[ -f "$JSONL" ] || [ -f "$NEW_JSONL" ] || { echo "G-ID: el <id> elegido no tiene .jsonl — ¿registro huérfano?"; exit 1; }
jq -e --arg id "$ID" '.masters[]|select(.id==$id)' "$MJ" >/dev/null \
  || echo "AVISO: el id vivo NO está en masters.json ⇒ S4 hará UPSERT (lo AÑADE), no update"
```
**Caso real (2026-09-08, Cachy):** `masters.json` traía `claude-brain-cachy-master` con dos ids —
`7a6960de` (ya **sin `.jsonl`**: el fork original) y `9cbc2856` (frío del día anterior) — mientras la sesión
**viva** era `4e7b786c`, **ausente del registro**. Elegir por `masters.json` habría movido una sesión muerta.

### G-LIVENESS · la sesión objetivo está CERRADA — mide EL ARCHIVO QUE SE VA A MOVER
`fuser`/`lsof` sobre el `.jsonl` es **falso-negativo**: Claude Code appendea-y-cierra el fd, no lo sostiene
→ inútil como prueba de "cerrada" (sirve solo como señal EXTRA: si da positivo, seguro está viva). La
prueba de CERRADA = **mtime frío del archivo objetivo + sin lock de export + cita humana**.

**El gate mide el MISMO archivo que va a mover el mutador, no el del slug viejo.** `session-move.js` usa
`findSession()`, que barre **todos** los slugs y elige por CONTENIDO (ts→bytes→mtime); un gate que mire `$JSONL` a pelo puede
certificar frío sobre una copia MUERTA mientras el mutador se lleva la VIVA de otro slug (medido). Y si el
id existe en **más de un slug**, el gate **bloquea**: no hay tie-break aceptable para un `unlink`.
```bash
COPIAS="$(find "$PROJ" -maxdepth 2 -name "$ID.jsonl" 2>/dev/null | sort)"
NCOP=$(printf '%s\n' "$COPIAS" | grep -c . || true)
[ "$NCOP" -ge 1 ] || { echo "BLOQUEO G-LIVENESS: no hay ningún $ID.jsonl bajo $PROJ"; exit 1; }
if [ "$NCOP" -gt 1 ]; then
  echo "BLOQUEO G-LIVENESS: el id vive en $NCOP slugs — el mutador elegiría por CONTENIDO (ts→bytes→mtime) y podría llevarse la que NO es:"
  printf '  %s\n' $COPIAS
  echo "  Resuélvelo a mano ANTES: deja UNA sola copia (las otras a ~/.claude/session-move-backups/, con 'mv', nunca 'rm')."
  exit 1
fi
TGT_FILE="$COPIAS"
mt=$(_mtime "$TGT_FILE")
[ "$mt" -gt 0 ] || { echo "BLOQUEO G-LIVENESS (fail-closed): no pude leer el mtime de $TGT_FILE (¿stat incompatible?)"; exit 1; }
age=$(( ( $(date +%s) - mt ) / 60 ))
LIVE_MIN="${REUBICAR_LIVE_MIN:-15}"
[ "$age" -ge "$LIVE_MIN" ] || { echo "BLOQUEO G-LIVENESS: $TGT_FILE tocado hace ${age}m (<${LIVE_MIN}) ⇒ presunta VIVA"; exit 1; }
[ -f "$DRIVE/.export-$ID.lock" ] && { echo "BLOQUEO G-LIVENESS: auto-export detached en vuelo (el hook exporta en background)"; exit 1; }
echo "  ok G-LIVENESS: $TGT_FILE frío hace ${age}m"
```
+ **CITA HUMANA obligatoria** (gate, no la infiere el skill): *"la sesión `<id>` en `<máquina>` está
CERRADA"*. En el handoff esa cita se materializa como `REUBICAR_LIVENESS_OK=1` — sin ella el guion **no
corre** (§6.1). En cross-máquina el mtime se chequea en el host remoto con el helper, no con `stat -c` a
pelo: `ssh <host> 'stat -c %Y <jsonl> 2>/dev/null || stat -f %m <jsonl>'`.
> **Consecuencia clave:** la sesión que EJECUTA esta skill NO puede moverse a sí misma (mtime caliente +
> `G-SELF-MOVE`). Por eso el move de cada master lo dispara **el OTRO** — ver la danza §6.

### G-QUIESCE · CERO sesiones vivas — por ARTEFACTO, ANTES **y DESPUÉS** del move
> **[verificado 2026-09-08, mudanza de axon-master]** `G-LIVENESS` solo prueba que la sesión OBJETIVO está
> fría. **No basta:** cualquier sesión viva puede deshacer la mudanza *después* de que las postcondiciones
> de S4/S5 pasaron. Lo que pasó: el move quedó impecable y medido; luego un resume escribió un transcript
> NUEVO en el slug viejo, **reescribió el `target` de `masters.json` de vuelta al viejo**, y al morir
> volcó 5 líneas con el `cwd` viejo dentro del transcript ya migrado.
>
> **Y el `target` no "se revirtió" por accidente: lo REESCRIBIÓ EL HOOK, por diseño.**
> `exportar-sesion-master.sh` (bloque *"registrar/ACTUALIZAR en masters.json"*) corre **SIEMPRE** y hace
> **UPSERT**: si el id no está lo agrega; **si está con `target` distinto lo ACTUALIZA**; y si el título
> cambió, **actualiza el `name`**. Además corre **DETACHED** (`nohup … &`), así que sobrevive al "cerré
> todas las sesiones". Corolario operativo: mientras exista una sesión viva con el cwd viejo, el revert es
> **inevitable** — no es un bug que se pueda esquivar, es el motivo por el que este gate existe.

**Se detecta por artefacto (`mtime` de los `.jsonl`), no por proceso** — la única señal que existe en los
tres OS. Contar procesos con `pgrep` no sirve aquí y falla en las DOS direcciones (bloquea siempre en macOS,
pasa vacío en Git Bash): la narrativa causal completa está en §9, fila *"El gate de quiescencia no mide
nada"*, y no se repite aquí.
```bash
QUIESCE_MIN="${REUBICAR_QUIESCE_MIN:-5}"
ref="$(mktemp)"
touch -t "$(date -v-"${QUIESCE_MIN}"M '+%Y%m%d%H%M' 2>/dev/null || date -d "-${QUIESCE_MIN} min" '+%Y%m%d%H%M')" "$ref" \
  || { rm -f "$ref"; echo "BLOQUEO G-QUIESCE (fail-closed): no pude fabricar la referencia de tiempo (ni 'date -v' ni 'date -d')"; exit 1; }
calientes="$(find "$PROJ" -maxdepth 2 -name '*.jsonl' -newer "$ref" ! -name "$ID.jsonl" 2>/dev/null || true)"
rm -f "$ref"
[ -n "${YO:-}" ] && calientes="$(printf '%s\n' "$calientes" | grep -v "/$YO\.jsonl\$" || true)"   # el ejecutor no se cuenta
if [ -n "$(printf '%s' "$calientes" | tr -d '[:space:]')" ]; then
  echo "BLOQUEO G-QUIESCE: transcript(s) tocados hace <${QUIESCE_MIN}m ⇒ sesiones presuntamente VIVAS:"
  printf '  %s\n' $calientes
  echo "  Cierra TODAS las sesiones de Claude en esta máquina (el daemon transitorio CUENTA: arrastra el"
  echo "  PWD de quien lo lanzó) y vuelve a correr."
  exit 1
fi
echo "  ok G-QUIESCE: ningún transcript ajeno caliente (<${QUIESCE_MIN}m)"
```
+ **CITA HUMANA obligatoria:** *"cerré todas las sesiones de Claude en `<máquina>`"*. El humano ES el gate;
el barrido de artefactos solo lo corrobora. En el handoff se materializa como `REUBICAR_QUIESCE_OK=1`.
> **Corolario para el QA de S6:** el resume de verificación debe ser **el único** proceso de Claude en la
> máquina. Con otro encendido no sabrás si un síntoma es de la mudanza o del vecino.

### G-GITIGNORE · BLINDAR el `.gitignore` del destino ANTES de depositar nada sensible
Un destino cuyo `.gitignore` no cubra el `CLAUDE.local.md` de la raíz dejaría lo sensible TRACKEADO = fuga
[verificado en `cortex`; **compruébalo en TU destino**]. Se blinda ANTES de tocar T2 — y aplica igual si el
destino es privado (§1.0: un privado puede volverse público).

**Se verifica ARCHIVO POR ARCHIVO.** `git check-ignore A B C` sale **0 si CUALQUIERA** matchea (medido:
con solo `CLAUDE.local.md` ignorado, el lote de tres pasa en verde mientras dos siguen expuestos), y
`git ls-files --error-unmatch A B` sale ≠0 si **alguna** ruta no está trackeada — con lo que el `if` de
"¿ya trackeado?" era **siempre falso** incluso con el secreto ya en el índice. Además, un glob sin comillas
lo expande **el shell del operador en SU cwd**, no git en el repo destino (y en zsh, sin match, **aborta**
el bloque con `nomatch`).
```bash
for pat in 'CLAUDE.local.md' '.claude/memory/*.local.md' '.claude/settings.local.json'; do
  grep -qxF "$pat" "$DST_POSIX/.gitignore" 2>/dev/null || printf '%s\n' "$pat" >> "$DST_POSIX/.gitignore"
done
SENSIBLES=("$T2_ROOT")
for m in ${T2_LOCAL[@]+"${T2_LOCAL[@]}"}; do SENSIBLES+=(".claude/memory/$m"); done
for f in "${SENSIBLES[@]}"; do
  git -C "$DST_POSIX" check-ignore -q -- "$f" \
    || { echo "G-GITIGNORE: '$f' NO está ignorado ⇒ ABORTA (riesgo de fuga)"; exit 1; }
  if git -C "$DST_POSIX" ls-files --error-unmatch -- "$f" >/dev/null 2>&1; then
    echo "G-GITIGNORE: '$f' YA está trackeado (añadir al .gitignore NO des-trackea)"
    echo "  → git -C \"$DST_POSIX\" rm --cached -- '$f'   y commitea ANTES de seguir"; exit 1
  fi
  echo "  ok: '$f' ignorado y no trackeado"
done
```
> **Por qué el chequeo de fuga de S5 usa `--ignored`:** `git status --porcelain` **no lista archivos
> ignorados**, así que un `grep 'local\.md'` sobre su salida pasa trivialmente y no caza nada. Lo que se
> exige es que cada sensible sea `!!` (ver S5, §6.1).

### G-PARITY · POSTCONDICIÓN (de S1–S3) · "PRESENTE Y CORRECTO EN EL DESTINO", no "igual al origen"
No se mide "18 vs 4 skills" (mezcla plantilla con master). Y **no** se mide `SRC == DST`: para la clase que
§1.0.1 declara normal —el cerebro del master **nunca vivió en el origen**— un `diff -q` contra un archivo
ausente falla siempre y el gate bloquearía aunque el destino esté COMPLETO. Se mide lo que el invariante
enuncia: que lo clasificado del-master **esté en el destino y sea el bueno**.
```bash
fail=0
_paridad(){ # $1 = ruta en el origen (puede no existir), $2 = ruta en el destino, $3 = etiqueta
  if   [ -e "$1" ] && [ -e "$2" ]; then
    diff -q "$1" "$2" >/dev/null 2>&1 || { echo "  PARIDAD ROTA (existe en ambos y DIFIERE): $3"; fail=1; }
  elif [ -e "$2" ]; then echo "  ok (no venía del origen, ya está en el destino): $3"
  elif [ -e "$1" ]; then echo "  FALTA EN EL DESTINO: $3"; fail=1
  else echo "  FALTA EN AMBOS: $3 — ¿está bien clasificada en T1/T2? (Decisión #2)"; fail=1; fi
}
for m in ${MEMORIAS_T1[@]+"${MEMORIAS_T1[@]}"} ${T2_LOCAL[@]+"${T2_LOCAL[@]}"}; do
  _paridad "$SRC/memory/$m" "$DST/memory/$m" "$m"
done
_paridad "$SRC_REPO/$T2_ROOT" "$DST_POSIX/$T2_ROOT" "$T2_ROOT"
# T4 · CABLEADO: no se copia del origen, se VERIFICA que el destino tenga el suyo.
[ -f "$DST/settings.json" ] || { echo "  T4: falta $DST/settings.json (los hooks tier-repo del destino NO se cargarían)"; fail=1; }
[ -f "$DST/settings.local.json" ] || echo "  T4 aviso: sin settings.local.json en el destino ⇒ el master despertará SIN su outputStyle (config per-máquina, gitignored: se re-crea a mano)"
# El subdir intocable del destino es PARAMÉTRICO (vacío = ninguno). No todo destino tiene 'brain/':
# `axon` no lo tiene, y hardcodearlo abortaba con un diagnóstico FALSO ("¿repo equivocado?").
if [ -n "${DST_PROTEGIDO:-}" ]; then
  [ -d "$DST_POSIX/$DST_PROTEGIDO" ] || { echo "  falta '$DST_PROTEGIDO' en $DST_POSIX (¿destino equivocado?)"; fail=1; }
fi
[ "$fail" -eq 0 ] || { echo "G-PARITY: BLOQUEA hasta migrar (S1/S2/S5)"; exit 1; }
echo "  ok G-PARITY"
```

---
## 4 · MÁQUINA DE ESTADOS (INV: NADA A MEDIAS — re-entrante, postcondición verificada por paso)
Al invocarse, **detecta el estado por sus postcondiciones y CONTINÚA** (no reinicia, no deja tail). Y a
partir del **punto de no retorno** (el `unlinkSync` del origen, dentro de `session-move.js` → `main()`) la
reanudación no adivina: el handoff deja `$DRIVE/reubicar-<ID>.state` con el paso alcanzado.

| Estado | Garantiza | Detector (postcondición) | Lo corre |
|---|---|---|---|
| **S0** reconstituido | Gate R hecho (lo que "sí iba" en el origen regresó del slug global) | memorias confirmadas presentes en `$SRC/memory`; `MEMORY.md`↔archivos cuadra | sesión viva (cuerpo) |
| **S1** T1 migrado (PR) | T1 versionado, merge dedup por CONTENIDO | `diff -q` T1 = idéntico en `$DST/memory` | sesión viva (cuerpo) |
| **S2** T2 empacado | bundle sensible en Drive | `$DRIVE/$ID.brain-local.tgz` existe (o `.aplicado` de una corrida previa) | sesión viva (cuerpo) |
| **S3** export-first | el `.gz` de Drive **cubre** la sesión (por CONTENIDO: nº de líneas ≥) | `gunzip -c "$DRIVE/$ID.jsonl.gz" \| wc -l` ≥ `wc -l < "$TGT_FILE"` | **handoff §6.1** |
| **S4** re-anclado | jsonl en slug nuevo (contenido validado) + cwd único + último evento normalizado + modo + target/name por-id con LOCK + alias, en UN bloque | ver "Postcondiciones S4" abajo — **todas ASERCIONES** | **handoff §6.1** |
| **S5** saneado | T2 depositado gitignored SIN pisar, residuo quirúrgico, cero symlinks | T2 presente e `!!` en `--ignored`; sin `.jsonl` viejo; `find "$DST" -type l` vacío | **handoff §6.1** |
| **S6** doc=realidad + QA | commit del versionable + docs; QA humano | dashboard/estado al día; humano confirmó resume | humano |
| **S7** re-verificado post-QA | las invariantes de S4/S5 siguen en pie DESPUÉS del resume | `_postcondiciones` en verde con `G-QUIESCE` otra vez ok | **handoff §6.1 (`REUBICAR_MODO=s7`)** |

> **S7 tiene fila propia a propósito.** Antes el mecanismo de re-entrancia listaba S0→S6 y una corrida
> cortada después del QA no tenía estado que detectar — el parche había añadido el paso pero no el estado.

### S0 · Reconstituir el cerebro canónico del origen (Gate R — que el ORIGEN tampoco quede a medias)
La consolidación rig-master (2026-08-02) se llevó memorias del proyecto al slug global de MÁQUINA. Regresan
las que sean del **proyecto/plantilla** (NO lo de máquina: kde/nvidia/kernel/openrgb se quedan global).
Descubrimiento (no bulk — el humano clasifica, anti-confabulación):
```bash
grep -rilE 'plantilladotnet|\.NET|blazor|dapper|EF Core|webapi|migracion-ef' "$GLOBAL_MEM/" | sort
BK="$HOME/.claude/reubicar-backups/$(date +%s)"; mkdir -p "$BK"; cp -a "$SRC/memory" "$BK/memory.src.bak"
MEMORIAS_REGRESAN=()     # ← ARRAY; poblar con lo que el humano confirme (Decisión #4); vacío ⇒ no-op verificado
for m in ${MEMORIAS_REGRESAN[@]+"${MEMORIAS_REGRESAN[@]}"}; do
  [ -e "$SRC/memory/$m" ] || cp -f "$GLOBAL_MEM/$m" "$SRC/memory/$m"
done
# re-indexar $SRC/memory/MEMORY.md; diff -q antes de descartar copias del global (a .trash/, NUNCA rm a ciegas)
```
**Honestidad:** hoy NO hay lista confirmada de "memorias del origen dejadas en el global"; el grep es el
MÉTODO, la clasificación la hace el humano. **Postcondición S0:** `MEMORY.md`↔archivos cuadra; escaneo de
secretos limpio.

### S1 · Migrar T1 (versionado, por PR — como rig-master, repo compartido)
> **No se mueve la rama del árbol del humano.** El folder de trabajo visible del dev vive en SU
> mini-develop y es su superficie estable de QA; un `git checkout develop` en el repo destino se la saca de
> abajo de los pies — y ramificar de `develop` viola la regla operativa (las ramitas salen de la mini y
> vuelven a la mini). S1 **ramifica de la rama VIVA del destino** y exige árbol limpio.
```bash
[ -z "$(git -C "$DST_POSIX" status --porcelain)" ] \
  || { echo "S1: el árbol de $DST_POSIX tiene cambios sin commitear ⇒ decide el humano (no lo toco)"; exit 1; }
BASE_DST="$(git -C "$DST_POSIX" branch --show-current)"
[ -n "$BASE_DST" ] || { echo "S1: el destino está en detached HEAD ⇒ el humano elige la base"; exit 1; }
echo "S1: ramificando de la rama VIVA del destino: $BASE_DST"
git -C "$DST_POSIX" checkout -b "docs/reubicar-$MASTER_NAME"
# escaneo de secretos ANTES de commitear lo que se co-ubica (array: nombres con espacio no se parten):
T1_RUTAS=(); for m in ${MEMORIAS_T1[@]+"${MEMORIAS_T1[@]}"}; do T1_RUTAS+=("$SRC/memory/$m"); done
if [ "${#T1_RUTAS[@]}" -gt 0 ] && grep -rinE 'pass(word|wd)?|secret|token|api[_-]?key|credential|\.env\b' "${T1_RUTAS[@]}"; then
  echo "BLOQUEO: Secreto detectado en T1. NO commitear a repo público."; exit 1
fi
for m in ${MEMORIAS_T1[@]+"${MEMORIAS_T1[@]}"}; do
  if [ -e "$DST/memory/$m" ] && ! diff -q "$SRC/memory/$m" "$DST/memory/$m" >/dev/null 2>&1; then
    echo "CONFLICTO $m: existe distinto en destino → reconciliar con humano (no piso)"
  else
    cp -f "$SRC/memory/$m" "$DST/memory/$m"
  fi
done
# indexar cada uno en $DST/memory/MEMORY.md (doc=realidad; editar, no duplicar líneas)
git -C "$DST_POSIX" add .claude/memory .gitignore
git -C "$DST_POSIX" status --short .claude | grep -iE 'local|\.jsonl|sessions' \
  && { echo "ABORT: algo sensible staged"; exit 1; } || true
git -C "$DST_POSIX" commit -m "docs(cerebro): traslada el cerebro personal del $MASTER_NAME a este repo"
```
Lo SENSIBLE (T2) NO va aquí — va por S2/S5. **Postcondición S1:** `diff -q` T1 idéntico en `$DST`.

### S2 · Empacar T2 (gitignored) para viajar cross-máquina
```bash
tmp2="$(mktemp -d)"; hay=0
for m in ${T2_LOCAL[@]+"${T2_LOCAL[@]}"}; do
  [ -f "$SRC/memory/$m" ] && { cp -a "$SRC/memory/$m" "$tmp2/"; hay=1; }
done
[ -f "$SRC_REPO/$T2_ROOT" ] && { cp -a "$SRC_REPO/$T2_ROOT" "$tmp2/$T2_ROOT"; hay=1; }
if [ "$hay" -eq 1 ]; then
  tar -C "$tmp2" -czf "$DRIVE/$ID.brain-local.tgz" .
  test -f "$DRIVE/$ID.brain-local.tgz" || { echo "S2: no se creó el bundle"; exit 1; }
  echo "S2 ok: $DRIVE/$ID.brain-local.tgz"
else
  echo "S2 NO-OP verificado: el origen no tiene ningún T2 (§1.0.1). S5 lo guardará: no habrá tar que extraer."
fi
rm -rf "$tmp2"
```
> **`$T2_ROOT` puede NO existir en ninguno de los dos extremos** (hoy, `CLAUDE.local.md` no existe ni en
> `plantilladotnet` ni en `cortex`). Todo el andamiaje de T2 lo trata como opcional: S2 lo guarda, S5 lo
> guarda y `G-PARITY` lo reporta como "falta en ambos" para que el humano decida si estaba mal clasificado.

### S3 · EXPORT-FIRST — el `.gz` de Drive **cubre** la sesión (por CONTENIDO, no por mtime)
**Bash: el handoff (§6.1) — lo genera `reubicar-master.sh`.** Qué hace y por qué:
- Re-exporta el transcript CERRADO al Drive **antes** de mover, con `--name "$NOMBRE_FINAL"` (el nombre
  **final**, no el viejo: `session-import.js` restaura el alias desde `meta.label`, así que exportar con el
  nombre viejo hace que un `seed`/import posterior **revierta** el renombre).
- Es la **capa 3 de recuperación** (§8): tener el `.gz` fresco antes de un `unlink` irreversible es
  rollback barato. **El orden export-first → move → fix-de-referencias es correcto y no cambia.**
- **Su postcondición se mide por CONTENIDO.** La versión anterior comparaba `mtime` del `.gz` contra el del
  `.jsonl`, pero el `.gz` se acaba de copiar con `cp` (sin `-p`) ⇒ mtime = ahora ⇒ **siempre ≥**: una
  tautología que no podía fallar. Ahora: `gunzip -c … | wc -l` ≥ `wc -l < "$TGT_FILE"`.
> **Corrección de premisa (la vieja justificación era FALSA):** el skill decía *"`seed.sh --force` pasa
> `--force` a import sin freshness"*. **El freshness gate EXISTE** — `session-import.js` lo trae comentado
> literalmente como `FRESHNESS GATE (#2)`: con `--force` sobre una sesión que ya existe local, si la copia
> LOCAL está más fresca **NO se pisa**; solo `--force-stale` lo salta, y `seed.sh` lo documenta igual. El
> escenario que esa premisa temía está cerrado. S3 sigue existiendo por la razón de arriba (rollback
> barato), no por esa.

### S4 · RE-ANCLAR + FIX TARGET/NAME + ALIAS — bloque ininterrumpido
**Bash: el handoff (§6.1) — lo genera `reubicar-master.sh`.** **LOCAL** (mismo host) → `session-move.js` (mueve, reescribe el `cwd` de TODAS las líneas,
respalda, aborta si colisiona). **CROSS-MÁQUINA** → `session-import.js` (§6.3, carril distinto con
postcondiciones propias). Sub-pasos y su razón:

1. **Respaldo PROPIO + respaldo del registro** antes de tocar nada, con sufijos que la poda no recicla.
2. **move** con `--to-cwd "$DST_CWD"` (la ruta que el harness verá; en Windows la NATIVA) **y
   `--git-branch "$RAMA_DST"`**, más **validación de CONTENIDO** del resultado (nº de líneas del destino ≥
   el del origen). Los dos flags hacen que el re-anclaje COMPLETO —cwd de todas las líneas + el par
   `(cwd, gitBranch)` del último evento con `cwd`— ocurra **en la misma pasada en streaming, ANTES del
   `unlink`**, que es lo que elimina la segunda lectura del archivo después de la mutación destructiva.
   `session-move.js` publica el destino con **temp+verify+rename** y **conserva el modo del origen**, así
   que un corte a media escritura deja solo el `.part` y el origen vivo: nunca un destino truncado
   haciéndose pasar por "S4 hecho". La validación de contenido se queda como defensa en profundidad.
3. **cwd uniforme y último evento correctos**, medidos con `_cwds`/`_ultimo_par` (JSON de **primer
   nivel**: un `cwd` anidado dentro de `toolUseResult` no cuenta, y la línea cortada se tolera — es la
   misma vista que tiene el harness). Si algo no cuadra, se **repara con `_reancla`** —también en
   streaming, por `rewriteTranscriptStream`— y se re-mide.
   **Asimetría declarada:** el `cwd` histórico **sí** se aplasta (lo exige el re-anclaje) y el `gitBranch`
   histórico **no** (solo el del último evento). No son el mismo caso: el `cwd` es lo que el harness usa
   para ubicar la sesión, la rama es dato histórico. Consecuencia asumida: tras la mudanza el transcript
   **no** conserva el cwd original, así que cualquier reconstrucción de procedencia debe leerlo del
   `.meta.json` del Drive, no del `.jsonl`.
4. **Nada de este bloque lee el transcript completo a un string.** Es una regla, no una casualidad: el
   move va en streaming y `_reancla` acota su memoria a una ventana de retención de 32 MiB (medido: el
   pico lo fija la ventana, **no** el tamaño del archivo). El patrón que se prohíbe —`readFileSync` del
   `.jsonl` **después** del punto de no retorno— costaba **1.73 GiB de pico sobre un archivo de 429 MB**
   (medido), justo donde una excepción por memoria es catastrófica.
5. **2c · `chmod 600`.** El move conserva el modo del **ORIGEN**, y el origen puede venir fuera de
   convención (verificado 2026-09-08: 1 de 131 en 644 donde el resto del slug está en 600) ⇒ se normaliza
   aquí. En **Windows/NTFS es no-op** y se declara como tal en vez de fingir la postcondición.
6. **3 · `masters.json` UPSERT (no UPDATE) tomando el LOCK del ecosistema.** Tres arreglos en un paso:
   - **UPSERT:** con un id ausente del registro —el caso REAL de `G-ID`— un `|=` UPDATE devuelve el JSON
     **intacto y sale 0**.
   - **No hay `&&`:** se escribe `if ! jq …`, no `jq … > tmp && mv tmp dst` — ese idioma deja el `jq`
     exento de `errexit` y un fallo real seguía hasta imprimir éxito (detalle en §9).
   - **Lock + aserción:** el hook de auto-export **ya** serializa el read-modify-write con un lock atómico
     por `mkdir` (`$MJ.lock`, reciclando huérfanos >5 min) y **ya** escribe tmp+rename. S4 **usa ese mismo
     lock** y su `tmp` va en el **MISMO directorio** que `$MJ` (con `mktemp` caía en otro filesystem y el
     `mv` era copy+unlink, no un rename atómico). Y después **relee y asere**: no se confía en el exit.
7. **4 · alias** con `writeAlias` **y su verificador**. `writeAlias` ya escribe tmp+rename y, si el
   `sesiones-alias.json` existente es ilegible, lo **respalda y avisa** en vez de degradarlo a `{}` (que
   habría reemplazado el mapa entero por una sola entrada). El verificador se queda: relee con
   `sessionAliases()` y **asere** — lo que queda sin cubrir del lado de la lib es el escritor
   CONCURRENTE (dos `writeAlias` a la vez pueden perder una actualización por last-writer-wins), y
   `G-QUIESCE` es lo que hace improbable ese escenario durante la mudanza.
8. **5 · residuo del RENOMBRE, el real.** El alias **no es un symlink** (es un mapa JSON por id en
   `~/.claude/sesiones-alias.json`, y `writeAlias` sobrescribe la misma clave), así que el `find … -type l`
   de la versión anterior era un paso fantasma que siempre imprimía nada. Los residuos que SÍ existen:
   **otras entradas de `masters.json` con el nombre viejo** (el caso real contó *"dos `claude-brain-master`,
   dos `claude-brain-cachy-master`, tres `games-master`, dos `rig-master`"*), el `meta.label` del Drive (lo
   regenera S3 con `$NOMBRE_FINAL`) y el `customTitle` del transcript.

> **El RENOMBRE es parte del mismo bloque, no un paso aparte.** Un master cuyo `target` se movió pero cuyo
> `name` sigue siendo el viejo es la misma clase de tail que `helios-selene`. Caso real:
> `claude-brain-cachy-master` → `axon-master`, decidido el 2026-08-22, con `masters.json` todavía diciendo
> el nombre viejo semanas después porque el renombre no tenía dueño.

**Postcondiciones S4 (todas ASERCIONES — el guion NO imprime el ✅ si alguna falla):**
`find "$PROJ" -name "$ID.jsonl"` = **exactamente 1**; **líneas del destino ≥ líneas del origen**; `_cwds`
= un único valor y ese valor = `$DST_CWD`; `_ultimo_par` = `$DST_CWD|$RAMA_DST`; **modo 600** (informativo
en Windows); `masters.json` releído: `target` = `$TARGET` **y** `name` = `$NOMBRE_FINAL`; **alias releído**
con `sessionAliases()` = `$NOMBRE_FINAL`.

### S5 · Depositar T2 SIN PISAR + barrido QUIRÚRGICO + CERO symlinks
**Bash: el handoff (§6.1) — lo genera `reubicar-master.sh`.** Qué cambia respecto a la versión que clobbeaba:
- **T2 no se pisa.** El bundle se extrae a un `mktemp -d`, se **diffea** contra el destino y **ante
  cualquier diferencia se PARA pidiendo reconciliación humana** — la misma regla que S1 ya tenía para T1.
  Por qué es la pérdida más cara del flujo (identidad + autorizaciones, gitignored ⇒ git no las recupera)
  está en §9, fila *"T2 del destino CLOBBEADO"*. Dato vigente: hay dos copias divergentes vivas del
  archivo de autorizaciones (4 líneas / 7 líneas, distintas fechas).
- **Respaldo antes de escribir** en `$HOME/.claude/reubicar-backups/<ID>.<ts>.t2/`.
- **Idempotencia real:** el bundle consumido se renombra a `.tgz.aplicado`. Antes, re-correr el guion —lo
  que su propia cabecera *"idempotente y re-entrante"* invita a hacer— **revertía en silencio** la edición
  de identidad que S5/S6 exigen ("corro desde `<destino>` (mi nueva base)").
- **Chequeo de fuga con `--ignored`**, exigiendo `!!` por archivo (ver G-GITIGNORE).
- **`memory` del slug COMPARTIDO: intacto.** Se barre SOLO `<id>.jsonl`.
- **CERO symlinks nuevos.** Decisión de unjordi (2026-09-08, textual): *"QUIERO QUE ESTO QUEDE SIN
  SIMLINKS. PUNTO"* · *"son un pinche bug que no logro que dejen de propagar"*. El cerebro del repo se lee
  NATIVO porque el destino es el cwd; el `memory` de un slug es el canal per-máquina y va como
  **DIRECTORIO REAL** o no existe. Medido en Cachy: de 20 slugs con `memory`, los 5 que unjordi considera
  bien hechos tienen dir real y los 15 con symlink los sembró `claude-proyecto-autocontenido`, que lo
  PRESCRIBE. Si el bootstrap ya lo creó, se **retira** (borrando solo el enlace, sin `-r` y sin slash
  final). El verificador corre **sin `-L`**: con `-L`, `find` sigue el enlace y lo clasifica por su destino
  ⇒ **solo ve los ROTOS** (verificado con fixture: un symlink sano NO aparece) — justo el que no ve los que
  violan la decisión. Y **falla**, no solo imprime.
- **El `memory` del slug VIEJO se detecta y se avisa** (§1.0.2): no se mueve, y si el master guardó algo
  suyo ahí, es Decisión #7.

### S6 · doc=realidad + commit + QA FUNCIONAL (humano = sello LISTO)
- **MR de T1 → develop en PREVIEW** (repo compartido): con OK EXPLÍCITO de unjordi y `--squash` (lo exigen
  `confirmar-merge-develop`/`merge-squash-guard`). **NUNCA `--auto-merge`** — integridad de guardarraíles.
  Sin OK, queda en la mini-develop (Decisión #5). Solo lo versionable (T1 + gitignore); jamás
  `.jsonl`/`*.local.md`/`$DST_PROTEGIDO`.
- Actualizar: **dashboard global** (Mapa: el master ahora vive en `$TARGET` + bitácora fechada con `>>`),
  `estado-proyecto.md`, y el `CLAUDE.local.md`/README del origen si mencionaba al master como residente.
  **Registrar la RUEDA** (el TAIL que a helios-selene le faltó).
- **Barrer los CONSUMIDORES de la ruta vieja.** Al mover el transcript cambia su RUTA, y hay mecanismos
  *path-addressed* (p. ej. `axon resume --from <transcript.jsonl>`): cualquier `--from`, alias, script o
  doc con la ruta literal del slug viejo muere con la mudanza. Prefiere siempre la forma id→ruta.
  ```bash
  grep -rn --exclude-dir=.git --include='*.md' --include='*.sh' --include='*.json' \
       --include='*.ts' --include='*.js' -- "$OLD_SLUG" "$HOME/code" "$HOME/.claude" 2>/dev/null | head -40
  ```
- **LISTO = QA del humano.** `claude --resume "$ID"` **parado en `$DST_CWD`** (el `cd` es requisito duro:
  el scope de `--resume` es repo + worktrees, y el slug sale del cwd del PROCESO). `claude -r` acepta
  `<id|nombre>`; el título automático **no** es handle de reanudación, así que usa el `<id>` o el alias que
  S4 acaba de escribir. Confirmar: (a) reanuda sin folder muerto; (b) identidad cargada
  (conocimiento-propio re-inyectado por `aviso-drift-cerebro`); (c) las skills del destino + las GLOBAL
  aparecen; (d) las memorias-del-master (T1∪T2) están; (e) **T4: los hooks tier-`repo` del destino
  disparan y el `outputStyle` es el suyo**; (f) `masters.json` con el **target Y el name** correctos, y el
  alias apuntando al nombre final. **Verde técnico ≠ LISTO. No se declara a ciegas.**

### S7 · RE-VERIFICAR DESPUÉS DEL QA (el paso que faltaba, ahora EJECUTABLE)
> **El skill terminaba en S6, y el daño ocurre en S6.** El QA es un resume, y un resume MUTA: escribe
> eventos, deriva un slug del cwd del proceso y —vía el hook, **por diseño**— reescribe el `target` de
> `masters.json` desde el cwd vivo. Declarar LISTO con las postcondiciones de S4/S5 es declarar sobre un
> estado que el propio QA ya cambió. [verificado 2026-09-08]

**Cómo se corre:** `REUBICAR_MODO=s7 bash "$DRIVE/handoff-$ID.sh"` — **desde un shell plano**, con el
resume de QA ya cerrado. Re-evalúa `G-QUIESCE` y luego la MISMA función `_postcondiciones` de S4/S5 (una
sola definición ⇒ S7 no puede medir algo distinto de lo que S4 exigió).

**Quién lo corre, explícito:** un shell plano. Si lo corriera una sesión de Claude, `G-QUIESCE` se contaría
a sí misma — el gate excluye el `.jsonl` del ejecutor cuando puede identificarlo (`$YO`), y si corre dentro
de Claude sin poder leer su id, `G-SELF-MOVE` ya bloqueó antes.

**Remedios (y su COTA).** Si falla:
1. **>1 copia** — la del slug viejo es un transcript **NUEVO**, no un duplicado: **no se borra**; se saca
   del árbol de proyectos (`mv` a `~/.claude/session-move-backups/`, nunca `rm`) y se conserva.
2. **target revertido** — re-corre el modo `full`: es idempotente y vuelve a hacer el UPSERT con el lock.
3. **cwd contaminado o último evento revertido** — el guion los repara con `_reancla` (streaming, la
   MISMA lib que usa el move) y re-mide. Ojo: el re-anclaje preserva por diseño las líneas que no parsean
   (la última cortada), así que **no puede** arreglar un `cwd` que vive en una línea truncada — y `_cwds`
   tampoco lo cuenta, que es la vista correcta (el harness también parsea JSON por línea). El remedio y
   la medición ven lo mismo. Cota declarada: si el último evento con `cwd` quedara a más de 32 MiB del
   final del archivo, `_reancla` **lo reporta como fallo** en vez de dar el paso por hecho.
4. **último par incorrecto** — es una **ASERCIÓN** que aborta, no un `jq -r` que imprime `rama=null` y pasa.
5. **reapareció el symlink** — el bootstrap lo re-siembra; se retira.

**COTA del bucle S6→S7 (declarada):** cada remedio de S7 deja un estado que solo un nuevo resume valida
funcionalmente ⇒ S6'→S7'. **Máximo 2 iteraciones.** Si la tercera falla, **PARA y escala al humano**: hay
algo re-escribiendo el estado fuera de la ventana del skill (típicamente una sesión viva o un gemelo
sincronizando por Drive) y seguir iterando solo suma pasadas destructivas sobre un archivo de cientos de MB.

**Postcondición S7 = la de S4/S5, re-medida.** Solo entonces el humano puede sellar LISTO.

---

## 5 · Resumen del flujo (una máquina)
```
PRELUDIO (§2: preflight de herramientas/plataforma/Drive/BIN + derivadas)
  → G-SELF-MOVE → G-ID
  → S0 canónico-origen → G-GITIGNORE → S1 T1(PR) → S2 T2-bundle          [NO destructivo · cuerpo]
  → G-LIVENESS(cerrada, cita humana) → G-QUIESCE(cita humana)            [gates del handoff]
  → S3 export-first → S4 {move --git-branch + 2c + target/name con LOCK + alias} → S5 {T2 sin pisar + residuo
    quirúrgico + cero symlinks} → _postcondiciones                        [handoff §6.1 · MODO=full]
  → G-PARITY (postcondición de S1–S3/S5)
  → S6 doc + QA-humano (resume parado en $DST_CWD)
  → S7 re-verificar POST-QA                                              [handoff §6.1 · MODO=s7]
```
`G-QUIESCE` corre **antes de S3 y otra vez en S7**. Re-entrante: cada S deja postcondición verificable y,
pasado el punto de no retorno, además un `$ST` con el paso alcanzado; una corrida a medias se reanuda desde
el primer S cuya postcondición falle. **`REUBICAR_MODO=dry`** corre preludio + todos los gates + imprime el
plan y el último evento, y **sale antes de mutar** — úsalo siempre la primera vez.

---
## 6 · Quién ejecuta el move (la clave: **nadie se auto-mueve**)

`G-SELF-MOVE` + `G-LIVENESS` impiden que una sesión mueva su propio transcript (se partiría en dos). De
ahí sale todo lo demás: **el move lo dispara SIEMPRE alguien que no es la sesión objetivo.** Hay dos
formas, y **la primera es la que aplica en el caso normal** — léela y, si te basta, sáltate §6.0.

### 6.0 · UN solo master (caso simple · es el caso REAL pendiente)
No hace falta SSH, ni gemelo, ni coreografía. Tres pasos:
1. **La sesión VIVA prepara** lo NO-destructivo: `G-SELF-MOVE` / `G-ID` / S0 / `G-GITIGNORE` / S1 (T1
   por PR, o detectar que el destino ya está canonizado y es no-op, §1.0.1) / S2 (bundle T2) / y **corre
   `reubicar-master.sh`**, que escribe el preludio, genera el handoff a disco y lo VERIFICA (§6.1).
2. **El humano CIERRA la sesión** y da las dos citas. Un **shell plano en la MISMA máquina** corre el
   handoff:
   ```bash
   REUBICAR_MODO=dry bash "$DRIVE/handoff-$ID.sh"                                  # primero, siempre
   REUBICAR_LIVENESS_OK=1 REUBICAR_QUIESCE_OK=1 bash "$DRIVE/handoff-$ID.sh"
   ```
   (el `--dry` del script ya corrió el primero por ti; el handoff es autocontenido y no necesita ni el
   script ni el skill para ejecutarse)
3. **El humano resume** el master en su nueva casa (parado en `$DST_CWD`) → QA de §S6 → **S7**.

Es el caso de la mudanza pendiente de `axon-master`. Si estás aquí, **§6.0 es todo lo que necesitas leer
de esta sección**; sigue en §6.1 (el generador del handoff).

### 6.0.1 · DOS masters gemelos — la danza SSH cruzada
Aplica **solo** si hay que mudar dos masters vivos en máquinas distintas y ninguno puede auto-moverse.
Requisito textual del humano: *"muevas al gemelo por ssh y luego pedirle a él que te mueva."* → **cada
máquina dispara el move del OTRO master, que está CERRADO**. SSH es el **plano de control** (ordena el
move remoto); **Drive es el plano de datos** (transporta el `.gz` + el bundle T2); **git-PR** lleva T1. El
transcript de cada master ya es LOCAL a su máquina — SSH no transporta el `.jsonl`, solo ORDENA el move allá.

**Preflight SSH:** `ssh -o BatchMode=yes -o ConnectTimeout=8 <usuario>@<host> 'echo ok'` (key-auth + mDNS)
+ verificar `node`, `jq` y el `$DST_REPO` remoto, y que los scripts de sesión existan allá (el preludio los
resuelve solo: `$CORTEX_BIN`, `~/.local/bin`, `~/.cortex/bin`, `~/code/cortex/bin`).

> **Los gemelos NO tienen por qué ir al MISMO destino.** La danza no consolida: solo resuelve el
> huevo-y-gallina de que nadie puede auto-moverse. Cada master declara SU `DST_REPO` (Decisión #0) y puede
> además renombrarse (#0b). Estado real al 2026-09-08: el gemelo Mac ya opera como **`cortex-master`** con
> casa en `cortex`; el de Cachy va a **`axon`** y se renombra a **`axon-master`**. Destinos distintos, misma
> coreografía.

**Coreografía (genérica — A y B son los dos masters; cada uno con su propio `DST_REPO`):**
1. **Preparar A** — igual que el paso 1 de §6.0, en la máquina de A.
2. **El humano CIERRA a A** y da las dos citas. Desde la otra máquina, por SSH, **B** (o un shell plano)
   corre el handoff de A: `REUBICAR_LIVENESS_OK=1 REUBICAR_QUIESCE_OK=1 bash "$DRIVE/handoff-<id-A>.sh"`.
   La identidad T2 de A viaja por su bundle de Drive; T1 le llega con `git pull` del PR mergeado.
3. **El humano resume A** en su nueva casa → A vivo con cerebro completo. QA (§S6) → **S7**.
4. **El humano CIERRA a B.** Ahora **A** (vivo en su casa nueva) corre por SSH el handoff de B. **Así cada
   uno mueve al otro** — ninguno se auto-mueve.
5. **El humano resume B** en su casa → cerebro completo. QA (§S6) → **S7**, en cada máquina.

**Cómo sobrevive el orquestador a su propia reubicación:** la sesión viva orquesta el move del OTRO; NO
puede ejecutar el suyo → lo ejecuta el otro master, un shell plano o una sesión distinta. "Sobrevive"
reapareciendo con `claude --resume` desde el slug nuevo.

### 6.1 · Handoff a DISCO — la ÚNICA fuente de los pasos destructivos

`reubicar-master.sh` escribe el guion del paso destructivo a `$DRIVE/handoff-$ID.sh` para que **otra
persona u otra sesión lo corra tal cual**, con la sesión objetivo cerrada. Sobrevive compactaciones
porque vive en disco, y es **autocontenido**: cabecera con los parámetros horneados (`printf %q`) +
el preludio TEXTUAL + los pasos. No necesita ni el skill ni el script para correr.

**Tres modos:** `REUBICAR_MODO=dry` (gates + plan, sin mutar — **úsalo siempre primero**), `full`
(default, los pasos destructivos) y `s7` (re-verificar tras el QA).

```bash
reubicar-master.sh --id <uuid> --dst-repo <ruta> --master-name <nombre> [...] --dry   # genera + plan
REUBICAR_LIVENESS_OK=1 REUBICAR_QUIESCE_OK=1 bash "$DRIVE/handoff-<id>.sh"            # destructivo
REUBICAR_MODO=s7 REUBICAR_QUIESCE_OK=1 bash "$DRIVE/handoff-<id>.sh"                  # tras el QA
reubicar-master.sh verificar "$DRIVE/handoff-<id>.sh"                                 # re-verificar
```

> **Regla dura: el handoff se escribe COMPLETO y EJECUTABLE.** Un handoff que dice "(ver SKILL §4)"
> obliga a quien lo corre a reconstruir los pasos destructivos a mano — justo lo que el skill existe para
> evitar. Si un paso no se puede escribir, va su `echo` y un `exit 1`, nunca un comentario que finge que
> está resuelto. **Y este guion no puede reportar éxito sobre un estado a medias:** sus
> "postcondiciones" imprimían en vez de aserir, así que decía **"✅ Move hecho"** con el `masters.json`
> intacto — el modo de fallo más caro posible, *un artefacto que certifica lo que no verificó*, entregado
> precisamente a quien lo corre sin haber leído el skill. Hoy **toda** postcondición es una aserción, el
> `✅` habla de "pasos destructivos verificados" (no de LISTO) y las citas humanas son **gates reales**.

#### Lo que el candado verifica AL GENERAR (y lo que NO)
`_verificar_handoff` corre en el mismo proceso que generó el handoff, y su fallo es un `exit 1` **antes
de que exista un handoff utilizable**. Tres capas, cada una con su alcance declarado:

1. **El PRELUDIO quedó EMBEBIDO.** Presencia TEXTUAL (byte a byte, con `node`) cuando el preludio está a
   mano, y presencia de sus SÍMBOLOS —helpers y derivadas, en frontera de palabra— siempre. La capa
   textual cierra la CLASE: lo que el preludio gane mañana viaja solo, sin que nadie actualice una lista.
   La lista de símbolos se verifica **contra el preludio real**: si driftó, el candado lo dice en vez de
   creerse. Es **la capa que faltaba** el 2026-09-10 y la que habría atajado el handoff muerto.
2. **Los pasos obligatorios, en línea EJECUTABLE** (14 marcadores + `PUNTO DE NO RETORNO`). Detecta que
   una edición futura del generador borre un paso o lo degrade a comentario — `bash -n` no lo caza: un
   guion al que le falta un paso es sintácticamente perfecto. Mencionar el marcador en un comentario NO
   satisface el candado (era el hueco más barato de abrir sin querer al reescribir un bloque).
3. **Prohibiciones + sintaxis + LF:** cero `ln -s` (S5 lo prohíbe por decisión textual del humano), cero
   stubs `ver SKILL §`, ningún `stat -c` sin el helper portable, `bash -n` limpio y **cero CR** (el Drive
   sincroniza con Windows y un `\r` invisible rompe el parseo antes de que ninguna línea pueda defenderse).

**Ninguna de las tres prueba que el guion FUNCIONE**, y la capa 2 en particular mide presencia de TEXTO:
un paso que dijera lo correcto sin hacer nada la pasaría. Lo que prueba la corrección es
`_postcondiciones` **cuando el guion se ejecuta** (todas aserciones) y el `REUBICAR_MODO=dry` previo. Un
handoff que no se puede correr no es un handoff; **uno que puede reportar éxito sin verificar es peor que
no tenerlo** — y por eso el sello del cierre sigue siendo la QA del humano, no el `✅` del guion.

> **Si el guion viajó por Drive/Windows** y se queja en su primera línea (`set: -<CR>: invalid option`),
> el candado ya te lo dijo con el comando exacto: `LC_ALL=C tr -d '\r' < h.sh > h2.sh && mv h2.sh h.sh`.
> `reubicar-master.sh verificar <handoff>` lo re-verifica sin regenerarlo — no necesita ni Drive ni
> parámetros.


### 6.2 · Fallback SIN SSH (Drive caído o sin mDNS/key-auth)
Consolidar dos máquinas sin una sola llamada SSH: en CADA máquina, un operador local (shell plano) corre
**su propio handoff** para SU master cerrado; T1 por `git pull` del PR; T2 por el bundle Drive. **SSH no
exime ningún gate.** Si aparece un `masters (1).json` (copia-en-conflicto de Drive), el preludio **aborta**
y hay que reconciliar a mano ANTES (Decisión #6) — `masters.json` es UN archivo compartido, edición por-id
serializada **con el lock**, nunca en ambas máquinas dentro de la ventana de sync.

### 6.3 · Carril CROSS-MÁQUINA por import (cuando el `.jsonl` NO está en esta máquina)
> **Los dos carriles no son intercambiables y antes se prescribían como si lo fueran.** El de §6 mueve el
> transcript **local** (SSH solo ORDENA); este SIEMBRA uno que llegó por Drive. Elige UNO y usa SUS
> postcondiciones.

Lo que hace y lo que **no**:
- El comando correcto es **explícito**, con `--sessions-dir`: `session-import.js` lee los `.gz` de
  `<repo>/.claude/sessions/` **por default**, y los de este skill viven en **el Drive** ⇒ sin la bandera
  sale `{"ok":true,"imported":[], "note":"sin sesiones que importar…"}` **con exit 0**: el operador cree
  que sembró y no sembró nada.
- **Reescribe TODOS los `cwd` al repo local** (`lib.rewriteCwd(text, repoRoot)`) — no es un "swap
  `/home`↔`/Users`", como decía la doc vieja; es más general (y por eso Windows sí funciona en esta pieza).
  Y **hace `realpathSync(repo)`**, así que su slug es el FÍSICO.
- **NO** unlinkea el origen (el `.jsonl` sigue en la otra máquina), **NO** re-ancla el `gitBranch` del
  último evento ni normaliza el modo (2c), **NO** toca
  `masters.json` ni el alias por-id salvo restaurarlo desde `meta.label`. **Sin `--force` SALTA en
  silencio** si el destino ya tiene el archivo (y un detector por existencia lo lee como éxito con un
  transcript AJENO/viejo).
```bash
out="$(node "$BIN/session-import.js" --repo "$DST_POSIX" --sessions-dir "$DRIVE" --only "$ID" --force)"
echo "$out"
[ "$(printf '%s' "$out" | jq '.imported | length')" -ge 1 ] \
  || { echo "ABORTO: import no sembró nada (revisa .skipped[].reason: 'ya existe local' o el FRESHNESS GATE)"; exit 1; }
# el FRESHNESS GATE de session-import.js NO se salta a la ligera: --force-stale pisa una copia local
# MÁS FRESCA con una más vieja. Úsalo solo con decisión humana explícita.
```
**Después del import, el resto de S4 NO está hecho:** corre `REUBICAR_MODO=full` del handoff **en la
máquina destino** (detecta `YA_MOVIDO=1` y arranca tras el move: re-anclaje del último evento si hace
falta, 2c, `masters.json` con lock, alias) y
resuelve explícitamente **quién borra el `.jsonl` de la máquina de ORIGEN** — la postcondición "exactamente
1 copia" es **per-máquina** y con dos máquinas hay dos. Decisión humana, no default.

---
## 7 · Decisiones del HUMANO (acotadas — se preguntan en RUNTIME, no se asumen)
0. **`DST_REPO` — la casa destino.** No hay default: la skill NO asume `cortex` ni ningún otro. Se pregunta,
   y se verifica que sea un repo git y cuál es su visibilidad real (§1.0).
0b. **¿Se RENOMBRA el master?** (`MASTER_NAME_NUEVO`) — si la identidad cambió junto con la casa. Vacío = no
   se renombra. El renombre va en el bloque de S4, nunca después. **Restricción DURA:** el nombre final
   **debe terminar en `-master`** — el hook `exportar-sesion-master.sh` decide si una sesión es master
   leyendo el `customTitle` del transcript y **exige el sufijo**; sin él, el auto-export se APAGA. El
   preludio lo hace cumplir.
1. **`<id>` vigente** de cada máquina (duplicados en `masters.json`; cruce registro∩disco en `G-ID`).
2. **Frontera T1↔T3** — el skill propone el corte del §1; el humano confirma qué memorias son del-master
   (viajan) vs de-la-plantilla (se quedan). NO baja alcance: mueve TODO lo del master. **Comando de
   descubrimiento** (el inverso del grep de S0: lo que NO huele a plantilla, y lo que el origen tocó
   recientemente):
   ```bash
   grep -rilEv 'plantilladotnet|\.NET|blazor|dapper|EF Core|webapi|migracion-ef' "$SRC/memory"/*.md | sort
   git -C "$SRC_REPO" log --format= --name-only -- .claude/memory | sort -u | head -40
   ```
3. **Escape-hatch T3** (§1.1): ¿el master conserva acceso vivo a los skills .NET vía overlay gitignored?
   Default NO.
4. **Set de reconstitución (S0)** — qué memorias del slug global "sí iban" al origen.
5. **PR de T1 → develop** (con OK explícito + squash, sin auto-merge) o queda en la mini-develop.
6. **Copia-en-conflicto de Drive** (`masters (1).json`) si aparece: el preludio **aborta**; reconciliar antes.
7. **`~/.claude/projects/<slug-viejo>/memory/`** — ¿el master guardaba algo SUYO en el canal per-máquina
   del slug viejo? Si sí, se copia al slug nuevo **como DIRECTORIO REAL** (nunca symlink). Default: no se
   toca (lo comparten todas las sesiones de ese slug).
8. **`$DST_PROTEGIDO`** — ¿el destino tiene un subdirectorio que JAMÁS se muta (p. ej. `brain/` en cortex)?
   Default: vacío (ninguno). No se hardcodea: `axon` no tiene `brain/` y asumirlo abortaba con un
   diagnóstico falso.
+ **Las DOS citas de liveness/quiescencia** — *"la sesión `<id>` en `<máquina>` está CERRADA"* y *"cerré
  todas las sesiones de Claude en `<máquina>`"*. No las infiere el skill, y en el handoff son **gates
  reales** (`REUBICAR_LIVENESS_OK=1`, `REUBICAR_QUIESCE_OK=1`).

---

## 8 · DESHACER (rollback) — tres capas, y una de ellas CADUCA
> Esto existe porque un operador que aborta a media corrida no puede quedarse sin párrafo. El inventario
> que imprime el handoff al fallar te dice **dónde estás**; esto te dice **cómo volver**.

**Las tres capas de respaldo, en orden de preferencia:**
1. **`~/.claude/reubicar-backups/<ID>.<ts>.pre-reubicar.jsonl`** — la copia PROPIA del handoff. Sufijo
   distinto de `*.jsonl.bak` **a propósito**: `pruneBackups()` de `session-move.js` solo poda `*.jsonl.bak`,
   así que esta **no se recicla nunca**. Es la que quieres.
2. **`~/.claude/session-move-backups/<ID>.jsonl.bak`** — el de `session-move.js` (la ruta exacta la imprime
   en su JSON: **captúrala**). **CADUCA:** `pruneBackups()` conserva los **10** más recientes
   (`CLAUDE_SESSION_MOVE_BACKUPS_KEEP`, default 10). **No es una red permanente** — la doc vieja decía
   "respalda sin límite", que es falso en la dirección peligrosa. Y `…KEEP=0` es un valor válido que
   **borraría el respaldo que acaba de crear**.
3. **`$DRIVE/<ID>.jsonl.gz`** — el export de S3. Durable, y sobrevive al `cleanupPeriodDays` del CLI. Es la
   única capa que sobrevive a un borrado del store local.

**El undo, paso a paso** (con la sesión CERRADA y `G-QUIESCE` en verde):
```bash
. "$HOME/.claude/reubicar-preludio.sh"     # re-declara todo (en un shell desechable)
# 1) el transcript de vuelta al slug viejo
mkdir -p "$PROJ/$OLD_SLUG"
node "$BIN/session-move.js" "$ID" --to-cwd "$SRC_CWD" --git-branch "$(git -C "$SRC_POSIX" branch --show-current)"
#    …y si session-move.js se niega (destino colisiona / copia truncada), a mano desde el respaldo:
#    cp -f "$HOME/.claude/reubicar-backups/$ID.<ts>.pre-reubicar.jsonl" "$JSONL" && chmod 600 "$JSONL"
#    rm -f "$NEW_JSONL"
# 2) el registro (tomando el LOCK, igual que S4 — no lo edites a pelo)
mkdir "$MJ.lock" && cp -f "$DRIVE/masters.json.pre-reubicar-$ID.bak" "$MJ" && rmdir "$MJ.lock"
# 3) el alias, de vuelta al nombre viejo
node -e 'require(process.argv[1]).writeAlias(process.argv[2],process.argv[3])' "$BIN/session-lib.js" "$ID" "$MASTER_NAME"
# 4) T2: lo que S5 hubiera pisado está en ~/.claude/reubicar-backups/<ID>.<ts>.t2/ — cópialo de vuelta
#    y devuelve el bundle a su nombre:  mv "$DRIVE/$ID.brain-local.tgz.aplicado" "$DRIVE/$ID.brain-local.tgz"
# 5) el archivo de estado
rm -f "$ST"
```
**Lo que el undo NO deshace** (dilo en voz alta antes de empezar): el PR de S1 si ya se mergeó (revert por
git), y las ediciones de identidad de S6 (están en el `.t2` de respaldo).

---

## 9 · Modos de fallo → mitigación (tabla de defensa)
| Fallo | Causa | Mitigación |
|---|---|---|
| Lobotomía del master | mover cwd sin llevar T1∪T2 | `G-PARITY` mide **presencia y corrección EN EL DESTINO** (no `SRC==DST`, que falla en falso cuando el cerebro nunca vivió en el origen) |
| Lobotomía del CABLEADO | mover (a) transcript y (b) memorias y dejar (c) hooks y (d) config: el master corre sin sus candados y sin su `outputStyle` | **T4** en los tiers + `G-PARITY` verifica `settings.json`/`settings.local.json` del destino + ítem (e) del QA de S6 |
| Lobotomía parcial en Mac | `*.local.md` no viaja por git | bundle T2 por Drive; depósito gitignored en cada máquina |
| Fuga del template .NET | commitear T3/skills a repo público | T3 se queda; el chequeo es **"ningún skill del ORIGEN aparece trackeado en el destino"** — `git ls-files .claude/skills` **vacío** era un check FALSO: todo destino con skills propias (cortex tiene 4 legítimas) lo hacía disparar |
| Fuga de identidad con el gate en VERDE | `git check-ignore A B C` sale 0 si **cualquiera** matchea; `git status --porcelain` **no lista ignorados** | `G-GITIGNORE` verifica **archivo por archivo** con `-q`, y el chequeo de fuga exige el marcador `!!` por archivo |
| Fuga con el secreto YA en el índice | `ls-files --error-unmatch A B` sale ≠0 si **alguna** falta ⇒ el `if` era siempre falso | `ls-files --error-unmatch -- "$f"` **uno por uno** |
| Transcript vivo partido | `unlink` de sesión viva (`session-move.js` → `main()`, el `unlinkSync` FINAL) | `G-LIVENESS`: mtime del archivo **que se va a mover** + fail-closed si no puede medir + cita humana como gate real |
| **Se mueve la copia VIVA aunque el gate midió una FRÍA** | el gate miraba `$JSONL` (slug viejo) y el mutador usa `findSession()`, que barre TODOS los slugs y elige por CONTENIDO (ts→bytes→mtime) | `G-LIVENESS` resuelve el archivo real y **BLOQUEA si el id vive en >1 slug** (no hay tie-break aceptable para un `unlink`) |
| **Self-move con el gate en verde** | el gate comparaba contra `CLAUDE_SESSION_ID`, **que no existe** ⇒ `"<id>" = ""` siempre falso ⇒ pasaba SIEMPRE | `G-SELF-MOVE` usa `CLAUDE_CODE_SESSION_ID` (con fallback) y **falla CERRADO** si corre dentro de Claude sin poder leer su id |
| Reencarnar helios-selene | fix de target no atómico con el move | move + UPSERT **con el lock de `$MJ.lock`** + `writeAlias` en el MISMO bloque (S4), con aserción de lectura-tras-escritura |
| **"✅ Move hecho" con `masters.json` intacto** | `jq` en forma UPDATE (con id ausente devuelve el JSON intacto y **sale 0**) + `jq … > tmp && mv` (el `&&` **exime al `jq` de errexit**) + postcondiciones que **imprimían** en vez de aserir | UPSERT + `if ! jq …` + **todas** las postcondiciones son aserciones + el `✅` dice "pasos destructivos verificados", no LISTO |
| **Tail dentro del bloque "sin ventana"** | un paso posterior al move que lee y parsea el transcript puede reventar (última línea TRUNCADA, memoria) y abortar **entre** el move y `masters.json` | el re-anclaje del último evento ocurre **DENTRO del move** (`--git-branch`, misma pasada en streaming, antes del `unlink`); la reparación (`_reancla`) también va en streaming y, si falla, **avisa y sigue** hasta dejar registro y alias coherentes — nunca aborta entre el move y `masters.json` |
| **Aborto post-move por un `cwd` ANIDADO** | la postcondición era un `grep` textual y veía el `cwd` de un sub-objeto (`toolUseResult`) como un segundo valor | se mide con `jq -rR 'fromjson? \| .cwd'` (**primer nivel**, tolera la línea cortada) — la misma vista que tiene el harness |
| **Transcript TRUNCADO en el destino leído como "S4 hecho"** | un detector por EXISTENCIA (`[ -f "$NEW_JSONL" ]`) da por hecho el paso con cualquier archivo en el destino | `session-move.js` publica con **temp → verificar nº de renglones → `fsync` → `rename`** y borra el origen solo después: un corte deja únicamente el `.part`. El skill valida además por **CONTENIDO** (líneas destino ≥ origen) y respalda antes del move |
| **Transcript inmovible por tamaño** | leerlo completo a un string de JS: LANZA por encima de `MAX_STRING_LENGTH` (~512 MiB) y antes de eso pide ~6× el archivo en heap | **no hay techo:** todo el camino que toca el transcript va en STREAMING con memoria ACOTADA (`rewriteTranscriptStream`/`scanTranscriptFile`); medido, el pico lo fija la ventana de retención y **no** el tamaño (mismo pico sobre 107 MB y 428 MB). El gate de 512 MiB que hubo aquí **se retiró: bloqueaba mudanzas que la maquinaria sí puede hacer** (probado hasta 587 MB). Lo único que escala con el tamaño es el DISCO (el move sostiene origen+destino hasta el `rename`) y el skill lo informa |
| Rollback por `seed --force` | un `.gz` viejo pisando lo bueno | **ya cerrado por el `FRESHNESS GATE (#2)` de `session-import.js`** (solo `--force-stale` lo salta). S3 sigue por rollback barato, no por esto |
| **Se mueve la copia MUERTA porque su transcript trae un timestamp AJENO más "reciente"** | el desempate de `findSession` leía el `timestamp` por regex sobre el renglón CRUDO ⇒ el `timestamp` que un `toolUseResult` embebe de una respuesta de API contaba como actividad de la sesión (confirmado por ejecución: una copia de enero con un anidado de 2099 le ganaba a la copia real de hoy). Lo mismo contaminaba el **gate de frescura** de `session-import.js` | el `timestamp` se lee por CAMPO de **primer nivel** (`topLevelString`: un recorrido del renglón llevando la profundidad, sin el `JSON.parse` por línea que haría inviable barrer cientos de MB). Y `G-LIVENESS` sigue **bloqueando** si el id vive en >1 slug: no hay tie-break aceptable para un `unlink` |
| Borrar el `memory` compartido | barrido no-quirúrgico en un slug de ~130 sesiones | barrer SOLO `<id>.jsonl`; verificar que el `memory` del slug viejo sigue vivo |
| **Symlink que viola la decisión, con el verificador en verde** | `find -L … -type l` **solo ve los ROTOS** (sigue el enlace y clasifica por su destino; verificado con fixture) | `find "$DST" -type l` **sin `-L`**, y **falla**, no solo imprime |
| Symlink `memory` re-sembrado en el slug nuevo | `claude-proyecto-autocontenido` lo PRESCRIBE y el bootstrap lo crea | S5 lo retira; `_postcondiciones` (y por tanto S7) verifica que no reapareció |
| Conflicto Drive de `masters.json` | edición concurrente de UN archivo, con el hook del gemelo escribiendo **DETACHED** | preflight **aborta** ante `masters (1).json`; S4 toma el **mismo `mkdir`-lock del hook** y escribe tmp **en el mismo dir** + rename |
| Move NO atómico (a medias) | copy-a-slug-nuevo + unlink-viejo (no es un rename atómico) | respaldo propio + validación de contenido + **archivo de estado `$ST`** + máquina de estados re-entrante: la reanudación es por ESTADO, no por adivinanza de postcondiciones |
| **Mudanza revertida por el propio QA** | el resume MUTA, y el hook **por diseño** reescribe el `target` desde el cwd vivo (UPSERT: *"si está con target distinto → lo ACTUALIZA"*), además **detached** | **G-QUIESCE** por artefacto (antes y después) + **S7** re-mide con la MISMA función que S4, con **cota de 2 iteraciones** |
| Resume aterriza en el slug VIEJO aunque el `cwd` sea correcto | el par `(cwd, gitBranch)` del último evento es lo que hereda el resume, y reescribir solo `cwd` deja la rama del repo VIEJO | el move corre con **`--git-branch "$RAMA_DST"`**: fija `cwd`+`gitBranch` del último evento **con `cwd`** en su propia pasada, sin tocar las ramas históricas; `_postcondiciones` lo **asere** y `_reancla` lo repara. (Hipótesis operativa sobre un formato sin contrato publicado: el `cd` al destino sigue siendo requisito duro del QA — el slug lo deriva el cwd del PROCESO) |
| Transcript world-readable tras el move | el modo del destino no lo fija nadie ⇒ lo pone el umask (644 donde el slug está en 600) | `session-move.js` **conserva el modo del ORIGEN** (`chmod` del `.part` antes del `rename`), y como el origen mismo puede venir fuera de convención (1 de 131 en 644, verificado), S4 **2c** normaliza a `600`; aserción en `_postcondiciones`, **declarada informativa en Windows/NTFS** |
| **T2 del destino CLOBBEADO (irrecuperable)** | `tar -xzf` + `mv -f` sin diff ni respaldo, sobre identidad y **autorizaciones vigentes**, que son **gitignored** ⇒ git no los recupera | S5 extrae a `mktemp`, **diffea y PARA** pidiendo reconciliación (misma regla que S1), y respalda en `~/.claude/reubicar-backups/<ID>.<ts>.t2/` |
| **Re-correr el handoff REVIERTE S6** | S5 re-extraía el `.tgz` incondicionalmente, deshaciendo la edición de identidad ("corro desde el destino") | el bundle consumido se renombra a `.tgz.aplicado` ⇒ idempotencia real |
| `tar` sin bundle: dos comportamientos opuestos | bsdtar avisa y **sigue**; GNU tar **aborta** — el mismo comando, ningún resultado correcto | S2 declara el no-op y S5 **guarda** el `tar` con `[ -f "$TGZ" ]` |
| **El gate de quiescencia no mide nada** | `pgrep -a` en macOS = *"include process ancestors"* (auto-match ⇒ bloquea siempre) y en Git Bash `pgrep` **no existe** (`wc -l`=0 ⇒ pasa VACÍO) | detección por **artefacto** (`mtime` de los `.jsonl`), fail-closed si no puede fabricar la referencia de tiempo |
| **`G-ID` inejecutable / degradado en silencio** | `date -d` no existe en macOS (`find -printf` **sí** existe: ese era un falso positivo) y `wc -l` por candidato lee cientos de MB | helpers `_mtime`/`_fecha`/`_size` (GNU primero, BSD de respaldo) y **tamaño** en vez de líneas |
| **`$DRIVE` apuntando a la nada** | default hardcodeado de OTRA máquina + `CLAUDE_SESSIONS_DRIVE` vive en el `env` de `settings.json` ⇒ **vacía en el shell plano** que el skill prescribe | `DRIVE` es PARÁMETRO sin default; el preludio verifica valor, montaje, `masters.json` legible y copias-en-conflicto **antes** de todo |
| `BIN` no encontrado con los scripts instalados | `$HOME/code/cortex/bin` hardcodeado, mientras `seed.sh` busca en `~/.local/bin` y `~/.cortex/bin` | el preludio resuelve `$CORTEX_BIN` → `~/.local/bin` → `~/.cortex/bin` → `~/code/cortex/bin` |
| **Windows: transcript a un slug fantasma** | `/c/Users/…` (Git Bash) vs `C:\Users\…` (harness) producen slugs distintos, y MSYS puede convertir el argumento al invocar `node.exe` | el preludio separa `DST_POSIX` (para bash) de `DST_CWD` (**nativa**, con `cygpath -w`), deriva **los tres** slugs (origen, destino, `$HOME`) de la forma nativa con `slugFromCwd` de la lib, y apaga la conversión (`MSYS2_ARG_CONV_EXCL`) |
| **Windows: el preludio muere en su PRIMERA derivada** | resolver la ruta física con `node -e realpathSync` sobre un parámetro en forma POSIX (`$HOME` es `/c/Users/…`), con la conversión de MSYS ya apagada: `node.exe` es nativo y trata `/c/…` como raíz sin unidad ⇒ la resuelve contra la unidad actual (`C:\c\Users\…`, inexistente) y lanza ENOENT antes de llegar a `cygpath -w` | `_real()` resuelve con `cd`+**`pwd -P`** (bash puro, mismo idioma que el resto del guion en los tres OS) y la traducción a la forma nativa ocurre **después**, en `_cwdform`. **NO VERIFICADO en Windows real** — razonado sobre la semántica de `GetFullPathNameW` y simulado con `path.win32` |
| Rutas WSL (`/mnt/c/…`) dadas a un Node NATIVO de Windows | `normalizeCwd` solo reconocía `/c/…` y `/cygdrive/c/…` ⇒ `/mnt/c/…` caía sin traducir y `path.win32.resolve` la volvía `C:\mnt\c\…` (slug fantasma) | el regex de la rama win32 reconoce también `/mnt/<letra>/…`. En una máquina POSIX real `/mnt/c/…` es una ruta legítima y se deja intacta (la traducción vive SOLO en la rama win32) |
| Slug divergente por barra final / ruta relativa / symlink de prefijo | el slug se derivaba con un `sed` paralelo sobre la cadena CRUDA | **un solo derivado**: `_slug()` llama a `slugFromCwd()` de la lib sobre la ruta **realpath**-eada |
| Handoff roto por CRLF | vive en el Drive, que sincroniza con Windows; un `\r` invisible rompe la línea 1 | el generador fuerza LF (`tr -d '\r'`) y §6.1 da el comando de normalización |
| **Handoff que certifica lo que no verificó** | sus "postcondiciones" imprimían; el único gate era `bash -n`, que mide sintaxis | **gate de PARIDAD por marcadores** + todas las postcondiciones son aserciones + `REUBICAR_MODO=dry` |
| **El cuerpo y el handoff derivan por separado** | eran dos superficies mantenidas a mano; los parches entraban en una y media | los pasos destructivos viven **SOLO** en §6.1, el preludio es **UN archivo** que los dos consumen, y el gate de marcadores lo vigila |
| Cross-máquina: "sembré" sin sembrar | `session-import.js` lee `<repo>/.claude/sessions/` por default y el `.gz` está en el Drive ⇒ `{"ok":true,"imported":[]}` con exit 0 | §6.3: `--sessions-dir "$DRIVE" --only "$ID" --force` + aserción `.imported \| length >= 1` |
| Renombre que revive con el nombre viejo | el hook re-deriva la identidad del `customTitle`; `session-import.js` restaura el alias desde `meta.label` | S3 exporta con `$NOMBRE_FINAL`; el preludio exige el sufijo `-master`; S4 paso 5 lista las otras entradas con el nombre viejo y recuerda renombrar el `customTitle` |
| Alias perdidos en silencio | degradar un `sesiones-alias.json` ilegible a `{}` en el camino de ESCRITURA: la siguiente escritura deja **una sola** entrada y borra los demás | `writeAlias` escribe **tmp+rename** y un JSON ilegible lo **respalda y avisa** en vez de degradarlo; el verificador con `sessionAliases()` en `_postcondiciones` se queda. **Sigue sin cubrirse** el escritor CONCURRENTE (dos `writeAlias` a la vez: last-writer-wins) — lo hace improbable `G-QUIESCE` |
| Nombre de archivo con espacio parte el flujo | listas por word-splitting (`for m in $MEMORIAS_T1`) | **arrays** (`${ARR[@]+"${ARR[@]}"}`) y `while IFS= read -r` para las listas de archivos |
| Glob expandido en el cwd EQUIVOCADO | `.claude/memory/*.local.md` lo expande el shell del operador, no git en el destino (y en zsh sin match **aborta**) | rutas construidas desde el array y pasadas a git con `--` una por una |
| El árbol de trabajo del humano movido de rama | S1 hacía `git checkout develop` en el destino y ramificaba de `develop` | S1 exige árbol limpio y **ramifica de la rama VIVA del destino** |
| Master que desaparece antes del QA | `cleanupPeriodDays` (default 30) reapa transcripts viejos | §1.0.2 lo nombra; el `.gz` del Drive es la copia durable |
| Consumidores de la RUTA vieja del transcript | mecanismos *path-addressed* (`axon resume --from <ruta>`) mueren con la mudanza | S6 barre `grep -rn "$OLD_SLUG"` en `~/code` y `~/.claude` y la doc prefiere la forma id→ruta |
| Destino asumido (`cortex` por default) | el destino venía hardcodeado | `DST_REPO` es Decisión #0 sin default; se aborta si viene vacío o no es repo git |
| "Es privado, me llevo T3" | leer el candado NO-FUGA como si la fuga fuera el único motivo | §1.0: el motivo dominante es el **duplicado divergente**, que no depende de la visibilidad |
| Mueve la sesión EQUIVOCADA | elegir el `<id>` desde `masters.json` sin cruzarlo con los `.jsonl` reales | `G-ID` cruza registro ∩ disco por frescura y avisa si el id vivo no está registrado; S4 hace **UPSERT** |
| Handoff inservible | el guion a disco era un stub con "(ver SKILL §4)" | §6.1 exige script completo + `bash -n` + paridad de marcadores como postcondición |

### 9.1 · Dónde este sistema RESISTE (no lo re-audites, no lo "arregles")
- **La costura con `axon resume` converge.** Su parser tolera todo lo que el move produce: última línea sin
  `\n`, líneas no parseables (las omite con warning), el último evento mutado (**no lee `cwd` ni
  `gitBranch`**), y la re-serialización JSON (empareja `tool_use`↔`tool_result` por id, no por posición).
  Y **no escribe** en `~/.claude/projects/` ni en `masters.json` ⇒ no hay carrera. La única asimetría es de
  DIRECCIONAMIENTO (es *path-addressed*), y la cubre el barrido de S6.
  **Aviso vigente:** su roadmap se compromete a un modo **in-place** ("read-only es el primer peldaño, no
  el destino"). Cuando eso aterrice, un `axon resume` in-place sobre un transcript a media mudanza **sí**
  hará daño. Hasta entonces: **nunca corras `axon resume` sobre un `<id>` a media mudanza** (si existe
  `$DRIVE/reubicar-<ID>.state`, está a media mudanza).
- **El manejo de rutas con ESPACIOS** está resuelto: todas las expansiones de `$DRIVE`, `$MJ`, `$JSONL`,
  `$NEW_JSONL`, `$SRC`, `$DST` están comilladas, y una ruta de Drive **con espacios** (el folder por
  defecto de Google Drive los lleva en varios idiomas) no las rompe.
  El problema de esa zona era el **valor por default**, no el quoting.
- **El patrón `[ cond ] && { echo …; exit 1; }` NO es un bug** bajo `set -euo pipefail`: bash exime al
  operando izquierdo de un `&&`. No lo "arregles". Lo que **sí** es real es su reverso —
  `cmd > tmp && mv tmp dst` deja `cmd` exento de errexit — y de ahí salió el arreglo de S4 paso 3.
- **`find -printf` funciona en macOS 26** (verificado). Los GNU-ismos reales son `stat -c` y `date -d`, y
  para eso están `_mtime`/`_fecha`. No lo listes como problema.
- **Los TODOs no se pierden** con el cambio de slug: viven en `~/.claude/tasks/<session-id>/`, indexados
  por session-id, que es estable a través del move. El artefacto que sí queda huérfano es
  `~/.claude/projects/<slug>/memory/` (§1.0.2, Decisión #7).
- **El tie-break de `findSession()`** desempata por CONTENIDO —`timestamp` de **primer nivel** más
  reciente de la cola → bytes → mtime → slug— y ya no se lo puede engañar con un timestamp anidado de un
  `toolUseResult`. No lo "arregles" volviendo al mtime: un respaldo viejo restaurado trae mtime de HOY y
  por mtime ganaría siendo la copia muerta. Lo que el tie-break **no** sustituye es el gate: `G-LIVENESS`
  bloquea si el id vive en >1 slug, porque para un `unlink` ningún tie-break es aceptable.
- **El diseño de tiers y la resolución "el destino privado NO autoriza llevarse T3"** son sólidos. Su
  defecto era de completitud (faltaba T4), no de criterio.
- **El ORDEN export-first → move → fix-de-referencias** sigue siendo el correcto, aunque su justificación
  vieja estuviera stale: el `.gz` fresco antes de un `unlink` irreversible es rollback barato.

---

## 10 · Pendientes DELEGADOS a `bin/` y al brain (fuera del alcance de este skill)
Este skill **no puede** arreglar el código de `bin/`; lo que hace es ser correcto respecto al
comportamiento ACTUAL y gatear lo que ese comportamiento no cubre. **Regla de mantenimiento de esta
lista:** cuando `bin/` cierre un ítem, el ítem baja a "Ya NO son pendientes" **en la misma tanda** en que
se toca `bin/` — una lista que pide lo que el código ya hace no es un backlog, es doc que miente, y ya
produjo un gate que bloqueaba una mudanza posible (el techo de 512 MiB, retirado).

**ABIERTOS de verdad (3):**
- **`session-move.js`: `--from-slug`.** Para que el llamador FIJE el archivo objetivo en vez de dejarlo al
  tie-break de `findSession()`. Mitigado por partida doble: `G-LIVENESS` **bloquea** si el id vive en >1
  slug, y el tie-break ya desempata por contenido de primer nivel. Sigue siendo la solución de raíz.
- **`session-move.js`: la poda no debe poder borrar el respaldo recién creado** (`CLAUDE_SESSION_MOVE_BACKUPS_KEEP=0`
  es un valor válido y `pruneBackups()` correría **después** de crear el `.bak` de esta corrida), y
  convendría que respetara un sufijo propio. Mitigado: el skill hace su copia con otro sufijo
  (`*.pre-reubicar.jsonl`), que la poda no mira.
- **Extraer la escritura de `masters.json` a un `bin/masters-set.js`** que hook y skill llamen. Hoy el
  idioma vive en el hook (con lock), en este skill (también con lock) y en `test-brain.sh` — tres copias
  de la misma escritura, y la tercera es la que puede driftar sin que nada falle.

**Ya NO son pendientes** (el código ya lo hace — verificado leyendo la fuente y por ejecución):
- **Escritura ATÓMICA del move:** `session-move.js` escribe `<id>.jsonl.part.<pid>` en el dir destino,
  verifica el nº de renglones contra el origen, `fsync`, `chmod` al modo del ORIGEN y `renameSync`; el
  origen se borra al final. Un corte deja solo el `.part`.
- **STREAMING sin techo de tamaño:** `rewriteTranscriptStream`/`scanTranscriptFile` no sostienen el
  archivo completo, y `move`/`export`/`import` van todos por ahí. Medido: el pico lo fija la ventana de
  retención, **no** el tamaño (mismo pico sobre 107 MB y 428 MB). Por eso el gate de 512 MiB del skill
  **se retiró**: bloqueaba mudanzas que la maquinaria sí hace.
- **`--git-branch` en el move:** fija el `gitBranch` del último evento con `cwd` en la MISMA pasada, antes
  del `unlink`. Es lo que permitió **borrar** el paso post-move que releía el transcript completo.
- **Slug desde la ruta NORMALIZADA:** `normalizeCwd()` resuelve absoluta/física/sin barra final (y en
  Windows traduce `/c/…`, `/cygdrive/c/…` y `/mnt/c/…` a la nativa) y todo pasa por `slugForRepo`.
- **`writeAlias`:** tmp+rename, y un JSON ilegible se **respalda y avisa** en vez de degradarse a `{}`.
  (Lo que sigue sin cubrir es el escritor CONCURRENTE — anotado en §9, no es un pendiente de esta lista.)
- **Desempate de `findSession()` por CONTENIDO** y por el `timestamp` de **primer nivel** (no por regex
  sobre el texto crudo, que dejaba ganar a la copia muerta con un `timestamp` anidado de un `toolUseResult`).
- **Test de PARIDAD del handoff en `test-brain.sh`:** existe. Extrae el generador de §6.1 y la lista de
  marcadores del propio candado, y **falla** si un marcador ya no aparece en una línea ejecutable del
  generador o si el skill vuelve a describir `bin/` con las afirmaciones que `bin/` ya no cumple.
- El *freshness-check* de `seed.sh --force` (`FRESHNESS GATE (#2)` en `session-import.js`, con
  `--force-stale` como escape documentado); que el auto-registro **ACTUALICE `target`** y reconozca un
  **renombre** (el hook hace UPSERT de `target` **y** `name`); el **lock/escritura atómica** de
  `masters.json` (el hook trae el `mkdir`-lock con reciclaje a los 5 min + tmp&rename — lo que faltaba era
  que **S4 lo tomara**, y lo toma); y la **poda** de `~/.claude/session-move-backups/` (`pruneBackups()`).
