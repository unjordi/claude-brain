# Candidatos para integrar — sesión 2026-07-21 (pkexec + git-SSH + experiencia-vivida)

> **Qué es esto:** material de una sesión real (proyecto powerscripts) que salió al **cerebro de
> máquina** de unjordi (`~/.claude`) y que Jordi quiere **revisar aquí** para decidir cómo integrarlo
> a los mecanismos/flowcharts de claude-brain. **Ya está VIVO** en su máquina (hook cableado + memorias
> escritas); esta carpeta es una COPIA para revisión, no la instalación. No está cableado al `MANIFEST`
> ni a `test-brain.sh` a propósito (para no forzar decisiones antes de tu revisión).

## De dónde salió (el incidente)
Sesión de ~1h de fricción dando acceso web a la VM Windows. Tres tropiezos, todos por lo mismo:
una regla **ya estaba en el CLAUDE.md/memoria pero no se activó en el momento** (falla de saliencia,
no de memoria — el texto estaba en contexto, pero nada lo ató al disparador). De ahí, tres remedios.

## Archivos

### 1. `usar-pkexec-y-git-ssh.sh` (+ `test-usar-pkexec-y-git-ssh.sh`)
Hook que DISPARA en el instante dos reglas de máquina que se olvidaban:
- **PreToolUse/Bash:** comando con `sudo` → **deny** + "usa `pkexec` tú mismo" (en CachyOS/KDE sin TTY
  sudo cuelga; pkexec saca el diálogo KDE = confirmación del usuario).
- **PostToolUse/Bash:** si el comando fue `git|gh|glab` **y** la salida trae la firma de
  `ksshaskpass`/password-HTTPS → **nudge** "cambia el remote a SSH".
- Detección por posición de comando (no dispara sobre menciones entre comillas ni sobre salidas que
  solo mencionan las cadenas). Test incluido: **10/10**.

### 2. Memorias (candidatas a norma / o a quedarse como instancia)
- `usar-pkexec-para-root.md` — Claude corre `pkexec` él mismo; NO sudo, NO pasárselo al usuario, NO
  tratar "necesito root" como bloqueo.
- `git-remoto-ssh-nunca-askpass.md` — el diálogo ksshaskpass de HTTPS no sirve en sesiones de Claude;
  remote a SSH.
- `feedback-experiencia-vivida-gana.md` — si el usuario dice que algo NO funciona, deja de ofrecerlo
  aunque mi prueba dé 200; su experiencia gana (verde técnico ≠ que le sirva).

## ⚠️ Caveat de OS (decisión tuya al integrar)
claude-brain es **OS-agnóstico** (los hooks corren bajo bash en Mac/Linux/Windows Git Bash). El hook
de **pkexec es específico de CachyOS/KDE** — `pkexec`/el diálogo de KDE no existen igual en Mac/Windows.
Opciones a decidir:
- (a) darle un **tier nuevo** en `MANIFEST` tipo `linux-kde`/`maquina` que solo se instale en esa máquina;
- (b) generalizar el hook a "escalada de privilegios del SO" (pkexec en KDE, `sudo -A`/askpass gráfico
  en otros) — más ambicioso;
- (c) dejarlo como **instancia** (solo en el `~/.claude` de unjordi, fuera del template) y subir a
  claude-brain **solo** la parte genérica: el patrón "regla-pasiva-en-CLAUDE.md que no se activa →
  conviértela en hook de disparo", que sí es OS-agnóstico.
- La regla `git-SSH` y la de `experiencia-vivida` son **más portables** (git es multiplataforma; la
  segunda es puro comportamiento) → candidatas más limpias a norma genérica.

## Checklist de integración (si decides subir algo al template)
1. Hook → `brain/hooks/<nombre>.sh` (fail-open, dedupe si es `both`).
2. `brain/hooks/MANIFEST`: línea `<nombre> <tier> hook` (elegir tier según el caveat de OS).
3. Cableado en settings.json: lo deriva `install-brain.sh` del MANIFEST — verifícalo (Pre y PostToolUse/Bash).
4. `brain/test-brain.sh`: agregar el caso del hook (o traer el test de aquí) + que el drift-check (e2) siga verde.
5. Normas → `brain/norms/global-claude-md.md` si alguna sube a norma dura, con su "mecanismo" (este hook).
6. Flowchart/doc en `docs/` del mecanismo "regla pasiva → hook de saliencia", si aplica.
