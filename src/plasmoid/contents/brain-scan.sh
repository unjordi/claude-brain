#!/usr/bin/env bash
# brain-scan.sh — helper del plasmoid Claude Brain Widget (KDE).
#
# El plasmoid NO puede leer archivos ni correr procesos por sí mismo: lo hace a través del
# DataSource "executable" de Plasma5Support (el mismo mecanismo con que ya lee state.json/stats.json).
# Este helper es el brazo de ese mecanismo para la pestaña Cerebro:
#
#   brain-scan.sh scan  -> imprime en JSON el estado REAL del cerebro global (~/.claude):
#                          hooks presentes, hooks cableados, si hay normas, y skills.
#                          Espeja BrainInspector.swift (misma semántica, doc = realidad).
#   brain-scan.sh heal  -> corre install-brain.sh (self-healing). Ver nota de RUTA abajo.
#
# Un solo juego bash (igual que el resto del cerebro; corre en Mac/Linux/Windows-GitBash).
# Todo el I/O de "scan" es de LECTURA y fail-safe: si algo falta, esa pieza sale ausente en vez de romper.
# PATH enriquecido para hallar jq (el entorno del plasmoid suele traer un PATH mínimo).
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

CLAUDE="$HOME/.claude"

# ── scan: estado real de ~/.claude como JSON ──
scan() {
  local present="" wired="" skills="" hasNorms=false f b w x d

  # (1) hooks presentes: *.sh en ~/.claude/hooks (basename sin .sh)
  for f in "$CLAUDE"/hooks/*.sh; do
    [ -e "$f" ] || continue
    b="$(basename "$f" .sh)"
    present="$present${present:+,}\"$b\""
  done

  # (2) hooks cableados: basenames referenciados por la regex /hooks/<nombre>.sh en settings.json
  if [ -f "$CLAUDE/settings.json" ]; then
    w="$(grep -oE '/hooks/[A-Za-z0-9._-]+\.sh' "$CLAUDE/settings.json" 2>/dev/null \
         | sed -E 's#^/hooks/##; s#\.sh$##' | sort -u)"
    # los nombres de hook no llevan espacios -> el word-split por defecto es seguro
    for x in $w; do
      [ -n "$x" ] || continue
      wired="$wired${wired:+,}\"$x\""
    done
  fi

  # (3) normas: el marcador de inyección O el texto de las normas escritas a mano (ambas gobiernan)
  if [ -f "$CLAUDE/CLAUDE.md" ] && \
     grep -qE 'BEGIN claude-brain|Definición de "LISTO"|reflejo de la realidad' "$CLAUDE/CLAUDE.md" 2>/dev/null; then
    hasNorms=true
  fi

  # (4) skills: subcarpetas de ~/.claude/skills que tengan un SKILL.md
  for d in "$CLAUDE"/skills/*/; do
    [ -f "${d}SKILL.md" ] || continue
    b="$(basename "$d")"
    skills="$skills${skills:+,}\"$b\""
  done

  printf '{"present":[%s],"wired":[%s],"hasNorms":%s,"skills":[%s]}\n' \
    "$present" "$wired" "$hasNorms" "$skills"
}

# ── heal: corre install-brain.sh (idempotente) ──
# NOTA DE RUTA (limitación conocida en Linux/KDE): install.sh instala SOLO src/plasmoid vía
# kpackagetool6; NO copia brain/ dentro del paquete instalado. Por eso, a diferencia de macOS
# (donde install-brain.sh va empaquetado en el .app), aquí no hay una ruta empaquetada garantizada.
# Buscamos en orden: (a) por si algún día se empaqueta dentro del plasmoid, (b) relativo al repo si
# se corre desde el árbol fuente, (c) clones habituales del repo, (d) fallback a $PATH (command -v).
heal() {
  local self here c
  self="$0"
  here="$(cd "$(dirname "$self")" 2>/dev/null && pwd)"
  for c in \
    "$HOME/.local/share/plasma/plasmoids/io.github.unjordi.claude-brain/contents/brain/install-brain.sh" \
    "$here/brain/install-brain.sh" \
    "$here/../../brain/install-brain.sh" \
    "$here/../../../brain/install-brain.sh" \
    "$HOME/code/claude-brain/brain/install-brain.sh" \
    "$HOME/.claude-brain/brain/install-brain.sh" \
    "$HOME/claude-brain/brain/install-brain.sh" \
    "$HOME/src/claude-brain/brain/install-brain.sh" \
    "$HOME/Projects/claude-brain/brain/install-brain.sh"; do
    if [ -f "$c" ]; then
      echo "==> usando $c"
      bash "$c"
      exit $?
    fi
  done
  # Fallback tolerante: un alias/lanzador en el PATH, si el usuario lo instaló.
  if command -v claude-brain-install >/dev/null 2>&1; then claude-brain-install; exit $?; fi
  if command -v install-brain.sh   >/dev/null 2>&1; then install-brain.sh;   exit $?; fi
  echo "install-brain.sh no encontrado (ver NOTA DE RUTA en brain-scan.sh)" >&2
  exit 3
}

case "${1:-scan}" in
  scan) scan ;;
  heal) heal ;;
  *) echo "uso: $0 {scan|heal}" >&2; exit 2 ;;
esac
