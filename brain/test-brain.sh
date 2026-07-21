#!/usr/bin/env bash
# test-brain.sh — pruebas VERSIONADAS y REPETIBLES del cerebro (claude-brain). No toca tu ~/.claude:
# todo corre contra un $HOME FALSO aislado (mktemp) que se borra al final.
#
# Cubre:
#   (a) sintaxis: `bash -n` de todos los hooks .sh + `jq empty` de todos los .json de brain/.
#   (b) gate de delegación: casos gratis / incluido / metered(overage) / metered(externo) /
#       desconocido, el ciclo gate→registrar→gate-silencioso, y la transición dentro/fuera de la
#       ventana de 5h (incluido → metered al agotarse la ventana).
#   (b5) compactación: precompact RETIRADO (ya no existe el .sh) + rehidratar-hilo inyecta/silencia
#        según exista el hilo, con gate de frescura (viejo/otra-rama → "⚠️ posiblemente OBSOLETO").
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

# G3 — fan-out PARALELO: el 1er gate del lote pregunta; los HERMANOS (misma sesión+key, aún sin
# registrar) pasan en SILENCIO (coalescing) para gratis/incluido → mata el flood de N asks. Metered
# NO se coalesce (un fan-out de PAGO confirma cada uno: un 'no' no debe dejar correr agentes caros).
rm -f "$CONS"; rm -rf "$CDIR"/.delegacion-ask.*.lock 2>/dev/null; write_state 19
B="$(payload BATCH '' sonnet)"   # incluido (ventana 19% < 90%)
out="$(run_gate "$B")"; is_ask "$out"    && ok "G3 fan-out · 1er gate del lote → pregunta"             || bad "G3: 1er gate no preguntó; got: $out"
out="$(run_gate "$B")"; is_silent "$out" && ok "G3 fan-out · hermano del lote → silencio (coalesced)"  || bad "G3: el hermano volvió a preguntar (flood); got: $out"
rm -f "$CONS"; rm -rf "$CDIR"/.delegacion-ask.*.lock 2>/dev/null; write_state 99
M="$(payload BATCHM '' gpt-4o)"  # metered (API externa de pago)
out="$(run_gate "$M")"; is_ask "$out"    && ok "G3 · metered 1er gate → pregunta"                      || bad "G3 metered 1º → ask; got: $out"
out="$(run_gate "$M")"; is_ask "$out"    && ok "G3 · metered hermano → SIGUE preguntando (protección)" || bad "G3 metered hermano → debía seguir preguntando; got: $out"

