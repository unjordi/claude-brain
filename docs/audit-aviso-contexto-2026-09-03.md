# Auditoría READ-ONLY — ¿el rediseño "reportero tonto" (b479ac9) eliminó los FP de aviso-contexto?

**Auditor:** sesión Claude (fork de análisis), 2026-09-03. Alcance: solo lectura de
`brain/hooks/aviso-contexto.sh`, `docs/rediseno-aviso-contexto-2026-09-01.md`, `brain/test-brain.sh`,
el corpus de FP (canónico en `docs/guards-falsos-positivos.md` + el archivo per-máquina retirado
`~/.claude/memory/guards-falsos-positivos.md`) y los flowcharts/doc que describen el hook. Cero cambios.

## Veredicto corto

**El rediseño SÍ cumplió su promesa central** (dejó de derivar un techo ventana×pct y de gritar bandas
ℹ️/⚠️/🚨 con "INMINENTE") — eso está bien lockeado por tests (`brain/test-brain.sh` líneas ~3002-3006).
Pero **unjordi tiene razón: sigue dando falsos positivos**, por TRES vías distintas que el rediseño no
tocó, más una incoherencia de documentación y un hueco de proceso:

1. **Staleness post-compact — SIGUE VIVO** (el más grave; es justo el bug que se creía resuelto).
2. **El % reportado se queda corto vs `/context`** por la granularidad del debounce (50K), no por un
   error de medición — pero el usuario lo experimenta como "el hook miente el número".
3. **El "Recordatorio" final SÍ es un veredicto**, no un dato crudo — contradice la premisa del rediseño
   aunque no sea una banda escalada.
4. Múltiples diagramas y `docs/mapa-cerebro.md` siguen describiendo el diseño VIEJO (bandas, techo
   derivado, "compacta TÚ ahora antes del auto-compact-sorpresa") — doc que miente sobre el código actual.
5. El FP de staleness (2026-09-01) quedó **huérfano**: se escribió en el archivo per-máquina que la norma
   había RETIRADO un día antes (commit `15ce970`, 2026-08-31), así que nunca llegó al corpus canónico en
   git y nadie lo trianó — explica por qué "se suponía resuelto" pero nadie volvió a mirarlo.

---

## 1. Staleness post-compact (FP más grave, confirmado post-rediseño)

**Mecanismo en el código** (`brain/hooks/aviso-contexto.sh:39-43`):

```bash
ctx=$(tail -n 400 "$tp" 2>/dev/null | jq -rR '
    fromjson? | select(.isSidechain != true) | (.message.usage // empty)
    | (.input_tokens // 0) + (.cache_creation_input_tokens // 0) + (.cache_read_input_tokens // 0)
  ' 2>/dev/null | tail -1 | tr -cd '0-9')
```

Toma literalmente el **último objeto `usage` no-sidechain** de las últimas 400 líneas del transcript en
disco. No hay NINGÚN filtro que distinga "un turno conversacional normal" de "la llamada interna de
resumen que el propio `/compact` dispara para generar el resumen" — y esa llamada de resumen necesita
mandar TODO el contexto pre-compact para poder resumirlo, así que su `usage.input_tokens` **es del
tamaño completo pre-compact**, no del contexto ya comprimido.

Si el hook se dispara (por el siguiente PostToolUse) ANTES de que exista un turno nuevo con un `usage`
ya pequeño (post-compact), el "último usage" que `tail -1` agarra sigue siendo el de esa llamada de
resumen gigante → el hook reporta el tamaño VIEJO como si fuera el actual.

**Evidencia empírica, y es POSTERIOR al rediseño:** el FP quedó registrado así:

> `~/.claude/memory/guards-falsos-positivos.md` (mtime 2026-09-01 16:53):
> "2026-09-01 · aviso-contexto · disparó a "~94% (944K)" INMEDIATAMENTE despues de un /compact recién
> completado · el hook mide el tamaño del transcript en disco (que aún trae las líneas pre-compact), no
> el contexto vivo → tras compactar reporta el valor VIEJO y pide otro checkpoint/compact en falso"

