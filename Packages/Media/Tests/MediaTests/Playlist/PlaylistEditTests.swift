import Core
import CoreMocks
import Foundation
import Testing
@testable import Media

/// Edición en vivo (`update(playlist:)`) y fin en held sin cued (L5).
extension MediaSerialTests {
    @Suite(.serialized, .enabled(if: GPU.available), .timeLimit(.minutes(1)))
    struct PlaylistEditTests {
        typealias Kit = PlaylistTesting

        private func started(_ playlist: Playlist) async throws -> (PlaylistInput, ManualDriver) {
            let input = try PlaylistInput(playlist: playlist, environment: Kit.environment(), drivenByClock: false)
            try await input.prepare()
            var driver = ManualDriver(input)
            await driver.run(1)
            input.play()
            await input.settle()
            return (input, driver)
        }

        @Test func reorderKeepsCurrentItemAndPosition() async throws {
            let items = Kit.colors([Kit.red, Kit.green, Kit.blue], seconds: 2)
            var (input, driver) = try await started(Playlist(items: items))
            await driver.run(60)
            let before = try #require(input.currentTime)
            input.update(playlist: Playlist(items: [items[2], items[0], items[1]]))
            await driver.run(1)
            #expect(input.currentItemID == items[0].id)
            #expect((input.currentTime ?? 0) >= before)
            #expect(input.upcomingItemID == items[1].id)
            #expect(input.stats.switches == 0)
            #expect(Kit.isColor(Kit.pixel(input.texture(for: driver.time)), Kit.red))
            // Sigue al final del rojo con el verde (el siguiente en el orden nuevo).
            var colors: [Int?] = []
            await driver.run(70) { _, texture in
                let px = Kit.pixel(texture)
                colors.append([Kit.red, Kit.green, Kit.blue].firstIndex { Kit.isColor(px, $0) })
            }
            #expect(!colors.contains(nil))
            #expect(colors.last == 1)
            #expect(input.stats.maxLoadedItems <= 2)
        }

        @Test func removingCurrentMovesToSuccessor() async throws {
            let items = Kit.colors([Kit.red, Kit.green, Kit.blue], seconds: 2)
            var (input, driver) = try await started(Playlist(items: items))
            await driver.run(10)
            input.update(playlist: Playlist(items: [items[1], items[2]]))
            await driver.run(5)
            #expect(input.currentItemID == items[1].id)
            #expect(Kit.isColor(Kit.pixel(input.texture(for: driver.time)), Kit.green))
            #expect(input.stats.maxLoadedItems <= 2)
        }

        @Test func editingStillDurationAppliesInPlace() async throws {
            let items = Kit.colors([Kit.red, Kit.green], seconds: 2)
            var (input, driver) = try await started(Playlist(items: items))
            await driver.run(10)
            var edited = items
            edited[0].duration = 0.5
            input.update(playlist: Playlist(items: edited))
            await driver.run(30)
            #expect(input.currentItemID == items[1].id)
            #expect(input.stats.createdItems == 2)
        }

        @Test func heldWithoutCuedEmitsEnded() async throws {
            var items = Kit.colors([Kit.red], seconds: 0.5)
            items[0].stopAfter = true
            let input = try PlaylistInput(playlist: Playlist(items: items), environment: Kit.environment(), drivenByClock: false)
            let events = input.events
            try await input.prepare()
            var driver = ManualDriver(input)
            await driver.run(1)
            input.play()
            await input.settle()
            await driver.run(40)
            #expect(input.sequencerState == .held(index: 0, cued: nil))
            let ended = await firstEvent(events, timeout: 1) { $0 == .ended }
            #expect(ended == .ended)
        }

        /// N1: una edición con un cambio ya programado lo revalida (stopAfter recién activado).
        @Test func editWhileSwitchIsArmedRevalidates() async throws {
            let items = Kit.colors([Kit.red, Kit.green], seconds: 1)
            var (input, driver) = try await started(Playlist(items: items))
            await driver.run(59)
            #expect(input.state.withLock { $0.pending != nil })
            var edited = items
            edited[0].stopAfter = true
            input.update(playlist: Playlist(items: edited))
            var colors: [Int?] = []
            await driver.run(30) { _, texture in
                let px = Kit.pixel(texture)
                colors.append([Kit.red, Kit.green].firstIndex { Kit.isColor(px, $0) })
            }
            #expect(input.sequencerState == .held(index: 0, cued: 1))
            #expect(colors.allSatisfy { $0 == 0 }, "\(colors)")
        }

        /// N3: si la edición deja la playlist terminada, se avisa como al final normal.
        @Test func editThatEndsPlaylistEmitsEnded() async throws {
            let items = Kit.colors([Kit.red, Kit.green], seconds: 2)
            var (input, driver) = try await started(Playlist(items: items))
            let events = input.events
            await driver.run(10)
            // Se elimina el actual y no queda sucesor.
            input.update(playlist: Playlist(items: []))
            await driver.run(5)
            let ended = await firstEvent(events, timeout: 1) { $0 == .ended }
            #expect(ended == .ended)
            #expect(input.playbackState == .ended)
        }

        /// N4: eliminar el actual cuando el precargado es su sucesor reutiliza la ranura.
        @Test func removingCurrentReusesPreloadedSuccessor() async throws {
            let items = Kit.colors([Kit.red, Kit.green, Kit.blue], seconds: 1)
            var (input, driver) = try await started(Playlist(items: items))
            await driver.run(40) // a < 3 s del final: verde precargado
            let preloaded = try #require(input.state.withLock { $0.standby })
            #expect(preloaded.item.id == items[1].id)
            input.update(playlist: Playlist(items: [items[1], items[2]]))
            await driver.run(3)
            #expect(input.currentItemID == items[1].id)
            #expect(input.state.withLock { $0.active?.source } === preloaded.source)
            #expect(Kit.isColor(Kit.pixel(input.texture(for: driver.time)), Kit.green))
        }
    }
}
