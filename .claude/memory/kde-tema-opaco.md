---
name: kde-tema-opaco
description: "tema Plasma \"CachyOS Nord (opaco)\" — fork local para bajar la transparencia de los widgets de KDE en CachyOS"
metadata: 
  node_type: memory
  type: project
  originSessionId: f59bc25a-fdde-4d83-80c0-f29da9699946
---

unjordi quiso **bajar la transparencia de TODOS los widgets de KDE** (no solo el de Claude). La transparencia NO es un slider global en Plasma 6: vive en los fondos SVG del **tema de Plasma** (desktop theme) + el blur de KWin. Su tema activo era `CachyOS-Nord-round` (de `/usr/share/plasma/desktoptheme/`, de root).

**Solución (2026-06-29, quedó PERFECTO a su gusto):** fork del tema a uno suyo, editable sin root, en `~/.local/share/plasma/desktoptheme/CachyOS-Nord-opaco/` (Name "CachyOS Nord (opaco)", Id `CachyOS-Nord-opaco`). Se subió la opacidad del fondo Nord `#1e2233` de los widgets de **~0.81 → 0.97** (igual que sus paneles, que ya estaban a 0.97):
- `widgets/background.svg`: `opacity:0.807852` → `0.97`
- `widgets/translucentbackground.svg` (la variante que usa Plasma CON blur, la que de verdad se veía): `opacity:0.81101643` → `0.97`
- (los `opacity:0.05/0.01/0.25` son realces/sombras sutiles — NO tocar)

**Aplicar:** `plasma-apply-desktoptheme CachyOS-Nord-opaco`. **Revertir:** `plasma-apply-desktoptheme CachyOS-Nord-round`.
**Tunear:** subir `opacity:0.97`→`1.0` (100% opaco) o bajar a 0.90 en esos dos SVG y re-aplicar.

OJO: cambio LOCAL de CachyOS (los SVG del tema viven en `~/.local`, NO viajan por git ni por Drive — solo viaja esta nota); macOS/Windows no aplica. Editar SVGs con **`command sed`** (su `cp` está aliaseado a `cp -i`; ver [[claude-quota-widget]] gotchas). Surgió mientras pulíamos el [[claude-quota-widget]].