El rediseño `b479ac9` es de las **14:06** del mismo día; el commit que lo estabiliza en tests (`ea55cfc`,
"suite verde reconciliando al rediseño") es de las **16:08**. El FP se escribió a las **16:53**, es decir
**después de ambos commits** — con la versión ACTUAL del hook (mide `usage` real, ya sin techo
fantasma). El diagnóstico del FP ("mide el tamaño del transcript en disco... trae líneas pre-compact")
es la descripción de un síntoma correcto aunque el mecanismo preciso (arriba) sea más fino que "tamaño
del archivo": es el ÚLTIMO `usage` real, pero ese último `usage` real es el de la llamada de resumen
pre-compact, no una medición de bytes del archivo.

**Por qué el rediseño no lo tocó:** el rediseño (`b479ac9`) cambió QUÉ se reporta (quitó el techo
derivado y el % override fantasma) pero **no tocó CÓMO se localiza "el usage actual"** — sigue siendo
`tail -n 400 | ... | tail -1`, exactamente la lógica de antes de julio (commit `b2bf4f9`, "medir el
llenado por TOKENS reales"). El bug de staleness es ortogonal al problema que el rediseño resolvió
(veredictos fantasma) — vive en la SELECCIÓN del dato crudo, no en su interpretación. "Reportero tonto"
solo garantiza que no se INVENTE un juicio sobre el dato; no garantiza que el dato mismo sea fresco.

**Cobertura de test:** el test de "compact" en `brain/test-brain.sh:2979-2980` (`gen_ctx 80000` tras
`gen_ctx 150000`) solo verifica que el DEBOUNCE se re-arma cuando el `ctx` sintético BAJA — nunca
simula el escenario real (una llamada de resumen con `usage` grande siendo la última línea justo tras
compactar). El bug reportado por unjordi NO tiene ningún test que lo hubiera cazado.

## 2. Discrepancia "~71-72%" del hook vs "75%" de `/context`

No parece ser un error de aritmética (`brain/test-brain.sh` línea `math_check` valida la fórmula exacta
`pctw = ctx*100/window`, entera, y cuadra). La causa más probable es el **debounce grueso por escalones
de 50K** (`aviso-contexto.sh:80-91`, `STEP=50000`): el hook solo EMITE mensaje al cruzar un escalón
nuevo, así que el número que el usuario LEE quedó congelado en el momento del último cruce — y puede
haber seguido subiendo sin emitir nada hasta cruzar el siguiente escalón. En una ventana de 1M, un
escalón de 50K es **5 puntos porcentuales** de holgura — exactamente el orden de la brecha observada
(71-72% vs 75% ≈ 3-4 puntos). No es que el hook "mienta" el dato en el momento en que lo calculó; es que
lo calculó una vez y no lo vuelve a anunciar hasta el siguiente escalón, mientras `/context` sí es
on-demand y siempre fresco. Esto es un efecto secundario del diseño "silencioso, no ruidoso" — legítimo
como trade-off, pero no está documentado como tal en `docs/rediseno-aviso-contexto-2026-09-01.md`
(que solo lista 4 "residuos BAJO aceptados", y este no es uno de ellos).

## 3. El "Recordatorio" final es un veredicto residual, no dato crudo

`aviso-contexto.sh:102`:
```
"Recordatorio: sin checkpoint el auto-compact te BORRA el cerebro fresco → mejor checkpoint + /compact, y TÚ decides cuándo (/context manda)."
```

El design doc promete explícitamente "**Sin veredicto de urgencia inventado**" y "el hook es un
REPORTERO TONTO de datos, **NO un juez**". Esta línea es fija (no varía con el nivel de `ctx`: sale
IGUAL a 55% que a 95%), así que no reintroduce las BANDAS escaladas que el lock-in test (b6-neutro,
líneas 3002-3006) sí vigila (`INMINENTE|holgura|DELIBERADO|...|banda`) — por eso pasa el test. Pero
sigue siendo una recomendación de acción ("mejor checkpoint + /compact") inyectada por el hook mismo, no
un dato. Es un veredicto NO graduado en vez de un veredicto graduado — cumple la letra del lock-in test
(que solo busca ciertas palabras/emoji de banda) pero no el espíritu de "dato crudo, cada quién decide
cómo morirse" que el propio doc del rediseño enuncia como principio rector. Ningún test verifica la
AUSENCIA de esta frase o de cualquier imperativo — el lock-in solo bloquea el vocabulario viejo de bandas,
no bloquea que se cuele un imperativo nuevo.

