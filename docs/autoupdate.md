# Autoupdate del widget

Cómo se actualiza el widget cuando nosotros subimos una versión y los demás la reciben.

## Modelo actual (git + recompilación local) — las 3 plataformas

Cada plataforma embebe un `version.json` (SHA + fecha del commit con que se buildeó, ruta del clon,
rama) junto al binario. Al abrir la pestaña **Cerebro**, el widget consulta `commits/main` de
`github.com/unjordi/claude-brain` (throttle ~15 min, timeout ~6 s, **fail-open**: sin red / sin
`version.json` / sin clon → no molesta). Si `main` avanzó, dibuja el banner **⬆ Actualizar**.

Al aceptar, un script suelto hace `git fetch` + `git merge --ff-only origin/main` y —**solo si tuvo
éxito**— re-corre el instalador (`install.sh` / `install.ps1`), que reconstruye y relanza. Como el
proceso corre desprendido, sobrevive a que el instalador cierre la app.

> **ONE-STOP, sin asimetría entre OS.** El instalador que re-corre el botón es el **completo**
> (**cerebro + widget**) en las 3 plataformas: `install.sh` en Mac/Linux, y en Windows `install.ps1`
> instala el cerebro por defecto (antes era solo-widget → el botón del Mac pasaba `--no-brain` y el de
> Windows no tocaba hooks; ambos corregidos 2026-07-23). Así **un clic deja la máquina completa** (hooks
> nuevos incluidos). El botón **"🩹 Curar cerebro global"** queda como el self-heal SIN `git pull`
> (re-cablea el cerebro empaquetado en el app), no como el paso obligado que era antes en el Mac.

- macOS (`Updater.swift`), Linux (`main.qml` → `forceRefresh`), Windows (`Updater.cs`).
- **Requisito:** el receptor tiene el **clon de git** + el **toolchain de build** (Swift/CLT en
  macOS, nada en Linux porque el plasmoide es QML, **.NET SDK en Windows**).

**El dolor:** en Windows recompilar exige el .NET SDK (cientos de MB) en la máquina del usuario.
Eso rompe la promesa "los demás reciben sin fricción".

## Fase 1 — CI precompila el exe de Windows y lo publica (HECHO, en develop)

`.github/workflows/release-windows.yml`: en push a `main` que toque `windows/**`, un runner
`windows-latest` hace `dotnet publish` del exe **self-contained single-file** (no necesita runtime
ni SDK en destino) y lo publica como asset del **release rolling `windows-latest`** (delete+recreate
para que el tag apunte al SHA del build; `build-sha:` en el cuerpo). También `workflow_dispatch`.

> Los workflows de `push`-a-`main` solo corren **desde `main`**. Este workflow queda **dormido en
> `develop`** hasta que un release lo lleve a `main`. Primera corrida real = el próximo release +
> (opcionalmente) un `workflow_dispatch` desde la pestaña Actions.

Solo Windows por ahora: macOS compila Swift en ~1 s con las CLT; Linux es QML sin compilar. Ambos
siguen con el modelo git-based, que ahí no duele.

## Fase 2 — el updater de Windows BAJA el exe (IMPLEMENTADO, pendiente de QA)

> ✅ **Implementado en `Updater.cs`** (compila 0/0). ⚠️ **Pendiente de QA real en Windows** (VM +
> laptop de Liora) antes de confiar en él, y el asset del release no existe hasta el primer release a
> `main` que dispare la Fase 1. Diseño y comportamiento reales:

Cambios en `windows/src/ClaudeBrain/Updater.cs`:

1. **Detección de versión** → dejar de comparar contra `commits/main` y comparar contra el
   **release**: `GET /repos/unjordi/claude-brain/releases/tags/windows-latest`, leer el `build-sha:`
   del cuerpo (o el `target_commitish`), comparar con el SHA embebido. Así el banner solo aparece
   cuando el **artefacto ya está publicado** (no en el hueco de ~minutos que tarda el build de CI).
   Mantener el **fail-open** (sin release / sin red → no molesta).

2. **Acción de update** → en vez de `git ff` + rebuild:
   - Descargar el asset `ClaudeBrain.exe` del release a un archivo **temporal** (`%TEMP%`).
   - (Opcional pero recomendado) verificar tamaño/deshabilitar si la descarga viene vacía.
   - Un script `pwsh` desprendido: espera a que el proceso del widget cierre, **reemplaza** el exe en
     `%LOCALAPPDATA%\Programs\ClaudeBrain\ClaudeBrain.exe` con el temporal, reescribe `version.json`
     con el nuevo SHA, y **relanza**. (Un exe self-contained single-file NO puede sobreescribirse
     mientras corre → por eso el swap va en el script externo, igual que hoy con el rebuild.)
   - **Fail-open duro:** ante CUALQUIER fallo (descarga, permiso, swap) → NO dejar el widget en mal
     estado; caer al mensaje actual `"actualiza a mano: …"`. Peor caso = no auto-actualiza, nunca un
     brick.

3. **Refrescar el cerebro + re-cablear los hooks (RESUELTO 2026-07-23).** La ruta de descarga, tras el
   swap del exe: si hay clon, hace `git ff` y refresca `brain/` al lado del exe (opción (a)); y en
   AMBOS casos corre el **`install-brain.ps1` empaquetado** para re-cablear los hooks → deja la máquina
   ONE-STOP (paridad con la ruta git y con Mac/Linux), sin `.NET SDK`. Pendiente menor (opción (b), no
   enfilada): sin clon, el CONTENIDO de `brain/` no se refresca por pura descarga — subirlo como 2º
   asset del release lo cubriría; hoy el caso real (máquinas con clon del bootstrap) no lo necesita.

4. `install.ps1` puede ganar un `-FromRelease` que **descargue** el exe en vez de compilar (para
   instalaciones nuevas sin .NET SDK), dejando el build-desde-fuente como camino de dev.

### QA mínimo antes de confiar en la Fase 2
- Release real a `main` → CI publica el asset → `gh release view windows-latest` muestra el exe.
- En una Windows: instalar una versión vieja, publicar una nueva, abrir la pestaña Cerebro, ver el
  banner, aceptar, y confirmar que el widget se reemplaza y relanza **sin** .NET SDK presente.
- Probar el fail-open: sin red, y con un asset corrupto/borrado.
