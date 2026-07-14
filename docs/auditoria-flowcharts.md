# Auditoría del mapa `docs/mapa-flujos.dot` — claude-brain

> Auditor de Calidad (experto en procesos industriales/FMEA + análisis de algoritmos). Leyó los 18 hooks,
> la lib compartida, las 2 skills, el cableado de `settings.json`, y cotejó el mapa contra el source
> (`brain/hooks/`) **Y** la copia desplegada en la plantilla .NET. Fecha: 2026-07-14.
> Checklist accionable derivado: `docs/plan-refactor-desacople.md` §7. H1/H3/H5/H6/H7 re-verificados contra el código.

## 1. Resumen ejecutivo

El mapa es, en conjunto, **notablemente honesto y de alta fidelidad**: la mayoría de los flujos (③ secret/árbol,
⑤ dod salvo un matiz, ⑥ cerrar-slice, ⑦ delegación, ⑧ fan-out) casan bien con el `.sh`/`SKILL.md`, y el propio
flujo ⓪ ya diagnostica sus peores agujeros (drift, `cp -f`, sets de instalación divergentes). Pero hay
**defectos reales** que el mapa no muestra y algunos son del código mismo, no del dibujo.

Los 3 riesgos más graves:
1. **`git-branch-guard` tiene un falso NEGATIVO en el caso más básico**: un `git push` pelón estando en
   `develop`/`main` NO se bloquea (el regex exige que el nombre de la rama aparezca en el texto del comando).
   El mapa lo pinta como candado total.
2. **La premisa "fuente única / fiel a la lógica real" es falsa: el drift es BIDIRECCIONAL.** El
   `dod-verificar` del widget tiene el bloqueo de QA-visual-a-ciegas (⑤ G2_D1) que NO existe en el
   `dod-verificar` que embarca la plantilla .NET; y el `git-branch-guard` de la plantilla tiene un fix de
   comillas que falta en `brain/hooks/` (la supuesta fuente). Ningún mapa puede ser fiel a ambos despliegues.
3. **`confirmar-merge-develop` se puede evadir** con un token inocuo (`… && git status`) → integra a develop
   sin verificar el OK del usuario (fail-open del gate de LISTO).

## 2. Hallazgos (de más a menos severo)

### H1 · [ALTO] `git push` pelón a develop/main NO se bloquea — LÓGICA (+ mapa lo oculta)
- Flujo ② (G1_D1). `PUSH_RE` exige `main|develop` como token *dentro del texto del comando*
  (`brain/hooks/git-branch-guard.sh:30`, greps `$cmd` en :33). Un `git push` sin refspec estando checkouteado
  en `develop`/`main` empuja a la rama protegida pero no contiene la palabra "develop" → no matchea → **pasa**.
- Escenario: estás en `develop` (p. ej. tras `git checkout develop && git pull`), corres `git push` → se sube
  a develop sin que el guard chiste.
- Mitigado por ramas protegidas server-side (backstop real según CLAUDE.md) + aviso de `sesion-inicio`, pero el
  candado en sí es evadible en su caso canónico. El mapa G1_D1 ("¿push DIRECTO a develop/main?") sugiere cobertura total.
- Arreglo (1 línea): si no hay refspec, resolver la rama actual (`git rev-parse --abbrev-ref HEAD`) y su
  upstream y bloquear si es develop/main.

### H2 · [ALTO] Drift BIDIRECCIONAL rompe "fuente de verdad" — MAPA vs realidad desplegada
El header del `.dot` dice "fuente de verdad… fiel a la lógica real de cada hook". Comprobado falso en ambos sentidos:
- **Widget adelante de la plantilla:** `brain/hooks/dod-verificar.sh:80-94` tiene el bloqueo B2 (QA visual a
  ciegas, detección por estructura de tool_use chrome-MCP). El shipped `plantilladotnet/.claude/hooks/dod-verificar.sh`
  NO lo tiene (grep de `claude-in-chrome|VISUAL_RE|A CIEGAS` = 0; el archivo es 5.7k vs 12k del widget). El mapa
  ⑤ dibuja G2_D1→G2_VIS como rama activa; en la plantilla desplegada esa rama no existe.
