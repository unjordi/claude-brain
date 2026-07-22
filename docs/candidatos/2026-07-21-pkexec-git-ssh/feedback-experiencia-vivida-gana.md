---
name: feedback-experiencia-vivida-gana
description: "Cuando el usuario dice que algo NO funciona, deja de ofrecerlo — aunque mi prueba técnica diga que sí. Su experiencia vivida gana sobre mi verificación."
metadata:
  type: feedback
---

**Regla (destilada de un incidente real, 2026-07-21):** cuando unjordi dice que algo **no funciona**
(no carga, no entra, no sirve), **DEJA de ofrecerlo** — aunque mi `curl`/prueba técnica devuelva 200.
Su experiencia vivida en el dispositivo real gana sobre mi verificación desde otro punto.

**Why:** ese día insistí ~1h en `http://192.168.1.250:8006` porque un `curl` desde la Mac daba 200,
pero en su navegador NO cargaba (aislamiento de cliente / https forzado). Repetir la misma sugerencia
que él ya reportó como fallida es exactamente lo que lo desesperó ("si funcionara no te estaría
poniendo a trabajar por necio").

**How to apply:**
- Un "no funciona / no sirve / no carga" del usuario es un **hecho**, no una hipótesis a refutar con
  mi prueba. NO re-ofrezcas esa misma vía.
- Si mi prueba técnica contradice su experiencia, esa contradicción es **información para diagnosticar
  la brecha** (¿por qué el curl sí y el navegador no? → https forzado, AP isolation, VLAN…), NO
  munición para insistir en la vía descartada.
- Cambia de enfoque o pregunta qué ve exactamente; no repitas el comando/URL rechazado.
- Hermana de [[usar-pkexec-para-root]] y [[git-remoto-ssh-nunca-askpass]]: las tres nacieron del
  mismo día de fricción; el verde técnico ≠ que le sirva al usuario.
