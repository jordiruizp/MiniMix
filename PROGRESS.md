# MiniMix — PROGRESS

Mantenido por el orquestador. Estados: ⬜ pendiente · 🟦 en curso · 🟨 en revisión · ✅ integrado en main · ⛔ bloqueado

## Olas

| Ola | Estado |
|---|---|
| 0 · Andamiaje + contratos + CI + CLAUDE.md | ✅ |
| 1 · A, B, C, E, G(mocks), H | 🟦 A, B, E integrados · G corrigiendo · C, H reanudados · B, E con seguimiento |
| 2 · D, F, G-real, ORQ T80 | ⬜ |
| 3 · H rendimiento, E sync, G pulido | ⬜ |
| 4 · T99 release | ⬜ |

## Tareas

| ID | Agente | Tarea | Estado | Rama | Notas |
|---|---|---|---|---|---|
| T00 | ORQ | Andamiaje SwiftPM, 7 paquetes, sandbox, SwiftLint, CI | ✅ | main | CI local verde; CI de GitHub sin verificar (sin push) |
| T01 | ORQ | Contracts.swift + tipos base + CoreMocks | ✅ | main | Aprobado por el usuario 2026-10-23 · tag `contracts-v1` |
| T02 | ORQ | CLAUDE.md | ✅ | main | |
| T10 | A | Modelos Codable + versión de esquema | ✅ | feat/a-core → main | |
| T11 | A | SwitcherState | ✅ | feat/a-core → main | 34 tests · cobertura 98,95 % |
| T12 | A | PlaylistSequencer | ✅ | feat/a-core(+fixes) → main | 113 tests Core; fixes de revisión integrados |
| T20 | B | MetalContext, TexturePool, MonitorView | ✅ | feat/b-render → main | |
| T21 | B | Compositor + shaders | ✅ | feat/b-render → main | |
| T22 | B | ImageInput → textura | ✅ | feat/b-render → main | |
| T30 | C | MasterClock | 🟦 | feat/c-media | |
| T31 | C | VideoInput | 🟦 | feat/c-media | CVMetalTextureCache propio; se pasa a MetalContext al integrar |
| T32 | C | AudioInput + InputManager | 🟦 | feat/c-media | |
| T40 | E | AudioEngine | ✅ | feat/e-audio → main | |
| T41 | E | Audio sigue a Programa + fundido | ✅ | feat/e-audio → main | contra el contrato (AudioMixing + TransitionCurve); no necesita T11 |
| T50 | G | Layout con mocks | ⛔ devuelto | feat/g-ui-mocks | R: DEVOLVER (B1–B4, M1–M7); no compila sobre main por RGBAColor(hex:) duplicado |
| T51 | G | Panel de playlist | ⛔ devuelto | feat/g-ui-mocks | R: DEVOLVER (B1–B4, M1–M7); no compila sobre main por RGBAColor(hex:) duplicado |
| T60 | H | Generador TestMedia | 🟦 | feat/h-qa | |
| T61 | H | Harness de estrés | 🟦 | feat/h-qa | |
| T70 | D | PlaylistInput A/B | ⬜ | | Ola 2 |
| T71 | D | Fundido entre items + hold | ⬜ | | Ola 2 |
| T80 | ORQ | Integración switcher | ⬜ | | Ola 2 |
| T81 | F | Output externo | ⬜ | | Ola 2 |
| T82 | F | Persistence | ⬜ | | Ola 2 |
| T90 | H | Estrés 1 h / 2 h | ⬜ | | Ola 3 |
| T91 | G | Pulido UI | ⬜ | | Ola 3 |
| T99 | ORQ | Firma, notarización, DMG | ⬜ | | Ola 4 |

## Peticiones de contrato (pendientes de decisión del usuario)

- **PC1** (A) · `Effect.transitionCancelled` para distinguir la cancelación de T-bar de una transición completada. Hoy se señala con `transitionProgress(0)` + `transitionCompleted` sin `busesChanged`. Candidata a contracts-v2; no bloquea.

## Revisiones

- **R-A** (feat/a-core, 55368f3): APROBAR CON CAMBIOS MENORES, 0 bloqueantes. Integrado en main. Devuelto a A en `feat/a-core-fixes`:
  reajuste del secuenciador al borrar varios items, `SwitcherState.removeInput`, señal explícita de «reiniciar item» para D,
  validación de colores no finitos/canvas/frameRate, tolerancia en fin de fade, acotar `supportedVersion`, hex con saltos de línea.

- **R-E** (feat/e-audio): APROBAR CON CAMBIOS MENORES. Integrado. Seguimiento pendiente (sin lanzar): rampa en detach,
  rearranque asíncrono tras cambio de dispositivo con log, validación de formatos/frameCount en el AU, test de wrap del anillo.
- **R-B** (feat/b-render): APROBAR CON CAMBIOS MENORES. Integrado. Seguimiento pendiente (sin lanzar): token en
  MonitorFeed (dismantle), lease de textura publicada, no compilar pipelines en encode (`prepare(pixelFormat:)`),
  `view.colorspace = sRGB`, decode fuera del pool cooperativo, stats por bus, guard en recycle, flush de CVMetalTextureCache.
