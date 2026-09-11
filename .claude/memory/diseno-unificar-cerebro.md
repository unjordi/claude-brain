---
name: diseno-unificar-cerebro
description: PROPUESTA (preview) del mecanismo para unificar memorias+cerebro de varios devs a develop sin perder atribución/feeling ni romper guardrails.
metadata:
  type: project
---

# Mecanismo: unificar el cerebro (memorias + skills + hooks) mini→develop

> **Estado: PROPUESTA en preview, a revisión de unjordi. NO construida.** Síntesis de 3 diseños Opus
> (lentes atribución+feeling · conflict-safety/git · plantilla+proceso) + 3 auditorías de datos, todo
> verificado read-only sobre el repo el 2026-07-21. Decisiones abiertas al final.

## El problema (DOBLE)
Los 3 devs (unjordi, Carlos "AliazCIA", Chunito) trabajan cada uno en su mini-develop y acumulan en
`.claude/` dos materiales distintos a unificar hacia `develop`: **(A) memorias** (prosa de
aprendizajes) y **(B) cerebro** (skills + hooks/guardrails). Hay que juntarlos (1) sin perder QUIÉN
aportó cada uno, (2) sin aplanar el FEELING/voz, (3) sin romper los guardrails delicados, y (4) de forma
INTEGRABLE en la plantilla para que un MR futuro a develop no rompa nada.

## Verdad de campo (verificada, no hipótesis)
- **Atribución git = rota.** `develop` hoy: 171 commits de Jordi Serra + 28 unjordi + **0 Carlos + 0 Chunito**.
  El flujo squashea 2 veces (ramita→mini, mini→develop) → el autor colapsa al INTEGRADOR. Y como el repo
  es **plantilla CLONABLE**, al instanciar el git-history NO viaja → atribución git = **CERO** en cada clon.
  Una misma persona tiene hasta 3 firmas git (unjordi/Jordi Serra, 2 emails). → **git-author NO basta.**
- **Merge casi limpio.** Cada mini→develop individual: LIMPIO. El único choque de MEMORIA en todo el
  cruce es **`MEMORY.md` (Unjordi↔Chunito)** — los dos insertan en el índice. `bitacora.md` blindada por
  `merge=union`. Aliaz↔Chunito: limpio. Los demás conflictos son de CÓDIGO de app (NavMenu, Program.cs,
  app.css, MiCuentaDialog, UsuarioTests), no del cerebro.
- **"Chunito tocó 3 hooks" = FALSO POSITIVO.** Solo `chmod -x` (contenido byte-idéntico; su Git Bash de
  Windows perdió el exec bit). No tocó lógica. Riesgo funcional casi nulo (settings.json los lanza vía
  `bash`; las libs se hacen `source`). Pero es **drift** que ensucia diffs → hay que rutearlo/limpiarlo.
- **Unjordi borró skills** `cerrar-slice`+`checkpoint` (a propósito: son globales del brain). Si eso sube
  crudo a develop = regresión/revive-delete. → cerebro canónico NO se file-mergea.
