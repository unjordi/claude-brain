---
name: diseno-sync-sesiones
description: Motor GENÉRICO del brain para mover una sesión/transcript de Claude Code entre máquinas y poder `claude --resume` en otra compu (reescribe el cwd al slug local). Herramientas en bin/. El CANAL de transporte (rama git, carpeta sincronizada tipo Drive/NAS, scp) y QUÉ sesiones viajan son elección PERSONAL de cada quien — no viven aquí. Motor verificado y liberado a main 2026-07.
metadata:
  type: reference
---

# Mover una sesión de Claude Code entre máquinas (`claude --resume` cross-máquina)

Motor **genérico** del brain para **sembrar en otra máquina una sesión iniciada aquí** y poder retomarla
con `claude --resume`. Liberado a main (MR #182→develop, release #183→main, 2026-07). `bin/claude-session`
+ los `session-*.js` se despliegan a `~/.local/bin/` por los instaladores.

> **Este doc es SOLO el motor genérico.** *Qué* sesiones sincronizas, por *qué canal* (una rama de
> transporte git, una carpeta sincronizada tipo Drive/NAS, scp…) y con qué automatización es una
> **preferencia PERSONAL** de cada dev → NO vive en el brain compartido; va en tu memoria personal / la
> doc de tu propio setup. El brain solo aporta las herramientas.

## El problema (verificado leyendo el CLI, no hipótesis)
- Cada sesión es UN archivo `~/.claude/projects/<slug>/<sessionId>.jsonl`. El `<slug>` se DERIVA del
  cwd absoluto (cada char no-alfanumérico → `-`). **El slug NO vive dentro del jsonl** (solo es el
  nombre del dir); el `cwd` SÍ está en muchas líneas.
- `claude --resume <id>` busca en el slug del **cwd actual**. En otra máquina el repo/carpeta vive en
  otra ruta (`/Users/…` Mac vs `/home/…` Linux vs `C:\…` Win) → **slug distinto + cwd interno equivocado**.
  Un copy crudo NO basta: hay que re-sluggear + reescribir el cwd de cada línea. Eso es lo que hace el motor.
- No hay `claude compact` headless (confirmado): un hook NO puede disparar compactación, solo reaccionar.
  `SessionEnd`/`PreCompact`/`PostCompact` reciben `transcript_path`+`cwd`+`session_id` → sirven para
  EXPORTAR automático, no para adelgazar. (Por eso el adelgazado disponible = gzip, no compact.)
- Los transcripts pesan **decenas–cientos de MB** y pueden traer **datos sensibles** (log completo,
  posibles secretos pegados). De ahí que se compriman (gzip) y que el canal/alcance sea decisión de cada quien.

## El motor (bin/ del brain — genérico)
- **`session-lib.js`** — helpers COMPARTIDOS (fuente única, no divergir): `slugFromCwd`, `findSession`,
  `rewriteCwd`, `firstCwd`, `titleFromTranscript` (lee el `customTitle`/`ai-title` del jsonl — OJO: hay
  uno por cada `/rename`, el vigente es el ÚLTIMO), `sessionAliases`/`writeAlias`. `session-move.js` la consume.
- **`session-export.js <id> --repo <ruta> [--name "…"] [--force]`** — localiza el jsonl, lo **gzip**ea a
  `<ruta>/.claude/sessions/<id>.jsonl.gz` + sidecar `<id>.meta.json` (origen cwd/slug/máquina/título/
  tamaños/fecha). NO toca git. Idempotente (pide `--force` para re-embarcar).
- **`session-import.js --repo <ruta-destino> [--sessions-dir <dir-con-.gz>] [--only <id>] [--force] [--dry-run]`**
  — por cada `.jsonl.gz`: gunzip → **reescribe el cwd al del `--repo` LOCAL** → escribe
  `~/.claude/projects/<slug-local>/<id>.jsonl` → restaura el alias del meta. Idempotente. Clave: `--repo`
  (para qué carpeta se deriva el slug/cwd) se separa de `--sessions-dir` (de dónde se leen los `.gz`) →
  el payload puede venir de cualquier canal.
- **`session-move.js`** — mueve una sesión entre slugs en la MISMA máquina (lo usa la GUI del widget).
- **`claude-session export|import|list`** — wrapper que implementa UN canal concreto: una **rama de
  transporte git orphan `sesiones/<usuario>`** (jamás se mergea → no contamina develop/clones). Es una
  opción lista para usar; otros canales usan los primitivos de arriba directamente.

### Verificación (home de juguete `CLAUDE_CONFIG_DIR`)
Export → import a un repo con **ruta distinta** → el import derivó el slug local, reescribió el cwd de
cada línea, quedó **idéntico byte a byte salvo el cwd**, restauró el alias, e idempotente (re-import salta).

## El CANAL de transporte es PERSONAL (no vive aquí)
El motor solo comprime y reescribe cwd. CÓMO viaja el `.gz` entre tus máquinas es tuyo:
- **Rama de transporte git orphan** — lo hace `claude-session` (útil si ya usas git entre las compus).
- **Carpeta sincronizada** (Google Drive / NAS / Syncthing) — suelta los `.gz` ahí y siembra con
  `session-import --sessions-dir <carpeta>`. Buena para blobs grandes (sin límite de 100 MB de GitHub).
- **scp/rsync directo** entre máquinas en LAN.
Ojo con secretos: los transcripts son el log completo. Si el canal es un repo compartido, un scanner de
secretos ayuda pero no garantiza. Tu configuración concreta (qué sesiones, qué canal, qué automatización
como un hook `SessionEnd`) va en TU doc personal, no en el brain.

## Herencia / multi-dev
Genérico (vive en el brain, viaja por bootstrap). Es transporte cross-MÁQUINA del **mismo** dev, NO
compartir sesiones entre devs. Complementa la cosecha semanal de `diseno-unificar-cerebro.md`: los
aprendizajes CURADOS van a `aprendizajes.md` (git-shared); esto mueve el CRUDO comprimido para retomar
la MISMA sesión en otra compu.
