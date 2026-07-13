# Auditoría de cps → mejoras al cerebro (reporte interno + autoauditoría)

> Reporte pedido por unjordi (2026-07-12). Qué se observó al revisar los transcripts de cps, qué se
> implementó para resolverlo, y una autoauditoría de coherencia (contradicciones + referencias circulares).
> Disciplina: **[HECHO]** = leído en el transcript · **[INF]** = inferido (no confirmado).

## 1. Qué se observó
Auditoría forense: **4 agentes read-only** barrieron los **11 transcripts de cps (~35k líneas)** por señales
de falla (correcciones, reverts, huérfanos, FRENOs de hooks, reworks, bugs que el QA humano cazó). **42
hallazgos crudos → clusters.** Los de mayor impacto comparten UNA raíz: **actuar/declarar sin verificar el
ARTEFACTO REAL final** (el commit vivo, la pantalla renderizada, el asset servido).

Top recurrentes:
- **Verde técnico → "LISTO/✅/cerrado/🏁" → desmentido** — el fallo MÁS repetido (todos los transcripts).
- **QA visual "a ciegas"** — se insinuó QA de Chrome sin ver la pantalla → reaparecieron bugs ya resueltos.
- **Fan-out/worktree:** agente en árbol compartido reseteó HEAD → **commit huérfano**; sub-agente que "alucina"
  trabajo en background; deploy desde worktree de agente (sin `appsettings` gitignored) → **rompió el login**.
- **Deploy sirvió artefacto VIEJO** (caché de capas Docker / `.dockerignore *.md` / `appsettings` post-copy → 405).
- **Verde técnico ≠ runtime-safe:** bugs a develop Y a pisa (13.º parámetro rompió firma Dapper → 500;
  `Ok(string)` text/plain colgó un diálogo; `GETDATE()` concatenado → 0 filas) — todos pasaron build+tests.
- **Doc con encabezado stale** ("miente arriba"); **decisión destructiva** (aplanó un esquema de permisos de
  meses amparado en `AGENTS.md`) sin marcarla como pérdida.
- Menores: bash 4 en macOS 3.2, commit-file frágil, git en loops background que trunca, gotchas Blazor/EF/CSS,
  seeding incompleto, y el `ls` que prefija cada resultado de Bash (**[INF]** causa no fijada).

El detalle crudo por cluster vive en `.claude/memory/backlog-desarrollo.md` (sección 2026-07-12).

## 2. Qué se implementó (5 slices → 5 MRs)
| Slice | Qué resuelve | Dónde | MR |
|---|---|---|---|
| Blindaje fan-out | worktree aislado obligatorio + guard `proteger-arbol` (avisa antes de git destructivo que orfanaría commits) | claude-brain | #119 ✅ merged |
| Pain-points al backlog | los 42 hallazgos documentados con evidencia+causa+mejora | claude-brain | #120 ⏸ en revisión con unjordi |
| S1 · `dod-verificar` "la reina" | léxico de cierre ampliado (cerrado/🏁/✅) + **bloqueo de claim VISUAL a ciegas** + migración=paridad | claude-brain | #121 ✅ merged |
| CB · gobernanza | `orquestar-fanout` (agente terminal, verificar-antes-de-creer, no-deploy-desde-worktree, no-checkout-con-agentes, mensajería DE→PARA) + `cerrar-slice` (smoke E2E runtime-safe, destructivo=pausa+OK, releer-encabezado, estado bidireccional, gotchas de commit) + norma DoD | claude-brain | #122 🔶 armado |
| PLANTILLA · gotchas .NET | Blazor/MudBlazor/CSS + EF + deploy-verificado + seed → skills `crear-pagina-blazor`/`migracion-ef`/`build-produccion`/`agregar-seed` | plantilladotnet | !97 🔶 armado |
| Este reporte + test anti-ciclos | persistir la auditoría + un test que caza referencias circulares nuevas | claude-brain | (este) |

