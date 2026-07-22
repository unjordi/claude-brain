---
name: orquestar-fanout
description: >
  Orquestar un fan-out de agentes SIN NIÑERA: asignar ítems autocontenidos del backlog, y que al
  terminar cada agente su avance quede registrado y su worktree limpio AUTOMÁTICAMENTE — no
  monitoreándolos a mano. Define el modelo de estado (2 archivos, sin redundancia) y el contrato de
  reporte. Úsalo cuando delegues trabajo paralelizable a varios agentes.
---

# orquestar-fanout — fan-out con auto-reporte (sin niñera)

El hueco que cierra: los agentes hacían el trabajo pero NO reportaban; el estado del proyecto
dependía de que el humano lo pidiera y monitoreara a mano. Esta skill hace del **auto-reporte el
default** y mata la redundancia de dónde vive el estado.

## Modelo de estado — DOS archivos, roles claros (cero redundancia)
- **`.claude/memory/estado-proyecto.md`** = la **fuente de verdad**: dónde estamos + **BACKLOG VIVO**
  (pendientes autocontenidos, con prioridad + HELD "esperan tu decisión" + follow-ups + justificación).
  **Aquí empiezas siempre.** Lo **cura el orquestador** (no los agentes en paralelo → cero conflictos).
- **`.claude/memory/bitacora.md`** = **log cronológico append-only** (qué se cerró y cuándo). `merge=union`
  → parallel-safe. **Aquí APPENDAN los agentes/orquestador** una línea por slice.
- Regla anti-redundancia: **el mismo dato NO se escribe en 3 lados.** bitácora = *qué pasó*;
  estado-proyecto = *qué sigue*. El estado "actual" se DERIVA (leer ambos), no se triplica.
- La lista de **TodoWrite** del harness es **scratch de sesión** — el backlog DURABLE es
  estado-proyecto.md. No confundas una con la otra.

## PREREQUISITO: la sesión debe vivir DENTRO de un repo git
El fan-out con worktrees aislados **exige que el cwd de la sesión sea un repo git** — Claude Code
solo sabe crear worktrees vía git. Si lanzas un agente con `isolation: "worktree"` desde una sesión
cuyo cwd NO es un repo, truena con:
`Cannot create agent worktree: not in a git repository and no WorktreeCreate hooks are configured`
(los hooks `WorktreeCreate`/`WorktreeRemove` que menciona el error son para OTROS VCS — no aplican aquí).
**Regla práctica:** inicia la sesión EN el repo (además así carga sus hooks/`CLAUDE.md` — las sesiones
se INICIAN en el repo, no se mudan a él, ver abajo). Si el trabajo es multi-repo, ancla la sesión en el
repo principal y que los agentes creen sus worktrees con `git -C <ruta-del-repo> worktree add …`.
(Caso real: CachyOS, 2026-07-20.)

## Regla dura de AISLAMIENTO (lo que evita que un agente te coma trabajo)
**Todo agente que MUTE archivos o COMMITEE corre en un WORKTREE AISLADO, NUNCA en el árbol de trabajo
COMPARTIDO/principal.** Spawnéalo con `isolation: "worktree"` (el Agent tool crea un worktree fresco) o
dale tú un worktree disjunto. El árbol principal es SOLO del orquestador (o del humano). **Por qué muerde:**
un agente que corre `git reset`/`checkout`/`rebase` en el árbol compartido puede **mover el HEAD y dejar
huérfanos los commits del orquestador** → la fuente queda a medias y el build compila eso (lección REAL,
2026-07: un agente de verificación se metió al árbol principal, reseteó HEAD y orfanó un commit; se
recuperó por cherry-pick, pero casi se pierde). Si un ítem NO se puede aislar en su worktree, **lo hace el
orquestador**, no un agente suelto en el árbol compartido. Lo respalda el guard `proteger-arbol` (avisa
antes de un git destructivo que orfanaría commits sin pushear).

