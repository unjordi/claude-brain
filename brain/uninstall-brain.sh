#!/usr/bin/env bash
# uninstall-brain.sh — INVERSO EXACTO de install-brain.sh. Quita de esta máquina el CEREBRO GLOBAL
# de Claude Code (cortex) que instaló install-brain.sh. Idempotente: re-correrlo es SEGURO
# (si algo ya no está, lo salta sin quejarse).
#
# Quita GLOBAL (de ~/.claude):
#   (a) los HOOKS de tier global que copió el instalador → git-branch-guard, merge-squash-guard,
#       confirmar-merge-develop, recordar-dashboard, secret-scan, rama-vieja, proteger-arbol,
#       limite-gasto, rehidratar-hilo, delegacion-gate/registrar/reporte, libs (delegacion-comun,
#       analizar-comando-git, detectar-secretos), limpiar-worktrees (script) + ~/.claude/agentes-costo.json.
#       La lista EXACTA se deriva de brain/hooks/MANIFEST (misma fuente que install-brain).
#   (b) DES-CABLEA de ~/.claude/settings.json SOLO las entradas que apuntan a esos hooks (deja
#       intactas las demás — usa jq); poda los arrays de evento que queden vacíos.
#   (c) las SKILLS genéricas (cerrar-slice, orquestar-fanout, checkpoint, rehidratar-hilo, turno-nocturno, diagramar, cosechar-sesion, unificar-cerebro) de ~/.claude/skills/.
#   (d) el BLOQUE de normas de ~/.claude/CLAUDE.md (entre los marcadores BEGIN/END cortex).
#
# NO borra (son DATOS del usuario, no instalación):
#   - el Dashboard del cerebro (dashboard_cerebro.md en la memoria GLOBAL).
#   - el registro de consentimiento de delegación (~/.claude/delegacion-consentimiento.json).
#   - ninguna memoria de proyecto.
#
# FAIL-SAFE sin jq: NO puede des-cablear el settings.json a mano de forma segura → avisa y deja el
# cableado (los hooks ya no existen en disco → fallan abierto, no rompen) para que lo quites tú.
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MANIFEST="$SCRIPT_DIR/hooks/MANIFEST"
CLAUDE_DIR="$HOME/.claude"
HOOKS_DIR="$CLAUDE_DIR/hooks"
SKILLS_DIR="$CLAUDE_DIR/skills"
GSET="$CLAUDE_DIR/settings.json"
GCLAUDE="$CLAUDE_DIR/CLAUDE.md"

echo "==> cortex: desinstalando cerebro global de $CLAUDE_DIR"

# ── (a) Borrar los hooks de tier global + la lib compartida + la config de costo ──
# Derivado del MANIFEST (fuente única, igual que install-brain) → no es una 3ª lista que driftee.
if [ -f "$MANIFEST" ]; then
  GLOBAL_HOOKS="$(awk '$1!~/^#/ && NF>=3 && ($2=="global"||$2=="both"){print $1".sh"}' "$MANIFEST")"
else
  echo "warn: falta $MANIFEST; caigo a la lista embebida (compatibilidad)"
  GLOBAL_HOOKS="git-branch-guard.sh merge-squash-guard.sh confirmar-merge-develop.sh recordar-dashboard.sh \
                secret-scan.sh rama-vieja.sh proteger-arbol.sh limite-gasto.sh rehidratar-hilo.sh aviso-contexto.sh \
                delegacion-gate.sh delegacion-registrar.sh delegacion-reporte.sh delegacion-comun.sh \
                analizar-comando-git.sh limpiar-worktrees.sh"
fi
for h in $GLOBAL_HOOKS; do
  rm -f "$HOOKS_DIR/$h"
done
rm -f "$CLAUDE_DIR/agentes-costo.json"
echo "ok: hooks globales + lib + config de costo eliminados de $HOOKS_DIR"

# ── (b) Des-cablear del settings.json SOLO las entradas de esos hooks (idempotente, jq) ──
# BRAIN_PAT = regex de basenames a des-cablear, DERIVADO del MANIFEST ({global,both} kind=hook = EXACTAMENTE
# el set que install-brain cablea vía ev_de) → NO es una 3ª lista hardcodeada que driftee. ANTES sí lo era
# y HABÍA drifteado: omitía entorno-maquina-guard, exportar-sesion-master, no-bypass-deploy,
# proteger-fuente-cerebro y recordar-orquestar → tras un uninstall quedaban 5 cableados ZOMBIE en
# settings.json apuntando a hooks ya borrados del disco (Claude Code invocaría hooks inexistentes).
if [ -f "$MANIFEST" ]; then
  BRAIN_PAT="$(awk '$1!~/^#/ && NF>=3 && ($2=="global"||$2=="both") && $3=="hook"{print $1}' "$MANIFEST" | sed 's/$/\\.sh/' | paste -sd'|' -)"
