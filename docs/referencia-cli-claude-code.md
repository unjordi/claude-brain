# Referencia Claude Code CLI + ecosistema Claude

> Wiki local de referencia para trabajar/desarrollar sobre el ecosistema Claude (con foco en el widget de cuota de `cortex`).
> **Fecha de captura:** 2026-08-05.
> **Fuentes oficiales:** documentación de Claude Code en `https://code.claude.com/docs/en/…` (los viejos `docs.anthropic.com/en/docs/claude-code/*` y `docs.claude.com/en/docs/claude-code/*` **redirigen 301** aquí). Índice máquina-legible: `https://code.claude.com/docs/llms.txt`.
> **Fuente de la WebAPI interna de uso/cuota:** NO está en la doc oficial → se documenta desde el **código del propio widget** (`~/.cortex/…`), que ya la consume en producción, citando `archivo:línea`.
> Regla dura de este documento: lo que la doc oficial no dice, va marcado como **hueco**, no se inventa.

---

## Índice (TOC)

**Lo más accionable primero (🎯):**
- [0. Los 3 puntos 🎯 (respuesta directa)](#0-los-3-puntos-)
  - [0.1 🎯 `claude -p` headless lo más rápido SIN romper el OAuth de suscripción](#01--claude--p-headless-lo-más-rápido-sin-romper-el-oauth-de-suscripción)
  - [0.2 🎯 Cómo invocar/orquestar un agente](#02--cómo-invocarorquestar-un-agente)
  - [0.3 🎯 Contrato de I/O de los hooks](#03--contrato-de-io-de-los-hooks)

**Claude Code CLI:**
- [1. CLI reference: comandos y flags](#1-cli-reference-comandos-y-flags)
- [2. Modo headless / SDK / automatización](#2-modo-headless--sdk--automatización)
- [3. Subagents (definición completa)](#3-subagents-definición-completa)
- [3.5 🎯 Herramientas `Task*` (to-do nativo): apagadas por defecto en modelos nuevos](#35--herramientas-task-to-do-nativo-apagadas-por-defecto-en-modelos-nuevos)
- [4. Hooks (todos los eventos + I/O)](#4-hooks-todos-los-eventos--io)
- [5. settings.json (esquema + precedencia)](#5-settingsjson-esquema--precedencia)
- [6. Variables de entorno](#6-variables-de-entorno)
- [7. Memoria / CLAUDE.md / auto memory](#7-memoria--claudemd--auto-memory)
- [8. Slash commands (built-in y custom)](#8-slash-commands-built-in-y-custom)
- [9. Skills](#9-skills)
- [10. MCP servers](#10-mcp-servers)
- [11. Sesiones y transcripts](#11-sesiones-y-transcripts)
- [12. Compactación y contexto](#12-compactación-y-contexto)

**Ecosistema Claude que nos afecta:**
- [13. Claude.app (app de escritorio)](#13-claudeapp-app-de-escritorio)
- [14. La API de pago (ANTHROPIC_API_KEY / Console) vs la suscripción](#14-la-api-de-pago-anthropic_api_key--console-vs-la-suscripción)
- [15. 🎯 La WebAPI interna de USO/CUOTA (fuente del widget)](#15--la-webapi-interna-de-usocuota-fuente-del-widget)
- [16. OAuth de suscripción: flujo, token, alcance de máquina](#16-oauth-de-suscripción-flujo-token-alcance-de-máquina)
- [17. Interrelación: qué superficie usa qué auth / qué bolsa](#17-interrelación-qué-superficie-usa-qué-auth--qué-bolsa)

- [18. Huecos: lo que la doc oficial NO responde](#18-huecos-lo-que-la-doc-oficial-no-responde)

---

## 0. Los 3 puntos 🎯

### 0.1 🎯 `claude -p` headless lo más rápido SIN romper el OAuth de suscripción

**El nudo:** el flag que la doc recomienda para reducir el arranque en scripts es **`--bare`**, PERO `--bare` **desactiva el OAuth de suscripción a propósito**:

> "In bare mode, Claude Code never reads OAuth credentials or the system keychain. For the Anthropic API, set `ANTHROPIC_API_KEY`…" — [headless]

Es decir, **`--bare` te obliga a usar API key de pago** (o `apiKeyHelper`), NO tu suscripción Pro/Max. Los proveedores cloud (Bedrock / Vertex / Foundry) sí leen sus propias credenciales igual. [headless]

**Por lo tanto, para conservar la suscripción OAuth hay DOS caminos limpios:**

1. **Login local activo (interactivo o ya logueado):** corre `claude -p` **sin `--bare`**. Lee el OAuth del keychain (mac) o de `~/.claude/.credentials.json`. Reduce arranque quitando fuentes **sin** apagar OAuth:
   - `--strict-mcp-config` (+ `--mcp-config '{}'` o sin `--mcp-config`) para no cargar MCP del proyecto/usuario.
   - `--setting-sources user` (o el subconjunto que necesites) para no barrer project/local.
   - `--disallowedTools` / `--allowedTools` para acotar el toolset.
   - `--no-session-persistence` para no escribir transcript (evita "proyecto fantasma" y disco).
   - `--exclude-dynamic-system-prompt-sections` mueve las secciones per-máquina al primer mensaje de usuario (arranque más liviano).
   - Este ES el patrón que usa el propio widget: `claude -p --no-session-persistence <prompt>` (NUNCA `--bare`), justamente porque depende del login OAuth activo — ver `QuotaModel.swift:313-317`.

2. **Headless en CI / launchd (sin login interactivo) conservando la SUSCRIPCIÓN:** genera un **token OAuth de larga vida** con `claude setup-token` y expórtalo como **`CLAUDE_CODE_OAUTH_TOKEN`**. Ese token es entitlement de suscripción (NO facturación por token de la API). Confirmado por el código del widget: `CLAUDE_CODE_OAUTH_TOKEN` = "token de larga vida de `claude setup-token`", usado como fallback headless (`cortex-fetch:91-94`).

**Regla mental:** `--bare` = arranque mínimo **pero** exige API key (bolsa de pago). Suscripción OAuth = `claude -p` normal **o** `CLAUDE_CODE_OAUTH_TOKEN`. No existe un flag documentado que a la vez dé "arranque mínimo tipo `--bare`" **y** OAuth de suscripción → ver [Huecos](#18-huecos-lo-que-la-doc-oficial-no-responde).

Notas de rendimiento headless:
- Exit code 0 = éxito; ≠0 = fallo (los scripts ramifican por `$?`). [headless]
- stdin cap = 10MB (v2.1.128+); más grande → escribir a archivo y referenciar la ruta. [headless]
- Tareas Bash en background se matan ~5s tras el resultado final; subagents/workflows en background se esperan (tope 10min por defecto, `CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS`, `0` = sin tope). [headless]

### 0.2 🎯 Cómo invocar/orquestar un agente

Un **subagent** corre en su propia ventana de contexto, con system prompt, tools y permisos propios, y devuelve solo su resumen. [sub-agents]

**Formas de invocar (de menos a más determinista):**
- **Lenguaje natural:** nombra el subagent en el prompt ("Use the test-runner subagent to…") → Claude decide si delega.
- **@-mención:** `@"code-reviewer (agent)"` o manual `@agent-<name>` → **garantiza** ese subagent para esa tarea (tú eliges cuál; Claude escribe el prompt de la tarea).
- **Sesión entera como agente:** `claude --agent <name>` → el hilo principal ADOPTA el system prompt, tools y modelo de ese agente (reemplaza el system prompt default, como `--system-prompt`). Persiste al hacer `--resume`. Default por proyecto: `"agent": "code-reviewer"` en `.claude/settings.json`.
- **Programáticamente:** la herramienta **`Agent`** (antes `Task`, renombrada en v2.1.63; `Task(...)` sigue como alias). Parámetros clave: `subagent_type`, `run_in_background`, y (en fork) el modelo se hereda.

**Definir subagents — `.claude/agents/*.md`** (Markdown con frontmatter YAML; body = system prompt):
```markdown
---
name: code-reviewer            # requerido; minúsculas y guiones; sin ":"; = agent_type en hooks
description: When to delegate  # requerido; guía la delegación automática ("use proactively" fuerza)
tools: Read, Grep, Glob        # allowlist; si se omite hereda el pool de subagents
disallowedTools: Write, Edit   # denylist (se aplica ANTES que tools)
model: sonnet                  # sonnet|opus|haiku|fable|<id completo>|inherit (default inherit)
permissionMode: plan           # default|acceptEdits|auto|dontAsk|bypassPermissions|plan
maxTurns: 10
skills: [api-conventions]      # precarga contenido completo de skills al arranque
mcpServers: [github]           # nombres ya configurados o defs inline
hooks: {PreToolUse: [...]}     # hooks scoped a este agente (Stop→SubagentStop en subagent)
memory: project                # user|project|local → dir persistente cross-sesión
background: true               # forzar background siempre
effort: high                   # low|medium|high|xhigh|max
isolation: worktree            # corre en un git worktree temporal (auto-limpiado si no hay cambios)
color: blue
initialPrompt: "..."           # auto-enviado como 1er turno cuando corre como main (--agent)
---
Cuerpo = system prompt del agente.
```
- **Ubicación/precedencia** (mayor→menor): managed settings > `--agents` (JSON de sesión) > `.claude/agents/` (proyecto) > `~/.claude/agents/` (usuario) > plugin. Se descubren recursivamente (subcarpetas ok); identidad = campo `name`.
- **`--agents '<json>'`**: define subagents solo para esa sesión (mismos campos: `description`, `prompt`, `tools`, `disallowedTools`, `model`, `permissionMode`, `mcpServers`, `hooks`, `maxTurns`, `skills`, `initialPrompt`, `memory`, `effort`, `background`, `isolation`, `color`). Útil en automatización.

**Built-in subagents:** `Explore` (read-only, búsqueda; modelo hereda, cap Opus en la API), `Plan` (research en plan mode, read-only), `general-purpose` (todo el toolset, multi-paso), `claude` (catch-all; **default del background dispatch**), más `statusline-setup`, `claude-code-guide`.

**Foreground vs background:**
- **Default (v2.1.198+): background.** Claude usa foreground solo cuando necesita el resultado ya.
- Background: toolset built-in **más chico** (Read, Grep, Glob, Bash, PowerShell, Edit, Write, NotebookEdit, WebFetch, WebSearch, TodoWrite, Skill, ToolSearch, EnterWorktree, ExitWorktree, Monitor, TaskStop, SendMessage, Artifact); resultado llega como notificación en un turno posterior (Claude espera a esa notificación antes de reportar).
- `Ctrl+B` manda una tarea a background; `CLAUDE_CODE_DISABLE_BACKGROUND_TASKS=1` apaga todo el background.
- **Aislamiento:** `isolation: worktree` da copia aislada del repo (rama por defecto desde tu default branch). Un subagent NO saca la rama del árbol compartido — corre en su worktree.
- **Anidamiento:** un subagent puede spawnear subagents si `Agent` está en su `tools` y no llegó al depth limit. `Agent(worker, researcher)` restringe qué tipos puede spawnear (solo aplica al main con `--agent`).
- **Restringir/desactivar:** `permissions.deny: ["Agent(Explore)"]` o `--disallowedTools "Agent(Explore)"`.

**Orquestación paralela:** spawnear varios subagents para investigaciones independientes; cada uno explora en su contexto y Claude sintetiza. Cuidado: muchos resultados detallados de vuelta consumen contexto. Para paralelismo sostenido/varias sesiones full, ver `agent-teams` y `agent-view` (background agents). [sub-agents, costs]

### 0.3 🎯 Contrato de I/O de los hooks

**Entrada:** cada hook recibe por **stdin** un JSON. Campos comunes a (casi) todos: `session_id`, `transcript_path`, `cwd`, `hook_event_name`, y según el evento `permission_mode`, `prompt_id`, `tool_name`, `tool_input`, `tool_response`, `tool_use_id`, `prompt`, `stop_hook_active`, `source`/`trigger`, `last_assistant_message`, `error`, `message`. (Tabla completa por evento en [§4](#4-hooks-todos-los-eventos--io).)

**Salida:** por **stdout** un JSON (con **exit code 0**), o se controla por **exit code**:
- **exit 0** → éxito; se parsea stdout como JSON. stderr solo va al debug log.
- **exit 2** → **error bloqueante**; stderr se muestra a Claude (o al usuario en eventos no bloqueantes); la acción se previene; el JSON de stdout se ignora.
- **otro** → error no bloqueante; la acción sigue; se anota un aviso con la 1ª línea de stderr. (Excepción: `WorktreeCreate` falla con cualquier ≠0.)

**Campos de salida (JSON):**
- Comunes: `continue` (bool; `false` detiene), `stopReason`, `suppressOutput`, `systemMessage` (aviso), `terminalSequence`.
- `decision: "block"` + `reason` → bloquea/continúa según el evento (p. ej. en `UserPromptSubmit` borra el prompt; en `Stop`/`SubagentStop` impide terminar; en `PreCompact` bloquea compactar).
- `hookSpecificOutput.additionalContext` → **inyecta contexto** para Claude. Lo ACEPTAN: `SessionStart`, `Setup`, `UserPromptSubmit`, `UserPromptExpansion`, `PreToolUse`, `PostToolUse`, `PostToolUseFailure`, `PostToolBatch`, `Stop`, `SubagentStart`, `SubagentStop`. (Otros solo tienen side-effects / `systemMessage`.)
- `hookSpecificOutput.permissionDecision`: `allow|deny|ask|defer` + `permissionDecisionReason` (solo `PreToolUse`).
- `hookSpecificOutput.updatedInput` (reescribe tool_input, `PreToolUse`), `updatedToolOutput` (reemplaza resultado, `PostToolUse`), `displayContent` (`MessageDisplay`), `worktreePath` (`WorktreeCreate`).

**Cableado en settings.json:**
```json
{
  "hooks": {
    "PreToolUse": [
      { "matcher": "Bash|Edit|Write",
        "hooks": [
          { "type": "command", "command": "${CLAUDE_PROJECT_DIR}/.claude/hooks/guard.sh",
            "shell": "bash", "timeout": 600, "if": "Bash(rm *)" }
        ] }
    ]
  }
}
```
- `matcher`: nombre de tool / regex (no anclada) / `mcp__server__.*`. `shell: "bash"|"powershell"`. `type`: `command|http|mcp_tool|prompt|agent`. Placeholders: `${CLAUDE_PROJECT_DIR}`, `${CLAUDE_PLUGIN_ROOT}`.
- Ubicaciones: `~/.claude/settings.json` (global), `.claude/settings.json` (proyecto, viaja por git), `.claude/settings.local.json` (local), managed policy, plugin `hooks/hooks.json`, frontmatter de skill/agent. `disableAllHooks: true` apaga todos.

---

## 1. CLI reference: comandos y flags

Fuente: [cli-reference]. `claude` abre sesión interactiva; `claude "prompt"` con prompt inicial; `claude -p "prompt"` no-interactivo.

### Subcomandos
| Comando | Qué hace |
|---|---|
| `claude` / `claude "q"` | Sesión interactiva (opcional prompt inicial) |
| `claude -p "q"` | Query no-interactiva (SDK) y sale |
| `claude -c` / `--continue` | Continúa la conversación más reciente del cwd |
| `claude -r "<id\|nombre>" "q"` / `--resume` | Reanuda sesión (o abre el picker sin arg) |
| `claude update` | Actualiza a la última versión |
| `claude install [version]` | Instala/reinstala el binario nativo (`stable`/`latest`) |
| `claude auth login\|logout\|status` | Login / logout / estado (JSON) de la cuenta Anthropic |
| `claude setup-token` | Genera **token OAuth de larga vida** para CI/scripts (→ `CLAUDE_CODE_OAUTH_TOKEN`) |
| `claude mcp …` | Configura MCP servers (`add`, `list`, `get`, `remove`, `add-json`, `login/logout <name>`) |
| `claude agents [--json] [--all] [--cwd <p>]` | Ver/monitorear sesiones background paralelas |
| `claude attach <id>` | Adjuntar a una sesión background |
| `claude logs <id>` / `stop <id>` / `respawn <id>` / `rm <id>` | Gestión de sesiones background (`stop` alias `kill`) |
| `claude daemon status\|stop --any` | Supervisor de sesiones background |
| `claude doctor` | Diagnóstico de instalación/settings |
| `claude project purge [path] [--dry-run]` | Borra TODO el estado local de Claude Code de un proyecto |
| `claude gateway` | Servidor self-hosted "Claude apps gateway" |
| `claude plugin …` | Gestión de plugins |
| `claude remote-control` | Servidor Remote Control |
| `claude auto-mode defaults\|reset` | Reglas del clasificador auto-mode (JSON / reset) |
| `claude ultrareview [target]` | Ultrareview no-interactivo |

### Flags (por familia)
**Sesión:** `-p/--print`, `-c/--continue`, `-r/--resume`, `-n/--name`, `-w/--worktree`, `--fork-session`, `--session-id <uuid>`, `--bg/--background`, `--cloud` (`--remote` deprecado), `--teleport`, `--remote-control/--rc`, `--from-pr <n>`.
**Modelo/esfuerzo:** `--model <alias|id>` (`sonnet|opus|haiku|fable` o full), `--effort <low|medium|high|xhigh|max|ultracode>`, `--fallback-model <a,b>`, `--advisor <model>`.
**Permisos/tools:** `--permission-mode <default|acceptEdits|plan|auto|dontAsk|bypassPermissions|manual>`, `--dangerously-skip-permissions` (= bypassPermissions), `--allow-dangerously-skip-permissions`, `--permission-prompt-tool <mcp_tool>`, `--allowedTools`/`--allowed-tools`, `--disallowedTools`/`--disallowed-tools`, `--tools "Bash,Edit,Read"`.
**System prompt:** `--system-prompt`, `--system-prompt-file`, `--append-system-prompt`, `--append-system-prompt-file`, `--append-subagent-system-prompt`, `--exclude-dynamic-system-prompt-sections`.
**Salida/formato:** `--output-format <text|json|stream-json>`, `--input-format <text|stream-json>`, `--verbose`, `--include-partial-messages`, `--include-hook-events`, `--forward-subagent-text`, `--prompt-suggestions`, `--replay-user-messages`, `--json-schema '<schema>'`, `--no-session-persistence`.
**Directorios/settings:** `--add-dir <...>`, `--setting-sources <user,project,local>`, `--settings <archivo|json>`.
**Agentes:** `--agent <name>` (sesión entera como ese agente), `--agents '<json>'` (define subagents en línea).
**MCP/plugins:** `--mcp-config <archivos|json>`, `--strict-mcp-config` (solo los de `--mcp-config`), `--channels`, `--dangerously-load-development-channels`, `--plugin-dir <path>`, `--plugin-url <url>`.
**Navegador/IDE:** `--chrome`, `--no-chrome`, `--ide`.
**Control de flujo:** `--init` / `--init-only` / `--maintenance` (corren hooks Setup), `--exec '<cmd>'` (job PTY background), `--max-turns <n>` (print mode), `--max-budget-usd <n>` (print mode).
**Modo/config:** `--bare` (arranque mínimo; **exige API key**, ver §0.1), `--safe-mode`, `--disable-slash-commands`, `--autocompact <auto|tokens>`, `--betas <...>` (solo API key).
**UX/debug:** `--ax-screen-reader`, `--teammate-mode <in-process|auto|tmux|iterm2>`, `--tmux`, `--debug ["cats"]`, `--debug-file <path>`, `--version/-v`.

---

## 2. Modo headless / SDK / automatización

Fuente: [headless]. `claude -p` = el Agent SDK vía CLI. Todos los flags de la CLI valen con `-p`.

- **Auth (crítico):** con login normal, `claude -p` lee OAuth del keychain/`~/.claude/.credentials.json` (suscripción). Con **`--bare`** NO lee OAuth → exige `ANTHROPIC_API_KEY` o `apiKeyHelper` (pago). Para CI con suscripción: `CLAUDE_CODE_OAUTH_TOKEN` (de `claude setup-token`). Ver §0.1 y §16.
- **Formatos de salida:** `text` (default), `json` (result + session_id + usage + `total_cost_usd` + breakdown por modelo), `stream-json` (NDJSON de eventos; la última línea es el `result`). Para streaming de tokens: `--output-format stream-json --verbose --include-partial-messages`.
- **Salida estructurada por schema:** `--output-format json --json-schema '<JSON Schema>'` → el resultado va en `structured_output`. `format` se acepta como anotación (no se enforcea).
- **Eventos del stream:** `system/init` (model, tools, mcp_servers, plugins, `capabilities`), `system/api_retry` (attempt, max_retries, retry_delay_ms, error_status, error), `system/plugin_install`. Mensajes de subagent llevan `parent_tool_use_id`.
- **Continuar/reanudar:** `--continue`; capturar `session_id` de `--output-format json` y `--resume "$session_id"` (scope = cwd + worktrees).
- **Auto-aprobar tools:** `--allowedTools "Bash,Read,Edit"`; o permission-mode (`dontAsk` = CI cerrado, `acceptEdits` = escribe sin pedir). Sintaxis de reglas: `Bash(git diff *)` (ojo al espacio antes de `*`).
- **Ejemplos:**
  ```bash
  cat build-error.txt | claude -p 'explica la causa raíz' > out.txt
  git diff main | claude -p "revisa estos cambios por seguridad" --output-format json
  claude -p "extrae nombres de función de auth.py" --output-format json \
    --json-schema '{"type":"object","properties":{"functions":{"type":"array","items":{"type":"string"}}},"required":["functions"]}' | jq '.structured_output'
  ```
- **Skills/commands en `-p`:** incluir `/skill-name` en el prompt (se expande). Built-ins solo-terminal (p. ej. `/login`) NO están en `-p`. `/model`, `/effort`, `/fast`, `/color`, `/config key=value`, `/mcp` (resumen) funcionan en `-p` (v2.1.205+).
- **SDK Python/TypeScript:** `agent-sdk/overview`, `agent-sdk/python`, `agent-sdk/typescript` (objetos de mensaje, callbacks de aprobación, streaming).

---

## 3. Subagents (definición completa)

(Resumen accionable en §0.2.) Fuente: [sub-agents]. Puntos que no caben arriba:

- **Qué carga un subagent:** solo su system prompt (body) + detalles básicos de entorno (cwd). NO la auto memory del main (salvo *fork*). Explore/Plan además saltan CLAUDE.md y el git status del padre.
- **Resolución del modelo:** `CLAUDE_CODE_SUBAGENT_MODEL` → param por-invocación → frontmatter `model` → modelo del main. Se valida contra `availableModels`. Hereda el extended thinking del main (v2.1.198+).
- **Filtros de tools:** se quitan siempre `AskUserQuestion`, `EndConversation`, `EnterPlanMode`, `ExitPlanMode` (salvo permissionMode plan), `ScheduleWakeup`, `TaskOutput`, `WaitForMcpServers`, `Workflow`, y `Agent` en el depth limit. Background reduce más el set (ver §0.2).
- **`disallowedTools` primero, luego `tools`** contra el pool restante. Aceptan patrones MCP (`mcp__server`, `mcp__server__*`, y `mcp__*` en deny).
- **Memoria persistente (`memory`):** `user`→`~/.claude/agent-memory/<name>/`, `project`→`.claude/agent-memory/<name>/`, `local`→`.claude/agent-memory-local/<name>/`. Se carga `MEMORY.md` (primeras 200 líneas/25KB). Depende de auto memory global (`autoMemoryEnabled`/`CLAUDE_CODE_DISABLE_AUTO_MEMORY`).
- **Hooks del subagent:** en frontmatter (solo mientras corre; `Stop`→`SubagentStop`) o en settings (`SubagentStart`/`SubagentStop` con matcher = `name`). Los plugin subagents ignoran `hooks`, `mcpServers`, `permissionMode` por seguridad.
- **Escaneo de output:** Claude Code escanea el reporte final del subagent (inserta backslash a imitaciones de `<system-reminder>`/`Human:`/`Assistant:`; prepende línea `[harness: …]` si menciona `bypassPermissions`). No juzga malicia ni sustituye los límites de tools. (v2.1.210+)
- **`/agents`** (v2.1.198+) ya NO abre wizard: recuerda pedirle a Claude o editar `.claude/agents/`. `CLAUDE_CODE_DISABLE_EXPLORE_PLAN_AGENTS=1` quita Explore/Plan; `CLAUDE_AGENT_SDK_DISABLE_BUILTIN_AGENTS=1` quita todos los built-in en headless/SDK.

---

## 3.5 🎯 Herramientas `Task*` (to-do nativo): apagadas por defecto en modelos nuevos

> Nos costó horas hoy (2026-09-08) sin que esta referencia dijera nada al respecto — de ahí esta sección.
> **Ojo con el nombre:** esto NO es el `Task` legacy de §0.2 (la tool de invocar subagents, renombrada
> `Agent` en v2.1.63; `Task(...)` sigue de alias ahí). Es una familia DISTINTA: trackear un to-do/backlog
> dentro de la sesión — el reemplazo nativo de `TodoWrite`.

**Accionable primero — cómo encenderlas de forma durable:** en el bloque `env` de `settings.json`
(global o de proyecto), pon `CLAUDE_CODE_ENABLE_TODO_TOOLS=1` (el parser acepta `1`, `true`, `yes`, `on`).
**Gotcha verificado en vivo:** el toolset se resuelve **al ARRANCAR la sesión** — agregar la variable al
settings con la sesión ya viva **NO** las trae; hay que reabrir. (Medido hoy: un proceso arrancó a las
17:27 sin ninguna `CLAUDE_*` en su entorno, y el `settings.json` se editó a las 17:57 — esa sesión nunca
las tuvo hasta reabrir.)

**El gate — verificado hoy contra el binario 2.1.265, en vivo:** desde el CLI **v2.1.233**, `TaskCreate` /
`TaskGet` / `TaskList` / `TaskUpdate` vienen **APAGADAS por defecto** cuando el modelo del **bucle
principal** es de una familia/versión nueva: **opus ≥ 4.8, sonnet ≥ 5, fable ≥ 5, mythos ≥ 5**. Por
debajo de ese umbral (o familia desconocida) están **ON sin condiciones**. Motivo declarado por
Anthropic: esos modelos ya siguen el trabajo multi-paso internamente, y el esquema de las tools les
costaba contexto sin aportar.

**Las 5 vías que las encienden (basta con una):**
1. Sesión **background**, o Claude Code **en la web** → siempre las tienen, sin importar el modelo.
2. Arrancar con `--allowedTools TaskCreate` (o `--tools` incluyéndola) → enciende el opt-in de arranque.
3. El modelo del bucle principal es anterior al umbral de arriba.
4. Env var **`CLAUDE_CODE_ENABLE_TODO_TOOLS=1`** (acepta `1`, `true`, `yes`, `on`).
5. Un feature flag de servidor con nombre en clave — no es un flag público con "task" en el nombre, y no
   aparece en el cache local de features. `[SIN CONFIRMAR]` el nombre/mecanismo exacto de ese flag.

**Variable hermana — `CLAUDE_CODE_ENABLE_TASKS`:** decide **CUÁL** familia sale, no **SI** sale. Sin
setear (o en verdadero) → salen las `Task*`. En falso (`0`, `false`, `no`, `off`) → devuelve el
`TodoWrite` legacy. Son carriles **mutuamente excluyentes**: con las `Task*` activas, `TodoWrite` no
aparece — y es por diseño, no bug.

**Cómo se aisló el gate (comando reproducible):**
```bash
claude -p "Llama a TaskList. Responde EXISTE o NO-EXISTE." --model opus
CLAUDE_CODE_ENABLE_TODO_TOOLS=1 claude -p "Llama a TaskList. Responde EXISTE o NO-EXISTE." --model opus
```
La primera invocación no las tiene; la segunda sí — así se aisló el gate del resto de variables de entorno.

**No es cosa de nuestra máquina:** el mismo síntoma (las task tools dejan de exponerse al modelo) está
reportado en `anthropics/claude-code` issues **#80015**, **#23816** y **#80566**, sin respuesta de
mantenedores al momento de escribir esto.

---

## 4. Hooks (todos los eventos + I/O)

(Contrato general en §0.3.) Fuente: [hooks]. Todos los eventos observados en la doc, con disparador, entrada distintiva y control de salida:

| # | Evento | Dispara | Entrada distintiva | Control de salida |
|---|---|---|---|---|
| 1 | **SessionStart** | inicia/reanuda sesión | `source: startup\|resume\|clear\|compact\|fork`, `model?` | `additionalContext`, `initialUserMessage`, `watchPaths`, `sessionTitle`, `reloadSkills`, `systemMessage` |
| 2 | **Setup** | `--init/--init-only/--maintenance` | `trigger: init\|maintenance` | `additionalContext`, `systemMessage` |
| 3 | **UserPromptSubmit** | usuario envía prompt (antes de procesar) | `prompt`, `prompt_id` | `decision:block`+`reason` (borra prompt), `additionalContext`; exit 2 bloquea. Timeout 30s |
| 4 | **UserPromptExpansion** | un slash-command se expande a prompt | `command_name`, `expanded_prompt` | `decision:block`+`reason`, `additionalContext` |
| 5 | **PreToolUse** | antes de ejecutar una tool | `tool_name`, `tool_input`, `tool_use_id`, `effort` | `permissionDecision: allow\|deny\|ask\|defer` + `permissionDecisionReason`, `updatedInput`; exit 2 bloquea. Matcher = tool; `if` = regla de permiso |
| 6 | **PermissionRequest** | una tool necesita decisión de permiso | `tool_input`, `permission_type` | `decision:{behavior:allow\|deny, updatedInput}` |
| 7 | **PermissionDenied** | el clasificador auto-mode denegó | `tool_name`, `tool_input` | `retry: true` (exit 0, no bloquea) |
| 8 | **PostToolUse** | tras tool exitosa | `tool_response` | `decision:block`+`reason`, `additionalContext`, `updatedToolOutput`, `systemMessage`; exit 2 = stderr a Claude (la tool YA corrió) |
| 9 | **PostToolUseFailure** | tras tool fallida | `error` | `decision:block`+`reason`, `additionalContext` |
| 10 | **PostToolBatch** | tras batch de tools paralelas | `tool_calls[]` | `decision:block` (para el loop antes del próximo model call), `additionalContext` |
| 11 | **Stop** | Claude termina el turno | `last_assistant_message`, `stop_hook_active` | `decision:block`+`reason` (impide terminar → sigue), `additionalContext`; exit 2 previene stop |
| 12 | **StopFailure** | turno termina por error de API | `error`, `error_message` | sin control (ignorado) |
| 13 | **SubagentStart** | se spawnea subagent | `agent_id`, `agent_type` | `additionalContext`, `systemMessage`. Matcher = agent type |
| 14 | **SubagentStop** | subagent termina | `agent_id`, `agent_type`, `last_assistant_message` | `decision:block`+`reason`, `additionalContext` |
| 15 | **TaskCreated** | se crea task (`TaskCreate`) | `task{title,description}` | `decision:block` (rollback), `continue:false` |
| 16 | **TaskCompleted** | task marcada completa | `task{title,id}` | `decision:block` (impide), `continue:false` |
| 17 | **TeammateIdle** | teammate va a quedar idle | `agent_type` | exit 2 / `continue:false` = sigue trabajando |
| 18 | **PreCompact** | antes de compactar | `trigger: manual\|auto` | `decision:block` (bloquea compactar) |
| 19 | **PostCompact** | tras compactar | `trigger` | solo `systemMessage`, `terminalSequence` |
| 20 | **Notification** | Claude Code notifica | `type`, `message` | sin control (side-effects). Matcher = tipo |
| 21 | **MessageDisplay** | se muestra texto del asistente | `message` | `displayContent` (reemplaza en pantalla, no en transcript). Timeout 10s |
| 22 | **InstructionsLoaded** | carga CLAUDE.md / `.claude/rules/*.md` | `source`, `file_path` | sin control |
| 23 | **ConfigChange** | cambia un archivo de config | `config_source`, `file_path` | `decision:block` (salvo `policy_settings`) |
| 24 | **CwdChanged** | cambia el cwd (`cd`) | `previous_cwd` | sin control (siempre fira; sin matcher) |
| 25 | **DirectoryAdded** | `/add-dir` o SDK añade dir | `added_directory`, `source` | sin control |
| 26 | **FileChanged** | cambia un archivo vigilado | `file_path`, `change_type` | sin control. Matcher = nombres literales |
| 27 | **WorktreeCreate** | se crea worktree | `isolation_source`, `base_directory` | command→ruta por stdout; http→`worktreePath`. **Cualquier ≠0 falla la creación** |
| 28 | **WorktreeRemove** | se quita worktree | `worktree_path` | sin control |
| 29 | **Elicitation** | MCP pide input al usuario | `mcp_server_name`, `form_schema` | `action: accept\|decline\|cancel` + `content`. Matcher = server |
| 30 | **ElicitationResult** | tras respuesta a elicitation | `mcp_server_name`, `user_response` | `action` + `content` (override) |

**Config avanzada por hook:** `async`/`asyncRewake`, `statusMessage`, `once`, `url`+`headers`+`allowedEnvVars` (http), `server`+`tool`+`input` (mcp_tool), `prompt`+`model` (prompt/agent). `allowedHttpHookUrls` en settings restringe URLs.
**Nota:** NO hay hook útil de `PreCompact` para inyectar contexto (no hay turno del modelo antes de compactar); el "no perder el hilo" se hace con SessionStart + skill de checkpoint.

---

## 5. settings.json (esquema + precedencia)

Fuente: [settings]. **Precedencia (mayor→menor):** managed/policy (MDM, plist, registry, `managed-settings.json`) > argumentos CLI > local (`.claude/settings.local.json`) > proyecto (`.claude/settings.json`) > usuario (`~/.claude/settings.json`) > default. Arrays de `permissions`/MCP **se fusionan**; `deny` gana sobre `allow`.
Rutas de sistema: mac `/Library/Application Support/ClaudeCode/`, Linux/WSL `/etc/claude-code/`, Windows `C:\Program Files\ClaudeCode\`. Home `~/.claude/`.

**Claves top-level destacadas:**
- Modelo: `model`, `fallbackModel[]`, `availableModels[]`, `enforceAvailableModels`, `advisorModel`, `effortLevel`, `alwaysThinkingEnabled`, `agent`.
- Permisos: `permissions{allow[],deny[],ask[],defaultMode,additionalDirectories[]}`, `disableAutoMode`, `autoMode{environment,allow,soft_deny,hard_deny,classifyAllShell}`.
- MCP: `enableAllProjectMcpServers`, `enabledMcpjsonServers[]`, `disabledMcpjsonServers[]`, `allowedMcpServers[]`/`deniedMcpServers[]` (managed), `disableClaudeAiConnectors`.
- Hooks: `hooks{}`, `disableAllHooks`, `allowManagedHooksOnly`, `allowedHttpHookUrls[]`.
- Memoria/contexto: `autoMemoryEnabled`, `autoMemoryDirectory`, `claudeMd` (managed), `claudeMdExcludes[]`, `cleanupPeriodDays` (default 30), `autoCompactEnabled`, `autoCompactWindow` (100k–1M).
- UI: `outputStyle` (`classic|default|fullscreen`), `tui`, `editorMode` (`normal|vim`), `defaultShell` (`bash|powershell`), `statusLine`.
- Auth/API: `apiKeyHelper` (comando que emite el valor de auth; TTL vía `CLAUDE_CODE_API_KEY_HELPER_TTL_MS`), `awsCredentialExport`, `awsAuthRefresh`, `forceLoginMethod`, `forceLoginOrgUUID`.
- Otros: `env{}`, `attribution{commit,pr}`, `includeCoAuthoredBy` (attribution), `autoUpdatesChannel` (`latest|stable`), `requiredMinimum/MaximumVersion` (managed), `disableSideloadFlags` (managed; rechaza `--plugin-dir/--plugin-url/--agents/--mcp-config`), `sandbox{}`, `disableBundledSkills`, `disableWorkflows`, `enableArtifact`/`disableArtifact`.
- `$schema`: `https://json.schemastore.org/claude-code-settings.json`.

---

## 6. Variables de entorno

Fuente: [settings], [env-vars]. Las que más importan aquí:
- **Auth:** `ANTHROPIC_API_KEY` (API de pago), `CLAUDE_CODE_OAUTH_TOKEN` (token OAuth de larga vida = suscripción, headless), `ANTHROPIC_AUTH_TOKEN` (auth alterna).
- **Config/rutas:** `CLAUDE_CONFIG_DIR` (mueve `~/.claude` → afecta dónde viven `.credentials.json`, `.claude.json`, `projects/`), `XDG_CONFIG_HOME`, `XDG_DATA_HOME`.
- **Modelo/inferencia:** `ANTHROPIC_MODEL`, `CLAUDE_CODE_SUBAGENT_MODEL`, `MAX_THINKING_TOKENS`, `ANTHROPIC_API_URL`/`ANTHROPIC_BASE_URL` (proveedor alterno).
- **Toggles:** `CLAUDE_CODE_DISABLE_AUTO_MEMORY`, `DISABLE_AUTO_COMPACT`, `DISABLE_AUTOUPDATER`, `CLAUDE_CODE_DISABLE_BACKGROUND_TASKS`, `CLAUDE_CODE_DISABLE_BUNDLED_SKILLS`, `CLAUDE_CODE_ENABLE_TELEMETRY`, `CLAUDE_CODE_SKIP_PROMPT_HISTORY` (no escribe transcripts), `CLAUDE_CODE_FORWARD_SUBAGENT_TEXT`, `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`.
- **Herramientas `Task*` (to-do nativo):** `CLAUDE_CODE_ENABLE_TODO_TOOLS=1` fuerza que existan (apagadas por defecto en modelos nuevos); `CLAUDE_CODE_ENABLE_TASKS=0` devuelve el `TodoWrite` legacy en vez de la familia `Task*`. Requiere reiniciar la sesión (no aplica en caliente). Detalle completo + el gate por modelo: [§3.5](#35--herramientas-task-to-do-nativo-apagadas-por-defecto-en-modelos-nuevos).
- **Cloud/gateway:** `AWS_PROFILE/REGION/…`, OTEL_*.

---

## 7. Memoria / CLAUDE.md / auto memory

Fuente: [memory]. Dos sistemas, ambos cargan al inicio de cada sesión:

**CLAUDE.md (lo escribes tú).** Ubicaciones (orden de carga, amplio→específico):
- Managed: mac `/Library/Application Support/ClaudeCode/CLAUDE.md`, Linux/WSL `/etc/claude-code/CLAUDE.md`, Windows `C:\Program Files\ClaudeCode\CLAUDE.md` (o clave `claudeMd` en managed settings).
- Usuario: `~/.claude/CLAUDE.md`.
- Proyecto: `./CLAUDE.md` o `./.claude/CLAUDE.md` (viaja por git).
- Local: `./CLAUDE.local.md` (gitignore).
- Se concatenan subiendo por el árbol (root→cwd); `CLAUDE.local.md` va tras `CLAUDE.md` en cada nivel; subdirectorios cargan on-demand.
- **Imports:** `@path/to/file` (relativo al archivo, o absoluto; recursivo hasta 4 saltos; se salta dentro de code spans/backticks). Imports externos a un memory de proyecto piden diálogo de aprobación.
- `.claude/rules/*.md`: reglas modulares; con frontmatter `paths:` (globs) cargan solo al tocar archivos que casan. `~/.claude/rules/` = reglas de usuario.
- `AGENTS.md`: Claude Code NO lo lee directo; usar `@AGENTS.md` en CLAUDE.md o symlink. `/init` genera/mejora CLAUDE.md.
- Target < 200 líneas; comentarios HTML de bloque se quitan del contexto.

**Auto memory (la escribe Claude).** Por defecto ON. Storage: `~/.claude/projects/<project>/memory/` (derivado del repo git; compartido por worktrees). `MEMORY.md` = índice (se cargan primeras 200 líneas/25KB); topic files se leen on-demand. Es **machine-local** (no viaja entre máquinas). Toggle: `/memory`, `autoMemoryEnabled`, `CLAUDE_CODE_DISABLE_AUTO_MEMORY=1`. `autoMemoryDirectory` reubica. Campo `modified` (ISO 8601) en frontmatter (v2.1.214+).

---

## 8. Slash commands (built-in y custom)

Fuente: [commands], [skills]. **Custom commands se fusionaron en skills:** `.claude/commands/deploy.md` y `.claude/skills/deploy/SKILL.md` ambos crean `/deploy`. Los `.claude/commands/` viejos siguen; si chocan, la skill gana.

**Custom command mínimo** (`.claude/commands/<name>.md` proyecto, o `~/.claude/commands/` usuario):
```markdown
---
description: Qué hace (ayuda a Claude a autoinvocarla)
---
Instrucciones. Usa $ARGUMENTS para el texto pasado tras el comando.
!`git diff HEAD`    # inyección dinámica: corre el comando e inlinea su salida
```

**Built-ins destacados** (mayoría solo-terminal; en `-p` solo un subconjunto):
`/help`, `/clear` (alias `/reset`,`/new`), `/compact [instr]`, `/context [all]`, `/model [m]`, `/effort [lvl]`, `/config` (alias `/settings`), `/permissions` (alias `/allowed-tools`), `/agents`, `/init`, `/memory`, `/resume [name]`, `/rename`, `/branch [name]`, `/rewind`, `/status`, `/tasks`, `/mcp`, `/hooks`, `/login`, `/logout`, `/add-dir`, `/cd`, `/export [file]`, `/copy [N]`, `/doctor` (alias `/checkup`), `/cost` (= `/usage`), `/usage`, `/usage-credits`, `/upgrade`, `/desktop` (alias `/app`), `/teleport`, `/vim`, `/plan`, `/goal`, `/diff`.
**Cuota/costo:** `/usage` muestra uso y límites de suscripción (barras plan + 24h/7d, atribución por skill/subagent/MCP; `d`/`w` alternan); `/cost` es alias; `/usage-credits` gestiona créditos de sobreuso (requiere login claude.ai, no API key).
En `-p` (v2.1.205+): `/model`, `/effort`, `/fast`, `/color`, `/config key=value`, `/mcp` (resumen).

---

## 9. Skills

Fuente: [skills]. Una skill = carpeta con `SKILL.md` (frontmatter YAML + cuerpo Markdown). El cuerpo carga **on-demand** (barato hasta usarse). Se invoca con `/skill-name` o auto por `description`.
Ubicaciones/precedencia: enterprise > `~/.claude/skills/<name>/SKILL.md` (personal) > `.claude/skills/<name>/SKILL.md` (proyecto) > plugin (`plugin:skill`). Nested `.claude/skills/` cargan al tocar archivos de su subdir (nombre calificado `apps/web:deploy`).
Frontmatter: `description` (requerido), `disable-model-invocation: true` (solo tú la invocas), `context: fork` (inyecta en el agente que indiques), etc. Inyección dinámica con `` !`cmd` ``. Live-reload sin reiniciar (salvo crear un dir nuevo).
Bundled: `/run`, `/verify`, `/run-skill-generator`, `/code-review`, `/debug`, `/dataviz`, etc. `disableBundledSkills`/`CLAUDE_CODE_DISABLE_BUNDLED_SKILLS` los apagan.

---

## 10. MCP servers

Fuente: [mcp]. MCP = estándar abierto para conectar Claude a tools/datos externos.
**Añadir servidores:**
```bash
claude mcp add --transport http notion https://mcp.notion.com/mcp
claude mcp add --transport http secure https://api.example.com/mcp --header "Authorization: Bearer TOK"
claude mcp add --transport sse asana https://mcp.asana.com/sse        # SSE deprecado
claude mcp add --env KEY=val --transport stdio airtable -- npx -y airtable-mcp-server   # OJO al `--`
claude mcp add-json events '{"type":"ws","url":"wss://…","headers":{...}}'
claude mcp list | get <n> | remove <n> | login/logout <n>
```
- **Transports:** `http` (recomendado; alias `streamable-http`; soporta OAuth), `sse` (deprecado), `stdio` (proceso local; recibe `CLAUDE_PROJECT_DIR`), `ws` (bidireccional, solo header-auth).
- **Un `url` sin `type` = error** (se lee como stdio) → añade `"type":"http"`.
- **Scopes / archivos:** `.mcp.json` (proyecto, viaja por git; requiere trust del workspace para aprobar), `~/.claude.json` (local/usuario). Aprobación: `enableAllProjectMcpServers`, `enabledMcpjsonServers[]`, `disabledMcpjsonServers[]`.
- **Flags:** `--mcp-config <archivo|json>`, `--strict-mcp-config` (ignora todos los demás). `--bare` no carga MCP.
- **Tools nombradas `mcp__<server>__<tool>`**; tool-search difiere las defs por defecto (solo nombres entran al contexto). Nombres reservados: `workspace`, `claude-in-chrome`, `computer-use`, `Claude Preview`, `Claude Browser`.

---

## 11. Sesiones y transcripts

Fuente: [sessions]. Una sesión = conversación atada a un directorio de proyecto, guardada continuamente.
- **Ubicación:** `~/.claude/projects/<project>/<session-id>.jsonl` — `<project>` = ruta del cwd con no-alfanuméricos → `-` (el "slug"). Cada línea = 1 objeto JSON (mensaje / tool use / metadata). **Formato interno, cambia entre versiones** → no parsear a mano para producción (usa `/export` o las interfaces de script). El widget SÍ lo parsea con grep/awk para stats locales (aceptando la fragilidad).
- **Reanudar:** `claude --continue` (más reciente del cwd), `claude --resume` (picker), `claude --resume <id|nombre>` (scope = repo + worktrees), `claude --from-pr <n>`, `/resume` (dentro). Sesiones de `claude -p`/SDK no salen en el picker pero se reanudan por ID.
- **Nombrar:** `claude -n <name>`, `/rename`, `Ctrl+R` en el picker. Sin nombre, se genera un título (Haiku) que NO es handle de reanudación.
- **Branch/fork:** `/branch [name]` (copia la conversación y cambia a ella); CLI: `--continue/--resume --fork-session` (nuevo session id). 
- **Limpieza:** `cleanupPeriodDays` (default 30). `--no-session-persistence` (una corrida), `CLAUDE_CODE_SKIP_PROMPT_HISTORY` (todo), `CLAUDE_CONFIG_DIR` (mueve el store). `claude project purge` borra todo el estado local.
- **Export:** `/export [file]` (texto legible); para scripts: `claude -p --output-format json`, `transcript_path` en hooks/statusline.

---

## 12. Compactación y contexto

Fuente: [context-window], [sessions], [costs].
- **`/compact [instrucciones]`:** reemplaza el historial por un resumen (+ últimos intercambios + hasta 5 archivos leídos). `/clear` arranca vacío (cuesta 0). `/context` muestra qué consume contexto.
- **Auto-compact:** al acercarse al límite. `autoCompactEnabled`, `autoCompactWindow` (100k–1M), `--autocompact <auto|tokens>`, `DISABLE_AUTO_COMPACT`.
- **Instrucciones de compactación** en CLAUDE.md bajo `# Compact instructions` (el CLI re-lee el CLAUDE.md al compactar y busca ese heading H1).
- **Qué sobrevive:** el CLAUDE.md de root se re-lee de disco tras `/compact`; nested/`paths:` recargan al tocar archivos; lo dicho solo en chat se pierde.
- **Por qué sube el uso en sesiones largas:** long context (se manda toda la conversación cada request), cache misses (>1h en suscripción, 5min en créditos/API), scheduled tasks, teammates, la propia compactación.

---

## 13. Claude.app (app de escritorio)

Fuente: [desktop], [overview]. App standalone (macOS universal, Windows x64/ARM64, Linux beta apt/.deb). Tres pestañas: **Chat**, **Cowork** (Dispatch/agentic largo), **Code** (desarrollo). Requiere **subscripción de pago** (claude.ai).
- **Auth:** sign-in con tu cuenta **claude.ai** (OAuth de suscripción) — la misma bolsa que el CLI/chat. En Windows necesita Git for Windows.
- **Mismo motor y config que el CLI:** cada superficie conecta al MISMO engine de Claude Code, así que tus `CLAUDE.md`, settings y MCP servers funcionan en todas. [overview]
- **Diferencias vs CLI:** UI visual — sesiones en paralelo con aislamiento git, revisión visual de diffs, editor/terminal integrados, preview del app, monitoreo de PRs, side chats, computer use, Dispatch desde el teléfono, tareas programadas locales.
- **Handoff:** `/desktop` (alias `/app`) continúa la sesión de terminal en la app (requiere subscripción claude.ai; mac + Windows x64). Cada superficie mantiene su propio historial de sesiones.
- **Dato para el widget:** la app cachea sus conversaciones en un **IndexedDB local** (Snappy + V8) que `chats-extract.js` lee sin red ni cookies (`cortex-fetch:495-505`). El CLI y la app **comparten el mismo slot de credencial** de la máquina (ver §16).

---

## 14. La API de pago (ANTHROPIC_API_KEY / Console) vs la suscripción

Fuente: [costs], [headless]. **Son bolsas/cuentas DISTINTAS.** No se mezclan.

| | Suscripción Claude (Pro/Max/Team/Enterprise) | API de pago (Claude Console / Platform) |
|---|---|---|
| Cómo se autentica el CLI | OAuth (`/login`, keychain/`.credentials.json`, o `CLAUDE_CODE_OAUTH_TOKEN`) | `ANTHROPIC_API_KEY` (o `apiKeyHelper`) |
| Modelo de cobro | Incluido en el plan; **ventanas** de uso (5h + semanal), por asiento | **Pago por token** (input/output/cache), facturado al workspace |
| Dónde se ve el gasto | `/usage` (barras del plan) + claude.ai | Console `platform.claude.com/usage` |
| Precios | `claude.com/pricing` (plan mensual) | `platform.claude.com/pricing` (tarifas por token) — **exactas: ver esa página (hueco aquí)** |
| Límites | ventana rodante 5h + ventana semanal, compartidas entre modelos y con chat/Cowork | rate limits (TPM/RPM) del workspace |

- **Cuándo el CLI usa cada una:** con login OAuth activo → suscripción. Con `ANTHROPIC_API_KEY` seteado → puede saltar el login y usar la API (te pide aprobar la key). **`--bare` fuerza la vía API key** (no lee OAuth). Cloud providers (Bedrock/Vertex/Foundry) usan sus propias credenciales y facturan al cloud.
- Al autenticar el CLI con Console se crea un workspace "Claude Code" (no puedes crear API keys ahí; es solo para el CLI). El tráfico cuenta contra los rate limits de la org.
- **La suscripción NO comparte bolsa con la API:** cada dev se mide según el método con el que se autenticó. `/usage` (bloque Session) muestra $ de tokens **solo relevante para usuarios de API**; los suscriptores lo ignoran (su uso va contra el plan).

---

## 15. 🎯 La WebAPI interna de USO/CUOTA (fuente del widget)

**No documentada oficialmente.** Verdad = el código del widget, que ya la consume en producción. Rutas: `~/.cortex/macos/bin/cortex-fetch` (mac), `~/.cortex/src/bin/cortex-fetch` (Linux), modelo Swift `~/.cortex/macos/Sources/Cortex/QuotaModel.swift`.

### Endpoint
```
GET https://api.anthropic.com/api/oauth/usage
  Authorization: Bearer <accessToken>
  anthropic-beta: oauth-2025-04-20
```
- macOS: `cortex-fetch:121-123`; Linux: `src/bin/cortex-fetch:103-105`.
- Es "los mismos datos que `/usage` muestra dentro de Claude Code", leídos con el token OAuth que Claude Code ya guarda (cabecera del script, líneas 2-8).
- Sanity check: la respuesta debe traer `.five_hour.utilization != null` (`cortex-fetch:125`).

### De dónde sale el token (orden de preferencia)
Función `oauth_token()` (`cortex-fetch:77-96`):
1. **macOS Keychain:** `security find-generic-password -s "Claude Code-credentials" -w` → JSON con `.claudeAiOauth.accessToken` (`:82`, `:88`).
2. **Archivo:** `$CLAUDE_CONFIG_DIR/.credentials.json` o `~/.claude/.credentials.json`, mismo path JSON `.claudeAiOauth.accessToken` (`:83-85`, `:88`). (En Linux es la fuente primaria: `src/bin/cortex-fetch:66-73`.)
3. **Fallback headless:** env `CLAUDE_CODE_OAUTH_TOKEN` (token de larga vida de `claude setup-token`), SOLO si no hay login local (`:91-94`).
- Se prefiere el **login activo** para reflejar la cuenta con la que estás logueado AHORA (el token rota en cada `login`/`logout`).
- Email/UUID de la cuenta **no** están en el token: se leen de `~/.claude.json` (`.oauthAccount.emailAddress`, `.oauthAccount.accountUuid`) — `:102`, `:105`. La ruta de `.claude.json` honra `CLAUDE_CONFIG_DIR` (`:41-45`).

### Forma de la respuesta (campos que el widget consume)
Del `jq` en `cortex-fetch:186-279` y los structs Swift en `QuotaModel.swift:5-57`:
- **`.five_hour`** — ventana de 5 horas: `.utilization` (0–100, %), `.resets_at` (ISO; el script normaliza fracciones/`+00:00`→`Z`). (`:212-213`, `:220`)
- **`.seven_day`** — ventana **semanal** (7 días): `.utilization`, `.resets_at`. (`:214-215`, `:224`)
- **`.limits[]`** — límites acotados en el tiempo (solo en modo oauth). Cada uno: `.kind` (`session` | `weekly_all` | `weekly_scoped`), `.scope.model.display_name` (nombre del modelo, solo en `weekly_scoped`), `.percent`, `.resets_at`, `.severity`, `.is_active`. (`:255-264`; struct `LimitEntry` `QuotaModel.swift:16-23`). El widget renderiza dinámicamente los `weekly_scoped` con modelo (`QuotaModel.swift:406-408`).
- **`.spend`** — **gasto REAL de bolsillo (dinero)**: `.used.amount_minor` / `.used.exponent` / `.used.currency`, `.limit.{amount_minor,exponent,currency}`, `.percent`, `.enabled`. El widget normaliza `amount_minor / 10^exponent` (`:265-271`; struct `Spend` `QuotaModel.swift:26-32`).
- **`.extra_usage`** — **overage / créditos de sobreuso**: `.used_credits`, `.monthly_limit`, `.currency`, `.utilization`, `.is_enabled`. (`:272-278`; struct `ExtraUsage` `QuotaModel.swift:35-41`).

### Cómo lo materializa el widget
- Snapshot normalizado → `~/Library/Caches/cortex/state.json` (mac) / `~/.cache/cortex/state.json` (Linux). Campos: `basis` (`"oauth"` datos reales | `"cost"` estimado local), `status` (`ok|warn|crit` por umbrales `WARN_PCT`/`CRIT_PCT`), `five_hour`, `weekly`, `limits`, `spend`, `extra_usage`, `account_email/uuid`, `account_mismatch` (`cortex-fetch:227-279`, struct `Snapshot` `QuotaModel.swift:44-57`).
- **Fallback sin OAuth:** estima por costo con `ccusage` (constantes `FIVE_HOUR_CAP_USD`/`WEEKLY_CAP_USD`, `:33-34`). En ese modo NO hay `limits`/`spend`/`extra_usage`.
- Stats locales (por día/modelo/proyecto, sesiones, mensajes, hora pico) → `stats.json`, parseando `~/.claude/projects/**/*.jsonl` con grep/awk (dedup por `msg_id`). Chats de la app → `chats.json`; sesiones → `sessions.json`.
- **Guard de identidad:** como el CLI y Claude.app comparten un solo slot de credencial, un re-login puede cambiar de cuenta en silencio → `account_mismatch` avisa si la cuenta activa ≠ la fijada en `~/.config/cortex/account` (`:107-117`).

---

## 16. OAuth de suscripción: flujo, token, alcance de máquina

Fuente: [overview], [headless], + código del widget.
- **Login:** `/login` (interactivo), `claude auth login` (`--console` para Console), `claude auth status` (JSON). En primer uso te pide loguearte; si `ANTHROPIC_API_KEY` está seteada, salta el login y pide aprobar la key.
- **CI / headless conservando suscripción:** `claude setup-token` genera un **token OAuth de larga vida** → exportar `CLAUDE_CODE_OAUTH_TOKEN`.
- **Dónde vive el token:**
  - **macOS:** Keychain, item genérico `"Claude Code-credentials"` (JSON con `.claudeAiOauth.accessToken`).
  - **Linux (y fallback mac):** `~/.claude/.credentials.json` (o `$CLAUDE_CONFIG_DIR/.credentials.json`), JSON `.claudeAiOauth.accessToken`.
  - El token **rota** en cada `login`/`logout`.
- **El login es GLOBAL a la máquina:** un solo credential store, **no** por-terminal. **El CLI y Claude.app comparten ese slot** → un re-login en una superficie cambia la identidad para todas (documentado en el código del widget, `cortex-fetch:109-110`, `src/bin/cortex-fetch:91-92`).
- **Cuenta (email/uuid):** en `~/.claude.json` → `.oauthAccount.emailAddress` / `.accountUuid` (no en el token).
- **Diferencia con API key:** OAuth = entitlement de suscripción (bolsa del plan, ventanas 5h/semanal). `ANTHROPIC_API_KEY` = facturación por token vía Console (otra bolsa). `--bare` ignora OAuth y exige API key.
- **Refresh / expiración del access token:** el `.credentials.json` normalmente trae también refresh token y expiry, pero la **mecánica exacta de refresh no está documentada oficialmente** → [hueco](#18-huecos-lo-que-la-doc-oficial-no-responde).

---

## 17. Interrelación: qué superficie usa qué auth / qué bolsa

| Superficie | Auth | Bolsa de cuota | Límites que aplican |
|---|---|---|---|
| CLI `claude` (login normal) | OAuth suscripción (keychain/`.credentials.json`) | Plan Pro/Max/Team/Enterprise | Ventana **5h** + **semanal** (compartidas entre modelos y con chat/Cowork) |
| CLI `claude -p` (login normal) | OAuth suscripción | Plan | 5h + semanal |
| CLI `claude -p --bare` | **API key** (`ANTHROPIC_API_KEY`/`apiKeyHelper`) | API de pago (Console) | Rate limits TPM/RPM del workspace |
| CLI + `CLAUDE_CODE_OAUTH_TOKEN` | OAuth suscripción (token largo) | Plan | 5h + semanal |
| CLI con `ANTHROPIC_API_KEY` (sin `--bare`) | API key | API de pago | Rate limits del workspace |
| CLI en Bedrock/Vertex/Foundry | Credenciales del cloud | Cuenta cloud (por token) | Budget/limits del cloud |
| Claude.app (Code) | OAuth suscripción (mismo slot que el CLI) | Plan | 5h + semanal |
| Claude Code web / mobile | claude.ai (suscripción) | Plan | 5h + semanal |
| **Widget cortex** | Reusa el OAuth del CLI (keychain/archivo) o `CLAUDE_CODE_OAUTH_TOKEN`; fallback ccusage | Lee la bolsa del plan vía `api/oauth/usage`; fallback = estimación por costo local | Reporta 5h (`.five_hour`) + semanal (`.seven_day`) + limits por modelo + spend + overage |

Claves:
- **Suscripción y API de pago son bolsas separadas.** Un dev se mide según cómo se autenticó.
- Las ventanas de suscripción son **5 horas (rodante)** y **semanal**; compartidas entre modelos → cambiar de modelo con `/model` no restaura acceso (salvo el mensaje model-specific tipo "hit your Opus limit").
- El widget es fiel a la superficie con la que estás logueado AHORA porque lee el mismo token OAuth activo del CLI.

---

## 18. Huecos: lo que la doc oficial NO responde

1. **Flag "rápido + OAuth" inexistente.** No hay un flag documentado que reduzca el cold-start como `--bare` **y** conserve el OAuth de suscripción: `--bare` explícitamente desactiva OAuth (exige API key). El camino OAuth-headless es `CLAUDE_CODE_OAUTH_TOKEN` o `claude -p` normal con recortes manuales (`--strict-mcp-config`, `--setting-sources`, `--no-session-persistence`). El impacto real de esos recortes en el arranque no está cuantificado en la doc.
2. **La WebAPI `api/oauth/usage` NO está en la doc oficial.** Todo lo de §15 sale del código del widget (que funciona), no de docs. El esquema completo del endpoint (todos los campos posibles, versionado del `anthropic-beta: oauth-2025-04-20`, estabilidad) no está publicado → puede cambiar sin aviso.
3. **Refresh del token OAuth.** La doc no detalla la mecánica de refresh/expiración del access token en `.credentials.json` (refresh token, TTL, rotación automática).
4. **Formato interno del `.jsonl` de transcripts.** La doc dice explícitamente que es interno y **cambia entre versiones**; no publica el esquema (el widget lo parsea a su propio riesgo).
5. **Tarifas exactas por token de la API.** La doc de costos remite a `platform.claude.com/pricing` y `claude.com/pricing`; no fija números → no se transcriben aquí para no mentir.
6. **Límites numéricos de las ventanas 5h/semanal por plan.** La doc describe las ventanas (rodante 5h + semanal, por asiento) pero no publica los cupos exactos por plan (el widget los calibra con `*_CAP_USD` solo para el modo fallback por costo).
7. **settings.json de fuentes mixtas.** Algunas claves listadas (p. ej. estructura fina de `sandbox`, `statusLine`) están resumidas; el esquema JSON canónico vive en `https://json.schemastore.org/claude-code-settings.json`.

---

### Apéndice: mapa de fuentes citadas
- Docs oficiales (todas bajo `https://code.claude.com/docs/en/`): `overview`, `cli-reference`, `headless`, `sub-agents`, `hooks`, `settings`, `memory`, `sessions`, `mcp`, `skills`, `commands`, `costs`, `desktop`, `context-window`, `env-vars`, `permission-modes`, `agent-sdk/overview`. Índice: `https://code.claude.com/docs/llms.txt`.
- Código del widget (fuente de la WebAPI interna): `/Users/unjordi/.cortex/macos/bin/cortex-fetch`, `/Users/unjordi/.cortex/src/bin/cortex-fetch`, `/Users/unjordi/.cortex/macos/Sources/Cortex/QuotaModel.swift`.


---

## KB viva — hallazgos de campo (fechados)

> Fundido de la ex-memoria `ecosistema-claude.md` (2026-08-28): gotchas operativos con evidencia+fecha.
> Complementa las secciones de arriba; algún ítem (OAuth a la API) también se toca en §14.
# Conocimiento del ecosistema Claude (KB viva)

> Base de conocimiento que **CRECE**: cada cosa no-obvia que descubrimos sobre cómo se comporta
> Claude Code (CLI), Claude chat/desktop, la API, hooks, cuotas y sesiones — sobre todo lo destilado
> al construir el **cortex**. Un ítem = un hallazgo, con su **evidencia + fecha**. Añade abajo.

## Autenticación / cuentas
- **La Messages API de `api.anthropic.com` ACEPTA el token OAuth de la suscripción** (el mismo login de
  Claude Code, no una API key) enviándolo como `Authorization: Bearer <oauth>` **+ el header
  `anthropic-beta: oauth-2025-04-20`** — así puedes hacer `curl` directo al modelo (p. ej. un juez LLM)
  con tu cuota de suscripción, sin API key aparte. Referencia completa del ecosistema Claude (CLI / OAuth /
  `curl` al juez): **`docs/referencia-cli-claude-code.md`**.
- **El login de Claude Code es GLOBAL a la máquina** — un solo credential store en `~/.claude/`, **NO
  por-terminal ni por-sesión.** Consecuencia clave: si haces logout/login a OTRA cuenta (aunque sea en
  otra terminal), **las sesiones ya vivas toman la credencial/cuota nueva en sus SIGUIENTES requests** —
  el switch es **transparente para la sesión en curso** (no hay que resumear en otra terminal). Truco
  práctico: al toparte el límite de una cuenta, cambiar a una 2ª cuenta deja **seguir la MISMA sesión**
  sin overage. Prueba lógica de que el switch ya aplicó: si la cuenta vieja estuviera topada sin overage,
  Claude **no podría responder** — que responda demuestra que ya está sobre la cuota fresca.
  *(2026-07-15, verificado en vivo.)*

## Cuotas / límites
- **El mensaje "claude-opus-4-8 temporarily unavailable — auto mode cannot determine safety of Bash" NO
  significa que Bash esté roto:** significa que **se agotó un quota de tokens** (el clasificador de
  seguridad de Bash es una llamada al modelo que no puede correr sin cuota). **Read/Edit/Write siguen
  funcionando** (no pasan por el clasificador); solo **Bash** queda bloqueado, hasta el reset O hasta
  cambiar de cuenta / habilitar overage. Confirmación rápida: el widget cortex muestra el semanal
  y/o la ventana de 5h al 100%. *(2026-07-15.)*
- Hay dos ventanas **independientes**: **5 h** y **semanal (7 d)**. El widget las muestra por separado
  (+ desglose por modelo). Toparse la semanal no topa necesariamente la de 5h y viceversa.

## Compactación / contexto
- **`PreCompact` NO puede inyectar `additionalContext`** — el CLI rechaza el JSON con "Hook JSON output
  validation failed — (root): Invalid input". Solo `Stop`/`SubagentStop`/`UserPromptSubmit`/`PostToolUse`
  aceptan `additionalContext`. Por eso el hook `precompact-volcar-estado` fue **RETIRADO**; el "no perder
  el HILO al compactar" lo hacen el skill `checkpoint` (ESCRIBE el hilo antes) + el hook `rehidratar-hilo`
  en **SessionStart** (LEE el hilo al retomar — canal FIABLE). *(Confirmado de nuevo en cps 2026-07-15:
  un repo con el hook viejo aún cableado tiraba ese error en cada `/compact`; era ruido, no rotura — el
  compact ocurría y el hilo rehidrataba igual.)*
- Tras compactar, el harness ordena **retomar en SILENCIO** (sin recap ni "continúo") — es feature, no
  bug; el anuncio visible solo aplica si el usuario invoca el skill `rehidratar-hilo` a mano.

## Sesiones
- Los transcripts viven en `~/.claude/projects/<slug>/<id>.jsonl` — **por-máquina, NO en el repo**
  (gitignored: pesan MBs y traen datos sensibles). El **slug se DERIVA del cwd** (ruta con `/`→`-`).
- **Resumear una sesión en otra máquina** = sembrar su `.jsonl` en el slug del destino (derivado del
  cwd LOCAL, que suele diferir: `/Users/…`≠`/home/…`≠`C:\…`) **con el `cwd` interno reescrito** + `claude
  --resume <id>`. El slug NO vive dentro del jsonl (solo es el nombre del dir); el `cwd` sí, en muchas
  líneas → por eso hay que reescribirlo, no basta re-sluggear.
- **Sync cross-máquina de sesiones = CONSTRUIDO** (2026-07-23, verificado técnicamente; wiring de release
  en curso). `bin/session-export.js` (gzip la sesión a `<repo>/.claude/sessions/<id>.jsonl.gz`+meta, opt-in)
  + `bin/session-import.js` (siembra en el slug local reescribiendo cwd + restaura alias, idempotente) +
  wrapper `bin/claude-session` (gestiona la **rama de transporte orphan `sesiones/<usuario>`**, que jamás
  se mergea → no toca develop/clones). Helpers compartidos en `bin/session-lib.js` (fuente única, la
  consume también `session-move.js`). Diseño+decisiones+evidencia: `diseno-sync-sesiones.md`.
- **NO hay `claude compact` headless** (v2.1.218): un hook no puede DISPARAR compactación, solo
  reaccionar. `SessionEnd`/`PreCompact`/`PostCompact` reciben `transcript_path`+`cwd`+`session_id` (útiles
  para exportar/archivar, no para adelgazar). El CLI nuevo ya escribe `custom-title`/`ai-title` DENTRO del
  jsonl (antes se derivaban a mano en `sessions-extract.js`).

## Gotcha: una versión del CLI `claude` puede SEGFAULTEAR al arrancar → rollback por symlink
Incidente 2026-08-25 (Cachy/CachyOS, glibc 2.44 rolling): `claude` no abría (ni `--resume`) en NINGÚN
master. Causa: el auto-update instaló **v2.1.243**, que **segfaultea** (`claude --version` → exit **139**);
la previa **2.1.241** corría perfecto. Sin libs faltantes (`ldd` limpio) → build malo / incompat con glibc
bleeding-edge, no config ni PATH. **Diagnóstico:** el CLI nativo vive en `~/.local/share/claude/versions/<v>`
con un symlink `~/.local/bin/claude`→`versions/<actual>`; correr cada versión directo (`versions/2.1.241 --version`)
aísla cuál está rota. **Fix (rollback):** `ln -sfn ~/.local/share/claude/versions/2.1.241 ~/.local/bin/claude`.
**Caveat:** el instalador nativo auto-actualiza a la ÚLTIMA al arrancar → si "latest" sigue rota, re-rompe;
mitigación: dejar la terminal ABIERTA (la sesión viva ya corre en memoria con la buena) hasta que salga una
versión > la rota, o pinear. NO es de config/entorno → aplica en cualquier máquina, no solo la Cachy.
