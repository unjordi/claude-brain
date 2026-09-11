#!/usr/bin/env bash
# contrato-hilo.sh — LIB (tier global). El CONTRATO entre quien ESCRIBE el hilo (el skill `checkpoint`)
# y quien lo LEE (`rehidratar-hilo.sh`). UNA sola definición del footer de metadatos y de la fecha.
#
# POR QUÉ EXISTE: el footer `> Última actualización: <fecha> · rama <rama> · nivel <x>` es un contrato
# REAL — `rehidratar-hilo.sh` decide con él si el hilo está vigente o si lo degrada a "⚠️ POSIBLEMENTE
# OBSOLETO" —, la skill `checkpoint` lo PRESCRIBE en su plantilla… y nadie lo VERIFICABA. Medido el
# 2026-09-11 sobre los 9 `hilo-mental-actual.md` reales de ~/code: **2 de 9 (22%) no traen el footer**
# ⇒ el gate de rama no puede dispararse, cae al proxy de 12h y un hilo VIGENTE se presenta como obsoleto.
# Es el MISMO modo de falla (A8) que el gate documenta haber cerrado por el otro flanco (el regex goloso):
# se cerró la puerta del regex y quedó abierta la del footer ausente.
#
# La lib es la mitad "una sola definición": el lector la SOURCEA (en vez de re-escribir el regex) y el
# escritor la puede correr como verificación de su propio volcado. Que el regex viva en un solo lado es
# lo que impide que escritor y lector deriven — la misma clase de falla que el candado de
# `reubicar-master` combate exigiendo el preludio byte a byte.
#
# API (todo read-only; ninguna función escribe ni un byte):
#   hilo_rama <archivo>          → imprime la rama del footer ("" si no hay)
#   hilo_fecha <archivo>         → imprime la 1a fecha ISO del archivo ("" si no hay)
#   hilo_edad_legible <segundos> → "2d 5h" / "3h 20m" / "45m"
#   verificar_hilo <archivo>     → exit 0 si cumple el contrato; 1 e imprime los motivos si no
#
# CONTRATO DE USO: fail-open en el LECTOR (un hilo sin footer se lee igual, solo pierde el gate de rama),
# fail-LOUD en el ESCRITOR (el checkpoint SÍ debe enterarse de que su volcado nace inauditable).

# La rama del footer de metadatos. ANCLADA al separador `·` a propósito — es la misma extracción que
# `rehidratar-hilo.sh` usaba inline, y cierra sus dos bugs históricos:
#   (1) un `.*[Rr]ama` goloso consumía hasta el "rama" de una SUBCADENA (`feat/diagrama-x` → `-x`), y
#   (2) una línea de PROSA con "de rama X" no son metadatos (la prosa no lleva `· rama`).
# Una rama de git no tiene espacios; `tr` limpia el markdown (`· rama \`<x>\``).
hilo_rama() {
  [ -f "${1:-}" ] || return 0
  grep -E '·[[:space:]]+[Rr]ama[[:space:]]' "$1" 2>/dev/null | head -n1 \
    | sed -E 's/.*·[[:space:]]+[Rr]ama[[:space:]]+//' | awk '{print $1}' | tr -d '`*"'
}

# La fecha ABSOLUTA (ISO) del volcado. "hoy"/"ayer" no son fechas: al releerse tras un corte, una fecha
# relativa miente sobre su propia antigüedad.
hilo_fecha() {
  [ -f "${1:-}" ] || return 0
  grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' "$1" 2>/dev/null | head -n1
}

# Edad en prosa corta, para que el encabezado del rehidratado diga el DATO y no solo un veredicto.
hilo_edad_legible() {
  _s="${1:-0}"
  case "$_s" in ''|*[!0-9]*) printf 'edad desconocida'; return 0 ;; esac
  _d=$(( _s / 86400 )); _h=$(( (_s % 86400) / 3600 )); _m=$(( (_s % 3600) / 60 ))
  if   [ "$_d" -gt 0 ]; then printf '%sd %sh' "$_d" "$_h"
  elif [ "$_h" -gt 0 ]; then printf '%sh %sm' "$_h" "$_m"
  else                       printf '%sm' "$_m"; fi
}

# El verificador. Lo corre el skill `checkpoint` tras volcar (fail-LOUD) y `test-brain.sh` sobre fixtures.
# NO juzga el CONTENIDO del hilo (eso es criterio del modelo): solo que sea AUDITABLE por su lector.
verificar_hilo() {
  _f="${1:-}"
  _fallos=0
  if [ ! -f "$_f" ]; then
    printf 'CONTRATO-HILO: no existe el archivo: %s\n' "$_f" >&2
    return 1
  fi
  if [ -z "$(hilo_rama "$_f")" ]; then
    printf 'CONTRATO-HILO: %s SIN footer "· rama <x>" ⇒ rehidratar-hilo NO puede usar el gate de rama y\n' "$_f" >&2
    printf '  caerá al proxy de 12h: un hilo VIGENTE se presentará como "⚠️ POSIBLEMENTE OBSOLETO".\n' >&2
    printf '  Arreglo: la 2a línea del hilo va como "> Última actualización: <AAAA-MM-DD> · rama <rama> · nivel <ligero|COMPLETO>".\n' >&2
    _fallos=$((_fallos+1))
  fi
  if [ -z "$(hilo_fecha "$_f")" ]; then
    printf 'CONTRATO-HILO: %s SIN fecha ABSOLUTA (AAAA-MM-DD) ⇒ al releerlo no se puede juzgar su antigüedad.\n' "$_f" >&2
    _fallos=$((_fallos+1))
  fi
  [ "$_fallos" -eq 0 ]
}
