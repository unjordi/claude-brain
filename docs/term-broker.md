# El broker de terminal (`cortex-term-broker.service`) — opt-in, Linux

> **Lee esto antes de instalarlo.** Este servicio sirve **un shell de tu computadora** por un socket
> local y un puerto de loopback. No es una sandbox. Está apagado por defecto y solo se instala si lo
> pides con `./install.sh --con-term-broker`.

## Qué es y por qué vive en cortex

El widget de Terminal de Odysseus habla con `axon`, que corre **dentro de un contenedor**. Un shell
lanzado ahí es el shell **del contenedor**: sin `~/code`, sin tus credenciales, sin tus
herramientas — otra máquina, y menos útil. Las alternativas para arreglarlo eran darle al contenedor
acceso al host (`--pid=host`, `/` montado, `docker.sock`), que es exactamente dejar de tener un
contenedor.

La salida es un **broker**: un proceso nativo, del lado de la máquina, que expone esa capacidad por
un contrato acotado (socket local + token) en vez de por un agujero en el aislamiento. Y un shell de
la máquina anfitriona **no es una pieza de un harness: es infraestructura per-máquina** — que es
justo el trabajo de cortex (hooks globales, servicios de usuario, config que no viaja en el git de
un proyecto). Por eso vive aquí y no en axon.

El reparto queda:

| | quién |
|---|---|
| el **servidor** (este servicio, los módulos, la unidad, el token) | **cortex** |
| el **cliente** (reenviar al broker si hay token; reportar el modo real si no) | **axon** |

axon no instala, no arranca y no es dueño del broker.

## Los DOS transportes (y por qué no basta el puerto)

El broker abre **dos listeners sobre el mismo handler y el mismo pool de shells**:

| transporte | quién lo usa | dónde |
|---|---|---|
| **socket unix** | el cliente **en contenedor** (el caso real) | `$XDG_RUNTIME_DIR/axon/term-broker.sock`, modo `0600` |
| **TCP loopback** | clientes **nativos** del host | `127.0.0.1:8799` |

El socket unix no es redundancia: **es el que hace funcionar la terminal.** Un contenedor NO alcanza
un bind a `127.0.0.1` del host — en Linux `host.docker.internal` resuelve a la gateway de Docker, no
a loopback —, y abrir el puerto a la red sería exponer ejecución de comandos arbitrarios detrás de
una regla de firewall que vive fuera del repo. El socket no tiene dirección de red: se alcanza solo
montándolo en el contenedor, y lo protegen los permisos del filesystem.

Dos consecuencias que ya costaron una terminal muerta y están resueltas en la unidad:

- **Se monta el DIRECTORIO, no el archivo.** Un bind-mount de archivo se ata al inodo, y el broker
  recrea el socket en cada arranque: con el archivo montado, el primer `restart` deja al contenedor
  hablándole a un inodo muerto (`ECONNREFUSED`).
- **`RuntimeDirectory=axon` + `RuntimeDirectoryPreserve=yes`.** Lo primero hace que *systemd* cree
  `/run/user/<uid>/axon` con tu usuario **antes** del `ExecStart`: si no, gana el primero que llegue,
  y si el stack de Docker levanta antes, Docker crea el directorio como `root:root` y el broker no
  puede escribir el socket (`listen EACCES`). Lo segundo evita que systemd lo **borre** al parar el
  servicio — si desapareciera, el mount del contenedor quedaría atado a un inodo muerto.

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
- **Un fallo permanente termina en `failed`, no en un bucle.** `Restart=on-failure` + `RestartSec=3`
  con los defaults de systemd (burst 5 en 10 s) da ~3 arranques por ventana: nunca alcanza el burst,
  nunca cae en `failed`, y cicla para siempre en silencio contra un error que no se va a curar
  (puerto ocupado, socket de otro broker, `node` ausente). Por eso la unidad fija
  `StartLimitIntervalSec=60` + `StartLimitBurst=5`: agota la ventana en ~15 s y **se rinde diciéndolo**.

## Postura de seguridad (léela, no la asumas)

El broker ejecuta **literalmente** lo que le llega, con tu login shell, como tu usuario. Las
defensas son dos, y **ninguna es una sandbox**:

