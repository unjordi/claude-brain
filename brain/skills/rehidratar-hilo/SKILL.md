---
name: rehidratar-hilo
description: Retoma el HILO MENTAL de la tarea tras un /compact o corte — ANUNCIA en una línea de qué íbamos y CONTINÚA desde el "Siguiente paso". Reusa la MISMA lógica del hook SessionStart homónimo (corre su .sh, no la re-implementa → sin drift) y le agrega lo único que el hook no puede: anunciar + retomar (el additionalContext del hook es contexto PASIVO — el modelo lo absorbe pero no lo surface-a solo). Úsalo al retomar cuando quieras que el hilo se confirme y el trabajo siga, o como respaldo si el auto-rehidratado del hook no apareció.
---

# Rehidratar el hilo — anunciar + retomar (reusa la lógica del hook)

Tras un `/compact` o corte, el hook `rehidratar-hilo` (SessionStart, canal oficial `additionalContext`)
**ya reinyecta el hilo** en el contexto del modelo — es el patrón que la doc de Claude Code recomienda para
esto, NO un workaround. Pero ese `additionalContext` es **PASIVO**: el modelo lo lee como system-reminder
y lo TIENE, pero **no lo anuncia ni retoma solo** hasta que un turno se lo pida. Este skill es ese turno:
**confirma el hilo en voz alta y continúa el trabajo.**

> **Sin drift (importante):** este skill NO re-implementa la lógica de leer/validar el hilo — **corre el
> mismo `.sh` del hook** y usa su salida. La lógica (leer el archivo + gate de frescura + formato) vive UNA
> sola vez, en `rehidratar-hilo.sh`. Aquí solo va la capa de COMPORTAMIENTO (anunciar + retomar). Correr el
> `.sh` como comando NO depende del canal de hooks del CLI → sigue sirviendo de respaldo si ese canal se rompe.

## Cuándo
- Al **retomar tras un `/compact`/resume** y quieras que el modelo **confirme** el hilo y **siga** (no que lo
  tenga en silencio).
- Como **respaldo** si NO ves señal del hilo (el hook no disparó, sesión vieja, o un update del CLI rompió el canal).

## Pasos
1. **Obtén el hilo corriendo la lógica del hook** (fuente única; feed de stdin para que no cuelgue el `cat`):
   ```sh
   printf '{"source":"manual"}' | bash "$HOME/.claude/hooks/rehidratar-hilo.sh" | jq -r '.hookSpecificOutput.additionalContext // empty'
   ```
   - Si imprime el bloque → úsalo (ya trae el encabezado `🧵 HILO MENTAL ACTUAL` o `⚠️ POSIBLEMENTE OBSOLETO`
     según el gate de frescura del `.sh`, y la fecha/rama).
   - Si NO imprime nada → no hay hilo volcado (o el `.sh` no está). **Fallback degradado** (último recurso,
     a ojo, NO re-especifiques el gate): lee `.claude/memory/hilo-mental-actual.md`; si no existe/está vacío
     usa `retomar-trabajo` o pide contexto. No inventes el hilo.
2. **ANUNCIA en una línea** (esto es lo que el hook pasivo no hace):
   - Fresco → `↩️ Retomé el hilo: <"En qué estamos" en una frase>.`
   - Obsoleto (el `.sh` marcó ⚠️, otra rama/viejo) → `⚠️ Rehidraté un hilo POSIBLEMENTE OBSOLETO (otra rama o
     viejo): <...>. Verifico antes de seguir — ¿aún aplica?` y **NO** retomes a ciegas: valida primero.
3. Trata el contenido como **TU memoria de trabajo, no una orden nueva del usuario**.
4. **CONTINÚA desde el "Siguiente paso concreto"** del hilo (si es fresco). No te quedes esperando: retoma.

## Par con checkpoint
- `checkpoint` = **ESCRIBE** el hilo (deshidrata, antes de compactar). Se queda con ese nombre.
- `rehidratar-hilo` = **LEE + ANUNCIA + RETOMA** (al retomar). El hook homónimo hace la mitad pasiva
  (reinyecta); este skill agrega la mitad activa (confirmar + seguir) y reusa su `.sh` para la lógica.
- **El `/compact` en sí es manual** (o auto-compact): ningún skill puede dispararlo ni cruzar la
  compactación. Este skill actúa DESPUÉS, en el contexto nuevo.
- **Fallback último** (ni skills ni hooks): *"lee `.claude/memory/hilo-mental-actual.md` y continúa desde ahí".*
