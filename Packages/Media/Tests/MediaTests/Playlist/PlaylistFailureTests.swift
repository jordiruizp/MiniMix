import Core
import CoreMocks
import Foundation
import Testing
@testable import Media

/// Items que no cargan: se saltan sin reintentos (revisión B1).
extension MediaSerialTests {
    @Suite(.serialized, .enabled(if: GPU.available), .timeLimit(.minutes(1)))
    struct PlaylistFailureTests {
        typealias Kit = PlaylistTesting

        private static let bad = PlaylistItem(source: .video(MediaReference(path: "/nonexistent/clip.mp4")))

        @Test func failingLastItemReturnsToActiveWithoutRetrying() async throws {
            let items = Kit.colors([Kit.red], seconds: 5) + [Self.bad]
            let input = try PlaylistInput(playlist: Playlist(items: items), environment: Kit.environment(),
                                          drivenByClock: false)
            let events = input.events
            try await input.prepare()
            var driver = ManualDriver(input)
            await driver.run(1)
            input.play()
            await input.settle()
            input.jump(to: Self.bad.id)
            var red = 0
            await driver.run(60) { _, texture in if Kit.isColor(Kit.pixel(texture), Kit.red) { red += 1 } }
            #expect(red == 60)
            #expect(input.sequencerState == .playing(index: 0))
            #expect(input.playlist.items[1].enabled == false)
            #expect(input.stats.createdItems == 2)
            input.next()
            await driver.run(10)
            #expect(input.stats.createdItems == 2)
            let errors = Locked(0)
            _ = await firstEvent(events, timeout: 0.5) { event in
                if case .error = event { errors.withLock { $0 += 1 } }
                return false
            }
            #expect(errors.current == 1)
        }

        @Test func failingTargetWithoutFallbackStops() async throws {
            let items = [Self.bad] + Kit.colors([Kit.red], seconds: 0.5)
            let input = try PlaylistInput(playlist: Playlist(items: items), environment: Kit.environment(),
                                          drivenByClock: false)
            try await input.prepare()
            // El primero falla en prepare y se salta: queda el rojo.
            #expect(input.playlist.items[0].enabled == false)
            var driver = ManualDriver(input)
            await driver.run(1)
            // El rojo deja de estar disponible y se pide el item que falló: no hay a dónde ir.
            input.state.withLock { $0.sequencer.playlist.items[1].enabled = false }
            input.play()
            await driver.run(30)
            #expect(input.playbackState != .playing)
            let created = input.stats.createdItems
            await driver.run(60)
            #expect(input.stats.createdItems == created)
        }
    }
}
