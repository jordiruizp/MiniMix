# MiniMix — PROGRESS

Mantenido por el orquestador. Estados: ⬜ pendiente · 🟦 en curso · 🟨 en revisión · ✅ integrado en main · ⛔ bloqueado

## Olas

| Ola | Estado |
|---|---|
| 0 · Andamiaje + contratos + CI + CLAUDE.md | 🟨 contratos pendientes de validación del usuario |
| 1 · A, B, C, E, G(mocks), H | ⬜ |
| 2 · D, F, G-real, ORQ T80 | ⬜ |
| 3 · H rendimiento, E sync, G pulido | ⬜ |
| 4 · T99 release | ⬜ |

## Tareas

| ID | Agente | Tarea | Estado | Rama | Notas |
|---|---|---|---|---|---|
| T00 | ORQ | Andamiaje SwiftPM, 7 paquetes, sandbox, SwiftLint, CI | ✅ | main | CI local verde; CI de GitHub sin verificar (sin push) |
| T01 | ORQ | Contracts.swift + tipos base + CoreMocks | 🟨 | main | Esperando validación → tag `contracts-v1` |
| T02 | ORQ | CLAUDE.md | ✅ | main | |
| T10 | A | Modelos Codable + versión de esquema | ⬜ | | |
| T11 | A | SwitcherState | ⬜ | | |
| T12 | A | PlaylistSequencer | ⬜ | | |
| T20 | B | MetalContext, TexturePool, MonitorView | ⬜ | | |
| T21 | B | Compositor + shaders | ⬜ | | |
| T22 | B | ImageInput → textura | ⬜ | | |
| T30 | C | MasterClock | ⬜ | | |
| T31 | C | VideoInput | ⬜ | | depende de T20 |
| T32 | C | AudioInput + InputManager | ⬜ | | |
| T40 | E | AudioEngine | ⬜ | | |
| T41 | E | Audio sigue a Programa + fundido | ⬜ | | depende de T11 |
| T50 | G | Layout con mocks | ⬜ | | |
| T51 | G | Panel de playlist | ⬜ | | depende de T10 |
| T60 | H | Generador TestMedia | ⬜ | | |
| T61 | H | Harness de estrés | ⬜ | | |
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
