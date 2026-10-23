import Core
import CoreMocks
import Foundation
@testable import MiniMixUI

/// Secuenciador espía: registra eventos y playlists recibidas; avance lineal simple.
struct SpySequencer: PlaylistSequencing {
    final class Log: @unchecked Sendable {
        private let box = Locked<(events: [SequencerEvent], playlists: [Playlist])>(([], []))
        var events: [SequencerEvent] { box.current.events }
        var lastPlaylist: Playlist? { box.current.playlists.last }
        func record(_ event: SequencerEvent) { box.withLock { $0.events.append(event) } }
        func record(_ playlist: Playlist) { box.withLock { $0.playlists.append(playlist) } }
    }

    let log: Log
    var playlist: Playlist { didSet { log.record(playlist) } }
    private(set) var state: SequencerState = .idle

    init(playlist: Playlist, log: Log) {
        self.playlist = playlist
        self.log = log
    }

    var upcomingIndex: Int? {
        guard case .playing(let index) = state, index + 1 < playlist.items.count else { return nil }
        return index + 1
    }

    mutating func handle(_ event: SequencerEvent) -> SequencerState {
        log.record(event)
        switch (event, state) {
        case (.play, .idle), (.play, .ended):
            state = .playing(index: 0)
        case (.next, .playing(let index)), (.itemEnded, .playing(let index)):
            state = index + 1 < playlist.items.count ? .playing(index: index + 1) : .ended
        case (.previous, .playing(let index)):
            state = .playing(index: max(index - 1, 0))
        case (.jump(let item), _):
            if let index = playlist.items.firstIndex(where: { $0.id == item }) { state = .playing(index: index) }
        default:
            break
        }
        return state
    }
}

/// Reloj de interfaz controlable desde el test.
final class TestTime: @unchecked Sendable {
    var seconds: Double = 0
}

@MainActor
struct Harness {
    let app: AppViewModel
    let audio: MockAudioMixer
    let inputs: MockInputManager
    let sequencerLog: SpySequencer.Log
    let output: MockOutputPresenter
    let time: TestTime
    let clock: MockClock

    /// `spySequencer: false` usa el `PlaylistSequencer` real de `AppServices.mocks()`.
    init(project: Project = SampleData.project, spySequencer: Bool = true,
         makeSwitcher: (@MainActor (Project) -> any SwitcherStateMachine)? = nil) {
        let audio = MockAudioMixer()
        let inputs = MockInputManager()
        let log = SpySequencer.Log()
        let output = MockOutputPresenter()
        let time = TestTime()
        let clock = MockClock()
        var services = AppServices.mocks(project: project, audio: audio, demo: false)
        services.inputs = inputs
        services.output = output
        services.clock = clock
        if let makeSwitcher { services.makeSwitcher = makeSwitcher }
        if spySequencer { services.makeSequencer = { SpySequencer(playlist: $0, log: log) } }
        services.uptime = { time.seconds }
        self.app = AppViewModel(services: services)
        self.audio = audio
        self.inputs = inputs
        self.sequencerLog = log
        self.output = output
        self.time = time
        self.clock = clock
    }

    var project: Project { app.project }
    func input(_ number: Int) -> InputDescriptor { app.project.inputs[number - 1] }
    /// En `SampleData.project`: 1 Vídeo, 2 Imagen, 3 Color, 4 Playlist, 5 Música.
    var video: InputID { input(1).id }
    var image: InputID { input(2).id }
    var color: InputID { input(3).id }
    var playlist: InputID { input(4).id }
    var music: InputID { input(5).id }

    func advance(to seconds: Double) {
        time.seconds = seconds
        app.refresh(now: seconds)
    }
}
