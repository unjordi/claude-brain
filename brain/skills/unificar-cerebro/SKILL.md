---
name: unificar-cerebro
description: Ritual de RECONCILIACIÓN SEMANAL del cerebro del equipo — junta los aprendizajes+memorias de las minis de los devs hacia develop sin perder atribución ni voz ni romper guardrails. Inventaría el delta, baja primero el brain canónico, resuelve por clase, CURA el log (trenza solapes acreditando a ambos + gradúa lo maduro), verifica test-brain + lint, integra por el carril existente (OK explícito, sin auto-merge, con squash) y anota bitácora. Hermana de cerrar-slice, NO la extiende.
---

# Unificar el cerebro (reconciliación SEMANAL mini→develop)

Es la **capa SEMANAL** del ritual de cerebro: alguien designado (1 run/semana, o cuando unjordi lo
pide) reconcilia lo que las minis de los devs acumularon en `.claude/` hacia `develop` —
**aprendizajes** (prosa cosechada por `cosechar-sesion`) y **memorias** — sin perder QUIÉN aportó
qué, sin aplanar la voz, y sin tocar los guardrails delicados.

> **Objeto y disparador DISTINTOS de `cerrar-slice`** → es su HERMANA, no su extensión. `cerrar-slice`
> cierra un slice de CÓDIGO (build/tests/lint, un MR de feature). Ésta reconcilia PROSA+cerebro (no hay
> `dotnet build`; el "verde" es `test-brain.sh` + lint de memoria) y su disparador es *integrar la mini
> completa a develop*, no *terminar un slice*.

> **Regla de oro que atraviesa todo el ritual:** los **hooks/settings/skills CANÓNICOS del brain se
> rutean a `claude-brain`** (su MANIFEST es la fuente única) y bajan por `sincronizar-cerebro.sh`.
> **JAMÁS** viajan por el MR de la mini a develop. Lo que sube por este MR es MEMORIA+APRENDIZAJES, no
> cerebro canónico. (Un MR de mini que toque `.claude/hooks/*`/`settings.json`/`.brain-version` es un
> error de ruteo — sácalo en el Paso 1.)

## Disparadores
- Manual: `/unificar-cerebro` (el run semanal designado, o cuando unjordi lo pide).
- El hook `recordar-unificar-cerebro` (SessionStart) avisa —no bloquea— cuando el delta de `.claude/`
  de tu rama vs `origin/develop` supera el umbral (≥5 archivos o >7 días sin unificar).
- Encadenado desde `cerrar-slice` cuando la cosecha de un slice cae en `.claude/`.

## Paso 0 — Inventario del delta de cada mini
Para tu mini (y, en el modo-semana, fetch de las otras minis `Develop<Usuario>`), lista qué cambió en
`.claude/` vs develop y **clasifica cada archivo**:

```
git fetch origin --prune
git diff --stat origin/develop...HEAD -- .claude/
```

Clases:
- **Aprendizajes** (`aprendizajes.md`, `aprendizajes-*.md`) → log compartido, `merge=union`.
- **Notas atómicas / archivos propios** (un módulo, `estado-proyecto.md`, una decisión con ciclo
  propio) → van tal cual (raro que choquen).
- **Índices** (`MEMORY.md`, `skills/README.md`) → **NO se editan a mano**: `merge=ours` + regen.
- **CEREBRO canónico** (`.claude/hooks/*`, `settings.json`, `.brain-version`, skills-de-proceso del
  brain, `aprendizajes-*-brain.md`) → **NO sube por este MR**; se resuelve en el Paso 1.

## Paso 1 — Baja PRIMERO el brain canónico (sácalo del diff)
Antes de subir nada, sincroniza el cerebro canónico HACIA ABAJO en tu mini para que el diff quede
LIMPIO de cerebro:

```
bash <ruta-a-claude-brain>/brain/sincronizar-cerebro.sh . --apply
```

Esto pone la copia por-repo al día desde la fuente única. Los `aprendizajes-*-brain.md` (los que son
del brain, no del proyecto) se **mueven a claude-brain**, no a develop. Tras este paso, el delta que
queda para subir es SOLO memoria+aprendizajes del proyecto.

> Si el sync destapa que la mini tenía **ediciones locales de cerebro canónico** (un hook modificado,
> un exec-bit flipeado, una skill del brain borrada), eso NO se resuelve aquí subiéndolo: se enruta a
> un MR contra `claude-brain`. Anótalo y sepáralo.

