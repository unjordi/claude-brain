# Memory Index — claude-brain

> Cerebro de Claude Code de ESTE repo (`github.com/unjordi/claude-brain`).
> Es la fuente de verdad única (código + memoria/skills viajan juntos por el repo).
> Tras `git clone` en otra máquina: corre `bash .claude/bootstrap-claude.sh` una vez.
> Memorias personales/sensibles → `*.local.md` (gitignored, no viajan al equipo).

- [Claude Brain Widget](claude-brain.md) — qué es y dónde vive (este repo, fuente única); fuente de datos (endpoint OAuth `/usage` + ccusage); look FelixDes (naranja, icono speedometer); popup de 3 pestañas (Límites/Resumen/Modelos); gotchas de iteración en KDE y de la bandeja; replicación multi-OS (macOS con paridad completa desde 2026-07-04, Windows por construir)
- [Tema KDE opaco](kde-tema-opaco.md) — fork local "CachyOS Nord (opaco)" para bajar la transparencia de los widgets de KDE (0.81→0.97); revertir con `plasma-apply-desktoptheme CachyOS-Nord-round`
- [Árbol del Cerebro — sync](arbol-cerebro-sync.md) — la jerarquía de la pestaña Cerebro está DUPLICADA en 4 lugares (README + brainTiers de macOS/Linux/Windows) + lógica de estado por GUI que casa NOMBRES; tocar uno = tocar los 4 o se divergen (doc <= realidad). Diferencia de medio legítima: por-repo va indentado en README, con ◈ en el widget.
- [Backlog de desarrollo](backlog-desarrollo.md) — features pedidas y NO implementadas (un ítem = un slice): (1) inicializar/reconciliar el cerebro global + barrer todos los slugs desde el widget (extiende la curita a per-repo); (2) mover sesiones con su transcripción entre slugs.
- [BUG: rename no jala en Linux](rename-linux-no-jala.md) — el renombrar proyecto/sesión (c/d) por clic-secundario NO surte efecto en KDE Plasma 6 (macOS sí); checklist para debuggear en la máquina Linux: aísla menú→escritura del alias JSON→refresh→extractor desplegado (sospechoso #1: `sessions-extract.js` viejo instalado; #2: WRITE por el DataSource executable en Plasma 6). Borrar al resolver.
- [Ecosistema Claude (KB viva)](ecosistema-claude.md) — todo lo aprendido sobre el ecosistema Claude (CLI, chat, API, hooks, cuotas, sesiones) al construir el brain; CRECE con cada hallazgo. Semilla: auth GLOBAL a la máquina (switch de cuenta transparente a la sesión viva), el mensaje "cannot determine safety of Bash" = quota agotado (NO Bash roto), PreCompact no inyecta additionalContext, transcripts por-máquina no viajan.
