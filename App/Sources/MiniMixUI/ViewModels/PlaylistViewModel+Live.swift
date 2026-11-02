import Core
import Foundation
import Media

/// Fuente de playlist que lleva su propio secuenciador (`PlaylistInput` de Media). En modo real
/// manda ella: la UI le reenvía el transporte y refleja su estado; el secuenciador de la UI solo
/// se usa en la demo con mocks.
public protocol PlaylistSourceControlling: AnyObject {
    func play()
    func pause()
    func next()
    func previous()
    func jump(to item: ItemID)
    func restartItem()
    func update(playlist: Playlist)
    var sequencerState: SequencerState { get }
    var currentItemID: ItemID? { get }
    var upcomingItemID: ItemID? { get }
    var itemRemainingTime: Double? { get }
    var playlistRemainingTime: Double? { get }
}

extension PlaylistInput: PlaylistSourceControlling {}

extension PlaylistViewModel {
    /// Fuente real de la playlist, si la hay (modo real).
    func liveSource(for id: InputID) -> PlaylistSourceControlling? {
        app?.services.inputs.frameSource(for: id) as? PlaylistSourceControlling
    }

    /// Reenvía un evento de transporte a la fuente real. `.play` ya lo recibió como
    /// `FrameSource.play()`; `.itemEnded` lo decide la propia fuente.
    func forward(_ event: SequencerEvent, to source: PlaylistSourceControlling) {
        switch event {
        case .next: source.next()
        case .previous: source.previous()
        case .jump(let item): source.jump(to: item)
        case .restartItem: source.restartItem()
        case .play, .itemEnded: break
        }
        liveRevision += 1
    }

    /// Índice en la playlist de la UI de un item de la fuente.
    func index(of item: ItemID?, in id: InputID) -> Int? {
        guard let item else { return nil }
        return playlist(for: id)?.items.firstIndex { $0.id == item }
    }

    /// Refresco (~4 Hz): refleja held/ended de la fuente en el estado de reproducción de la entrada.
    func syncLiveStates() {
        guard let app else { return }
        for input in app.project.inputs where input.kind == .playlist {
            guard let source = liveSource(for: input.id), let info = app.playback[input.id] else { continue }
            switch source.sequencerState {
            case .held where info.state == .playing:
                app.playback[input.id]?.pause(at: app.now)
                app.playback[input.id]?.state = .held
                liveRevision += 1
            case .ended where info.state != .ended:
                app.playback[input.id]?.end(at: app.now)
                liveRevision += 1
            case .playing where info.state == .held || info.state == .ended:
                app.playback[input.id]?.play(at: app.now)
                liveRevision += 1
            default:
                break
            }
        }
    }
}
