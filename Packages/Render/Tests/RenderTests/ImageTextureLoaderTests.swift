import Core
import CoreGraphics
import Foundation
import ImageIO
import Metal
import Testing
import UniformTypeIdentifiers
@testable import Render

@Suite("ImageTextureLoader", .enabled(if: hasGPU))
struct ImageTextureLoaderTests {
    let loader = ImageTextureLoader(context: GPU.context)

    // MARK: Generación de imágenes de prueba (CGContext + ImageIO)

    private static func tempURL(_ ext: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("minimix-render-\(UUID().uuidString).\(ext)")
    }

    /// Imagen RGBA sRGB dibujada con `draw` (coordenadas CG: origen abajo-izquierda).
    private static func makeImage(width: Int, height: Int, draw: (CGContext) -> Void) -> CGImage {
        let cg = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                           space: CGColorSpace(name: CGColorSpace.sRGB)!,
                           bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        draw(cg)
        return cg.makeImage()!
    }

    @discardableResult
    private static func write(_ image: CGImage, type: UTType, properties: [CFString: Any] = [:]) -> URL? {
        let url = tempURL(type.preferredFilenameExtension ?? "img")
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(dest, image, properties as CFDictionary)
        return CGImageDestinationFinalize(dest) ? url : nil
    }

    private static func fill(_ cg: CGContext, _ rgba: [CGFloat], _ rect: CGRect) {
        cg.setFillColor(red: rgba[0], green: rgba[1], blue: rgba[2], alpha: rgba[3])
        cg.fill(rect)
    }

    // MARK: Tests

    @Test func pngAlphaIsPremultipliedAndCoherentWithCompositor() async throws {
        // Mitad izquierda transparente, mitad derecha rojo al 50 %.
        let image = Self.makeImage(width: 64, height: 32) { cg in
            cg.clear(CGRect(x: 0, y: 0, width: 64, height: 32))
            Self.fill(cg, [1, 0, 0, 0.5], CGRect(x: 32, y: 0, width: 32, height: 32))
        }
        let url = try #require(Self.write(image, type: .png))
        defer { try? FileManager.default.removeItem(at: url) }

        let texture = try await loader.loadTexture(from: url, maxSize: .hd1080)
        #expect(texture.width == 64 && texture.height == 32)
        #expect(texture.pixelFormat == .bgra8Unorm)
        #expect(texture.storageMode == .private)
        #expect(texture.usage == .shaderRead)

        let pixels = GPU.read(texture)
        let left = pixels[16 * 64 + 8]
        let right = pixels[16 * 64 + 48]
        #expect(left == Pixel(red: 0, green: 0, blue: 0, alpha: 0))
        #expect(abs(Int(right.red) - 128) <= 1 && right.green == 0 && right.blue == 0, "\(right)")
        #expect(abs(Int(right.alpha) - 128) <= 1, "\(right)")

        // Sobre blanco con el compositor: (255, 127, 127) a la derecha, blanco a la izquierda.
        let compositor = try Compositor(context: GPU.context, statsMode: .disabled)
        compositor.backgroundColor = RGBAColor(red: 1, green: 1, blue: 1)
        let target = GPU.target(width: 64, height: 32)
        GPU.run { compositor.encode(CompositorFrame(a: texture, b: nil, mix: 0, kind: .cut, fitA: .stretch),
                                    into: target, commandBuffer: $0) }
        let k = 255 * (1 - Double(right.alpha) / 255)
        let result = compare(target) { x, _ in
            if (31...32).contains(x) { return nil }
            return x < 32 ? Expected(red: 255, green: 255, blue: 255)
                : Expected(red: Double(right.red) + k, green: k, blue: k)
        }
        #expect(result.maxDeltaE < 1, "\(result)")
    }

