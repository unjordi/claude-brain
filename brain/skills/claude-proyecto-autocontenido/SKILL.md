---
name: claude-proyecto-autocontenido
description: >-
  Criterio para mantener TODO el "cerebro" de Claude Code de un proyecto (memorias, skills,
  transcripts y settings) dentro de la PROPIA carpeta del proyecto, en `<proyecto>/.claude/`,
  leído NATIVO desde el cwd por los hooks del cerebro (SIN symlinks — decisión dura de unjordi 2026-09-08).
  Úsala cuando quieras: que la memoria/skills "viajen" con el proyecto (Drive, iCloud, git, otra
  máquina como una MacBook), evitar que una sesión arranque "amnésica" al abrirla desde otro cwd,
  consolidar archivos de Claude dispersos, o definir esta convención para el onboarding del equipo.
  Cubre la regla del slug, el symlink de slug-dir, un bootstrap de un comando para que el equipo
  clone-y-listo, el triage de privacidad (qué viaja al repo vs qué se queda local), la disciplina
  anti-duplicados y la verificación.
---

> ⚠️ **RE-ARQUITECTURA A CERO-SYMLINKS (decisión dura de unjordi, 2026-09-08: "NO quiero symlinks en ningún lado").**
> La sección **"⛔ CERO SYMLINKS"** de abajo es la VIGENTE: el cerebro del repo se lee **NATIVO** desde el cwd
> (los HOOKS del cerebro —sesion-inicio, rehidratar-hilo— reinyectan `MEMORY.md`/`estado-proyecto.md`
> cwd-relative), y el `~/.claude/projects/<slug>` de CC va como **DIR REAL o no existe — JAMÁS un symlink** al
> repo. Todo lo de abajo que ARMA/verifica un symlink (el `bootstrap-claude.sh` embebido con su `ln -s`, el
> triage "cuando el slug se symlinkea al repo", la verificación por `readlink`) está **SUPERSEDIDO** y pendiente
> de reescritura completa — **NO lo sigas para crear symlinks nuevos.** Motivo: los symlinks CUELGAN al mover/
> borrar/renombrar el repo (rompen `/to-do` y cuanto lea `.claude/memory`) y proliferan (15 basura en la Cachy
> de "consolidar cerebro"). Migrar un symlink existente = convertirlo a dir real o borrarlo.

# Proyecto autocontenido de Claude Code (memoria/skills/transcripts en SU folder)

## El criterio (en una frase)
**El cerebro de Claude Code de cada proyecto vive en la carpeta del proyecto** (`<proyecto>/.claude/`),
no disperso en el árbol global. El global `~/.claude/projects/<slug>/` queda como **symlink** a esa
carpeta, para que Claude Code lo siga leyendo/escribiendo de forma nativa.

Así el cerebro **viaja con el proyecto** (se respalda, se sincroniza a Drive/iCloud, se versiona en
git, se comparte con el equipo o se copia a otra máquina) y deja de depender de la ruta absoluta
exacta desde la que abriste la sesión.

## Por qué hace falta (el problema que resuelve)
Claude Code guarda **memoria y transcripts** en `~/.claude/projects/<slug>/`, donde `<slug>` =
la ruta absoluta del directorio de trabajo con **cada carácter no alfanumérico → `-`**.
Consecuencias de dejarlo así:
- El cerebro queda **lejos del proyecto** y atado a esa ruta exacta.
- Si abres Claude desde **otro cwd** (p. ej. tu `$HOME` en vez de la carpeta del proyecto), o desde
  **otra máquina** donde la ruta cambia, el slug es distinto → la sesión arranca **"amnésica"**
  (sin memoria), aunque el trabajo exista.

Detalle clave que hace esto posible y limpio:
- **Skills y settings** ya se leen de forma nativa desde `<cwd>/.claude/` → ponerlos ahí es la
  ubicación oficial, sin truco.
