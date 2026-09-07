# El broker de terminal (`cortex-term-broker.service`) — opt-in, Linux

> **Lee esto antes de instalarlo.** Este servicio sirve **un shell de tu computadora** en un puerto
> local. No es una sandbox. Está apagado por defecto y solo se instala si lo pides con
> `./install.sh --con-term-broker`.

## Qué es y por qué vive en cortex

El widget de Terminal de Odysseus habla con `axon`, que corre **dentro de un contenedor**. Un shell
lanzado ahí es el shell **del contenedor**: sin `~/code`, sin tus credenciales, sin tus
herramientas — otra cosa, y menos útil. Las alternativas para arreglarlo eran darle al contenedor
acceso al host (`--pid=host`, `/` montado, `docker.sock`), que es exactamente dejar de tener un
contenedor.

La salida es un **broker**: un proceso nativo, del lado de la máquina, que expone esa capacidad por
un contrato acotado (loopback + token) en vez de por un agujero en el aislamiento. Y un shell de la
máquina anfitriona **no es una pieza de un harness: es infraestructura per-máquina** — que es
justo el trabajo de cortex (hooks globales, servicios de usuario, config que no viaja en el git de
un proyecto). Por eso vive aquí y no en axon.

El reparto queda:

| | quién |
|---|---|
| el **servidor** (este servicio, los módulos, la unidad, el token) | **cortex** |
| el **cliente** (reenviar al broker si hay token; degradar al shell del contenedor si no) | **axon** |

axon no instala, no arranca y no es dueño del broker. Y si el token no está, **axon degrada solo**
al shell del contenedor: no falla.

## Esto cambia el PERFIL de cortex — dicho en voz alta

Hasta aquí, cortex era un **recolector periódico**: su único servicio (`cortex.service`) es
`Type=oneshot`, lo dispara un `.timer` cada 5 minutos, corre unos segundos y muere.

El broker es otra clase de cosa: **`Type=simple`, vivo 24/7, con `Restart=on-failure`, y padre de
procesos del usuario** (un shell persistente por sesión del widget, y PTYs reales vía `script`).
cortex pasa de recolector a **host de procesos**. Consecuencias que importan:

- **La memoria del cgroup es la de tus sesiones, no la del broker.** Medido en la unidad previa que
  corría lo mismo: **3.4 GB en uso, pico de 56 GB** — porque adentro corrían sesiones de trabajo
  reales. Por eso la unidad trae `MemoryAccounting=yes` pero **no** un `MemoryMax`: un tope aquí
  mataría tu trabajo, no un leak. Se mide para verlo:
  `systemctl --user show cortex-term-broker -p MemoryCurrent -p MemoryPeak`.
- **`OOMPolicy=continue`**: si el OOM killer se lleva UNA sesión, el broker sigue vivo con las
  demás. Con el default (`stop`) systemd pararía el servicio entero.
- **Parar el servicio mata las sesiones** (`KillMode` en su default `control-group`). Es lo
  correcto —son hijos suyos— pero significa que `systemctl --user restart` cierra las terminales
  abiertas. Trátalo como tal.

## Postura de seguridad (léela, no la asumas)

El broker ejecuta **literalmente** lo que le llega, con tu login shell, como tu usuario. Las
defensas son dos, y **ninguna es una sandbox**:

1. **Token obligatorio.** Sin `AXON_TERM_BROKER_TOKEN` el proceso **no arranca** (nunca hay un modo
   "sin auth por accidente"). Cada request se responde `401` **antes** de leer el body o tocar el
   shell. El token lo **genera el instalador** (32 bytes de `openssl rand` o `/dev/urandom`) en
   `~/.config/cortex/term-broker.env` con modo `0600`. **No hay token por defecto ni horneado en el
   repo**, y una reinstalación **no lo regenera**.
2. **Bind solo a loopback** (`127.0.0.1`), jamás `0.0.0.0`. Alcanzable desde la propia máquina, o
   desde un contenedor con `--add-host=host.docker.internal:host-gateway`.

No hay whitelist de comandos: **quien tenga el token puede correr cualquier cosa como tú.** Trátalo
como una llave SSH. No expongas el puerto más allá de loopback ni relajes el bind.

Un detalle de higiene que sí está resuelto: el shell de cada sesión arranca con
`buildSessionEnv()`, que **borra `ANTHROPIC_API_KEY` y todo lo que empiece con `AXON_`** del
entorno — así el token del broker no aparece en el `env` de tu terminal. (Es también la razón por la
que las variables se siguen llamando `AXON_*` en un servicio de cortex: ver
[`../src/term-broker/PROCEDENCIA.md`](../src/term-broker/PROCEDENCIA.md).)

## Instalar

```bash
./install.sh --con-term-broker        # opt-in; sin la bandera no se instala NADA de esto
```

Requiere **Linux** (usa `script` de util-linux para el PTY, tu login shell y `systemd --user`), y
`node` ≥ 22 (los módulos corren sin transpilar con `--experimental-strip-types`; **cero
dependencias de npm**). En macOS/Windows la bandera falla ruidosamente en vez de saltarse en
silencio: instala sin ella y el resto de cortex funciona igual.

Qué deja puesto:

