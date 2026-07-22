---
name: git-remoto-ssh-nunca-askpass
description: "Git en esta máquina: remotes SIEMPRE por SSH; el diálogo ksshaskpass de HTTPS nunca sirve en sesiones de Claude (Jordi lo pidió explícito 2026-07-21)"
metadata:
  type: feedback
---

**Regla (Jordi, 2026-07-21):** en esta máquina, NO invocar el diálogo de
credenciales de git (`ksshaskpass`). Se dispara cuando un repo tiene remote
**HTTPS** y git pide password — en el shell no-interactivo de Claude ese diálogo
"nunca sirve" (falla con `unable to read askpass response`), aunque Jordi tenga
las creds en el wallet de KDE (eso le funciona a ÉL en interactivo, no a Claude).

**Why:** el askpass gráfico necesita la sesión/agente de KDE del usuario; los
comandos de Claude no la tienen. El SSH en cambio siempre funciona aquí
(`ssh -T git@github.com` → "Hi unjordi!").

**How to apply:**
- Si un `pull/push` truena con `unable to read askpass response from
  '/usr/bin/ksshaskpass'` o `could not read Password for 'https://…'` →
  el remote está en HTTPS. **Cambiarlo a SSH** y reintentar:
  `git remote set-url origin git@github.com:<owner>/<repo>.git`
  (mismo patrón para GitLab: `git@gitlab.com:…`).
- Al clonar para Claude, preferir la URL SSH de entrada.
- `gh`/`glab` no se ven afectados (usan su propio token).
- Caso real: `~/code/powerscripts` amaneció con remote HTTPS el 2026-07-21
  (era SSH; causa del cambio desconocida) → restaurado a SSH y todo fluyó.
