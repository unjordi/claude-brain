---
name: checkpoint
description: Volcado del estado efímero a memoria durable para poder compactar (o cerrar sesión) sin perder el hilo, en DOS NIVELES. LIGERO (pausas naturales, punto de retorno rápido) reescribe hilo-mental-actual.md —leyendo antes el previo para no pisar ideas vivas a medio cocinar— (de qué va la tarea AHORA) y GARANTIZA, antes de sobrescribir, que todo pendiente/decisión DURABLE del hilo ya esté en estado-proyecto.md + bitácora (barrido SIN PÉRDIDA: el hilo volátil sube al backlog durable, nunca al revés). COMPLETO (OBLIGATORIO antes de cualquier /compact —manual o anunciado por el aviso de contexto— y cada ~2h en corridas largas) abre con el 🗂️ ÁRBOL de memorias+tooling (3 ramas: actualizadas-hoy / a-leer-para-lo-que-sigue / tooling) al PRINCIPIO y luego agrega el PLAN COMPLETO con el CÓMO, lo RESUELTO HOY y la COSECHA DURABLE a memorias/skills. Es el "volcado compartido" que cerrar-slice §2 también hace. Ante la duda de nivel: COMPLETO.
---

# Checkpoint — vaciar lo efímero a memoria durable (sin fricción)

Un **checkpoint** vuelca lo que solo vive en el contexto del chat (frágil: se pierde al compactar) a
archivos durables en disco, para que **compactar cuanto quieras NO cueste el hilo**. Es la mitad
"escribir" del par; la mitad "leer" la hace el hook `rehidratar-hilo` (SessionStart) al retomar.

> **Por qué existe.** Al compactar se pierden DOS cosas y solo una tenía casa. El **estado del
> proyecto** (hecho/pendiente/decidido) ya vivía en `estado-proyecto.md`/`bitacora.md`. El **HILO de
> la conversación** (qué razonamos AHORA, la decisión a medio cocinar, el siguiente paso, el porqué)
> no vivía en ningún lado durable → se degradaba en cada resumen del LLM. `hilo-mental-actual.md` es
> su casa. Con el hilo en disco, la compactación deja de ser el único portador del contexto real.

## Los DOS NIVELES (y cómo elegir)

- **LIGERO** — pausas naturales, punto de retorno rápido. El hilo terso (memorias/tooling en lista
  simple + en qué estamos / decisión abierta / siguiente paso / hilos sueltos) + estado-proyecto/
  bitácora si avanzó. Cuesta segundos.
- **COMPLETO** — **OBLIGATORIO antes de cualquier `/compact`** (manual, o cuando el hook
  `aviso-contexto` anuncie que viene) **y cada ~2h en corridas largas/nocturnas**. Abre con el
  **🗂️ ÁRBOL de memorias + tooling** (ver abajo) y, además del hilo terso, el `hilo-mental-actual.md`
  crece con TRES secciones (PLAN COMPLETO con el CÓMO · RESUELTO HOY · COSECHA DURABLE — ver abajo) y
  la cosecha a memorias/skills se hace COMO PARTE del checkpoint.

**Criterio de elección:** ¿viene un compact? ¿llevas >2h de corrida? ¿la implementación que sigue es
crítica? → **COMPLETO**. ¿Pausa casual entre sub-pasos? → ligero. **Ante la duda, COMPLETO**:
sub-volcar cuesta una noche (pasó de verdad); sobre-volcar cuesta 2 minutos.

## Por qué el nivel COMPLETO funciona (anatomía del descubrimiento)

Nació de un descubrimiento de unjordi (2026-07-18): antes de un compact crítico, en vez del checkpoint
terso, le pidió a su Claude — *"puedes hacer una memoria super temporal con TODO lo que tienes planeado
ahorita, todos los pendientes, el mecanismo y detalles de cómo los quieres resolver, y toda la lista de
cosas que resolvimos hoy? y actualizar las memorias y skills de etl? haciendo eso ya podemos hacer el
compact con calma"* — y funcionó "perfecto de perfectolandia". La anatomía de por qué:

