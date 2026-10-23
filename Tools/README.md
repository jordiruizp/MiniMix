# Tools

Herramientas de QA (H · T60/T61).

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

**Punto de inyección (T80/T90)**: crear una `RealPipelineFactory` con `Media.MasterClock` y las
fuentes reales (`InputManager`, playlist de D) y registrarla en `PipelineRegistry.factories`
(`Sources/StressHarnessKit/Pipeline.swift`), añadiendo la dependencia de Media en
`StressHarness/Package.swift`. El runner y el formato del informe no cambian.

Para tests de integración, `Tests/Sources/TestSupport` ofrece: lector del código de fotograma
(`FrameCodeReader` sobre `MTLTexture`/`CVPixelBuffer`/`RGBAImage`), `FrameSequenceAnalysis`
(negros/repetidos/saltos para gapless), comparador ΔE CIE76/CIEDE2000 (`ImageDifference`) y
medidores (`ProcessMetrics`, `CPUUsageMeter`, `ResourceMonitor`, `MachineInfo`).