    @Test func hugeImageIsReducedToCanvas() async throws {
        // 8000×8000 en gris (64 MB transitorios para generarla); se guarda como JPEG.
        let url: URL = try autoreleasepool {
            let cg = CGContext(data: nil, width: 8000, height: 8000, bitsPerComponent: 8, bytesPerRow: 0,
                               space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
            cg.setFillColor(gray: 0.5, alpha: 1)
            cg.fill(CGRect(x: 0, y: 0, width: 8000, height: 8000))
            return try #require(Self.write(cg.makeImage()!, type: .jpeg))
        }
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(try ImageTextureLoader.targetSize(of: url, maxSize: .hd1080) == PixelSize(width: 1080, height: 1080))
        let texture = try await loader.loadTexture(from: url, maxSize: .hd1080)
        #expect(texture.width == 1080 && texture.height == 1080)
        let canvasBytes = 1920 * 1080 * 4
        print("[T22] 8000×8000 JPEG → \(texture.width)×\(texture.height), allocatedSize = \(texture.allocatedSize) B "
              + "(lienzo 1080p BGRA = \(canvasBytes) B; original a tamaño completo = \(8000 * 8000 * 4) B)")
        #expect(texture.allocatedSize <= canvasBytes)
    }

    @Test func downscalesKeepingAspect() async throws {
        let image = Self.makeImage(width: 400, height: 200) { Self.fill($0, [0, 0, 1, 1], CGRect(x: 0, y: 0, width: 400, height: 200)) }
        let url = try #require(Self.write(image, type: .jpeg))
        defer { try? FileManager.default.removeItem(at: url) }
        let texture = try await loader.loadTexture(from: url, maxSize: PixelSize(width: 100, height: 100))
        #expect(texture.width == 100 && texture.height == 50)
        // Nunca amplía.
        let small = try await loader.loadTexture(from: url, maxSize: .uhd4K)
        #expect(small.width == 400 && small.height == 200)
    }

    @Test func appliesExifOrientation() async throws {
        // Almacenada 40×20: izquierda roja, derecha azul. Orientación 6 = girar 90° horario.
        let image = Self.makeImage(width: 40, height: 20) { cg in
            Self.fill(cg, [1, 0, 0, 1], CGRect(x: 0, y: 0, width: 20, height: 20))
            Self.fill(cg, [0, 0, 1, 1], CGRect(x: 20, y: 0, width: 20, height: 20))
        }
        let url = try #require(Self.write(image, type: .jpeg, properties: [kCGImagePropertyOrientation: 6]))
        defer { try? FileManager.default.removeItem(at: url) }

        let texture = try await loader.loadTexture(from: url, maxSize: .hd1080)
        #expect(texture.width == 20 && texture.height == 40)
        let pixels = GPU.read(texture)
        let top = pixels[5 * 20 + 10]
        let bottom = pixels[35 * 20 + 10]
        #expect(top.red > 200 && top.blue < 60, "arriba \(top)")
        #expect(bottom.blue > 200 && bottom.red < 60, "abajo \(bottom)")
    }

    @Test(arguments: [UTType.tiff, .heic, .jpeg])
    func decodesFormats(type: UTType) async throws {
        let image = Self.makeImage(width: 32, height: 16) { Self.fill($0, [0, 1, 0, 1], CGRect(x: 0, y: 0, width: 32, height: 16)) }
        guard let url = Self.write(image, type: type) else {
            print("[T22] \(type.identifier): codificador no disponible en esta máquina; se omite")
            return
        }
        defer { try? FileManager.default.removeItem(at: url) }
        let texture = try await loader.loadTexture(from: url, maxSize: .hd1080)
        #expect(texture.width == 32 && texture.height == 16)
        let center = GPU.read(texture)[8 * 32 + 16]
        #expect(center.green > 230 && center.red < 30 && center.blue < 30 && center.alpha == 255, "\(type): \(center)")
    }

    #if DEBUG
    @Test func decodesOffTheCooperativePool() async throws {
        let image = Self.makeImage(width: 64, height: 64) { Self.fill($0, [1, 1, 0, 1], CGRect(x: 0, y: 0, width: 64, height: 64)) }
        let url = try #require(Self.write(image, type: .png))
        defer { try? FileManager.default.removeItem(at: url) }
        let before = ImageTextureLoader.dedicatedDecodes.withLock { $0 }
        // Varias cargas concurrentes: se serializan en la cola de decodificación.
        let sizes = try await withThrowingTaskGroup(of: Int.self) { group in
            for _ in 0..<4 {
                group.addTask { try await loader.loadTexture(from: url, maxSize: .hd1080).width }
            }
            return try await group.reduce(into: [Int]()) { $0.append($1) }
        }
        #expect(sizes == [64, 64, 64, 64])
        #expect(ImageTextureLoader.dedicatedDecodes.withLock { $0 } >= before + 4)
    }
    #endif

    @Test func cancelledBeforeStartDoesNotDecode() async throws {
        let image = Self.makeImage(width: 8, height: 8) { Self.fill($0, [1, 0, 0, 1], CGRect(x: 0, y: 0, width: 8, height: 8)) }
        let url = try #require(Self.write(image, type: .png))
        defer { try? FileManager.default.removeItem(at: url) }
        let loader = loader
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await loader.loadTexture(from: url, maxSize: .hd1080).width
        }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }

    @Test func cancelledWhileQueuedDoesNotDecode() async throws {
        let image = Self.makeImage(width: 8, height: 8) { Self.fill($0, [1, 0, 0, 1], CGRect(x: 0, y: 0, width: 8, height: 8)) }
        let url = try #require(Self.write(image, type: .png))
        defer { try? FileManager.default.removeItem(at: url) }
        let queue = ImageTextureLoader.decodeQueue
        queue.isSuspended = true
        let loader = loader
        let task = Task { try await loader.loadTexture(from: url, maxSize: .hd1080).width }
        let queued = waitUntil { queue.operationCount > 0 }
        task.cancel()
        queue.isSuspended = false
        #expect(queued)
        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }

    @Test func missingFileThrows() async {
        let url = Self.tempURL("png")
        await #expect(throws: ImageTextureLoaderError.self) {
            _ = try await loader.loadTexture(from: url, maxSize: .hd1080)
        }
    }
}
