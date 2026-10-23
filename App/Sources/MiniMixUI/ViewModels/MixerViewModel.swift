import Core
import Foundation
import Observation

/// Mixer: un canal por entrada con audio + Master. Escribe solo con `Command`s.
@MainActor @Observable
public final class MixerViewModel {
    public struct Channel: Identifiable, Hashable, Sendable {
        public let id: InputID
        public var number: Int
        public var name: String
        public var volume: Float
        public var muted: Bool
        public var solo: Bool
        public var followsProgram: Bool
        public var onProgram: Bool
        /// Pico por canal (dBFS).
        public var levels: [Float]
    }

    /// Último valor de `AudioMixing.meters` (nil = Master).
    public private(set) var levels: [InputID?: [Float]] = [:]
    public private(set) var solos: Set<InputID> = []
    @ObservationIgnored weak var app: AppViewModel?

    init() {}

    public var channels: [Channel] {
        guard let app else { return [] }
        return app.project.inputs.enumerated().compactMap { index, input in
            guard input.kind.hasAudio else { return nil }
            return Channel(
                id: input.id, number: index + 1, name: input.name, volume: input.volume,
                muted: input.muted, solo: solos.contains(input.id), followsProgram: input.audioFollowsProgram,
                onProgram: app.project.program == input.id, levels: levels[input.id] ?? []
            )
        }
    }

    public var masterVolume: Float { app?.project.masterVolume ?? 1 }
    public var masterLevels: [Float] { levels[nil] ?? [] }

    // MARK: Acciones (→ Command)

    public func setVolume(_ volume: Float, for id: InputID) { app?.send(.setVolume(id, min(max(volume, 0), 2))) }
    public func toggleMute(_ id: InputID) {
        guard let input = app?.descriptor(id) else { return }
        app?.send(.setMute(id, !input.muted))
    }
    public func toggleSolo(_ id: InputID) { app?.send(.setSolo(id, !solos.contains(id))) }
    public func setFollowsProgram(_ follows: Bool, for id: InputID) { app?.send(.setAudioFollowsProgram(id, follows)) }
    public func setMasterVolume(_ volume: Float) { app?.send(.setMasterVolume(min(max(volume, 0), 2))) }

    // MARK: Entrada desde el despachador / servicios

    func receive(_ newLevels: [InputID?: [Float]]) { levels = newLevels }

    func recordSolo(_ solo: Bool, for id: InputID) {
        if solo { solos.insert(id) } else { solos.remove(id) }
    }

    func reset() {
        levels = [:]
        solos = []
    }

    /// dBFS → 0…1 para el vúmetro (escala lineal en dB de −60 a 0).
    public nonisolated static func meterFraction(_ dbfs: Float) -> Double {
        Double(min(max((dbfs + 60) / 60, 0), 1))
    }
}