## Paso 2 — Resuelve por CLASE (sin curar todavía)
- **Aprendizajes** → `merge=union`: se fusionan solos, no los toques a mano. (La curación es el Paso 3.)
- **Notas atómicas / archivos propios** → tal cual; si dos devs crearon el mismo slug (add/add),
  renombra uno.
- **Índices** → NO editar; `merge=ours` deja ganar a develop y el regen los rehace verídicos.
- **Cerebro canónico** → ya salió del diff en el Paso 1.

## Paso 3 — CURACIÓN del log (el corazón del ritual)
Sobre el `aprendizajes.md` ya juntado, haz DOS cosas. **Nunca reescribas prosa a ciegas** (norma
global anti-aplanado/destructivo): la máquina/tú DETECTAS candidatos y armas el andamiaje, pero la
VOZ de cada quien se preserva.

**(a) Trenza los solapes ACREDITANDO A AMBOS.** Cuando dos devs escribieron sobre lo mismo, elige uno
de 3 desenlaces — jamás fundir borrando una voz:
1. **Hermanas cross-linked** [DEFAULT, preserva 100% la voz] — deja ambos bloques, enlázalos entre sí
   (`> Ver también [[...]]`). Patrón `lecciones-migracion-cps` ↔ `-desde-cero`.
2. **Consolidada que CITA en bloque cada voz** — un bloque nuevo `aportó: a, b` que **cita
   textualmente** la prosa de cada quien (no la parafrasea), con las fuentes marcadas (no se borran).
3. **Tensión anotada** — cuando las dos calibraciones son OPUESTAS por-dev (p. ej. "arregla de corrido"
   vs "no pushees sin mi OK"): deja ambos bloques vivos + una línea `> Tensión con [[otra]]: <cuándo
   aplica cada una>`.

**(b) GRADÚA lo maduro a su hogar.** Un aprendizaje que ya se estabilizó deja de ser inbox y se
promueve:
- → **skill/hook del brain** si es un mecanismo genérico (rutéalo a `claude-brain`, no a develop).
- → **norma en `_PROTOCOLO.md` / `AGENTS.md`** si es una regla dura de proceso.
- → **archivo propio** si creció a un tema autocontenido (`modulo-x.md`).
Al graduar, deja en el inbox una marca de que se movió (o retíralo si ya vive íntegro en su hogar) —
pero eso es EDICIÓN curada y deliberada, distinta del append ciego que hace `cosechar-sesion`.

## Paso 4 — Verifica (el "verde" del cerebro)
NO hay build. El verde técnico aquí es:
- `bash <claude-brain>/brain/test-brain.sh` → **0 FAIL** (incluye el drift-check del MANIFEST/widget).
- Lint de memoria: frontmatter válido, todo enlazado desde `MEMORY.md`, sin `*.local.md` colado, sin
  rutas muertas, cada entrada de `aprendizajes.md` termina en línea en blanco.

**Verde técnico ≠ LISTO** — es peldaño necesario, no la meta.

## Paso 5 — Integra a develop por el carril EXISTENTE
Promover `Develop<Usuario> → develop` es integración COORDINADA:
- MR `Develop<Usuario> → develop`, con **OK EXPLÍCITO de unjordi** (lo exige `confirmar-merge-develop`),
- **SIN `--auto-merge`**,
- **CON `--squash`** y mensaje curado que **acredita a los devs** cuyo trabajo se integra (lo exige
  `merge-squash-guard`).

**NO toques ni aflojes `confirmar-merge-develop` ni `merge-squash-guard`** — este ritual pasa por ellos,
no los evade. Si el candado frena pidiendo confirmación y ya la tienes, cítala; no la fabriques.

## Paso 6 — Post-merge
- Regenera los índices (`MEMORY.md`, `skills/README.md`) si hubo notas/skills nuevas.
- Consolida `estado-proyecto.md` (single-writer: lo hace el integrador, una vez, desde la bitácora).
- **Appendea una línea a `bitacora.md` con `>>`** (append-only, `merge=union` → parallel-safe; nunca
  un Edit que reescriba): qué se unificó, de qué minis, qué se graduó.

> Recuerda: los aprendizajes graduados a **skill/hook/norma del brain** se rutean a `claude-brain` por
> su propio MR — no por el de la mini. El MR de la mini lleva memoria+aprendizajes del proyecto.
