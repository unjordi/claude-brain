#!/usr/bin/env bash
# exportar-sesion-master.sh — hook del brain (mecanismo GENÉRICO, opt-in por convención de nombre).
# Exporta el transcript comprimido de una sesión cuyo TÍTULO vigente sea `*-master` (o que ya esté
# listada en masters.json) a la CARPETA DE SESIONES, para poder `claude --resume` la MISMA sesión
# después (sobrevive el cleanup de 30 días de Claude Code) — y, si esa carpeta vive en una nube, para
# que la sesión VIAJE entre máquinas. Mitad "auto-export" del sync; la mitad "sembrar" es seed.sh.
#
# CARPETA DE SESIONES: default ~/.claude-sessions (local, oculta). Override con $CLAUDE_SESSIONS_DRIVE
# para apuntarla a una carpeta SINCRONIZADA (Drive/iCloud/…) → viaje cross-máquina (config PERSONAL de
# cada quien; ver brain/sesiones-master/README.md). Las rutas concretas de una nube NO viven en el código.
#
# GATILLOS (cablea install-brain / brain/sesiones-master/install-hook.sh, en ~/.claude/settings.json):
#   - Stop        BACKBONE: dispara al final de CADA turno, con DEBOUNCE (a lo mucho 1 export/N min por
#                 sesión) para no re-gzipear cientos de MB en balde. Mantiene la master fresca CONTINUA-
#                 mente aunque la sesión NUNCA "termine" (las de vida larga se resumen por días →
#                 SessionEnd casi nunca disparaba → el export se congelaba). En Stop, fast-path: solo
#                 actúa si el sid YA está en masters.json (grep a ~1KB); NO escanea el transcript gigante.
#   - SessionEnd  Estado FINAL en salida limpia (sin debounce). Aquí sí se escanea el título para
#                 detectar/registrar un master NUEVO.
#   - PreCompact  Bonus: justo antes de compactar (sin debounce). NO crítico (Stop ya cubre frescura).
#
# El export corre DETACHED (nohup … &) con lock por-sid: un transcript grande excede el timeout del hook
# ("Hook cancelled", caso real cps-master 456 MB) → el hook retorna al instante y el gzip+copy termina en
# segundo plano. El MOTOR (session-export.js) es genérico y lo aporta cortex.
#
# CONTRATO: SILENCIOSO y FAIL-OPEN. Si la sesión no es master, falta el motor/node, o el debounce aún no
# vence → no hace nada y NO bloquea. JAMÁS rompe el turno/cierre (siempre exit 0). Opt-in por convención
# de nombre (título *-master) y/o por estar ya en masters.json.
# Overrides: $CLAUDE_SESSIONS_DEBOUNCE_MIN (min, default 20) · $CLAUDE_SESSIONS_DRIVE (carpeta de sesiones).
set -u

DEBOUNCE_MIN="${CLAUDE_SESSIONS_DEBOUNCE_MIN:-20}"

# ── stdin del hook: {session_id, transcript_path, cwd, hook_event_name, ...} (Stop trae stop_hook_active) ─
input=$(cat 2>/dev/null || true)
have_jq=0; command -v jq >/dev/null 2>&1 && have_jq=1
getf() {
  if [ "$have_jq" = 1 ]; then printf '%s' "$input" | jq -r ".$1 // empty" 2>/dev/null
  else printf '%s' "$input" | sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -n1; fi
}
sid=$(getf session_id)
tpath=$(getf transcript_path)
cwd=$(getf cwd)
event=$(getf hook_event_name)
[ -n "$sid" ] || exit 0
[ -n "$tpath" ] && [ -f "$tpath" ] || exit 0

# Evita re-entradas del hook Stop (cuando el propio Stop hook ya está activo/continuando)
if [ "$event" = "Stop" ]; then
  [ "$(getf stop_hook_active)" = "true" ] && exit 0
fi

# ── carpeta de respaldo de sesiones ──────────────────────────────────────────────────────────────
# DEFAULT: ~/.claude-sessions (oculta en el home, SIEMPRE local → el respaldo sobrevive el cleanup de
# 30 días de Claude Code sin depender de ninguna nube). OVERRIDE: exporta CLAUDE_SESSIONS_DRIVE para
# apuntarla a una carpeta SINCRONIZADA (Google Drive / iCloud / …) y que las sesiones VIAJEN entre
# máquinas — decisión personal de cada quien (ver brain/sesiones-master/README.md). Las rutas concretas
# de una nube son config de MÁQUINA, no del mecanismo → NO viven aquí.
DRIVE="${CLAUDE_SESSIONS_DRIVE:-$HOME/.claude-sessions}"
mkdir -p "$DRIVE" 2>/dev/null || exit 0
mj="$DRIVE/masters.json"

