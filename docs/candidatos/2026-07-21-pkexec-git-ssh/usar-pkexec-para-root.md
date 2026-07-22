---
name: usar-pkexec-para-root
description: "En esta máquina (CachyOS/KDE) Claude ejecuta acciones root con pkexec ÉL MISMO (saca diálogo KDE que Jordi autoriza); NO pedirle a Jordi que las corra, NO tratar 'necesito root' como bloqueo, NO usar sudo"
metadata:
  type: feedback
---

**Regla (Jordi, reforzada 2026-07-21 con molestia — se me olvida seguido):** cuando una acción en
esta máquina necesita root y no hay TTY (el shell de Claude Code), **Claude corre `pkexec <cmd>` él
mismo**. `pkexec` saca un **diálogo gráfico de KDE** donde Jordi autoriza — ESA es la confirmación.

**Why:** Jordi ni conocía `pkexec` hasta que se lo enseñé; que yo "olvide" usarlo y en su lugar le
pida *"córrelo tú con `!`"* o trate "necesito root" como un muro es justo lo que lo desespera. El
mecanismo existe y es de un paso. Está también en `~/.claude/CLAUDE.md` (sección "Root sin TTY").

**How to apply:**
- Acción root (firewall `ufw`, leer `/etc/letsencrypt`, systemd de sistema, montar, etc.) →
  `pkexec sh -c '…'` directo, en el mismo turno. No la delego a Jordi ni la pospongo.
- **NO `sudo`** (sin TTY cuelga/falla). **NO** decir "necesito permiso" y parar: uso pkexec.
- ⚠️ `pkexec` **no** tiene `--noconfirm` (lo interpreta como el programa a correr y falla con
  "No such file or directory"); el diálogo de KDE ES la confirmación.
- Si el **clasificador auto-mode** bloquea el comando (p. ej. barrer llaves privadas por todo el
  home = parece cosecha de credenciales), eso es OTRA cosa: ahí sí explico y dejo decidir a Jordi
  o acoto el comando — pero para "solo necesito root", pkexec es la respuesta, no un bloqueo.
- Excepción viva: el diálogo `ksshaskpass` de git NO sirve en sesiones de Claude → ver
  [[git-remoto-ssh-nunca-askpass]] (eso se arregla con remote SSH, no con pkexec).