1. **Token obligatorio, en los dos transportes.** Sin `AXON_TERM_BROKER_TOKEN` el proceso **no
   arranca** (nunca hay un modo "sin auth por accidente"). Cada request se responde `401` **antes**
   de leer el body o tocar el shell. El token lo **genera el instalador** (32 bytes de
   `openssl rand` o `/dev/urandom`) en `~/.config/cortex/term-broker.env` con modo `0600`. **No hay
   token por defecto ni horneado en el repo**, y una reinstalación **no lo regenera**.
2. **Nada expuesto a la red.** El socket unix va en `0600` (solo tu usuario), y el listener TCP
   bindea `127.0.0.1`. `AXON_TERM_BROKER_BIND` existe pero **cualquier valor que no sea loopback es
   exponer RCE**; el broker lo grita en el journal si lo cambias.

No hay whitelist de comandos: **quien tenga el token puede correr cualquier cosa como tú.** Trátalo
como una llave SSH.

**Higiene del entorno, con su alcance exacto.** El shell de cada sesión arranca con
`buildSessionEnv()` (`src/term-broker/term-session.ts`), que borra del entorno del hijo
`ANTHROPIC_API_KEY` y **todo lo que empiece con `AXON_`**. Eso cubre el token del broker *porque se
llama `AXON_TERM_BROKER_TOKEN`* — y ésa es toda la garantía: una coincidencia entre el nombre de la
variable y un literal en un módulo. Por eso el nombre **no se cambia** aunque el servicio sea de
cortex (ver [`PROCEDENCIA.md`](../src/term-broker/PROCEDENCIA.md)) y por eso `probe-broker-vivo.sh`
lo **prueba**: pide un `env` en una sesión real, verifica que ni el valor ni el nombre del token
aparezcan, y con un **control positivo** (una variable gemela sin el prefijo, que SÍ se filtra)
demuestra que el check no es vacío. Lo que ese barrido **no** hace es sanear el resto del entorno:
lo demás que traiga el `EnvironmentFile` del servicio sí llega al shell. Y **no aplica al modo
contenedor**: ahí no hay broker, el shell lo abre axon dentro de su propio contenedor y lo que se
hereda es el entorno de ESE proceso.

## Instalar

```bash
./install.sh --con-term-broker        # opt-in; sin la bandera no se instala NADA de esto
```

Requiere **Linux** (usa `script` de util-linux para el PTY, tu login shell y `systemd --user`), y
`node` ≥ 22 (los módulos corren sin transpilar con `--experimental-strip-types`; **cero
dependencias de npm**). La bandera se valida **en el paso 0**, pegada al parseo de argumentos: si
falta `node` o `script`, el instalador aborta **antes de escribir nada** en vez de dejar el resto de
cortex instalado y quejarse al final.

Qué deja puesto:

| qué | dónde |
|---|---|
| los 5 módulos (`.ts`, vendorizados) | `~/.local/lib/cortex/term-broker/` |
| el lanzador | `~/.local/bin/cortex-term-broker` |
| el migrador | `~/.local/bin/migrar-term-broker.sh` |
| el token (0600, generado) | `~/.config/cortex/term-broker.env` |
| la unidad | `~/.config/systemd/user/cortex-term-broker.service` |

**En otros sistemas operativos** — dicho con precisión, porque aquí este documento mentía
(afirmaba que la bandera "falla ruidosamente" en macOS y Windows; no es así en ninguno de los dos):

| | qué pasa con `--con-term-broker` |
|---|---|
| **Linux** (`./install.sh`) | instala. Si falta un prerrequisito, **aborta ruidoso en el paso 0**. |
| **macOS** (`macos/install.sh`) | **avisa y sigue**: imprime que es Linux-only e instala el resto de cortex. No aborta — la bandera llega ahí por el pass-through de `bootstrap.sh`, y tumbar la instalación entera por una bandera inaplicable sería peor. |
| **Windows** (`bootstrap.ps1`) | **la bandera no llega nunca.** `bootstrap.ps1` se corre con `irm … \| iex`, que no admite argumentos, y llama a `windows\install.ps1` sin ninguno. Invocando el script directo, `windows\install.ps1 -ConTermBroker` **avisa** que es Linux-only en vez de morir con "a parameter cannot be found". |

