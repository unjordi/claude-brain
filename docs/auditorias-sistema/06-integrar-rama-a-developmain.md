# Auditoría de SISTEMA — 06 · Integrar rama a develop/main
> 2026-09-08 (turno-nocturno) · 3 lentes ollama (think:false).
> Código: confirmar-merge-develop, merge-squash-guard, git-branch-guard, analizar-comando-git — los MISMOS guards de supervisión que el proceso 03.

## VEREDICTO: 100% OVERLAP con el proceso 03. Nada nuevo.
Sin alto/crítico. Los medios son exactamente los del audit-03 (mismo código de guards de integración):
- merge-squash `--fill`/`$()`/`--body-file` como UNVERIFICABLE → salta el piso de sustancia (evasión).
- confirmar-merge `_juez_merge_uno`: robustez del juez-LLM (centinela último, cruce del contexto factual).
- `acg_destino_de_mr`: dependencia de PATH sin modo debug.
TODO ya PARQUEADO en `docs/auditorias-sistema/03-*.md` + backlog #9 (pasada de tuning de guards con unjordi, cada fix con su test). No se re-lista aquí para no duplicar. Guards de supervisión → no se tocan sin OK.