- **Plantilla adelante del "source":** `plantilladotnet/.claude/hooks/git-branch-guard.sh:22` despoja comillas
  (`unquoted=… sed`) para no matchear menciones entrecomilladas; el `brain/hooks/git-branch-guard.sh` (la
  supuesta fuente) no lo hace.
- Consecuencia: no hay UNA lógica; el mapa sobre-declara los guards para quien corre la plantilla, y `brain/`
  no es fiel a su propia copia desplegada. Corrobora ⓪ (I8_HUECO/I8_FIX) pero con el twist de que el source también está stale.
- Arreglo: el `sincronizar-cerebro.sh` + sello de versión + check de drift en CI que el propio mapa ya propone
  (I8_FIX), pero bidireccional.

### H3 · [ALTO→MEDIO] `confirmar-merge-develop` se evade con un token de escape — LÓGICA (fail-open)
- Flujo ② (G1_D3). `brain/hooks/confirmar-merge-develop.sh:32`:
  `grep -qE '(^|[[:space:]])(--help|-h|list|view|--dry-run|status)([[:space:]]|$)' && exit 0`. El match es sobre
  **todo** el comando, por token suelto.
- Escenario: `glab mr merge 5 --yes && git status` — el token `status` dispara el escape → el hook sale antes
  de exigir el OK → integra a develop sin confirmación. (Igual con `… ; echo status`, `… && glab mr view 5`.)
  `merge-squash-guard` no tiene este escape, así que el squash se sigue exigiendo, pero el gate de LISTO se cae solo.
- Arreglo: anclar los escapes al subcomando real (`glab mr (list|view)…`), no a cualquier aparición del token.

### H4 · [MEDIO] `dod-verificar`: STATUS_RE precede al claim → un cierre real se enmascara — LÓGICA + mapa impreciso
- Flujo ⑤ (G2_D0). El fix G1 (claim vs pregunta) solo protege el escape por `¿…?` (`dod-verificar.sh:68` bajo
  `if [ "$claim" != si ]`). Pero el escape por STATUS_RE en `:62` es incondicional y corre antes.
- Escenario: "Listo, quedó terminado. Dime si reviso algo más." — `dime si` ∈ STATUS_RE → `exit 0` → no bloquea,
  pese a un claim de cierre afirmado tras tocar código. El mapa G2_D0 insinúa que la co-ubicación de claim aplica
  a TODO el escape; en el código solo aplica a la pregunta.
- Arreglo: subordinar también el escape STATUS_RE a `claim != si`.

### H5 · [MEDIO] Guards dependientes de red fallan-ABIERTO por TIMEOUT — LÓGICA + mapa
- Flujo ②. `merge-squash-guard.sh:49-51` y `confirmar-merge-develop.sh:47-52` llaman `glab api`/`gh pr view`
  para resolver `target_branch`. En el MISMO `glab mr merge` ambos disparan en paralelo → 2 llamadas de red
  idénticas (la dedup solo cubre repo-vs-global del mismo hook, no entre hooks distintos). Timeouts cableados:
  10s (squash) y 15s (confirmar) en `plantilladotnet/.claude/settings.json`.
- Si la API va lenta y el proceso se mata por timeout, Claude Code lo trata como "sin deny" → el merge procede
  sin squash / sin OK. Ojo: la lógica falla-SEGURO ante *error* de API (destino="" → se trata como develop),
  pero un *timeout del proceso* evade el hook entero. El mapa los pinta como confiables.
- Arreglo: cachear el `target_branch` una vez por MR-id y compartirlo; subir timeout o degradar a "deny
  conservador" si la resolución no termina.

### H6 · [MEDIO] `delegacion-gate`: una negación se puede burlar reintentando en <60s — LÓGICA
- Flujo ⑦. `delegacion-gate.sh:22-28,45`: el lock de coalescencia (`mkdir` por sid+key) NO se borra al negar y
  vive 60s. Si el usuario niega el ask, un reintento del mismo Task dentro del minuto ve el lock fresco →
  `soy_el_primero_del_lote` devuelve 1 → el gate `exit 0` (permite en silencio, sin preguntar).
- Además, en el lote original los hermanos ya salieron `exit 0` (permitidos) antes de que se respondiera el ask
  → un "no" no los detiene. Es "by-design" para gratis/incluido (costo cero), pero mina la semántica de
  consentimiento y el mapa G3_SIL no muestra que una negación no se propaga.
