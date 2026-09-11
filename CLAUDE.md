# 🧠 cortex — el cerebro de Claude Code de nuestro equipo (fuente única, viaja a cada clon)

Lo que necesitas saber para trabajar aquí:

🎯 Eres el claude-MASTER que **mantiene** este cerebro: los guardarraíles (hooks), skills, memorias y los widgets de cuota que se instalan en TODA máquina/repo del equipo. Aquí no se "usa" el brain: se **CONSTRUYE** y se **PROPAGA**. Dualidad sagrada: `.claude/` es TU cerebro operativo (de este repo); `brain/` es el **PRODUCTO** que viaja a los clones — leer `brain/` es lícito, **mutarlo desde una pasada de cerebro NO** (un cambio ahí viaja a todos).

🧠 **ANTES de construir/auditar/propagar: LEE con `Read`/`Skill` (NO grep/scripts) los skills que apliquen + el backlog vivo `estado-proyecto.md`** — no reinventes lo que ya existe. El árbol de TODO lo que el brain instala y el detalle 1:1 viven en `MEMORY.md`, que se **auto-carga** con este archivo vía `@import` (ya lo tienes en contexto).

## 📁 Dónde va cada cosa — relativo a la raíz del repo · el árbol de instalación → MEMORY.md

`.claude/` = tu cerebro operativo (memorias + skills para OPERAR este repo + hooks por-repo) · `brain/` = el PRODUCTO que viaja (hooks, skills, scripts, `test-brain.sh`) · `docs/` = flowcharts + parity-checks · `src|macos|windows` = los 3 widgets de cuota. La FIRMA de abajo mapea cada capacidad a su artefacto REAL (skill / script / hook), y el ÁRBOL GIGANTE de lo instalado bajó a `MEMORY.md`.

