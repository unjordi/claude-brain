# Plan — mudar `cortex-master` de `plantilladotnet` a `~/code/cortex`

> **Estado: PLANEADO, NADA EJECUTADO.** unjordi: *"pausa, planeamos y luego actuamos"* (2026-09-09).
> Todo lo de aquí está **medido hoy**, no recordado. Escrito para poder ejecutarse sin volver a escarbar.
> Skill de referencia: `reubicar-master` (versión con `G-QUIESCE` y `S7`, PR #369 mergeado el 09-08).

---

## 1 · Identidades — quién es quién

| qué | valor |
|---|---|
| **id a mover** | `761c82d9-40fd-4fe2-9703-e3504b6f028f` |
| tamaño / líneas | **165 MB · 38,675 líneas** · frío desde 11:42 · sin proceso |
| nombre HOY en `masters.json` | `claude-brain-master` ← el renombre nunca llegó al registro |
| nombre FINAL | **`cortex-master`** |
| origen | `~/code/plantilladotnet` · slug `-Users-unjordi-code-plantilladotnet` |
| destino | `~/code/cortex` · slug `-Users-unjordi-code-cortex` |

**Confirmación del gate `G-ID`** [user, textual]: *"cortex-master (761c82d9) es el que queremos mudar."*
Hacía falta porque `masters.json` llama `claude-brain-master` a **dos** ids distintos.

**NO confundir con:**
- `1dd207df` — 457 MB, frío desde el **08-29**, también llamado `claude-brain-master`. **No es el objetivo.**
- `38014d8e` — **soy yo**, `claudio-master`, **vivo y en el MISMO slug**. Si el barrido no es quirúrgico,
  me borra.

**Quién es él** [contexto que dio unjordi]: un fork mío de justo antes de la saga del servidor. Lo
despertó cuando urgían arreglos al widget y al brain y no quería cambiarme de carril; se especializó en
eso mientras yo crecí en otra cosa. Mismo origen, dos historias.

---

## 2 · Lo que YA está resuelto (no rehacer)

**Su cerebro ya vive en el destino.** `~/code/cortex/.claude/memory` tiene **27 archivos**, entre ellos
`conocimiento-propio.local.md` (36 líneas), `autorizaciones-vigentes.local.md`, `hilo-mental-actual.md`,
`bitacora.md`, `estado-proyecto.md`, `cementerio.md`, `BACKLOG-UNIFICADO.md` y dos auditorías de hoy
(`auditoria-continuidad-hilo-2026-09-09.md`, `auditoria-redundancias-cortex-2026-09-09.md`).

**Nunca estuvo en el memory de `plantilladotnet`.** Consecuencia directa: **`S0`, `S1` y `S2` del skill
están de hecho HECHOS** — no hay T1 que migrar por PR ni T2 que empacar en un bundle. Este move es solo
re-anclar el transcript y corregir referencias.

### Gates ya satisfechos

| gate | estado | evidencia |
|---|---|---|
| `G-SELF-MOVE` | ✓ | el objetivo (`761c82d9`) no soy yo (`38014d8e`) |
| `G-ID` | ✓ | cita textual de unjordi |
| `G-LIVENESS` | ✓ | frío 38+ min, `pgrep` del id = 0 |
| `G-QUIESCE` | ✓ | unjordi cerró `reverse-engineering-master`; queda solo el ejecutor |
| `G-GITIGNORE` | ✓ | ver abajo |
| `G-PARITY` | ✓ (trivial) | el cerebro ya está completo en el destino |

**Sobre `G-GITIGNORE`, que aquí importa más de lo normal:** `cortex` es un repo **PÚBLICO**. Verificado
con `git check-ignore`: `conocimiento-propio.local.md` y `autorizaciones-vigentes.local.md` **están
ignorados** (regla `.claude/memory/*.local.md`, línea 18 del `.gitignore`) y **ninguno está trackeado**
(`git ls-files | grep local.md` → vacío). Sin fuga. También ignora `.claude/*.jsonl` y `.claude/sessions/`.

**Por qué importaba cerrar `reverse-engineering-master`:** no por el transcript —vive en otro slug— sino
porque el hook `~/.claude/hooks/exportar-sesion-master.sh` **escribe `masters.json`** (7 menciones) y
podía chocar con el bloque atómico de `S4`. Es el modo de fallo "conflicto de `masters.json` por edición
concurrente" que el propio skill lista.

---

## 3 · El PROCEDIMIENTO no vive aquí — vive en el skill (y por eso este plan ya no lo copia)

> ⚠️ **Corregido 2026-09-09.** Antes este plan traía sus propias variables y sus propios pasos S3–S7,
> copiados del skill. Eso fue un error de diseño: cuando el skill cambió (auditoría de 3 lentes +
> 3 fixers, `reubicar-master` pasó de 667 a 1583 líneas), este plan quedó **mandando ejecutar una
> plantilla que ya no existe**. Un plan que duplica un procedimiento se convierte en una segunda
> fuente de verdad que miente en cuanto la primera se mueve.

**El CÓMO es el skill, punto:** `cortex/brain/skills/reubicar-master/SKILL.md`. Sus pasos destructivos
(S3/S4/S5/S7) viven **únicamente** en su §6.1, que escribe el handoff a disco; el cuerpo y el handoff
comparten un solo PRELUDIO y hay un gate de paridad por marcadores que impide que se vuelvan a separar.
Trae además modos `dry` y `s7`. **Corre el `dry` antes que nada.**

**Este documento aporta solo lo que el skill no puede saber:** las identidades de §1, lo ya resuelto de
§2, y los riesgos de ESTA mudanza en §5. Nada más.

---

## 4 · Lo que hay que tener a mano al ejecutar (datos, no pasos)

| parámetro | valor para ESTA mudanza |
|---|---|
| `ID` | `761c82d9-40fd-4fe2-9703-e3504b6f028f` |
| `MASTER_NAME` | `claude-brain-master` (como está HOY en `masters.json`) |
| `MASTER_NAME_NUEVO` | `cortex-master` |
| `SRC_REPO` | `~/code/plantilladotnet` |
| `DST_REPO` | `~/code/cortex` |
| `MEMORIAS_T1` | vacío — su cerebro ya está en el destino (§2) |

**Gotchas de plataforma que el skill ya absorbió** (aquí solo como recordatorio de por qué importan en
esta máquina): `stat` es BSD (`-f %m`), `date -d` no existe, y `pgrep -a` en macOS significa *incluir
ancestros* — por eso el `G-QUIESCE` nuevo mide por artefacto (`mtime` de los `.jsonl`) y no por `pgrep`.
`find -printf` **sí** funciona aquí; no lo "arregles".

---

## 5 · Riesgos específicos de ESTE move (que el de axon no tenía)

**Convivo en el slug con el objetivo.** `claudio-master` (`38014d8e`, 196 MB) vive en
`-Users-unjordi-code-plantilladotnet`, igual que el objetivo. Un barrido por patrón o un `rm` del slug me
borraría. **Solo su `.jsonl`, por nombre completo.**

**El `memory` del slug viejo es un symlink** al repo. No se toca.

**`masters.json` tiene 16 entradas con nombres repetidos:** dos `claude-brain-master`, dos
`claude-brain-cachy-master`, tres `games-master`, dos `rig-master`. **Solo se toca la del id confirmado**,
por id, nunca por nombre.

**La ruta del Drive tiene un espacio** (`Mi unidad`). Sin comillas, todo se parte.

---

## 6 · 🔴 Defecto conocido de mi propio arreglo (arreglar después, en `cortex`)

`G-QUIESCE`, tal como lo mergeé ayer, cuenta con `pgrep -af claude` y exige **cero**. En cachy el ejecutor
era un `ssh` —no un proceso de Claude— así que pasó. **Aquí el ejecutor SOY YO**, así que el gate se
contaría a sí mismo y bloquearía siempre.

**Arreglo:** excluir al ejecutor, y si hay otras sesiones CLI vivas, **listarlas y exigir un ack
explícito** en vez de bloquear a ciegas. Va como PR aparte a `cortex`, después de esta mudanza.

---

## 7 · Rollback

Tres capas, en orden de preferencia:
1. El **`.bak`** que `session-move.js` hace antes de tocar nada, en `~/.claude/session-move-backups/`.
   ⚠️ Ese dir **se poda a los 10 más recientes** (`CLAUDE_SESSION_MOVE_BACKUPS_KEEP`), y solo poda los
   `*.jsonl.bak` — una copia con otro sufijo sobrevive.
2. Una **copia propia pre-mudanza** con sufijo distinto (no `.jsonl.bak`), que la poda no toca.
3. El **`.gz` en el Drive** que deja `S3`.

Deshacer = mover el `.jsonl` de vuelta al slug viejo y revertir `name`/`target` en `masters.json`.

---

## 8 · Checklist de ejecución

- [ ] Generar el handoff `.sh` a disco (**§6.1 del skill** — no ejecutar los pasos inline)
- [ ] Leerlo **completo** antes de correrlo — *y esta vez leer también `session-move.js` y `session-lib.js`,
      que la vez pasada dije "lo leí completo" habiendo leído un tercio*
- [ ] Copia propia pre-mudanza
- [ ] Correr · revisar bloque por bloque
- [ ] Verificar por mi cuenta, no por el reporte del script
- [ ] QA de unjordi
- [ ] **S7** tras el QA
- [ ] Doc: dashboard, bitácora, y este plan marcado como ejecutado