# ── ¿es master? FAST-PATH: si el sid ya está en masters.json no escaneamos el transcript. ──────────
title=""
is_master=0
if [ -f "$mj" ] && grep -q "\"$sid\"" "$mj" 2>/dev/null; then
  is_master=1
  [ "$have_jq" = 1 ] && title=$(jq -r --arg id "$sid" '.masters[]? | select(.id==$id) | .name // empty' "$mj" 2>/dev/null)
fi
# sid NO registrado: el escaneo del transcript (caro) SOLO en eventos infrecuentes, jamás en Stop.
if [ "$is_master" = 0 ]; then
  case "$event" in
    SessionEnd|PreCompact)
      t=$(grep -ao '"customTitle":"[^"]*"' "$tpath" 2>/dev/null | tail -1 | sed 's/.*:"//; s/"$//')
      case "$t" in *-master) title="$t"; is_master=1 ;; esac
      ;;
    *) exit 0 ;;   # Stop u otro con sid no listado → salimos barato, sin escanear
  esac
fi
# título registrado pero sin name (o sin jq): recupéralo con un scan (raro; jq va presente por install-hook)
if [ "$is_master" = 1 ] && [ -z "$title" ]; then
  t=$(grep -ao '"customTitle":"[^"]*"' "$tpath" 2>/dev/null | tail -1 | sed 's/.*:"//; s/"$//')
  case "$t" in *-master) title="$t" ;; *) title="$sid" ;; esac
fi
[ "$is_master" = 1 ] && [ -n "$title" ] || exit 0

# ── DEBOUNCE (solo Stop): si el export en Drive es más nuevo que N min, no re-exportar. ──────────
if [ "$event" = "Stop" ]; then
  prev="$DRIVE/$sid.jsonl.gz"
  if [ -f "$prev" ]; then
    # mtime epoch, portable: GNU `stat -c %Y` primero (falla LIMPIO en BSD, sin ensuciar stdout);
    # si no, BSD/macOS `stat -f %m`. OJO: al revés NO sirve — en GNU `-f` es --file-system y `%m`
    # se toma como archivo → vuelca basura a stdout y rompe la aritmética bajo set -u.
    now=$(date +%s 2>/dev/null || echo 0)
    mt=$(stat -c %Y "$prev" 2>/dev/null || stat -f %m "$prev" 2>/dev/null || echo 0)
    case "$now" in ''|*[!0-9]*) now=0 ;; esac
    case "$mt"  in ''|*[!0-9]*) mt=0  ;; esac
    age=$(( now - mt ))
    [ "$mt" -gt 0 ] && [ "$age" -ge 0 ] && [ "$age" -lt $(( DEBOUNCE_MIN * 60 )) ] && exit 0
  fi
fi

# ── localizar el motor (genérico, lo aporta cortex) ────────────────────────────────────────
# resolve_brain_dir() vive en drift-cerebro-comun.sh (misma carpeta, fuente y una vez instalado) — mismo
# orden/fallback que los widgets (#322): $CLAUDE_BRAIN_DIR → ~/.cortex → ~/.claude-brain (nombre viejo).
# Si la lib no está (caso raro), cae al default histórico sin el fallback (fail-open, nunca bloquea).
_selfdir="$(dirname "$0")"
if [ -f "$_selfdir/drift-cerebro-comun.sh" ]; then
  # shellcheck source=drift-cerebro-comun.sh
  . "$_selfdir/drift-cerebro-comun.sh"
  BRAIN_DIR="$(resolve_brain_dir)"
else
  BRAIN_DIR="${CLAUDE_BRAIN_DIR:-$HOME/.cortex}"
fi
EXP=""
for c in "$HOME/.local/bin/session-export.js" "$BRAIN_DIR/bin/session-export.js"; do
  [ -f "$c" ] && EXP="$c" && break
done
[ -n "$EXP" ] || exit 0
command -v node >/dev/null 2>&1 || exit 0

