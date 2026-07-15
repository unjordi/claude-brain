# Memory Index — claude-brain

> Cerebro de Claude Code de ESTE repo (`github.com/unjordi/claude-brain`).
> Es la fuente de verdad única (código + memoria/skills viajan juntos por el repo).
> Tras `git clone` en otra máquina: corre `bash .claude/bootstrap-claude.sh` una vez.
> Memorias personales/sensibles → `*.local.md` (gitignored, no viajan al equipo).

- [Claude Brain Widget](claude-brain.md) — qué es y dónde vive (este repo, fuente única); fuente de datos (endpoint OAuth `/usage` + ccusage); look FelixDes (naranja, icono speedometer); popup de 3 pestañas (Límites/Resumen/Modelos); gotchas de iteración en KDE y de la bandeja; replicación multi-OS (macOS con paridad completa desde 2026-07-04, Windows por construir)
- [Tema KDE opaco](kde-tema-opaco.md) — fork local "CachyOS Nord (opaco)" para bajar la transparencia de los widgets de KDE (0.81→0.97); revertir con `plasma-apply-desktoptheme CachyOS-Nord-round`
- [Árbol del Cerebro — sync](arbol-cerebro-sync.md) — la jerarquía de la pestaña Cerebro está DUPLICADA en 4 lugares (README + brainTiers de macOS/Linux/Windows) + lógica de estado por GUI que casa NOMBRES; tocar uno = tocar los 4 o se divergen (doc <= realidad). Diferencia de medio legítima: por-repo va indentado en README, con ◈ en el widget.
- [Ecosistema Claude (KB viva)](ecosistema-claude.md) — todo lo aprendido sobre el ecosistema Claude (CLI, chat, API, hooks, cuotas, sesiones) al construir el brain; CRECE con cada hallazgo. Semilla: auth GLOBAL a la máquina (switch de cuenta transparente a la sesión viva), el mensaje "cannot determine safety of Bash" = quota agotado (NO Bash roto), PreCompact no inyecta additionalContext, transcripts por-máquina no viajan.
- [Estrategia de memoria](estrategia-memoria.md) — PLAN (no ejecutado, en el backlog): 5 fases para hacer el cerebro más eficiente/fluido sin perder el hilo (0 gratis · 1 recall selectivo sin daemon · 2 spike Basic Memory · 3 Serena para código .NET · 4 Graphiti condicional) + qué NO haremos (Mem0/Zep cloud, Letta) + decisiones abiertas.
- [Feedback: correr comandos sin modificar](feedback_correr-comandos-sin-modificar.md) — al QAear un mecanismo documentado (instalador, one-liner del README), córrelo LITERAL; verifica el estado real antes de "optimizar" con flags/env (2026-07-15: una copia redundante ya existente costó menos que debuggear mi desvío).
