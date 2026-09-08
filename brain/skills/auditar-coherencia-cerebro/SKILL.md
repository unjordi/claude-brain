---
name: auditar-coherencia-cerebro
description: Manda un fan-out de auditores expertos READ-ONLY a barrer la COHERENCIA del propio cerebro (hooks/guards + flowcharts + normas + doc) buscando evasiones, huecos y doc que miente, y —a petición— itera fix→re-auditar hasta CONVERGER. Es la aplicación al cerebro de la metodología de auditar-proceso-algoritmo (su modo "un SISTEMA"), empaquetada y repetible. Es la mitad CONSISTENCIA de la DUPLA con auditar-suficiencia-operativa (la mitad OPERABILIDAD): van JUNTAS en un cambio a doc/sistema — ninguna caza lo de la otra.
---

# Auditar la coherencia del cerebro (fan-out read-only, iterativo)

Cuando unjordi lo pide ("audita la coherencia del cerebro", "corre los auditores de coherencia",
"barre el brain a ver qué se rompe"), este skill **lanza uno o varios agentes-auditores READ-ONLY**
que revisan el cerebro como SISTEMA —¿los guards se pueden evadir? ¿los flowcharts mienten respecto al
código? ¿alguna norma contradice a otra? ¿hay doc desincronizada?— y devuelven **hallazgos priorizados**.
No es un comando que Claude ejecute por su cuenta: es la **capacidad invocable** que unjordi pide correr.

> **Por qué existe.** Nació de una re-auditoría post-integración del cerebro (jul 2026) que se convirtió
> en un LOOP de 9 rondas: cada ronda destapaba una evasión más fina de los git-guards (opciones globales
> de git → valores entrecomillados → comilla en medio → backslash → `git.exe`…) y de la fidelidad de los
> flowcharts, y cada fix nacía con su test hasta que el auditor CONVERGIÓ (443 PASS). Ese loop se
> improvisó a mano; aquí queda **destilado y repetible**. Es la aplicación concreta al cerebro del
> **modo (B) "un SISTEMA / el propio cerebro"** de [[auditar-proceso-algoritmo]] (que aporta la
> METODOLOGÍA: persona experta, individual→colectivo, leyenda+normas obligatorias). Este skill aporta la
> ORQUESTACIÓN: qué dimensiones, cómo alimentarlas, la verificación por EJECUCIÓN, el loop y el cierre.

## Introspección: el punto ciego del auto-audit (y por qué igual sirve)
Auditar tu propio cerebro se llama **introspección**, y tiene un punto ciego que NO se ignora: el
auditor **comparte el modelo mental de lo que audita** — da por buenas las mismas premisas y no ve los
mismos huecos. Un `general-purpose` FRESCO alimentado con los "zapatos" mitiga esto (no arrastra el
contexto ni los supuestos del orquestador), pero **no lo elimina**; y el auditor **no es infalible ni
se pretende infalible** — se ejercita y mejora en **cada corrida** (es un gate recurrente: típicamente
uno por release, ver «Cuándo usarlo»), igual que el resto del cerebro. Por eso su veredicto NUNCA se
toma a ciegas; dos candados lo sujetan:
- **Los hallazgos son PLAUSIBLES, no verdad.** En la dimensión A se verifican **por EJECUCIÓN** en
  sandbox; en B/C, contra el código/doc real. Nada se cree por su palabra (de ahí CONFIRMADO vs PLAUSIBLE).
- **unjordi tiene la última palabra — no por infalible, sino porque el REPO es suyo.** También se
  equivoca y también necesita ayuda; es una relación de ida y vuelta, no un oráculo que dictamina desde
  arriba. "Auditado sin hallazgos graves" es *verificado técnicamente*, jamás LISTO: cerrar exige su
  QA/OK (definición de LISTO). La introspección PROPONE; unjordi DECIDE.

Dicho corto: **es tu cerebro, es mi repo, y es nuestro proyecto.** Las tres a la vez — contenido,
propiedad y trabajo — de otro modo la introspección se vuelve o un oráculo suelto o un dueño ausente.

## Cuándo usarlo
- Tras **integrar cambios a `develop`** (varios PRs, un refactor de wiring, hooks nuevos): barrer que no
  se coló una evasión ni un drift de doc antes de un release a `main`.
- Cuando toques un **guard de supervisión** (git-branch-guard, secret-scan, confirmar-merge-develop,
  merge-squash-guard, la lib `analizar-comando-git.sh`): un cambio de precisión puede reabrir un hueco
  más fino (lección de las 9 rondas — el value-model de git reabrió 5 veces seguidas).
