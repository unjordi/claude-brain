#!/usr/bin/env bash
# test-brain.sh — pruebas VERSIONADAS y REPETIBLES del cerebro (claude-brain). No toca tu ~/.claude:
# todo corre contra un $HOME FALSO aislado (mktemp) que se borra al final.
#
# Cubre:
#   (a) sintaxis: `bash -n` de todos los hooks .sh + `jq empty` de todos los .json de brain/.
#   (b) gate de delegación: casos gratis / incluido / metered(overage) / metered(externo) /
#       desconocido, el ciclo gate→registrar→gate-silencioso, y la transición dentro/fuera de la
#       ventana de 5h (incluido → metered al agotarse la ventana).
#   (b5) compactación: precompact NO emite hookSpecificOutput (contrato de PreCompact — el bug real
#        que bash -n no veía) + rehidratar-hilo inyecta/silencia según exista el hilo.
#   (c) idempotencia: install-brain.sh corrido 2× contra el $HOME falso → cada hook queda 1× en
#       settings.json y hay 1 solo bloque de normas en CLAUDE.md.
#
# NOTA anti-auto-bloqueo: este script NO escribe el literal del comando de merge de GitLab en sus
# pruebas (lo arma partido) para no disparar el guard global merge-squash-guard sobre sí mismo.
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOKS="$SCRIPT_DIR/hooks"
INSTALLER="$SCRIPT_DIR/install-brain.sh"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  PASS: %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL: %s\n' "$1"; }

command -v jq >/dev/null 2>&1 || { echo "ERROR: se requiere jq para las pruebas"; exit 1; }

# $HOME falso aislado (se limpia al salir)
FAKEHOME="$(mktemp -d "${TMPDIR:-/tmp}/brain-test.XXXXXX")"
cleanup() { rm -rf "$FAKEHOME"; }
trap cleanup EXIT

