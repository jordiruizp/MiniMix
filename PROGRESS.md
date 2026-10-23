# MiniMix — PROGRESS

Mantenido por el orquestador. Estados: ⬜ pendiente · 🟦 en curso · 🟨 en revisión · ✅ integrado en main · ⛔ bloqueado

## Olas

| Ola | Estado |
|---|---|
| 0 · Andamiaje + contratos + CI + CLAUDE.md | ✅ |
| 1 · A, B, C, E, G(mocks), H | 🟦 lanzada 2026-10-23 |
| 2 · D, F, G-real, ORQ T80 | ⬜ |
| 3 · H rendimiento, E sync, G pulido | ⬜ |
| 4 · T99 release | ⬜ |

## Tareas

| ID | Agente | Tarea | Estado | Rama | Notas |
|---|---|---|---|---|---|
| T00 | ORQ | Andamiaje SwiftPM, 7 paquetes, sandbox, SwiftLint, CI | ✅ | main | CI local verde; CI de GitHub sin verificar (sin push) |
| T01 | ORQ | Contracts.swift + tipos base + CoreMocks | ✅ | main | Aprobado por el usuario 2026-10-23 · tag `contracts-v1` |
| T02 | ORQ | CLAUDE.md | ✅ | main | |
| T10 | A | Modelos Codable + versión de esquema | 🟦 | feat/a-core | |
| T11 | A | SwitcherState | 🟦 | feat/a-core | |
| T12 | A | PlaylistSequencer | 🟦 | feat/a-core | |
| T20 | B | MetalContext, TexturePool, MonitorView | 🟦 | feat/b-render | |
| T21 | B | Compositor + shaders | 🟦 | feat/b-render | |
| T22 | B | ImageInput → textura | 🟦 | feat/b-render | |
| T30 | C | MasterClock | 🟦 | feat/c-media | |
| T31 | C | VideoInput | 🟦 | feat/c-media | CVMetalTextureCache propio; se pasa a MetalContext al integrar |
| T32 | C | AudioInput + InputManager | 🟦 | feat/c-media | |
| T40 | E | AudioEngine | 🟦 | feat/e-audio | |
| T41 | E | Audio sigue a Programa + fundido | 🟦 | feat/e-audio | contra el contrato (AudioMixing + TransitionCurve); no necesita T11 |
| T50 | G | Layout con mocks | 🟦 | feat/g-ui-mocks | |
| T51 | G | Panel de playlist | 🟦 | feat/g-ui-mocks | con MockSequencer; conexión al real en Ola 2 |
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

## Bloqueos

- ~~Sin Xcode~~ → resuelto 2026-10-23: Xcode 27.1 instalado. `xcode-select` sigue en CLT (cambiarlo requiere sudo);
  los scripts usan Xcode vía `scripts/env.sh`. CI local verde con Xcode.
- **Sin push a GitHub** (sin credenciales `gh`/git): el CI de Actions no se ha podido ejecutar. Puerta de calidad = `scripts/ci.sh` local.

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
- **D7** · Regla SwiftLint `inclusive_language` desactivada («Master» es terminología del plan).
- **D8** · Solapamiento ImageInput/ColorInput (plan: B y C): B hace la carga a textura en Render
  (`ImageTextureLoader`, render de color); C hace las clases `FrameSource` en Media con un cargador inyectable.
- **D9** · T41 y T51 se adelantan a la Ola 1 contra contratos/mocks; la conexión con `SwitcherState`/`PlaylistSequencer` reales se valida en Ola 2.
