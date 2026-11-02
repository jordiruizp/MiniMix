import Core
import Foundation
import Media
import Metal
@testable import MiniMixUI
import Testing

/// Playlist real (PlaylistInput) en modo live con items de color (sin archivos): manda su
/// secuenciador; la UI reenvía el transporte y refleja su estado.
@MainActor
@Suite(.serialized, .enabled(if: MTLCreateSystemDefaultDevice() != nil))
struct LivePlaylistTests {
    struct Session {
        let app: AppViewModel
        let playlistID: InputID
        let items: [ItemID]
        let source: PlaylistInput
        let suite: DefaultsSuite
    }

    private func makeSession(itemDuration: Double) async throws -> Session {
        let colors = [RGBAColor(red: 1, green: 0, blue: 0), RGBAColor(red: 0, green: 1, blue: 0),
                      RGBAColor(red: 0, green: 0, blue: 1)]
        let items = colors.map { PlaylistItem(source: .color($0), duration: itemDuration) }
        let playlist = InputDescriptor(name: "PL", content: .playlist(Playlist(items: items)))
        let black = InputDescriptor(name: "Negro", content: .color(.black))
        let project = Project(canvas: CanvasFormat(size: PixelSize(width: 64, height: 36), frameRate: .fps60),
                              inputs: [playlist, black], preview: playlist.id, program: black.id)
        let (live, _) = try AppServices.live(project: project)
        var services = live
        let suite = DefaultsSuite()
        services.defaults = suite.defaults
        let app = AppViewModel(services: services)
        app.start()
        #expect(await eventually { services.inputs.frameSource(for: playlist.id) is PlaylistInput })
        let source = try #require(services.inputs.frameSource(for: playlist.id) as? PlaylistInput)
        return Session(app: app, playlistID: playlist.id, items: items.map(\.id), source: source, suite: suite)
    }

    @Test func transportIsForwardedToTheSourceAndReflected() async throws {
        let session = try await makeSession(itemDuration: 30)
        let (app, id, items, source) = (session.app, session.playlistID, session.items, session.source)
        defer { app.stop() }

        app.send(.play(id))
        #expect(await eventually { source.currentItemID == items[0] })
        #expect(app.playlists.currentIndex(for: id) == 0)
        #expect(app.playlists.nextIndex(for: id) == 1)

        app.playlists.next(id)
        #expect(await eventually { source.currentItemID == items[1] })
        #expect(app.playlists.currentIndex(for: id) == 1)

        app.playlists.previous(id)
        #expect(await eventually { source.currentItemID == items[0] })

        app.playlists.jump(id, to: items[2])
        #expect(await eventually { source.currentItemID == items[2] })
        #expect(app.playlists.currentIndex(for: id) == 2)
        #expect(app.playlists.state(for: id) == source.sequencerState, "un solo secuenciador: el de la fuente")
        #expect((app.playlists.itemRemaining(for: id) ?? 0) > 20)

        app.send(.pause(id))
        #expect(await eventually { source.playbackState == .paused })
    }

    @Test func itemChangedFromTheSourceIsReflectedInTheUI() async throws {
        let session = try await makeSession(itemDuration: 0.3)
        let (app, id, items, source) = (session.app, session.playlistID, session.items, session.source)
        defer { app.stop() }
        app.send(.play(id))
        #expect(await eventually { source.currentItemID == items[0] })
        let revision = app.playlists.liveRevision
        // Sin comandos de la UI: la fuente pasa sola al siguiente item y lo notifica.
        #expect(await eventually { source.currentItemID == items[1] })
        #expect(await eventually { app.playlists.liveRevision > revision })
        #expect(app.playlists.currentIndex(for: id) == 1)
        // Al terminar, la entrada queda terminada en la UI.
        #expect(await eventually(timeout: 3) { app.playback[id]?.state == .ended })
        #expect(app.playlists.playlistRemaining(for: id) == 0)
    }
}