echo "==> claude-brain test — \$HOME falso: $FAKEHOME"

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "== (a) sintaxis: bash -n de los hooks + jq empty de los json =="
for f in "$HOOKS"/*.sh; do
  [ -e "$f" ] || continue
  if bash -n "$f" 2>/dev/null; then ok "bash -n $(basename "$f")"; else bad "bash -n $(basename "$f")"; fi
done
# también el propio instalador/desinstalador/este test
for f in "$INSTALLER" "$SCRIPT_DIR/uninstall-brain.sh" "$SCRIPT_DIR/test-brain.sh"; do
  [ -e "$f" ] || continue
  if bash -n "$f" 2>/dev/null; then ok "bash -n $(basename "$f")"; else bad "bash -n $(basename "$f")"; fi
done
while IFS= read -r j; do
  if jq empty "$j" 2>/dev/null; then ok "jq empty $(basename "$j")"; else bad "jq empty $(basename "$j")"; fi
done < <(find "$SCRIPT_DIR" -name '*.json' -type f)

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "== (b) gate de delegación (\$HOME falso, snapshot de cuota de prueba) =="

CDIR="$FAKEHOME/.claude"
CACHE="$FAKEHOME/.cache/claude-brain"
CONS="$CDIR/delegacion-consentimiento.json"
mkdir -p "$CDIR" "$CACHE"
cp "$HOOKS/agentes-costo.json" "$CDIR/agentes-costo.json"

# escribe un state.json de prueba con el % de ventana 5h indicado (y una semanal)
write_state() {
  cat > "$CACHE/state.json" <<EOF
{
  "five_hour": { "percent": $1, "cost_usd": 2.48, "cost_cap": 45, "tokens_used": 3700000 },
  "weekly":    { "percent": 57, "cost_usd": 401,  "cost_cap": 4800 }
}
EOF
}

# corre el gate con el $HOME falso; devuelve su stdout
run_gate() {
  HOME="$FAKEHOME" XDG_CACHE_HOME="$FAKEHOME/.cache" bash "$HOOKS/delegacion-gate.sh" <<<"$1"
}
# corre el registrador (materializa el consentimiento tras un ask aprobado)
run_registrar() {
  HOME="$FAKEHOME" XDG_CACHE_HOME="$FAKEHOME/.cache" bash "$HOOKS/delegacion-registrar.sh" <<<"$1"
}
is_ask()    { printf '%s' "$1" | jq -e '.hookSpecificOutput.permissionDecision == "ask"' >/dev/null 2>&1; }
is_silent() { [ -z "$(printf '%s' "$1" | tr -d '[:space:]')" ]; }

payload() { # payload <session> <subagent_type> <model>
  jq -nc --arg s "$1" --arg t "$2" --arg m "$3" \
    '{tool_name:"Task", session_id:$s, tool_input:{subagent_type:$t, model:$m}}'
}

# Casos base (sin registrar → cada uno debe PREGUNTAR en su primer encuentro)
rm -f "$CONS"; write_state 19
out="$(run_gate "$(payload S1 ollama '')")"
is_ask "$out"    && ok "gratis (local: ollama) → pregunta" || bad "gratis (local) → esperaba ask; got: $out"

out="$(run_gate "$(payload S1 '' sonnet)")"
is_ask "$out"    && ok "incluido (claude, ventana 19% < 90%) → pregunta" || bad "incluido → esperaba ask; got: $out"

write_state 99
out="$(run_gate "$(payload S1 '' sonnet)")"
is_ask "$out"    && ok "metered (claude overage, ventana 99%) → pregunta" || bad "metered overage → esperaba ask; got: $out"

out="$(run_gate "$(payload S1 '' gpt-4o)")"
is_ask "$out"    && ok "metered (API externa: gpt-4o) → pregunta" || bad "metered externo → esperaba ask; got: $out"

out="$(run_gate "$(payload S1 general-purpose '')")"
is_ask "$out"    && ok "desconocido (default token) → pregunta" || bad "desconocido → esperaba ask; got: $out"

# Un no-Task no debe incumbir al gate (silencio)
out="$(printf '%s' '{"tool_name":"Bash","tool_input":{"command":"ls"}}' | HOME="$FAKEHOME" XDG_CACHE_HOME="$FAKEHOME/.cache" bash "$HOOKS/delegacion-gate.sh")"
is_silent "$out" && ok "no-Task (Bash) → gate silencioso" || bad "no-Task → esperaba silencio; got: $out"

# Ciclo metered: gate(pregunta) → registrar → gate(silencioso) EN EL MISMO workflow
rm -f "$CONS"; write_state 99
P="$(payload WF1 '' gpt-4o)"
out="$(run_gate "$P")";      is_ask "$out"    && ok "ciclo metered · 1º gate → pregunta"        || bad "ciclo metered 1º → ask; got: $out"
run_registrar "$P"
out="$(run_gate "$P")";      is_silent "$out" && ok "ciclo metered · tras registrar → silencio" || bad "ciclo metered 2º → silencio; got: $out"
# … pero OTRO workflow (session distinta) con costo vuelve a preguntar
out="$(run_gate "$(payload WF2 '' gpt-4o)")"; is_ask "$out" && ok "ciclo metered · otro workflow → pregunta" || bad "otro workflow → ask; got: $out"

# Transición dentro/fuera de ventana: incluido (consentido por compu) → metered al agotarse
rm -f "$CONS"; write_state 19
Q="$(payload WFA '' sonnet)"
out="$(run_gate "$Q")";      is_ask "$out"    && ok "ventana · incluido 1º → pregunta"          || bad "ventana incluido 1º → ask; got: $out"
run_registrar "$Q"
out="$(run_gate "$Q")";      is_silent "$out" && ok "ventana · incluido consentido → silencio"  || bad "ventana incluido 2º → silencio; got: $out"
write_state 99   # se agota la ventana → mismo agente pasa a metered
out="$(run_gate "$Q")";      is_ask "$out"    && ok "ventana · agotada → vuelve a preguntar (metered)" || bad "ventana agotada → ask; got: $out"

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "== (b1b) limite-gasto: FRENA solo con la AND (ventana agotada Y overage sin holgura) =="
write_state_lg() { cat > "$CACHE/state.json" <<EOF
{ "five_hour":{"percent":$1}, "extra_usage":{"utilization":$2,"enabled":$3} }
EOF
}
run_limite() { HOME="$FAKEHOME" XDG_CACHE_HOME="$FAKEHOME/.cache" bash "$HOOKS/limite-gasto.sh" <<<"$1"; }
is_deny()    { printf '%s' "$1" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1; }
TP="$(payload WL general-purpose '')"
write_state_lg 10  100 true;  is_silent "$(run_limite "$TP")" && ok "lg: ventana fresca + overage topado → NO frena (plan cubre)"      || bad "lg: frenó con ventana fresca"
write_state_lg 100 50  true;  is_silent "$(run_limite "$TP")" && ok "lg: ventana agotada + overage con saldo → NO frena (gate pregunta)" || bad "lg: frenó teniendo saldo de overage"
write_state_lg 100 100 true;  is_deny   "$(run_limite "$TP")" && ok "lg: ventana agotada + overage topado → FRENA (sin capacidad)"      || bad "lg: NO frenó con ambos agotados"
write_state_lg 100 0   false; is_deny   "$(run_limite "$TP")" && ok "lg: ventana agotada + overage deshabilitado → FRENA"               || bad "lg: NO frenó sin overage y sin ventana"
write_state 19   # restablece el state.json de ventana para lo que siga

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "== (b2) secret-scan: bloquea un secreto staged, deja pasar lo limpio, respeta --no-verify =="
SCANREPO="$(mktemp -d "${TMPDIR:-/tmp}/brain-scan.XXXXXX")"
git -C "$SCANREPO" init -q >/dev/null 2>&1
git -C "$SCANREPO" config user.email t@t >/dev/null 2>&1
git -C "$SCANREPO" config user.name  tester >/dev/null 2>&1
scan() { printf '%s' "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"$1\"}}" \
         | CLAUDE_PROJECT_DIR="$SCANREPO" bash "$HOOKS/secret-scan.sh"; }
# (1) llave AWS falsa staged → deny
printf 'aws_key = AKIA1234567890ABCDEF\n' > "$SCANREPO/config.txt"
git -C "$SCANREPO" add config.txt >/dev/null 2>&1
o="$(scan 'git commit -m x')"
printf '%s' "$o" | grep -q '"deny"' && ok "secret-scan bloquea una llave AWS staged" || bad "secret-scan no bloqueó; got: $o"
# (2) --no-verify → pasa (escape deliberado)
o="$(scan 'git commit --no-verify -m x')"
[ -z "$o" ] && ok "secret-scan respeta --no-verify (escape)" || bad "secret-scan ignoró --no-verify; got: $o"
# (3) contenido limpio → silencio
git -C "$SCANREPO" reset -q >/dev/null 2>&1; rm -f "$SCANREPO/config.txt"
printf 'hola mundo, sin secretos\n' > "$SCANREPO/readme.txt"
git -C "$SCANREPO" add readme.txt >/dev/null 2>&1
o="$(scan 'git commit -m x')"
[ -z "$o" ] && ok "secret-scan deja pasar contenido limpio" || bad "secret-scan bloqueó limpio; got: $o"
# (4) un no-git → silencio
o="$(scan 'ls -la')"
[ -z "$o" ] && ok "secret-scan ignora comandos no-git" || bad "secret-scan reaccionó a no-git; got: $o"
rm -rf "$SCANREPO"

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "== (b3) proteger-arbol: avisa si un git destructivo orfanaría commits sin pushear =="
PABARE="$(mktemp -d "${TMPDIR:-/tmp}/brain-pa.XXXXXX")/remote.git"
PAREPO="$(mktemp -d "${TMPDIR:-/tmp}/brain-pa.XXXXXX")/wt"
git init --bare -q "$PABARE" >/dev/null 2>&1
git clone -q "$PABARE" "$PAREPO" >/dev/null 2>&1
git -C "$PAREPO" config user.email t@t >/dev/null 2>&1
git -C "$PAREPO" config user.name  tester >/dev/null 2>&1
printf 'base\n' > "$PAREPO/a.txt"; git -C "$PAREPO" add a.txt >/dev/null 2>&1
git -C "$PAREPO" commit -q -m base >/dev/null 2>&1
git -C "$PAREPO" push -q origin HEAD >/dev/null 2>&1
git -C "$PAREPO" branch --set-upstream-to=origin/"$(git -C "$PAREPO" rev-parse --abbrev-ref HEAD)" >/dev/null 2>&1
pa() { printf '%s' "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"$1\"}}" \
       | CLAUDE_PROJECT_DIR="$PAREPO" bash "$HOOKS/proteger-arbol.sh"; }
# sin commits en riesgo (todo pusheado) → reset --hard silencioso
o="$(pa 'git reset --hard HEAD')"
[ -z "$o" ] && ok "proteger-arbol: reset sin commits en riesgo → silencio" || bad "proteger-arbol avisó sin riesgo; got: $o"
# ahora 1 commit local SIN pushear → en riesgo
printf 'local\n' >> "$PAREPO/a.txt"; git -C "$PAREPO" add a.txt >/dev/null 2>&1
git -C "$PAREPO" commit -q -m local >/dev/null 2>&1
o="$(pa 'git reset --hard HEAD~1')"
printf '%s' "$o" | grep -q 'ORFANAR' && ok "proteger-arbol: reset --hard con commit sin pushear → AVISA" || bad "proteger-arbol NO avisó con commit en riesgo; got: $o"
# comando no-destructivo → silencio aunque haya riesgo
o="$(pa 'git status')"
[ -z "$o" ] && ok "proteger-arbol: comando no-destructivo → silencio" || bad "proteger-arbol reaccionó a no-destructivo; got: $o"
# 'git reset' entrecomillado (dato de un grep) → silencio
o="$(pa "grep -r 'git reset --hard' .")"
[ -z "$o" ] && ok "proteger-arbol: 'git reset' entrecomillado (dato) → silencio" || bad "proteger-arbol matcheó texto entrecomillado; got: $o"
rm -rf "$PABARE" "$PAREPO"

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "== (b4) dod-verificar: cierre/claim-visual sin evidencia bloquea; con OK o tool de navegador, no =="
DODTX="$FAKEHOME/dod-transcript.jsonl"
dod() { # dod "<texto final asistente>" "<línea extra de tool/edit o vacío>"
  { printf '%s\n' '{"type":"user","message":{"role":"user","content":[{"type":"text","text":"haz el cambio"}]}}'
    [ -n "$2" ] && printf '%s\n' "$2"
    jq -nc --arg t "$1" '{type:"assistant",message:{role:"assistant",content:[{type:"text",text:$t}]}}'
  } > "$DODTX"
  printf '%s' "{\"stop_hook_active\":false,\"transcript_path\":\"$DODTX\"}" | bash "$HOOKS/dod-verificar.sh"
}
is_block() { printf '%s' "$1" | jq -e '.decision == "block"' >/dev/null 2>&1; }
EDITR='{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Edit","input":{"file_path":"src/Foo.razor"}}]}}'
BROWSERT='{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"mcp__claude-in-chrome__navigate","input":{}}]}}'
is_block "$(dod '¡Cerrado! 🏁 el módulo quedó terminado.' "$EDITR")" && ok "dod B1: 'cerrado 🏁' + código sin OK → bloquea" || bad "dod B1 NO bloqueó cierre sin evidencia"
is_block "$(dod 'Lo dejé en preview, con tu OK lo cierro.' "$EDITR")" && bad "dod bloqueó lenguaje de estatus" || ok "dod: 'en preview / con tu OK' → no bloquea"
is_block "$(dod 'Quedó idéntico al mockup, se ve tal cual.' "$EDITR")" && ok "dod B2: claim visual sin browser-tool → bloquea (a ciegas)" || bad "dod B2 NO bloqueó claim visual a ciegas"
o="$(dod 'En Chrome se ve como el mockup.' "$BROWSERT")"; is_block "$o" && bad "dod B2 bloqueó con browser-tool presente; got: $o" || ok "dod B2: claim visual + browser-tool → no bloquea"
is_block "$(dod 'Quedó listo; validaste el QA visual y diste el ok.' "$EDITR")" && bad "dod bloqueó con (1) confirmación del usuario" || ok "dod: con (1) confirmación citada del usuario → no bloquea"
# P1 (precisión): una PREGUNTA no es un cierre, aunque traiga léxico de cierre → NO dispara
is_block "$(dod '¿ya quedó terminado el módulo?' "$EDITR")" && bad "dod P1: bloqueó una PREGUNTA (falso positivo del UUID)" || ok "dod P1: pregunta con léxico de cierre → no bloquea"
is_block "$(dod 'Terminé el fix. ¿Lo cierro y abro el MR?' "$EDITR")" && bad "dod P1: bloqueó una oferta que termina preguntando" || ok "dod P1: mensaje que termina en pregunta → no bloquea"
rm -f "$DODTX"

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "== (b5) compactación: precompact RETIRADO + rehidratar-hilo (inyecta + gate de staleness) =="
# precompact-volcar-estado se RETIRÓ (2026-07): PreCompact no puede inyectar contexto ni pedir acción
# (no hay turno antes de compactar) → era peso muerto. El "no perder el hilo" lo hacen checkpoint
# (escribe) + rehidratar-hilo (relee) + aviso-contexto (watermark). Verificamos que ya NO exista.
[ ! -f "$HOOKS/precompact-volcar-estado.sh" ] && ok "precompact-volcar-estado retirado (ya no existe)" || bad "precompact aún existe (debía retirarse)"

# rehidratar-hilo (SessionStart): con hilo → inyecta additionalContext; sin/vacío → silencio
RHROOT="$(mktemp -d "${TMPDIR:-/tmp}/brain-rh.XXXXXX")"
mkdir -p "$RHROOT/.claude/memory"
rh() { printf '%s' '{"source":"resume"}' | CLAUDE_PROJECT_DIR="$RHROOT" bash "$HOOKS/rehidratar-hilo.sh"; }
is_silent "$(rh)" && ok "rehidratar-hilo: sin hilo-mental-actual.md → silencio" || bad "rehidratar-hilo: esperaba silencio sin hilo"
: > "$RHROOT/.claude/memory/hilo-mental-actual.md"
is_silent "$(rh)" && ok "rehidratar-hilo: hilo vacío → silencio" || bad "rehidratar-hilo: esperaba silencio con hilo vacío"
printf '# Hilo mental actual\n## En qué estamos AHORA\nMARCA_HILO_XYZ\n' > "$RHROOT/.claude/memory/hilo-mental-actual.md"
rhout="$(rh)"
printf '%s' "$rhout" | jq -e '.hookSpecificOutput.hookEventName == "SessionStart"' >/dev/null 2>&1 \
  && ok "rehidratar-hilo: emite hookSpecificOutput SessionStart válido" || bad "rehidratar-hilo: JSON SessionStart inválido; got: $rhout"
printf '%s' "$rhout" | jq -r '.hookSpecificOutput.additionalContext' 2>/dev/null | grep -q 'MARCA_HILO_XYZ' \
  && ok "rehidratar-hilo: el cuerpo del hilo viaja en additionalContext" || bad "rehidratar-hilo: no encontré el cuerpo del hilo"

# staleness (A): hilo FRESCO → encabezado normal
printf '# Hilo mental actual\n> Última actualización: 2026-07-13 · rama %s\nMARCA_FRESCO\n' \
  "$(git -C "$RHROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo sinrepo)" \
  > "$RHROOT/.claude/memory/hilo-mental-actual.md"
printf '%s' "$(rh)" | jq -r '.hookSpecificOutput.additionalContext' 2>/dev/null | grep -q 'HILO MENTAL ACTUAL' \
  && ok "rehidratar-hilo: hilo fresco → encabezado normal" || bad "rehidratar-hilo: esperaba encabezado normal en fresco"
# staleness (B): mtime ANTIGUO (> umbral) → OBSOLETO
touch -t 202001010000 "$RHROOT/.claude/memory/hilo-mental-actual.md" 2>/dev/null
printf '%s' "$(rh)" | jq -r '.hookSpecificOutput.additionalContext' 2>/dev/null | grep -q 'OBSOLETO' \
  && ok "rehidratar-hilo: hilo viejo (mtime > umbral) → OBSOLETO" || bad "rehidratar-hilo: esperaba OBSOLETO en viejo"
# staleness (C): fresco pero de OTRA rama → OBSOLETO (umbral alto aísla la edad)
RHGIT="$(mktemp -d "${TMPDIR:-/tmp}/brain-rhg.XXXXXX")"
git -C "$RHGIT" init -q >/dev/null 2>&1; git -C "$RHGIT" config user.email t@t >/dev/null 2>&1
git -C "$RHGIT" config user.name tester >/dev/null 2>&1; git -C "$RHGIT" checkout -q -b rama-actual >/dev/null 2>&1
mkdir -p "$RHGIT/.claude/memory"
printf '# Hilo mental actual\n> Última actualización: 2026-07-13 · rama otra-rama-vieja\nMARCA_RAMA\n' > "$RHGIT/.claude/memory/hilo-mental-actual.md"
rhbranch="$(printf '%s' '{"source":"resume"}' | HILO_STALE_HORAS=100000 CLAUDE_PROJECT_DIR="$RHGIT" bash "$HOOKS/rehidratar-hilo.sh")"
printf '%s' "$rhbranch" | jq -r '.hookSpecificOutput.additionalContext' 2>/dev/null | grep -q 'OBSOLETO' \
  && ok "rehidratar-hilo: hilo de OTRA rama → OBSOLETO (aunque fresco)" || bad "rehidratar-hilo: esperaba OBSOLETO por rama; got: $rhbranch"
rm -rf "$RHGIT" "$RHROOT"

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "== (b6) aviso-contexto: avisa al cruzar banda, debounce, y se resetea con el baseline (compact) =="
ACROOT="$(mktemp -d "${TMPDIR:-/tmp}/brain-ac.XXXXXX")/r"
mkdir -p "$ACROOT/.claude/memory"
ACTX="$ACROOT/transcript.jsonl"
BASE_F="$ACROOT/.claude/memory/.contexto-baseline"
gen_tx() { : > "$ACTX"; i=0; while [ "$i" -lt "$1" ]; do printf 'x\n' >> "$ACTX"; i=$((i+1)); done; }
ac() { printf '%s' "{\"transcript_path\":\"$ACTX\"}" | AVISO_CONTEXTO_UMBRAL=10 CLAUDE_PROJECT_DIR="$ACROOT" bash "$HOOKS/aviso-contexto.sh"; }
has_aviso() { printf '%s' "$1" | jq -e '.hookSpecificOutput.hookEventName == "PostToolUse"' >/dev/null 2>&1; }
o="$(printf '%s' '{"transcript_path":"/no/existe"}' | AVISO_CONTEXTO_UMBRAL=10 CLAUDE_PROJECT_DIR="$ACROOT" bash "$HOOKS/aviso-contexto.sh")"
is_silent "$o" && ok "aviso-contexto: sin transcript → silencio" || bad "aviso-contexto reaccionó sin transcript; got: $o"
gen_tx 5;  is_silent "$(ac)" && ok "aviso-contexto: delta < umbral → silencio" || bad "aviso-contexto avisó bajo el umbral"
gen_tx 25; has_aviso "$(ac)" && ok "aviso-contexto: cruza banda nueva → avisa" || bad "aviso-contexto NO avisó al cruzar banda"
o="$(ac)"; is_silent "$o" && ok "aviso-contexto: misma banda → debounce (silencio)" || bad "aviso-contexto re-avisó la misma banda; got: $o"
gen_tx 45; has_aviso "$(ac)" && ok "aviso-contexto: banda mayor → vuelve a avisar" || bad "aviso-contexto NO re-avisó en banda mayor"
printf '45' > "$BASE_F"
gen_tx 48; is_silent "$(ac)" && ok "aviso-contexto: tras reset de baseline (compact) → silencio" || bad "aviso-contexto avisó justo tras el reset"
gen_tx 60; has_aviso "$(ac)" && ok "aviso-contexto: crece tras el reset → avisa de nuevo" || bad "aviso-contexto NO avisó tras crecer post-reset"
rm -rf "$(dirname "$ACROOT")"

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "== (b7) dedupe doble-cableado: la copia REPO cede si existe la GLOBAL; corre si no =="
DDNO="$(mktemp -d "${TMPDIR:-/tmp}/brain-ddno.XXXXXX")"
DDYES="$(mktemp -d "${TMPDIR:-/tmp}/brain-ddyes.XXXXXX")"; mkdir -p "$DDYES/.claude/hooks"
cp "$HOOKS/git-branch-guard.sh" "$DDYES/.claude/hooks/git-branch-guard.sh"
DDCMD='{"tool_name":"Bash","tool_input":{"command":"git push origin develop"}}'
o="$(printf '%s' "$DDCMD" | HOME="$DDNO" bash "$HOOKS/git-branch-guard.sh")"
printf '%s' "$o" | grep -q '"deny"' && ok "dedupe: SIN copia global → la copia repo CORRE (bloquea push a develop)" || bad "dedupe: repo debía bloquear sin global; got: $o"
o="$(printf '%s' "$DDCMD" | HOME="$DDYES" bash "$HOOKS/git-branch-guard.sh")"
is_silent "$o" && ok "dedupe: CON copia global → la copia repo CEDE (silencio; la global maneja)" || bad "dedupe: repo debía ceder con global; got: $o"
rm -rf "$DDNO" "$DDYES"

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "== (c) idempotencia: install-brain.sh 2× contra el \$HOME falso =="
FAKEHOME2="$(mktemp -d "${TMPDIR:-/tmp}/brain-inst.XXXXXX")"
HOME="$FAKEHOME2" bash "$INSTALLER" >/dev/null 2>&1
HOME="$FAKEHOME2" bash "$INSTALLER" >/dev/null 2>&1
GSET2="$FAKEHOME2/.claude/settings.json"
GCLAUDE2="$FAKEHOME2/.claude/CLAUDE.md"

for pat in git-branch-guard merge-squash-guard confirmar-merge-develop recordar-dashboard proteger-arbol rehidratar-hilo aviso-contexto delegacion-gate delegacion-registrar; do
  n="$(jq --arg p "$pat" '[.hooks[]?[]? | select(([.hooks[]?.command]|join(" "))|test($p))] | length' "$GSET2" 2>/dev/null)"
  if [ "$n" = "1" ]; then ok "settings.json: $pat cableado 1× (idempotente)"; else bad "settings.json: $pat aparece ${n:-?}× (esperaba 1)"; fi
done
b="$(grep -c 'BEGIN claude-brain' "$GCLAUDE2" 2>/dev/null || echo 0)"
e="$(grep -c 'END claude-brain'   "$GCLAUDE2" 2>/dev/null || echo 0)"
{ [ "$b" = "1" ] && [ "$e" = "1" ]; } && ok "CLAUDE.md: 1 solo bloque de normas (BEGIN/END)" || bad "CLAUDE.md: BEGIN=$b END=$e (esperaba 1/1)"
# la skill y la lib deben haber quedado instaladas
[ -f "$FAKEHOME2/.claude/skills/cerrar-slice/SKILL.md" ] && ok "skill cerrar-slice instalada" || bad "falta skill cerrar-slice"
[ -f "$FAKEHOME2/.claude/skills/checkpoint/SKILL.md" ]   && ok "skill checkpoint instalada"   || bad "falta skill checkpoint"
[ -f "$FAKEHOME2/.claude/hooks/rehidratar-hilo.sh" ]     && ok "hook rehidratar-hilo instalado" || bad "falta hook rehidratar-hilo"
[ -f "$FAKEHOME2/.claude/hooks/aviso-contexto.sh" ]      && ok "hook aviso-contexto instalado"  || bad "falta hook aviso-contexto"
[ -f "$FAKEHOME2/.claude/hooks/delegacion-comun.sh" ]    && ok "lib delegacion-comun.sh instalada" || bad "falta lib delegacion-comun.sh"

# Bonus: el desinstalador deja settings.json sin las entradas del cerebro y sin el bloque de normas
if [ -f "$SCRIPT_DIR/uninstall-brain.sh" ]; then
  HOME="$FAKEHOME2" bash "$SCRIPT_DIR/uninstall-brain.sh" >/dev/null 2>&1
  left="$(jq '[.hooks[]?[]? | select(([.hooks[]?.command]|join(" "))|test("git-branch-guard|merge-squash-guard|recordar-dashboard|delegacion-gate|delegacion-registrar"))] | length' "$GSET2" 2>/dev/null)"
  [ "${left:-x}" = "0" ] && ok "uninstall: 0 entradas del cerebro en settings.json" || bad "uninstall: quedan ${left:-?} entradas"
  grep -q 'BEGIN claude-brain' "$GCLAUDE2" && bad "uninstall: quedó el bloque de normas" || ok "uninstall: bloque de normas removido"
  [ -f "$FAKEHOME2/.claude/hooks/git-branch-guard.sh" ] && bad "uninstall: quedó git-branch-guard.sh" || ok "uninstall: hooks globales removidos"
fi
rm -rf "$FAKEHOME2"

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "== (c2) refresh de normas: un bloque VIEJO se REEMPLAZA en su lugar =="
FAKEHOME3="$(mktemp -d "${TMPDIR:-/tmp}/brain-refresh.XXXXXX")"
mkdir -p "$FAKEHOME3/.claude"
G3="$FAKEHOME3/.claude/CLAUDE.md"
printf 'mi config a mano (antes)\n\n<!-- BEGIN claude-brain -->\nNORMA VIEJA OBSOLETA\n<!-- END claude-brain -->\n\nmi config a mano (despues)\n' > "$G3"
HOME="$FAKEHOME3" bash "$INSTALLER" >/dev/null 2>&1
grep -q 'NORMA VIEJA OBSOLETA' "$G3" && bad "refresh: quedó la norma vieja (no reemplazó)" || ok "refresh: la norma vieja fue reemplazada"
grep -q 'Definición de' "$G3" && ok "refresh: el bloque nuevo quedó" || bad "refresh: falta el bloque nuevo"
n3="$(grep -c 'BEGIN claude-brain' "$G3" 2>/dev/null || echo 0)"
[ "$n3" = "1" ] && ok "refresh: 1 solo bloque tras refrescar" || bad "refresh: $n3 bloques (esperaba 1)"
{ grep -q 'mi config a mano (antes)' "$G3" && grep -q 'mi config a mano (despues)' "$G3"; } \
  && ok "refresh: conserva la config del usuario alrededor del bloque" || bad "refresh: se comió config del usuario"
rm -rf "$FAKEHOME3"

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "== (d) los .ps1 son ASCII puro (Windows PowerShell 5.1 lee un .ps1 sin BOM como ANSI, no UTF-8, =="
echo "==     y un no-ASCII -acento, em-dash, emoji- le rompe la tokenización. caso real: un Windows ajeno) =="
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
if command -v perl >/dev/null 2>&1; then
  # perl (no grep): determinista e igual en GNU/BSD/ugrep/Git-Bash. Sale 1 si hay algún byte >0x7F.
  ps1_noascii=0
  while IFS= read -r f; do
    if perl -0777 -ne 'exit(/[^\x00-\x7F]/ ? 1 : 0)' "$f" 2>/dev/null; then
      :   # ASCII limpio
    else
      bad "ASCII: $f tiene bytes no-ASCII (romperá PowerShell 5.1)"; ps1_noascii=1
    fi
  done < <(find "$REPO_ROOT" -name '*.ps1' -not -path '*/.git/*' -not -path '*/build/*')
  [ "$ps1_noascii" = 0 ] && ok "ASCII: todos los .ps1 son ASCII puro (a prueba de PowerShell 5.1)"
else
  echo "  (perl no disponible -> salto el guard ASCII de .ps1)"
fi

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "== (e) sin referencias circulares NUEVAS entre elementos del cerebro =="
# Allowlist de pares bidireccionales BENIGNOS conocidos (skill<->hook enforcement / lib<->consumidor /
# hooks-hermanos). Un par NUEVO fuera de aqui = posible referencia circular -> revisalo (peor que una
# contradiccion). El test COMPUTA los pares en cada corrida, no depende de contarlos a mano.
CE_ALLOW="cerrar-slice|merge-squash-guard
cerrar-slice|recordar-dashboard
delegacion-comun|delegacion-gate
delegacion-comun|delegacion-registrar
delegacion-gate|limite-gasto
delegacion-reporte|orquestar-fanout
cerrar-slice|checkpoint
cerrar-slice|rehidratar-hilo
checkpoint|rehidratar-hilo
aviso-contexto|rehidratar-hilo"
ce_els=()
for d in "$SCRIPT_DIR"/skills/*/; do [ -d "$d" ] && ce_els+=("$(basename "$d")"); done
for h in "$HOOKS"/*.sh; do [ -e "$h" ] && ce_els+=("$(basename "$h" .sh)"); done
ce_fileof() { if [ -f "$SCRIPT_DIR/skills/$1/SKILL.md" ]; then echo "$SCRIPT_DIR/skills/$1/SKILL.md"; elif [ -f "$HOOKS/$1.sh" ]; then echo "$HOOKS/$1.sh"; fi; }
ce_new=0
for x in "${ce_els[@]}"; do
  fx="$(ce_fileof "$x")"; [ -z "$fx" ] && continue
  for y in "${ce_els[@]}"; do
    [[ "$x" < "$y" ]] || continue
    fy="$(ce_fileof "$y")"; [ -z "$fy" ] && continue
    if grep -qw "$y" "$fx" 2>/dev/null && grep -qw "$x" "$fy" 2>/dev/null; then
      if ! printf '%s\n' "$CE_ALLOW" | grep -qxF "$x|$y"; then
        bad "ref bidireccional NUEVA (¿circular?): $x <-> $y — revísala (o agrégala al allowlist si es benigna)"; ce_new=1
      fi
    fi
  done
done
[ "$ce_new" = 0 ] && ok "sin referencias circulares nuevas (los pares bidireccionales presentes son los benignos del allowlist)"

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "==> resultado: $PASS PASS · $FAIL FAIL"
[ "$FAIL" -eq 0 ]