- **Solapes reales de aprendizaje** (candidatos a trenzar, NO fundir): (a) "la pantalla es la verdad"
  (Unjordi `auditor-es-piso` × Chunito `no-pushear-sin-verificar`+`flexibilidad-visual-css`); (b) autonomía
  dev/QA en TENSIÓN (Unjordi `dev-qa-continuar-sin-frenar` "arregla de corrido" × Chunito
  `no-pushear-sin-confirmar" "no pushees sin mi OK"); (c) choque de CONVENCIÓN (Aliaz usa un
  `aprendizajes-claude-brain.md` append-only único vs Unjordi/Chunito usan notas atómicas `type:feedback`).

## ACTUALIZACIÓN (unjordi, 2026-07-21): pivote a LOG COMPARTIDO append-only (NO atómicas)
unjordi prefiere el mecanismo de `aprendizajes-claude-brain.md` (de Aliaz) DENTRO de la plantilla: cada
dev **appendea** a un log compartido → integrar y conciliar es más fácil. Es mejor que las notas atómicas
porque **borra la maquinaria del índice**: las atómicas exigían mantener `MEMORY.md` (el ÚNICO archivo de
memoria que choca en el merge) con `merge=ours`+regen; un log append-only + `merge=union` integra trivial
como `bitacora.md` (cero conflicto, cero ritual) y coloca todos los aprendizajes en un lugar → conciliar
solapes después es más simple. Esto **REEMPLAZA los principios 2 y 3 de abajo**:
- **Aprendizajes (feedback/lecciones) → APPEND a log(s) compartido(s)** `.claude/memory/aprendizajes.md`
  (partir por dominio si crece: `aprendizajes-ui.md`/`-infra.md`/`-flujo.md`), con `merge=union`. Cada
  entrada = bloque `## <fecha> · aportó: <dev> · <tema>` + prosa. La atribución y la VOZ viven en el bloque
  → sobreviven squash y clon (igual que bitácora). Integración = union, conflict-free, sin ritual.
- **Conciliar = pasada de CURACIÓN posterior** (en `unificar-cerebro` o periódica) sobre el log colocado:
  trenzar solapes acreditando a ambos, anotar tensiones (§5 sigue aplicando pero AHORA es sobre el log, no
  entre archivos), y **GRADUAR** lo maduro a su propio hogar (archivo/skill/contrato) cuando lo amerite. El
  log es el **inbox**; lo estable se promueve.
- **Archivo propio SOLO para artefactos GRANDES autocontenidos** (un módulo, una decisión con ciclo propio;
  p. ej. `modulo-notificaciones.md`, `estado-proyecto.md`). Pocos y rara vez multi-dev → poco conflicto.
- **`MEMORY.md`** entonces solo lista los DOCS grandes + los logs → cambia rara vez → deja de ser archivo-imán
  (ya no hace falta el regen agresivo; el log se auto-indexa por sus headers).
- **Trade-off aceptado:** el log es un blob (menos recall dirigido / no `[[..]]`-direccionable por entrada).
  Mitigación: partir por dominio + graduar lo maduro.
- **DECISIÓN #6 RESUELTA (unjordi 2026-07-21):** **UN solo `aprendizajes.md` como inbox** (no por-dominio
  al escribir). Razón: los gemelos NO respetan convenciones de ruteo — PRUEBA: el protocolo ya pide "una nota
  por feature, no sobre archivos compartidos" y los 3 devs igual editaron los archivos-imán. "Appendea AL
  log" es la convención mínima (nada que misrutear). Los DOMINIOS emergen en la **curación** (mecanismo:
  la skill/humano), no en el write-time (frágil). Regla de oro derivada: **mecanismos > convenciones**
  siempre (git config/guards/scripts se cumplen solos; las convenciones no).
- **DRY-RUN VALIDADO (2026-07-21, repo desechable):** `merge=union` sobre `aprendizajes.md` fusionó bloques
  multi-línea de 2 devs SIN conflicto (0 marcadores, contenido intacto, sin interleave). Único nit: se pierde
  una línea en blanco entre entradas → **regla de formato: cada entrada termina con línea en blanco** (y/o el
  lint la normaliza). Confirma que union aguanta prosa multi-línea, no solo el una-línea de bitácora.

