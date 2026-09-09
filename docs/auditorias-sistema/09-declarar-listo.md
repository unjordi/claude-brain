# Auditoría de SISTEMA — 09 · Declarar LISTO al fin de turno (dod-verificar)
> 2026-09-08 (turno-nocturno) · 3 lentes ollama (think:false, con prompts anti-alucinación).
> Código: dod-verificar.sh — guard de SUPERVISIÓN cuyo núcleo es un PROMPT LLM (juez de la definición de LISTO).

## VEREDICTO: sin C/A/M real accionable. PARK (guard de supervisión + low-signal).
El auditor DEGENERÓ sobre este archivo porque su "código" es mayormente un PROMPT en prosa natural (el juez
_juez_dod), no un algoritmo:
- Lente **proceso**: entró en LOOP de repetición (repitió "el verdadero problema es la regla TRABAJO-EN-MINI…"
  decenas de veces buscando una contradicción entre las reglas CIERRE del prompt, sin hallarla — cada iteración
  concluía "Esto es consistente"). Degeneración, no hallazgo.
- Lente **coherencia**: 19 "hallazgos" que se AUTO-REFUTAN ("Esto es consistente · impacto: Ninguno · fix:
  Ninguno"). El auditor generó y descartó él mismo.
- Lente **suficiencia**: 5, mismo patrón.

**Único semi-real (minor):** la detección de "tocó código" usa `grep -oE '"file_path":"[^"]+"'`; si el formato
del transcript cambiara (espacios en el JSON, o `path` en vez de `file_path` en alguna tool) la detección
podría fallar. Fragilidad de acoplamiento al formato del transcript. Guard de supervisión → parqueado; de
bajísima probabilidad (el formato del CLI es estable).

## LECCIÓN META (para el barrido): auditar con ollama un hook cuyo cuerpo es un PROMPT LLM (dod-verificar) es
poco fértil — el auditor confunde la prosa del prompt con "algoritmo" y degenera. El prompt anti-alucinación
quitó los números de línea inventados (proceso 08) pero NO el loop de repetición sobre prosa. Para dod, el
juez real de su calidad es su propio corpus de FP + el uso en vivo, no un auditor de algoritmos.

Opus gate: N/A (guard de supervisión, sin fix accionable).