- Arreglo: liberar el lock cuando el registrar (PostToolUse) no persiste consentimiento, o registrar el "no" como veto de sesión.

### H7 · [MEDIO] `secret-scan`: guard de SEGURIDAD que falla-ABIERTO + cobertura estrecha + ausente en clon fresco
- Flujo ③. `secret-scan.sh:23-24,35,80`: sin jq / sin git / rango indeterminable → `exit 0` (el secreto pasa).
  Patrones solo por prefijo (`AKIA/PEM/sk-*/gh_/glpat/xox/AIza`): no detecta connection strings (`://user:pass@`,
  `Password=`), JWTs, ni blobs base64. Para la peor clase de error (credencial filtrada), fail-open + patrones
  angostos = cero garantía.
- Agravante sistémico: `secret-scan` no está cableado por-repo (`plantilladotnet/.claude/settings.json` no lo
  incluye). Un clon fresco de la plantilla sin `install-brain` global no tiene NINGÚN escaneo de secretos.
  Confirma I8_DIV del mapa; es un hueco P0 de seguridad, no solo de fricción.
- El mapa S_PASA3 reconoce el fail-open, pero no marca "clon fresco = sin secret-scan" como el filo agudo que es.

### H8 · [MEDIO] Contradicción "release a main solo por web" vs. CLI permitido — MAPA + norma
- La norma N_GIT y CLAUDE.md dicen: main es release-only, "lo promueve el humano en la web, JAMÁS por CLI", y
  `git-branch-guard.sh:31,37-38` bloquea `glab mr merge … main`. Pero `confirmar-merge-develop.sh:80-89` sí
  permite un release a main por CLI con autorización súper-explícita, y el mapa ② G1_OK lo dibuja como camino
  verde ("main: release SIN squash").
