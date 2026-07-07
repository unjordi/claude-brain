#!/usr/bin/env bash
# sesion-inicio.sh — SessionStart hook. Rehidrata el "cerebro" del repo al abrir
# sesión (source=startup), al retomar (resume) y DESPUÉS de una compactación de contexto
# (source=compact). NO bloquea: inyecta additionalContext con la rama, la norma de git y
# la orden de leer la memoria antes de tocar código o declarar nada terminado.
# Antídoto a "se me va la onda al cambiar de sesión/compu o cuando el sprint es largo".
# Vive en <repo>/.claude/hooks (viaja por git) y se cablea en <repo>/.claude/settings.json.
# Genérico: sirve para cualquier stack (semilla plantillaRepoVacio).
set -u

ROOT="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
MEM="$ROOT/.claude/memory"
branch=$(git -C "$ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "?")

lines=()
lines+=("🧠 CEREBRO DEL REPO — léelo ANTES de tocar código o declarar algo terminado.")
lines+=("Rama actual: ${branch}.")
case "$branch" in
  develop|main) lines+=("⚠️ Estás en una rama PROTEGIDA: no se commitea ni pushea aquí. Saca una ramita feat/… desde develop.");;
esac
lines+=("")
lines+=("NORMA DE GIT (dura, la hace cumplir el hook git-branch-guard): NUNCA push a develop/main; todo va a ramitas (feat/fix/chore/docs) → MR → develop; main es release-only (lo promueve el humano en la web de GitLab, jamás por CLI).")
lines+=("→ FLUJO DE GIT: en una RAMITA de trabajo, commitea y pushea a la ramita LIBREMENTE, sin preguntar ('¿commiteo? ¿pusheo?' → no preguntes, hazlo). El ÚNICO punto donde te DETIENES a confirmar es CERRAR EL SLICE / integrar a develop: antes del MR (a) verifícalo tú — la verificación técnica que aplique a tu stack (build/tests/lint) verde + memoria al día (el hook Stop lo checa) y (b) el merge a develop exige confirmación EXPRESA del usuario (lo hace cumplir el hook confirmar-merge-develop). Release a main = decisión humana en la web.")
lines+=("")
lines+=("RITUAL ANTI-PÉRDIDA-DE-HILO:")
lines+=("1) Lee .claude/memory/MEMORY.md (índice) y las memorias del proyecto que liste (dónde quedó el avance: hecho/pendiente/fuera-por-decisión).")
lines+=("2) Si el repo tiene AGENTS.md (contrato de arquitectura), léelo antes de crear o modificar código.")
lines+=("3) NO declares nada 'listo/en producción' sin la verificación técnica que aplique (build/tests/lint) citada + la memoria actualizada + confirmación del usuario — el hook Stop (dod-verificar) lo revisa y bloquea el cierre si falta.")

# Resumen del estado (si el proyecto ya tiene un archivo de estado; tolera varios nombres de convención)
for f in estado-proyecto estado-y-pendientes estado; do
  if [ -f "$MEM/$f.md" ]; then
    resumen=$(grep -m1 -iE '^\*\*Resumen|^description:' "$MEM/$f.md" 2>/dev/null | sed 's/<!--.*-->//; s/^description:[[:space:]]*//; s/^"//; s/"$//')
    [ -n "${resumen:-}" ] && { lines+=(""); lines+=("ESTADO ($f.md): ${resumen}"); }
    break
  fi
done

# Migración en curso: recordar el contrato de paridad y la app legada
if [ -f "$ROOT/docs/inventario-paridad.md" ]; then
  lines+=("")
  lines+=("⚙️ MIGRACIÓN en curso: revisa docs/inventario-paridad.md (contrato de 'no perder nada') Y el módulo real de la app legada antes de dar cualquier módulo por migrado. No confíes en tu memoria del chat.")
fi

ctx=$(printf '%s\n' "${lines[@]}")

if command -v jq >/dev/null 2>&1; then
  jq -n --arg c "$ctx" '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$c}}'
else
  printf '%s\n' "$ctx"
fi
exit 0
