# Tools

Herramientas de QA (H · T60/T61/T90).

## `generate-testmedia.sh` (T60)

Genera `TestMedia/` (no versionado) y reescribe `TestMedia/manifest.json` (versionado).
Idempotente y determinista; ver `TestMedia/README.md`.

```bash
Tools/generate-testmedia.sh [--force] [--only REGEX] [--out DIR] [--manifest-only]
```

## `StressHarness/` → `minimix-stress` (T61)

Ejecuta un escenario durante N segundos al ritmo del reloj y escribe **un informe JSON por
ejecución** en `Tools/reports/` (ignorado por git): fps medidos, fotogramas perdidos (huecos del
reloj y descartes por GPU saturada), intervalos entre ticks (marcas de la rejilla y llegada real
`deliveryIntervalMs`, que mide el jitter), tiempo de GPU y de CPU por fotograma,
RAM (`phys_footprint`, muestreada), CPU del proceso, estado térmico con muestreo temporal,
eventos (cortes, transiciones, items de playlist, máx. items cargados, fotogramas sin item listo)
y metadatos de máquina/OS.

```bash
swift build --package-path Tools/StressHarness -c release --product minimix-stress
Tools/StressHarness/.build/release/minimix-stress --list
Tools/StressHarness/.build/release/minimix-stress --scenario switch-every-3s --duration 30
Tools/StressHarness/.build/release/minimix-stress --scenario playlist-50 --fps 59.94 --size 1280x720
Tools/StressHarness/.build/release/minimix-stress --scenario mi-escenario.json   # ScenarioConfig en JSON
scripts/swift-test.sh Tools/StressHarness                                         # tests del harness
```

Escenarios: `switch-every-3s` (corte cada 3 s rotando 4 entradas), `fade-every-3s` (fundido de 1 s),
`playlist-50` (50 items vídeo/imagen/color de 0,5 s en bucle, precarga A/B con máx. 2 cargados).

Pipelines (`--pipeline`), todos programados contra los protocolos de `Contracts.swift`:

| Nombre | Reloj | Compositor | Switcher | Secuenciador | Fuentes |
|---|---|---|---|---|---|
| `core-render` (defecto) | `WallClock` | `Render.Compositor` | `Core.SwitcherState` | `Core.PlaylistSequencer` | `MockFrameSource` |
| `mock` | `WallClock` | `BlitCompositor` | `MockSwitcher` | `MockSequencer` | `MockFrameSource` |

| `real` | `Media.MasterClock` | `Render.Compositor` | `Core.SwitcherState` | `Core.PlaylistSequencer` | `VideoInput`/`ImageInput`/`ColorInput` |

### Estrés T90 sobre los módulos reales (sección 10.2 del plan)

Requiere TestMedia generado. Lienzo 1080p60, 8 entradas (5 vídeos de la matriz, PNG con alfa, color y
`playlist_50`), 2 activas; montaje igual que `AppServices.live()`: `MasterClock`, `InputManager` con
`PlaylistInput.factory`, `AudioEngine` con el audio de cada entrada, `setVisible` como la app, y una
réplica de `LiveRenderer` con el `Compositor` real (MiniMixUI no es un producto importable).
El renderer copia la esquina del código de fotograma de Programa y la lee al completarse la GPU:
negros, saltos, repeticiones y latencia de Cut sin bloquear el render.

```bash
Tools/StressHarness/.build/release/minimix-stress --scenario stress-5m-cuts       # 5 min, verificación
Tools/StressHarness/.build/release/minimix-stress --scenario stress-5m-playlist
nohup caffeinate -i Tools/StressHarness/.build/release/minimix-stress --scenario stress-1h-playlist \
    > Tools/reports/stress-1h-playlist.log 2>&1 &
nohup caffeinate -i Tools/StressHarness/.build/release/minimix-stress --scenario stress-2h-cuts \
    > Tools/reports/stress-2h-cuts.log 2>&1 &
```

El informe (`LiveReport`) incluye la tabla `targets` (objetivo/medido/cumple), arranque en frío,
perdidos (reloj, contrapresión, colector del compositor; separados en calentamiento, máquina
tranquila y máquina cargada), CPU (proceso y sistema), GPU (nuestros fotogramas y sistema), memoria
con deriva por hora, térmica en el tiempo, latencia de Cut, análisis del feed de Programa, saltos por
clip y estadísticas de la playlist (`lateSwitches`, máx. items cargados). El desfase A/V no se mide
todavía (informativo).

Para tests de integración, `Tests/Sources/TestSupport` ofrece: lector del código de fotograma
(`FrameCodeReader` sobre `MTLTexture`/`CVPixelBuffer`/`RGBAImage`), `FrameSequenceAnalysis`
(negros/repetidos/saltos para gapless), comparador ΔE CIE76/CIEDE2000 (`ImageDifference`) y
medidores (`ProcessMetrics`, `CPUUsageMeter`, `ResourceMonitor`, `MachineInfo`).