- Además el mapa ② omite por completo la rama MERGE_RE de git-branch-guard (G1_D1 solo pregunta por "push
  directo"): un `glab mr merge` que mencione `main`/`develop` como token también se bloquea, y eso no aparece.
- Arreglo: alinear el texto de la norma ("posible por CLI con OK súper-explícito", no "jamás") y agregar al mapa
  la rama de merge de branch-guard.

### H9 · [MEDIO] La norma P0 (integridad de guardarraíles) NO tiene mecanismo local — coherencia norma↔flujo
- `N_P0` se pinta "activa" y "protege dod-verificar ⑤ · confirmar/squash/branch ② · proteger-arbol ③", pero
  ningún hook del repo impide editar/aflojar `brain/hooks/*.sh`. El enforcement es enteramente externo (el
  "clasificador auto-mode", según CLAUDE.md). Es exactamente el anti-patrón que `N_MEC` ("toda norma nace con su
  mecanismo") denuncia: una norma presentada como activa sin enforcer in-repo. El mapa sobre-declara P0.

### H10 · [BAJO] Hook PreCompact cableado que el mapa no muestra + statusMessage engañoso
- `plantilladotnet/.claude/settings.json` cablea `precompact-volcar-estado.sh` con
  `statusMessage:"Cerebro: volcando estado antes de compactar"`, pero el hook es un no-op documentado
  (`cat >/dev/null; exit 0`). El mapa ① no dibuja este nodo cableado y su statusMessage miente sobre lo que hace (nada).
- Arreglo: quitar el statusMessage o descablearlo; reflejar en ① que existe como punto de extensión inerte.

### H11 · [BAJO] Falsos positivos de `git-branch-guard` — LÓGICA
- Repo cuyo path termina en `/develop` o `/main`: `gh pr merge 5 -R org/develop` → MERGE_RE matchea
  `[[:space:]:/]develop` al final → DENY indebido.
- Versión widget (sin fix de comillas): `git commit -m "documentar git push a develop"` → PUSH_RE matchea dentro
  del literal → DENY. (Corregido en la plantilla vía `unquoted`, no en `brain/`.)

### H12 · [BAJO] Doc=realidad violado dentro del propio hook
- `delegacion-gate.sh:6` dice "umbral configurable, def 95%", pero el default real es 90
  (`delegacion-comun.sh:18,28`). El mapa usa 90 (correcto); el comentario del hook, no.

### H13 · [BAJO] Manejo inconsistente de comillas entre guards del mismo evento
- `recordar-dashboard`, `rama-vieja`, `proteger-arbol` despojan literales entrecomillados; `secret-scan` y
  (widget) `git-branch-guard` no. La misma clase de falso positivo (un verbo git dentro de un string) se maneja
  en unos y no en otros.

## 3. Matriz disparador × hooks (colisiones visibles)

Todos los del mismo evento corren en PARALELO (sin despachador; para permisos gana `deny` > `ask` > `allow`; los
`additionalContext` se acumulan). Clave: 🔒 puede DENY · 🔔 inyecta · ⚪ sale sin efecto.

| Acción (tool) | Hooks que disparan | Nota de colisión |
|---|---|---|
| `git push origin feat/x` (PreToolUse/Bash) | git-branch-guard ⚪ · squash-guard ⚪ · confirmar ⚪ · **recordar-dashboard 🔔** · **secret-scan 🔒** · **rama-vieja 🔔** · proteger-arbol ⚪ | Hasta 2 inyecciones apiladas + posible DENY de secret-scan. UN push = 7 hooks lo inspeccionan. El mapa lo parte en ②③④ (mismo evento). |
| `git commit` | **secret-scan 🔒** · resto ⚪ | secret-scan no despoja comillas (H13). |
| `glab mr merge <id>` → develop, sin squash, sin OK | branch-guard ⚪(si sin token) · **squash-guard 🔒 DENY** · **confirmar 🔒 DENY** | Doble DENY simultáneo (no secuencial como pinta ②) + 2 llamadas de red idénticas (H5). |
| `glab mr merge <id>` → main, con OK release | branch-guard ⚪(si sin token)/🔒(si token) · squash-guard ⚪ · confirmar 🟢 | Contradicción norma "jamás por CLI" (H8). |
| `git reset --hard` / `rebase` / `branch -D` | **proteger-arbol 🔔** · resto ⚪ | Solo avisa; fail-open OK (guard de fricción). |
| `Task` (delegar) | **limite-gasto 🔒** · **delegacion-gate 🟠** (Pre) → **delegacion-registrar 🔔** · **delegacion-reporte 🔔** (Post) → **aviso-contexto 🔔** (Post, toda tool) | deny(limite) > ask(gate) por precedencia = intención del mapa, pero "corre ANTES" es simplificación (son paralelos). |
| Stop (fin de turno) | **dod-verificar 🔒** (solo por-repo) | Ausente si sesión no inició en el repo. |
| SessionStart | **sesion-inicio 🔔** (repo) · **rehidratar-hilo 🔔** (global) | Dos inyecciones; rehidratar resetea el baseline del watermark. |
| Toda tool (PostToolUse) | **aviso-contexto 🔔** | Corre en cada tool; barato pero constante. |

Coberturas ausentes: `rm -rf`/destructivo de FS no-git (proteger-arbol solo cubre git); edición de los propios
hooks (P0 sin mecanismo, H9); `git push` pelón en develop (H1); clon fresco de plantilla = sin
secret-scan/delegación/aviso-contexto/rehidratar (H2/H7).

## 4. Veredicto

**El conjunto es coherente y razonablemente completo como MODELO conceptual — no hay que rehacer flujos.** El mapa
captura bien la arquitectura y hasta autocritica sus peores huecos (⓪). Pero **no debe presentarse como "fiel a la
lógica real" sin dos correcciones estructurales**:

1. **Resolver el drift bidireccional (H2)** antes que cualquier otra cosa: hoy el mapa describe una amalgama que no
   corresponde ni al `brain/` ni a la plantilla desplegada. Sin sello de versión + check de drift (I8_FIX, ya
   propuesto), el mapa envejece hacia la mentira.
2. **Corregir 3 defectos de LÓGICA que degradan candados a fail-open real**, no solo el dibujo: H1 (push pelón),
   H3 (escape por token en confirmar), H5 (timeout de red). Son los que convierten un candado en un colador bajo
   condiciones plausibles.

Ajustes de MAPA recomendados (no rehacer, sí anotar): mostrar que ②③④ son el MISMO evento PreToolUse/Bash con N
hooks paralelos; añadir la rama MERGE_RE de branch-guard en ②; matizar G2_D0 (el escape STATUS_RE no es
claim-aware, H4); reflejar el PreCompact no-op cableado (H10); y bajar P0 de "activa/protege" a "norma sin
mecanismo local — enforcement externo" (H9).