En el contexto viven **3 tipos de estado**, y el resumen del compact solo trata bien uno:
1. **La narrativa** — lo único que el resumen conserva (con pérdida).
2. **Las intenciones procedimentales** — el PLAN con su CÓMO. Lo MÁS frágil: un resumen conserva
   "pendiente: X" pero amputa "lo iba a resolver con Y porque Z". Por eso el PLAN se vuelca completo.
3. **Lo RESUELTO** — decisiones ya tomadas. Si no se escriben, **reviven como pendientes fantasma**
   tras compactar (caso real: frenaron una noche entera de ETL). Por eso la sección anti-fantasma.

El volcado **en las PROPIAS palabras del modelo** permite re-instanciarse releyendo textual, en vez de
reconstruir desde un resumen ajeno (= confabular). Y "actualizar memorias/skills" **desaloja del canal
volátil lo que tiene casa durable** → reduce lo que el compact puede siquiera perder.

## Cuándo correrlo
- **Antes de un `/compact` manual** — lo más importante. **Nivel COMPLETO, sin excepción.**
- Cuando el aviso de contexto (`aviso-contexto`) anuncie que el compact viene → **COMPLETO**.
- Cada **~2h en corridas largas/nocturnas** → **COMPLETO** (el auto-compact no avisa).
- En una **pausa natural** (terminaste un sub-paso, vas a cambiar de tema) → ligero basta.
- Cuando quieras dejar un **punto de retorno** por si la sesión se corta → ligero basta.
- ⚠️ El **auto-compact** (contexto lleno) no te avisa a TI, y `PreCompact` no puede darte un turno para
  que TÚ vuelques el juicio (no tiene canal para inyectar contexto ni pedirte actuar). Por eso el
  checkpoint es **proactivo**, no de último momento: si vienes trabajando rato, vuelca aunque no vayas a
  compactar todavía. Lo que SÍ pasa en ese evento, sin tu turno: `checkpoint-mecanico.sh` (hook de
  `PreCompact`) deja el andamio mecánico escrito — ver "Qué NO es" abajo — así que aunque el auto-compact
  te gane la carrera, el 🗂️ árbol/RESUELTO-HOY/citas del usuario no dependen solo de que TÚ alcanzaras a volcar.

## Qué hace (el volcado)

> **GARANTÍA DURA (answer-first): un checkpoint NUNCA pierde nada durable al sobrescribir el hilo.**
> `hilo-mental-actual.md` es VOLÁTIL y este volcado lo PISA — así que **antes de sobrescribirlo, barre el
> hilo y sube todo pendiente/decisión DURABLE a `estado-proyecto.md`** (o el backlog durable del repo). La
> flecha va en UNA dirección: **hilo (volátil) → SUBE al backlog (durable), NUNCA al revés** (el hilo jamás
> genera ni pisa el HUD/backlog desde la memoria volátil de un Claude — eso invertiría la fuente de verdad).
> Recién entonces el hilo se puede TIRAR sin perder nada. Mecánica y matices en el paso 2.

