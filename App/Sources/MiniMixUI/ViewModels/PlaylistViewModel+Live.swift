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
    /// Encaje de los items (fundidos entre items).
    var itemFit: FitMode { get set }
}

/// Lo que la UI refleja de una fuente de playlist; si cambia, las vistas se reevalúan.
struct LivePlaylistSnapshot: Equatable {
    var state: SequencerState
    var current: ItemID?
    var upcoming: ItemID?
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
        // La fuente aplica el comando en su cola: la UI se actualiza cuando `syncLiveStates`
        // (o `itemChanged`) vea el cambio, no ahora con valores viejos.
    }

    /// Índice en la playlist de la UI de un item de la fuente.
    func index(of item: ItemID?, in id: InputID) -> Int? {
        guard let item else { return nil }
        return playlist(for: id)?.items.firstIndex { $0.id == item }
    }

    /// Refresco (~4 Hz). Compara cada fuente con su instantánea anterior y:
    /// - sube `liveRevision` si cambió estado, item actual o siguiente (el panel se reevalúa con
    ///   los valores ya aplicados por la cola de la fuente);
    /// - refleja en la entrada solo las **transiciones** de la fuente (a espera, fin o reproducción),
    ///   así un refresco que llega antes de que la cola procese `play` no la rebaja (sin parpadeo);
    /// - si la entrada debería sonar pero la fuente sigue en reposo dos refrescos seguidos (un
    ///   `play` que llegó mientras se preparaba), le reenvía `play()`.
    func syncLiveStates() {
        guard let app else { return }
        for input in app.project.inputs where input.kind == .playlist {
            guard let source = liveSource(for: input.id) else { continue }
            let id = input.id
            let snapshot = LivePlaylistSnapshot(state: source.sequencerState, current: source.currentItemID,
                                                upcoming: source.upcomingItemID)
            let previous = liveSnapshots[id]
            if previous != snapshot {
                liveSnapshots[id] = snapshot
                liveRevision += 1
            }
            let playback = app.playback[id]?.state
            if previous?.state != snapshot.state { reflectTransition(to: snapshot.state, for: id) }
            if snapshot.state == .idle, playback == .playing {
                idleWhilePlaying[id, default: 0] += 1
                if idleWhilePlaying[id, default: 0] >= 2 {
                    idleWhilePlaying[id] = 0
                    source.play()
                }
            } else {
                idleWhilePlaying[id] = nil
            }
        }
    }

    private func reflectTransition(to state: SequencerState, for id: InputID) {
        guard let app, let info = app.playback[id] else { return }
        switch state {
        case .held where info.state == .playing:
            app.playback[id]?.pause(at: app.now)
            app.playback[id]?.state = .held
        case .ended where info.state != .ended:
            app.playback[id]?.end(at: app.now)
        case .playing where info.state == .held || info.state == .ended:
            app.playback[id]?.play(at: app.now)
        default:
            break
        }
    }
}