| qué | dónde |
|---|---|
| los 5 módulos (`.ts`, vendorizados) | `~/.local/lib/cortex/term-broker/` |
| el lanzador | `~/.local/bin/cortex-term-broker` |
| el token (0600, generado) | `~/.config/cortex/term-broker.env` |
| la unidad | `~/.config/systemd/user/cortex-term-broker.service` |

## Compartir el token con el cliente

El instalador **no** escribe en el `.env` de nadie (no sabe dónde vive tu compose): imprime qué
pegar. En el `.env` del cliente (axon):

```
AXON_TERM_BROKER_URL=http://host.docker.internal:8799
AXON_TERM_BROKER_TOKEN=<el valor de ~/.config/cortex/term-broker.env>
```

Para copiarlo sin imprimir el secreto en la terminal:

```bash
grep '^AXON_TERM_BROKER_TOKEN=' ~/.config/cortex/term-broker.env >> /ruta/al/.env/del/cliente
```

Sin `AXON_TERM_BROKER_TOKEN`, axon degrada al shell del contenedor y el widget lo reporta honesto
(`GET /api/axon/term/mode` → `container`). Con token → `host`.

## Migración desde la unidad vieja (`axon-term-broker.service`)

Hay máquinas donde una sesión instaló **a mano** una unidad `axon-term-broker.service` apuntando a
un clon de axon (`WorkingDirectory=…/axon-run`, rutas absolutas). Esa unidad **no es de cortex**:
el instalador la **consulta** (para no arrancar dos brokers en el mismo puerto 8799) pero **nunca
la apaga ni la borra** — puede haber una terminal en uso.

Si `install.sh --con-term-broker` la encuentra activa, deja todo instalado y la unidad
**habilitada pero sin arrancar**, y te lo dice. El cambio lo haces tú, cuando no estorbe:

```bash
# 0. Confirma que no hay una terminal en uso que te importe perder.
systemctl --user status axon-term-broker.service

# 1. Copia el token VIEJO al archivo nuevo, para que el cliente NO tenga que cambiar nada:
grep '^AXON_TERM_BROKER_TOKEN=' ~/.config/axon/maincar.env > ~/.config/cortex/term-broker.env
chmod 600 ~/.config/cortex/term-broker.env
#    (o quédate con el token NUEVO que generó el instalador y actualiza el .env del cliente)

# 2. Apaga la vieja y levanta la nueva, en ese orden (comparten el puerto 8799):
systemctl --user disable --now axon-term-broker.service
systemctl --user start cortex-term-broker.service

# 3. Verifica.
systemctl --user status cortex-term-broker.service
curl -s -o /dev/null -w '%{http_code}\n' -X POST http://127.0.0.1:8799/run \
     -H 'Content-Type: application/json' -d '{"cmd":"true"}'     # debe dar 401 (sin token)
```

**Revertir** (si algo sale mal, la unidad vieja sigue en disco hasta que la borres):

```bash
systemctl --user stop cortex-term-broker.service
systemctl --user enable --now axon-term-broker.service
```

Solo cuando la nueva lleve un rato bien: `rm ~/.config/systemd/user/axon-term-broker.service &&
systemctl --user daemon-reload`.

**Un detalle que el cambio arregla de paso:** la unidad legacy carga
`EnvironmentFile=~/.config/axon/maincar.env`, un archivo COMPARTIDO que además del token trae
`ANTHROPIC_API_KEY` y varias `AXON_*` del harness — todas terminan en el entorno del proceso que
lanza tus shells. (No llegan a la terminal: `buildSessionEnv()` las barre del hijo. Pero están en el
padre sin necesidad.) La unidad de cortex lee un archivo **dedicado** que contiene **solo el token**.
Al migrar, copia la LÍNEA del token — no el archivo entero.

## Desinstalar

`./uninstall.sh` lo retira **siempre**, sin bandera aparte (unidad, lanzador, módulos). El token se
va con `~/.config/cortex` salvo que pases `--keep-cfg`. La unidad legacy de axon, si la hay, **no**
se toca.

## Probar

Dos pruebas funcionales, ambas sin tocar ningún servicio del sistema:

```bash
bash src/term-broker/probe-instalador.sh   # instalador en un HOME sandbox: opt-in, token, idempotencia
bash src/term-broker/probe-broker-vivo.sh  # levanta el broker en :18799 y le habla de verdad
```

`probe-instalador.sh` corre el `install.sh` REAL con `HOME` en un temporal y `systemctl`/`kpackagetool6`
como stubs que solo registran: prueba que **sin** la bandera no queda nada, que **con** ella queda todo
(token 0600, unidad con `%h`), que es idempotente y que `uninstall.sh` lo retira — sin tocar el systemd
real. `probe-broker-vivo.sh` levanta el broker desde el clon en `:18799` (nunca el 8799 del servicio) y
verifica el 401 sin token, el wire SSE de `/run`, la persistencia de la sesión, el canal PTY sobre
WebSocket (`probe-pty-ws.ts`) y que el bind sea solo loopback.

## De dónde sale el código

`src/term-broker/*.ts` es una copia **byte-a-byte** de módulos de axon, con el commit de origen y
los `sha256` anotados, más el argumento de por qué copia y no artefacto:
[`../src/term-broker/PROCEDENCIA.md`](../src/term-broker/PROCEDENCIA.md).
