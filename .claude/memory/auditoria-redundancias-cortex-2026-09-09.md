# Auditoría — REDUNDANCIAS UNIFICABLES del cerebro cortex · 2026-09-09

> Dictamen de 1 auditor Claude (skill `auditar-proceso-algoritmo`, modo sistema). Read-only. Pendiente: DECISIÓN.
> Alcance: 38 hooks/libs + MANIFESTs, 25 skills, los CLAUDE.md/README/mapa/CONVENCIONES + 14 flowcharts + docs/.

## VEREDICTO: el olfato de unjordi es correcto, PERO la redundancia está en PROSA de normas re-tecleada,
NO en lógica de código. El código está bien factorizado (`juez-comun`, `analizar-comando-git`,
`delegacion-comun`, `drift-cerebro-comun` = el modelo de cómo SÍ se deduplica). ~9 unificables reales; el
resto es copia-por-diseño (correo `both`, artefacto generado, log append-only) que NO se toca.

## ALTA (mayor beneficio)
- **A1 · idiom de emitir `additionalContext` inline en ~22 hooks** (el bloque `if jq … hookSpecificOutput.additionalContext … else printf`). Mayor FRECUENCIA. Unificable a un helper `emit_ctx <evento> <texto>` — pero requiere decidir una lib `emit-comun.sh` con su tier (`both/lib` para viajar como correo, o `global/lib`). No trivial por el modelo de dedupe.
- **A2 · la regla "CÓMO DECIDIR EL TIER" escrita 3× casi verbatim:** `~/.claude/CLAUDE.md:345-362` + `brain/hooks/MANIFEST:15-29` + `brain/skills/MANIFEST:14-23`. Pueden driftear. Fuente única = la norma "Cerebro por-repo = CORREO"; los MANIFEST apuntan a ella. **Riesgo cero, drift real hoy.**
- **A3 · bloques de prosa re-tecleados entre skills:** firma CLAUDE.md/MEMORY.md/AGENTS (×4: auditar-coherencia/suficiencia, consolidar, canonizar) · ruteo de TRATO→global (×3: cosechar-sesion, unificar, desinflar) · gradiente de estabilidad CLAUDE=main (×4). Dueño canónico + punteros `[[skill]]`.

## MEDIA
- **M1 · throttle "1×/día/repo" copiado ×4** (recordar-cosechar, recordar-unificar, aviso-drift, hud-stale) → helper `nudge_throttle_1x_dia`. Hogar natural: una `nudge-comun.sh` (junto con A1).
- **M2 · resolución del snapshot de cuota ×3** (limite-gasto:21, delegacion-comun:44 Y :95) → `_cortex_snapshot_path()` en delegacion-comun.
- **M3 · extracción de ventana de transcript duplicada entre los 2 jueces** (dod-verificar vs confirmar-merge `_recent_intercalado`) → mover a `juez-comun.sh` (donde ya vive su hermana, el veto-de-cita).
- **M4 · boilerplate de auditoría ×3** (proceso-algoritmo/coherencia/suficiencia re-teclean individual→colectivo + 4 reglas duras + contrato de reporte) → bloque común citado.
- **M5 · `CONVENCIONES.md` §3 y §7 dicen lo mismo** (leyenda=árbol generado del README). Fusionar. **Riesgo cero.**
- **M6 · "append a bitácora con `>>` no Edit" re-tecleado ×5** (checkpoint, cerrar-slice, orquestar-fanout, unificar, cosechar) → enunciado canónico (dueño: orquestar-fanout) + punteros.

## BAJA / borderline
- B1 preámbulo git-guards (~10 líneas): la cláusula de dedupe DEBE ser self-contained (huevo-gallina: decide si siquiera se hace `source`) → no factorizar; el resto ya delega a `analizar-comando-git`. Bajo valor.
- B2 `mapa-cerebro §4` re-lista hooks por tier a mano (copia del MANIFEST) → impuesto de doc=realidad, no bug.
- B3 sprawl de `docs/` (12 auditoria-*.md + 3 de flowcharts) → logs append-only, no unificables; un índice/poda ayudaría a legibilidad.

## 🔴 HAZARD adjacente (no es redundancia, nace de ella)
El texto de normas TIENE fuente única real: `brain/norms/global-claude-md.md`, que `install-brain.sh` inyecta
entre marcadores en `~/.claude/CLAUDE.md` y REFRESCA. Casi toda "duplicación norma↔CLAUDE.md" es
fuente→artefacto, NO redundancia. PERO **no hay guard que proteja el bloque inyectado**: editarlo a mano
driftea en silencio y se sobreescribe en el próximo refresh. Amerita un aviso/guard análogo a
`proteger-fuente-cerebro` (que hoy solo cubre copias de hooks/skills). "Toda norma nace con su mecanismo."

## DELIBERADO — parece redundante, NO TOCAR
Copias `both` de guards (+ su cláusula de dedupe) · libs ya compartidas (juez-comun/analizar-comando-git/
delegacion-comun/drift-cerebro-comun/ramas-zombie/detectar-secretos) · el norm-block inyectado (fuente única)
· copias-correo en CLAUDE.md de repos instanciados (self-contained para quien clona sin brain) · receta git
single-sourced en cerrar-slice (los demás REFERENCIAN) · fronteras checkpoint/cerrar-slice, dupla
coherencia/suficiencia, trío de cosecha, VISTA vs ZOOM (decisión humana marcada en CONVENCIONES:116-121).

## RANKING ACCIONABLE
1. A2 + M5 (prosa, riesgo cero, drift real). 2. A3 + M6 (bloques de skills → dueño+punteros). 3. M2 + M3
(código, hogar ya existe). 4. A1 + M1 (mayor volumen, requiere decidir `nudge-comun`/`emit-comun` + su tier).
5. HAZARD (guard del bloque de normas inyectado).
