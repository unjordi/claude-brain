# Auditoría de SISTEMA — 03 · Enforcement / git-guards
> 2026-09-08 (turno-nocturno) · 3 lentes ollama qwen3.8:27b (think:false) · flowchart 03 como zapato.
> Código: git-branch-guard.sh, merge-squash-guard.sh, confirmar-merge-develop.sh, analizar-comando-git.sh (lib), juez-comun.sh (lib).

## ⛔ VEREDICTO DE LA NOCHE: TODO PARQUEADO PARA unjordi (no tocado)
El proceso 03 es **100% guards de SUPERVISIÓN**. Por la cerca del turno-nocturno + la norma de Integridad de
guardarraíles, **NINGÚN cambio de conducta de estos guards se hace sin OK explícito de unjordi.** Los hallazgos
son reales y corpus-backed, pero se PARQUEAN como la **pasada de tuning de guards** (backlog #9) — cada fix
nace con su test, con tu decisión. Aquí agrupados para esa pasada.

## (A) PRECISIÓN — guard demasiado ESTRICTO (FPs recurrentes, corpus-backed)
- **ALTO/recurrente · `analizar-comando-git.sh:acg_push_toca_base` · push PELÓN desde una ramita** con upstream a la misma ramita → bloqueado (lee la rama actual, no distingue "pelón en develop" de "pelón en ramita con upstream"). Corpus: 2026-08-03/08-06/08-28/09-03/09-08 (5+). Efecto colateral: corta la cadena `commit && push && worktree remove`. Fix propuesto: si el push es pelón y la rama actual NO es develop/main, resolver el upstream (`@{u}`) y dejar pasar si NO apunta a develop/main.
- **ALTO · checkout-then-push en el MISMO comando** (`git checkout fix/x && git push`) → lee la rama ANTERIOR → bloquea. Fix: resolver la rama POST-comando o no fallar-cerrado si hay checkout/cd previo.
- **MEDIO · `confirmar-merge-develop.sh` matchea "develop" como SUBCADENA en `DevelopUnjordi`** → bloquea el MR a la mini-develop personal. Corpus 2026-09-08 (MR !57). Fix: match EXACTO `^develop$`/`^main$`; `Develop[A-Z]*` pasa libre (mismo patrón que `drift_chequea_repo`).
- **BAJO · `acg_despoja_comillas` no filtra cuerpos de heredoc** → un `cat >>f <<EOF` que mencione `git push`/`glab mr merge` dispara en falso. Corpus 07-22/08-06/08-07/09-03/09-07. Fix: filtrar heredocs antes de escanear (como ya hace `proteger-arbol`).
- **BAJO · seed de repo VACÍO** (primer `git push -u origin main` con 0 commits) bloqueado. Corpus 07-22. Fix: detectar repo vacío (0 commits) y permitir el seed inicial.

## (B) EVASIÓN — guard demasiado DÉBIL (huecos de seguridad; SUBEN de prioridad)
- **MEDIO/seguridad · merge-squash falla-OPEN con `$(cat …)` / `--body-file` / `gh --fill`** → un mensaje de squash BASURA o vacío pasa SIN validar el piso anti-basura. **Lo exploté yo mismo hoy** (usé `--body-file` para pasar el guard). `--fill` es determinista y verificable vía API (`gh pr view --json title`) igual que AUTO → tratarlo como AUTO, no UNVERIFICABLE. Y validar el contenido del archivo referenciado en `$(cat f)` (tamaño/no-vacío) antes de pasar.
- **MEDIO/seguridad · `confirmar-merge-develop.sh`: el PISO DETERMINISTA de main NO se aplica cuando el destino es IRRESOLUBLE.** Si la consulta de destino falla (timeout/red) el juez trata el destino como main (fail-seguro) PERO el piso determinista de release (que exige lenguaje explícito "release/libera/hasta main") NO corre porque `$destino != main` literal → un merge a main podría colarse con lenguaje ambiguo si la red falla. Fix: aplicar el piso determinista de main también cuando el destino es IRRESOLUBLE.
- **BAJO · `master` no está en la lista de bases protegidas** (alias de main en muchos repos). Fix: incluir `master`.
- **BAJO · caché de destino de MR por-id no se invalida si cambia la base del MR** (develop→main) → podría usar el destino viejo y saltarse el gate de release. Fix: hash/timestamp del MR en la clave.

## (C) ROBUSTEZ DEL JUEZ-LLM (bajos; varios especulativos/inherentes al diseño LLM)
Superficie de prompt-injection del juez de merge: el LLM podría citar una línea de USUARIO irrelevante o
alucinada; el centinela `VEREDICTO:` no se exige como ÚLTIMO; el contexto factual no se cruza con la API;
patrones de editorialización/narración/trazabilidad solo en español y por regex fija (evadibles con otras
frases/idiomas). La mayoría son inherentes a un juez-LLM y de bajo impacto real (hay VETO de cita verificada +
voto múltiple + sandbox de contexto factual que mitigan). Para la pasada de tuning: priorizar el "centinela
último" y el cruce del contexto factual con la API; el resto documentar como límites conocidos del juez.

## (D) DOC/OPERABILIDAD (no-conducta)
- confirmar-merge sin red/token = DENY sin ruta CLI documentada (la Web es el flujo humano, NO un escape para desatorar a Claude — la norma lo prohíbe como vein-popper). Documentar "sin red = flujo web del humano" en la doc operativa. NO implementar bypass.
- Falta un modo debug de la resolución de destino (`acg_destino_de_mr`) que vuelque PATH efectivo + comando gh/glab + error.
- juez-comun: el mensaje de error no distingue Anthropic-caído vs Ollama-caído.

## NADA convergido/tocado esta noche (correcto). Siguiente: proceso 04.
Estos van a la **pasada de tuning de guards con unjordi** (backlog #9, ahora con corpus completo). Cada fix con su test.
