# Auditoría de SISTEMA — 04 · Delegación / orquestar-fanout
> 2026-09-08 (turno-nocturno) · 3 lentes ollama (think:false) + 2 builders ollama · flowchart 04 como zapato.
> Código: delegacion-gate, delegacion-registrar, delegacion-reporte, recordar-orquestar, delegacion-comun (lib), limite-gasto.

## APLICADO (verde, test-brain 748 PASS)
- **MEDIO · `delegacion-comun.sh:linea_cuota` mostraba snapshot RANCIO como "estado real"** → el ask del gate se apoya en esa línea. Fix (a49315d): marca "⚠️posible dato rancio" si el snapshot tiene >5 min de mtime.

## PARQUEADO (real, pero fix delicado / decisión de diseño → unjordi)
- **ALTO · `delegacion-gate.sh:soy_el_primero_del_lote` — ventana de coalescencia deja pasar hermanos SIN consentimiento** tras una NEGACIÓN del usuario o un crash del 1er gate antes del ask (el lock solo se libera al aprobar; durante los ~10s los hermanos pasan en silencio). REAL. **PERO el fix NO es trivial:** el builder propuso PID-aware, pero el 1er gate SALE por diseño justo tras emitir el ask → su PID muere de inmediato → un check de PID-vivo recicla el lock siempre y ROMPE el coalescing (test-brain "G3 flood" lo cazó → revertido). El fix correcto necesita OTRA señal que distinga "salió tras preguntar" de "crasheó antes de preguntar" (p.ej. escribir un marcador DESPUÉS de emitir el ask, o reducir la ventana + fail-safe-ask). Para tu decisión.
- **MEDIO · `limite-gasto.sh` awk sin validar numérico** (five_pct/over_util) → si el snapshot trae basura, el freno no se activa. El fix es robustez, pero la DIRECCIÓN fail-safe (frenar) CONTRADICE la filosofía documentada del guard ("no frenar a ciegas" = fail-open ante duda). Decisión de diseño → tu OK (misma familia que el fail-open del overage, ya parqueado en audit-03/backlog).

## DESCARTADO (falso positivo del auditor, verificado contra código)
- El builder/auditor sugirió forzar metered si `DG_CLASE` vacío/desconocido. FALSO: `DG_CLASE` init="token" (clase LEGÍTIMA de Claude, NO desconocido), el `case` tiene `*)→metered`, y `DG_NIVEL` init="metered". La clasificación YA es conservadora por default; forzar metered rompería la clase "incluido".

## BAJOS → backlog: recordar-orquestar no resetea con delegación por Bash · delegacion-registrar registra consentimiento aunque el Task FALLE (depende de si el CLI da el status al PostToolUse) · limite-gasto 3ª ruta de state.json no documentada.

## Opus gate: DIFERIDO (el único abierto real es A1, parqueado con fix delicado; correrlo re-hallaría A1). Se cierra el 04 cuando unjordi decida A1/B2.
