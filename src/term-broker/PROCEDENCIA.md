# Procedencia de `src/term-broker/` — copia VENDORIZADA desde axon

Los cinco `.ts` de esta carpeta son una **copia byte-a-byte** de módulos del repo `axon`. No se
editan aquí: si hay que cambiarlos, se cambian en axon y se re-vendorizan (abajo está el comando).

| archivo | origen en axon | líneas |
|---|---|---|
| `term-host-broker.ts` | `src/server/term-host-broker.ts` | 230 |
| `term-session.ts` | `src/server/term-session.ts` | 263 |
| `term-pty-bridge.ts` | `src/server/term-pty-bridge.ts` | 70 |
| `ws.ts` | `src/server/ws.ts` | 297 |
| `pty-session.ts` | `src/server/pty-session.ts` | 188 |
| | **total** | **1048** |

**Commit de origen:** `cf840e625edfdd408e0ec2b573a3fc941c3c84c2` (`origin/develop` de axon, 2026-09-07).

```
bbf2362427eac1035de4e88b204740221a0b8ec74216212ecd3d2b066c570d5c  pty-session.ts
f2c7b9c3717ea08b77511b8e002e14cfc0fa86dcd5e8a6b0895bec2fabd541f6  term-host-broker.ts
7175a4966b4a6351ef349ce4dcc9f382931374d10ce43bb9904c439f8a7ba711  term-pty-bridge.ts
791affbea4c74238c2adc68bda2823f87b55d3ff53064baddffcf77d82a10987  term-session.ts
fd3cc4c43b50359b3595a5784adac540acb5705e240982b52047fa1312f9f119  ws.ts
```

**Verificar drift** (desde un clon de axon, sin salir de la terminal):

```bash
for f in term-host-broker term-session term-pty-bridge ws pty-session; do
  diff <(git -C ~/code/axon show origin/develop:src/server/$f.ts) src/term-broker/$f.ts \
    && echo "$f: idéntico" || echo "$f: DRIFT"
done
```

Como la copia es byte-a-byte, ese `diff` es el chequeo completo: cualquier cambio en axon aparece
como un diff legible, no como "a ver quién cambió qué". Por eso **no** se tocan los comentarios
(hablan de axon/Odysseus/maincar: es correcto, ése es el cliente).

---

## Por qué COPIA y no "cortex instala un artefacto que axon publica"

Se evaluaron las dos y ganó la copia, por razones medibles — no por comodidad:

1. **El cierre de dependencias son 5 módulos, no 4.** El inventario previo decía
   "`term-host-broker` + `term-session` + `term-pty-bridge` + `ws` = 860 líneas". Falta
   `pty-session.ts` (188): `term-pty-bridge.ts:15` lo importa (`spawnPty`). El total real es 1048.
2. **Cuatro de los cinco NO se pueden "mover": axon los sigue necesitando.** El contrato exige que
   axon **degrade** al shell del contenedor cuando no hay token, y esa ruta usa exactamente los
   mismos módulos (`src/server/http-server.ts`: `ShellSessionPool` de `term-session.ts`,
   `servePtyOverWs`+`relayWsToWs` de `term-pty-bridge.ts`, `acceptWebSocket`/`rejectWebSocket`/
   `wsConnect` de `ws.ts`; y `term-pty-bridge` arrastra `pty-session.ts`). Solo
   `term-host-broker.ts` (230 líneas, el `main()` + el servidor) es exclusivo del servidor. O sea:
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
