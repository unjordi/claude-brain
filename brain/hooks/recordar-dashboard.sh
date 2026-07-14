#!/usr/bin/env bash
# PreToolUse (matcher Bash): antes de un `git push`, recuerda (NO bloquea) DOS cosas:
#  (1) actualizar el Dashboard del cerebro (memoria GLOBAL de esta maquina);
#  (2) doc=realidad del PROYECTO — si los commits a pushear tocan features/estructura SIN tocar su
#      doc (README, arbol del cerebro, memoria), recuerda actualizarla en la MISMA tanda. Antes esto
#      era solo NORMA (dependia de disciplina y fallo: se olvido el README de un feature); aqui muerde.
# Si no es git push, silencio. Fail-open. Ignora un 'git push' entrecomillado (dato de un grep/MR/test).
# dedupe doble-cableado: si soy la copia del REPO y la copia GLOBAL existe, cedo (la global recuerda).
# Evita el recordatorio DUPLICADO en cada push (la fricción #1). NO-debilitante: sigue recordando 1×.
case "$0" in "$HOME/.claude/hooks/"*) : ;; *) [ -f "$HOME/.claude/hooks/$(basename "$0")" ] && exit 0 ;; esac
cmd=$(jq -r '.tool_input.command // ""' 2>/dev/null)
unquoted=$(printf '%s' "$cmd" | sed "s/'[^']*'//g; s/\"[^\"]*\"//g")
printf '%s' "$unquoted" | grep -qE 'git[[:space:]]+push' || exit 0

DASH="RECORDATORIO (cerebro autocontenido): antes de completar este push, revisa/actualiza el Dashboard del cerebro (dashboard_cerebro.md en la memoria GLOBAL de esta maquina: ~/.claude/projects/<slug-del-HOME>/memory/) — APPENDEA una linea al FINAL de la Bitacora con >> (p. ej. printf '%s\\n' '- FECHA - rama - que' >> \"\$DASH\"), NO edites arriba: el append-al-final no choca con otras sesiones de Claude que escriben este mismo archivo a la vez (dos >> no se pisan; un Edit tropieza con 'File modified since read'). Ajusta Mapa/Infra/Cabos sueltos solo si cambio el layout de memoria, repos o proyectos. La memoria GLOBAL es solo config de ESTA maquina; lo de un proyecto vive en su .claude/. Esto es parte de CERRAR bien el slice (skill cerrar-slice): dashboard + doc=realidad + memoria + resumen curado."

# (2) doc=realidad del proyecto: analiza los commits que se van a pushear (vs upstream, o vs develop
# si la rama es nueva). Afinado a senal ALTA para no fastidiar.
DOCMSG=""
root=$(git rev-parse --show-toplevel 2>/dev/null || true)
if [ -n "$root" ]; then
  if git -C "$root" rev-parse --abbrev-ref '@{u}' >/dev/null 2>&1; then range="@{u}..HEAD"
  else mb=$(git -C "$root" merge-base HEAD develop 2>/dev/null || git -C "$root" merge-base HEAD main 2>/dev/null || true); [ -n "$mb" ] && range="$mb..HEAD" || range=""; fi
  if [ -n "$range" ]; then
    names=$(git -C "$root" diff --name-only "$range" 2>/dev/null)
    status=$(git -C "$root" diff --name-status "$range" 2>/dev/null)
    touched_doc=0; struct=0; code=0
    printf '%s\n' "$names"  | grep -iqE '(^|/)README|\.md$|(^|/)docs/|\.claude/memory/' && touched_doc=1
    printf '%s\n' "$status" | grep -E '^[AD][[:space:]]' | grep -qE 'brain/hooks/.*\.sh$|brain/skills/.*SKILL\.md$|\.claude/hooks/.*\.sh$' && struct=1
    printf '%s\n' "$names"  | grep -iqE 'brain/(hooks|skills|norms)/|(^|/)src/|macos/Sources/|windows/src/|(^|/)bin/.*\.(js|sh)$|install-brain|(^|/)install\.sh|make-' && code=1
    if [ "$struct" = 1 ] && [ "$touched_doc" = 0 ]; then
      DOCMSG=" || doc=realidad: este push AGREGA/QUITA un hook o skill pero ningun commit toca doc — actualiza el ARBOL del cerebro en README.md + el conteo de checks de test-brain.sh ANTES de pushear."
    elif [ "$code" = 1 ] && [ "$touched_doc" = 0 ]; then
      DOCMSG=" || doc=realidad: este push toca codigo/features pero ninguna doc — si cambio comportamiento, config, rutas o una interfaz, actualiza su doc (README/memoria/comentarios) en esta tanda. Si no aplica, ignora."
    fi
  fi
fi

jq -n --arg d "$DASH" --arg x "$DOCMSG" '{hookSpecificOutput:{hookEventName:"PreToolUse",additionalContext:($d+$x)}}'
exit 0
