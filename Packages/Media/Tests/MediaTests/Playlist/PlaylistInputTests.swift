import Core
import CoreMocks
import Foundation
import Metal
import Testing
@testable import Media

/// T70/T71 con items de color y ticks manuales (deterministas, sin decodificadores).
extension MediaSerialTests {
    @Suite(.serialized, .enabled(if: GPU.available), .timeLimit(.minutes(2)))
    struct PlaylistInputTests {
        typealias Kit = PlaylistTesting

        private func make(_ playlist: Playlist, preloadLead: Double = 3) async throws -> (PlaylistInput, ManualDriver) {
            let input = try PlaylistInput(playlist: playlist, environment: Kit.environment(preloadLead: preloadLead),
                                          drivenByClock: false)
            try await input.prepare()
            var driver = ManualDriver(input)
            await driver.run(1)
            return (input, driver)
        }

        /// Colores vistos por tick, agrupados en rachas.
        private func runs(_ driver: inout ManualDriver, ticks: Int, palette: [RGBAColor]) async -> [(Int?, Int)] {
            var result: [(Int?, Int)] = []
            await driver.run(ticks) { _, texture in
                let px = Kit.pixel(texture)
                let index = palette.firstIndex { Kit.isColor(px, $0) }
                if let last = result.last, last.0 == index {
                    result[result.count - 1].1 += 1
                } else {
                    result.append((index, 1))
                }
            }
            return result
        }

        /// Eventos hasta `last` (incluido) o hasta 5 s, sin esperas sin límite.
        private func collectEvents(_ events: AsyncStream<SourceEvent>, until last: SourceEvent) async -> [SourceEvent] {
            let list = Locked([SourceEvent]())
            _ = await firstEvent(events, timeout: 5) { event in
                list.withLock { $0.append(event) }
                return event == last
            }
            return list.current
        }

        @Test func continuousCutsAtFrameBoundariesWithoutBlack() async throws {
            let palette = [Kit.red, Kit.green, Kit.blue]
            let (input, initial) = try await make(Playlist(items: Kit.colors(palette)))
            var driver = initial
            #expect(input.playbackState == .paused)
            input.play()
            await input.settle()
            let seen = await runs(&driver, ticks: 200, palette: palette)
            // Rojo ya se veía en el tick de play; verde y azul, exactamente 60 ticks (1 s a 60 Hz).
            #expect(seen.map(\.0) == [0, 1, 2])
            #expect(seen.count == 3 && seen[0].1 == 59 && seen[1].1 == 60)
            #expect(input.sequencerState == .ended)
            #expect(input.playbackState == .ended)
            #expect(input.stats.maxLoadedItems <= 2)
            #expect(input.stats.switches == 2)
            #expect(input.stats.lateSwitches == 0)
        }

        @Test func stopAfterEachHoldsWithNextCued() async throws {
            let palette = [Kit.red, Kit.green, Kit.blue]
            let items = Kit.colors(palette)
            let (input, initial) = try await make(Playlist(items: items, mode: .stopAfterEach))
            var driver = initial
            input.play()
            await input.settle()
            var seen = await runs(&driver, ticks: 90, palette: palette)
            #expect(input.sequencerState == .held(index: 0, cued: 1))
            #expect(input.playbackState == .held)
            #expect(input.upcomingItemID == items[1].id)
            #expect(input.currentItemID == items[0].id)
            // holdBehavior por defecto: último fotograma.
            #expect(seen.map(\.0) == [0])
            #expect(input.stats.loadedItems == 2)
            input.play()
            await input.settle()
            seen = await runs(&driver, ticks: 30, palette: palette)
            #expect(seen.first?.0 == 1)
            #expect(input.sequencerState == .playing(index: 1))
        }

        @Test(arguments: HoldBehavior.allCases)
        func holdBehaviorDecidesWhatHeldShows(_ hold: HoldBehavior) async throws {
            let palette = [Kit.red, Kit.green, .black]
            var items = Kit.colors([Kit.red, Kit.green])
            items[0].stopAfter = true
            let (input, initial) = try await make(Playlist(items: items, holdBehavior: hold))
            var driver = initial
            input.play()
            await input.settle()
            let seen = await runs(&driver, ticks: 90, palette: palette)
            #expect(input.playbackState == .held)
            let expected: Int = switch hold {
            case .lastFrame: 0
            case .black: 2
            case .nextFirstFrame: 1
            }
            #expect(seen.last?.0 == expected, "\(hold): \(seen)")
            #expect(seen.first?.0 == 0)
        }

        @Test func neverMoreThanTwoItemsLoaded() async throws {
            let palette = [Kit.red, Kit.green, Kit.blue, Kit.red, Kit.green, Kit.blue]
            let (input, initial) = try await make(Playlist(items: Kit.colors(palette, seconds: 0.5), loop: true))
            var driver = initial
            input.play()
            await input.settle()
            var maxSeen = 0
            await driver.run(60 * 8) { _, _ in maxSeen = max(maxSeen, input.stats.loadedItems) }
            #expect(maxSeen <= 2)
            #expect(input.stats.maxLoadedItems <= 2)
            #expect(input.stats.createdItems >= 15)
            #expect(input.stats.lateSwitches == 0)
            #expect(input.playbackState == .playing)
        }