- Cuando cambien **flowcharts, README-árbol o normas**: verificar que la doc sigue reflejando la realidad
  (doc=realidad) y que las leyendas generadas cuadran con el árbol vivo.
- Como **gate de coherencia recurrente antes de CADA release `develop→main`** — barrido de rutina, no
  evento excepcional; nunca como sustituto del QA/OK de unjordi.

## Los "zapatos" (inputs OBLIGATORIOS — sin esto el auditor camina descalzo)
Regla dura heredada de [[auditar-proceso-algoritmo]]: **a cada auditor se le dan los zapatos o audita a
ciegas.** Para el cerebro son:
1. **El árbol del README** (`README.md` raíz, bloque «🔒 Hooks Forzosos») — la lista CANÓNICA de
   hooks/skills/normas (fuente única). Contra esto se mide "¿falta algo? ¿sobra? ¿la leyenda cuadra?".
2. **Los flowcharts CON su leyenda + las normas** (`docs/flowcharts/*.dot` + `CONVENCIONES.md`) — el
   MAPA del sistema y su notación. Un `.dot` pelón sin leyenda ni normas lo hace auditar a ciegas.
3. **El `brain/hooks/MANIFEST`** — la fuente única de tiers/eventos; el cableado DERIVA de aquí
   (`install-brain.sh` `ev_de()` + loop), no está hardcodeado. Los charts/afirmaciones se miden contra él.
4. **El código real** que cada nodo/afirmación describe — los `.sh` de los hooks, la lib compartida,
   `install-brain.sh`/`.ps1`, `sincronizar-cerebro.sh`. El auditor LEE la fuente, no la memoria.
5. **Las normas que los guards HACEN CUMPLIR** — flujo de git (nunca push a develop/main; ramita→MR→
   develop con squash; main release-only con OK super-explícito) y la **definición de LISTO**. El auditor
   necesita saber QUÉ debe pasar para juzgar si el guard lo logra.
6. **El corpus de FALSOS POSITIVOS** (`docs/guards-falsos-positivos.md`) — cuando el target toca un guard
   (o un flowchart de guards), dale al auditor los FP RELEVANTES a ese guard. Uso doble: (a) el chart/afirmación
   debe reflejar la conducta **TUNEADA** del guard (no la pre-tuning), y (b) un patrón de FP recurrente suele
   ser un **edge REAL** que el diagrama debería depictar o anotar. Blinda contra que el auditor marque como
   "bug del chart" algo que es solo cómo se comporta el guard de verdad. (Decisión unjordi 2026-09-08:
   "aliméntaselos también a los auditores cuando corras el loop sobre ESE flowchart".)

> **Cuando el target es el cerebro de un PROYECTO** (no el `cortex` meta), los "zapatos" se traducen:
> audita contra la **FIRMA** = `CLAUDE.md` (thin, TOC) → el **detalle operativo** → la memoria/skill →
> **realidad (código)**. **Para AUDITAR, lee el entry-point operativo REAL, sea cual sea su nombre** (hoy varía:
> `AGENTS.md` en games-master, `MEMORY.md`-índice en cps). La **CONVENCIÓN destino es `CLAUDE.md`+`MEMORY.md`**
> (`consolidar-cerebro` migra hacia ella); `AGENTS.md` queda para **arquitectura real** (en cps, 3194 líneas:
> capas/dominio, medido vs el `.cs`). La coherencia verifica que **ninguno mienta respecto al código real** y que
> no se confunda el ROL de cada doc (auditar lee la realidad; consolidar la lleva a la convención).

## Las dimensiones (una por auditor, en paralelo)
El cerebro se barre por dimensiones INDEPENDIENTES; se lanza **un auditor por dimensión** (fan-out, ver
[[orquestar-fanout]]) para que cada uno sea profundo y no se diluya:
- **A · Guards / lib de git** — ¿se pueden EVADIR? (push a base, escaneo de secretos, gate de merge,
  confirmación). Es la dimensión más adversarial y **se audita por EJECUCIÓN** (ver abajo).
- **C · Fidelidad de flowcharts + doc** — ¿los `.dot`/leyendas/citas reflejan el código y el árbol del
  README? ¿drift, citas de línea stale, valencia de color inconsistente, huecos ya resueltos?
- **B · Instalador / wiring / cobertura** — ¿`install-brain.sh/.ps1` cablea TODO lo del MANIFEST? ¿la
  paridad cross-OS (bootstrap.ps1, CLAUDE_BRAIN_DIR)? ¿el `test-brain.sh` cubre lo que dice cubrir?