## 4. Doc-código incoherente: varios artefactos describen el diseño VIEJO

Estos archivos siguen narrando el comportamiento PRE-rediseño (bandas de urgencia, techo derivado ×pct,
"compacta TÚ ahora antes del auto-compact-sorpresa") y no se tocaron en `b479ac9` ni `ea55cfc`:

- `docs/mapa-cerebro.md:89` — nodo `AC` describe "escala por banda (1 heads-up · 2 checkpoint AHORA · ≥3 inminente)".
- `docs/flowcharts/02-ciclo-de-vida-de-la-sesion.dot:124` — "técho DERIVADO = ventana × pct auto-compact (≈92%); bandas ℹ️/⚠️/🚨".
- `docs/flowcharts/05-continuidad-checkpoint-compact-rehidratar.dot:95` — mismo texto de bandas ℹ️76%/⚠️88%/🚨95%.
- Y la misma leyenda genérica "watermark: avisa 'compacta TÚ ahora' antes del auto-compact-sorpresa (GLOBAL)"
  se repite IDÉNTICA en `docs/flowcharts/{01,03,04,06,07,08,09,10,11,12,13,14}-*.dot` (12 archivos) — todos
  heredan la descripción vieja de un único bloque de leyenda copiado, ninguno actualizado tras `b479ac9`.

Esto es exactamente el patrón "doc que miente" que la norma dura del propio cerebro prohíbe: el código YA
no deriva techo ni banda, pero 14 archivos de doc/diagrama siguen afirmando que sí.

## 5. Proceso: el FP de staleness quedó huérfano, nunca llegó al corpus canónico

El 2026-08-31 (commit `15ce970`) se migró el corpus de FP de `~/.claude/memory/guards-falsos-positivos.md`
(per-máquina) a `docs/guards-falsos-positivos.md` **dentro del repo cortex** — con el archivo viejo
BORRADO explícitamente ("Borrado el original per-máquina — evita dos fuentes de verdad") y la norma en
`brain/norms/global-claude-md.md` actualizada para apuntar solo a la ruta trackeada en git.

Al día siguiente (2026-09-01), la sesión que cachó el FP de staleness **volvió a escribir en la ruta
vieja retirada** (`~/.claude/memory/guards-falsos-positivos.md`, que se recreó con 5 entradas de ese
día, incluida la de `aviso-contexto`). Ese archivo **no está en git** y **no viaja a develop** — por eso
`grep aviso-contexto docs/guards-falsos-positivos.md` en el repo NO devuelve ese caso: el hallazgo quedó
atrapado en una máquina, exactamente el problema que la migración del día anterior buscaba evitar. Esto
explica en buena parte por qué el bug "se sentía resuelto" (el rediseño se declaró CONVERGIDO el mismo
2026-09-01 en el propio doc de rediseño) mientras el FP real seguía sin llegar al lugar donde se trianan
los FP con ~5 casos del mismo guard.

---

## Resumen para acción (no ejecutado — solo se reporta)

| # | Hallazgo | Severidad | Dónde |
|---|----------|-----------|-------|
| 1 | Staleness post-compact: última línea de `usage` puede ser la llamada de resumen pre-compact | ALTO | `brain/hooks/aviso-contexto.sh:39-43` |
| 2 | Debounce de 50K produce lag de hasta 5pp vs `/context` | BAJO/esperable, no documentado como trade-off | `brain/hooks/aviso-contexto.sh:80-91` |
| 3 | "Recordatorio" final es un veredicto no graduado, sin test que lo vigile | MEDIO | `brain/hooks/aviso-contexto.sh:102` |
| 4 | 14 archivos de doc/diagrama narran el diseño de bandas ya retirado | MEDIO (doc miente) | `docs/mapa-cerebro.md`, `docs/flowcharts/*.dot` |
| 5 | El corpus de FP recreó el archivo per-máquina retirado; el caso de aviso-contexto nunca llegó al corpus canónico | MEDIO (proceso) | `~/.claude/memory/guards-falsos-positivos.md` vs `docs/guards-falsos-positivos.md` |