# ── EXPORTAR en SEGUNDO PLANO (detached) ─────────────────────────────────────────────────────────
# Un transcript grande (cientos de MB) tarda en gzipearse y EXCEDE el timeout del hook → "Hook
# cancelled" (caso REAL: cps-master, 456 MB, el auto-export se quedó congelado). Solución: lanzar el
# export con nohup … & → el hook RETORNA al instante y el gzip+copy termina en segundo plano, sin que
# el CLI lo mate. Un lock por-sid evita que dos triggers seguidos (Stop/SessionEnd/PreCompact) lancen
# exports SOLAPADOS de la misma sesión; el lock se ignora si quedó viejo (>30 min = export colgado).
lock="$DRIVE/.export-$sid.lock"
if [ -f "$lock" ]; then
  lnow=$(date +%s 2>/dev/null || echo 0)
  lmt=$(stat -c %Y "$lock" 2>/dev/null || stat -f %m "$lock" 2>/dev/null || echo 0)
  case "$lnow" in ''|*[!0-9]*) lnow=0 ;; esac
  case "$lmt"  in ''|*[!0-9]*) lmt=0 ;; esac
  [ "$lmt" -gt 0 ] && [ $(( lnow - lmt )) -lt 1800 ] && exit 0   # export en vuelo → no solapar
fi
: > "$lock" 2>/dev/null || true
# El subshell detachado hace TODO el trabajo pesado (export + gzip + copy) y libera el lock al final.
nohup bash -c '
  EXP="$1"; sid="$2"; title="$3"; DRIVE="$4"; lock="$5"
  tmp=$(mktemp -d 2>/dev/null) || { rm -f "$lock"; exit 0; }
  node "$EXP" "$sid" --repo "$tmp" --name "$title" --force >/dev/null 2>&1
  gz="$tmp/.claude/sessions/$sid.jsonl.gz"; meta="$tmp/.claude/sessions/$sid.meta.json"
  # Solo copia el .gz si PASA la verificación de integridad (gzip -t): si node crasheó a media escritura,
  # un gz truncado NO debe SOBREESCRIBIR el backup bueno anterior en $DRIVE (mejor un backup viejo-pero-válido
  # que uno nuevo-corrupto). Sin gzip -t, un export corrupto pasaba silencioso y reventaba al `claude --resume`.
  if [ -f "$gz" ] && gzip -t "$gz" 2>/dev/null; then
    cp -f "$gz" "$DRIVE/" 2>/dev/null
    [ -f "$meta" ] && cp -f "$meta" "$DRIVE/" 2>/dev/null   # el meta acompaña SOLO a un gz válido
  fi
  rm -rf "$tmp" 2>/dev/null
  rm -f "$lock" 2>/dev/null
' _ "$EXP" "$sid" "$title" "$DRIVE" "$lock" >/dev/null 2>&1 &

# ── registrar/ACTUALIZAR en masters.json (target = cwd relativo a $HOME → "code/<repo>") ─────────
# Corre SIEMPRE (ya no solo cuando falta el sid): si el master YA está pero se MOVIÓ de folder, su
# `target` viejo haría que `seed.sh` en otra máquina lo sembrara al lugar equivocado. Ahora: si no está
# → lo agrega; si está con target distinto → lo ACTUALIZA; y si el título cambió (rename real, no el
# fallback al sid) → actualiza el name. Solo reescribe el archivo si HUBO cambio (masters.json vive en
# Drive compartido → no generar churn de sync en cada export).
if [ -f "$mj" ] && [ -n "$cwd" ]; then
  target="${cwd#"$HOME"/}"
  node -e '
    const fs=require("fs"),p=process.argv[1],id=process.argv[2],name=process.argv[3],target=process.argv[4];
    try{const m=JSON.parse(fs.readFileSync(p,"utf8"));m.masters=m.masters||[];
      const e=m.masters.find(x=>x.id===id); let changed=false;
      if(!e){ m.masters.push({id,name,target}); changed=true; }
      else {
        if(target && e.target!==target){ e.target=target; changed=true; }
        // name solo si es un título REAL (no el fallback al sid) y de verdad cambió
        if(name && name!==id && e.name!==name){ e.name=name; changed=true; }
      }
      if(changed) fs.writeFileSync(p,JSON.stringify(m,null,2)+"\n");
    }catch(e){}
  ' "$mj" "$sid" "$title" "$target" 2>/dev/null || true
fi
exit 0