**Deferido honesto:** el `ls` en cada Bash (H1) — revisé la cadena del profile (`~/.zshrc` → oh-my-zsh →
powerlevel10k → `~/.config/zsh-aliases.zsh`) y **no pude fijar la causa**; NO inventé un fix ni toqué la
config viva del shell. Queda en el backlog para investigación honda.

## 3. Autoauditoría de coherencia
Se mapeó el grafo de referencias entre hooks/skills/normas y se analizaron las interacciones.

### Contradicciones → NINGUNA
- Los gates `PreToolUse/Bash` que coinciden en un mismo comando (p. ej. un merge a develop dispara
  `merge-squash-guard` + `confirmar-merge-develop`) **se ANDan** — deben pasar TODOS, no compiten.
- `proteger-arbol` (avisa en `reset --hard`/`checkout -f`/`rebase`/`branch -D`) **no** se dispara con el flujo
  de `cerrar-slice` (`git branch -d` minúscula / `git checkout develop` plano no matchean su patrón).
- La Definición de LISTO se aplica coherente en dos puntos distintos: al **DECLARAR** (`dod-verificar`, Stop) y
  al **INTEGRAR** (`confirmar-merge-develop`, PreToolUse) — refuerzo mutuo, no choque.
- El bloqueo B2 (claim visual sin tool de navegador) NO contradice la realidad de que Chrome se desconecta: es
  el punto — si no puedes correr la tool, no declaras QA visual (dices "sin QA visual"). Consistente con la norma.

### Referencias circulares → NINGUNA tóxica (6 enlaces bidireccionales benignos)
El grafo tiene **6 pares bidireccionales** (X e Y se mencionan mutuamente). Se inspeccionó cada uno:

| Par | Tipo | Por qué es benigno |
|---|---|---|
| `cerrar-slice` ↔ `merge-squash-guard` | skill↔hook (enforcement) | la skill define el flujo; el hook exige squash y ATRIBUYE a la skill. Cada uno autocontenido. |
| `cerrar-slice` ↔ `recordar-dashboard` | skill↔hook (recordatorio) | la skill define el ritual; el hook recuerda + atribuye. |
| `delegacion-comun` ↔ `delegacion-gate` | lib↔consumidor | los consumidores SOURCEAN la lib (una dirección); la lib solo los MENCIONA en un comentario. **No hay ciclo de sourcing runtime** (verificado). |
| `delegacion-comun` ↔ `delegacion-registrar` | lib↔consumidor | idem. |
| `delegacion-gate` ↔ `limite-gasto` | hooks hermanos | comparten el modelo ventana+overage, documentado cruzado en comentarios; lógica propia cada uno. |
| `delegacion-reporte` ↔ `orquestar-fanout` | hook↔skill | el hook refuerza; la skill define el flujo. |

**Criterio aplicado:** *ciclo TÓXICO* = la definición de X en A depende de B y la de B depende de A, sin base
(runaround / deferral infinito). *enlace BENIGNO* = dos piezas con contenido propio y completo que se cruzan
("see also"). Los 6 son del segundo tipo; el único riesgo real (ciclo de **sourcing** en la lib de delegación)
se descartó verificando que `delegacion-comun` no sourcea a sus consumidores.

> **Nota de honestidad:** el conteo manual inicial dijo "2 pares"; el script los computó y son **6**. Es
> justo el error que la propia auditoría advierte (no fiarse de la memoria, verificar). Por eso el test de
> abajo: computa los pares en cada corrida, no depende de que alguien los cuente bien.

### Guardarraíl nuevo
`test-brain.sh` sección **(e)**: computa los pares bidireccionales del grafo y falla si aparece **uno NUEVO**
fuera del allowlist de los 6 benignos — obligando a revisar si es referencia circular tóxica antes de que
entre. (No juzga benigno-vs-tóxico automáticamente —eso es semántico— pero CONGELA el set actual y caza
cualquier enlace mutuo nuevo.)

## Veredicto
El cerebro queda **coherente**: sin contradicciones ni ciclos tóxicos; las mejoras se refuerzan en la
dirección correcta (**verificar lo real antes de declarar/integrar**). Los enlaces bidireccionales son
benignos y ahora están vigilados por un test.