- Solo **memoria y transcripts** necesitan el symlink, porque esos sí los resuelve CC por `<slug>`.

## La regla del slug (memorízala)
```
SLUG = ruta_absoluta_del_proyecto  con  [^a-zA-Z0-9] → '-'
```
Ejemplos:
- `/home/ana/dev/miapp`            → `-home-ana-dev-miapp`
- `/Users/ana/Drive/Mi Proyecto`   → `-Users-ana-Drive-Mi-Proyecto`

Reprodúcela y **verifica** contra lo que ya existe:
```bash
PROJ="$(pwd)"                                  # o la ruta del proyecto
SLUG="$(printf '%s' "$PROJ" | sed 's/[^a-zA-Z0-9]/-/g')"
ls -d ~/.claude/projects/"$SLUG"               # debe ser el dir (o symlink) de este proyecto
```

## Layout objetivo
```
<proyecto>/.claude/
├── settings.json          (compartible: permisos/hooks del proyecto)
├── settings.local.json    (local de la máquina; NO se comparte)
├── memory/                (MEMORY.md + las memorias del proyecto, archivos reales)
├── skills/                (SOLO skills específicas de ESTE proyecto)
└── transcripts/           (logs .jsonl; opcional según el modo, ver abajo)

~/.claude/projects/<slug>/   (dir REAL de CC: sus transcripts + su auto-memory — NUNCA un symlink al repo)
```
El `<proyecto>/.claude/` se lee **NATIVO** como `<cwd>/.claude` (CC lee `skills/` y `settings`; los HOOKS
del cerebro —sesion-inicio, rehidratar-hilo— reinyectan `memory/MEMORY.md` y `estado-proyecto.md` relativos
al **cwd**, no dependen del slug).

## ⛔ CERO SYMLINKS (decisión dura de unjordi, 2026-09-08: "NO quiero symlinks en ningún lado")
El cerebro del repo (`<proyecto>/.claude/memory`, `skills/`, `settings.json`, versionados) se lee NATIVO
porque el cwd ES el proyecto. El `~/.claude/projects/<slug>/memory` de CC (su auto-memory + `*.jsonl`) va
como **DIRECTORIO REAL** (lo crea CC solo) o **no existe** — **JAMÁS un symlink** al repo.
- **Por qué el cambio:** un `ln -s slug/memory → repo/.claude/memory` unificaba la auto-memory de CC con el
  cerebro del repo, PERO los symlinks son frágiles (CUELGAN al mover/borrar/renombrar el repo — rompen
  `/to-do` y todo lo que lea `.claude/memory` por el link roto) y proliferan (medido: 15 symlinks basura en
  la Cachy de "consolidar cerebro"). Un symlink colgante fue justo la causa de "/to-do no sirve" en un repo.
- **Qué NO se pierde:** la continuidad del cerebro NO dependía del symlink — la dan los HOOKS del cerebro
  (sesion-inicio reinyecta el orden de leer `MEMORY.md`/`estado-proyecto.md`; rehidratar-hilo relee el hilo),
  todos cwd-relative. La auto-memory NATIVA de CC (que sí resuelve por slug) queda SEPARADA (su propio dir
  real), y eso está bien: el cerebro del repo es la fuente, leída nativa.
- **Modo personal y modo equipo:** IGUAL — `<proyecto>/.claude/` versionado y leído nativo; NUNCA se
  symlinkea el slug ni `memory`. (Si CC ya creó un symlink `slug/memory`, conviértelo a dir real o bórralo:
  `[ -L ~/.claude/projects/<slug>/memory ] && rm ~/.claude/projects/<slug>/memory`.)