fi
# Fallback COMPLETO si falta el MANIFEST (los 21 {global,both} kind=hook actuales — sin omisiones):
[ -n "${BRAIN_PAT:-}" ] || BRAIN_PAT='git-branch-guard\.sh|merge-squash-guard\.sh|confirmar-merge-develop\.sh|recordar-dashboard\.sh|secret-scan\.sh|entorno-maquina-guard\.sh|no-bypass-deploy\.sh|hud-stale\.sh|rama-vieja\.sh|proteger-arbol\.sh|proteger-fuente-cerebro\.sh|limite-gasto\.sh|rehidratar-hilo\.sh|aviso-contexto\.sh|aviso-drift-cerebro\.sh|exportar-sesion-master\.sh|barrer-ramas\.sh|delegacion-gate\.sh|delegacion-registrar\.sh|delegacion-reporte\.sh|recordar-orquestar\.sh'
if command -v jq >/dev/null 2>&1; then
  if [ -f "$GSET" ]; then
    tmp="$(mktemp)" || tmp=""
    if [ -n "$tmp" ] && jq --arg pat "$BRAIN_PAT" '
        if (.hooks | type) == "object" then
          .hooks |= (
            to_entries
            | map(.value |= [ .[] | select((([.hooks[]?.command] | join(" ")) | test($pat)) | not) ])
            | map(select((.value | type) == "array" and (.value | length) > 0))
            | from_entries
          )
          | (if (.hooks | length) == 0 then del(.hooks) else . end)
        else . end
      ' "$GSET" > "$tmp" 2>/dev/null && [ -s "$tmp" ]; then
      mv "$tmp" "$GSET"
      echo "ok: entradas de los hooks del cerebro removidas de $GSET (las demás quedan intactas)"
    else
      [ -n "$tmp" ] && rm -f "$tmp"
      echo "warn: no pude editar $GSET con jq (¿JSON inválido?); revísalo a mano"
    fi
  else
    echo "ok: no hay $GSET que des-cablear"
  fi
else
  echo "ADVERTENCIA: 'jq' no está en el PATH: NO des-cablé $GSET (editarlo a mano es riesgoso)."
  echo "  Los hooks ya no existen en disco, así que fallan abierto (no bloquean). Para limpiar el"
  echo "  cableado, instala jq y re-corre, o quita a mano las entradas que citen: $BRAIN_PAT"
fi

# ── (c) Quitar las skills genéricas del cerebro (cerrar-slice, orquestar-fanout, checkpoint) ──
for sk in cerrar-slice orquestar-fanout checkpoint rehidratar-hilo turno-nocturno diagramar cosechar-sesion unificar-cerebro; do
  if [ -d "$SKILLS_DIR/$sk" ]; then
    rm -rf "$SKILLS_DIR/$sk"
    echo "ok: skill $sk eliminada de $SKILLS_DIR"
  fi
done

# ── (d) Quitar el bloque de normas de ~/.claude/CLAUDE.md (entre los marcadores) ──
if [ -f "$GCLAUDE" ] && grep -q 'BEGIN cortex' "$GCLAUDE"; then
  tmp="$(mktemp)" || tmp=""
  # Borra desde la línea del marcador BEGIN hasta la del END (inclusive). Sin sed -i (portable).
  if [ -n "$tmp" ] && awk '
      /BEGIN cortex/ { skip=1 }
      skip != 1 { print }
      /END cortex/   { skip=0 }
    ' "$GCLAUDE" > "$tmp"; then
    # Poda una posible línea en blanco al inicio que el bloque dejaba de separador.
    mv "$tmp" "$GCLAUDE"
    echo "ok: bloque de normas del cerebro removido de $GCLAUDE"
  else
    [ -n "$tmp" ] && rm -f "$tmp"
    echo "warn: no pude editar $GCLAUDE; quita a mano el bloque BEGIN/END cortex"
  fi
else
  echo "ok: no hay bloque de normas del cerebro en $GCLAUDE"
fi

# ── (e) Quitar el @import de aliases-activos.md (marcador propio) + el artefacto GENERADO ──
# Inverso de (d3) de install-brain. El artefacto es GENERADO per-máquina (no dato curado del usuario) →
# se elimina. Borra la línea del marcador `brain:import-aliases`, el `@aliases-activos.md` que le sigue y
# una posible línea en blanco separadora previa. Idempotente (si no están, no hace nada).
if [ -f "$GCLAUDE" ] && grep -q 'brain:import-aliases' "$GCLAUDE" 2>/dev/null; then
  tmp="$(mktemp)" || tmp=""
  if [ -n "$tmp" ] && awk '
      /brain:import-aliases/ { skip_next=1; next }            # tira la línea del marcador
      skip_next==1 && /^@aliases-activos\.md[[:space:]]*$/ { skip_next=0; next }   # y el @import que le sigue
      { skip_next=0; print }
    ' "$GCLAUDE" > "$tmp"; then
    mv "$tmp" "$GCLAUDE"
    echo "ok: @import de aliases-activos.md removido de $GCLAUDE"
  else
    [ -n "$tmp" ] && rm -f "$tmp"
    echo "warn: no pude quitar el @import de $GCLAUDE; hazlo a mano (líneas brain:import-aliases + @aliases-activos.md)"
  fi
fi
if [ -f "$CLAUDE_DIR/aliases-activos.md" ]; then
  rm -f "$CLAUDE_DIR/aliases-activos.md"
  echo "ok: artefacto GENERADO aliases-activos.md eliminado (se regenera en el próximo install)"
fi

echo "listo: cerebro global desinstalado. Se conservaron el dashboard, el registro de"
echo "       consentimiento de delegación y toda la memoria (datos del usuario, no instalación)."