## Compartir el token con el cliente

El instalador **no** escribe en el `.env` de nadie (no sabe dónde vive tu compose): imprime qué
pegar. Para un cliente **en contenedor** (el caso real) hacen falta el volumen y el token:

```yaml
volumes:
  - /run/user/1000/axon:/run/user/1000/axon   # el DIRECTORIO, no el archivo
environment:
  AXON_TERM_BROKER_SOCKET: /run/user/1000/axon/term-broker.sock
  AXON_TERM_BROKER_TOKEN:  <el valor de ~/.config/cortex/term-broker.env>
```

Un cliente **nativo** del host usa en cambio `AXON_TERM_BROKER_URL=http://127.0.0.1:8799`.

Para copiar el token sin imprimirlo en la terminal:

```bash
grep '^AXON_TERM_BROKER_TOKEN=' ~/.config/cortex/term-broker.env >> /ruta/al/.env/del/cliente
```

Sin `AXON_TERM_BROKER_TOKEN`, axon usa el shell del contenedor y el widget lo reporta honesto
(`GET /api/axon/term/mode` → `container`). Con token y broker alcanzable → `host`. Con token y
broker **caído** → `host-down`, **no** una degradación silenciosa: el shell del contenedor es otra
máquina (root, `/workspace`, sin tu PATH ni tus llaves) y sustituirlo sin decirlo convierte un fallo
ruidoso en un `rm` o un `git commit` corrido donde nadie quería.

## Migrar desde la unidad vieja (`axon-term-broker.service`)

Hay máquinas donde una sesión instaló **a mano** una unidad `axon-term-broker.service` apuntando a
un clon de axon (`WorkingDirectory=…/axon-run`, rutas absolutas). Esa unidad **no es de cortex**.

**Corre el migrador. No pegues comandos:**

```bash
~/.local/bin/migrar-term-broker.sh --dry-run    # diagnostica y muestra el plan; no toca nada
~/.local/bin/migrar-term-broker.sh              # migra de verdad
```

Qué hace, y por qué no es una lista de pasos para copiar:

- **Ordena lo que comparte recurso.** Las dos unidades pelean por el MISMO puerto y el MISMO socket:
  primero `disable --now` de la vieja, luego **espera a que el endpoint se libere de verdad**
  (sondeando, no con un `sleep`), y recién entonces levanta la nueva.
- **Adopta el token viejo por default**, así el `.env` del cliente **no cambia**. Con
  `--token-nuevo` se queda el que generó el instalador y te dice cómo actualizar al cliente.
- **Verifica con el token REAL.** El paso de verificación que antes estaba escrito aquí era un
  `POST /run` **sin auth** esperando `401`… que da `401` siempre: con el broker viejo, con el nuevo,
  con cualquier token y hasta con el proceso muerto. No verificaba nada, y el fallo que no detectaba
  era silencioso. Ahora se comprueba `GET /health` con Bearer **por el socket y por TCP** (200), el
  `401` sin token como control negativo, un `/run` con una marca que tiene que volver en el wire SSE
  con `exit 0` y `[DONE]`, y los permisos del socket.
- **Revierte solo si algo falla**, y sabe revertir a pedido: `migrar-term-broker.sh --revertir`.
- **Es idempotente:** si ya estás migrado y verifica bien, no hace nada y sale 0.

La unidad legacy queda **apagada y deshabilitada pero en disco**, por si hay que volver. Cuando
lleves un rato bien: `rm ~/.config/systemd/user/axon-term-broker.service && systemctl --user daemon-reload`.

**Por qué el instalador no lo hace solo.** Si al instalar encuentra el endpoint ocupado, **no
arranca NI habilita** la unidad, y te manda aquí. Habilitar mientras la otra sigue viva dejaría
**dos unidades en `default.target.wants` sobre el mismo endpoint y con tokens distintos**: hoy no se
nota, y en el siguiente reboot systemd arranca las dos, una gana el bind y la otra cicla — si la que
gana es la de cortex, el cliente que trae el token viejo recibe `401` y el usuario ve su terminal
rara sin una pista. (Si una instalación previa la había habilitado, el instalador la deshabilita.)
La salvaguarda pregunta por el **recurso** —`ss` sobre el puerto y sobre el socket— y no por el
nombre de una unidad conocida, así que también ve un broker corrido a mano o una unidad en
`activating`.

