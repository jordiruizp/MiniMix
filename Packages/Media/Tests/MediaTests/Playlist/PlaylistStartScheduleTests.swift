import Core
import CoreMocks
import Foundation
import Testing
@testable import Media

/// Arranque a hora fija del vídeo entrante (`VideoInput.play(atHostTime:)`) frente a ediciones
/// dentro de la ventana de 1 s antes del cambio (revisión M1/M2 del #23): la hora pedida se anula
/// y se vuelve a pedir con la playlist nueva.
extension MediaSerialTests {
    @Suite(.serialized, .enabled(if: GPU.available), .timeLimit(.minutes(1)))
    struct PlaylistStartScheduleTests {
        typealias Kit = PlaylistTesting

        private func video() async throws -> PlaylistItem {
            var spec = TestMediaFactory.VideoSpec()
            spec.width = 320
            spec.height = 180
            spec.fps = 30
            spec.seconds = 2
            let url = try await TestMediaFactory.shared.video(spec)
            return PlaylistItem(source: .video(MediaReference(path: url.path)))
        }

        private func startAt(_ input: PlaylistInput) -> HostTime? { input.state.withLock { $0.standby?.startAt } }

        /// Arranca la playlist y avanza hasta que el entrante tenga hora fija.
        struct Scheduled {
            let input: PlaylistInput
            var driver: ManualDriver
            let at: HostTime
        }

        private func scheduled(_ playlist: Playlist) async throws -> Scheduled {
            let input = try PlaylistInput(playlist: playlist, environment: Kit.environment(), drivenByClock: false)
            try await input.prepare()
            var driver = ManualDriver(input)
            await driver.run(1)
            input.play()
            await input.settle()
            var at: HostTime?
            for _ in 0..<150 where at == nil {
                await driver.run(1)
                at = startAt(input)
            }
            return Scheduled(input: input, driver: driver, at: try #require(at))
        }

        /// Tras la edición: hora anulada y, más tarde, pedida de nuevo.
        private func rescheduled(_ input: PlaylistInput, _ driver: inout ManualDriver) async throws -> HostTime {
            await input.settle()
            #expect(startAt(input) == nil)
            var at: HostTime?
            for _ in 0..<300 where at == nil {
                await driver.run(1)
                at = startAt(input)
            }
            return try #require(at)
        }

        @Test func lengtheningThePlayingStillReschedules() async throws {
            var items = [PlaylistItem(source: .color(Kit.red), duration: 2), try await video()]
            let run = try await scheduled(Playlist(items: items))
            let (input, first) = (run.input, run.at)
            var driver = run.driver
            items[0].duration = 4
            input.update(playlist: Playlist(items: items))
            let second = try await rescheduled(input, &driver)
            #expect(abs((second - first) - 2) < 0.001, "\(second - first)")
            // Y el cambio ocurre en esa hora nueva, no en la anulada.
            await driver.run(Int(((second - driver.time) * 60).rounded()) + 2)
            #expect(input.currentItemID == items[1].id)
        }

        @Test func cutToFadeReschedulesEarlier() async throws {
            let items = [PlaylistItem(source: .color(Kit.red), duration: 3), try await video()]
            let run = try await scheduled(Playlist(items: items))
            let (input, first) = (run.input, run.at)
            var driver = run.driver
            input.update(playlist: Playlist(items: items, itemTransition: .fade(seconds: 0.5)))
            let second = try await rescheduled(input, &driver)
            #expect(abs((first - second) - 0.5) < 0.001, "\(first - second)")
        }

        @Test func fadeToCutReschedulesLater() async throws {
            let items = [PlaylistItem(source: .color(Kit.red), duration: 3), try await video()]
            let run = try await scheduled(Playlist(items: items, itemTransition: .fade(seconds: 0.5)))
            let (input, first) = (run.input, run.at)
            var driver = run.driver
            input.update(playlist: Playlist(items: items))
            let second = try await rescheduled(input, &driver)
            #expect(abs((second - first) - 0.5) < 0.001, "\(second - first)")
        }

        /// M3: sin margen para el preroll (precarga tardía) no se pide hora fija.
        @Test func lateStandbyDoesNotRequestAFixedStart() async throws {
            let items = [PlaylistItem(source: .color(Kit.red), duration: 0.2), try await video()]
            let input = try PlaylistInput(playlist: Playlist(items: items), environment: Kit.environment(),
                                          drivenByClock: false)
            try await input.prepare()
            var driver = ManualDriver(input)
            await driver.run(1)
            input.play()
            await input.settle()
            var requested = false
            await driver.run(30) { _, _ in if startAt(input) != nil { requested = true } }
            #expect(!requested)
            #expect(input.currentItemID == items[1].id)
        }
    }
}
