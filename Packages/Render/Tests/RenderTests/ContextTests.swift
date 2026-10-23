import Core
import CoreVideo
import Foundation
import IOSurface
import Metal
import Testing
@testable import Render

@Suite("MetalContext y TexturePool", .enabled(if: hasGPU))
struct ContextTests {
    @Test func sharedContextAndLibrary() throws {
        let context = try #require(MetalContext.shared)
        let library = try context.shaderLibrary()
        #expect(library.functionNames.contains("minimix_compositor_fragment"))
        #expect(library.functionNames.contains("minimix_monitor_fragment"))
        #expect(try context.shaderLibrary() === library)
        #expect(MetalContext(device: nil) == nil)
    }

    @Test func flushTextureCacheReleasesUnusedTextures() throws {
        let context = GPU.context
        var pixelBuffer: CVPixelBuffer?
        let attrs = [kCVPixelBufferMetalCompatibilityKey: true, kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        #expect(CVPixelBufferCreate(nil, 32, 18, kCVPixelFormatType_32BGRA, attrs, &pixelBuffer) == kCVReturnSuccess)
        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            nil, context.textureCache, try #require(pixelBuffer), nil, .bgra8Unorm, 32, 18, 0, &cvTexture)
        #expect(status == kCVReturnSuccess)
        let texture = try #require(cvTexture.flatMap { CVMetalTextureGetTexture($0) })
        #expect(texture.iosurface != nil)
        cvTexture = nil
        context.flushTextureCache() // no debe fallar ni invalidar texturas aún retenidas
        #expect(texture.width == 32)
    }

    @Test func poolReusesByKey() throws {
        let pool = TexturePool(device: GPU.context.device)
        let first = try #require(pool.dequeue(width: 64, height: 32))
        pool.recycle(first)
        #expect(pool.cachedCount == 1)
        #expect(pool.cachedBytes == first.allocatedSize)
        let again = try #require(pool.dequeue(width: 64, height: 32))
        #expect(again === first)
        #expect(pool.cachedCount == 0)

        pool.recycle(again)
        let otherFormat = try #require(pool.dequeue(width: 64, height: 32, pixelFormat: .rgba16Float))
        let otherUsage = try #require(pool.dequeue(width: 64, height: 32, usage: .shaderRead))
        #expect(otherFormat !== first && otherUsage !== first)
        #expect(pool.cachedCount == 1)
    }

    @Test func poolRespectsMemoryLimit() throws {
        let pool = TexturePool(device: GPU.context.device)
        let a = try #require(pool.dequeue(width: 128, height: 128))
        let b = try #require(pool.dequeue(width: 128, height: 128))
        pool.memoryLimit = a.allocatedSize
        pool.recycle(a)
        pool.recycle(b)
        #expect(pool.cachedCount == 1)
        #expect(pool.cachedBytes <= pool.memoryLimit)
        // Se conserva la más reciente.
        #expect(pool.dequeue(width: 128, height: 128) === b)
        pool.recycle(a)
        pool.memoryLimit = 0
        #expect(pool.cachedCount == 0)
        pool.recycle(b)
        #expect(pool.cachedCount == 0)
    }

    @Test func poolRejectsForeignTextures() throws {
        let device = GPU.context.device
        let pool = TexturePool(device: device)

        // IOSurface (como las de CVMetalTextureCache): pertenecen a su CVPixelBuffer.
        let surface = try #require(IOSurfaceCreate([
            kIOSurfaceWidth: 16, kIOSurfaceHeight: 16, kIOSurfaceBytesPerElement: 4,
            kIOSurfacePixelFormat: 0x4247_5241 // 'BGRA'
        ] as CFDictionary))
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 16, height: 16,
                                                            mipmapped: false)
        desc.usage = [.shaderRead, .renderTarget]
        desc.storageMode = .shared
        let ioTexture = try #require(device.makeTexture(descriptor: desc, iosurface: surface, plane: 0))
        #expect(!pool.recycle(ioTexture))

        // No 2D.
        let arrayDesc = MTLTextureDescriptor()
        arrayDesc.textureType = .type2DArray
        arrayDesc.width = 16
        arrayDesc.height = 16
        arrayDesc.arrayLength = 2
        #expect(!pool.recycle(try #require(device.makeTexture(descriptor: arrayDesc))))

        // Con mipmaps (la clave no los distingue).
        let mipDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 16, height: 16,
                                                               mipmapped: true)
        #expect(!pool.recycle(try #require(device.makeTexture(descriptor: mipDesc))))

        // Vista de otra textura.
        let base = try #require(pool.dequeue(width: 16, height: 16))
        #expect(!pool.recycle(try #require(base.makeTextureView(pixelFormat: .bgra8Unorm))))

        #expect(pool.cachedCount == 0)
        #expect(pool.recycle(base))
        #expect(pool.cachedCount == 1)
    }

    @Test func poolRecyclesAfterCommandBuffer() throws {
        let pool = TexturePool(device: GPU.context.device)
        let texture = try #require(pool.dequeue(width: 16, height: 16))
        GPU.run { commandBuffer in
            commandBuffer.makeBlitCommandEncoder()!.endEncoding()
            pool.recycle(texture, after: commandBuffer)
        }
        for _ in 0..<100 where pool.cachedCount == 0 { usleep(1_000) }
        #expect(pool.cachedCount == 1)
        pool.purge()
        #expect(pool.cachedCount == 0 && pool.cachedBytes == 0)
    }

    @Test func poolIsThreadSafe() async throws {
        let pool = TexturePool(device: GPU.context.device)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    for _ in 0..<50 {
                        if let texture = pool.dequeue(width: 32, height: 32) { pool.recycle(texture) }
                    }
                }
            }
        }
        #expect(pool.cachedCount <= 8)
    }
}

