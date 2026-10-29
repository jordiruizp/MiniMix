# MiniMix — PROGRESS

Mantenido por el orquestador. Estados: ⬜ pendiente · 🟦 en curso · 🟨 en revisión · ✅ integrado en main · ⛔ bloqueado

## Olas

| Ola | Estado |
|---|---|
| 0 · Andamiaje + contratos + CI + CLAUDE.md | ✅ |
| 1 · A, B, C, E, G(mocks), H | ✅ todos integrados |
| 2 · D, F, G-real, ORQ T80 | 🟦 F y T80 integrados · D en curso · G-real en curso |
| 3 · H rendimiento, E sync, G pulido | 🟦 E sync: PR #14 R=APROBAR CON MENORES (pendiente integrar) · C con transitorio de arranque · H y G esperan |
| 4 · T99 release | ⬜ |

## Tareas

| ID | Agente | Tarea | Estado | Rama | Notas |
|---|---|---|---|---|---|
| T00 | ORQ | Andamiaje SwiftPM, 7 paquetes, sandbox, SwiftLint, CI | ✅ | main | CI local verde; CI de GitHub sin verificar (sin push) |
| T01 | ORQ | Contracts.swift + tipos base + CoreMocks | ✅ | main | `contracts-v1` 2026-10-23 · `contracts-v2` 2026-10-24 |
| T02 | ORQ | CLAUDE.md | ✅ | main | |
| T10 | A | Modelos Codable + versión de esquema | ✅ | feat/a-core → main | |
| T11 | A | SwitcherState | ✅ | feat/a-core → main | 34 tests · cobertura 98,95 % |
| T12 | A | PlaylistSequencer | ✅ | feat/a-core(+fixes) → main | 113 tests Core; fixes de revisión integrados |
| T20 | B | MetalContext, TexturePool, MonitorView | ✅ | feat/b-render → main | |
| T21 | B | Compositor + shaders | ✅ | feat/b-render → main | |
| T22 | B | ImageInput → textura | ✅ | feat/b-render → main | |
| T30 | C | MasterClock | ✅ | feat/c-media → main | |
| T31 | C | VideoInput | ✅ | feat/c-media → main | |
| T32 | C | AudioInput + InputManager | ✅ | feat/c-media → main | |
| T40 | E | AudioEngine | ✅ | feat/e-audio → main | |
| T41 | E | Audio sigue a Programa + fundido | ✅ | feat/e-audio → main | contra el contrato (AudioMixing + TransitionCurve); no necesita T11 |
| T50 | G | Layout con mocks | ✅ | feat/g-ui-mocks → main | fase mocks; conexión real en Ola 2 |
| T51 | G | Panel de playlist | ✅ | feat/g-ui-mocks → main | fase mocks; conexión real en Ola 2 |
| T60 | H | Generador TestMedia | ✅ | feat/h-qa → main | |
| T61 | H | Harness de estrés | ✅ | feat/h-qa → main | |
| T70 | D | PlaylistInput A/B | ⛔ devuelto | feat/d-playlist (PR #13) | R: DEVOLVER (bucle de reintentos con item fallido; AVFoundation bajo el lock del render; pool de fundido sin reciclar…) → D corrigiendo |
| T71 | D | Fundido entre items + hold | 🟨 | feat/d-playlist (PR #13) | fundido ΔE 0,23 · en revisión |
| T80 | ORQ | Integración switcher | ✅ | feat/orq-t80 → main (PR #9, 91f396b) | sesión completa verificada en píxeles reales; smoke con sandbox en CI (84 MB) |
| G-real | G | UI con módulos reales | 🟨 | feat/g-ui-real (PR #12) | correcciones hechas (281ae01) · CI en cola → integrar si verde |
| T81 | F | Output externo | ✅ | feat/f-output-persistence → main | |
| T82 | F | Persistence | ✅ | feat/f-output-persistence → main | |
| T90 | H | Estrés 1 h / 2 h | ⬜ | | Ola 3 |
| T91 | G | Pulido UI | ⬜ | | Ola 3 |
| T99 | ORQ | Firma, notarización, DMG | ⬜ | | Ola 4 |

## Contratos

- **contracts-v2** (2026-10-24), aprobado por el usuario («aprobado todo como recomiendas»):
  PC1 `Effect.transitionCancelled` · PC2 `RGBAColor` = sRGB codificado · PC3 `InputManaging.update` ·
  PC4 `FrameSource.currentTime` (por defecto nil) · PC5 `Command.setFit` · PC6 `ticks` = una suscripción por acceso,
  dueño App/T80 · PC7 `SwitcherStateMachine.removeInput` · PC8 `PlaylistSequencing.lastEventRestartsItem`
  (por defecto false) · PC9 `meters` con un único consumidor. D11 confirmada (VU post-fader pre-gate, solo post-fader).
  Integrado por el ORQ con los ajustes mínimos en SwitcherState, CoreMocks y App para que main compile.
  Pendiente en ramas abiertas: C implementa `InputManager.update` y `currentTime`.

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
| #1 | feat/e-audio-fixes | ✅ integrado (4dd30c8) · re-revisión APROBAR · CI verde Swift 6.3 |
| #2 | feat/b-render-fixes | ✅ integrado (ffddbab) |
| #5 | feat/b-render-fixes2 | ✅ integrado (8b4a90e) |
| #6 | feat/c-media (T30–T32) | ✅ integrado (8181341) · memoria retenida peor caso ~900 → ~120 MB |
| #7 | feat/b-render-ci | ✅ integrado (19b7cd1) |
| #8 | feat/f-output-persistence (T81, T82) | ✅ integrado (12c8856) · pendiente probar con pantalla externa real |
| #9 | feat/orq-t80 (T80) | ✅ integrado (91f396b) |
| #10 | feat/e-audio-sandbox | ✅ integrado (c0e05bb) |
| #11 | feat/h-ci-perf | ✅ integrado |
| #3 | feat/h-qa (T60, T61) | ✅ integrado · Core/Render/Audio verificados en local (Actions sin minutos) |
| #4 | feat/g-ui-mocks (T50, T51) | ✅ integrado (5b3c5a3) |

## GitHub Actions

- ~~2026-10-23: jobs no arrancados por límite de facturación~~ → resuelto: el usuario hizo público el repo.
- **D14** · `ProjectDecoder` sigue rechazando `schemaVersion < 1` (v1 es el primer esquema); las migraciones se prueban con el registro.
- **D13** · Tests de rendimiento: miden siempre y exigen objetivos solo fuera de CI (runners macOS = VM con GPU paravirtualizada).
- **D12** · CI reducido: un solo job macOS (`scripts/ci.sh` + bundle) en push a main y PRs no borrador, más `core-linux`.

## ~~Bloqueo: Audio en sandbox~~ (resuelto, PR #10)

- Causa: con sandbox solo se crean AU en proceso con `kAudioComponentFlag_SandboxSafe`. Arreglado en c0e05bb;
  además se sondea con la API C para que un fallo sea un error Swift y no una excepción ObjC.
- 2026-10-24 (T80): `AudioEngine()` termina la app empaquetada con sandbox (excepción AVFAudio `error -3000` al
  crear el AUv3 propio `RampGainUnit`). Sin sandbox funciona; `swift test` no corre en sandbox. Asignado a E
  (`feat/e-audio-sandbox`). Nueva prueba de humo `scripts/smoke-app.sh` en el CI para que no vuelva a pasar.

## Pendiente tras integrar D

- C: `InputManager.applyInPlace` debe llamar a `PlaylistInput.update(playlist:)` en vez de sustituir la playlist (hoy vuelve al primer item en cada edición).
- C: `VideoInput.play(atHostTime:)` (preroll + setRate atHostTime) para arranque exacto en playlist; `InputManager.applyInPlace` reenvía `fit` a `PlaylistInput.itemFit`.
- App: conectar `PlaylistInput.factory(environment:)` en `AppServices.live()` y reenviar comandos de playlist a la fuente (decisión: manda el secuenciador de PlaylistInput).
- Duplicado aceptado: lector mínimo de código de fotograma en tests de Media (`FrameCodeProbe`), porque Media no puede depender de TestSupport.

## Pendiente tras integrar E (sync A/V)

- Revisión PR #14: APROBAR CON MENORES. Menores para E: retardo antes de ganancia/medidor en etapas con anillo; permitir
  ajuste manual negativo; doc de videoPresentationLatency (la latencia del proyector va en la compensación global);
  HAL fuera del lock; tolerar throw de AudioEngine() en tests; test de cambio de retardo en caliente sin clic.

- App: `LiveInputs.attachAudio` → `audio.setSyncProfile(source is VideoInput ? .playerTap : .direct, for:)`
  (y `.playerTap` para items de vídeo de playlist); `audio.videoPresentationLatency = frameDuration` (recalcular al
  cambiar fps; sumar latencia del proyector en salida externa).
- C (obligatorio): transitorio de arranque (1.er segundo tras play(): audio 142–240 ms tarde) → `preroll(atRate:)` +
  marcar el tap con `timeRangeOut` y alinear por tiempo de item en el AVAudioSourceNode (elimina también ±7 ms entre reproducciones).
- H: test de integración de claqueta en Tests/ (Media + Audio), exigiendo |desfase| < 20 ms solo fuera de CI.
- Medido (altavoces internos): desfase estable −10,1…+1,9 ms (media −3,1) con compensación; sin ella ≈ −92 ms.

## Deuda menor (no bloqueante, para Ola 3)

- Audio: `renderBlockOutlivesUnit` depende de comportamiento no documentado del framework (usar autoreleasepool o deallocate explícito);
  `drainLifecycleQueue()` sin `dispatchPrecondition(.notOnQueue)`; test de retiro por reloj de pared.

## Bloqueos

- ~~Sin Xcode~~ → resuelto 2026-10-23: Xcode 27.1 instalado. `xcode-select` sigue en CLT (cambiarlo requiere sudo);
  los scripts usan Xcode vía `scripts/env.sh`. CI local verde con Xcode.
- ~~Sin push a GitHub~~ → resuelto: `gh` autenticado; main y tag `contracts-v1` subidos. CI de Actions en `macos-26` (Swift 6.3.3) + Linux (`swift:latest`).
- ~~CI rojo en Audio/App/Tests~~ → resuelto con PR #1 (LockedState en lugar de Mutex).

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
- **D11** · Audio: vúmetro de canal post-fader pre-gate y solo-escucha post-fader (confirmada por el usuario).
- **D7** · Regla SwiftLint `inclusive_language` desactivada («Master» es terminología del plan).
- **D8** · Solapamiento ImageInput/ColorInput (plan: B y C): B hace la carga a textura en Render
  (`ImageTextureLoader`, render de color); C hace las clases `FrameSource` en Media con un cargador inyectable.
- **D9** · T41 y T51 se adelantan a la Ola 1 contra contratos/mocks; la conexión con `SwitcherState`/`PlaylistSequencer` reales se valida en Ola 2.
