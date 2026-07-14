# Plan de refactor — Desacoplar LÓGICA de MECANISMO (hooks ↔ libs ↔ skills)

> Estado: **borrador a revisión** (2026-07-14). Origen: idea de unjordi ("¿y si abstraemos la lógica de
> los hooks a skills, que los hooks las invoquen pero también estén disponibles?") + hallazgos del auditor
> de flowcharts (#1 dod débil en plantilla, #2 falso positivo de comillas, #3 copias por-repo desfasadas,
> #4 secret-scan ausente sin bootstrap). Este plan ataca los cuatro de raíz con una sola reorganización.

## 1. El principio que manda: la asimetría hook ≠ skill
> **Explicación canónica en el README** (raíz: sección "La jerarquía"; brain: "Hooks vs skills — por qué
> unos bloquean y otros no"). No se duplica aquí para que no se desincronice.

Resumen para este plan: el *enforcement* (deny/block) SOLO puede ser hook (corre fuera del turno del
modelo); la *lógica/cómputo* se abstrae a libs `.sh`; los *nudge/inyección* pueden tener un gemelo skill
manual. **Todo el refactor se apoya en esa asimetría.**

## 2. Arquitectura en 3 capas
```
  Capa LÓGICA  →  lib/*.sh   (funciones puras, sin decidir I/O; testeables solas)
  Capa MECANISMO → hooks/*.sh (wrapper delgado: lee stdin → llama lib → emite decisión/inyección)
  Capa MANUAL   →  skills/    (gemelo de los nudge; dry-run opcional de los enforcement)
```
`delegacion-comun.sh` YA es exactamente este patrón (lib compartida por delegacion-gate y -registrar).
El refactor lo generaliza al resto.

### 2.1 Capa LÓGICA — libs (funciones puras). Nombre = verbo+objeto, obvio para cualquier humano.
- **`lib/analizar-comando-git.sh`**: dado un comando git, responde preguntas. `despoja_comillas(cmd)`
  (⇒ arregla #2 para TODOS los git-hooks de un tiro), `es_push_a_base(cmd)`, `es_merge_mr(cmd)`,
  `destino_de_mr(cmd)` (glab/gh), `merge_base_con_integracion()`.
- **`lib/detectar-secretos.sh`**: `patrones()`, `escanear(diff)` → coincidencias redactadas.
- **`lib/definicion-de-listo.sh`** (la "DoD"): `es_estatus_o_pregunta(msg)`, `hay_claim_de_cierre(msg)`
  (con el CLAIM_RE rico), `afirma_qa_visual_a_ciegas(turn)`, `toco_codigo(turn)` (incl. edición por Bash).
  ⇒ una sola definición ⇒ la plantilla deja de tener una `dod` DÉBIL distinta (arregla #1).
- **`lib/medir-contexto.sh`**: `lineas_transcript(path)`, `baseline_leer/escribir`, `banda(delta)`.
- **`lib/leer-hilo-mental.sh`**: `leer_hilo(root)`, `frescura(hilo, rama)` (mtime + rama). La usan el hook
  rehidratar-hilo Y su skill gemelo (misma frescura en ambos).

> Convención: **`<verbo>-<objeto>.sh`**, en español, que se entienda sin conocer el proyecto. Nombres
> abiertos a tu ajuste — si alguno aún suena a jerga, lo cambiamos.

### 2.2 Capa MECANISMO — hooks = wrappers delgados
Cada hook queda en ~10-15 líneas: dedupe-clause + `source lib` + leer JSON stdin + llamar la fn + emitir
`permissionDecision`/`additionalContext`. La FUERZA (deny/block) se queda aquí. Cero lógica de negocio
duplicada.

### 2.3 Capa MANUAL — skills (dos ideas distintas)

**(i) Gemelo de un hook de NUDGE.** Un hook "nudge" es de los que NO bloquean: solo INYECTAN algo
(rehidratar-hilo reinyecta el hilo; sesion-inicio inyecta rama+norma+memoria; recordar-dashboard recuerda).
Como no bloquean, un **skill puede hacer exactamente lo mismo** → son *gemelos*: la misma tarea con dos
formas de dispararse. El **hook** lo hace SOLO (en su evento); el **skill** lo haces TÚ a mano.
- ¿Para qué el gemelo manual si el hook ya lo hace solo? → Por RESILIENCIA: si un update del CLI rompe el
  evento del hook, o la sesión arrancó sin él, invocas el skill y funciona igual.
- Ejemplo real, ya hecho: **`rehidratar-hilo`** es hook (auto, en SessionStart) **y** skill (lo tecleas si
  el hook no disparó). Candidatos a tener gemelo: `sesion-inicio`, `recordar-dashboard`.

**(ii) Dry-run de un hook de ENFORCEMENT (OPCIONAL — bonus, se puede recortar).** Un hook de enforcement
(secret-scan, dod, git-branch-guard) BLOQUEA en el momento de la acción — no puede ser skill (un skill no
bloquea). Pero su LÓGICA (ya en una lib) se puede exponer como un skill que **solo CHEQUEA y REPORTA, sin
bloquear nada**, para correrlo **cuando TÚ quieras, ANTES** de intentar la acción.
- *Cuándo ocurre:* lo invocas proactivamente. Ejemplo: antes de un commit grande tecleas `revisar-secretos`
  → corre el MISMO escaneo que secret-scan y te dice *"hay una llave AWS en config.txt"* (o "limpio") —
  pero no bloquea nada (todavía no commiteas). El hook sigue siendo el que muerde en el commit real; el
  dry-run es una *vista previa* voluntaria.
- Es un extra de comodidad, no de seguridad. **Si sigue sin convencerte, lo sacamos del alcance** — el
  valor central (resiliencia + anti-drift) NO depende de los dry-runs.

## 3. Anti-drift (mata el hallazgo #3) — la pieza con mecanismo propio
Abstraer a libs NO basta: la lib igual viaja en el `.claude/` del repo (para clones sin bootstrap) y puede
envejecer. El mecanismo que lo cierra:
- **`sincronizar-cerebro.sh <repo>`**: copia hooks+libs+skills del brain → `.claude/` del repo destino
  (fuente ÚNICA = el brain). Los archivos del repo se GENERAN, no se editan a mano.
- **Check de drift en `test-brain.sh` / CI**: por cada archivo del cerebro presente en un repo, aseverar
  que es idéntico (o marca-versión ≥) al del brain; si difiere → FAIL. Así el desfase se detecta, no se
  descubre en una auditoría meses después.
- Decisión asociada (**#4**): cablear `secret-scan` (y demás global-only relevantes) TAMBIÉN por-repo, para
  que un clon sin bootstrap no pierda un guard de seguridad — o documentar explícitamente que dependen del bootstrap.

## 3.1 Ciclo de INSTALACIÓN/ACTUALIZACIÓN — flowchart ⓪ ✅; el HUECO de MECANISMO sigue
El flowchart de instalación/actualización **ya existe como ⓪** del mapa (añadido en PASO 1: el mapa pasó a
⓪–⑧). Documenta el ciclo real; el HUECO que queda es de MECANISMO (no hay update por-repo). Estado hoy:

| Pregunta | Hoy | ¿Definido? |
|---|---|---|
| **1ª instalación GLOBAL (máquina)** | `install.sh`/`install-brain.sh`: copia hooks+skills+normas a `~/.claude/`, cablea `settings.json`. Idempotente. | ✅ |
| **1ª instalación POR-REPO** | Los hooks del repo VIAJAN en su `.claude/` (por git, al clonar). `bootstrap-claude.sh` (1× tras clonar) enlaza el cerebro + instala en `~/.claude` un **SUBCONJUNTO** de globales que el repo trae. | ⚠️ parcial |
| **¿Cuándo se copia el tooling a un repo?** | Al crear un repo desde la plantilla (clon trae `.claude/`) o al aplicar `aplicar-plantilla-a-proyecto` a uno existente. Acto PUNTUAL. | ✅ |
| **Actualización GLOBAL** | Re-correr `install-brain.sh` (idempotente + reemplaza el bloque de normas). Manual. | ✅ |
| **Actualización POR-REPO** | **NADA.** Los `.claude/hooks/` del repo se pusieron una vez y nadie los re-sincroniza desde el brain → **driftean** (= hallazgo #3). | ❌ **EL HUECO** |

**Divergencia extra descubierta (raíz de #4):** `bootstrap-claude.sh` (plantilla) instala globalmente solo
`git-branch-guard`, `recordar-dashboard`, `merge-squash-guard`; **NO** `secret-scan`, `delegacion-*`,
`aviso-contexto`, `rehidratar-hilo` (esos solo los instala `install-brain.sh`, que vive en claude-brain).
⇒ quien clona la plantilla y corre SU bootstrap **no obtiene secret-scan** (seguridad) ni el watermark.
Hay **dos rutas de instalación que instalan conjuntos distintos** — nadie las reconcilió.

**Defectos del ciclo CONFIRMADOS por el auditor del flujo de instalación (⑧ entonces, hoy ⓪) (contra los scripts reales):**
- 🔴 **Drift INVERSO** (el peor): `bootstrap-claude.sh` hace `cp -f` INCONDICIONAL → un clon con plantilla
  VIEJA **PISA** los 3 hooks globales con versiones stale. La dedup R1 es del CABLEADO (quién corre), no
  del `.sh` (el binario siempre se sobreescribe) → un repo viejo CONTAMINA el global.
- 🟠 `bootstrap-claude.sh` verifica **jq pero NO git** — el `.dot` y el `CLAUDE.md` dicen "ambos" (doc miente).
- 🟠 `aplicar-plantilla-a-proyecto` **NO copia `.claude/`** (es un playbook de UI/arquitectura); sembrar el
  cerebro en un repo existente es un paso MANUAL no scriptado → hueco de automatización.
- 🟡 `install.sh` es **Linux/KDE-only** (systemctl/kpackagetool6) y corre el brain ANTES de checar prereqs
  (en Mac instalaría y luego moriría). La vía global real en Mac/Windows es `install-brain.sh` directo.
- 🟡 el cerebro **no tiene sello de versión** (el widget sí, `version.json`) → el drift es indetectable hoy.
- 🟡 los dos instaladores siembran el dashboard con convención de bitácora **contradictoria** (install-brain
  "más reciente ABAJO, `>>`"; bootstrap "más reciente arriba") — la norma le da la razón a install-brain.

**Propuesta:**
- **[✅ PASO 1]** El **flowchart ⓪ "Instalación / actualización del cerebro"** ya está en el mapa (primera instalación global
  vs por-repo · actualización global vs por-repo · qué se copia y cuándo). Hace visible el ciclo y su hueco.
- **Reconciliar las dos rutas:** una fuente/lista ÚNICA de qué es global (que `install-brain` y el
  `bootstrap-claude` de cada repo compartan), para que "qué guards tienes" no dependa de por dónde entraste.
- El comando **`sincronizar-cerebro.sh` + check de drift** (§3) es el que llena la casilla ❌ (update por-repo).

## 4. Fases (cada una = un slice, ramita→MR→develop, test verde entre fases)
0. **Alcance** — cerrar esta lista (qué hooks, qué libs, qué gemelos, qué dry-runs). ← decisión de unjordi.
1. **`lib/git-analiza.sh`** + adelgazar los 3 git-hooks a wrappers. *Incluye el fix #2 (despoja_comillas).*
2. **`lib/dod.sh`** + unificar la `dod` genérica y la .NET en un wrapper c/u sobre la MISMA lib. *Cierra #1.*
3. **`lib/secretos.sh`**, **`lib/contexto.sh`**, **`lib/hilo.sh`** + sus wrappers.
4. **Gemelos-skill** faltantes (sesion-inicio; recordar-dashboard opc.) + **dry-run** opcionales.
5. **Ciclo de instalación/actualización** (§3.1): flowchart de instalación (⓪) al mapa **[✅ hecho]** + reconciliar las dos rutas de
   install (lista única de "qué es global") + `sincronizar-cerebro.sh` + check de drift en test-brain/CI.
   *Cierra #3 y #4 y llena el hueco del ciclo de vida del cerebro.*

## 5. Riesgos / caveats (no negociables)
- **Refactor de comportamiento CONSTANTE**: la suite `test-brain.sh` (hoy 115/0) es el contrato — debe
  quedar verde en cada fase; si un test cambia de expectativa, es señal de que NO fue puro refactor.
- **Guard-integrity (P0)**: es reorganización, NO afloja candados. Los dientes (deny/block) se quedan en
  hooks. Cambiar un candado sigue exigiendo OK explícito de unjordi para ESE candado.
- **Resolución de path de la lib**: el wrapper debe encontrar su lib tanto en global (`~/.claude/hooks/`)
  como por-repo (`.claude/hooks/`) — `source "$(dirname "$0")/lib/..."` robusto y con fail-open si falta.
- **Bash puro** (sin python/node en hooks).
- La escalera de resiliencia resultante: `hook` (auto+enforce) → `skill` (manual, sin enforce) → `lib`
  invocable como comando → `prompt` a mano (no depende de ninguna feature del CLI).

## 6. Qué NO cambia
Los flujos ⓪–⑧ del mapa (la lógica de decisión) son los MISMOS; solo cambia DÓNDE vive el código y qué
tiene gemelo manual. El mapa se re-anota (badge "⚙ lib" donde aplique), no se rehace.

## 7. Hallazgos de la AUDITORÍA de flowcharts (2026-07-14) → checklist atómico
> El Auditor de Calidad (procesos industriales + análisis de algoritmos) revisó los 9 flujos individual y
> colectivamente, cotejando el mapa contra `brain/hooks/*.sh` **Y** la copia desplegada en la plantilla .NET.
> Reporte completo: [`docs/auditoria-flowcharts.md`](auditoria-flowcharts.md). **Verificado H1/H3/H5/H6/H7
> contra el código real (son reales).** Veredicto: el mapa es coherente como MODELO (no rehacer flujos),
> pero la etiqueta "fiel a la lógica real" no se sostiene sin resolver el drift, y 3 candados se vuelven
> fail-open bajo condiciones plausibles.
>
> **Regla de proceso (dura):** los fixes de **LÓGICA** de abajo son **CAMBIOS DE COMPORTAMIENTO** (nuevos
> deny/disparos), NO "refactor puro con `test-brain` constante". Cada uno **nace con su test nuevo** (la
> suite CRECE). En cada MR, separar explícitamente "reorg pura" de "fix de comportamiento".

### A · ANTI-DRIFT primero (sostiene la premisa «fuente única») — H2, H7-cableado
- [ ] Reconciliar `brain/hooks/` ↔ copia desplegada en la plantilla .NET (hoy driftea en AMBOS sentidos:
      el widget tiene el `dod` fuerte con bloqueo QA-visual; la plantilla tiene el fix de comillas de
      `git-branch-guard` — y ese fix vive en la ramita `fix/git-branch-guard-comillas`, aún NO en esta rama).
- [ ] **Sello de versión** del cerebro (hoy no existe; el widget sí lo tiene).
- [ ] `sincronizar-cerebro.sh` (fuente única = brain; NO `cp -f` ciego) + **check de drift BIDIRECCIONAL** en test-brain/CI.
- [ ] Reconciliar las 2 rutas de install en una lista ÚNICA de «qué es global» → un clon de la plantilla SÍ obtiene secret-scan (hoy no).

### B · lib `analizar-comando-git.sh` (Fase 1) — H1, H3, H5, H11, H13
- [ ] `despoja_comillas(cmd)` para TODOS los git-hooks (fix #2; H13: hoy secret-scan y branch-guard-widget no despojan).
- [ ] `es_push_a_base(cmd)` que resuelva la **rama actual + upstream** cuando el push es PELÓN (sin refspec)
      → cierra **H1** (`git push` a secas en develop/main hoy NO se bloquea).
- [ ] Anclar los escapes al **subcomando real** (`glab mr list|view`), no a cualquier token suelto (`status`)
      → cierra **H3** (evasión de `confirmar-merge-develop` con `… && git status`).
- [ ] `destino_de_mr(cmd)` con **caché por MR-id COMPARTIDA** entre squash-guard y confirmar → 1 sola llamada
      de red (**H5**) + degradar a **deny conservador** si la resolución hace timeout (hoy el timeout evade el hook).
- [ ] Guarda contra falso positivo de repo-path que termina en `/develop`|`/main` (**H11**).

### C · lib `definicion-de-listo.sh` (Fase 2) — H4, #1
- [ ] STATUS_RE **claim-aware**: subordinar el escape de estatus a que NO haya claim de cierre co-ubicado →
      cierra **H4** («Listo, quedó terminado. Dime si reviso algo más.» hoy NO dispara).
- [ ] Unificar la `dod` DÉBIL de la plantilla con la fuerte (bloqueo QA-visual-a-ciegas) sobre la MISMA lib (#1, confirmado por H2).

### D · lib `detectar-secretos.sh` (Fase 3) — H7
- [ ] Ampliar patrones: connection strings (`://user:pass@`, `Password=`), JWT, blobs base64 — hoy solo prefijos.
- [ ] Decidir **fail-open vs fail-closed** para un guard de SEGURIDAD (hoy fail-open sin jq/git/rango).
- [ ] Cablear `secret-scan` **también por-repo** (o documentar su dependencia del bootstrap) → **H7 = #4 como
      P0 de seguridad**: un clon fresco de la plantilla NO tiene ningún escaneo de secretos.

### E · Pasada de MAPA (anotar, NO rehacer) — H8, H9, H10, colisiones
- [ ] Mostrar que **②③④ son el MISMO evento** PreToolUse/Bash con N hooks en PARALELO (no secuencial);
      añadir la **matriz disparador×hooks** del reporte.
- [ ] Añadir en ② la rama **`MERGE_RE`** de git-branch-guard (hoy solo pinta «push directo»).
- [ ] Alinear norma N_GIT/CLAUDE.md: release a main **por CLI con OK súper-explícito** (no «JAMÁS por CLI»)
      — o cerrar esa vía; hoy mapa+código se contradicen con la norma (**H8**).
- [ ] Bajar **P0** de «activa/protege» a «norma SIN mecanismo local — enforcement externo (auto-mode)», o
      darle mecanismo (guard que avise al editar `brain/hooks/*.sh`) (**H9**).
- [ ] Reflejar `precompact-volcar-estado` como no-op inerte (o descablearlo + quitar su `statusMessage` que miente) (**H10**).

### F · Backlog (fuera del refactor inmediato) — H6, H12
- [ ] **H6** `delegacion-gate`: liberar el lock de coalescencia al NEGAR (hoy un «no» + reintento <60s permite
      en silencio). *Alcance: solo gratis/incluido (costo cero) → wart de semántica, no de gasto; metered no se coalesce.*
- [ ] **H12** doc=realidad dentro del hook: `delegacion-gate.sh:6` dice «def 95%», el real es **90**.

### G · Numeración (unificar Fases ↔ PASOS)
- [ ] PASO 1 = flowchart ⓪ **[✅]** · PASO 2 = Fases 1–3 (libs B/C/D) · **Fase 4** (gemelos-skill + dry-run
      opcional) y el **mecanismo** de Fase 5 (anti-drift §A) quedan explícitos · PASO 3 = TIER 1/2 (G-fixes) en MR propio.

### Secuencia sugerida por el auditor (a revisar con unjordi)
**§A (anti-drift) PRIMERO** — hoy el mapa describe una amalgama que no corresponde ni a `brain/` ni a la
plantilla; sin sello+drift-check, todo lo demás se construye sobre arena. Luego B/C/D (libs con sus fixes),
luego E (mapa), F al backlog. **Alternativa:** hacer los fixes de LÓGICA de mayor severidad (H1/H3) ya
mismo como hotfix, y el anti-drift como fase. ← decisión de unjordi.
