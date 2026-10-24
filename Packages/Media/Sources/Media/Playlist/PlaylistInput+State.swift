import Core
import Foundation
import Metal

extension PlaylistInput {
    /// Una ranura (A/B): un item cargado.
    struct Slot {
        let index: Int
        let item: PlaylistItem
        let source: FrameSource
        var ready = false
        var started = false
        /// Duración efectiva (s), redondeada a fotogramas en imagen/color.
        var duration: Double?
        /// Reloj de items sin posición propia (imagen, color, audio).
        var elapsedBase: Double = 0
        var runningSince: HostTime?

        var isVideo: Bool { source is VideoInput }
    }

    /// Lo que se ve de un item.
    enum Visual {
        case source(FrameSource)
        case texture(MTLTexture)
        case black
    }

    struct Fade {
        var from: Visual
        var to: Visual
        var start: HostTime
        var duration: Double
    }

    enum PendingKind {
        case cut(Visual)
        case fade(Double)
        case hold
        case end
    }

    /// Cambio programado en la rejilla de ticks.
    struct Pending {
        var at: HostTime
        var kind: PendingKind
    }

    struct State {
        var sequencer: PlaylistSequencer
        var fit: FitMode
        var frameDuration: Double
        var prepared = false
        var active: Slot?
        var standby: Slot?
        /// Saliente durante un fundido.
        var outgoing: Slot?
        var pending: Pending?
        var fadeEnd: HostTime?
        /// Arranque preciso programado del entrante (se invalida al cancelar).
        var armID = 0
        var scheduledPlay: Int?
        var scheduledSource: ObjectIdentifier?
        /// Latencia estimada de arranque de AVPlayer (s) de un vídeo precargado y en pausa:
        /// 0,25–0,31 s medidos en MacBook Neo; se corrige con cada arranque programado.
        var startLatency = 0.3
        var userPaused = false
        var decodingEnabled = true
        var lastTick: HostTime?
        var lateMarked = false
        var loading = 0
        /// Liberaciones diferidas pendientes.
        var releasing = 0
        var failures = 0
        var stats = Stats()
        var knownDurations: [ItemID: Double] = [:]
        // Render (lo lee `texture(for:)`).
        var shown: Visual?
        var armed: (visual: Visual, at: HostTime)?
        var fade: Fade?

        var timelineFrozen: Bool { userPaused || !decodingEnabled }

        var isPlaying: Bool {
            if case .playing = sequencer.state { true } else { false }
        }
    }
}

/// Segundos transcurridos en el item de `slot` (desde su In) en el instante `time`: el vídeo
/// por la posición de su reproductor; imagen, color y audio por su propio reloj de ticks.
func elapsed(of slot: PlaylistInput.Slot, at time: HostTime) -> Double {
    if slot.isVideo {
        let position = slot.source.currentTime ?? slot.item.inPoint ?? 0
        return max(0, position - (slot.item.inPoint ?? 0))
    }
    return slot.elapsedBase + (slot.runningSince.map { max(0, time - $0) } ?? 0)
}
