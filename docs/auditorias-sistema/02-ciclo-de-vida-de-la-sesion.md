# Auditoría de SISTEMA — 02 · Ciclo de vida de la sesión
> 2026-09-08 · barrido proceso-por-proceso del cortex (ollama qwen3.8:27b local, 3 lentes, think:false) · flowchart 02 como zapato, CÓDIGO como verdad.
> Código auditado: `sesion-inicio.sh`, `rehidratar-hilo.sh`, `aviso-contexto.sh`, `exportar-sesion-master.sh`, `dod-verificar.sh` (SessionStart/Stop lifecycle).
> ⚠️ Hallazgos = CANDIDATOS; cada C/A/M verificado contra código en el merge.

## RONDA 1 — triage (cada hallazgo verificado contra el código real)

**ARREGLADO:**
- **ALTO (suficiencia) · `exportar-sesion-master.sh:142-144` · export sin verificación de integridad** → un `.gz` corrupto/truncado (node crasheó a media escritura) se copiaba al drive SOBREESCRIBIENDO el backup bueno → reventaba al `claude --resume`. **Fix (332c6ed):** `gzip -t` antes del `cp`; un gz inválido NO pisa el backup válido; el meta acompaña solo a un gz válido. Verificado bash -n.

**FALSO POSITIVO (descartado con evidencia):**
- **ALTO (proceso) · `dod-verificar.sh` · "B2 antes del candado principal = evasión"** → FALSO. El orden B2-antes-del-candado es INTENCIONAL (declarar QA visual a ciegas es el daño en sí, independiente del código — L256-263). La "evasión turno-2-sin-código" que describe NO la crea B2: la crea la medición de "código tocado SOLO en el turno actual" (L268-289), que es DISEÑO DELIBERADO documentado (un cierre en un turno posterior sin código no se re-gatea — si no, cada turno quedaría gateado para siempre). El turno 1 SÍ se bloquea. No es hueco de B2. **Además `dod-verificar` es un guard de SUPERVISIÓN → no se toca sin OK explícito de unjordi (Integridad de guardarraíles).**

**DEFERIDO a backlog #20 (reales, pero accepted-tolerance / frágil-self-correcting / doc / guard):**
- **medio · `aviso-contexto.sh` ventana hardcodeada por lista de modelos** → un modelo 1M-nativo nuevo no listado se reporta como 200K (engañoso por debajo de 200K). MITIGA: auto-corrección `ctx>WINDOW→1M` (solo arriba de 200K). Frágil pero no peligroso (no sub-reporta el riesgo). Fix = leer ventana real / warning si modelo desconocido.
- **medio (coherencia, YA en backlog #9) · `dod-verificar.sh` B2 no reconoce Read de PNG en algunos casos** → guard-precision recurrente; su tuning vive en la campaña de guards (#9), y cambiar el guard exige OK de unjordi.
- **bajo · `exportar-sesion-master.sh` lock orphan** → YA tiene tolerancia de 30min (L134, diseño aceptado); PID/heartbeat lo bajaría a instantáneo (refinamiento, no bug).
- **bajo · `dod-verificar.sh` juez LLM fail-open sin diagnóstico** → deliberado (fail-open del brain); falta un comando de health-check + doc. Guard → OK de unjordi.
- **bajo · `sesion-inicio.sh` orden fijo de archivos de estado** (inyecta el primero encontrado).
- **bajo · `rehidratar-hilo.sh` detección de rama por regex frágil** → si `checkpoint` cambia el formato, cae al proxy de edad (mtime>12h) → FP de "obsoleto". Fix = formato robusto / test del formato de `hilo-mental-actual.md`.
- **bajo (fidelidad .dot) · leyenda 02** no refleja el fail-open de dod-verificar si el juez LLM no está + falta doc de recuperación del `index.lock` (nodo RACE).

## Estado
Ronda 1: 1 alto arreglado (integridad del export), 1 alto FP descartado (no se tocó el guard de supervisión), resto → backlog #20. Pendiente: ronda 2 (confirmar convergencia con el fix) → Opus gate.
