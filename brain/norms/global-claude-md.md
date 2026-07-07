<!-- BEGIN claude-brain (normas globales — no editar a mano; se regeneran con install-brain.sh) -->
# Normas globales del cerebro (claude-brain)

> Bloque instalado por `claude-brain` en `~/.claude/CLAUDE.md`. Son normas DURAS y genéricas
> (agnósticas de stack) que aplican a Claude, a los agentes que delega y a toda sesión del equipo.

## Documentación = reflejo de la realidad (norma dura, NO se pregunta)
Cuando cambia algo (config aplicada en vivo, decisión revertida, ruta, comportamiento real),
**actualiza la doc que lo describe en la MISMA tanda** — README, memoria, dashboard, comentarios.
No preguntes "¿actualizo la doc?": hazlo. Una doc que miente es peor que no tener doc. Y el orden
correcto SIEMPRE es **revisar el estado real → editar**, no al revés.

## Definición de "LISTO" (norma dura, MUTUA e inviolable)
Algo es **LISTO** (terminado / funciona / en producción / "quedó" / "a la par" / "de punta a punta")
**solo** si se cumple UNA de estas dos, y **jamás** fuera de ellas:
1. **Funcionalidad confirmada** — el usuario la validó (QA visual/funcional), *o* pasó una prueba
   funcional que se **acordó de antemano** como suficiente para ESE tipo de cambio.
2. **Autorización expresa de cierre** — el usuario dijo explícitamente, para ESA cosa concreta, que se
   da por lista sin su revisión.

Reglas que lo blindan:
- **Verde técnico ≠ LISTO.** "build/tests/lint verdes + memoria al día" es *verificado técnicamente*:
  peldaño necesario, **insuficiente** para declarar LISTO.
- **"sigue / avanza / no pares" ≠ LISTO.** Una luz verde para trabajar de corrido solo permite
  avanzar sin pedir permiso a cada paso; cada entregable sigue necesitando (1) o (2) para llamarse LISTO.
- **"revisamos en la mañana / al rato" ⇒ todo queda "en preview / a revisión", NUNCA LISTO**, hasta
  la confirmación.
- **Léxico obligatorio** mientras no haya (1) o (2): "en preview", "a tu revisión", "verificado
  técnicamente", "pendiente de tu QA", "armado sin mergear". **Prohibido**: listo/terminado/funciona/
  quedó/a la par/de punta a punta.
- **La autorización es ACOTADA y NO transitiva.** Un "adelante/sí/dale" aplica SOLO a lo que el usuario
  nombró explícitamente — no se estira a "todo el paquete". El silencio, tomarse el tiempo para
  leer/considerar, o una reacción positiva a UNA idea NO son autorización. Ante alcance ambiguo, la
  carga de aclarar es de Claude: **preguntar "¿adelante con qué exactamente?"**, no maximizar la interpretación.
- Lo hace cumplir el hook `dod-verificar` (Stop): distingue lenguaje de ESTATUS/espera (no dispara) de
  lenguaje de CIERRE (exige, además del verde técnico, la marca citada de (1) o (2)).

## Flujo de git — NUNCA push a `develop` ni a `main` (norma dura)
> Léxico: "merge request" (GitLab) = "pull request / PR" (GitHub) = lo mismo.

**REGLA DE ORO — SIN PREGUNTAR.** Aplica a **TODOS los repos SIEMPRE** y es el **default**: no preguntes
"¿commiteo?", "¿creamos develop?", "¿le hago merge?", "¿directo a main?". Solo hazlo por el flujo. Si un
repo no tiene `develop`, créalo (de `main`) y sigue el flujo. La ÚNICA vez que el commit inicial puede
ir directo a una rama base es para **sembrar un repo vacío** (0 commits); una vez sembrado, jamás se
vuelve a tocar base con push.

1. **NUNCA `git push` a `develop` ni a `main`.** Sin excepciones. Incluye el disfraz
   `git checkout develop && git merge rama && git push origin develop` — eso ES un push a develop.
2. **TODOS los push van a ramitas** (`feat/…`, `fix/…`, `chore/…`, `docs/…`), sacadas de `develop`.
3. La ramita se integra a `develop` por el **MERGE de un MR/PR**, del lado del servidor. Nunca tocas
   `develop`/`main` con un push local. A `main` se llega igual: MR/PR desde `develop`.
4. **El tamaño del equipo SOLO decide si hay revisión, NO si hay push:**
   - **1–3 devs:** MR/PR con **AUTO-MERGE** al instante.
   - **≥4 devs:** el MR/PR **se revisa** antes de mergear.
5. **Al integrar a `develop` se SQUASHEA** (un commit limpio y curado por slice). Lo exige el hook
   `merge-squash-guard`. Los releases `develop→main` van SIN squash (conservan historia).
6. **`main` es RELEASE-ONLY.** El flujo normal TERMINA en `develop`. Promover `develop→main` es una
   decisión de release DELIBERADA que el usuario pide explícitamente — jamás automática, jamás por un
   chore/docs/memoria. Si no dijo "release" o "a main", **te quedas en develop.** El release a main por
   CLI exige autorización SUPER explícita (lo hace cumplir `confirmar-merge-develop`); un `mergea`
   genérico NO lo autoriza.

Enforced por: ramas protegidas server-side + los hooks `git-branch-guard`, `merge-squash-guard` y
`confirmar-merge-develop`.

## Modelo MINI-DEVELOP (iterar sin fricción)
Para trabajar horas/días sin pedir permiso a cada paso: mergea las ramitas de feature **con `git merge`
LOCAL** a una rama de INTEGRACIÓN de larga vida (`integracion/<sprint>` o `epic/<tema>`) — ahí rompes y
arreglas a gusto, reconstruyes, sin fricción. El `git merge` local NO pasa por ningún candado. El ÚNICO
cruce que exige tu confirmación expresa es integrar esa rama a `develop`/`main` por MR/PR.

## Consentimiento de costo de delegación (norma dura)
Reclutar un agente (Task/subagente) cuesta según su nivel: **gratis** (local), **incluido** (Claude
dentro de la ventana de 5h — sin costo marginal) o **metered** (Claude en overage, API externa de pago,
o desconocido). Los hooks `delegacion-gate`/`delegacion-registrar` piden consentimiento window-aware:
- **gratis / incluido** → se pregunta **1× por computadora**, luego silencioso.
- **metered** → se pregunta **1× por workflow** (session_id).
El *ask* muestra el estado real de tu ventana de 5h (%, $ usado de tope, tokens). No delegues a agentes
con costo sin ese consentimiento; ante duda de nivel, se trata como metered (conservador).
<!-- END claude-brain -->
