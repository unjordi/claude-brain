# Procedencia de `src/term-broker/` — copia vendorizada desde axon, HOY CON UN PARCHE PROPIO

Los cinco `.ts` de esta carpeta salieron como **copia byte-a-byte** de módulos del repo `axon`, y la
regla sigue siendo *no se editan aquí*: lo normal es cambiarlos en axon y re-vendorizar (abajo está
el comando). La divergencia que hubo con los topes **ya está saldada**; queda registrada abajo porque
explica QUÉ hacer al re-vendorizar: [Divergencia vs axon](#divergencia-vs-axon--saldada-2026-09-08).

| archivo | origen en axon | líneas (al vendorizar) | líneas (hoy) |
|---|---|---|---|
| `term-host-broker.ts` | `src/server/term-host-broker.ts` | 394 | 498 |
| `term-session.ts` | `src/server/term-session.ts` | 263 | 307 |
| `term-pty-bridge.ts` | `src/server/term-pty-bridge.ts` | 70 | 91 |
| `ws.ts` | `src/server/ws.ts` | 306 | 483 |
| `pty-session.ts` | `src/server/pty-session.ts` | 188 | 307 |
| | **total** | **1221** | **2121** |

**Commit de origen:** `8719248` (rama `feat/broker-conciliar-axon-cortex` de axon, 2026-09-08) — el
commit en que los topes de esta copia ya viven río arriba. Antes fue `341fb53` (2026-09-07), re-vendorizado desde
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

## Divergencia vs axon — SALDADA (2026-09-08)

Hubo un rato en que estos módulos **no** eran byte-a-byte iguales a axon: aquí se les añadieron los
**topes** del broker (techo de sesiones, techo de PTYs, backpressure en el relay) mientras axon avanzaba
por su lado (manejo de error de `listen()`, socket unix, cola de resizes). El `diff` no daba vacío en
ninguna de las dos direcciones, y eso dejaba una trampa: **re-vendorizar copiando encima desde axon
habría borrado los topes en silencio**.

Se resolvió por la vía buena, la que esta misma sección recomendaba: **portar el parche a axon** —con un
merge a 3 vías tomando como base el commit del que se vendorizó, que entró limpio en los cinco módulos— y
re-vendorizar desde ahí. Hoy la copia vuelve a ser byte-a-byte de axon, y axon corre EL MISMO código en su
modo contenedor, así que el shell contenerizado ya no se queda sin topes.

De paso, la conciliación destapó un **error de tipos** que aquí no podía verse: el parche usaba
`opts.maxSessions` sin declararlo en `ShellSessionPoolOptions`. Estos módulos corren con
`--experimental-strip-types` y nunca pasan por `tsc`; axon sí typechequea, y lo cazó al primer intento.
Ésa es la razón de que el anti-drift de abajo tenga un tercer chequeo pendiente: los hashes prueban
"nadie editó esto a escondidas", no "esto compila".

**La regla no cambia:** los cinco `.ts` **no se editan aquí**. Se cambian en axon y se re-vendorizan.
Después de cada re-vendorización, correr el probe de topes — es lo que comprueba que el mecanismo sigue
vivo, y no darlo por hecho:

```bash
node --disable-warning=ExperimentalWarning --experimental-strip-types src/term-broker/probe-topes.ts
```

## El anti-drift, que ahora SÍ se ejecuta

Había un problema con el chequeo que vivía aquí: nadie lo corría, y apuntaba a `origin/develop` —una
ref **móvil**—, así que "idéntico" solo significaba "idéntico a lo que develop tenga hoy", que es
otra cosa que "idéntico a lo que dice este archivo". Se parte en dos, y la primera es automática:

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