## Principios del mecanismo (2 y 3 SUPERSEDED por la ACTUALIZACIÓN de arriba)
1. **La atribución vive en el CONTENIDO, no en git.** Campo explícito en frontmatter `aportó: [handle]`
   (lista → co-autoría) + `sobre:` opcional (sujeto ≠ autor: "unjordi escribió una nota SOBRE una
   preferencia de chun") + `origen:` (originSessionId corto, traza de máquina, NO atribución humana).
   Más `· quién` en cada línea de `bitacora.md`. Tabla de **handles canónicos** en `_PROTOCOLO.md`
   (unjordi=Jordi Serra{2 emails}, carlos=AliazCIA, chun=chununo) — fin del caos de 5 firmas.
2. **Un aprendizaje = una nota-slug atómica.** NUNCA appendear a un archivo compartido. Merge = unión de
   archivos nuevos = conflict-free (verificado: las notas atómicas jamás chocan). Slugs con prefijo de
   dominio (`feedback-<tema>`, `leccion-<tema>`) para no colisionar entre devs.
3. **Índices DERIVADOS, no editados a mano.** `MEMORY.md` y `skills/README.md` → `.gitattributes`
   `merge=ours linguist-generated=true` + scripts `regen-memory-index.sh`/`regen-skills-index.sh` que los
   reconstruyen del set de notas ya unido (header curado entre marcadores `<!-- index:auto -->`). Así el
   conflicto clásico del índice **desaparece** (gana develop sin marcar, y regen lo hace verídico).
4. **`estado-proyecto.md` = single-writer en integración.** Las minis NO lo tocan (el detalle en vuelo va
   a la nota-slug + una línea de bitácora union); el integrador lo consolida UNA vez desde la bitácora.
5. **Solapes → TRENZADO acreditado, jamás auto-fundir prosa.** 3 desenlaces, SIEMPRE decisión humana:
   (a) **hermanas cross-linked** [default, preserva 100% la voz] (patrón `lecciones-migracion-cps` ↔
   `-desde-cero`); (b) **nota consolidada que CITA en bloque** la prosa de cada quien (`aportó:[a,b]`,
   fuentes marcadas `consolidada-en:` — no se borran); (c) **tensión anotada** (dos notas vivas + línea
   `> Tensión con [[otra]]: <cuándo aplica cada una>`) para calibraciones opuestas por-dev. La máquina solo
   DETECTA candidatos y arma el andamiaje; **nunca reescribe prosa** (norma global anti-aplanado/destructivo).
6. **Cerebro CANÓNICO (hooks/settings/skills-de-proceso del brain) NO se file-mergea a develop.** Se rutea
   a `claude-brain` (MANIFEST fuente única) y baja por `sincronizar-cerebro.sh`. Un guard pre-merge
   **`cerebro-canonico-guard`** (local PreToolUse/Bash + job CI server-side no-evadible) BLOQUEA un MR de
   mini que toque `.claude/hooks/*`, `settings.json`, `.brain-version` o skills-de-proceso — sea edición,
   **cambio de modo/exec-bit** (caso Chunito), **borrado** (caso Unjordi) o archivo canónico EXTRA que el
   brain ya retiró. Reusa `analizar-comando-git.sh` (misma lib que los otros git-guards). Esto es lo que
   protege "el trabajo delicado". NO afloja ningún guard existente.
7. **Integración SECUENCIAL** (nunca octopus), con `git merge-tree --write-tree` (read-only) como GATE;
   entre minis, absorber develop y re-correr el dry-run.

## El ritual — skill nueva `unificar-cerebro` (hermana de `cerrar-slice`, NO la extiende)
Objeto distinto (prosa+guardrails, no código compilable), disparador distinto (integrar la mini completa),
verificación distinta (no hay `dotnet build`; el "verde" es `test-brain.sh` + lint de memoria). Pasos:
0. **Inventario** de tu delta: `git diff --stat origin/develop...HEAD -- .claude/`; clasifica cada archivo.
1. **Sync del brain HACIA ABAJO primero** (`sincronizar-cerebro.sh . --apply` en tu mini) → saca el cerebro
   canónico del diff antes de subir; los `aprendizajes-*-brain.md` se MUEVEN a claude-brain, no a develop.
2. **Resuelve por clase:** notas atómicas → tal cual; `bitacora` → union (no editar); índices → `merge=ours`
   + regen; prosa compartida normativa → NO es campo de aprendizajes (va a nota-slug).
3. **Verifica (el "verde" del cerebro):** `test-brain.sh` (drift e2) + `lint-memoria.sh` (frontmatter válido,
   enlazado, sin `*.local.md` colado, sin rutas muertas). Verde técnico ≠ LISTO.
4. **Integra a develop por el carril EXISTENTE:** MR `Develop<Usuario>→develop`, con **OK explícito de
   unjordi**, **SIN --auto-merge**, **CON --squash** (mensaje curado que acredita al dev). Lo hacen cumplir
   sin cambios `confirmar-merge-develop` + `merge-squash-guard`.
5. **Post-merge:** regen índices + consolidar estado-proyecto (single-writer) + línea a bitácora con `>>`.
Disparadores: manual `/unificar-cerebro`; hook nuevo **`recordar-unificar-cerebro`** (SessionStart, gemelo
*hacia arriba* de `aviso-drift-cerebro`: avisa —no bloquea— cuando el delta de `.claude/` vs develop supera
un umbral); encadenado desde `cerrar-slice` cuando la cosecha cae en `.claude/`.

## Qué se añade / toca
- **`.gitattributes`**: `merge=ours linguist-generated=true` en `MEMORY.md` + `skills/README.md` (mantener
  `union` acotado a `bitacora.md`/`inventario-paridad.md`).
- **Brain (MANIFEST fuente única → auto-propaga + viaja a clones)**: skill `unificar-cerebro` (global),
  hook `recordar-unificar-cerebro` (repo, SessionStart), scripts `regen-memory-index.sh`/`regen-skills-index.sh`
  + `lint-memoria.sh` (global script), guard `cerebro-canonico-guard` (both) + su job CI.
- **Doc (misma tanda)**: `_PROTOCOLO.md` (nueva §"Unificar el cerebro" + tabla de handles + las 3 reglas
  duras), `flujo-de-trabajo.md` (1 línea: el MR mini→develop también unifica cerebro), `CLAUDE.md`,
  `AGENTS.template.md §8`, `ONBOARDING.md`, README del cerebro (+conteo de checks).
- **`.gitlab-ci.yml`**: job merge-request server-side = dry-run `merge-tree` + integridad (`jq empty settings.json`,
  grep de markers `<<<<`, `*.local.md`, exec-bit, CANON-touch). No evadible con `--no-verify`.

## Casos borde cubiertos
settings.json malformado por merge (guard bloquea edición desde mini + `jq empty` en CI) · `*.local.md`
colado (guard/CI bloquea) · hook retirado que revive (chequeo vs MANIFEST vigente) · exec-bit flip
(detecta `old/new mode`) · skill del brain borrada (diff-filter=D ∩ CANON) · union duplica (solo en logs,
línea con fecha·quién) · índice a medias (merge=ours+regen) · slug colisionado entre devs (add/add → renombrar).

## Herencia al clonar la plantilla + 4º dev
Todo viaja en `.claude/` (gates + gitattributes por-repo; skill/hooks del brain vía bootstrap). Un repo
instanciado nace con el mecanismo. Onboarding de un 4º dev: clona → `bootstrap-claude.sh` → `sembrar-mini-develop.sh`
(crea+protege su `Develop<Nuevo>` server-side) → trabaja en notas atómicas → `aviso-drift` mantiene sus hooks →
`recordar-unificar-cerebro` le avisa → `/unificar-cerebro`. La **convención de nombre `Develop<Usuario>` es
requisito** (el auto-sync de `aviso-drift-cerebro` solo matchea `Develop?*`), no cosmética.

## Capa SEMANAL — cosecha del equipo (propósito de fondo, unjordi 2026-07-21)
Este mecanismo es la **base de un ritual SEMANAL**. Dos pasos:
- **Cosecha LOCAL (per-dev):** skill nueva **`cosechar-sesion`** — cada Claude revisa SU PROPIO transcript
  de la sesión y appendea los aprendizajes (atribuidos, formato del log) a `aprendizajes.md` de su mini.
  (No puede leer transcripts de OTRAS máquinas; cosecha el suyo.) Esto alimenta el inbox con contenido real.
- **Reconciliación SEMANAL (1 run designado):** `unificar-cerebro` en modo-semana — fetch de los 3 minis,
  junta los logs (`union` → sin conflicto), trenza solapes/anota tensiones/gradúa, integra a develop por el
  ritual (OK explícito, squash). Disparo: `schedule`/cron semanal **o** unjordi lo pide 1×/semana.
- **Transcripts cross-máquina = NO accesibles** desde una sola máquina → "revisar las otras sesiones" se
  logra vía los **logs cosechados+atribuidos** (git-shared), no leyendo transcripts crudos ajenos (mejor:
  curado, no crudo). **v2 opcional** (NO enfilado): sincronizar transcripts crudos a un lugar común.
- Piezas extra: skill **`cosechar-sesion`** (brain-global) + el modo/disparo semanal de `unificar-cerebro`.

## DECISIONES ABIERTAS (las decide unjordi, no yo)
1. `unificar-cerebro` en el **brain global** (recomendado: es genérica, como cerrar-slice) vs por-repo en la plantilla.
2. ¿Partir la sección "Backlog vivo" de `estado-proyecto.md` a un `backlog.md merge=union` (mata el 2º archivo-imán de conflicto)? Recomendado: SÍ.
3. Índices: **`merge=ours`+regen** (recomendado, determinístico) vs merge=union (duplica/desordena índices).
4. Nombre del campo de atribución: `aportó:` vs `autor:` vs `contribuido-por:` (para skills). + poblar la tabla de handles con los emails git reales.
5. Umbral de `recordar-unificar-cerebro` (≥5 archivos / N días).

## Ejemplos canónicos ya en el repo (construir SOBRE ellos)
`bitacora.md`+`.gitattributes` (atribución-en-contenido probada) · `aprendizajes-claude-brain.md` (log atribuido/fechado append-only, de Aliaz) · `lecciones-migracion-cps` ↔ `-desde-cero` (hermanas cross-linked).