@Suite("MonitorRenderer", .enabled(if: hasGPU))
struct MonitorRendererTests {
    @Test func letterboxAndBorder() throws {
        let renderer = try MonitorRenderer(context: GPU.context)
        let source = GPU.solid(width: 40, height: 30, Pixel(red: 255, green: 0, blue: 0, alpha: 255))
        let target = GPU.target(width: 200, height: 100)
        let border = MonitorBorder(color: RGBAColor(red: 0, green: 1, blue: 0), width: 4)
        GPU.run { renderer.encode(source, into: target, border: border, commandBuffer: $0) }

        // Interior 192×92; 4:3 → 122,67 px de ancho centrado: x ∈ [38,67; 161,33].
        let rect = MonitorRenderer.contentRect(source: PixelSize(width: 40, height: 30),
                                               destination: PixelSize(width: 200, height: 100), borderWidth: 4)
        #expect(abs(rect.x - 38.667) < 0.01 && rect.y == 4 && abs(rect.z - 122.667) < 0.01 && rect.w == 92)
        let result = compare(target) { x, y in
            if x < 4 || y < 4 || x >= 196 || y >= 96 { return .green }
            if (37...39).contains(x) || (160...162).contains(x) { return nil }
            return x < 38 || x > 161 ? .black : .red
        }
        #expect(result.maxDeltaE < 1, "\(result)")
    }

    @Test func noTextureNoBorderIsBlack() throws {
        let renderer = try MonitorRenderer(context: GPU.context)
        let target = GPU.target(width: 32, height: 18)
        GPU.run { renderer.encode(nil, into: target, border: nil, commandBuffer: $0) }
        #expect(compare(target) { _, _ in .black }.maxDeltaE < 1)
    }

    @Test func feedCoalescesRedraws() {
        let feed = MonitorFeed()
        let calls = Counter()
        feed.setInvalidationHandler { calls.increment() }
        let texture = GPU.solid(width: 2, height: 2, Pixel(red: 1, green: 2, blue: 3, alpha: 255))
        feed.display(texture)
        feed.display(texture)
        #expect(calls.value == 1)
        #expect(feed.takeForDrawing() === texture)
        feed.display(nil)
        #expect(calls.value == 2)
        #expect(feed.currentTexture == nil)
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}
