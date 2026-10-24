// CoreMocks — implementaciones falsas de los contratos para avanzar en paralelo.
// Propiedad: ORQUESTADOR. Solo para tests y para la UI con datos falsos (G · T50).

import Core
import Foundation

/// Caja con cerrojo para estado mutable en mocks `Sendable`.
public final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    public init(_ value: Value) { self.value = value }
    public func withLock<R>(_ body: (inout Value) throws -> R) rethrows -> R {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }
    public var current: Value { withLock { $0 } }
}

// MARK: - Switcher

/// Switcher mínimo: solo selectPreview y cut (intercambio). La implementación
/// completa (fade, T-bar) es `SwitcherState` (A · T11).
public struct MockSwitcher: SwitcherStateMachine {
    public private(set) var preview: InputID?
    public private(set) var program: InputID?
    public private(set) var transition: TransitionState = .idle

    public init(preview: InputID? = nil, program: InputID? = nil) {
        self.preview = preview
        self.program = program
    }

    public mutating func apply(_ cmd: Command, at time: HostTime) -> [Effect] {
        switch cmd {
        case .selectPreview(let id):
            preview = id
            return [.busesChanged(preview: preview, program: program)]
        case .cut, .fade, .tbar:
            swap(&preview, &program)
            return [.busesChanged(preview: preview, program: program)]
        default:
            return [.forward(cmd)]
        }
    }

    public mutating func tick(at time: HostTime) -> [Effect] { [] }

    public mutating func removeInput(_ id: InputID, at time: HostTime) -> [Effect] {
        guard preview == id || program == id else { return [] }
        if preview == id { preview = nil }
        if program == id { program = nil }
        return [.busesChanged(preview: preview, program: program)]
    }
}

/// Secuenciador trivial: avanza linealmente sin modos ni bucle.
public struct MockSequencer: PlaylistSequencing {
    public var playlist: Playlist
    public private(set) var state: SequencerState = .idle

    public init(playlist: Playlist) { self.playlist = playlist }

    public var upcomingIndex: Int? {
        guard case .playing(let i) = state, i + 1 < playlist.items.count else { return nil }
        return i + 1
    }

    public mutating func handle(_ event: SequencerEvent) -> SequencerState {
        switch (event, state) {
        case (.play, .idle), (.play, .ended):
            state = playlist.items.isEmpty ? .ended : .playing(index: 0)
        case (.itemEnded, .playing), (.next, .playing):
            state = upcomingIndex.map { .playing(index: $0) } ?? .ended
        default:
            break
        }
        return state
    }
}

// MARK: - Reloj

/// Reloj manual: los tests avanzan el tiempo con `advance(frames:)`.
public final class MockClock: MasterClockProtocol {
    public let frameRate: FrameRate
    private let state = Locked(HostTime.zero)
    private let subscribers = Locked([UUID: AsyncStream<HostTime>.Continuation]())

    public init(frameRate: FrameRate = .fps60) {
        self.frameRate = frameRate
    }

    /// contracts-v2: cada acceso crea una suscripción nueva.
    public var ticks: AsyncStream<HostTime> {
        let (stream, continuation) = AsyncStream.makeStream(of: HostTime.self, bufferingPolicy: .bufferingNewest(1))
        let key = UUID()
        subscribers.withLock { $0[key] = continuation }
        continuation.onTermination = { [weak self] _ in _ = self?.subscribers.withLock { $0.removeValue(forKey: key) } }
        return stream
    }

    public var now: HostTime { state.current }
    public func start() {}
    public func stop() {
        let all = subscribers.withLock { subs -> [AsyncStream<HostTime>.Continuation] in
            defer { subs.removeAll() }
            return Array(subs.values)
        }
        all.forEach { $0.finish() }
    }

    public func advance(frames: Int = 1) {
        for _ in 0..<frames {
            let t = state.withLock { time -> HostTime in
                time.seconds += frameRate.frameDuration
                return time
            }
            subscribers.withLock { Array($0.values) }.forEach { $0.yield(t) }
        }
    }
}

// MARK: - Audio

public final class MockAudioMixer: AudioMixing {
    public struct TransitionCall: Sendable, Equatable {
        public var from: InputID?
        public var to: InputID?
        public var progress: Double
    }