> **GOTCHA del worktree — base equivocada (feedback real, 2026-07).** El Agent tool crea el
> worktree basado en **`origin/HEAD`** (= el default branch remoto, normalmente `origin/main`), **NO** en
> el HEAD de tu rama activa. Si `main` es release-only y tu trabajo vive en `develop`/una ramita (p. ej. una
> migración a una nueva estructura aún NO promovida a main), el worktree nace en un commit VIEJO (la estructura
> previa) y el agente NO encuentra los archivos que espera. **Workaround defensivo (ponlo en el prompt del agente):**
> *"al iniciar, `git reset --hard <rama-objetivo>` en TU worktree aislado para nacer sobre la base correcta"*
> — es seguro porque es tu worktree AISLADO (no el compartido). Disparará `proteger-arbol` (aviso, no bloqueo):
> es un falso positivo conocido en worktree aislado (backlog H14). Fix de raíz = harness (backlog H15).
>
> **El workaround NO basta por sí solo — el ORQUESTADOR verifica la BASE, no la cree (lección REAL, C7, 2026-07-21).**
> Un agente reportó "reseteé a `DevelopUnjordi`" pero su commit salió con **parent = tip de `main`**
> (el reset no ocurrió, o falló en silencio): al nacer sobre `main` NO vio infra que sí existía en
> `develop` y **rehízo trabajo redundante**. El auto-reporte del agente sobre su propia base es
> exactamente lo que NO es evidencia. **Antes de integrar el commit de un agente, el orquestador
> COMPRUEBA su linaje con git** (no confía en la prosa del reporte):
> `git merge-base --is-ancestor <commit>^ <rama-objetivo>` (¿su padre YA está en mi rama?) y
> `git log --oneline -1 <commit>^` / `git show --stat <commit>` (¿el padre y el diff son los esperados?).
> Si el padre resultó ser `main` (u otra base equivocada) → **NO integres**: descarta la rama y rehaz
> el ítem sobre la base correcta. **Integra por CHERRY-PICK del delta** (no `merge`) cuando la base del
> agente pueda estar vieja — el merge arrastraría el árbol viejo; el cherry-pick trae solo el cambio neto.

## Con agentes ACTIVOS — reglas anti-desastre (destiladas de un caso real, 2026-07)
- **El sub-agente es TERMINAL.** Su prompt DEBE decírselo: *"eres terminal — cuando tu turno acaba NADA
  tuyo sigue corriendo; NO puedes 'lanzar en background' ni esperar notificaciones. Ejecuta el trabajo
  COMPLETO en ESTE turno."* (En un caso real un agente se despidió creyendo que dejó algo "corriendo en background"
  — no había hecho nada, esperaba una notificación que jamás llegaría.)
- **Verifica ANTES de creer — incluida la BASE del commit.** El reporte de un agente NO es evidencia: el
  orquestador comprueba el resultado real (git status/worktree/archivo existe/compila) **read-only** antes
  de marcar el ítem hecho — **y verifica el LINAJE del commit** (que su padre esté sobre la rama-objetivo,
  no sobre `main`; ver el GOTCHA de base equivocada arriba) ANTES de integrar. Un "reseteé a la rama X" del
  agente es justo lo que hay que comprobar, no creer (caso C7, 2026-07-21).
  El prompt del agente exige *"ENTREGA el artefacto ejecutado y verificado, NO un plan ni un stub; si no
  puedes completarlo, dilo explícito"* (agentes devolvieron esqueletos en vez del trabajo real).
- **NUNCA publiques/deployes desde el worktree de un agente.** Los worktrees NO heredan archivos
  gitignored (p. ej. `appsettings.json`) → un publish desde ahí sale con manifiesto inconsistente y
  **rompe la app** (en un caso real tumbó el login del usuario). El deploy sale SIEMPRE del clon principal tras `git pull`.
- **Con agentes activos, el orquestador NO hace `git checkout`/build en el clon principal** (cruzaría la
  rama que un worktree tiene tomada — "is already used by worktree"). Usa tu propio worktree o espera.
- **Mensajería con dirección explícita.** Encabeza los mensajes a un agente con `[DE: orquestador → PARA:
  agente X]` para que no confunda una instrucción-descendente con un reporte-ascendente (un agente prudente
  lee un mensaje ambiguo como posible inyección y se traba).
- **PORTA, no REHAGAS** (migración/armonización). Si ya existe la fuente VIVA (el código de la app legada
  / otra app / un proyecto de referencia), el agente la **cita y la LEE ANTES de escribir** y la ADAPTA.
  **PROHIBIDO reconstruir desde cero** un componente que ya funciona (rehacerlo en vez de traer el que servía).
  El prompt del agente lo dice explícito: *"PORTAR = copiar el artefacto que YA funciona y adaptarlo; cita
  el archivo origen; si no existe fuente, dilo — no inventes"*.
