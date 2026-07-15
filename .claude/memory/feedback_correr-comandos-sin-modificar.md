---
name: feedback-correr-comandos-sin-modificar
description: "Al QAear un mecanismo documentado (instalador, comando del README), córrelo TAL CUAL, sin pre-optimizar con flags/env — verifica el estado real primero"
metadata:
  type: feedback
---

Al pedir "corre el comando normalito, el del README, sin moverle nada" para hacer QA de un mecanismo
(instalador, updater, cualquier one-liner documentado), **córrelo literal, sin agregar flags/env vars
por anticipado** aunque parezca una optimización razonable (evitar un clon duplicado, por ejemplo).

**Qué pasó (2026-07-15, claude-brain):** el README trae `curl …/bootstrap.sh | bash`, que por default
clona en `$HOME/claude-brain` (no en `~/code/claude-brain`, nuestro clon canónico). Para "no duplicar",
antepuse `export CLAUDE_BRAIN_DIR="$HOME/code/claude-brain"` sin verificar antes si ya existía algo en
el default — sí existía: un clon viejo en `$HOME/claude-brain` de una corrida anterior. Mi desvío del
comando literal no evitó ningún duplicado nuevo (ya estaba ahí) y en cambio disparó una cadena larga:
hubo que descubrir el clon viejo, diffearlo, revisar un archivo huérfano (`backlog-desarrollo.md`) para
no perder nada, decidir si borrarlo, etc. — trabajo que no habría existido si simplemente hubiera corrido
el comando tal cual (usando el clon canónico ya presente, vía la detección de `-d "$DIR/.git"` del
propio script) y reportado lo que pasara.

**La lección explícita del usuario:** *"causó mucho más trabajo debuggear tu decisión de no duplicar
que lo que hubiera estorbado tener una copia redundante que ya teníamos y no revisaste."* — el costo de
una copia redundante e inofensiva casi siempre es MENOR que el costo de debuggear una desviación del
camino documentado. Antes de "optimizar" un comando que el usuario pidió correr literal, **verifica el
estado real actual** (¿ya existe lo que crees que vas a evitar duplicar?) en vez de asumir y ajustar.

**Cómo aplicar:** cuando el usuario pida explícitamente correr ALGO tal cual (un one-liner del README,
un comando de un doc, un botón de una UI reproducido por CLI) para **QA del mecanismo mismo**, resiste
el impulso de "mejorarlo" con flags/env vars aunque tengas una razón válida — si la razón importa,
verifícala primero (¿el problema que quieres evitar existe de verdad?) o pregúntale al usuario, no decidas
por tu cuenta y corras una versión modificada.
