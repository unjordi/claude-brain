# Memory Index — claude-quota-widget

> Cerebro de Claude Code de ESTE repo (`github.com/unjordi/claude-quota-widget`).
> Es la fuente de verdad única (código + memoria/skills viajan juntos por el repo).
> Tras `git clone` en otra máquina: corre `bash .claude/bootstrap-claude.sh` una vez.
> Memorias personales/sensibles → `*.local.md` (gitignored, no viajan al equipo).

- [Claude Quota Widget](claude-quota-widget.md) — qué es y dónde vive (este repo, fuente única); fuente de datos (endpoint OAuth `/usage` + ccusage); look FelixDes (naranja, icono speedometer); popup de 3 pestañas (Límites/Resumen/Modelos); gotchas de iteración en KDE y de la bandeja; replicación multi-OS (macOS con paridad completa desde 2026-07-04, Windows por construir)
- [Tema KDE opaco](kde-tema-opaco.md) — fork local "CachyOS Nord (opaco)" para bajar la transparencia de los widgets de KDE (0.81→0.97); revertir con `plasma-apply-desktoptheme CachyOS-Nord-round`
- [Árbol del Cerebro — sync](arbol-cerebro-sync.md) — la jerarquía de la pestaña Cerebro está DUPLICADA en 4 lugares (README + brainTiers de macOS/Linux/Windows) + lógica de estado por GUI que casa NOMBRES; tocar uno = tocar los 4 o se divergen (doc <= realidad). Diferencia de medio legítima: por-repo va indentado en README, con ◈ en el widget.
