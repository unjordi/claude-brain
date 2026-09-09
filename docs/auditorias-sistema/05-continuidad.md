# Auditoría de SISTEMA — 05 · Continuidad (checkpoint / compact / rehidratar)
> 2026-09-08 (turno-nocturno) · 3 lentes ollama (think:false) · flowchart 05 como zapato.
> Código: rehidratar-hilo.sh, aviso-contexto.sh, skills checkpoint + rehidratar-hilo. SOLAPA con el proceso 02.

## Ya cubierto por procesos previos
- rehidratar-hilo regex de rama → YA ARREGLADO (50d87d3, ancla a `· rama`, ignora prosa, portable) en el barrido del proceso 02.
- aviso-contexto ventana hardcodeada por lista de modelos → YA en backlog #20 (self-correcting arriba de 200K).

## PARQUEADO / ANOTADO (real, pero edge o requiere cambio de skill/CLI)
- **ALTO · rehidratar-hilo falla SILENCIOSO sin `jq`** (emite printf crudo que el canal SessionStart ignora → el hilo NO se reinyecta tras compact). REAL, pero `jq` es REQUISITO DURO del brain (install-brain avisa, bootstrap lo instala) → sin jq se rompen MUCHAS cosas, no solo esto. Consistente con la postura "jq obligatorio". Mejora posible: aviso ruidoso a stderr / fallback node-python para el JSON. Bajo en la práctica. → nota.
- **MEDIO · coupling skill-checkpoint ↔ hook-rehidratar:** el hook parsea `· rama <x>` pero el skill `checkpoint` no garantiza escribir EXACTAMENTE ese formato (si el modelo omite el `·` o usa guion, el hook no extrae la rama → cae al proxy de mtime → puede marcar fresco/obsoleto mal). **FIX ACCIONABLE (vale la pena, daytime): un test de integración** que tome el formato documentado del skill checkpoint y lo pase por la extracción del hook, aseverando que casa (locking del 50d87d3). Además: fijar en el skill checkpoint el formato byte-exacto del footer. → backlog.
- **MEDIO · regla de OVERFLOW del checkpoint (>~200 líneas) [SIN CONFIRMAR]:** sin mecanismo automático de detección/corte a overflow.md ni límite real confirmado del CLI. Si el hilo crece mucho, la cola (donde vive "Siguiente paso") podría truncarse. → confirmar el límite del CLI + check en el skill/hook. backlog.

## Sin C/A/M nuevo ACCIONABLE-en-código esta noche (el regex ya estaba arreglado; el resto = edge/skill/test).
Opus gate: DIFERIDO (findings = overlap-ya-arreglado + edge de jq + coupling que se cierra con un test daytime).
