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
        #expect(waitUntil { pool.cachedCount == 1 })
        pool.purge()
        #expect(pool.cachedCount == 0 && pool.cachedBytes == 0)
    }

    @Test func poolIsThreadSafe() async throws {
        let pool = TexturePool(device: GPU.context.device)
        // Ninguna textura puede estar entregada a dos dueños a la vez.
        let inUse = InUseTracker()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    for _ in 0..<50 {
                        guard let texture = pool.dequeue(width: 32, height: 32) else { continue }
                        inUse.checkOut(texture)
                        inUse.checkIn(texture)
                        pool.recycle(texture)
                    }
                }
            }
        }
        #expect(inUse.violations == 0)
        #expect(inUse.checkouts == 400)
        // Como mucho una textura por tarea concurrente; contabilidad de bytes coherente.
        #expect((1...8).contains(pool.cachedCount))
        #expect(inUse.distinct <= 8)
        let bytesPerTexture = try #require(pool.dequeue(width: 32, height: 32)).allocatedSize
        #expect(pool.cachedBytes == pool.cachedCount * bytesPerTexture)
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

    @Test func unpreparedFormatClearsToBlack() throws {
        let renderer = try MonitorRenderer(context: GPU.context)
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 8, height: 8,
                                                            mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .shared
        let target = try #require(GPU.context.device.makeTexture(descriptor: desc))
        let source = GPU.solid(width: 4, height: 4, Pixel(red: 255, green: 0, blue: 0, alpha: 255))
        GPU.run { renderer.encode(source, into: target, border: nil, commandBuffer: $0) }
        #expect(renderer.missingPipelineFrames == 1)
        var bytes = [UInt8](repeating: 9, count: 4)
        target.getBytes(&bytes, bytesPerRow: 8 * 4, from: MTLRegionMake2D(4, 4, 1, 1), mipmapLevel: 0)
        #expect(bytes == [0, 0, 0, 255])

        try renderer.prepare(pixelFormat: .rgba8Unorm)
        GPU.run { renderer.encode(source, into: target, border: nil, commandBuffer: $0) }
        target.getBytes(&bytes, bytesPerRow: 8 * 4, from: MTLRegionMake2D(4, 4, 1, 1), mipmapLevel: 0)
        #expect(bytes == [255, 0, 0, 255])
        #expect(renderer.missingPipelineFrames == 1)
    }

    @Test func noTextureNoBorderIsBlack() throws {
        let renderer = try MonitorRenderer(context: GPU.context)
        let target = GPU.target(width: 32, height: 18)
        GPU.run { renderer.encode(nil, into: target, border: nil, commandBuffer: $0) }
        #expect(compare(target) { _, _ in .black }.maxDeltaE < 1)
    }

    @Test func feedCoalescesRedrawsPerObserver() {
        let feed = MonitorFeed()
        let callsA = Counter()
        let callsB = Counter()
        let tokenA = feed.addObserver { callsA.increment() }
        let tokenB = feed.addObserver { callsB.increment() }
        let texture = GPU.solid(width: 2, height: 2, Pixel(red: 1, green: 2, blue: 3, alpha: 255))
        feed.display(texture)
        feed.display(texture)
        #expect(callsA.value == 1 && callsB.value == 1)
        // Solo A dibuja: solo A vuelve a recibir aviso.
        let lease = feed.acquireForDrawing(tokenA)
        #expect(lease?.texture === texture)
        lease?.release()
        feed.display(nil)
        #expect(callsA.value == 2 && callsB.value == 1)
        #expect(feed.currentTexture == nil)
        feed.acquireForDrawing(tokenB)?.release()
        feed.display(texture)
        #expect(callsB.value == 2)
    }

    @Test func publishedTextureReturnsToPoolOnlyWhenUnused() throws {
        let pool = TexturePool(device: GPU.context.device)
        let feed = MonitorFeed()
        let token = feed.addObserver {}
        let first = try #require(pool.dequeue(width: 16, height: 16))
        let second = try #require(pool.dequeue(width: 16, height: 16))

        feed.display(first, returningTo: pool)
        let drawing = try #require(feed.acquireForDrawing(token))
        #expect(drawing.texture === first)

        // Sustituida pero aún dibujándose: no vuelve al pool.
        feed.display(second, returningTo: pool)
        #expect(pool.cachedCount == 0)

        // El command buffer del monitor termina: ahora sí.
        GPU.run { commandBuffer in
            commandBuffer.makeBlitCommandEncoder()!.endEncoding()
            drawing.release(after: commandBuffer)
        }
        #expect(waitUntil { pool.cachedCount == 1 })
        #expect(pool.dequeue(width: 16, height: 16) === first)

        // Sin dibujos en vuelo, sustituirla la devuelve en el acto.
        feed.display(nil, returningTo: pool)
        #expect(pool.cachedCount == 1)
        #expect(pool.dequeue(width: 16, height: 16) === second)
    }

    @Test func displayingSameTextureTwiceKeepsOneLease() throws {
        let pool = TexturePool(device: GPU.context.device)
        let feed = MonitorFeed()
        let calls = Counter()
        let token = feed.addObserver { calls.increment() }
        let texture = try #require(pool.dequeue(width: 16, height: 16))
        feed.display(texture, returningTo: pool)
        feed.acquireForDrawing(token)?.release()
        feed.display(texture, returningTo: pool)
        // Sigue siendo la actual: no vuelve al pool, pero sí se notifica.
        #expect(pool.cachedCount == 0)
        #expect(calls.value == 2)
        feed.display(nil, returningTo: pool)
        #expect(pool.cachedCount == 1) // una sola entrada en la lista libre
    }

    @Test func eachAcquisitionReleasesOnlyItsOwnReference() throws {
        let pool = TexturePool(device: GPU.context.device)
        let feed = MonitorFeed()
        let tokenA = feed.addObserver {}
        let tokenB = feed.addObserver {}
        let texture = try #require(pool.dequeue(width: 16, height: 16))
        feed.display(texture, returningTo: pool)
        let leaseA = try #require(feed.acquireForDrawing(tokenA))
        let leaseB = try #require(feed.acquireForDrawing(tokenB))
        feed.display(nil, returningTo: pool)
        // A suelta varias veces: no puede soltar la referencia de B.
        leaseA.release()
        leaseA.release()
        leaseA.release()
        #expect(leaseA.isReleased && !leaseB.isReleased)
        #expect(pool.cachedCount == 0)
        leaseB.release()
        #expect(pool.cachedCount == 1)
    }

    @Test func droppedLeaseReleasesItsReference() throws {
        let pool = TexturePool(device: GPU.context.device)
        let feed = MonitorFeed()
        let token = feed.addObserver {}
        feed.display(pool.dequeue(width: 16, height: 16)!, returningTo: pool)
        var lease = feed.acquireForDrawing(token)
        feed.display(nil, returningTo: pool)
        #expect(lease != nil && pool.cachedCount == 0)
        lease = nil // olvidado sin release(): deinit lo suelta
        #expect(pool.cachedCount == 1)
    }

    @Test func displayAndAcquireOnDifferentThreads() {
        let pool = TexturePool(device: GPU.context.device)
        let feed = MonitorFeed()
        let token = feed.addObserver {}
        let produced = InUseTracker()
        let acquired = Counter()
        DispatchQueue.concurrentPerform(iterations: 2) { worker in
            for _ in 0..<300 {
                if worker == 0 {
                    guard let texture = pool.dequeue(width: 8, height: 8) else { continue }
                    produced.checkOut(texture)
                    produced.checkIn(texture)
                    feed.display(texture, returningTo: pool)
                } else if let lease = feed.acquireForDrawing(token) {
                    acquired.increment()
                    _ = lease.texture.width
                    lease.release()
                }
            }
        }
        feed.display(nil, returningTo: pool)
        // Todas las texturas vuelven exactamente una vez (un doble reciclado haría saltar el assert del pool).
        #expect(acquired.value > 0)
        #expect(pool.cachedCount == produced.distinct)
    }

    @Test func textureWithoutPoolIsNotRecycled() throws {
        let pool = TexturePool(device: GPU.context.device)
        let feed = MonitorFeed()
        feed.display(pool.dequeue(width: 8, height: 8)!)
        feed.display(nil)
        #expect(pool.cachedCount == 0)
    }

    @Test func releasingFeedReturnsCurrentTexture() throws {
        let pool = TexturePool(device: GPU.context.device)
        var feed: MonitorFeed? = MonitorFeed()
        feed?.display(pool.dequeue(width: 8, height: 8)!, returningTo: pool)
        feed = nil
        #expect(pool.cachedCount == 1)
    }

    @Test func recreatedObserverSurvivesOldRemoval() {
        // Vista recreada con el mismo feed: la nueva se registra antes de que la vieja se desmonte.
        let feed = MonitorFeed()
        let oldCalls = Counter()
        let newCalls = Counter()
        let old = feed.addObserver { oldCalls.increment() }
        _ = feed.addObserver { newCalls.increment() }
        feed.removeObserver(old)
        feed.removeObserver(old) // idempotente
        #expect(feed.observerCount == 1)
        feed.display(nil)
        #expect(newCalls.value == 1 && oldCalls.value == 0)
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

final class InUseTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Set<ObjectIdentifier>()
    private var seen = Set<ObjectIdentifier>()
    private var violationCount = 0
    private var checkoutCount = 0

    func checkOut(_ texture: MTLTexture) {
        lock.withLock {
            let id = ObjectIdentifier(texture)
            if !current.insert(id).inserted { violationCount += 1 }
            seen.insert(id)
            checkoutCount += 1
        }
    }

    func checkIn(_ texture: MTLTexture) {
        _ = lock.withLock { current.remove(ObjectIdentifier(texture)) }
    }

    var violations: Int { lock.withLock { violationCount } }
    var checkouts: Int { lock.withLock { checkoutCount } }
    var distinct: Int { lock.withLock { seen.count } }
}

#if DEBUG
@Suite("TexturePool debug checks", .enabled(if: hasGPU))
struct TexturePoolDebugTests {
    @Test func doubleRecycleTraps() async {
        await #expect(processExitsWith: .failure) {
            let pool = TexturePool(device: MTLCreateSystemDefaultDevice()!)
            let texture = pool.dequeue(width: 4, height: 4)!
            pool.recycle(texture)
            pool.recycle(texture)
        }
    }
}
#endif