        @Test func navigationNextPreviousJumpRestart() async throws {
            let palette = [Kit.red, Kit.green, Kit.blue]
            let items = Kit.colors(palette, seconds: 5)
            let (input, initial) = try await make(Playlist(items: items))
            var driver = initial
            input.play()
            await input.settle()
            input.next()
            var seen = await runs(&driver, ticks: 10, palette: palette)
            #expect(seen.last?.0 == 1)
            #expect(input.currentItemID == items[1].id)
            input.jump(to: items[2].id)
            seen = await runs(&driver, ticks: 10, palette: palette)
            #expect(seen.last?.0 == 2)
            input.previous()
            seen = await runs(&driver, ticks: 30, palette: palette)
            #expect(seen.last?.0 == 1)
            let before = try #require(input.currentTime)
            #expect(before > 0.4)
            input.restartItem()
            await driver.run(1)
            #expect((input.currentTime ?? 1) < 0.1)
            #expect(input.stats.maxLoadedItems <= 2)
            #expect(abs((input.itemRemainingTime ?? 0) - (5 - (input.currentTime ?? 0))) < 0.05)
        }

        @Test func pauseFreezesStillTimer() async throws {
            let palette = [Kit.red, Kit.green]
            let (input, initial) = try await make(Playlist(items: Kit.colors(palette)))
            var driver = initial
            input.play()
            await input.settle()
            await driver.run(30)
            input.pause()
            await input.settle()
            #expect(input.playbackState == .paused)
            let seen = await runs(&driver, ticks: 120, palette: palette)
            #expect(seen.map(\.0) == [0])
            input.play()
            await input.settle()
            let resumed = await runs(&driver, ticks: 40, palette: palette)
            #expect(resumed.map(\.0) == [0, 1])
        }

        @Test func hiddenPlaylistFreezesTimeline() async throws {
            let palette = [Kit.red, Kit.green]
            let (input, initial) = try await make(Playlist(items: Kit.colors(palette)))
            var driver = initial
            input.play()
            await input.settle()
            input.setDecodingEnabled(false)
            let seen = await runs(&driver, ticks: 120, palette: palette)
            #expect(seen.map(\.0) == [0])
            #expect(input.playbackState == .playing)
            input.setDecodingEnabled(true)
            let resumed = await runs(&driver, ticks: 70, palette: palette)
            #expect(resumed.map(\.0) == [0, 1])
        }

        @Test func remainingTimesAndEvents() async throws {
            let items = Kit.colors([Kit.red, Kit.green, Kit.blue], seconds: 2)
            let input = try PlaylistInput(playlist: Playlist(items: items), environment: Kit.environment(), drivenByClock: false)
            let events = input.events
            try await input.prepare()
            var driver = ManualDriver(input)
            await driver.run(1)
            input.play()
            await driver.run(30)
            let remaining = try #require(input.playlistRemainingTime)
            #expect(abs(remaining - 5.5) < 0.05)
            await driver.run(60 * 6)
            let collected = await collectEvents(events, until: .ended)
            let changes = collected.compactMap { if case .itemChanged(let id) = $0 { id } else { nil } }
            #expect(changes == items.map(\.id))
            #expect(collected.contains(.durationKnown(2)))
            #expect(collected.last == .ended)
        }

        @Test func singleItemLoopRepeatsWithTwoInstances() async throws {
            let (input, initial) = try await make(Playlist(items: Kit.colors([Kit.red], seconds: 0.5), loop: true))
            var driver = initial
            input.play()
            await input.settle()
            var black = 0
            await driver.run(150) { _, texture in if !Kit.isColor(Kit.pixel(texture), Kit.red) { black += 1 } }
            #expect(black == 0)
            #expect(input.stats.switches >= 2)
            #expect(input.stats.maxLoadedItems <= 2)
        }

        @Test func factoryBuildsPlaylistForInputManager() async throws {
            let environment = Kit.environment()
            let manager = InputManager(context: GPU.context!, canvasSize: environment.canvasSize,
                                       playlistFactory: PlaylistInput.factory(environment: environment))
            let descriptor = InputDescriptor(name: "PL", content: .playlist(Playlist(items: Kit.colors([Kit.red]))))
            try await manager.add(descriptor)
            let source = try #require(manager.frameSource(for: descriptor.id) as? PlaylistInput)
            #expect(source.id == descriptor.id)
            #expect(manager.audioSource(for: descriptor.id) != nil)
            #expect(Kit.isColor(Kit.pixel(source.texture(for: HostTime(seconds: 1))), Kit.red))
            await manager.remove(descriptor.id)
        }
    }
}