- **Emite un LATIDO de estado** mientras haya agentes EN VUELO — no quedes mudo. El usuario no debería
  preguntar "¿sigues? ¿todo bien?": reporta avance periódico (qué agente va en qué), no solo el volcado a
  bitácora al cerrar. Señal de desvío: el usuario preguntó "¿ping?".
- **INICIA cada agente EN el repo destino; PROHIBIDO "cambia de folder" a media sesión.** Los hooks y el
  `CLAUDE.md` de un repo se cargan SOLO al INICIAR la sesión/agente en él — mudarse a otro folder a mitad
  NO los carga (el agente opera con las normas equivocadas). Si un agente debe trabajar otro repo, se
  INICIA ahí. Recuerda esto si un agente corre en un cwd distinto al de su arranque.

## El flujo (lo que hace el orquestador)
1. **Asigna:** saca del backlog (estado-proyecto.md) ítems **autocontenidos** (uno que un agente
   pueda cerrar solo, sin depender de otro en vuelo). Reparte **archivos disjuntos** (regla anti-choque)
   y **cada agente que toque código va en su WORKTREE AISLADO** (ver regla dura arriba).
2. **Contrato del agente:** cada agente DEVUELVE, además del trabajo:
   - `qué hizo` (el cambio neto),
   - `base`: la rama y el **SHA real** sobre los que construyó, **verificado con git** (`git rev-parse HEAD^`,
     `git rev-parse --abbrev-ref HEAD`), NO asumido — el orquestador lo re-verifica antes de integrar (ver GOTCHA de base),
   - `línea-de-bitácora` curada (prosa, no el pegote de commits),
   - `pendiente` que deje para otro (o "ninguno"),
   - `worktree`: `limpio` (rama mergeada) o `dejado-con-<nota>`.
3. **Cierra el loop (AUTOMÁTICO al terminar cada agente — lo recuerda el hook `delegacion-reporte`):**
   - **APPENDA** la línea a `bitacora.md`.
   - **ACTUALIZA/cierra** el ítem en `estado-proyecto.md` (backlog vivo).
   - **WORKTREE:** corre `limpiar-worktrees.sh` (borra los de ramas ya mergeadas; los vivos/a-medias
     los DEJA y anota su pendiente en la bitácora para quien lo retome).
   → No monitoreas a los agentes: el reporte y la limpieza son el cierre estándar.

## Hooks/tools que lo sostienen
- **`delegacion-gate`** (PreToolUse/Task) — consentimiento de costo por ventana de 5h (ver el flujo de gasto).
- **`delegacion-reporte`** (PostToolUse/Task) — tras cada subagente, recuerda registrar avance + limpiar worktree.
- **`limpiar-worktrees.sh`** — barre worktrees zombies (rama mergeada) y anota los vivos en la bitácora.
- **`proteger-arbol`** (PreToolUse/Bash) — avisa antes de un git DESTRUCTIVO (`reset --hard`/`checkout -f`/`rebase`/`branch -D`) que orfanaría commits sin pushear; antídoto al "agente reseteó HEAD en el árbol compartido".
- **`checkpoint`** (skill) + **`rehidratar-hilo`** (SessionStart) + **`aviso-contexto`** (watermark) — compactar sin perder el hilo del fan-out (el hook `precompact` se retiró: PreCompact no puede inyectar ni pedir acción).

## Anti-patrones
- ❌ Monitorear agentes "de niñera" y actualizar el estado a mano al final. → El auto-reporte es el default.
- ❌ Escribir el mismo pendiente en estado-proyecto Y bitácora Y un backlog aparte. → Un dato, un lugar.
- ❌ Dejar worktrees zombies acumulándose. → `limpiar-worktrees.sh` al cerrar la ola.
- ❌ Asignar ítems NO autocontenidos (que dependen de otro agente en vuelo). → Serialízalos o únelos.
- ❌ Dejar que un agente mute/commitee en el árbol de trabajo COMPARTIDO (o corra `git reset`/`checkout`/`rebase` ahí). → Worktree AISLADO por agente, o lo hace el orquestador. Es lo que orfanó un commit en un caso real.
- ❌ Creer el reporte de un agente sin verificar el resultado real. → Comprueba read-only (git/archivo/compila) antes de marcar hecho; el agente pudo devolver un stub o "alucinar" trabajo en background.
- ❌ Publicar/deployar desde el worktree de un agente (no hereda gitignored → rompe el deploy). → Del clon principal tras `git pull`.
