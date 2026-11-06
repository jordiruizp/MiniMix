import Core
import CoreMocks
import Foundation
@testable import MiniMixUI
import Observation
import Testing

/// Revisión del PR #17: la UI refleja la fuente de playlist real por instantáneas (sin GPU).
@Suite("Playlist real · sincronía")
@MainActor
struct LivePlaylistSyncTests {
    struct Fixture {
        let h: Harness
        let manager: TestInputManager
        let source: TestPlaylistSource
        let items: [ItemID]
    }

    private func makeFixture() async throws -> Fixture {
        let manager = TestInputManager()
        let h = Harness(configure: {
            $0.inputs = manager
            $0.simulatesPlayback = false
        })
        await h.app.registerAllInputs()
        let source = try #require(manager.testSource(h.playlist) as? TestPlaylistSource)
        let items = try #require(h.app.playlists.playlist(for: h.playlist)?.items.map(\.id))
        return Fixture(h: h, manager: manager, source: source, items: items)
    }

    /// 1 · El «siguiente» se actualiza cuando la cola de la fuente lo aplica, no antes.
    @Test func snapshotChangesTriggerARefresh() async throws {
        let f = try await makeFixture()
        let (h, source, items) = (f.h, f.source, f.items)
        source.live.withLock {
            $0.state = .playing(index: 0)
            $0.current = items[0]
            $0.upcoming = items[1]
        }
        h.app.playlists.syncLiveStates()
        #expect(h.app.playlists.nextIndex(for: h.playlist) == 1)

        let changed = Box(false)
        withObservationTracking {
            _ = h.app.playlists.nextIndex(for: h.playlist)
        } onChange: { MainActor.assumeIsolated { changed.value = true } }
        h.app.playlists.syncLiveStates() // sin cambios en la fuente
        #expect(!changed.value)
        source.live.withLock { $0.upcoming = items[2] } // la cola aplicó una edición
        h.app.playlists.syncLiveStates()
        #expect(changed.value)
        #expect(h.app.playlists.nextIndex(for: h.playlist) == 2)
    }

    /// 2 · Un refresco anterior a que la cola procese `play` no rebaja la entrada.
    @Test func onlySourceTransitionsChangePlaybackState() async throws {
        let f = try await makeFixture()
        let (h, source, items) = (f.h, f.source, f.items)
        h.app.send(.play(h.playlist))
        h.app.playlists.syncLiveStates() // la fuente aún en reposo
        #expect(h.app.playback[h.playlist]?.state == .playing)
        source.live.withLock {
            $0.state = .playing(index: 0)
            $0.current = items[0]
        }
        h.app.playlists.syncLiveStates()
        #expect(h.app.playback[h.playlist]?.state == .playing)
        source.live.withLock { $0.state = .held(index: 0, cued: 1) }
        h.app.playlists.syncLiveStates()
        #expect(h.app.playback[h.playlist]?.state == .held)
        source.live.withLock { $0.state = .ended }
        h.app.playlists.syncLiveStates()
        #expect(h.app.playback[h.playlist]?.state == .ended)
    }

    /// 5 · `play` que llegó mientras la fuente se preparaba: se reenvía.
    @Test func playIsResentWhenTheSourceStaysIdle() async throws {
        let f = try await makeFixture()
        let (h, source) = (f.h, f.source)
        h.app.send(.play(h.playlist))
        let plays = { source.live.current.calls.filter { $0 == "play" }.count }
        #expect(plays() == 1)
        h.app.playlists.syncLiveStates()
        #expect(plays() == 1, "un refresco de gracia")
        h.app.playlists.syncLiveStates()
        #expect(plays() == 2)
    }

    /// 2 · Transporte reenviado a la fuente, sin secuenciador de la UI.
    @Test func transportGoesToTheSource() async throws {
        let f = try await makeFixture()
        let (h, source, items) = (f.h, f.source, f.items)
        h.app.playlists.next(h.playlist)
        h.app.playlists.previous(h.playlist)
        h.app.playlists.jump(h.playlist, to: items[2])
        h.app.playlists.restartItem(h.playlist)
        #expect(source.live.current.calls == ["next", "previous", "jump", "restart"])
    }

    /// 4 · La duración que informa la playlist es la del item actual de la fuente.
    @Test func playlistDurationKnownGoesToTheCurrentItem() async throws {
        let f = try await makeFixture()
        let (h, source, items) = (f.h, f.source, f.items)
        source.live.withLock { $0.current = items[0] } // a.mp4
        h.app.updatePlaylist(h.playlist) { $0.items[0].inPoint = 2 }
        h.app.handleSourceEvent(.durationKnown(10), from: h.playlist)
        #expect(h.app.mediaDurations["/tmp/a.mp4"] == 12)
        source.live.withLock { $0.current = items[1] } // imagen: sin ruta de medio con duración propia
        h.app.handleSourceEvent(.durationKnown(5), from: h.playlist)
        #expect(h.app.mediaDurations["/tmp/b.png"] == 5)
    }

    /// 3 · Ediciones y encaje en sitio.
    @Test func editsAndFitAreAppliedInPlace() async throws {
        let f = try await makeFixture()
        let (h, manager, source, items) = (f.h, f.manager, f.source, f.items)
        h.app.playlists.setStopAfter(true, item: items[0], in: h.playlist)
        h.app.send(.setFit(h.playlist, .fill))
        #expect(await eventually { source.itemFit == .fill })
        #expect(source.live.current.playlist?.items[0].stopAfter == true)
        #expect(manager.log.current.updates.contains { $0.id == h.playlist && $0.fit == .fill },
                "las ediciones pasan por InputManaging.update")
        #expect(manager.testSource(h.playlist) === source, "la playlist real no se sustituye")
    }
}