0. **REGENERA el andamio mecánico y LÉELO (primer paso, ambos niveles).** Antes de escribir una sola
   línea del hilo:
   ```bash
   node "$(ls ~/.local/bin/checkpoint-mecanico.js ~/.cortex/bin/checkpoint-mecanico.js 2>/dev/null | head -1)" \
        --self --ensure          # regenera SOLO si quedó atrás del transcript; si no, dice "no-op"
   cat .claude/memory/hilo-mental-actual.andamio.md
   ```
   **Por qué es TU paso y no solo del hook** (restricción dura de unjordi, textual: *"no que PreCompact
   sea el único mecanismo"*): el hook `checkpoint-mecanico` solo corre en `PreCompact`, y la mayoría de
   los checkpoints NO vienen de una compactación (medido: ~5 volcados por cada compact). Sin este paso,
   un `/checkpoint` a mano encuentra el andamio viejo **o ausente, sin poder distinguir cuál** — un
   insumo de frescura desconocida presentado como vigente, que es justo el modo de falla que el gate del
   hilo existe para evitar. Con `--ensure`, el andamio SIEMPRE está al día cuando lo lees, venga o no de
   un compact. (Dentro de un SUBAGENTE `--self` se niega a correr y lo dice: el `CLAUDE_CODE_SESSION_ID`
   que ve un subagente es el del PADRE y regeneraría el andamio de otra sesión.)
   El andamio te da GRATIS y sin gastar ventana: el 🗂️ árbol de archivos tocados (los de Write/Edit y,
   aparte, los escritos desde Bash), las skills invocadas, los `git commit` del tramo y **las últimas
   citas TEXTUALES del usuario** — la materia prima de la PROCEDENCIA `[user: "…"]`, que reconstruida de
   memoria es justo donde se lava una idea tuya en la voz del usuario. Su ventana es el **TRAMO VIVO**
   (desde el último `/compact`): describe lo que está por perderse, no el acumulado de semanas.
   **NO lo copies al hilo**: es evidencia, no juicio. Lo FUSIONAS tú, con criterio, en los pasos de abajo.

1. **El HILO (siempre, ambos niveles).** Va a `.claude/memory/hilo-mental-actual.md` (créalo si no
   existe: `mkdir -p .claude/memory`). No es log ni backlog — es "de qué va ESTO ahora mismo".

   **LEE el hilo previo ANTES de sobrescribir (read-before-overwrite — paso OBLIGATORIO).** El archivo
   existe justo para cargar ideas a medio cocinar a través de un compact; pisarlo a ciegas puede BORRAR
   el único vestigio de una. Así que antes de reescribir, lee sus secciones vivas ("Decisión abierta",
   "Siguiente paso", "Hilos sueltos") y **fusiona en el volcado nuevo lo que el nuevo NO cubra.** Para
   cada ítem del hilo previo ausente del volcado nuevo, el criterio conservar-vs-descartar es:
   - **¿Sabes POR QUÉ ya no está?** (lo resolviste / se decidió / quedó superado esta tanda — puedes
     nombrar qué pasó) → descártalo; su cierre vive en `RESUELTO HOY`.
   - **¿NO puedes dar cuenta de él?** (no lo reconoces, no sabes qué le pasó — señal de que se cayó del
     contexto) → **consérvalo textual en el volcado nuevo**: el hilo en disco es su posible ÚNICO rastro.
   - **Ante la duda, CONSERVAR.** Arrastrar un ítem de más cuesta una línea que luego se limpia sin
     costo al reconstruir el estado real; perder una idea la pierde para siempre.

   Estructura (el 🗂️ ÁRBOL y las tres últimas secciones, SOLO en nivel COMPLETO):
   ```markdown
   # Hilo mental actual
   > Se REESCRIBE conservando lo vivo del previo, no se appendea. Última actualización: <FECHA> · rama <rama> · nivel <ligero|COMPLETO>.
   > Si el hilo pasa de ~200 líneas: corta el excedente a `hilo-mental-actual-overflow.md` y AVÍSALO aquí (ver "Regla de OVERFLOW" abajo).

   ## 🗂️ ÁRBOL — memorias y tooling (SIEMPRE al principio · LÉELO PRIMERO al rehidratar)
   <!-- LIGERO: basta una LISTA simple de las memorias/skills/scripts que el tema toca, cada una con su RUTA, agrupada por sub-tema. -->
   <!-- COMPLETO: el ÁRBOL de 3 ramas, en un bloque de código para leerlo de un vistazo (modelo de la firma-árbol del CLAUDE.md canónico): -->
   ```
   📁 MEMORIAS ACTUALIZADAS HOY (<fecha>) — <dónde viven: ramita/MR/repo si aplica>
   ├─ <ruta de la memoria> ......... <qué cambió, en UNA línea>
   └─ ...
   📁 INSUMOS A LEER PARA LO QUE SIGUE — <de qué tarea/expediente, con su ruta base>
   ├─ <ruta> ....................... <por qué leerlo / qué aporta>
   └─ ...
   🔧 TOOLING INTEGRADO / RELEVANTE
   ├─ <script/skill/herramienta + RUTA> ... <qué hace / estado (desplegado, en MR, pendiente)>
   └─ <accesos y comandos clave (ssh, URLs, puertos)>
   ```
   ## En qué estamos AHORA
   <1-3 líneas: la tarea viva y su porqué>
   ## Decisión abierta / lo que razonamos
   <la pregunta a medio cocinar, opciones sobre la mesa>
   ## Siguiente paso concreto
   <la próxima acción — con punto de entrada al código si aplica>
   ## Hilos sueltos / no olvidar
   <pequeños pendientes de contexto que el resumen perdería>

   <!-- ▼ SOLO nivel COMPLETO ▼ -->
   ## PLAN COMPLETO (con el CÓMO)
   <TODO lo planeado, ítem por ítem: qué + el MECANISMO de resolución pensado + detalles, gotchas y
    porqués — a fidelidad completa, en TUS propias palabras. NO telegráfico: es lo que te vas a
    releer para re-instanciarte tras el compact. Cada ítem lleva su PROCEDENCIA (ver abajo).>
   ## RESUELTO HOY (no reabrir)
   <decisiones tomadas + su porqué + su PROCEDENCIA en una línea cada una. El ANTI-FANTASMA: lo que
    está aquí NO se re-pregunta ni se re-descubre después de compactar.>
   ## COSECHA DURABLE (hecha en esta tanda)
   <qué se promovió EN ESTE checkpoint a su casa durable — memorias del proyecto, skills tocados —
    con sus rutas. La promoción se hace COMO PARTE del checkpoint completo, no "después".>
   ```
   Pon la **FECHA real** (córrela con `date` de bash, NO el metadato de sesión): `rehidratar-hilo` la muestra al retomar para que juzgues si el hilo quedó viejo.

   **VERIFICA el contrato al terminar de escribir (paso mecánico, 1 comando).** El footer
   `> Última actualización: <AAAA-MM-DD> · rama <rama> · nivel <x>` no es decoración: `rehidratar-hilo`
   decide con él si tu hilo se reinyecta como VIGENTE o degradado a "⚠️ POSIBLEMENTE OBSOLETO". Medido el
   2026-09-11 sobre los 9 hilos reales de `~/code`: **2 de 9 no lo traían** ⇒ su hilo VIGENTE se presenta
   como obsoleto en cada rehidratado. Córrelo y arregla lo que marque:
   ```bash
   . ~/.claude/hooks/contrato-hilo.sh && verificar_hilo .claude/memory/hilo-mental-actual.md
   ```

   **🗂️ ÁRBOL de memorias + tooling al PRINCIPIO (regla dura).** El hilo SIEMPRE abre con las memorias
   durables + herramientas/scripts que el tema toca, **cada una con su RUTA** — es la lista "lee esto al
   rehidratar" (antídoto a declarar "ya rehidraté" sin leer la memoria del tema, lección cara) y evita
   re-grepear el árbol cada vez. Va como PRIMERA sección, antes de "En qué estamos". La FORMA depende del
   nivel:
   - **LIGERO** — una **lista simple** con rutas, agrupada por sub-tema. Basta para un punto de retorno rápido.
   - **COMPLETO** — el **🗂️ ÁRBOL de 3 ramas** en un bloque de código (modelo de la firma-árbol del
     `CLAUDE.md` canónico), para que se lea de un vistazo: **📁 MEMORIAS ACTUALIZADAS HOY** (lo que tocaste
     esta tanda, con su ramita/MR) · **📁 INSUMOS A LEER PARA LO QUE SIGUE** (lo que hay que abrir para
     retomar la tarea activa) · **🔧 TOOLING INTEGRADO / RELEVANTE** (scripts/skills/accesos, con su estado).
     La prosa "sin drama" (En qué estamos / Decisión abierta / Siguiente paso …) va DESPUÉS del árbol.
     Origen de este formato: unjordi, 2026-08-25 — *"así deberíamos hacerlo siempre… actualiza tu skill
     drifteante"* tras ver un checkpoint con este árbol al principio.
   - **Anti-drift (sub-regla dura): cuando una memoria se MUEVE / FUSIONA / RENOMBRA, sincroniza el árbol/
     lista en la MISMA tanda** — igual que `RESUELTO HOY` registra el cambio, el puntero de MEMORIAS debe
     reflejarlo, o se contradicen dentro del mismo hilo y la lista deja de ahorrarte el grep (su único
     propósito). Es doc=realidad aplicado al propio hilo. Y al CONTESTAR "¿qué memorias hay de X?",
     **arranca de esta lista como HUD** y verifica/extiende contra disco — no grepees desde cero ignorándola.
     (Lección real 2026-08-20: la lista quedó con los 5 slugs viejos de red mientras `RESUELTO` ya decía
     "fusión hecha" → se grepeó el árbol de todos modos.)

   **⚠️ Regla de OVERFLOW (>~200 líneas) `[SIN CONFIRMAR — dato de docs, validar el límite exacto]`.** El
   import/autostart del hilo al arrancar sesión **trunca pasando las ~200 líneas**. Si `hilo-mental-actual.md`
   supera ~200 líneas, corta el excedente a `hilo-mental-actual-overflow.md` (mismo dir) y **MENCIÓNALO en las
   primeras líneas del hilo principal** ("…continúa en overflow"), para que el rehidratado sepa que hay más y
   lo lea. En el principal deja lo VIVO (🗂️ árbol de memorias/tooling, en qué estamos, decisión abierta,
   siguiente paso); al overflow van PLAN/RESUELTO/COSECHA extensos.

   **⭐ Estándar de calidad — 9 ejes (canónicos; corpus de pedidos reales en `corpus-checkpoint-frases.local.md`).**
   Un buen checkpoint es: **COMPLETO** (nada del hilo fuera) · **MINUCIOSO** (las minucias que si no re-descubrirías)
   · **ACCIONABLE** (datos/rutas/comandos/siguiente-paso, no descripción) · **DURABLE** (en piedra, para NO
   necesitar desinflado) · **SIN EDITORIALIZAR** (seco, solo hechos) · **SIN RESUMIR** (literales, no comprimir)
   · **SEGUIDO/PROACTIVO** (antes del techo, no de último momento) · **A SUS CASAS** (a cada destino durable que
   toque) · **CON PROCEDENCIA**. Anti-patrones: volátil · editorializado · resumido · escatimado en detalle
   técnico · contaminado con temas irrelevantes · de último momento.

   **PROCEDENCIA de cada idea (regla dura — el hilo mental DE LA IDEA, no solo el stub).** Cada ítem del
   PLAN y cada decisión de RESUELTO llevan de DÓNDE salió y QUIÉN la originó, con un marcador breve:
   `[user: "<cita textual>"]` si es del usuario · `[INFER-mío]` si es una hipótesis/propuesta TUYA (de
   Claude) · `[juntos <fecha>]` si se decidió en conversación. **Por qué:** al comprimir se pierde la
   procedencia y el default es re-leerse la idea PROPIA como si fuera del usuario ("unjordi cree X") →
   se lava una hipótesis tuya en su voz, primo hermano de fabricar autorización (viola la norma de
   autorización acotada y NO-transitiva). Marcar la procedencia hace que el LINAJE viaje CON la idea a
   través del compact. Regla dura al re-resumir: **nunca conviertas un `[INFER-mío]` en un `[user]`**; si
   no recuerdas el origen, es `[INFER-mío]` (conservador), no del usuario.
2. **El estado del proyecto — BARRIDO SIN PÉRDIDA del hilo → durable (GARANTÍA DURA, ambos niveles).**
   Antes de que el paso 1 pise el hilo, **barre el hilo entero y asegura que TODO pendiente y TODA
   decisión DURABLE que viva en él ya esté en `estado-proyecto.md`** (o el backlog durable equivalente del
   repo — `estado-y-pendientes.md`; y `bitacora.md` para lo que YA pasó). Es la dirección correcta de la
   flecha — **hilo (volátil) SUBE a estado-proyecto.md (durable), nunca al revés** —, la misma separación
   dura del skill `/to-do` (**el HUD/hilo = vista SCRATCH; el backlog durable = fuente de verdad**) y la
   norma "ninguna DECISIÓN se queda solo en el chat". Así la sobrescritura del hilo queda **SIN PÉRDIDA**:
   lo que legítimamente se descarta del hilo (paso 1) ya está a salvo en el durable. Mecánica: igual que
   `cerrar-slice §2` — mueve ítems en `estado-proyecto.md` (hecho/pendiente/decidido) y **appendea UNA
   línea al FINAL** de `bitacora.md` con `>>` (`printf '%s\n' '- …' >> bitacora.md`), **no** con un Edit
   que reescriba (así varias sesiones no se pisan). Lo puramente EFÍMERO (el micro-paso siguiente, un
   razonamiento a medio cocinar SIN decisión aún) NO necesita subir — vive en el hilo y lo cuida el
   read-before-overwrite del paso 1; **ante la duda de si algo es durable, SUBE** (barato de limpiar, caro
   de perder). El BARRIDO en sí NO es opcional; si tras barrer no queda nada durable sin subir, el
   checkpoint puede ser solo-hilo.
3. **doc = realidad (vistazo).** Si en esta tanda cambiaste comportamiento/config/rutas, actualiza la
   doc que lo describe en la MISMA tanda (no lo dejes para después).
4. **La cosecha durable (solo COMPLETO).** Antes de cerrar el volcado, pregúntate: *¿qué de lo que
   traigo en contexto ya tiene casa durable?* — un aprendizaje que va a una memoria del proyecto, un
   gotcha que va a un skill, una decisión de infra que va a su doc. **Promuévelo AHORA, como parte del
   checkpoint** (no lo agendes), y regístralo en `## COSECHA DURABLE` con sus rutas. Lo que ya vive en
   disco es lo único que el compact no puede perder.

## Qué NO es
- **No es `cerrar-slice`.** Checkpoint es SOLO el volcado; no verifica build/tests, no abre MR, no
  cosecha aprendizajes de cierre de slice. Cuando de verdad terminaste un slice, usa `cerrar-slice`
  (que hace este mismo volcado + esas etapas). Checkpoint es el "guarda punto" de en medio — ligero o
  completo, sigue siendo un punto de retorno, no un cierre.
- **No sustituye la disciplina del JUICIO.** `PreCompact` no puede inyectar contexto ni darte un turno
  — por eso ningún hook puede escribir el "en qué estamos / decisión abierta / siguiente paso" por ti;
  eso sigue siendo tuyo, vía esta skill. Lo que SÍ hace un hook (C1/M2, auditoría 2026-09-11): en ese
  MISMO evento, `checkpoint-mecanico.sh` YA corre (detached, cero tokens de modelo) y deja escrito
  `.claude/memory/hilo-mental-actual.andamio.md` — el 🗂️ árbol de archivos tocados, los mensajes de
  `git commit`, las citas textuales del usuario y las métricas de sesión, sacados del transcript sin
  criterio. **Al hacer el checkpoint, REGENÉRALO y LÉELO primero (paso 0), y FUSIÓNALO** al volcado (no
  lo copies a ciegas: sigue siendo un borrador mecánico, no el hilo). Y si el compact te GANA la carrera,
  ya no se pierde: `rehidratar-hilo` (SessionStart) inyecta el andamio junto al hilo cuando es MÁS FRESCO
  que él, con encabezado propio y etiquetado como evidencia — nunca como si fuera tu razonamiento. Tú
  sigues poniendo el juicio; el andamio te ahorra el grep. `aviso-contexto` además te lo RECUERDA cuando
  el contexto sube.

## Compartido vs local
`hilo-mental-actual.md` es memoria de trabajo **VOLÁTIL** (se sobrescribe seguido) y personal de tu
stream de trabajo. En repos **COMPARTIDOS** conviene **gitignorearlo** (per-dev, como los `*.local.md`)
para no generar conflictos de merge entre devs. El estado durable COMPARTIDO son
`estado-proyecto.md`/`bitacora.md`. El continuo cross-sesión del hilo (que es lo que este skill
protege) es para TU hilo, no el del equipo.
