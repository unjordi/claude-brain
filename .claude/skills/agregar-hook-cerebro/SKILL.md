---
name: agregar-hook-cerebro
description: >
  Añade un guardrail/hook NUEVO al cerebro global de claude-brain de punta a punta —
  el .sh, su cableado idempotente en install/uninstall, su prueba en test-brain, y su
  entrada en el catálogo de la pestaña "Cerebro" de las 3 GUIs (macOS/Linux/Windows).
  Úsalo cuando quieras sumar una regla nueva (bloqueante o de aviso) al cerebro; destila
  el proceso real con que se agregaron secret-scan, rama-vieja y limite-gasto.
---

# agregar-hook-cerebro — sumar un guardrail nuevo al cerebro (end-to-end)

Un hook nuevo NO está "puesto" hasta que: (1) existe el `.sh`, (2) está cableado en
`install-brain.sh` y des-cableado en `uninstall-brain.sh`, (3) tiene prueba en `test-brain.sh`,
y (4) aparece en el **catálogo de la pestaña Cerebro de las 3 GUIs** (si no, el auto-reflejo no
lo cuenta ni lo pinta). Sáltate cualquiera y queda a medias.

## 1. Escribe el hook — `brain/hooks/<nombre>.sh`
Estilo de la casa (mira `git-branch-guard.sh` / `secret-scan.sh` como plantilla):
- `input=$(cat)`; `command -v jq >/dev/null || exit 0` (**fail-open sin jq**, nunca frena a ciegas).
- `cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty')` y **actúa SOLO** sobre lo tuyo
  (p. ej. `grep -qE 'git ...'` o `tool_name=="Task"`); cualquier otra cosa → `exit 0` al instante.
- Escapes deliberados del humano (p. ej. `--no-verify`, una env `CLAUDE_SKIP_*=1`).
- Salida:
  - **BLOQUEA** → `jq -n --arg r "..." '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'`
  - **AVISA (no bloquea)** → `{hookSpecificOutput:{hookEventName:"PreToolUse",additionalContext:"..."}}`
- Mensajes en español, accionables, con el "qué hacer" y el escape. `chmod +x`.
- **Tier**: GLOBAL (aplica a todo repo, se instala en `~/.claude/hooks`) o REPO-SCOPED (viaja en el
  `.claude/` de cada repo; se carga solo si la sesión INICIA ahí). Los global se cablean abajo.

## 2. Cablea (idempotente) — `brain/install-brain.sh` + `brain/uninstall-brain.sh`
- `install-brain.sh`: añade el basename a `GLOBAL_HOOKS` y una línea
  `register_hook <PreToolUse|PostToolUse|Stop|…> <Bash|Task> 'bash "$HOME/.claude/hooks/<n>.sh"' '<n>'`
  (respeta el evento/matcher correcto). Actualiza el `echo` resumen.
- `uninstall-brain.sh`: añade el basename a `GLOBAL_HOOKS` **y** al regex `BRAIN_PAT` (des-cableado del
  settings.json por `jq`).

## 3. Prueba — `brain/test-brain.sh`
- `bash -n` de todos los hooks ya corre por glob (auto). Suma una prueba **funcional** del comportamiento
  (bloquea el caso malo / deja pasar el bueno / respeta el escape / ignora lo ajeno). Corre
  `bash brain/test-brain.sh` → **0 FAIL**. La CI repite `bash -n` + `jq empty` + shellcheck.

## 4. Catálogo de la pestaña Cerebro — vive en 4 LUGARES, mantenlos en SYNC
El árbol está duplicado a mano: **README + 3 GUIs**. Toca los CUATRO en la misma tanda con los MISMOS
`emoji/name/desc` (o el README miente sobre el widget → doc <= realidad; ver memoria [[arbol-cerebro-sync]]):
- **README** raíz — el bloque de árbol de texto (conectores `├─`/`└─`).
- **macOS** `macos/Sources/ClaudeBrain/PopoverView.swift` → `brainTiers` (en el tier que toque) +
  `BrainInspector.swift` → `knownGlobalHooks`.
- **Linux** `src/plasmoid/contents/ui/main.qml` → `brainTiers` + `brainGlobalHooks`.
- **Windows** `windows/src/ClaudeBrain/PopupForm.cs` → `BrainTiers` + `BrainInspector.cs` → `KnownGlobalHooks`.
- Tier por dureza: 🔒 INVIOLABLE (bloquea) · 🔔 AUTOMÁTICO (inyecta/recuerda) · 📜 NORMAS · 💡 SKILLS.
- El estado (activo/faltante) lo lee el inspector de cada GUI. **HOOKS** se casan por basename
  (`knownGlobalHooks`) → renombrar su texto no rompe el estado. **NORMAS** se casan por NAME en la
  lógica de estado de cada GUI (Swift `status()` case · QML `if (name===…)` · C# `StatusOf` switch) →
  si renombras una norma, renómbrala TAMBIÉN ahí en las 3, o se pinta "ausente" (rojo).
- Cierra con un `grep` del nombre VIEJO en README + las 3 GUIs: no debe quedar ninguno.

## 5. Verifica y cierra
`bash brain/test-brain.sh` (0 FAIL) · `swift build --package-path macos` · `dotnet build windows/... -p:EnableWindowsTargeting=true` (0/0) · QML balanceado. Actualiza `brain/README.md` (tabla) y el
dashboard. Reinstala macOS para QA (`bash macos/install.sh --no-brain` + `pkill` + `open`): tu Mac
mostrará **N+1/M** con el curita 🩹 hasta que sanes (el bucle self-healing en acción). Cierra por
el flujo de git (ver skill `publicar-widget`).

> Gemelo del delegado: el gate de costo `delegacion-gate` es un hook que PREGUNTA en vez de bloquear;
> `limite-gasto` es el que BLOQUEA por techo. Distínguelos al diseñar (ask vs deny).
