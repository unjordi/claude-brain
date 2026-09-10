# Auditoría — continuidad del hilo (checkpoint/compact/rehidratar/aviso-contexto) · 2026-09-09

> Dictámenes de 2 auditores Claude (skill `auditar-proceso-algoritmo`): lente PROCESO/adopción + lente
> MECANISMO/algoritmo. Convergen. Read-only. Pendiente: DECISIÓN de unjordi + el 3er auditor (redundancias, otro tema).

## CAUSA RAÍZ (ambos) — "norma sin mecanismo" + falla INVISIBLE
El checkpoint es 100% disciplina del modelo; nada fuerza ni NOTA entrar a compact sin hilo fresco; y
`rehidratar-hilo.sh:54` (`[ -f "$HILO" ] || exit 0`) **sale en silencio** si el hilo está AUSENTE → tras un
compact sin checkpoint, nadie (ni modelo ni unjordi) se entera de que se perdió el hilo → **el loop de
aprendizaje nunca se cierra** → saltarlo no cuesta nada visible → se salta. Es el opuesto exacto de
`hud-stale`/`delegacion-reporte`, que gritan (advisory) justo cuando el costo aparece.
Matiz de precisión: el auto-compact NO es wipe total — `# Compact instructions` sí se re-lee; se pierde el
DETALLE procedimental (el "cómo"), no todo. Degradación con pérdida, no borrado.

## HALLAZGO CLAVE NUEVO (no estaba en el prior art) — el material de rescate YA sobrevive
El `.jsonl` del transcript es **append-only y NO se trunca al compactar** (lo prueba `aviso-contexto.sh:46`
que hace `tail -n 400` anclado al boundary). El compact reemplaza el CONTEXTO del modelo, no el archivo.
→ Cuando el auto-compact "pierde el hilo", el hilo crudo **sigue en disco a un `tail` de distancia**. Esto
convierte el arreglo de "regaño" en "rescate" y es 100% bash (cero modelo, cero costo).

## RECOMENDACIONES (verdicto cruzado)
- **Rec3 = LA GANADORA (ambos): hacer VISIBLE la falla en `rehidratar`.** En `SessionStart(source=compact)`,
  si el hilo está AUSENTE/incompleto **y** el repo usa el sistema (gate tipo hud-stale: existe
  `estado-proyecto.md`): emitir un aviso por **`systemMessage`** (VISIBLE — no `additionalContext`, que es
  pasivo) que (a) nombre la falla ("compactaste sin hilo fresco") y (b) **apunte al material que sobrevivió**
  (la cola del transcript / estado-proyecto / bitácora). Cierra la causa raíz, en-canal, cero costo.
- **Mecanismo por CADENCIA (ambos, análogo a Hermes ~cada 10 turnos): `Stop`-hook `type: command` (NO agent)**
  que cada N turnos/tokens (dato que aviso-contexto ya calcula) inyecte por `additionalContext` un nudge
  mecánico "vuelca el hilo" — sin llamada de modelo, sin costo por turno. Es "toda norma nace con su mecanismo".
- **Rec1 (aviso-contexto escalar): descartar la versión "escalar"** — se filtra (cry-wolf en cada escalón de
  50K), cruza el charter "termómetro tonto" (2026-09-01, necesita OK), y NO cubre el auto-compact sorpresa.
  A lo sumo, con OK de unjordi, un HECHO NEUTRO ("no hay hilo fresco en disco"), pero rinde más en Rec3.
- **Rec2 (peldaño MICRO): descartar** — es cambio de doc, no toca el enforcement; no ataca la raíz.
- **`type: agent` hook (hook que resume solo): REFUTADO como primaria** — costo por turno (Stop dispara
  cada turno), write-tools SIN confirmar, reintroduce el "default invisible" (villano del SINTESIS), no
  cubre auto-compact. Si se explora → probe previo obligatorio + archivo SEPARADO (`hilo-mental-crudo.md`)
  para no pisar el checkpoint manual (gold).

## FIXES DE PRECISIÓN (independientes, bajo riesgo)
- **F3 (MEDIO) concurrencia:** `aviso-contexto` keyea `.contexto-aviso` por REPO, no por sesión → thrash con
  sesiones concurrentes (unjordi corre muchas). `hud-stale` (mismo autor) ya lo resolvió con `session_id`.
  Fix: `.contexto-aviso-<sid>`. Precisión, no toca política.
- **F4 (BAJO) gate de frescura frágil:** `rehidratar` parsea la rama de PROSA que el modelo escribe a mano;
  si el formato varía → cae al proxy de 12h → falso "OBSOLETO" en sesión larga misma-rama. Fix: `checkpoint`
  escribe la rama en formato máquina-parseable (`<!-- rama: X -->`), `rehidratar` la lee de ahí.
- **Flowcharts 05 y 02 INCOMPLETOS/mienten (doc≠realidad):** 05 no dibuja las 2 transiciones de pérdida
  (auto-compact-bypass, absent-silent); 02 el arco de aviso-contexto dice "propón /compact" pero el código
  rehúsa (se contradice con su propio nodo "reportero tonto"). Corregir los .dot.

## VERIFICAR ANTES DE CONSTRUIR (load-bearing, no medido)
Probe de 5 min con `--include-hook-events`: ¿el **auto-compact** emite `SessionStart(source=compact)`? Toda
la estrategia Rec3 lo asume (inferido de la doc, no medido). Si no lo emite, la mitad LEER está ausente
justo cuando más se necesita.

## ESTRATÉGICO (mecanismo auditor) — no sobre-invertir
`axon/docs/arquitectura/parches-cortex-a-nativo.md` CLUSTER A: los 6 parches del lado-CC (checkpoint,
rehidratar, # Compact instructions, aviso-contexto, sesion-inicio, exportar-sesion) existen por UNA flaqueza
— CC es dueño del historial y compacta con pérdida sin turno de modelo. El estado del arte (DeepSeek/OpenHands)
es **log append-only inmutable como fuente de verdad; el prompt se DERIVA por fold; compactar = APPENDAR un
evento-resumen, nunca mutar**. En axon esos 6 parches se vuelven NO-OP. → Invertir lo MÍNIMO para detener el
sangrado invisible (Rec3+visible + cadencia); dejar que el event-stream de axon lo disuelva.

## PLAN DE CAPAS PROPUESTO (bajo→alto riesgo)
1. Rec3 refinada (systemMessage + gate-sistema + apuntar al transcript) — cero costo, sin charter. **YA.**
2. Stamp de "distancia desde el último checkpoint" (turnos/mtime) — habilita frescura real + cadencia. Barato.
3. Nudge por cadencia (`Stop` command) — el mecanismo que la norma no tiene. Bash, sin modelo.
4. F3 (session_id) + F4 (rama parseable) + corregir los 2 .dot. Precisión.
- NO: Rec1-escalar, Rec2, `type: agent` (salvo probe + OK explícito).
