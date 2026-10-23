# MiniMix — guía para agentes

Switcher de vídeo tipo vMix para macOS (Preview + Programa). Fuentes: vídeo, audio,
imagen, color sólido y playlists. Objetivo hardware: MacBook Neo (A18 Pro, 8 GB, sin ventilador).
Plan completo: `../Plan_MiniMix_switcher_Mac.pdf`. Estado: `PROGRESS.md`.

## Entorno y comandos

La máquina de desarrollo tiene **solo Command Line Tools (sin Xcode)**. Consecuencias:
- No hay `xcodebuild` ni `.xcodeproj`: todo es **SwiftPM**. La app es el paquete `App/`
  (librería `MiniMixUI` + ejecutable `MiniMix`); `scripts/bundle-app.sh` crea `build/MiniMix.app`.
- **No hay XCTest**: los tests usan **Swift Testing** (`import Testing`, `@Test`, `#expect`).
- **No hay compilador `metal`**: los shaders se compilan **en tiempo de ejecución** con
  `MTLDevice.makeLibrary(source:options:)`. Guarda el código MSL como recurso de texto
  (`.copy("Shaders/Compositor.metal.txt")`) o como cadena Swift; no añadas `.metal` a un target.

```bash
scripts/swift-test.sh Packages/Core          # tests de un paquete (usar SIEMPRE este wrapper)
scripts/swift-test.sh Packages/Render --filter Compositor
scripts/ci.sh                                # puerta de calidad: swiftlint --strict + todos los paquetes
scripts/ci.sh Packages/Media App             # solo algunos paquetes
scripts/bundle-app.sh [debug|release]        # build/MiniMix.app firmada ad-hoc
```

`scripts/swift-test.sh` añade `-warnings-as-errors` y, con CLT, la ruta del plugin de macros de
Swift Testing. SwiftLint con CLT necesita `DYLD_FRAMEWORK_PATH=$(xcode-select -p)/usr/lib`
(`scripts/ci.sh` ya lo hace). El paquete Core también compila en Linux (job `core-linux` del CI).

## Estructura y dependencias

```
Packages/Core         modelos, Contracts.swift, SwitcherState, PlaylistSequencer, CoreMocks
Packages/Render       Metal: MetalContext, Compositor, shaders, TexturePool, MonitorView   → Core
Packages/Media        MasterClock, Video/Audio/Image/ColorInput, InputManager, Playlist/   → Core, Render
Packages/Audio        AudioEngine, canales, VU, Master, fundidos                           → Core
Packages/Output       pantallas externas, ventana de Programa                              → Core, Render
Packages/Persistence  ProjectStore (JSON .minimix), bookmarks, migraciones, reenlace       → Core
App/                  SwiftUI, ViewModels, atajos, menús, integración                      → todos
Tests/                paquete MiniMixIntegration: integración, snapshots, gapless          → Core, Render, Media, Audio
Tools/  TestMedia/    generador de medios (ffmpeg), harness de estrés; TestMedia no se versiona
```

Cada paquete expone una librería con su nombre; los tests de cada uno pueden usar `CoreMocks`.

## Propiedad de carpetas (sección 8.1 del plan)

| Agente | Puede modificar |
|---|---|
| ORQ · Orquestador | raíz del repo, `Packages/Core/Sources/Core/Contracts.swift`, `Packages/Core/Sources/CoreMocks/`, `Packages/*/Package.swift`, `App/Package.swift`, `App/Resources/`, `scripts/`, `.github/`, `CLAUDE.md`, `PROGRESS.md`, `.swiftlint.yml` |
| A · Core | `Packages/Core/` excepto lo del ORQ |
| B · Render | `Packages/Render/` (fuentes y tests) |
| C · Media | `Packages/Media/` excepto `Sources/Media/Playlist/` y sus tests |
| D · Playlist | `Packages/Media/Sources/Media/Playlist/`, `Packages/Media/Tests/MediaTests/Playlist/` |
| E · Audio | `Packages/Audio/` |
| F · Output+Persistencia | `Packages/Output/`, `Packages/Persistence/` |
| G · UI | `App/Sources/`, `App/Tests/` |
| H · QA | `Tests/`, `TestMedia/`, `Tools/` |
| R · Revisor | nada (solo lectura) |

Si necesitas un cambio fuera de tu carpeta (incluido un `Package.swift` o una dependencia nueva),
**no lo hagas**: descríbelo en tu informe final.

## Contratos

`Packages/Core/Sources/Core/Contracts.swift` está **congelado** (tag `contracts-v1`).
- Nadie salvo el orquestador lo modifica. Para cambiarlo: petición en el informe → el orquestador
  consulta al usuario, versiona (`contracts-vN`) y avisa a los afectados.
- Se pueden añadir **extensiones** de tipos de contrato en archivos propios del módulo
  (p. ej. `Core/Models/RGBAColor+Hex.swift`), sin cambiar su forma almacenada ni su Codable.
- Mientras una dependencia no esté lista, programa contra los protocolos y usa `CoreMocks`.

## Reglas de código

- Swift 6 con concurrencia estricta, **cero warnings** (`-warnings-as-errors`), SwiftLint `--strict` limpio.
- **Sin copias CPU de fotogramas**: CVPixelBuffer → `CVMetalTextureCache` (IOSurface) → `MTLTexture`.
  Las imágenes fijas se decodifican una vez, reducidas al tamaño del lienzo.
- **Nada bloqueante en el hilo de render** (`FrameSource.texture(for:)` y el compositor):
  ni `await`, ni E/S, ni locks largos (un `OSAllocatedUnfairLock` corto está bien).
- `@MainActor` solo en la interfaz (App, `OutputPresenting`). Core, Render, Media y Audio no son MainActor.
- Memoria (8 GB): pools reutilizables (`CVPixelBufferPool`, `TexturePool`), máx. 4 decodificadores
  activos, pausar entradas no visibles, como máximo 2 items cargados por playlist.
- macOS 15+, solo arm64. Sin dependencias externas (SPM) salvo acuerdo con el orquestador.
- No usar la marca «vMix» en código, textos ni recursos.
- Tests para cada criterio de aceptación del backlog; los tests que requieren GPU deben
  salir limpiamente si `MTLCreateSystemDefaultDevice()` es nil.

## Ramas, commits y entrega

- Rama por agente y tarea: `feat/<agente>-<tarea>` (p. ej. `feat/a-t10-t12`, `feat/b-render`).
- Commits pequeños en imperativo con prefijo de tarea: `T21: add mix shader and snapshots`.
- PR/entrega idealmente < 600 líneas por tarea, con tests y criterio de aceptación.
- Solo el orquestador fusiona en `main` (orden del grafo 8.3) y rebasa ramas abiertas.
- Puerta de calidad: `scripts/ci.sh` verde + revisión del agente R + aprobación del orquestador.
- **Informe final** de cada subagente: resumen, archivos tocados, tests añadidos, métricas
  medidas, riesgos, preguntas/cambios pedidos fuera de su carpeta.

## Definición de terminado (por tarea)

Criterio de aceptación del backlog verificado con tests (o métrica medida y documentada),
`scripts/ci.sh` verde, sin cambios fuera de la carpeta propia, informe entregado.