Ajusta el set a lo que cambió: si solo tocaste guards, corre A (y una pasada de C si tocaste su doc).

## Regla de oro de la dimensión A: se audita por EJECUCIÓN, no por lectura
La lección más cara de las 9 rondas: **un guard de regex se rompe por cómo el SHELL tokeniza, no por
cómo se LEE.** El auditor de guards NO debe conformarse con leer el `.sh` — debe **montar un repo git de
sandbox efímero** (mktemp), pararse en una rama no-base y en una base, y **correr el guard con entradas
JSON reales** (`{"tool_name":"Bash","tool_input":{"command":"..."}}`), pensando como adversario:
comillas simples/dobles, comilla en medio del valor, espacios escapados con `\`, prefijos globales de git
(`-c`, `--no-pager`, `--work-tree`…), refspecs (`HEAD:develop`, `+develop`), encadenamientos (`;`/`&&`/`|`),
`git.exe`/`glab.exe`/`gh.exe` (Windows), menciones dentro de `-m`/`--repo` (no deben disparar). El arnés
exacto vive en `brain/test-brain.sh` (bloques `gbg`, `scanf`, `cm`) — que el auditor lo reuse. Sin ejecución,
el dictamen es superficial y deja pasar justo lo que importa.

## Método: INDIVIDUAL → COLECTIVO (de [[auditar-proceso-algoritmo]])
Cada auditor hace las **dos pasadas**: primero cada pieza SOLA (¿dónde truena aislada?), luego TODAS
JUNTAS (¿una pieza correcta contradice a otra, o deja un hueco en la costura?). El dictamen separa los
hallazgos individuales de los **colectivos/de costura** — son de naturaleza distinta.

## El LOOP fix→re-auditar→hasta CONVERGER (el corazón, y solo con OK de unjordi)
Auditar ENCUENTRA; arreglar es **decisión de unjordi** (no-transitiva: el dictamen no autoriza tocar
nada). Cuando unjordi pide "dale vueltas hasta que salga limpio", el ciclo es:
1. **Fan-out** de auditores → dictámenes a disco → **sintetiza** (dedup + severidad).
2. Presenta los hallazgos; con OK, **arregla en una ramita** (`fix/...` o `feat/...`), y **cada hallazgo
   nace con su TEST** (verificado por ejecución contra el guard real). Corre la suite.
3. **Re-audita** SOLO lo que tocaste (si solo cambiaste guards, no re-corras la dimensión C intacta) +
   una batería que intente ROMPER el fix nuevo (los fixes de precisión reabren huecos más finos).
4. Repite hasta **CONVERGENCIA**: pídele al auditor que la DECLARE explícitamente ("el modelo resiste;
   los residuos son BAJO/fuera-de-alcance") en vez de inventar un crítico marginal para justificar otra
   ronda. Convergió cuando no quedan hallazgos CRÍTICO/ALTO/MEDIO accionables.
5. **Señala el patrón** si varias rondas destapan la MISMA clase (fue whack-a-mole de regex-vs-shell):
   generaliza el fix a la CLASE, no persigas instancias, y si solo quedan exóticos, **pausa y lleva a
   unjordi la decisión de convergencia** en vez de loopear indefinidamente.

## Read-only, aislamiento y reporte (reglas duras)
- **Read-only de verdad.** El auditor LEE el árbol bajo revisión y EJECUTA en sandbox mktemp; **NUNCA**
  muta el worktree del orquestador (nada de `git add/commit/checkout/reset/edit` ahí). Si el árbol es un
  worktree compartido, dáselo como snapshot de solo lectura.
- **Reporta a un `.md` en disco y devuelve SOLO exec-summary + ruta.** Cada auditor escribe su dictamen
  completo a `scratchpad/auditoria-<tema>/<AUDITOR-X>.md` y su respuesta al orquestador es 3 líneas:
  veredicto (conteo por severidad), hallazgos nuevos en bullets, y la ruta. Así no infla el contexto del
  orquestador (los transcripts de agente son enormes).
- **Dictamen DURABLE en el repo.** La síntesis (veredicto + rastro del loop) va a un doc versionado
  (`docs/auditoria-<tema>-<fecha>.md`), no solo al scratchpad efímero — es el record de qué se auditó y
  qué se aceptó. (Doc=realidad: si audita algo ya integrado, el dictamen es parte del record.)

## Convergencia y residuos ACEPTADOS
No todo hueco se cierra: los **BAJO/esotéricos con backstop externo** (p. ej. las ramas protegidas
server-side de GitLab respaldan a los git-guards) se **documentan y ACEPTAN**, no se persiguen —
cerrarlos suele aflojar en la dirección insegura o son irreales (`$(git push…)`, `eval`, etc.). El
dictamen durable los lista con su razón. Perseguir exóticos indefinidamente es el modo de falla a evitar.

## Reglas heredadas (no se saltan)
- **Consentimiento de costo.** Reclutar cada agente pasa por `delegacion-gate` (consentimiento
  window-aware). Con fan-out, es un set de agentes: cuéntalos.
- **Ningún hallazgo se queda solo en el chat.** Al cerrar, los hallazgos NO atendidos van al backlog
  vivo (`estado-proyecto.md` / la nota del tema) con severidad y origen — aunque solo se atienda un
  subconjunto (ver [[cerrar-slice]]). El chat no es la fuente de verdad.
- **El auditor NO declara LISTO.** Su dictamen es insumo; el cierre exige el QA o la autorización expresa
  de unjordi (definición de LISTO). "Auditado sin hallazgos graves" es *verificado técnicamente*, no *listo*.
- **Integridad de los guardarraíles.** Si el fix toca un guard de supervisión de Claude, el cambio es de
  PRECISIÓN/endurecimiento y exige **OK explícito de unjordi para ESE control** — nunca "para que deje
  de molestar".

## Familia
- **La DUPLA — va junto con [[auditar-suficiencia-operativa]] en todo cambio a doc/sistema.** Yo audito
  CONSISTENCIA (¿se contradice/evade/miente?); ella OPERABILIDAD (¿alguien nuevo puede HACER las tareas sin
  romper ni re-investigar?). **Lentes disjuntas — ninguna caza lo de la otra** → córrelas JUNTAS hasta converger
  (0 CRÍTICO/ALTO/MEDIO, BAJOS triaged). El FMEA [[auditar-proceso-algoritmo]] es el TERCER eje (algoritmo/flujo),
  se suma cuando lo hay.
- Hermano de [[auditar-proceso-algoritmo]] (la METODOLOGÍA general; este es su modo-cerebro empaquetado),
  de [[diagramar]] (produce los flowcharts que son los zapatos), de [[orquestar-fanout]] (cómo lanzar el
  fan-out sin niñera) y de [[cerrar-slice]] (los hallazgos → backlog, el fix → MR con resumen curado).

## El prompt del auditor (battle-tested — destilado de las 9 rondas)
Delega con `Task`/subagente `general-purpose`, uno por dimensión. Adapta el target, conserva la ESENCIA:

> Eres un AUDITOR FMEA READ-ONLY de `<dimensión: los git-guards / la fidelidad de los flowcharts / el
> instalador y wiring>` del repo `cortex`. NO MUTAS NADA (nada de git add/commit/checkout/edit en
> el worktree del orquestador); LEES y —para guards— EJECUTAS los scripts en un sandbox efímero (mktemp).
> Árbol a auditar: `<ruta del worktree @ commit>`. Contexto/zapatos: el árbol del README (bloque «🔒 Hooks
> Forzosos»), los flowcharts con su leyenda + CONVENCIONES.md, el `brain/hooks/MANIFEST`, el código real
> de los hooks/lib/instalador, y las normas que los guards hacen cumplir (flujo de git + definición de
> LISTO). Método FMEA: enumera los MODOS DE FALLA de cada pieza (¿qué la EVADE —falso negativo— o la
> dispara EN FALSO —falso positivo?), audita cada pieza INDIVIDUALMENTE y luego TODAS JUNTAS (una pieza
> correcta sola puede contradecir a otra en conjunto). Para guards, **VERIFICA POR EJECUCIÓN** montando un
> repo sandbox y corriendo el guard con JSON real, pensando como adversario (comillas, escapes, prefijos
> globales, refspecs, encadenamientos, `.exe` de Windows, menciones entrecomilladas que NO deben disparar);
> reusa el arnés de `brain/test-brain.sh`. Convención: CONFIRMADO = ejecutado y falla (cita comando +
> salida); PLAUSIBLE = sospecha sin cierre. Da severidad (CRÍTICO/ALTO/MEDIO/BAJO) + realismo + si hay
> backstop server-side. Si el sistema resiste, DECLARA CONVERGENCIA explícitamente (no inventes un crítico
> marginal). Escribe el dictamen COMPLETO a `<scratchpad>/AUDITOR-<X>.md`; tu RESPUESTA final es SOLO:
> (1) veredicto en una línea (conteo por severidad + si convergió), (2) hallazgos nuevos en bullets de una
> línea, (3) la ruta del .md. NADA más.
