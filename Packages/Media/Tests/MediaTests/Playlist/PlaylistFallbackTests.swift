import Core
import CoreMocks
import Foundation
import Metal
import Testing
@testable import Media

/// Revisión M3 y M5: lo que se ve cuando el entrante aún no tiene textura, y al navegar en held.
extension MediaSerialTests {
    @Suite(.serialized, .enabled(if: GPU.available), .timeLimit(.minutes(1)))
    struct PlaylistFallbackTests {
        typealias Kit = PlaylistTesting

        /// Fuente que no entrega textura hasta que se le permite (decodificador lento).
        final class LateSource: FrameSource, @unchecked Sendable {
            let id = InputID()
            let inner: MockFrameSource
            let available = Locked(false)
            init(color: RGBAColor) { inner = MockFrameSource(color: color) }
            var nativeSize: PixelSize { inner.nativeSize }
            var playbackState: PlaybackState { inner.playbackState }
            var events: AsyncStream<SourceEvent> { inner.events }
            func prepare() async throws { try await inner.prepare() }
            func texture(for time: HostTime) -> MTLTexture? { available.current ? inner.texture(for: time) : nil }
            func play() { inner.play() }
            func pause() { inner.pause() }
            func seek(to seconds: Double) async {}
        }

        @Test func incomingWithoutTextureKeepsOutgoingVisible() async throws {
            let late = LateSource(color: Kit.green)
            let items = Kit.colors([Kit.red], seconds: 0.5) + Kit.colors([Kit.green], seconds: 2)
            let base = Kit.environment()
            let environment = base.with(itemFactory: { item, playlist in
                if item.id == items[1].id { return late }
                return try base.makeItemSource(item, in: playlist)
            })
            let input = try PlaylistInput(playlist: Playlist(items: items), environment: environment, drivenByClock: false)
            try await input.prepare()
            var driver = ManualDriver(input)
            await driver.run(1)
            input.play()
            await input.settle()
            var colors: [String] = []
            await driver.run(60) { index, texture in
                if index == 45 { late.available.withLock { $0 = true } }
                let px = Kit.pixel(texture)
                colors.append(Kit.isColor(px, Kit.red) ? "r" : Kit.isColor(px, Kit.green) ? "g" : "x")
            }
            #expect(input.currentItemID == items[1].id)
            #expect(!colors.contains("x"), "\(colors.joined())")
            #expect(colors.last == "g")
        }

        @Test func previousWhileHeldOnNextFirstFrameKeepsAVisual() async throws {
            var items = Kit.colors([Kit.red, Kit.green, Kit.blue], seconds: 0.5)
            items[1].stopAfter = true
            let playlist = Playlist(items: items, holdBehavior: .nextFirstFrame)
            let input = try PlaylistInput(playlist: playlist, environment: Kit.environment(), drivenByClock: false)
            try await input.prepare()
            var driver = ManualDriver(input)
            await driver.run(1)
            input.play()
            await input.settle()
            await driver.run(80)
            #expect(input.playbackState == .held)
            // held en verde con el azul cued y mostrado (nextFirstFrame).
            #expect(Kit.isColor(Kit.pixel(input.texture(for: driver.time)), Kit.blue))
            input.previous()
            var unknown = 0
            await driver.run(20) { _, texture in
                let px = Kit.pixel(texture)
                if !(Kit.isColor(px, Kit.red) || Kit.isColor(px, Kit.green) || Kit.isColor(px, Kit.blue)) { unknown += 1 }
            }
            #expect(unknown == 0)
            #expect(input.currentItemID == items[0].id)
            #expect(Kit.isColor(Kit.pixel(input.texture(for: driver.time)), Kit.red))
            await driver.run(5)
            #expect(input.stats.loadedItems <= 2)
            #expect(input.stats.maxLoadedItems <= 2)
        }
    }
}