- **R-G** (feat/g-ui-mocks): DEVOLVER. Pendiente reenviar a G: rebase sobre main; B1 quitar hex duplicado (usar Core);
  B2 enviar `.tbar(0)` al completar; B3 filtrar monitor de teclado (ventana key, sin sheet, sin isARepeat);
  B4 limpiar Preview al quitar entrada (`SwitcherState.removeInput`); M1–M7; usar SwitcherState/PlaylistSequencer reales.

## Peticiones de contrato nuevas (para decisión del usuario)

- **PC2** (B, G) · Espacio de color de `RGBAColor`: el contrato dice «lineal» pero todo el sistema lo usa como sRGB codificado.
  Recomendación ORQ: cambiar el comentario a «sRGB codificado» (sin cambio de forma) y mezclar en sRGB.
- **PC3** (G) · `InputManaging.update(_ descriptor:)` para propagar ediciones en directo (color, fit, In/Out, playlist).
- **PC4** (G) · `FrameSource.currentTime` o evento de posición para tiempos restantes reales.
- **PC5** (G) · `Command.setFit` y comandos de edición de playlist (MIDI/Stream Deck).
- **PC7** (G) · Añadir `removeInput(_:at:)` a `SwitcherStateMachine` (hoy G hace cast a `SwitcherState`).
- **PC8** (G) · Añadir `lastEventRestartsItem` a `PlaylistSequencing` (hoy cast a `PlaylistSequencer`).
- **PC9** (E) · Documentar en `AudioMixing.meters` «un único consumidor».
- **PC6** (R-G) · `MasterClockProtocol.ticks` es un único AsyncStream: definir dueño del reloj y difusión a varios consumidores.

## PRs abiertos

| PR | Rama | Estado |
|---|---|---|
| #1 | feat/e-audio-fixes | CI ✅ (Swift 6.3) · en revisión |
| #2 | feat/b-render-fixes | CI en curso · en revisión |
| #3 | feat/h-qa (T60, T61) | CI en curso · en revisión |
| #4 | feat/g-ui-mocks (T50, T51) | CI en curso · re-revisión |

## Bloqueos

- ~~Sin Xcode~~ → resuelto 2026-10-23: Xcode 27.1 instalado. `xcode-select` sigue en CLT (cambiarlo requiere sudo);
  los scripts usan Xcode vía `scripts/env.sh`. CI local verde con Xcode.
- ~~Sin push a GitHub~~ → resuelto: `gh` autenticado; main y tag `contracts-v1` subidos. CI de Actions en `macos-26` (Swift 6.3.3) + Linux (`swift:latest`).
- **CI rojo en Audio/App/Tests**: `AudioEngine.swift` no compila con Swift 6.3 (aislamiento de regiones en `Mutex.withLock`). Asignado a E (feat/e-audio-fixes, punto 7).

## Decisiones

- **D1** · Build SwiftPM; la app es el paquete `App/` + `scripts/bundle-app.sh`. `.xcodeproj` diferido: el ORQ lo crea cuando haga falta (XCUITest, T99).
- **D2** · Tests con Swift Testing; XCTest solo para medidas de rendimiento.
- **D3** · Shaders compilados en tiempo de ejecución (`makeLibrary(source:)`) para que `swift test` y `xcodebuild` se comporten igual (se mantiene aunque ya hay compilador `metal`).
- **D4** · Core sin Metal/AVFoundation: los contratos GPU/audio (`FrameSource`, `AudioSource`, `CompositorFrame`,
  `Compositing`, `InputManaging`) están en `Contracts.swift` tras `#if canImport(Metal/AVFAudio)`; Core sigue compilando en Linux.
- **D5** · `nativeSize` usa `PixelSize` (Core) en lugar de `CGSize`.
- **D6** · Añadido a los contratos respecto al plan: `tick(at:)` en `SwitcherStateMachine`; comandos `seek`, `setLoop`,
  `setSolo`, `setAudioFollowsProgram`, `setMasterVolume`; `Effect`; `TransitionCurve` común audio/vídeo;
  `SequencerState/Event` + `PlaylistSequencing`; protocolos de servicio `MasterClockProtocol`, `AudioMixing`,
  `ProjectStoring`, `OutputPresenting`, `Compositing`, `InputManaging`; modelos `InputDescriptor`, `Project`.
- **D10** · CI alineado con la toolchain estable más reciente (macos-26 + `setup-xcode latest`); el código debe compilar en Swift 6.3 (CI) y 6.4 (local).
- **D11** · Audio: vúmetro de canal post-fader pre-gate y solo-escucha post-fader (decisión ORQ, a confirmar por el usuario).
- **D7** · Regla SwiftLint `inclusive_language` desactivada («Master» es terminología del plan).
- **D8** · Solapamiento ImageInput/ColorInput (plan: B y C): B hace la carga a textura en Render
  (`ImageTextureLoader`, render de color); C hace las clases `FrameSource` en Media con un cargador inyectable.
- **D9** · T41 y T51 se adelantan a la Ola 1 contra contratos/mocks; la conexión con `SwitcherState`/`PlaylistSequencer` reales se valida en Ola 2.
