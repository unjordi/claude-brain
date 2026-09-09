# Auditoría de SISTEMA — 07 · Comando git en bash (guards)
> 2026-09-08 (turno-nocturno) · 3 lentes ollama (think:false).
> Código: analizar-comando-git, git-branch-guard, proteger-arbol, secret-scan, detectar-secretos.

## OVERLAP con el 03 (git-branch/analizar-comando-git): ya parqueado ahí (#9). No se re-lista.

## NUEVO — 2 ALTOs en secret-scan (guard DEFENSIVO) → PARQUEADOS para unjordi (seguridad, verificar+fix con test)
- **ALTO/seguridad · `git add` ENCADENADO — solo el 1º se escanea por la ruta addfiles.** `grep -oE 'git[[:space:]]+add[^;&|]*' | head -1` toma SOLO el primer `git add`. Repro sugerido: `git add safe.txt && git add secret.txt && git commit`. **⚠️ VERIFICAR ANTES DE FIXEAR:** secret-scan escanea el STAGING COMPLETO al `git commit` (`git diff --cached`) — si esa ruta cubre AMBOS archivos ya staged, el hueco de addfiles NO es explotable en el commit (solo importaría en el escaneo pre-staging). Hay que confirmar contra el código si el commit-scan cubre el staging entero. Si SÍ lo cubre → el finding es benigno; si NO → es un hueco real. Fix (si real): iterar TODOS los segmentos `git add` (sin `head -1`).
- **ALTO · secret-scan fail-OPEN (exit 0) sin `jq`** → sin rastro. Un operador cree estar protegido; el escaneo se salta ciego. jq es requisito duro del brain, pero para un guard DEFENSIVO el fail-open-sin-jq es discutible (¿fail-closed / aviso ruidoso / CLAUDE_SECRET_SCAN_STRICT?). Decisión de seguridad → unjordi.

## medios: proteger-arbol (heredoc), overlap con 03. Guards de supervisión → no se tocan sin OK.
Opus gate: N/A (todo parqueado; guards). El chained-add de secret-scan es lo más importante a verificar en la mañana.