Se evaluó y **se descartó** `Conflicts=axon-term-broker.service` en la unidad: haría que systemd
arbitrara **matando** la unidad legacy en cuanto ésta arrancara, o sea cerrando las terminales que
el usuario tiene abiertas sin que nadie lo pidiera. La arbitración correcta no es que systemd decida
por su cuenta sobre un recurso en uso: es no habilitar hasta que el cambio sea deliberado.

**Un detalle que el cambio arregla de paso:** la unidad legacy carga
`EnvironmentFile=~/.config/axon/maincar.env`, un archivo COMPARTIDO que además del token trae
`ANTHROPIC_API_KEY` y varias `AXON_*` del harness — todas terminan en el entorno del proceso que
lanza tus shells. (No llegan a la terminal: `buildSessionEnv()` las barre del hijo. Pero están en el
padre sin necesidad.) La unidad de cortex lee un archivo **dedicado** con solo el token. El migrador
copia la **línea** del token, no el archivo.

## Actualizar

Re-correr `./install.sh --con-term-broker` (o el `bootstrap.sh`, que se anuncia como *"re-correrlo
solo actualiza"*) **copia el código nuevo pero NO reinicia el servicio**: el proceso vivo se queda
con los `.ts` que ya cargó. No es un olvido — un `restart` **mata las terminales abiertas**, y eso
no se decide por ti. El instalador lo detecta y te lo dice; el reinicio lo das tú:

```bash
systemctl --user restart cortex-term-broker.service    # ⚠️ cierra las terminales abiertas
~/.local/bin/migrar-term-broker.sh --verificar         # y compruébalo con el token real
```

Si además re-vendorizaste los módulos desde axon, revisa
[`PROCEDENCIA.md`](../src/term-broker/PROCEDENCIA.md): el manifiesto `SHA256SUMS` es lo que ata la
copia local a lo que dice haber copiado.

## Desinstalar

`./uninstall.sh` lo retira **siempre**, sin bandera aparte, y **dice pieza por pieza qué se llevó**
(unidad, lanzador, migrador, módulos) y qué **no** tocó. El token se va con `~/.config/cortex` salvo
que pases `--keep-cfg`. La unidad legacy de axon, si la hay, **no** se toca — y también se dice.

## Probar

Dos pruebas funcionales, ambas sin tocar ningún servicio del sistema:

```bash
bash src/term-broker/probe-instalador.sh   # instalador en un HOME sandbox: opt-in, token, idempotencia, C-1
bash src/term-broker/probe-broker-vivo.sh  # levanta el broker en :18799 + socket propio y le habla
```

`probe-instalador.sh` corre el `install.sh` REAL con `HOME` en un temporal y `systemctl`/`kpackagetool6`
como stubs que solo registran: prueba que **sin** la bandera no queda nada, que **con** ella queda todo
(token 0600, unidad con `%h`, los `SHA256SUMS` cuadran, los probes **no** se copian al runtime), que es
idempotente, que con el **endpoint ocupado** no habilita ni arranca, y que `uninstall.sh` lo retira.

`probe-broker-vivo.sh` levanta el broker desde el clon en `:18799` **y con su propio socket en un
tmpdir** —nunca el `8799` ni el socket del servicio, que están en uso— y verifica el fail-loud sin
token, el `401`, el wire SSE de `/run`, la persistencia de la sesión, `/health`, el **socket unix**
completo (health + run + `0600` + pool compartido con el TCP), que **el token no se filtre al `env`
de la sesión** (con su control positivo), el canal PTY sobre WebSocket y que el bind sea loopback.

## De dónde sale el código

`src/term-broker/*.ts` es una copia **byte-a-byte** de módulos de axon, con el commit de origen y
los `sha256` anotados, más el argumento de por qué copia y no artefacto:
[`../src/term-broker/PROCEDENCIA.md`](../src/term-broker/PROCEDENCIA.md).