<a id="gitignore-canonico"></a>**Bloque `.gitignore` canónico (modo equipo)** — referenciado por el resto del skill, no lo repitas con variantes:
```gitignore
# OJO: los comentarios van en su PROPIA línea. Un '#' al final de un patrón NO es
# comentario en .gitignore — pasa a formar parte del patrón y lo rompe (lo verifiqué
# en vivo: `*.local.md  # nota` deja de ignorar el .local.md → fuga del secreto).
# transcripts de sesión: pesados y pueden traer datos sensibles
.claude/transcripts/
.claude/*.jsonl
# config específica de la máquina
.claude/settings.local.json
# memorias personales/sensibles que NO viajan al equipo
.claude/memory/*.local.md
```
Tras escribir el `.gitignore`, **verifícalo de verdad**: `git check-ignore .claude/memory/x.local.md`
debe imprimir la ruta (= ignorado). No te fíes de que "se ve bien".

## Antes de tocar nada: ¿cuál de los dos caminos es el mío? (LÉEME, futuro Claude)
Las operaciones de abajo NO son intercambiables. Identifica el caso **antes** de mover o enlazar
nada, porque el bootstrap respalda-y-enlaza pero **no fusiona**: correrlo en el momento equivocado
estranda (no borra, pero esconde en un `.bak`) el cerebro que el dueño tenía.

- **(A) Consolidar por primera vez** — el cerebro está disperso (global con notas + repo a medias)
  y soy yo/el dueño armando la convención. → Sigo el **Playbook** completo: triage + merge a dos
  destinos + mover, y el **bootstrap es el ÚLTIMO paso**, nunca el primero. Si corro el bootstrap
  antes de consolidar, mando a `.bak` memorias que aún no moví al repo.
- **(B) Recibir un repo ya armado** — clono en otra compu (la Mac, un compañero) un repo que YA
  trae su `memory/` y `skills/` commiteados. → Aquí el global de ese slug está vacío o es irrelevante;
  **solo corro el bootstrap** (un comando) y listo. No hay triage ni merge que hacer.

Regla mnemónica: **¿el repo ya tiene el cerebro completo? → (B), solo bootstrap. ¿Yo lo estoy
armando? → (A), Playbook y el bootstrap de cierre.**

## Receta para el modo personal (dir completo)
El **modo equipo** lo automatiza el bootstrap de abajo; esto es solo para el **modo personal**
(symlink del dir COMPLETO, transcripts incluidos), que el bootstrap no hace:
```bash
set -e
PROJ="$(pwd)"                                       # ruta LÓGICA (igual que el slug de CC)
SLUG="$(printf '%s' "$PROJ" | sed 's/[^a-zA-Z0-9]/-/g')"
SRC="$HOME/.claude/projects/$SLUG"                  # donde CC tiene hoy memoria/transcripts
DST="$PROJ/.claude"

mkdir -p "$DST/memory" "$DST/skills" "$DST/transcripts"

# 1) Consolida tus .md canónicos en $DST/memory (mueve REALES; dedup con `diff -q`, nunca rm a ciegas).
# 2) Symlink del dir COMPLETO (slug -> proyecto):
cp "$SRC"/*.jsonl "$DST/transcripts/" 2>/dev/null || true   # snapshot de transcripts
mv "$SRC" "$SRC.bak-premigracion"                           # respaldo (no se borra nada)
ln -s "$DST" "$SRC"                                         # slug -> proyecto

# 3) (opcional) Resolver una memoria desde OTROS cwd sin duplicar: symlink desde ese slug a la canónica.
#    ln -sfn "$DST/memory/<archivo>.md"  "$HOME/.claude/projects/<otro-slug>/memory/<archivo>.md"
```

## Bootstrap para el equipo (clonar y listo, sin drama)
Para que un compañero no tenga que entender la regla del slug ni armar el symlink a mano,
**commitea este script en el repo** como `<proyecto>/.claude/bootstrap-claude.sh` (modo equipo).
El script viene listo como **archivo real en la carpeta de este skill** (`bootstrap-claude.sh`):
cópialo tal cual al repo, no lo retransribas. Es idempotente (re-ejecutarlo es inocuo), portable
(Linux + macOS, `bash` 3.2), no hardcodea usuario ni rutas, y **nunca borra**: si encuentra
memoria previa la respalda. El bloque de abajo es solo para leerlo aquí; la fuente es el archivo.

> ⚠️ **El bootstrap NO fusiona.** Si encuentra un `memory/` previo en el slug, lo manda a un
> `.bak` y enlaza el del repo encima — no une contenidos. Por eso es seguro en el camino **(B)**
> (global vacío/irrelevante) y peligroso en el **(A)** sin haber consolidado antes: las notas del
> `.bak` quedan vivas en ningún lado hasta que las reconcilies a mano. Camino (A) → fusiona primero
> (Playbook), corre esto al final. Camino (B) → adelante, es el único paso.

```bash
#!/usr/bin/env bash
# bootstrap-claude.sh — enlaza el "cerebro" (memory/) de ESTE repo al lugar donde
# Claude Code lo busca por slug. Córrelo UNA vez tras `git clone`. Re-correrlo es seguro.
set -eu

# Raíz del repo = el dir padre de este script (vive en <repo>/.claude/).
# Rutas LÓGICAS (pwd sin -P): CC calcula el slug con la ruta tal cual la ve el shell ($PWD),
# SIN resolver symlinks. En macOS (iCloud/Drive bajo symlinks) resolverlos con -P daría un
# slug distinto al de CC y enlazaría el dir equivocado.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
TARGET="$REPO/.claude/memory"                       # memoria real, versionada

# Slug = ruta absoluta del repo con [^a-zA-Z0-9] -> '-'  (lo calcula CADA máquina)
SLUG="$(printf '%s' "$REPO" | sed 's/[^a-zA-Z0-9]/-/g')"
PROJ_DIR="$HOME/.claude/projects/$SLUG"
LINK="$PROJ_DIR/memory"

echo "repo : $REPO"
echo "slug : $SLUG"
echo "       (ojéalo: debe coincidir con el dir que CC tiene en ~/.claude/projects/)"

mkdir -p "$PROJ_DIR" "$TARGET"

# Ya enlazado correctamente -> nada que hacer
if [ -L "$LINK" ] && [ "$(readlink "$LINK")" = "$TARGET" ]; then
    echo "ok: memory ya apunta a $TARGET"
    exit 0
fi

# Había algo en el slug (dir real con notas, o symlink viejo) -> apártalo, no lo pierdas
if [ -e "$LINK" ] || [ -L "$LINK" ]; then
    BAK="$LINK.bak-$(date +%Y%m%d%H%M%S)"
    mv "$LINK" "$BAK"
    echo "warn: había memory previo -> respaldado en $BAK (revisa si guardaba notas tuyas)"
fi

ln -s "$TARGET" "$LINK"
echo "ok: enlazado $LINK -> $TARGET"
echo "    (skills/ y settings.json los lee CC solo al abrirse desde $REPO)"
```

**Cómo se reparte al equipo:**
1. Commitea `bootstrap-claude.sh` y el [bloque `.gitignore` canónico](#gitignore-canonico).
2. El compañero, tras `git clone`, corre **un comando**:
   ```bash
   bash .claude/bootstrap-claude.sh      # desde la raíz del repo (o con ruta completa)
   ```
3. Listo: su `memory/` queda enlazada calculando el slug de SU máquina (su ruta de clone puede
   diferir — el script lo resuelve e imprime el slug para ojearlo). Las `skills/` no las toca el
   script: funcionan solas porque CC lee `<cwd>/.claude/skills` al abrirse desde la raíz del repo.
   Sin "arranque amnésico", sin tocar el global a mano.

**Por qué es drama-free:** el slug se deriva localmente, así que funciona aunque cada quien clone
en una ruta distinta; es idempotente (CI o re-clones no rompen nada); respalda en vez de pisar; y
solo enlaza `memory` (skills/settings se leen nativos desde `<cwd>/.claude`, sin symlink).

## Playbook: aplicar a un repo que YA tiene memoria dispersa
Caso típico: el cerebro está partido entre `<repo>/.claude/memory/` (lo que ya se commiteó) y el
global `~/.claude/projects/<slug>/memory/` (memorias-auto que CC fue guardando y **no viajan**).
A menudo hay **dos `MEMORY.md` disjuntos** (no duplicados: cada lado lista cosas distintas). Pasos:

1. **Inventariar y comparar** ambos lados antes de mover nada — y hazlo contra el **estado real de
   la rama destino** (la que el PR mergeará, p.ej. `develop`), no contra otra rama. Un dry-run o un
   inventario contra la rama equivocada miente: vi en vivo que `develop` ya tenía una canónica que
   una rama vieja no, y por poco la duplico.
   ```bash
   git checkout develop && git pull          # parte del estado real
   diff <(ls "$repo/.claude/memory") <(ls ~/.claude/projects/"$slug"/memory)
   ```
2. **Triage de pertenencia y privacidad — ANTES de cualquier symlink.** Este paso es irreversible
   de hecho una vez corrido el bootstrap: cuando el slug se symlinkea al repo, **ya no hay un
   `memory/` global aparte** que separar — el global ES la carpeta del repo. Así que la separación
   se hace **ahora, físicamente**, no después. Lo que decide qué viaja es **dónde queda el archivo**
   y el `.gitignore`.

   **⚠️ Clasifica por CONTENIDO, no por el `type:` del frontmatter ni por el tema.** Una memoria
   `type: project` que *habla del repo* puede contener un secreto (vi en vivo una con un password
   RDP en texto plano y refs a una API key). Por eso, **antes** de mandar nada al repo, lee el
   cuerpo y aplica esta **precedencia dura**:
   > **Si contiene secretos / credenciales / rutas privadas → es SENSIBLE, aunque sea técnico y
   > del proyecto. Sensible GANA sobre de-proyecto.** Ante la duda, trátalo como sensible.

   Clasifica **tanto memorias como skills** en tres categorías:
   - **Del-proyecto** (técnica, útil al equipo, **sin secretos**) → memoria: archivo normal en
     `<repo>/.claude/memory/`; skill: carpeta en `<repo>/.claude/skills/`. **Se commitea y viaja.**
   - **Personal transversal** (cómo trabajo en *todos* los proyectos, no específico de este repo) →
     **no pertenece a este proyecto.** No hay un store de memoria global que CC auto-cargue fuera de
     `~/.claude/CLAUDE.md`, así que el destino real es **integrarla como instrucción en
     `~/.claude/CLAUDE.md`** (es una **reescritura** de formato-memoria → instrucción, no un `mv` de
     archivo). Skill transversal: sí es un `mv` a `~/.claude/skills/` (global). En ambos casos
     **sácala FÍSICAMENTE del slug-dir**; no basta con "no migrarla". (El backup del bootstrap es
     red de seguridad, no su hogar.)
   - **Personal/sensible del proyecto** (rutas privadas, credenciales, notas que quiero al trabajar
     aquí pero no compartir) → memoria: archivo **`*.local.md` dentro de `<repo>/.claude/memory/`**,
     excluido por el `.gitignore`. Vive junto al proyecto y viaja a mi Drive/Mac por el symlink, pero
     **git no lo trackea**, así no llega al equipo. **No lo indexes en el `MEMORY.md` commiteado**
     (ese índice sí viaja → puntero colgante para quien clona); si quieres índice de lo local, uno
     aparte también gitignored (`MEMORY.local.md`).

   **Desempate proyecto-vs-transversal** (frontera difusa, p.ej. una preferencia de terminal en un
   repo que *es* de config de terminal): si el equipo se beneficiaría de saberlo para tocar ESTE
   repo → de-proyecto; si solo describe el gusto o el entorno de una persona → transversal. **Ante
   duda real, pregúntale al dueño en vez de adivinar** — clasificar mal aquí ensucia el repo o
   pierde una preferencia.

   En repo privado de una sola persona puedes commitear todo y filtrar luego (salvo secretos, que
   nunca); el triage importa cuando el repo se comparte.
3. **Merge = ruteo con reconciliación a DOS destinos, simultáneo.** Esto es lo que de verdad hace el
   "merge", y conviene tenerlo clarísimo: no es solo "volcar lo del repo en el repo". Es separar el
   montón disperso y **fusionar cada mitad en su hogar correcto, sin pérdida**:
   - **Hacia el repo** (`<repo>/.claude/`): une lo del-proyecto. Si el repo YA tenía `memory/`
     (los dos `MEMORY.md` disjuntos del caso típico), **fusiónalos en uno**: une índices, deduplica
     líneas, no pierdas entradas de ningún lado. Igual para skills del-proyecto. **Reconciliar ≠
     deduplicar:** si dos memorias afirman cosas DISTINTAS del mismo objeto (lo vi en vivo: un
     `MEMORY.md` decía repo `unjordi/scripts` y otro `unjordi/PowerScripts`), no arrastres ambas —
     **resuelve el conflicto** (pregunta al dueño si no es obvio cuál es la verdad actual).
   - **Hacia el global** (`~/.claude/`): lo personal/transversal que saqué en el paso 2 **no se tira:
     se fusiona en el scope de usuario** (su `CLAUDE.md`/memoria global o `~/.claude/skills/`),
     reconciliando con lo que ya viva ahí (puede haber versión previa → unir, no duplicar).
   Resultado: dos lugares quedan consistentes a la vez (repo = cerebro del proyecto; global = lo mío
   transversal), y nada quedó botado. El `*.local.md` del paso 2 es un tercer destino (sensible,
   junto al repo pero gitignored). **Recuerda: el bootstrap NO hace nada de esto** — este merge es
   manual/mío, y ocurre ANTES del bootstrap.
4. **Mover los archivos reales** a donde los ruteó el paso 3: memorias y skills del-proyecto →
   `<repo>/.claude/{memory,skills}/`; lo transversal → su hogar global. Deduplica con `diff -q`;
   lo que sobre va a una `.trash/`, **nunca `rm` a ciegas**.
5. **Commitear el bootstrap** (`<repo>/.claude/bootstrap-claude.sh`) y el
   [bloque `.gitignore` canónico](#gitignore-canonico).
6. **Correr el bootstrap** para que el slug-dir deje de ser dir real y pase a symlink → repo
   (el script respalda lo previo solo).
7. **Auditar (gate) + verificar** — corre la **Auditoría semántica** de abajo y la **Verificación**
   técnica; **no declares "ya quedó" hasta que ambas pasen**. Luego abre **rama + PR** según el flujo
   de git del repo (nunca commit directo a `main`/`develop` si esa es la norma). Si la rama activa
   tiene trabajo sin commitear, usa un **worktree** (`git worktree add`) para no perturbarla.

## Skills: global vs proyecto
- **Específica de un proyecto** → `<proyecto>/.claude/skills/` (se autocarga solo trabajando ahí).
- **Transversal / metodología** (como esta misma) → global en `~/.claude/skills/` (aplica a todo).
No pongas la misma skill en ambos lados (colisión de nombre): elige una ubicación canónica.

**Gotcha (visto en vivo):** Claude Code carga como skill **toda subcarpeta de `~/.claude/skills/`
(o `<repo>/.claude/skills/`) que tenga un `SKILL.md`**. Por eso un respaldo o copia ahí dentro
(`mi-skill.bak-…/`) aparece como **skill fantasma duplicado**. Los backups/copias de skills van
**FUERA** del árbol de skills (p. ej. `~/.claude/skill-backups/`).

## Gotchas
- **Migración a media sesión** parte el transcript vivo (CC reabre el archivo por ruta): si puedes,
  hazlo entre sesiones. Si no, guarda un **snapshot** y deja un **backup** del slug-dir hasta verificar.
- **Disco extraíble / red**: si el proyecto vive en un volumen que se desmonta, el symlink del slug
  queda colgando mientras está desmontado (irrelevante porque tampoco trabajas el proyecto sin él).
  Disco fijo / carpeta sincronizada local = sin problema.
- **macOS = igual**: `~/.claude` es `/Users/<tú>/.claude`. **Nunca hardcodees** usuario ni rutas
  absolutas en las memorias/skills compartidas — usa `~`/`$HOME` y rutas relativas, o no viajarán.
- **settings**: lo específico de máquina va en `settings.local.json` (no se comparte); lo común del
  proyecto en `settings.json`.
- **Anti-duplicados**: antes de descartar una copia, `diff -q`; manda a una `.trash/`, no `rm`.

## Auditoría semántica (gate: NO declarar "ya quedó" sin pasar esto)
La Verificación de abajo es técnica (¿el symlink existe?). Esto es lo otro: **¿el cerebro quedó
coherente?** Antes de decirle al dueño que terminé, confirmo punto por punto (si algo falla, lo
arreglo, no lo reporto como hecho):
- **🔴 Escaneo de secretos (BLOQUEO DURO).** Antes de commitear, revisa el contenido de TODO lo que
  va al repo trackeado (memorias + skills), no solo su título:
  ```bash
  grep -rinE 'pass(word|wd)?|secret|token|api[_-]?key|credential|credencial|\.env\b|[:=][[:space:]]*["]?[A-Za-z0-9+/]{20,}={0,2}' \
       <repo>/.claude/memory <repo>/.claude/skills
  ```
  (La 1ª mitad son keywords de alta señal; la 2ª caza valores de alta entropía SOLO si son
  asignados — `clave: AbC…` / `KEY="AbC…"` — para no marcar cada ruta o palabra larga.) Revisa
  cada acierto: si es un secreto **real** → por defecto ese archivo es **sensible**, va a
  `*.local.md` (o se redacta el valor), **nunca se commitea**. Aciertos por la mera palabra
  "password" en prosa se descartan.
  - **Excepción: override explícito del dueño.** En un repo privado el dueño puede *aceptar
    conscientemente* dejar un secreto trackeado (lo vi en vivo: un password en una memoria ya
    commiteada, "dale chance de vivir"). Entonces NO es bloqueo — pero **regístralo** (en el
    `*.local.md`, en la memoria del repo, o donde el dueño lleve estas decisiones) para **no volver
    a preguntarle lo mismo cada vez** que corra el gate. Sin override registrado → sigue siendo
    bloqueo duro: no declares hecho con un secreto sin decidir en lo trackeado.
  - **⚠️ El gate del HARNESS puede vencer al override de memoria.** Aparte de este gate del skill,
    el clasificador de permisos de Claude Code (nivel plataforma) puede **BLOQUEAR duro** un commit que
    escriba un secreto literal, y **no lo desbloquea un override que solo vive en una memoria** — exige
    autorización explícita del usuario en *esta* sesión. Visto en vivo 2026-07-01: el password `quesoqueso`
    estaba aceptado ("dale chance de vivir") en una memoria, pero el harness igual bloqueó el push. La
    salida cuando pasa esto (y el usuario no re-autoriza en la sesión): **redactar** el literal a un
    placeholder (`<VM_PASS>`) en TODO lo trackeado y poner el valor real en un `*.local.md` (gitignored),
    y **actualizar la nota de override** para reflejar que ya se redactó (si no, queda contradictoria).
- **🔴 El `.gitignore` REALMENTE ignora lo sensible (verificación dura, no visual).** Tras escribirlo:
  ```bash
  git check-ignore .claude/memory/ZZ.local.md   # debe imprimir la ruta = ignorado
  git status --short .claude/ | grep -i 'local.md' && echo "FUGA: un .local.md es visible para git"
  ```
  Si un `*.local.md` aparece en `git status`, NO está protegido (típico: comentario en línea que
  rompió el patrón) → arréglalo antes de seguir. Un secreto en un `.local.md` no-ignorado se filtra
  igual que si lo hubieras commiteado a mano.
- **Reconciliar hechos contradictorios:** si dos memorias afirmaban cosas distintas del mismo objeto,
  el resultado debe tener UNA versión coherente (resuelta con el dueño), no las dos.
- **Sin memorias duplicadas** entre el global y el repo: ningún `.md` con el mismo contenido
  viviendo en dos sitios (`diff -q`); la canónica está en un solo lugar. **Caso real visto:** una
  memoria-resumen "para recall" que apunta a una canónica que YA vive en el repo (`> ver
  project_x.md`) es redundante una vez consolidado → **no la copies al repo, descártala** (su valor
  era cuando el repo no era accesible; con el symlink, la canónica siempre lo está).
- **Ninguna skill en los dos lados**: una skill no puede estar a la vez en `~/.claude/skills/` y en
  `<repo>/.claude/skills/` (colisión de nombre); cada una en su hogar único (proyecto vs transversal).
- **`MEMORY.md` ↔ archivos reales cuadran**: cada línea del índice apunta a un archivo que existe,
  y cada memoria real está indexada. Sin entradas fantasma ni archivos huérfanos.
- **Sin `[[links]]` colgantes** salvo los intencionales (marcadores a futuro); ningún link a una
  memoria que se movió de lugar.
- **El `MEMORY.md` commiteado NO referencia ningún `*.local.md`** (ese índice viaja; el local no).
- **Lo transversal/sensible ya NO está en lo trackeado por git** (ni en `memory/` commiteado ni en
  skills del repo): de verdad se fue a su hogar global o a `*.local.md`.
- **Nada quedó vivo solo en un `.bak`/`.trash`**: lo que debía sobrevivir ya está en su destino
  real; los respaldos son red de seguridad, no el hogar de nada.

## Verificación
```bash
readlink ~/.claude/projects/<slug>            # → <proyecto>/.claude  (modo personal)
find -L <proyecto>/.claude -type l            # → sin symlinks rotos
ls -lL <proyecto>/.claude/memory/             # → MEMORY.md + memorias reales, legibles
```
Prueba real: abre una **sesión nueva** desde la carpeta del proyecto y confirma que (a) recuerda el
contexto sin escarbar y (b) aparecen las skills del proyecto al escribir `/`.

## Rollback
Todo reversible; nada único se borra (vive en backups/`.trash/` hasta confirmar):
- **Modo personal** (dir completo): `rm ~/.claude/projects/<slug>; mv ~/.claude/projects/<slug>.bak-premigracion ~/.claude/projects/<slug>`.
- **Modo equipo** (bootstrap): borra el symlink `memory` y restaura el respaldo que dejó el script:
  `rm ~/.claude/projects/<slug>/memory; mv ~/.claude/projects/<slug>/memory.bak-<timestamp> ~/.claude/projects/<slug>/memory`.

## Para el onboarding del equipo (resumen compartible)
> **Convención:** cada proyecto guarda su cerebro de Claude Code en `<repo>/.claude/`
> (`memory/`, `skills/`, `settings.json` versionados; transcripts, `settings.local.json` y
> `*.local.md` gitignored — ver bloque canónico). Tras `git clone`, corre
> **`bash .claude/bootstrap-claude.sh`** una vez → memoria y skills compartidas al instante,
> sin "arranques amnésicos". Re-correrlo es seguro.

_(Destilada del proyecto BibliotecaDigital, jun 2026: ahí el cerebro estaba disperso entre el global
`~/.claude/projects/-home-…` y la carpeta del proyecto en Drive; consolidarlo en `<proyecto>/.claude/`
+ symlink resolvió los arranques amnésicos.)_