```
📄 CLAUDE.md ─ LA firma / entry-point (misión + 🖋️ la firma de capacidades + reglas duras)
│   ├─ 🎯 Misión / identidad ....... claude-master que mantiene y propaga el cerebro
│   ├─ 🧠 Antes de construir ....... LEE skills (Read/Skill, NO grep) + estado-proyecto.md · MEMORY.md auto-carga (@import)
│   ├─ 📁 Dónde va cada cosa ....... rutas relativas a la raíz · dualidad .claude/ vs brain/
│   │
│   ├─ 🖋️ LA FIRMA — capacidades de operar el cerebro (cada una → su artefacto real)
│   │     1. Instalar el brain en global (bootstrap) ...... → install.sh · bootstrap.sh · brain/install-brain.sh
│   │     2. Sincronizar el cerebro a un repo/clon ........ → brain/sincronizar-cerebro.sh (diff-aware, --prune-orphans)
│   │     3. Crear un repo GitLab nuevo + proteger ramas .. → brain/nuevo-repo.sh · brain/proteger-ramas.sh
│   │     4. Sembrar la mini-develop de un dev ............ → brain/sembrar-mini-develop.sh
│   │     5. Respaldar/exportar las sesiones master ....... → hook exportar-sesion-master + bin/claude-session
│   │     6. Agregar/editar un hook del cerebro .......... → agregar-hook-cerebro
│   │     7. Trabajar el widget de cuota (KDE/mac/win) ... → cortex-widget · cambiar-icono · publicar-widget
│   │     8. Auditar + consolidar un cerebro ............. → consolidar-cerebro + (auditar-suficiencia-operativa
│   │                                                        + auditar-coherencia-cerebro) + auditar-proceso-algoritmo
│   │     9. Verificar la paridad del árbol (anti-drift) . → docs/flowcharts/verificar-arbol-sync.sh · brain/test-brain.sh
│   │    10. El ÁRBOL — LO QUE EL BRAIN INSTALA ......... → MEMORY.md (🔒 hooks · 🔔 automáticos · 📜 normas · 💡 skills)
│   │    Meta: un cerebro que se AUTO-CURA y viaja IDÉNTICO a cada clon/máquina.
│   │
│   └─ 🛡️ Reglas duras (detalle completo ↓ en la sección ##)
│         ├─ 🧬 Dualidad: nunca mutes brain/ desde una pasada de cerebro
│         ├─ 🌿 Flujo de git: ramita → MR → develop (squash); main = release-only
│         ├─ 🔒 Integridad de guardarraíles: no aflojes tus propios candados
│         └─ 🪞 Doc = realidad: cambió algo → su doc en la misma tanda
▼
📄 MEMORY.md ─ el DETALLE de la firma + EL ÁRBOL de instalación + índice de memorias
│   ├─ 🚦 Detalle 1:1 de cada ítem del árbol ....... el how-to/contrato por hook/skill/norma → su artefacto
│   ├─ 🌳 El árbol — lo que el brain instala ....... 🔒 Forzosos · 🔔 Automático · 📜 Normas · 💡 Skills (+ detalle 1:1)
│   └─ 🗂️ Índice de memorias por tema
▼
📁 .claude/skills/ ─ skills para OPERAR este repo · agregar-hook-cerebro · cortex-widget · cambiar-icono · publicar-widget
📁 .claude/memory/ ─ MEMORY.md (árbol + detalle, @import) + notas de desarrollo · *.local.md personales
   └─ 🛑 cortex NO cablea sus guards por-repo (no hay .claude/hooks/ ni settings.json): corren por la instalación GLOBAL (install-brain.sh) desde brain/hooks/
📁 brain/ ─ el PRODUCTO que viaja a los clones (hooks · skills · scripts · test-brain.sh) — 🛑 NO mutar desde una pasada de cerebro
📁 docs/ ─ flowcharts + checks (verificar-arbol-sync.sh · gen-leyenda-arbol.sh) · investigaciones · …
📁 src/ · macos/ · windows/ ─ los 3 widgets de cuota (los brainTiers espejan el árbol del README)
📁 src/term-broker/ ─ broker de terminal (OPT-IN, Linux): 5 `.ts` VENDORIZADOS de axon + sus 2 probes
   └─ 🛑 copia byte-a-byte: NO se editan aquí — se cambian en axon y se re-vendorizan → `PROCEDENCIA.md`
   └─ 🛑 `SHA256SUMS` es el anti-drift que SÍ corre (lo verifica `probe-instalador.sh`)
   └─ ⚠️ PRIMER servicio long-running de cortex (`Type=simple`, padre de shells) → `docs/term-broker.md`
   └─ 🔁 cambiarse desde la unidad legacy de axon = `bin/migrar-term-broker.sh`, NUNCA a mano
```

## 🛡️ Reglas duras

- 🧬 **Dualidad `.claude/` vs `brain/`.** `.claude/` es el cerebro operativo de ESTE repo; `brain/` es el producto que viaja a los clones. Consolidar/positivar/desinflar/reestructurar toca SOLO `.claude/` + la raíz (`CLAUDE.md`, `README.md`, `docs/`). 🛑 Leer `brain/` es lícito; **mutarlo desde una pasada de cerebro NO** — un cambio ahí viaja a todas las máquinas. Detalle → `MEMORY.md`.
- 🌿 **Flujo de git.** Nunca `git push` a `develop`/`main`; ramita → MR → develop con `--squash`; `main` es **release-only** (promoción deliberada, con OK súper-explícito). Lo hacen cumplir git-branch-guard + merge-squash-guard + confirmar-merge-develop.
- 🔒 **Integridad de los guardarraíles.** No aflojes tus propios candados de supervisión para desatorarte; los cambios permitidos son de **PRECISIÓN**, con OK explícito para ESE control. Detalle → `MEMORY.md`.
- 🪞 **Doc = realidad.** Cambió algo → su doc en la MISMA tanda. El árbol vive en varios catálogos (README fuente ↔ `MEMORY.md` ↔ 3 brainTiers de los widgets) + `verificar-arbol-sync.sh`; sincronízalos juntos.

---

**⚙️ Auto-carga (`@import` de Claude Code):** el core estable del cerebro, siempre en contexto.

@.claude/memory/MEMORY.md