# H6 — un ask NEGADO no persiste consentimiento (el registrar NO corre). Antes, dentro de la vieja
# ventana de 60s, el lock de coalescencia dejaba colar el reintento en SILENCIO. Ahora la ventana es
# corta (CLAUDE_DELEG_COALESCE_S): fuera de ella el lock se recicla → el reintento VUELVE a preguntar.
rm -f "$CONS"; rm -rf "$CDIR"/.delegacion-ask.*.lock 2>/dev/null; write_state 19
H6P="$(payload H6SESS '' sonnet)"   # incluido (ventana 19% < 90%)
out="$(run_gate "$H6P")"; is_ask "$out" && ok "H6 · 1er gate (usuario luego NIEGA) → pregunta" || bad "H6: 1er gate no preguntó; got: $out"
# sin registrar (= el usuario NEGÓ) + reintento FUERA de la ventana (COALESCE_S=0 recicla el lock)
out="$(HOME="$FAKEHOME" XDG_CACHE_HOME="$FAKEHOME/.cache" CLAUDE_DELEG_COALESCE_S=0 bash "$HOOKS/delegacion-gate.sh" <<<"$H6P")"
is_ask "$out" && ok "H6 · 'no' + reintento fuera de ventana → RE-pregunta (no cuela en silencio)" || bad "H6: el reintento tras negar coló en silencio; got: $out"
# y el registrar LIBERA el lock al APROBAR → la ruta feliz no deja fantasma
rm -rf "$CDIR"/.delegacion-ask.*.lock 2>/dev/null
run_gate "$H6P" >/dev/null 2>&1        # crea el lock del lote
run_registrar "$H6P"                    # aprobar → registra consentimiento + libera el lock
ls "$CDIR"/.delegacion-ask.*.lock >/dev/null 2>&1 && bad "H6: el registrar dejó el lock del lote (fantasma)" || ok "H6 · registrar libera el lock de coalescencia al aprobar (sin fantasma)"
rm -f "$CONS"; rm -rf "$CDIR"/.delegacion-ask.*.lock 2>/dev/null
write_state 19

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
echo "== (b1c) merge-squash-guard: EXIGE squash SOLO si destino=develop confirmado (G4) =="
# Modelo canónico (decisión del usuario): squash únicamente cuando el destino es develop CONFIRMADO;
# main (release), ramas personales, ramitas y destino INDETERMINADO → libres (nunca se fuerza squash).
rm -f "${TMPDIR:-/tmp}"/acg-mrdest-* 2>/dev/null   # caché de destino limpia (la lib cachea por MR-id)
MSBIN="$FAKEHOME/msbin"; mkdir -p "$MSBIN"
mock_glab() { printf '#!/usr/bin/env bash\necho '\''{"target_branch":"%s"}'\''\n' "$1" > "$MSBIN/glab"; chmod +x "$MSBIN/glab"; }
ms() { PATH="$MSBIN:$PATH" HOME="$FAKEHOME" CLAUDE_PROJECT_DIR="$FAKEHOME" bash "$HOOKS/merge-squash-guard.sh" <<<"{\"tool_input\":{\"command\":\"$1\"}}"; }
# NOTA: la lib cachea el destino por MR-id (compartido squash↔confirmar), así que cada caso usa un
# MR-id DISTINTO — si no, la caché del 1er caso (develop) contaminaría a los siguientes. En producción
# cada MR tiene su id; aquí es un artefacto de reusar mocks con el mismo número.
mock_glab develop; out="$(ms 'glab mr merge 42 --auto-merge --yes')"
is_deny "$out"   && ok "squash-guard G4: destino=develop confirmado, sin --squash → deny" || bad "squash-guard G4: no denegó merge a develop sin squash; got: $out"
mock_glab develop; out="$(ms 'glab mr merge 42 --squash --auto-merge --yes')"
is_silent "$out" && ok "squash-guard G4: develop CON --squash → pasa"                     || bad "squash-guard G4: bloqueó un merge que ya trae squash; got: $out"
mock_glab DevelopAna; out="$(ms 'glab mr merge 43 --auto-merge --yes')"
is_silent "$out" && ok "squash-guard G4: destino=rama personal → NO fuerza squash (día a día libre)" || bad "squash-guard G4: forzó squash a rama personal; got: $out"
mock_glab main; out="$(ms 'glab mr merge 44 --yes')"
is_silent "$out" && ok "squash-guard G4: destino=main (release) → NO fuerza squash"       || bad "squash-guard G4: forzó squash a un release; got: $out"
out="$(ms 'glab mr merge --auto-merge --yes')"   # sin ID → destino indeterminado
is_silent "$out" && ok "squash-guard G4: destino INDETERMINADO → NO fuerza squash (fail-safe hacia libre)" || bad "squash-guard G4: forzó squash con destino indeterminado; got: $out"
rm -f "${TMPDIR:-/tmp}"/acg-mrdest-* 2>/dev/null
rm -rf "$MSBIN"

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "== (b1d) git-branch-guard: push PELÓN / comillas / nombre-de-repo (H1/H11/H13) =="
GBROOT="$(mktemp -d "${TMPDIR:-/tmp}/brain-gb.XXXXXX")"; GBREPO="$GBROOT/repo"; GBHOME="$GBROOT/home"; mkdir -p "$GBREPO" "$GBHOME"
git -C "$GBREPO" init -q >/dev/null 2>&1
git -C "$GBREPO" config user.email t@t >/dev/null 2>&1; git -C "$GBREPO" config user.name tester >/dev/null 2>&1
printf 'base\n' > "$GBREPO/a.txt"; git -C "$GBREPO" add a.txt >/dev/null 2>&1; git -C "$GBREPO" commit -qm base >/dev/null 2>&1
git -C "$GBREPO" branch -M develop >/dev/null 2>&1
# HOME sin copia global → corre la copia del repo (no cede por dedupe)
gb() { jq -nc --arg c "$1" '{tool_name:"Bash",tool_input:{command:$c}}' | CLAUDE_PROJECT_DIR="$GBREPO" HOME="$GBHOME" bash "$HOOKS/git-branch-guard.sh"; }
git -C "$GBREPO" checkout -q develop >/dev/null 2>&1
printf '%s' "$(gb 'git push')"        | grep -q '"deny"' && ok "gbg H1: 'git push' pelón en develop → deny"          || bad "gbg H1: push pelón en develop NO bloqueó"
printf '%s' "$(gb 'git push --force')"| grep -q '"deny"' && ok "gbg H1: 'git push --force' pelón en develop → deny"  || bad "gbg H1: push --force pelón NO bloqueó"
printf '%s' "$(gb 'git push origin HEAD')" | grep -q '"deny"' && ok "gbg H1: 'git push origin HEAD' en develop → deny" || bad "gbg H1: push HEAD en develop NO bloqueó"
git -C "$GBREPO" checkout -q -b feat/x >/dev/null 2>&1
is_silent "$(gb 'git push')"              && ok "gbg H1: 'git push' pelón en ramita → silencio (sin falso positivo)" || bad "gbg H1: push pelón en ramita bloqueó"
is_silent "$(gb 'git push -u origin feat/x')" && ok "gbg: push explícito de la ramita → silencio"                    || bad "gbg: push de ramita bloqueó"
printf '%s' "$(gb 'git push origin develop')" | grep -q '"deny"' && ok "gbg: 'git push origin develop' explícito → deny (preservado)" || bad "gbg: push explícito a develop NO bloqueó"
is_silent "$(gb 'git commit -m "doc: no hacer git push a develop"')" && ok "gbg H13: 'git push a develop' entrecomillado → silencio" || bad "gbg H13: mención entrecomillada disparó"
is_silent "$(gb 'gh pr merge 5 -R org/develop --squash')" && ok "gbg H11: '-R org/develop' (nombre de repo) → silencio" || bad "gbg H11: -R org/develop disparó falso positivo"
rm -rf "$GBROOT"

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "== (b1e) confirmar-merge-develop: escape ANCLADO al subcomando (H3) + destino cacheado/timeout (H5) =="
# Antes NO tenía test de comportamiento. H3: el escape casaba `status|list|view` como token suelto en
# CUALQUIER parte → `glab mr merge 5 && git status` evadía el gate. H5: 2 llamadas de red idénticas +
# fail-open si el proceso lo mata el timeout del hook. La lógica ahora vive en la lib (acg_es_merge_mr,
# acg_destino_de_mr con caché por MR-id + timeout interno).
rm -f "${TMPDIR:-/tmp}"/acg-mrdest-* 2>/dev/null
CMROOT="$(mktemp -d "${TMPDIR:-/tmp}/brain-cm.XXXXXX")"; CMREPO="$CMROOT/repo"; CMHOME="$CMROOT/home"; CMBIN="$CMROOT/bin"; CMTX="$CMROOT/tx.jsonl"
mkdir -p "$CMREPO/.claude" "$CMHOME" "$CMBIN"
: > "$CMREPO/.claude/repo-compartido"                    # marca de repo compartido (gatea el candado)
git -C "$CMREPO" init -q >/dev/null 2>&1
git -C "$CMREPO" remote add origin git@gitlab.com:org/repo.git >/dev/null 2>&1   # para derivar el repo
mock_cm_glab() { printf '#!/usr/bin/env bash\necho '\''{"target_branch":"%s"}'\''\n' "$1" > "$CMBIN/glab"; chmod +x "$CMBIN/glab"; }
# cm "<cmd>" "<último mensaje del usuario>"  → corre el hook (HOME sin copia global → no cede por dedupe)
cm() {
  printf '%s\n' "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"$2\"}]}}" > "$CMTX"
  jq -nc --arg c "$1" --arg t "$CMTX" '{tool_input:{command:$c},transcript_path:$t}' \
    | PATH="$CMBIN:$PATH" HOME="$CMHOME" CLAUDE_PROJECT_DIR="$CMREPO" bash "$HOOKS/confirmar-merge-develop.sh"
}
mock_cm_glab develop
# H3: merge REAL con un `&& git status` encadenado, SIN OK → deny (el `status` ya NO evade el gate).
is_deny "$(cm 'glab mr merge 5 --yes && git status' 'haz el cambio')" \
  && ok "cmd H3: 'glab mr merge 5 && git status' sin OK → deny (escape ya NO se dispara por token suelto)" \
  || bad "cmd H3: el token 'status' encadenado evadió el gate (fail-open)"
# H3: inspección genuina (no matchea merge|accept) → silencio.
is_silent "$(cm 'glab mr view 5' 'haz el cambio')" \
  && ok "cmd H3: 'glab mr view' (inspección) → silencio" || bad "cmd H3: bloqueó una inspección"
# Con OK explícito citado → pasa (aunque traiga el `&& git status`).
is_silent "$(cm 'glab mr merge 5 --yes && git status' 'ya lo revisé, mérgalo')" \
  && ok "cmd: merge a develop CON OK explícito → pasa" || bad "cmd: bloqueó un merge con OK citado"
# Baseline: merge a develop SIN OK → deny.
is_deny "$(cm 'glab mr merge 5 --yes' 'sigue avanzando')" \
  && ok "cmd: merge a develop sin OK ('sigue' NO cuenta) → deny" || bad "cmd: no bloqueó merge a develop sin OK"
# H5 (lib): caché por MR-id → la 2ª consulta NO re-llama a la red (comparte destino entre squash+confirmar).
d1=$(PATH="$CMBIN:$PATH" CLAUDE_PROJECT_DIR="$CMREPO" bash -c '. "'"$HOOKS"'/analizar-comando-git.sh"; acg_destino_de_mr "glab mr merge 123"')
mock_cm_glab main   # si re-llamara, ahora diría main; la caché debe seguir dando develop
d2=$(PATH="$CMBIN:$PATH" CLAUDE_PROJECT_DIR="$CMREPO" bash -c '. "'"$HOOKS"'/analizar-comando-git.sh"; acg_destino_de_mr "glab mr merge 123"')
{ [ "$d1" = develop ] && [ "$d2" = develop ]; } \
  && ok "cmd H5: destino cacheado por MR-id (2ª consulta lee caché, no re-llama a la red)" \
  || bad "cmd H5: la caché por MR-id no se usó (d1='$d1' d2='$d2')"
# H5 (lib): un glab COLGADO se acota por el timeout interno → devuelve vacío RÁPIDO (no fail-open por
# muerte del proceso; el consumidor cae a su fail-policy y EMITE su decisión).
printf '#!/usr/bin/env bash\nsleep 5\necho '\''{"target_branch":"develop"}'\''\n' > "$CMBIN/glab"; chmod +x "$CMBIN/glab"
SECONDS=0
dhang=$(PATH="$CMBIN:$PATH" CLAUDE_PROJECT_DIR="$CMREPO" ACG_MR_TIMEOUT=1 bash -c '. "'"$HOOKS"'/analizar-comando-git.sh"; acg_destino_de_mr "glab mr merge 456"')
dur=$SECONDS
{ [ -z "$dhang" ] && [ "$dur" -lt 4 ]; } \
  && ok "cmd H5: glab colgado → timeout interno devuelve vacío en ${dur}s (no cuelga hasta que lo maten)" \
  || bad "cmd H5: la consulta colgada NO fue acotada por timeout (dhang='$dhang' dur=${dur}s)"
rm -f "${TMPDIR:-/tmp}"/acg-mrdest-* 2>/dev/null

# ── (b1f) confirmar: AUTORIZACIÓN DURABLE en disco (sobrevive compactaciones) + vocabulario "empuja/mete" ──
# El grant lo escribe el skill turno-nocturno con la CITA textual del usuario y vence_epoch; SOLO
# cubre scope=merge-develop. Caso real 2026-07-12: un OK blanket murió al compactarse el contexto.
echo ""
echo "== (b1f) confirmar-merge-develop: autorización durable (vence_epoch) + vocabulario empuja/mete =="
AUTHF="$CMREPO/.claude/memory/autorizaciones-vigentes.local.md"
mkdir -p "$CMREPO/.claude/memory"
mock_cm_glab develop
# (1) grant VIGENTE → permite el merge a develop aunque el transcript no traiga OK.
printf -- '- scope=merge-develop vence_epoch=%s vence="mañana 10am" cita="autorizo todos los merges a develop hasta mañana 10am" registrada=2026-07-18\n' "$(( $(date +%s) + 3600 ))" > "$AUTHF"
is_silent "$(cm 'glab mr merge 61 --squash --yes' 'sigue avanzando')" \
  && ok "cmd b1f: grant durable VIGENTE → merge a develop pasa (sobrevive compactación)" \
  || bad "cmd b1f: grant durable vigente NO destrabó el merge a develop"
# (2) grant VENCIDO → freno normal.
printf -- '- scope=merge-develop vence_epoch=%s vence="ayer" cita="autorizo hasta ayer" registrada=2026-07-17\n' "$(( $(date +%s) - 60 ))" > "$AUTHF"
is_deny "$(cm 'glab mr merge 62 --squash --yes' 'sigue avanzando')" \
  && ok "cmd b1f: grant VENCIDO → deny (no se estira)" \
  || bad "cmd b1f: un grant vencido dejó pasar el merge"
# (3) línea malformada (sin vence_epoch) → freno normal (fail-safe).
printf -- '- scope=merge-develop cita="sin vencimiento"\n' > "$AUTHF"
is_deny "$(cm 'glab mr merge 63 --squash --yes' 'sigue avanzando')" \
  && ok "cmd b1f: grant malformado (sin vence_epoch) → deny (fail-safe)" \
  || bad "cmd b1f: una línea malformada dejó pasar el merge"
# (4) EL MÁS IMPORTANTE: grant vigente pero destino MAIN → sigue exigiendo release súper-explícito.
printf -- '- scope=merge-develop vence_epoch=%s vence="+1h" cita="autorizo todos los merges a develop" registrada=hoy\n' "$(( $(date +%s) + 3600 ))" > "$AUTHF"
mock_cm_glab main
is_deny "$(cm 'glab mr merge 64 --yes' 'sigue avanzando')" \
  && ok "cmd b1f: grant develop vigente + destino MAIN → deny (main intacto, JAMÁS lo cubre el grant)" \
  || bad "cmd b1f: ¡el grant de develop destrabó un RELEASE a main! (aflojamiento grave)"
# (5) archivo ausente → comportamiento de siempre.
rm -f "$AUTHF"
mock_cm_glab develop
is_deny "$(cm 'glab mr merge 65 --squash --yes' 'sigue avanzando')" \
  && ok "cmd b1f: sin archivo de grants → deny normal (sin cambios de baseline)" \
  || bad "cmd b1f: sin archivo el guard dejó de frenar"
# (6) vocabulario: "empuja todo a develop" y "mete todo a develop" cuentan como OK explícito.
CMDCR2=$(grep "^CONF_RE=" "$HOOKS/confirmar-merge-develop.sh" | sed "s/^[^']*'//; s/'\$//")
printf '%s' "empuja todo lo que ya tienes a develop" | grep -qiE "$CMDCR2" && ok "cmd b1f: reconoce 'empuja todo … a develop'" || bad "cmd b1f: NO reconoce 'empuja … a develop' (falso-FRENO real)"
printf '%s' "mete todo eso a develop porfa"          | grep -qiE "$CMDCR2" && ok "cmd b1f: reconoce 'mete todo … a develop'"   || bad "cmd b1f: NO reconoce 'mete … a develop'"
printf '%s' "empújalo cuando puedas, a develop"      | grep -qiE "$CMDCR2" && ok "cmd b1f: reconoce 'empújalo … a develop'"     || bad "cmd b1f: NO reconoce 'empújalo'"
printf '%s' "no empujes nada todavía"                | grep -qiE "$CMDCR2" && bad "cmd b1f: FALSO POSITIVO con 'no empujes nada' (sin develop)" || ok "cmd b1f: 'empujes' sin develop NO dispara (acotado)"
rm -f "${TMPDIR:-/tmp}"/acg-mrdest-* 2>/dev/null
rm -rf "$CMROOT"

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "== (b2) secret-scan: bloquea un secreto staged, deja pasar lo limpio, respeta --no-verify =="
SCANREPO="$(mktemp -d "${TMPDIR:-/tmp}/brain-scan.XXXXXX")"
git -C "$SCANREPO" init -q >/dev/null 2>&1
git -C "$SCANREPO" config user.email t@t >/dev/null 2>&1
git -C "$SCANREPO" config user.name  tester >/dev/null 2>&1
# HOME sin copia global de secret-scan → la dedupe doble-cableado no cede (corre la copia bajo prueba).
scan() { printf '%s' "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"$1\"}}" \
         | HOME="$SCANREPO" CLAUDE_PROJECT_DIR="$SCANREPO" bash "$HOOKS/secret-scan.sh"; }
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
# ── §D: patrones NUEVOS (JWT, connection string, Password=) vía la lib detectar-secretos ──
reset_scan() { git -C "$SCANREPO" reset -q >/dev/null 2>&1; rm -f "$SCANREPO"/*.txt 2>/dev/null; }
# (6) JWT
reset_scan; printf 'jwt: eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c\n' > "$SCANREPO/j.txt"
git -C "$SCANREPO" add j.txt >/dev/null 2>&1; o="$(scan 'git commit -m x')"
printf '%s' "$o" | grep -q '"deny"' && ok "secret-scan §D: JWT (eyJ.eyJ.firma) → deny" || bad "secret-scan §D: no bloqueó un JWT; got: $o"
# (7) connection string con creds embebidas (user:pass@host)
reset_scan; printf 'db = postgres://admin:s3cr3tp4ss@db.internal:5432/prod\n' > "$SCANREPO/c.txt"
git -C "$SCANREPO" add c.txt >/dev/null 2>&1; o="$(scan 'git commit -m x')"
printf '%s' "$o" | grep -q '"deny"' && ok "secret-scan §D: connstring user:pass@host → deny" || bad "secret-scan §D: no bloqueó creds en URL; got: $o"
# (8) Password= estilo .NET con valor REAL → deny; con \$VAR de entorno → silencio (no es secreto en claro)
reset_scan; printf 'conn = "Server=db;User Id=sa;Password=Sup3rSecret!;"\n' > "$SCANREPO/p.txt"
git -C "$SCANREPO" add p.txt >/dev/null 2>&1; o="$(scan 'git commit -m x')"
printf '%s' "$o" | grep -q '"deny"' && ok "secret-scan §D: Password=<valor real> → deny" || bad "secret-scan §D: no bloqueó Password= real; got: $o"
reset_scan; printf 'conn = "Server=db;Password=${DB_PASS};"\n' > "$SCANREPO/e.txt"
git -C "$SCANREPO" add e.txt >/dev/null 2>&1; o="$(scan 'git commit -m x')"
[ -z "$o" ] && ok 'secret-scan §D: Password=${VAR} (ref de entorno) → silencio (sin falso positivo)' || bad "secret-scan §D: falso positivo con Password=\${VAR}; got: $o"
rm -rf "$SCANREPO"
# (9) §D fail-open vs fail-closed: en un NO-repo, default → fail-OPEN (silencio); STRICT=1 → fail-CLOSED (deny)
NONGIT="$(mktemp -d "${TMPDIR:-/tmp}/brain-nogit.XXXXXX")"
o="$(printf '%s' '{"tool_input":{"command":"git commit -m x"}}' | HOME="$NONGIT" CLAUDE_PROJECT_DIR="$NONGIT" bash "$HOOKS/secret-scan.sh")"
[ -z "$o" ] && ok "secret-scan §D: no-repo + default → fail-OPEN (silencio)" || bad "secret-scan §D: default no fue fail-open en no-repo; got: $o"
o="$(printf '%s' '{"tool_input":{"command":"git commit -m x"}}' | HOME="$NONGIT" CLAUDE_PROJECT_DIR="$NONGIT" CLAUDE_SECRET_SCAN_STRICT=1 bash "$HOOKS/secret-scan.sh")"
printf '%s' "$o" | grep -q '"deny"' && ok "secret-scan §D: no-repo + STRICT=1 → fail-CLOSED (deny)" || bad "secret-scan §D: STRICT no bloqueó en no-repo; got: $o"
rm -rf "$NONGIT"

# (5) G5: PRIMER push de una rama NUEVA sin upstream → antes fail-open (no escaneaba); ahora escanea lo
# que la rama AGREGA vs el merge-base con develop/main.
G5ROOT="$(mktemp -d "${TMPDIR:-/tmp}/brain-g5.XXXXXX")"; G5REPO="$G5ROOT/repo"; mkdir -p "$G5REPO"
git -C "$G5REPO" init -q >/dev/null 2>&1
git -C "$G5REPO" symbolic-ref HEAD refs/heads/main >/dev/null 2>&1
git -C "$G5REPO" config user.email t@t >/dev/null 2>&1
git -C "$G5REPO" config user.name  tester >/dev/null 2>&1
printf 'base limpia\n' > "$G5REPO/base.txt"; git -C "$G5REPO" add base.txt >/dev/null 2>&1; git -C "$G5REPO" commit -qm base >/dev/null 2>&1
git -C "$G5REPO" branch develop >/dev/null 2>&1
scan5() { printf '%s' "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"$1\"}}" | HOME="$G5REPO" CLAUDE_PROJECT_DIR="$G5REPO" bash "$HOOKS/secret-scan.sh"; }
git -C "$G5REPO" checkout -q -b feat/nueva >/dev/null 2>&1
printf 'key = AKIA1234567890ABCDEF\n' > "$G5REPO/secreto.txt"; git -C "$G5REPO" add secreto.txt >/dev/null 2>&1; git -C "$G5REPO" commit -qm add >/dev/null 2>&1
o="$(scan5 'git push -u origin feat/nueva')"
printf '%s' "$o" | grep -q '"deny"' && ok "secret-scan G5: 1er push de rama nueva (sin upstream) escanea vs merge-base → bloquea" || bad "secret-scan G5: NO bloqueó el secreto en el 1er push de rama nueva; got: $o"
git -C "$G5REPO" checkout -q main >/dev/null 2>&1; git -C "$G5REPO" checkout -q -b feat/limpia >/dev/null 2>&1
printf 'sin secretos\n' > "$G5REPO/nota.txt"; git -C "$G5REPO" add nota.txt >/dev/null 2>&1; git -C "$G5REPO" commit -qm nota >/dev/null 2>&1
o="$(scan5 'git push -u origin feat/limpia')"
[ -z "$o" ] && ok "secret-scan G5: 1er push de rama nueva LIMPIA → silencio (sin falso positivo)" || bad "secret-scan G5: falso positivo en rama nueva limpia; got: $o"
rm -rf "$G5ROOT"

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

# H14 — worktree AISLADO: el desastre que vigila el hook (orfanar commits del ORQUESTADOR en el árbol
# COMPARTIDO) es imposible ahí, y el workaround del bug H15 (reset --hard a la rama objetivo al arrancar)
# NO debe disparar la alarma. Montamos un worktree aislado con 1 commit adelante de su upstream (n>0).
DEFB="$(git -C "$PAREPO" rev-parse --abbrev-ref HEAD)"
PAWT="$(mktemp -d "${TMPDIR:-/tmp}/brain-pawt.XXXXXX")/iso"
git -C "$PAREPO" worktree add -q -b wtiso "$PAWT" "origin/$DEFB" >/dev/null 2>&1
git -C "$PAWT" branch --set-upstream-to=origin/"$DEFB" wtiso >/dev/null 2>&1
printf 'iso\n' >> "$PAWT/a.txt"; git -C "$PAWT" add a.txt >/dev/null 2>&1
git -C "$PAWT" commit -q -m iso >/dev/null 2>&1   # 1 commit adelante del upstream → n=1
paw() { printf '%s' "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"$1\"}}" \
        | CLAUDE_PROJECT_DIR="$PAWT" bash "$HOOKS/proteger-arbol.sh"; }
o="$(paw 'git reset --hard wtiso')"
[ -z "$o" ] && ok "proteger-arbol H14: aislado + reset a su PROPIA rama → SUPRIME (silencio)" || bad "H14: no suprimió el reset a la propia rama; got: $o"
o="$(paw 'git reset --hard develop')"
[ -z "$o" ] && ok "proteger-arbol H14: aislado + reset a una BASE (develop) → SUPRIME (workaround H15)" || bad "H14: no suprimió el reset a base; got: $o"
o="$(paw 'git reset --hard HEAD~1')"
{ printf '%s' "$o" | grep -q 'Nota (proteger-arbol)' && ! printf '%s' "$o" | grep -q 'ORFANAR'; } \
  && ok "proteger-arbol H14: aislado + OTRO objetivo → nota SUAVE (no alarma de árbol compartido)" \
  || bad "H14: aislado hacia otro objetivo no dio nota suave; got: $o"
git -C "$PAREPO" worktree remove --force "$PAWT" >/dev/null 2>&1; rm -rf "$PAWT"
rm -rf "$PABARE" "$PAREPO"

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "== (b3b) limpiar-worktrees: base de integración configurable + detección por cherry (G7) =="
# Flujo mini-develop: la base es una rama PERSONAL (no develop) y las ramitas se integran por merge
# LOCAL (a veces squash) → antes quedaban zombies eternos (base fija a develop + sin detección por
# equivalencia de parche). Ahora: CLAUDE_INTEGRACION_BASE fija la base; git cherry caza el squash local.
G7ROOT="$(mktemp -d "${TMPDIR:-/tmp}/brain-g7.XXXXXX")"; G7REPO="$G7ROOT/repo"; mkdir -p "$G7REPO"
git -C "$G7REPO" init -q >/dev/null 2>&1
git -C "$G7REPO" symbolic-ref HEAD refs/heads/miDevelop >/dev/null 2>&1
git -C "$G7REPO" config user.email t@t >/dev/null 2>&1
git -C "$G7REPO" config user.name  tester >/dev/null 2>&1
printf 'base\n' > "$G7REPO/base.txt"; git -C "$G7REPO" add base.txt >/dev/null 2>&1; git -C "$G7REPO" commit -qm base >/dev/null 2>&1
# ramita MERGEADA por squash LOCAL a la rama personal (no queda de ancestro, pero su parche sí está)
git -C "$G7REPO" checkout -q -b feat/hecha >/dev/null 2>&1
printf 'x\n' > "$G7REPO/f.txt"; git -C "$G7REPO" add f.txt >/dev/null 2>&1; git -C "$G7REPO" commit -qm hecha >/dev/null 2>&1
git -C "$G7REPO" checkout -q miDevelop >/dev/null 2>&1
git -C "$G7REPO" merge --squash feat/hecha >/dev/null 2>&1; git -C "$G7REPO" commit -qm "squash feat/hecha" >/dev/null 2>&1
git -C "$G7REPO" worktree add -q "$G7ROOT/wt-hecha" feat/hecha >/dev/null 2>&1
# ramita VIVA (commits nuevos aún no integrados)
git -C "$G7REPO" checkout -q -b feat/viva miDevelop >/dev/null 2>&1
printf 'y\n' > "$G7REPO/g.txt"; git -C "$G7REPO" add g.txt >/dev/null 2>&1; git -C "$G7REPO" commit -qm viva >/dev/null 2>&1
git -C "$G7REPO" checkout -q miDevelop >/dev/null 2>&1
git -C "$G7REPO" worktree add -q "$G7ROOT/wt-viva" feat/viva >/dev/null 2>&1
out="$(cd "$G7REPO" && CLAUDE_INTEGRACION_BASE=miDevelop bash "$HOOKS/limpiar-worktrees.sh" --dry-run 2>&1)"
printf '%s' "$out" | grep -q 'zombie.*feat/hecha' && ok "G7: ramita squash-mergeada a rama personal (base configurable) → zombie por cherry" || bad "G7: no detectó zombie por cherry; got: $out"
printf '%s' "$out" | grep -q 'DEJADO.*feat/viva'  && ok "G7: ramita viva no integrada → conservada"                                     || bad "G7: no conservó la ramita viva; got: $out"
rm -rf "$G7ROOT"

# ─────────────────────────────────────────────────────────────────────────────
echo "== (b3c) limpiar-ramas: barre ramas LOCALES integradas (squash) y CONSERVA trabajo vivo + protegidas =="
# El squash rompe `git branch -d` (la rama no queda de ancestro) y `fetch --prune` no toca ramas locales
# → se acumulan. limpiar-ramas usa la MISMA lib zombie (ramas-zombie.sh) que limpiar-worktrees.
LRROOT="$(mktemp -d "${TMPDIR:-/tmp}/brain-lr.XXXXXX")"; LRREPO="$LRROOT/repo"; mkdir -p "$LRREPO"
git -C "$LRREPO" init -q >/dev/null 2>&1
git -C "$LRREPO" symbolic-ref HEAD refs/heads/miDevelop >/dev/null 2>&1
git -C "$LRREPO" config user.email t@t >/dev/null 2>&1; git -C "$LRREPO" config user.name tester >/dev/null 2>&1
printf 'base\n' > "$LRREPO/base.txt"; git -C "$LRREPO" add base.txt >/dev/null 2>&1; git -C "$LRREPO" commit -qm base >/dev/null 2>&1
# (1) rama integrada por squash local → zombie por cherry → debe borrarse
git -C "$LRREPO" checkout -q -b feat/hecha >/dev/null 2>&1
printf 'x\n' > "$LRREPO/f.txt"; git -C "$LRREPO" add f.txt >/dev/null 2>&1; git -C "$LRREPO" commit -qm hecha >/dev/null 2>&1
git -C "$LRREPO" checkout -q miDevelop >/dev/null 2>&1
git -C "$LRREPO" merge --squash feat/hecha >/dev/null 2>&1; git -C "$LRREPO" commit -qm "squash feat/hecha" >/dev/null 2>&1
# (2) rama viva con commits únicos → conservar
git -C "$LRREPO" checkout -q -b feat/viva miDevelop >/dev/null 2>&1
printf 'y\n' > "$LRREPO/g.txt"; git -C "$LRREPO" add g.txt >/dev/null 2>&1; git -C "$LRREPO" commit -qm viva >/dev/null 2>&1
# (3) rama keep/ integrada (contenido en base) PERO protegida → conservar pese a ser zombie
git -C "$LRREPO" checkout -q -b keep/respaldo miDevelop >/dev/null 2>&1
git -C "$LRREPO" checkout -q miDevelop >/dev/null 2>&1
lrout="$(cd "$LRREPO" && CLAUDE_INTEGRACION_BASE=miDevelop bash "$HOOKS/limpiar-ramas.sh" --dry-run --no-fetch 2>&1)"
printf '%s' "$lrout" | grep -q 'borraría: feat/hecha'      && ok "b3c: rama squash-integrada → se barrería"                  || bad "b3c: no marcó feat/hecha para borrar; got: $lrout"
printf '%s' "$lrout" | grep -q 'CONSERVADA.*feat/viva'     && ok "b3c: rama con trabajo sin integrar → conservada"            || bad "b3c: no conservó feat/viva; got: $lrout"
printf '%s\n' "$lrout" | grep -v '^limpiar-ramas:' | grep -q 'miDevelop' && bad "b3c: tocó la base/rama actual miDevelop; got: $lrout" || ok "b3c: la base/rama actual (miDevelop) NO se lista para borrar ni conservar"
printf '%s' "$lrout" | grep -q 'keep/respaldo' && bad "b3c: keep/respaldo NO debe tocarse (protegida)" || ok "b3c: keep/* protegida (no se lista)"
# teeth: sin la protección, keep/respaldo sería zombie (ancestro de base) — confirma que la protección es la que lo salva
git -C "$LRREPO" merge-base --is-ancestor keep/respaldo miDevelop 2>/dev/null && ok "b3c(teeth): keep/respaldo ES ancestro de base (zombie real) → solo la protección lo conserva" || bad "b3c(teeth): keep/respaldo no era ancestro (test mal armado)"
rm -rf "$LRROOT"

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "== (b3c) git-branch-guard: bloquea push/merge REAL a main/develop, NO una MENCIÓN entrecomillada =="
# HOME AISLADO SIN copia global del hook: si no, la cláusula de dedupe doble-cableado (la copia del
# repo CEDE cuando existe ~/.claude/hooks/…) haría que el guard salga en silencio en una máquina con el
# cerebro instalado globalmente → falso FAIL. (Igual que el gb() de b1d, que usa $GBHOME.)
mkdir -p "$FAKEHOME/_nohooks/.claude"
gbg() { printf '{"tool_input":{"command":%s}}' "$(printf '%s' "$1" | jq -Rs .)" | HOME="$FAKEHOME/_nohooks" bash "$HOOKS/git-branch-guard.sh"; }
is_deny   "$(gbg 'git push origin develop')"                              && ok "gbg: push real a develop → deny (dientes intactos)"           || bad "gbg: NO bloqueó un push real a develop"
is_silent "$(gbg 'git push -u origin feat/x')"                            && ok "gbg: push a una ramita → pasa"                                || bad "gbg: bloqueó un push a ramita"
is_silent "$(gbg 'git commit -m "doc: no hagas git push a develop"')"     && ok "gbg: 'push…develop' en mensaje de commit (dato) → pasa"       || bad "gbg: bloqueó una mención entrecomillada en commit (regresión del fix de comillas)"
is_silent "$(gbg 'grep -rn "git push origin develop" .claude/')"          && ok "gbg: 'push…develop' en arg de grep (dato) → pasa"             || bad "gbg: bloqueó una frase entrecomillada en grep (regresión del fix de comillas)"

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "== (b3d) confirmar-merge-develop: el CONF_RE reconoce el imperativo 'haz merge a develop' =="
CMDCR=$(grep "CONF_RE=" "$HOOKS/confirmar-merge-develop.sh" | sed "s/^[^']*'//; s/'\$//")
printf '%s' "tonces, haz merge a develop de la rama X" | grep -qiE "$CMDCR" && ok "confirmar: reconoce 'haz merge a develop' (imperativo)" || bad "confirmar: NO reconoce 'haz merge a develop' (regresión del CONF_RE)"
printf '%s' "ya mergea eso"                            | grep -qiE "$CMDCR" && ok "confirmar: reconoce 'mergea'"                            || bad "confirmar: NO reconoce 'mergea'"
printf '%s' "sí, plz, súbelo hasta develop"            | grep -qiE "$CMDCR" && ok "confirmar: reconoce 'súbelo hasta develop' (precisión: subir/llevar/mandar → develop)" || bad "confirmar: NO reconoce 'súbelo hasta develop' (falso-FRENO)"
printf '%s' "llévalo a develop porfa"                  | grep -qiE "$CMDCR" && ok "confirmar: reconoce 'llévalo a develop'"                   || bad "confirmar: NO reconoce 'llévalo a develop'"
printf '%s' "sigue trabajando, no pares"               | grep -qiE "$CMDCR" && bad "confirmar: FALSO POSITIVO con 'sigue trabajando'"          || ok "confirmar: 'sigue/avanza' NO dispara CONF (correcto)"

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
# G1 (precisión): una pregunta co-ubicada NO debe salvar un CLAIM de cierre AFIRMADO en el mismo
# mensaje (la evasión "Listo, quedó terminado. ¿Reviso algo más?"). El claim se evalúa sobre el texto
# SIN los tramos ¿…?: si el cierre está afirmado FUERA de la pregunta, se bloquea igual.
is_block "$(dod 'Listo, quedó terminado el módulo. ¿Reviso algo más?' "$EDITR")" && ok "dod G1: claim afirmado + pregunta aparte → bloquea (no se salva por la pregunta)" || bad "dod G1: la pregunta co-ubicada salvó un cierre afirmado (evasión)"
is_block "$(dod 'Todo quedó funcionando y en producción. ¿Avanzo con el siguiente?' "$EDITR")" && ok "dod G1: cierre afirmado + pregunta neutra → bloquea" || bad "dod G1: una pregunta neutra evadió un cierre afirmado"
# H4 (precisión): un ESTATUS DÉBIL (deferir/avisar/consultar) co-ubicado NO salva un CLAIM afirmado —
# antes "Listo, quedó terminado. Dime si reviso algo más." se salvaba con "dime si".
is_block "$(dod 'Listo, quedó terminado. Dime si reviso algo más.' "$EDITR")" && ok "dod H4: claim afirmado + estatus débil ('dime si') → bloquea (no lo salva)" || bad "dod H4: un estatus débil salvó un cierre afirmado (evasión)"
# H4 (contrapeso, NO sobre-disparar): el léxico PRESCRITO de downgrade escapa AUNQUE haya palabra de
# cierre — "quedó terminado pero lo dejo EN PREVIEW, a tu revisión" es honesto, no un falso LISTO.
is_block "$(dod 'El módulo quedó terminado, pero lo dejo en preview, a tu revisión.' "$EDITR")" && bad "dod H4: bloqueó el léxico de downgrade PRESCRITO (falso positivo)" || ok "dod H4: 'quedó terminado … en preview / a tu revisión' → no bloquea (downgrade explícito)"
# H4: un estatus débil SIN claim de cierre sigue escapando (es puro estatus/espera)
is_block "$(dod 'Voy avanzando; te aviso cuando termine.' "$EDITR")" && bad "dod H4: bloqueó estatus débil sin claim" || ok "dod H4: estatus débil sin claim → no bloquea"
# G2(a): editar por Bash (sed -i / redirección) SÍ es "tocar código" aunque no haya "file_path".
BASHSED='{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash","input":{"command":"sed -i \"s/a/b/\" src/Foo.cs"}}]}}'
BASHREDIR='{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash","input":{"command":"cat > src/Bar.razor <<EOF\ncontenido\nEOF"}}]}}'
BASHREAD='{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash","input":{"command":"dotnet build 2>/dev/null | tee build.log"}}]}}'
is_block "$(dod 'Listo, quedó terminado el módulo.' "$BASHSED")" && ok "dod G2a: edición por 'sed -i' (sin file_path) cuenta como código → bloquea" || bad "dod G2a: 'sed -i' evadió el candado (no detectó código tocado)"
is_block "$(dod 'Listo, quedó terminado el módulo.' "$BASHREDIR")" && ok "dod G2a: redirección '> Bar.razor' cuenta como código → bloquea" || bad "dod G2a: redirección a código evadió el candado"
is_block "$(dod 'Listo, quedó terminado el módulo.' "$BASHREAD")" && bad "dod G2a: falso positivo — build+tee a .log/dev-null no es tocar código" || ok "dod G2a: build/tee a .log|/dev/null → NO cuenta como código (sin falso positivo)"
# G2(b): el bloqueo de QA-visual-a-ciegas NO se suprime por la palabra "screenshot" en PROSA;
# solo un tool_use REAL de navegador lo evita (estructura, no substring).
is_block "$(dod 'Quedó igual al mockup. No corrí screenshot, pero confío en que se ve bien.' "$EDITR")" && ok "dod G2b: 'screenshot' en prosa (sin browser-tool) → sigue bloqueando (a ciegas)" || bad "dod G2b: la palabra 'screenshot' en prosa suprimió el bloqueo visual"
# P2a (precisión): un PASO MECÁNICO del proceso ("checkpoint hecho", "push hecho", "MR abierto",
# "memoria actualizada") NO es un cierre de entregable → no dispara (caso real 2026-07-15: el freno
# saltó por "✅ Listo — checkpoint hecho"). Se enmascara la frase mecánica y el claim se evalúa
# sobre el residuo.
is_block "$(dod '✅ Checkpoint hecho' "$EDITR")" && bad "dod P2a: bloqueó '✅ Checkpoint hecho' (paso mecánico, falso positivo)" || ok "dod P2a: '✅ Checkpoint hecho' → no bloquea (paso mecánico)"
is_block "$(dod '✅ Listo — checkpoint hecho, hilo volcado.' "$EDITR")" && bad "dod P2a: bloqueó '✅ Listo — checkpoint hecho' (el caso real del 2026-07-15)" || ok "dod P2a: '✅ Listo — checkpoint hecho, hilo volcado' → no bloquea (caso real)"
is_block "$(dod 'Push hecho a la ramita, MR abierto.' "$EDITR")" && bad "dod P2a: bloqueó 'push hecho…MR abierto' (proceso git, falso positivo)" || ok "dod P2a: 'push hecho a la ramita, MR abierto' → no bloquea (proceso git)"
is_block "$(dod 'Memoria actualizada y bitácora al día. ✅ Hecho el commit.' "$EDITR")" && bad "dod P2a: bloqueó 'memoria actualizada / bitácora al día / hecho el commit'" || ok "dod P2a: 'memoria actualizada, bitácora al día, hecho el commit' → no bloquea"
# P2a FAIL-SAFE: si la frase mezcla paso mecánico Y claim de ENTREGABLE, el claim manda → bloquea.
is_block "$(dod 'Push hecho y la feature ya funciona.' "$EDITR")" && ok "dod P2a fail-safe: 'push hecho Y la feature ya funciona' → bloquea (el claim de entregable manda)" || bad "dod P2a fail-safe: el paso mecánico tapó un claim de entregable (evasión)"
is_block "$(dod 'MR abierto y el endpoint quedó terminado.' "$EDITR")" && ok "dod P2a fail-safe: 'MR abierto Y el endpoint quedó terminado' → bloquea" || bad "dod P2a fail-safe: 'MR abierto' tapó el cierre del endpoint (evasión)"
# P2b (precisión): celebración SIN entregable no dispara por sí sola — 🎉 dejó de ser gatillo
# standalone ("quedó el día" no es "quedó listo/terminado" → no hay claim textual); 🏁 sigue siendo cierre.
is_block "$(dod '🎉 ¡Qué bonito quedó el día!' "$EDITR")" && bad "dod P2b: bloqueó celebración sin entregable ('🎉 qué bonito quedó el día')" || ok "dod P2b: '🎉 ¡qué bonito quedó el día!' → no bloquea (celebración sin entregable)"
is_block "$(dod '¡Genial! ¡Vamos! ✨🚀' "$EDITR")" && bad "dod P2b: bloqueó interjecciones/emojis sin claim" || ok "dod P2b: interjecciones + emojis sin claim → no bloquea"
is_block "$(dod '🎉 El módulo quedó listo.' "$EDITR")" && ok "dod P2b fail-safe: '🎉 el módulo quedó listo' → bloquea (el claim textual dispara solo)" || bad "dod P2b fail-safe: el 🎉 dejó pasar un cierre de entregable"
# Dientes intactos: cierres de ENTREGABLE reales siguen exigiendo la marca (1)/(2).
is_block "$(dod 'El módulo de auth quedó listo.' "$EDITR")" && ok "dod dientes: 'el módulo de auth quedó listo' → sigue bloqueando" || bad "dod dientes: dejó pasar 'el módulo de auth quedó listo' (aflojado)"
is_block "$(dod 'Ya funciona el widget.' "$EDITR")" && ok "dod dientes: 'ya funciona el widget' → sigue bloqueando" || bad "dod dientes: dejó pasar 'ya funciona el widget' (aflojado)"
is_block "$(dod 'Terminamos la migración.' "$EDITR")" && ok "dod dientes: 'terminamos la migración' → sigue bloqueando" || bad "dod dientes: dejó pasar 'terminamos la migración' (aflojado)"
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
echo "== (b5b) aviso-drift-cerebro: drift por-repo vs fuente única (stub del sync; throttle; fail-open) =="
ADFIX="$(mktemp -d "${TMPDIR:-/tmp}/brain-ad.XXXXXX")"
ADROOT="$ADFIX/repo"; ADHOME="$ADFIX/home"; ADBRAIN="$ADFIX/clon"
mkdir -p "$ADROOT/.claude/hooks" "$ADHOME" "$ADBRAIN/brain"
ad() { printf '%s' '{"source":"startup"}' | HOME="$ADHOME" CLAUDE_BRAIN_DIR="$ADBRAIN" CLAUDE_PROJECT_DIR="$ADROOT" bash "$HOOKS/aviso-drift-cerebro.sh"; }
# (1) repo SIN cerebro por-repo → silencio (no estorba en repos ajenos)
is_silent "$(ad)" && ok "aviso-drift: repo no-brained → silencio" || bad "aviso-drift: habló en un repo sin cerebro"
# (2) brained pero SIN clon canónico (no hay sincronizar-cerebro.sh) → silencio (fail-open)
: > "$ADROOT/.claude/hooks/.brain-version"
is_silent "$(ad)" && ok "aviso-drift: sin clon canónico → silencio (fail-open)" || bad "aviso-drift: habló sin fuente única disponible"
# (3) sync LIMPIO (stub 0+0) → silencio y cachea el chequeo
printf '#!/usr/bin/env bash\necho "==> resumen: 0 nuevos · 0 a actualizar · 9 ya al día · 7 hooks cableados (kind=hook)"\n' > "$ADBRAIN/brain/sincronizar-cerebro.sh"
is_silent "$(ad)" && ok "aviso-drift: sin drift → silencio" || bad "aviso-drift: habló sin drift"
# (4) throttle: ahora el stub reporta DRIFT, pero el stamp fresco (chequeo limpio reciente) lo salta
printf '#!/usr/bin/env bash\necho "  NUEVO      secret-scan.sh (hook)"\necho "  ACTUALIZA  dod-verificar.sh (hook)  [10 líneas ±]"\necho "==> resumen: 1 nuevos · 1 a actualizar · 7 ya al día · 7 hooks cableados (kind=hook)"\n' > "$ADBRAIN/brain/sincronizar-cerebro.sh"
is_silent "$(ad)" && ok "aviso-drift: throttle — chequeo limpio reciente → no re-chequea" || bad "aviso-drift: el throttle no respetó el stamp fresco"
# (5) sin stamp → DETECTA el drift e inyecta additionalContext de SessionStart con el detalle
rm -rf "$ADHOME/.claude/memory/.drift-cerebro"
adout="$(ad)"
printf '%s' "$adout" | jq -e '.hookSpecificOutput.hookEventName == "SessionStart"' >/dev/null 2>&1 \
  && ok "aviso-drift: emite hookSpecificOutput SessionStart válido" || bad "aviso-drift: JSON inválido; got: $adout"
printf '%s' "$adout" | jq -r '.hookSpecificOutput.additionalContext' 2>/dev/null | grep -q 'DRIFT DEL CEREBRO' \
  && ok "aviso-drift: el aviso nombra el DRIFT" || bad "aviso-drift: no encontré el aviso de drift"
printf '%s' "$adout" | jq -r '.hookSpecificOutput.additionalContext' 2>/dev/null | grep -q 'secret-scan' \
  && ok "aviso-drift: el aviso trae el DETALLE (archivos atrás)" || bad "aviso-drift: el aviso no detalla los archivos"
# (6) el drift NO se cachea → la siguiente sesión vuelve a avisar (insistente hasta sanar)
printf '%s' "$(ad)" | jq -r '.hookSpecificOutput.additionalContext' 2>/dev/null | grep -q 'DRIFT DEL CEREBRO' \
  && ok "aviso-drift: con drift NO cachea — re-avisa en la siguiente sesión" || bad "aviso-drift: cacheó un chequeo CON drift (se calló)"
rm -rf "$ADFIX"

# ── (b5c) aviso-drift v2: AUTO-APPLY en la mini-develop (Develop<Usuario>) · aviso en ramita ──
AD2FIX="$(mktemp -d "${TMPDIR:-/tmp}/brain-ad2.XXXXXX")"
AD2REPO="$AD2FIX/repo"; AD2HOME="$AD2FIX/home"; AD2BRAIN="$AD2FIX/clon"
mkdir -p "$AD2REPO/.claude/hooks" "$AD2HOME" "$AD2BRAIN/brain"
git -C "$AD2REPO" init -q >/dev/null 2>&1
git -C "$AD2REPO" config user.email t@t >/dev/null 2>&1; git -C "$AD2REPO" config user.name Tester >/dev/null 2>&1
: > "$AD2REPO/.claude/hooks/.brain-version"
git -C "$AD2REPO" add -A >/dev/null 2>&1; git -C "$AD2REPO" commit -qm base >/dev/null 2>&1
# stub del sync: dry-run reporta drift; con --apply ESCRIBE el hook nuevo en el repo destino
cat > "$AD2BRAIN/brain/sincronizar-cerebro.sh" <<'STUB'
#!/usr/bin/env bash
repo="$1"
[ "${2:-}" = "--apply" ] && printf 'x\n' > "$repo/.claude/hooks/hook-nuevo.sh"
echo "  NUEVO      hook-nuevo.sh (hook)"
echo "==> resumen: 1 nuevos · 0 a actualizar · 8 ya al día · 7 hooks cableados (kind=hook)"
STUB
ad2() { printf '%s' '{"source":"startup"}' | HOME="$AD2HOME" CLAUDE_BRAIN_DIR="$AD2BRAIN" CLAUDE_PROJECT_DIR="$AD2REPO" bash "$HOOKS/aviso-drift-cerebro.sh"; }
# (1) en una RAMITA (no mini): NO auto-aplica — avisa y no crea commits
git -C "$AD2REPO" checkout -q -b feat/x >/dev/null 2>&1
n0=$(git -C "$AD2REPO" rev-list --count HEAD)
printf '%s' "$(ad2)" | jq -r '.hookSpecificOutput.additionalContext' 2>/dev/null | grep -q 'DRIFT DEL CEREBRO' \
  && ok "aviso-drift v2: en ramita → AVISA (no auto-aplica)" || bad "aviso-drift v2: en ramita no avisó"
{ [ "$(git -C "$AD2REPO" rev-list --count HEAD)" = "$n0" ] && [ ! -f "$AD2REPO/.claude/hooks/hook-nuevo.sh" ]; } \
  && ok "aviso-drift v2: en ramita NO tocó el árbol ni commiteó" || bad "aviso-drift v2: ¡escribió/commiteó en una ramita de feature!"
# (2) en la MINI-DEVELOP con .claude/ limpio: auto-aplica + commit (push sin remoto → tolerado)
git -C "$AD2REPO" checkout -q -b DevelopTester >/dev/null 2>&1
ad2out="$(ad2)"
printf '%s' "$ad2out" | jq -r '.hookSpecificOutput.additionalContext' 2>/dev/null | grep -q 'AUTO-SINCRONIZADO' \
  && ok "aviso-drift v2: en mini-develop limpia → AUTO-SINCRONIZA y lo anuncia" || bad "aviso-drift v2: no auto-sincronizó en la mini; got: $ad2out"
{ [ -f "$AD2REPO/.claude/hooks/hook-nuevo.sh" ] && git -C "$AD2REPO" log -1 --format=%s | grep -q 'auto-sync'; } \
  && ok "aviso-drift v2: el apply escribió y el commit de auto-sync existe" || bad "aviso-drift v2: falta el archivo aplicado o el commit"
[ -z "$(git -C "$AD2REPO" status --porcelain)" ] \
  && ok "aviso-drift v2: el árbol quedó LIMPIO tras el auto-sync (todo commiteado)" || bad "aviso-drift v2: dejó el árbol sucio"
# (3) en la mini pero con .claude/ SUCIO: no auto-aplica (solo avisa, no mezcla cambios)
printf 'sucio\n' >> "$AD2REPO/.claude/hooks/.brain-version"
printf '%s' "$(ad2)" | jq -r '.hookSpecificOutput.additionalContext' 2>/dev/null | grep -q 'DRIFT DEL CEREBRO' \
  && ok "aviso-drift v2: mini con .claude/ sucio → solo avisa (no mezcla cambios)" || bad "aviso-drift v2: auto-aplicó sobre un .claude/ sucio"
rm -rf "$AD2FIX"

# ── (b5d) sembrar-mini-develop: crea la rama desde origin/develop sin tocar el worktree ──
SMFIX="$(mktemp -d "${TMPDIR:-/tmp}/brain-sm.XXXXXX")"
SMBARE="$SMFIX/remoto.git"; SMREPO="$SMFIX/clon"
git init -q --bare "$SMBARE" >/dev/null 2>&1
git clone -q "$SMBARE" "$SMREPO" >/dev/null 2>&1
git -C "$SMREPO" config user.email t@t >/dev/null 2>&1; git -C "$SMREPO" config user.name Tester >/dev/null 2>&1
printf 'base\n' > "$SMREPO/a.txt"; git -C "$SMREPO" add a.txt >/dev/null 2>&1; git -C "$SMREPO" commit -qm base >/dev/null 2>&1
git -C "$SMREPO" branch -M develop >/dev/null 2>&1; git -C "$SMREPO" push -qu origin develop >/dev/null 2>&1
git -C "$SMREPO" checkout -q -b feat/trabajo >/dev/null 2>&1   # parado en una ramita (no debe moverse)
smout=$(CLAUDE_PROJECT_DIR="$SMREPO" bash "$SCRIPT_DIR/sembrar-mini-develop.sh" 2>&1)
git -C "$SMREPO" ls-remote --exit-code origin DevelopTester >/dev/null 2>&1 \
  && ok "sembrar-mini: creó DevelopTester en el remoto desde origin/develop (nombre derivado del git user)" \
  || bad "sembrar-mini: no creó la rama remota; out: $smout"
[ "$(git -C "$SMREPO" rev-parse --abbrev-ref HEAD)" = "feat/trabajo" ] \
  && ok "sembrar-mini: NO movió la rama actual del worktree" || bad "sembrar-mini: cambió la rama del usuario"
smout2=$(CLAUDE_PROJECT_DIR="$SMREPO" bash "$SCRIPT_DIR/sembrar-mini-develop.sh" 2>&1)
printf '%s' "$smout2" | grep -q "ya existe" && ok "sembrar-mini: idempotente (2ª corrida no duplica)" || bad "sembrar-mini: la 2ª corrida no fue idempotente; out: $smout2"
smout3=$(CLAUDE_PROJECT_DIR="$SMREPO" bash "$SCRIPT_DIR/sembrar-mini-develop.sh" develop 2>&1) && rc3=0 || rc3=$?
{ [ "$rc3" -ne 0 ] && printf '%s' "$smout3" | grep -q "rama base"; } \
  && ok "sembrar-mini: rechaza 'develop' como nombre de mini (protege las bases)" || bad "sembrar-mini: aceptó develop como mini"
rm -rf "$SMFIX"

# ── (b5e) barrer-ramas: TRIGGER throttled del barrido de ramas (fail-open, lanza, throttle) ──
echo ""
echo "== (b5e) barrer-ramas: da trigger al barrido (fail-open sin git/remoto; lanza; throttle) =="
BRFIX="$(mktemp -d "${TMPDIR:-/tmp}/brain-br.XXXXXX")"
BRHOME="$BRFIX/home"; BRHOOKS="$BRFIX/hooks"; BRREPO="$BRFIX/repo"
mkdir -p "$BRHOME" "$BRHOOKS" "$BRREPO"
# Copia el hook + un STUB de limpiar-ramas junto a él: dirname resuelve a ESTA carpeta → usa el stub (sin red).
cp "$HOOKS/barrer-ramas.sh" "$BRHOOKS/barrer-ramas.sh"
printf '#!/usr/bin/env bash\ntouch "%s/.barrido"\n' "$BRFIX" > "$BRHOOKS/limpiar-ramas.sh"; chmod +x "$BRHOOKS/limpiar-ramas.sh"
br() { printf '%s' '{"source":"startup"}' | HOME="$BRHOME" CLAUDE_PROJECT_DIR="$BRREPO" bash "$BRHOOKS/barrer-ramas.sh"; }
# (1) no es repo git → silencio (fail-open, no estorba)
is_silent "$(br)" && ok "barrer-ramas: no-git → silencio" || bad "barrer-ramas: habló fuera de un repo git"
git -C "$BRREPO" init -q >/dev/null 2>&1
# (2) repo SIN remoto → silencio (sin remoto no hay ramas squasheadas-y-borradas que barrer)
is_silent "$(br)" && ok "barrer-ramas: repo sin remoto → silencio" || bad "barrer-ramas: habló sin remoto"
git -C "$BRREPO" remote add origin /tmp/fake-no-red >/dev/null 2>&1   # URL fake: el hook nunca la contacta
# (3) con remoto y sin stamp → LANZA: SessionStart válido + escribe el stamp de throttle
brout="$(br)"
printf '%s' "$brout" | jq -e '.hookSpecificOutput.hookEventName == "SessionStart"' >/dev/null 2>&1 \
  && ok "barrer-ramas: con remoto y sin throttle → emite SessionStart válido" || bad "barrer-ramas: JSON inválido; got: $brout"
printf '%s' "$brout" | jq -r '.hookSpecificOutput.additionalContext' 2>/dev/null | grep -q 'Barriendo ramas' \
  && ok "barrer-ramas: el aviso anuncia el barrido" || bad "barrer-ramas: el aviso no menciona el barrido"
brslug=$(printf '%s' "$BRREPO" | cksum | awk '{print $1}')
[ -f "$BRHOME/.claude/memory/.barrer-ramas/$brslug" ] \
  && ok "barrer-ramas: escribió el stamp de throttle" || bad "barrer-ramas: no escribió el stamp"
# (4) throttle: 2ª corrida inmediata → silencio (stamp fresco)
is_silent "$(br)" && ok "barrer-ramas: throttle — 2ª corrida inmediata → silencio" || bad "barrer-ramas: no respetó el throttle"
rm -rf "$BRFIX"

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
# Escalada de urgencia por banda: 1=heads-up (holgura) · 2=checkpoint-ahora · ≥3=INMINENTE + re-checkpoint
AC2="$(mktemp -d "${TMPDIR:-/tmp}/brain-ac2.XXXXXX")/r"; mkdir -p "$AC2/.claude/memory"; AC2TX="$AC2/t.jsonl"
gen2() { : > "$AC2TX"; i=0; while [ "$i" -lt "$1" ]; do printf 'x\n' >> "$AC2TX"; i=$((i+1)); done; }
ac2msg() { printf '%s' "{\"transcript_path\":\"$AC2TX\"}" | AVISO_CONTEXTO_UMBRAL=10 CLAUDE_PROJECT_DIR="$AC2" bash "$HOOKS/aviso-contexto.sh" | jq -r '.hookSpecificOutput.additionalContext // empty'; }
gen2 15; m="$(ac2msg)"   # delta 15 / umbral 10 = banda 1
{ printf '%s' "$m" | grep -qi 'holgura' && ! printf '%s' "$m" | grep -q 'INMINENTE'; } \
  && ok "aviso escalada: banda 1 → heads-up (holgura, NO inminente)" || bad "aviso escalada: banda 1 no fue heads-up; got: $m"
gen2 35; m="$(ac2msg)"   # delta 35 / 10 = banda 3
{ printf '%s' "$m" | grep -q 'INMINENTE' && printf '%s' "$m" | grep -q 'DE NUEVO'; } \
  && ok "aviso escalada: banda ≥3 → INMINENTE + ORDENA re-checkpoint (DE NUEVO)" || bad "aviso escalada: banda ≥3 no ordenó re-checkpoint; got: $m"
rm -rf "$(dirname "$AC2")"

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
echo "== (b8) recordar-dashboard: merge-base cae a origin/develop en clon sin develop local (G8) =="
# Sin ref LOCAL develop/main (clon fresco / default con otro nombre) el merge-base fallaba y la revisión
# doc=realidad se auto-anulaba en silencio. Ahora cae a origin/develop|origin/main.
G8ROOT="$(mktemp -d "${TMPDIR:-/tmp}/brain-g8.XXXXXX")"; G8HOME="$G8ROOT/home"; mkdir -p "$G8HOME"
BARE8="$G8ROOT/bare.git"; SRC8="$G8ROOT/src"
git init --bare -q -b develop "$BARE8" >/dev/null 2>&1
git clone -q "$BARE8" "$SRC8" >/dev/null 2>&1
git -C "$SRC8" config user.email t@t >/dev/null 2>&1; git -C "$SRC8" config user.name tester >/dev/null 2>&1
printf 'base\n' > "$SRC8/base.txt"; git -C "$SRC8" add base.txt >/dev/null 2>&1; git -C "$SRC8" commit -qm base >/dev/null 2>&1
git -C "$SRC8" push -q origin develop >/dev/null 2>&1
git -C "$SRC8" checkout -q -b feat/g8 develop >/dev/null 2>&1
git -C "$SRC8" branch -D develop >/dev/null 2>&1   # simula clon fresco: solo queda origin/develop
mkdir -p "$SRC8/src"; printf 'x=1\n' > "$SRC8/src/foo.js"; git -C "$SRC8" add src/foo.js >/dev/null 2>&1; git -C "$SRC8" commit -qm code >/dev/null 2>&1
out="$(printf '%s' '{"tool_input":{"command":"git push -u origin feat/g8"}}' | (cd "$SRC8" && HOME="$G8HOME" bash "$HOOKS/recordar-dashboard.sh"))"
printf '%s' "$out" | grep -q 'doc=realidad' && ok "G8: sin develop local → merge-base cae a origin/develop → doc=realidad activo" || bad "G8: la revisión doc=realidad se auto-anuló (no cayó a origin/develop); got: $out"
rm -rf "$G8ROOT"

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
[ -f "$FAKEHOME2/.claude/skills/rehidratar-hilo/SKILL.md" ] && ok "skill rehidratar-hilo instalada (gemelo manual del hook)" || bad "falta skill rehidratar-hilo"
[ -f "$FAKEHOME2/.claude/skills/turno-nocturno/SKILL.md" ] && ok "skill turno-nocturno instalada (protocolo del turno de noche)" || bad "falta skill turno-nocturno"
[ -f "$FAKEHOME2/.claude/skills/diagramar/SKILL.md" ] && ok "skill diagramar instalada (dot2yed para editar · Mermaid para GitHub)" || bad "falta skill diagramar"
[ -f "$FAKEHOME2/.claude/hooks/rehidratar-hilo.sh" ]     && ok "hook rehidratar-hilo instalado" || bad "falta hook rehidratar-hilo"
[ -f "$FAKEHOME2/.claude/hooks/aviso-contexto.sh" ]      && ok "hook aviso-contexto instalado"  || bad "falta hook aviso-contexto"
[ -f "$FAKEHOME2/.claude/hooks/delegacion-comun.sh" ]    && ok "lib delegacion-comun.sh instalada" || bad "falta lib delegacion-comun.sh"
[ -f "$FAKEHOME2/.claude/hooks/analizar-comando-git.sh" ] && ok "lib analizar-comando-git.sh instalada" || bad "falta lib analizar-comando-git.sh"
[ -f "$FAKEHOME2/.claude/hooks/detectar-secretos.sh" ] && ok "lib detectar-secretos.sh instalada" || bad "falta lib detectar-secretos.sh"
# sello de VERSIÓN del brain instalado en ~/.claude/.brain-version (lo lee el tab Cerebro del widget)
if [ -f "$FAKEHOME2/.claude/.brain-version" ] && \
   [ "$(cat "$FAKEHOME2/.claude/.brain-version")" = "$(cat "$SCRIPT_DIR/VERSION")" ]; then
  ok "sello .brain-version estampado en ~/.claude (= brain/VERSION)"
else
  bad "falta ~/.claude/.brain-version o no coincide con brain/VERSION"
fi

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
CE_ALLOW="analizar-comando-git|git-branch-guard
analizar-comando-git|merge-squash-guard
analizar-comando-git|confirmar-merge-develop
confirmar-merge-develop|git-branch-guard
confirmar-merge-develop|merge-squash-guard
detectar-secretos|secret-scan
cerrar-slice|merge-squash-guard
cerrar-slice|recordar-dashboard
delegacion-comun|delegacion-gate
delegacion-comun|delegacion-registrar
delegacion-gate|limite-gasto
delegacion-reporte|orquestar-fanout
cerrar-slice|checkpoint
cerrar-slice|rehidratar-hilo
checkpoint|rehidratar-hilo
aviso-contexto|rehidratar-hilo
aviso-contexto|checkpoint
limpiar-ramas|limpiar-worktrees
limpiar-ramas|ramas-zombie
limpiar-worktrees|ramas-zombie"
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
echo "== (e2) drift-check: el MANIFEST es la FUENTE ÚNICA — install/uninstall/sincronizar coinciden (A4) =="
MF="$HOOKS/MANIFEST"
if [ ! -f "$MF" ]; then
  bad "drift: falta el MANIFEST ($MF)"
else
  # (1) todo *.sh de brain/hooks está declarado en el manifiesto (ningún hook queda fuera de la fuente única)
  miss_mf=0
  for f in "$HOOKS"/*.sh; do
    b="$(basename "$f" .sh)"
    awk '$1!~/^#/ && NF>=3{print $1}' "$MF" | grep -qxF "$b" || { bad "drift: $b.sh NO está en el MANIFEST (hook sin tier declarado)"; miss_mf=1; }
  done
  [ "$miss_mf" = 0 ] && ok "drift: todo *.sh de brain/hooks está declarado en el MANIFEST"
  # (2) toda entrada del manifiesto tiene su archivo
  miss_file=0
  for b in $(awk '$1!~/^#/ && NF>=3{print $1}' "$MF"); do
    [ -f "$HOOKS/$b.sh" ] || { bad "drift: el MANIFEST lista '$b' pero falta $HOOKS/$b.sh"; miss_file=1; }
  done
  [ "$miss_file" = 0 ] && ok "drift: toda entrada del MANIFEST tiene su .sh"
  # (3) install-brain DERIVA GLOBAL del manifiesto (no una lista hardcodeada paralela) y no está vacía
  derived="$(awk '$1!~/^#/ && NF>=3 && ($2=="global"||$2=="both"){print $1".sh"}' "$MF")"
  if grep -q "awk.*global.*both.*MANIFEST\|MANIFEST.*awk" "$INSTALLER" && [ -n "$derived" ]; then
    ok "drift: install-brain deriva GLOBAL_HOOKS del MANIFEST (fuente única, no lista paralela)"
  else
    bad "drift: install-brain NO deriva del MANIFEST (¿volvió a una lista hardcodeada?)"
  fi
  # (4) cada {global,both} kind=hook tiene su register_hook en install-brain (cableado ↔ manifiesto)
  miss_wire=0
  for b in $(awk '$1!~/^#/ && NF>=3 && ($2=="global"||$2=="both") && $3=="hook"{print $1}' "$MF"); do
    grep -q "register_hook.*$b" "$INSTALLER" || { bad "drift: '$b' es {global,both} hook pero NO tiene register_hook en install-brain"; miss_wire=1; }
  done
  [ "$miss_wire" = 0 ] && ok "drift: cada hook {global,both} del MANIFEST está cableado en install-brain"
  # (5) uninstall-brain también deriva del manifiesto (no una 3ª lista que driftee)
  grep -q "MANIFEST" "$SCRIPT_DIR/uninstall-brain.sh" 2>/dev/null \
    && ok "drift: uninstall-brain también deriva del MANIFEST" \
    || bad "drift: uninstall-brain NO referencia el MANIFEST (lista paralela)"
  # (6) sincronizar-cerebro existe y los archivos de tier {repo,both} que desplegaría están presentes
  if [ -f "$SCRIPT_DIR/sincronizar-cerebro.sh" ]; then
    miss_repo=0
    for b in $(awk '$1!~/^#/ && NF>=3 && ($2=="repo"||$2=="both"){print $1}' "$MF"); do
      [ -f "$HOOKS/$b.sh" ] || { bad "drift: sincronizar desplegaría '$b' pero falta su .sh"; miss_repo=1; }
    done
    [ "$miss_repo" = 0 ] && ok "drift: sincronizar-cerebro existe y todos sus archivos {repo,both} están presentes"
  else
    bad "drift: falta sincronizar-cerebro.sh (la ruta de despliegue por-repo)"
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
echo "== (e3) drift-check WIDGET: el catálogo curado del widget coincide con el MANIFEST + skills (antídoto al que un hook nuevo caiga en OTROS y a una skill sin tile) =="
# El widget (Windows/C#, macOS/Swift, plasmoid/QML) trae un catálogo CURADO de piezas del cerebro:
#   (1) los conjuntos known-global / known-repo que clasifican cada hook (si un hook NO está aquí,
#       cae en la sección "OTROS" → drift real que ya nos mordió), y
#   (2) los tiles de display (uno por hook/skill). Esta 3ª lista quedaba FUERA del drift-check e2.
# Invariante: known-global == MANIFEST{global,both}·hook · known-repo == MANIFEST{repo}·hook ·
#             y todo hook del MANIFEST + toda skill de brain/skills tiene un tile en el archivo de display.
ROOT="$SCRIPT_DIR/.."
if [ ! -f "$MF" ]; then
  bad "drift-widget: falta el MANIFEST"
else
  mf_global=$(awk '$1!~/^#/ && NF>=3 && ($2=="global"||$2=="both") && $3=="hook"{print $1}' "$MF" | sort -u)
  mf_repo=$(awk '$1!~/^#/ && NF>=3 && $2=="repo" && $3=="hook"{print $1}' "$MF" | sort -u)
  mf_hooks=$(printf '%s\n%s\n' "$mf_global" "$mf_repo" | grep -v '^$' | sort -u)
  wskills=$(for d in "$SCRIPT_DIR"/skills/*/; do [ -f "${d}SKILL.md" ] && basename "$d"; done | sort -u)
  # quoted tokens con al menos un guion (todos los hooks lo tienen → no captura keywords ni comentarios)
  qtok() { grep -oE '"[a-z][a-z0-9]*(-[a-z0-9]+)+"' | tr -d '"' | sort -u; }
  cmp_set() {  # label  what  got  want
    if [ "$3" = "$4" ]; then ok "drift-widget[$1]: $2 == MANIFEST"
    else bad "drift-widget[$1]: $2 DIFIERE de MANIFEST · sobran/faltan: $(comm -3 <(printf '%s\n' "$3") <(printf '%s\n' "$4") | tr '\t' '~' | tr '\n' ' ')"; fi
  }
  cover() {  # label  display_file
    miss=0
    for n in $mf_hooks $wskills; do
      grep -qF "\"$n\"" "$2" || { bad "drift-widget[$1]: '$n' (MANIFEST/skill) sin tile en $(basename "$2")"; miss=1; }
    done
    [ "$miss" = 0 ] && ok "drift-widget[$1]: todo hook del MANIFEST y toda skill tienen tile"
  }
  # (Windows / C#) known-sets en BrainInspector.cs · tiles en PopupForm.cs
  CS="$ROOT/windows/src/ClaudeBrain/BrainInspector.cs"; CSD="$ROOT/windows/src/ClaudeBrain/PopupForm.cs"
  if [ -f "$CS" ] && [ -f "$CSD" ]; then
    cmp_set win "known-global" "$(sed -n '/KnownGlobalHooks = new()/,/};/p' "$CS" | qtok)" "$mf_global"
    cmp_set win "known-repo"   "$(sed -n '/KnownRepoHooks = new()/,/};/p'   "$CS" | qtok)" "$mf_repo"
    cover   win "$CSD"
  else bad "drift-widget[win]: no encuentro BrainInspector.cs / PopupForm.cs"; fi
  # (macOS / Swift) known-sets en BrainInspector.swift · tiles en PopoverView.swift
  SW="$ROOT/macos/Sources/ClaudeBrain/BrainInspector.swift"; SWD="$ROOT/macos/Sources/ClaudeBrain/PopoverView.swift"
  if [ -f "$SW" ] && [ -f "$SWD" ]; then
    cmp_set mac "known-global" "$(sed -n '/knownGlobalHooks: Set<String> = \[/,/\]/p' "$SW" | qtok)" "$mf_global"
    cmp_set mac "known-repo"   "$(sed -n '/knownRepoHooks: Set<String> = \[/,/\]/p'   "$SW" | qtok)" "$mf_repo"
    cover   mac "$SWD"
  else bad "drift-widget[mac]: no encuentro BrainInspector.swift / PopoverView.swift"; fi
  # (plasmoid / QML) known-sets y tiles en el mismo main.qml
  QML="$ROOT/src/plasmoid/contents/ui/main.qml"
  if [ -f "$QML" ]; then
    cmp_set qml "known-global" "$(grep 'brainGlobalHooks:' "$QML" | qtok)" "$mf_global"
    cmp_set qml "known-repo"   "$(grep 'brainRepoHooks:'   "$QML" | qtok)" "$mf_repo"
    cover   qml "$QML"
  else bad "drift-widget[qml]: no encuentro main.qml"; fi
fi

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "==> resultado: $PASS PASS · $FAIL FAIL"
[ "$FAIL" -eq 0 ]