    public struct Snapshot: Sendable {
        public var volumes: [InputID: Float] = [:]
        public var mutes: [InputID: Bool] = [:]
        public var solos: [InputID: Bool] = [:]
        public var follows: [InputID: Bool] = [:]
        public var master: Float = 1
        public var lastTransition: TransitionCall?
    }

    public let recorded = Locked(Snapshot())
    private let continuation: AsyncStream<[InputID?: [Float]]>.Continuation
    public let meters: AsyncStream<[InputID?: [Float]]>

    public init() {
        (meters, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    public func setVolume(_ volume: Float, for input: InputID) { recorded.withLock { $0.volumes[input] = volume } }
    public func setMute(_ muted: Bool, for input: InputID) { recorded.withLock { $0.mutes[input] = muted } }
    public func setSolo(_ solo: Bool, for input: InputID) { recorded.withLock { $0.solos[input] = solo } }
    public func setAudioFollowsProgram(_ follows: Bool, for input: InputID) {
        recorded.withLock { $0.follows[input] = follows }
    }
    public func setMasterVolume(_ volume: Float) { recorded.withLock { $0.master = volume } }
    public func transition(from: InputID?, to: InputID?, progress: Double) {
        recorded.withLock { $0.lastTransition = TransitionCall(from: from, to: to, progress: progress) }
    }

    /// Publica niveles falsos (dBFS) para la UI.
    public func emit(_ levels: [InputID?: [Float]]) { continuation.yield(levels) }
}

// MARK: - Persistencia

public final class MockProjectStore: ProjectStoring {
    private let files = Locked([URL: Data]())
    public init() {}

    public func save(_ project: Project, to url: URL) throws {
        let data = try JSONEncoder().encode(project)
        files.withLock { $0[url] = data }
    }

    public func load(from url: URL) throws -> Project {
        guard let data = files.withLock({ $0[url] }) else { throw CocoaError(.fileNoSuchFile) }
        return try JSONDecoder().decode(Project.self, from: data)
    }

    public func unresolvedReferences(in project: Project) -> [MediaReference] { [] }
}

// MARK: - Salida

@MainActor
public final class MockOutputPresenter: OutputPresenting {
    public var displays: [DisplayInfo]
    public private(set) var activeDisplay: DisplayInfo.ID?
    public let displayChanges: AsyncStream<[DisplayInfo]>
    private let continuation: AsyncStream<[DisplayInfo]>.Continuation

    public init(displays: [DisplayInfo] = [
        DisplayInfo(id: 1, name: "Pantalla integrada", size: PixelSize(width: 2560, height: 1664), isBuiltIn: true),
        DisplayInfo(id: 2, name: "Proyector", size: .hd1080, isBuiltIn: false)
    ]) {
        self.displays = displays
        (displayChanges, continuation) = AsyncStream.makeStream()
    }

    public func show(on display: DisplayInfo.ID) { activeDisplay = display }
    public func hide() { activeDisplay = nil }

    public func simulate(_ displays: [DisplayInfo]) {
        self.displays = displays
        if let active = activeDisplay, !displays.contains(where: { $0.id == active }) { activeDisplay = nil }
        continuation.yield(displays)
    }
}

// MARK: - Datos de ejemplo

public enum SampleData {
    public static let project: Project = {
        let video = InputDescriptor(name: "Vídeo", content: .video(MediaReference(path: "/tmp/clip.mov")))
        let image = InputDescriptor(name: "Imagen", content: .image(MediaReference(path: "/tmp/logo.png")))
        let color = InputDescriptor(name: "Color", content: .color(RGBAColor(red: 0.1, green: 0.3, blue: 0.8)))
        let playlist = InputDescriptor(name: "Playlist", content: .playlist(Playlist(items: [
            PlaylistItem(source: .video(MediaReference(path: "/tmp/a.mp4"))),
            PlaylistItem(source: .image(MediaReference(path: "/tmp/b.png")), duration: 5),
            PlaylistItem(source: .color(.black), duration: 3, stopAfter: true)
        ])))
        let audio = InputDescriptor(name: "Música", content: .audio(MediaReference(path: "/tmp/m.wav"), visual: .black))
        return Project(inputs: [video, image, color, playlist, audio], preview: image.id, program: video.id)
    }()
}
