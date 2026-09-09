# Procedencia de `src/term-broker/` — copia vendorizada desde axon, HOY CON UN PARCHE PROPIO

Los cinco `.ts` de esta carpeta salieron como **copia byte-a-byte** de módulos del repo `axon`, y la
regla sigue siendo *no se editan aquí*: lo normal es cambiarlos en axon y re-vendorizar (abajo está
el comando). **Hoy hay UNA excepción viva y pendiente de portar** — léela antes de re-vendorizar
nada: [Divergencia vs axon](#divergencia-vs-axon--pendiente-de-portar).

| archivo | origen en axon | líneas (al vendorizar) | líneas (hoy) |
|---|---|---|---|
| `term-host-broker.ts` | `src/server/term-host-broker.ts` | 394 | 475 |
| `term-session.ts` | `src/server/term-session.ts` | 263 | 307 |
| `term-pty-bridge.ts` | `src/server/term-pty-bridge.ts` | 70 | 91 |
| `ws.ts` | `src/server/ws.ts` | 306 | 400 |
| `pty-session.ts` | `src/server/pty-session.ts` | 188 | 206 |
| | **total** | **1221** | **1479** |

**Commit de origen:** `341fb53` (`origin/develop` de axon, 2026-09-07). Re-vendorizado desde
`cf840e6` para traer el **socket unix** (`fix/term-broker-alcanzable`, #75): un cliente en
contenedor NO alcanza un bind a loopback del host, así que la copia anterior servía un broker que la
terminal del widget no podía usar. De paso llegan `GET /health` (lo que sondea el badge) y el
manejo de error de `listen()` — que en la copia anterior faltaba: `EADDRINUSE` es asíncrono, el
`try/catch` de `main()` no lo veía, un `'error'` sin listener reventaba como excepción no capturada,
y el log *"escuchando en …"* se imprimía **antes** de que el bind hubiera tenido éxito. O sea: en el
escenario central de esta migración —el puerto ya ocupado— el journal decía "escuchando" y a
renglón seguido escupía un stack trace.

Los `sha256` de la copia viven en [`SHA256SUMS`](SHA256SUMS), al lado. No es decoración: es lo que
se **verifica**.

## Divergencia vs axon — PENDIENTE DE PORTAR

Estos módulos ya **no** son byte-a-byte iguales a axon `341fb53`. Se les añadió aquí, en cortex, los
**topes** del broker (rama `feat/broker-topes`): techo de sesiones de shell concurrentes, techo de
PTYs concurrentes, y **backpressure** en el relay del WebSocket. El qué y el porqué están en
[`docs/term-broker.md` § Topes](../../docs/term-broker.md); el detalle, en los comentarios de cada
módulo. Los cinco archivos tocados:

| archivo | qué se le agregó |
|---|---|
| `term-session.ts` | `maxSessions` + rechazo `SESSION_LIMIT` + `size`/`limit` |
| `term-host-broker.ts` | techo de PTYs (`503` en el handshake), cableado de las env `MAX_*`, y `uncaughtException`/`unhandledRejection` en `main()` |
| `ws.ts` | `bufferedBytes`/`backpressured`/`onDrain`/`pause`/`resume` + válvula dura de buffer |
| `term-pty-bridge.ts` | pausar el PTY (y el socket peer, en el relay WS↔WS) cuando el destino no drena |
| `pty-session.ts` | `pause()`/`resume()` sobre la salida del PTY |

**Lo que esto implica, dicho sin adornos:** el `diff` contra axon ya no da vacío, y una
re-vendorización *ingenua* (copiar los cinco desde axon encima de éstos) **borraría los topes en
silencio** — el broker volvería a no tener ninguno y nadie se enteraría hasta la siguiente fuga. Las
dos salidas, en orden de preferencia:

1. **Portar el parche a axon** (`src/server/{term-session,term-host-broker,ws,term-pty-bridge,pty-session}.ts`)
   y re-vendorizar desde ese commit. Es la buena: axon corre EL MISMO código en su modo contenedor
   (ver el punto 2 de "Por qué COPIA…", abajo), así que hoy el broker de cortex tiene topes y el
   shell contenerizado de axon **no**.
2. Si se re-vendoriza antes de portar: **re-aplicar este parche a mano** sobre la copia nueva, y
   correr `probe-topes.ts` (abajo) para comprobar que sigue vivo. Nunca dar por buena una copia
   nueva sin ese probe en verde.

El chequeo (1) de la sección siguiente (`sha256sum -c SHA256SUMS`) **sigue sirviendo y sigue verde**:
sus hashes se regeneraron con esta copia, así que protege de lo que siempre protegió — un edit
accidental *aquí* que nadie declaró. Lo que ya no puede afirmar es "idéntico a axon"; eso lo dice el
chequeo (2), que a partir de hoy va a reportar DRIFT hasta que el parche esté portado. **Es correcto
que lo reporte** — el drift existe, y está documentado en esta sección. Y ninguno de los dos afirma
"compila": un edit declarado (como este mismo parche) puede pasar (1) y (2) igual de verde y no
typechecar — de hecho ya pasó una vez, ver el chequeo (3) más abajo.

Los topes tienen su propia prueba funcional, que no depende de nada instalado:

```bash
node --disable-warning=ExperimentalWarning --experimental-strip-types src/term-broker/probe-topes.ts
```

## El anti-drift, que ahora SÍ se ejecuta

Había un problema con el chequeo que vivía aquí: nadie lo corría, y apuntaba a `origin/develop` —una
ref **móvil**—, así que "idéntico" solo significaba "idéntico a lo que develop tenga hoy", que es
otra cosa que "idéntico a lo que dice este archivo". Se parte en tres, y las dos primeras son
automáticas:

**(1) ¿La copia local sigue siendo la que se vendorizó?** Lo corre `probe-instalador.sh` en cada
pasada (check *"módulos idénticos a la fuente"*), y no necesita un clon de axon:

```bash
cd src/term-broker && sha256sum -c SHA256SUMS
```

Éste es el que atrapa el riesgo REAL de una copia vendorizada: que alguien "arregle" un módulo
**aquí** en vez de en axon, y la copia deje de ser copia sin que nada se queje.

**(2) ¿axon cambió desde el commit anotado?** Necesita un clon, y se corre a mano cuando toca
re-vendorizar. Contra el **commit fijado**, no contra la punta móvil:

```bash
VEND=341fb53   # el commit anotado arriba — NO 'origin/develop'
for f in term-host-broker term-session term-pty-bridge ws pty-session; do
  diff <(git -C ~/code/axon show $VEND:src/server/$f.ts) src/term-broker/$f.ts >/dev/null \
    && echo "$f: idéntico al commit vendorizado" || echo "$f: DRIFT vs el commit vendorizado"
done
# y qué se ha movido en axon desde entonces (lo que faltaría por traer):
git -C ~/code/axon diff --stat $VEND origin/develop -- src/server/{term-host-broker,term-session,term-pty-bridge,ws,pty-session}.ts
```

Re-vendorizar = copiar los 5 desde el nuevo commit, regenerar `SHA256SUMS`
(`sha256sum term-host-broker.ts term-session.ts term-pty-bridge.ts ws.ts pty-session.ts > SHA256SUMS`),
actualizar el commit y las líneas de la tabla de arriba, y el commit en `NOTICE`.

**(3) ¿Los 5 módulos COMPILAN?** Es la que faltaba, y la razón de que exista: (1) y (2) verifican que
la copia sea idéntica a algo (a sí misma ayer, o al commit de axon) — **ninguna de las dos ejecuta el
código ni lo typechequea**, así que un edit *declarado* y con hashes regenerados podía tener un error
de tipos y las dos seguir en verde. Pasó de verdad: el parche de topes usaba `opts.maxSessions` en
`term-session.ts` sin declararlo en `ShellSessionPoolOptions` — vivió así hasta que el mismo código se
typechequeó del lado de axon, porque esta carpeta corre con `node --experimental-strip-types` (nunca
pasa por `tsc`). Ahora lo corre `probe-instalador.sh` en cada pasada (check *"tsc --noEmit sale limpio
sobre los 5 módulos"*):

```bash
tsc --noEmit --target ES2022 --module ES2022 --moduleResolution bundler --lib ES2023 --strict \
  --esModuleInterop --skipLibCheck --forceConsistentCasingInFileNames --allowImportingTsExtensions \
  --resolveJsonModule --typeRoots <ruta-a-@types-de-axon> --types node \
  term-host-broker.ts term-session.ts term-pty-bridge.ts ws.ts pty-session.ts
```

cortex no trae `tsc` propio a propósito (cero deps de npm es parte del diseño de esta carpeta, ver
"Por qué COPIA…" punto 4 más abajo), así que el chequeo reutiliza el `tsc` que ya trae axon —el propio
repo de origen de estos módulos, normalmente clonado como hermano de cortex— con las mismas
`compilerOptions` de su `tsconfig.json` (no se pueden pasar junto con una lista explícita de archivos:
TypeScript lo rechaza con `TS5042`, de ahí que se repliquen a mano). **Si no hay un `tsc`+`@types/node`
verificable a mano** (máquina limpia, sin axon clonado al lado, o axon sin `npm install` corrido), el
chequeo se **SALTA con un aviso explícito** en la salida del probe — no se instala una dependencia
nueva ni se falla en falso solo porque falte una herramienta opcional.

**Lo que (3) protege y lo que NO:** atrapa cualquier error de tipos en los 5 módulos, lo haya
introducido un patch de cortex o una re-vendorización mal aplicada. No sustituye a (1) ni a (2): un
módulo puede typechecar perfecto y aun así haber divergido de axon en runtime (p. ej. un `any`
disfrazando un bug de lógica), o haber sido editado aquí sin declararlo — para eso siguen (1) y (2).

Como la copia es byte-a-byte, ese `diff` es el chequeo completo: cualquier cambio en axon aparece
como un diff legible, no como "a ver quién cambió qué". Por eso **no** se tocan los comentarios
(hablan de axon/Odysseus/maincar: es correcto, ése es el cliente) — ni siquiera los que a un lector
de cortex le sobran.

---

## Por qué COPIA y no "cortex instala un artefacto que axon publica"

Se evaluaron las dos y ganó la copia, por razones medibles — no por comodidad:

1. **El cierre de dependencias son 5 módulos, no 4.** El inventario previo decía
   "`term-host-broker` + `term-session` + `term-pty-bridge` + `ws` = 860 líneas". Falta
   `pty-session.ts` (188): `term-pty-bridge.ts:15` lo importa (`spawnPty`). El total real era 1048
   con aquel commit; con el vendorizado de hoy (`341fb53`, socket unix + `/health`) son **1221**.
2. **Cuatro de los cinco NO se pueden "mover": axon los sigue necesitando.** El contrato exige que
   axon **degrade** al shell del contenedor cuando no hay token, y esa ruta usa exactamente los
   mismos módulos (`src/server/http-server.ts`: `ShellSessionPool` de `term-session.ts`,
   `servePtyOverWs`+`relayWsToWs` de `term-pty-bridge.ts`, `acceptWebSocket`/`rejectWebSocket`/
   `wsConnect` de `ws.ts`; y `term-pty-bridge` arrastra `pty-session.ts`). Solo
   `term-host-broker.ts` (394 líneas, el `main()` + los dos listeners) es exclusivo del servidor. O sea:
   **la duplicación existe pase lo que pase**; lo único que se decide es si cortex la obtiene por
   copia versionada o por descarga.
3. **El artefacto invertiría la dependencia justo al revés de #26i.** cortex es el lado ESTABLE del
   contrato (se instala con `curl … | bash`, sin Node ni npm garantizados, y de él dependen los
   guardarraíles de la máquina). Hacer que su instalador dependa de un release de axon —un harness
   experimental, iterado a diario— acopla el agente de máquina al ciclo del harness. El diseño de
   #26i dice lo contrario: cortex expone la capacidad, axon la consume.
4. **Vendorizar aquí no tiene el costo típico de vendorizar.** El costo normal (parches de
   seguridad de dependencias, lockfiles, builds) no aplica: **cero dependencias de npm**, solo
   builtins `node:`, y se ejecuta sin transpilar (`node --experimental-strip-types`). No hay
   `npm ci` que empaquetar ni artefacto que firmar.
5. **Lo que NO debe driftear es el WIRE, no el código.** Los dos lados están acoplados por el
   protocolo (SSE `{type:"stdout"|"stderr",chunk}` / `{type:"exit",code}` / `[DONE]`, y el canal WS
   con frames BINARY=bytes / TEXT=JSON de control), documentado idéntico en ambos repos. Un probe
   de cualquiera de los dos lados detecta un cambio de wire; el código fuente idéntico no es lo que
   da la garantía.

**Lo que la copia cuesta, dicho sin adornos:** un arreglo hecho en axon (como el de PATH del
2026-09-04, `buildSessionEnv`) no llega solo a cortex — hay que re-vendorizar. El `diff` de arriba
es el mecanismo para notarlo; no es automático.

## Por qué las env vars siguen llamándose `AXON_TERM_BROKER_*` en un servicio de cortex

Parece incoherente y es deliberado, por dos razones:

1. **Son el contrato con el cliente.** `AXON_TERM_BROKER_URL` / `AXON_TERM_BROKER_TOKEN` es lo que
   lee `http-server.ts` de axon y lo que pasa el `docker-compose`. Renombrarlas rompería la
   terminal en uso y obligaría a cambiar el compose — justo lo que este traslado promete no hacer.
2. **Seguridad concreta:** `buildSessionEnv()` (`term-session.ts:58-71`) borra del entorno de cada
   shell de usuario `ANTHROPIC_API_KEY` y **todo lo que empiece con `AXON_`**. El token del broker
   se limpia hoy *por ese prefijo*. Si en cortex se llamara `CORTEX_TERM_BROKER_TOKEN`, dejaría de
   ser barrido y **aparecería en el `env` de cada terminal del widget**. El nombre del servicio sí
   cambia (`cortex-term-broker.service`); el de las variables no.
