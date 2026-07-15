# detectar-secretos.sh — LIB (NO es un hook; se hace `source`). LÓGICA de detección de secretos que usa
# el hook secret-scan.sh (MECANISMO). Separar la lógica aquí la hace testeable en aislado y deja al hook
# como wrapper delgado (mismo patrón que analizar-comando-git.sh ↔ los git-guards). bash-3.2-safe.
# shellcheck shell=bash
#
# Filosofía (heredada de secret-scan): PRECISIÓN > exhaustividad. Patrones de formato inconfundible
# (prefijo + charset/longitud fijos), NO heurística de entropía genérica (que dispara con hashes, UUIDs,
# minified JS, git SHAs…). Mejor NO molestar que ahogar en falsos positivos → el guard se respeta.

# ds_patrones — regex ERE (alternado) de secretos de ALTA precisión.
ds_patrones() {
  local PAT
  PAT='(AKIA[0-9A-Z]{16})'                                                   # AWS access key id
  PAT="$PAT"'|(-----BEGIN[[:space:]-]*(RSA|EC|OPENSSH|DSA|PGP)?[[:space:]]*PRIVATE KEY-----)'  # clave privada PEM
  PAT="$PAT"'|(sk-ant-[A-Za-z0-9_-]{20,})'                                   # Anthropic
  PAT="$PAT"'|(sk-proj-[A-Za-z0-9_-]{20,})'                                  # OpenAI project
  PAT="$PAT"'|(sk-[A-Za-z0-9]{32,})'                                         # OpenAI clásica
  PAT="$PAT"'|(gh[posru]_[A-Za-z0-9]{36,})'                                  # GitHub token
  PAT="$PAT"'|(github_pat_[A-Za-z0-9_]{40,})'                                # GitHub fine-grained PAT
  PAT="$PAT"'|(glpat-[A-Za-z0-9_-]{20})'                                     # GitLab PAT
  PAT="$PAT"'|(xox[baprs]-[A-Za-z0-9-]{10,})'                                # Slack
  PAT="$PAT"'|(AIza[0-9A-Za-z_-]{35})'                                       # Google API key
  # ── §D: patrones NUEVOS, todos de alta precisión (formato inconfundible, no entropía) ──
  PAT="$PAT"'|(eyJ[A-Za-z0-9_-]{8,}\.eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,})'  # JWT (header b64 'eyJ' . payload 'eyJ' . firma)
  PAT="$PAT"'|([a-zA-Z][a-zA-Z0-9+.-]*://[^:@/[:space:]]+:[^@/[:space:]]+@)'     # connection string con creds embebidas user:pass@host
  PAT="$PAT"'|([Pp]assword[[:space:]]*=[[:space:]]*[^;"'"'"'[:space:]]{6,})'     # Password=... (estilo .NET connstring; 6+ chars)
  PAT="$PAT"'|([Pp]wd[[:space:]]*=[[:space:]]*[^;"'"'"'[:space:]]{6,})'          # Pwd=... (alias .NET de Password)
  printf '%s' "$PAT"
}

# ds_safe_re — regex de placeholders/ejemplos célebres que NO son secretos reales (se excluyen).
# Incluye referencias a variables de entorno (Password=$VAR / ${VAR} / %VAR%) → NO es un secreto en claro.
ds_safe_re() {
  printf '%s' 'AKIAIOSFODNN7EXAMPLE|EXAMPLE_KEY|your[-_]?(api[-_]?)?key|xxxx+|<[A-Za-z_]+>|[Pp]ass(word|wd)[[:space:]]*=[[:space:]]*[$%]|[Pp]ass(word|wd)[[:space:]]*=[[:space:]]*["'"'"']?\{|CHANGE[-_]?ME|placeholder|redacted|\*\*\*+'
}

# ds_buscar "<texto>" — imprime hasta 3 coincidencias REDACTADAS (primeros 6 chars + …), una por línea.
# Devuelve 0 si encontró algo (imprime), 1 si nada. El consumidor decide qué hacer (bloquear, etc.).
ds_buscar() {
  local found
  found=$(printf '%s' "$1" | grep -oE "$(ds_patrones)" 2>/dev/null | grep -viE "$(ds_safe_re)" | head -3)
  [ -n "$found" ] || return 1
  printf '%s' "$found" | sed -E 's/(.{6}).*/\1…(redactado)/'
  return 0
}
