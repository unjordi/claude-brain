# 🗺️ Mapa del cerebro — versión navegable (Mermaid)

> Flowcharts del cerebro **visibles en GitHub** (Mermaid se renderiza nativo — no hace falta
> Graphviz ni yEd para *verlos*). Un diagrama por capa: el flujo de git con sus guards, el ciclo
> del hilo/contexto, la delegación a agentes y el mapa de tiers del `MANIFEST`. Para el mapa
> *editable a mano* (yEd) el flujo es otro — ver el skill `diagramar`.

## Índice

1. [Flujo de git y sus guards](#1-flujo-de-git-y-sus-guards) — ramita → mini-develop → develop → main, y qué guard vigila cada cruce.
2. [Ciclo del hilo / contexto](#2-ciclo-del-hilo--contexto) — checkpoint → compact → rehidratar, con `aviso-contexto` y la rama de auto-sync de `aviso-drift-cerebro`.
3. [Delegación y fan-out](#3-delegación-y-fan-out) — gate de costo, freno duro, worktree aislado y cierre automático.
4. [Tiers del MANIFEST](#4-tiers-del-manifest--dónde-se-instala-cada-pieza) — global / repo / both, y por cuál ruta llega cada pieza.

---

## 1. Flujo de git y sus guards

El día a día vive en **tu mini-develop** (rama personal `Develop<Usuario>`, sembrada con
`sembrar-mini-develop.sh`): las ramitas entran ahí **sin candado**. Los únicos cruces con
fricción son los deliberados: integrar a `develop` (coordinado, con tu OK) y el release a `main`
(súper-explícito). El push directo a una base **nunca** pasa.

```mermaid
flowchart LR
    subgraph dia["🔄 Día a día — SIN fricción"]
        RAMITA["🌿 ramita<br/>feat/… fix/… docs/…"]
        MINI["🧑‍💻 mini-develop<br/>Develop&lt;Usuario&gt;<br/>(sembrar-mini-develop.sh)"]
        RAMITA -->|"git merge local<br/>o MR con auto-merge<br/>(ningún candado)"| MINI
    end

    subgraph coordinado["🤝 Integración COORDINADA"]
        DEVELOP["🌳 develop"]
    end

    subgraph release["🚀 Release-only"]
        MAIN["🏔️ main"]
    end

    MINI -->|"MR deliberado<br/>OK EXPLÍCITO del usuario<br/>con --squash, sin --auto-merge"| DEVELOP
    DEVELOP -->|"MR de RELEASE<br/>OK SÚPER-explícito<br/>SIN squash (conserva historia)"| MAIN

    GBG["🚧 git-branch-guard<br/>push/merge directo a develop·main<br/>→ DENEGADO, redirige a ramita"]
    MSG["🔗 merge-squash-guard<br/>MR a develop sin --squash → DENEGADO<br/>(destino main = exento: release sin squash)"]
    CMD["✋ confirmar-merge-develop<br/>merge sin OK expreso → DENEGADO<br/>target-aware: develop pide OK normal,<br/>main exige marca de RELEASE<br/>(un OK de release también cubre su paso a develop)"]
    SS["🕵️ secret-scan<br/>commit/push con secreto → DENEGADO"]
    RV["🕰️ rama-vieja<br/>base vieja al push → AVISA"]
    RD["📊 recordar-dashboard<br/>al push: dashboard + doc=realidad → RECUERDA"]
    LIB["📚 lib analizar-comando-git.sh<br/>(lógica compartida: qué comando toca una base)"]

    GBG -.->|vigila| DEVELOP
    GBG -.->|vigila| MAIN
    MSG -.->|vigila el MR| DEVELOP
    CMD -.->|candado del cruce| DEVELOP
    CMD -.->|candado súper-explícito| MAIN
    SS -.->|escanea lo que ENTRA| RAMITA
    RV -.->|aviso en el push| RAMITA
    RD -.->|nudge en el push| RAMITA
    LIB -.-> GBG
    LIB -.-> MSG
    LIB -.-> CMD

    style GBG fill:#7f1d1d,color:#fff
    style MSG fill:#7f1d1d,color:#fff
    style CMD fill:#7f1d1d,color:#fff
    style SS fill:#7f1d1d,color:#fff
    style RV fill:#78350f,color:#fff
    style RD fill:#78350f,color:#fff
    style LIB fill:#374151,color:#fff
```

**Leyenda:** rojo = hook que **bloquea** (deny) · ámbar = hook que **avisa/recuerda** (no bloquea)
· gris = lib compartida (los guards la hacen `source` → no divergen).

---

## 2. Ciclo del hilo / contexto

El compact (manual o auto) solo conserva un resumen con pérdida; el ciclo garantiza que el HILO
viva en **disco** antes de compactar y se **reinyecte** al retomar. `PreCompact` no sirve (no
tiene canal para inyectar ni turno del modelo — por eso se retiró `precompact-volcar-estado`).

```mermaid
flowchart TB
    TRABAJO["💬 Sesión trabajando<br/>(el HILO vive solo en el contexto — frágil)"]
    AC["📈 aviso-contexto (PostToolUse, GLOBAL)<br/>watermark del contexto: avisa ANTES<br/>del auto-compact-sorpresa, escala por banda<br/>(1 heads-up · 2 checkpoint AHORA · ≥3 inminente)"]
    CP["💾 skill checkpoint (manual, proactivo)<br/>vuelca el HILO a .claude/memory/hilo-mental-actual.md<br/>ligero (pausa) o COMPLETO (antes de compact:<br/>PLAN con el CÓMO · RESUELTO HOY · COSECHA)"]
    COMPACT["🗜️ /compact (o auto-compact)<br/>el resumen comprime — pero el hilo YA está en disco"]

    subgraph retomar["Al abrir / retomar / después de compactar (SessionStart)"]
        RH["🧵 rehidratar-hilo (GLOBAL)<br/>relee hilo-mental-actual.md y lo reinyecta<br/>vía additionalContext (con gate de frescura)"]
        SI["🧭 sesion-inicio (POR-REPO)<br/>reinyecta rama + norma de git +<br/>orden de leer MEMORY/estado-proyecto"]
        DRIFT{"🧬 aviso-drift-cerebro (GLOBAL)<br/>¿repo brained ATRÁS de la<br/>fuente única ~/.claude-brain?<br/>(diff real, no versión)"}
    end

    SYNC["✅ AUTO-SYNC<br/>parado en TU mini-develop y .claude/ limpio →<br/>apply + commit + push a tu mini SOLO;<br/>llega a develop con tu próxima integración"]
    AVISA["📣 solo AVISA<br/>(en otra rama no escribe nada:<br/>sincronizas tú por ramita→MR)"]
    SIGUE["🔁 la sesión continúa CON el hilo<br/>(skill rehidratar-hilo = gemelo manual del hook,<br/>respaldo si un update del CLI lo rompe)"]

    TRABAJO --> AC
    AC -->|"ordena volcar"| CP
    TRABAJO -->|"pausa natural / cada ~2h"| CP
    CP --> COMPACT
    COMPACT --> retomar
    TRABAJO -->|"cierre / corte de sesión"| retomar
    RH --> SIGUE
    SI --> SIGUE
    DRIFT -->|"sí, en mini-develop limpia"| SYNC
    DRIFT -->|"sí, en otra rama"| AVISA
    DRIFT -->|"al día"| SIGUE
    SYNC --> SIGUE
    AVISA --> SIGUE
    SIGUE --> TRABAJO

    style CP fill:#1e3a5f,color:#fff
    style RH fill:#14532d,color:#fff
    style SI fill:#14532d,color:#fff
    style AC fill:#78350f,color:#fff
    style DRIFT fill:#4a1d6e,color:#fff
    style SYNC fill:#14532d,color:#fff
```

**El par escritura/lectura:** `checkpoint` escribe · `rehidratar-hilo` lee. `dod-verificar`
(Stop, por-repo) cierra el ciclo del turno: un claim de CIERRE sin evidencia/OK — o un claim
visual a ciegas — se deniega ahí.

---

## 3. Delegación y fan-out

Reclutar agentes cuesta (gratis / incluido / metered) y muta archivos — dos riesgos, dos familias
de guards: el **gate de costo** antes de arrancar y el **aislamiento + cierre automático** al correr.

```mermaid
flowchart TB
    TASK["🤖 Task: reclutar un agente"]
    LG{"🛑 limite-gasto (PreToolUse/Task)<br/>¿ventana 5h AGOTADA <b>Y</b><br/>overage sin holgura?"}
    DG{"💸 delegacion-gate<br/>nivel de costo del agente<br/>(gratis/incluido: pregunta 1×/máquina ·<br/>metered: 1×/workflow)"}
    REG["📝 delegacion-registrar<br/>materializa el 'pregunta una sola vez'<br/>(consentimiento persistido)"]
    WT["🌲 agente corre en WORKTREE AISLADO<br/>(isolation: worktree — nunca el árbol compartido)"]
    PA["🌳 proteger-arbol<br/>git destructivo que orfanaría commits<br/>en el árbol compartido → AVISA"]
    REP["📮 delegacion-reporte (PostToolUse/Task)<br/>al terminar: recuerda appendear bitácora (>>)<br/>+ actualizar estado-proyecto + limpiar worktree"]
    LW["🧹 limpiar-worktrees.sh (script)<br/>barre worktrees de ramas mergeadas;<br/>los vivos quedan anotados en bitácora"]
    LR["🧹 limpiar-ramas.sh (script)<br/>barre RAMAS LOCALES ya integradas (squash-safe);<br/>conserva trabajo vivo + protegidas"]
    FRENO["⛔ FRENO DURO<br/>sin cupo del plan NI saldo:<br/>el agente moriría a medias"]

    TASK --> LG
    LG -->|"ambos agotados"| FRENO
    LG -->|"hay capacidad"| DG
    DG -->|"consentimiento dado"| REG
    REG --> WT
    PA -.->|"vigila el árbol compartido"| WT
    WT --> REP
    REP --> LW
    LW --> LR

    style LG fill:#7f1d1d,color:#fff
    style FRENO fill:#7f1d1d,color:#fff
    style DG fill:#78350f,color:#fff
    style REG fill:#78350f,color:#fff
    style REP fill:#78350f,color:#fff
    style PA fill:#78350f,color:#fff
    style LW fill:#374151,color:#fff
    style LR fill:#374151,color:#fff
```

El estilo de orquestación (fan-out + supervisión, 2 archivos de estado sin redundancia) lo guía
el skill `orquestar-fanout`; la lib `delegacion-comun.sh` comparte la lógica de gate/registro.

---

## 4. Tiers del MANIFEST — dónde se instala cada pieza

[`brain/hooks/MANIFEST`](../brain/hooks/MANIFEST) es la **fuente única**: declara tier (dónde) y
kind (cómo) de cada pieza, y de ahí **derivan** las dos rutas de instalación y el drift-check de
`test-brain.sh` — no hay listas curadas por separado que puedan divergir.

```mermaid
flowchart LR
    MANIFEST["📜 brain/hooks/MANIFEST<br/>fuente ÚNICA: tier + kind por pieza"]

    subgraph tiers["Tiers declarados"]
        BOTH["tier <b>both</b> — global + por-repo<br/>(con cláusula de dedupe:<br/>la copia del repo cede a la global)<br/><br/>hooks: git-branch-guard ·<br/>merge-squash-guard ·<br/>confirmar-merge-develop ·<br/>recordar-dashboard · secret-scan<br/>libs: analizar-comando-git ·<br/>detectar-secretos"]
        GLOBAL["tier <b>global</b> — solo ~/.claude<br/><br/>hooks: proteger-arbol · rama-vieja ·<br/>limite-gasto · rehidratar-hilo ·<br/>aviso-contexto · aviso-drift-cerebro ·<br/>delegacion-gate · delegacion-registrar ·<br/>delegacion-reporte<br/>lib: delegacion-comun · ramas-zombie<br/>script: limpiar-worktrees · limpiar-ramas"]
        REPO["tier <b>repo</b> — solo &lt;repo&gt;/.claude<br/>(se cargan si la sesión INICIA ahí)<br/><br/>hooks: dod-verificar · sesion-inicio"]
    end

    subgraph destinos["Destinos"]
        GDIR["🏠 ~/.claude/hooks + settings.json<br/>instala: brain/install-brain.sh<br/>(vía bootstrap / install.sh)<br/>+ skills genéricas en ~/.claude/skills<br/>(auto-descubre brain/skills/*/SKILL.md)"]
        RDIR["📁 &lt;repo&gt;/.claude/hooks + settings.json<br/>despliega: brain/sincronizar-cerebro.sh<br/>(diff-aware; viaja por git al equipo)"]
    end

    TEST["🧪 brain/test-brain.sh<br/>drift-check (e2): ambas rutas<br/>DEBEN coincidir con el MANIFEST"]

    MANIFEST --> BOTH
    MANIFEST --> GLOBAL
    MANIFEST --> REPO
    BOTH -->|"install-brain.sh"| GDIR
    BOTH -->|"sincronizar-cerebro.sh"| RDIR
    GLOBAL -->|"install-brain.sh"| GDIR
    REPO -->|"sincronizar-cerebro.sh"| RDIR
    TEST -.->|verifica| GDIR
    TEST -.->|verifica| RDIR
    TEST -.->|contra| MANIFEST

    style MANIFEST fill:#1e3a5f,color:#fff
    style TEST fill:#4a1d6e,color:#fff
```

**Kinds:** `hook` se cablea en `settings.json` (evento) · `lib` solo se copia (los hooks la hacen
`source`) · `script` solo se copia (standalone, se corre a mano/por cron).

---

> **Fuente de verdad: `brain/hooks/MANIFEST` + el árbol de "La jerarquía" del README raíz** (y los
> headers de los propios hooks). Este mapa es **doc de record** (norma *doc = realidad*): si
> agregas, quitas o mueves un hook/skill/norma — o cambia la lógica de un cruce — **actualiza este
> mapa en la MISMA tanda**, igual que el MANIFEST y el árbol del README.
