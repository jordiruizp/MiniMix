import CoreGraphics
import Metal
import Testing
@testable import TestSupport

@Suite("FrameCode")
struct FrameCodeTests {
    @Test func cellsEncodeValueWithEvenParity() {
        let code = FrameCode(clipID: 3, frameIndex: 30)
        #expect(code.value == 6174)
        #expect(code.cells.count == FrameCode.cellCount)
        #expect(code.cells[0] && !code.cells[1])
        #expect(code.cells.dropFirst(2).filter { $0 }.count % 2 == 0)
    }

    @Test(arguments: [(1920, 1080), (1280, 720), (1080, 1920)])
    func roundTripOnImage(width: Int, height: Int) {
        for value in [0, 1, 2048, 6174, 0x5555, 0xAAAA, FrameCode.maxValue] {
            var image = RGBAImage(width: width, height: height, fill: .init(r: 30, g: 200, b: 90))
            FrameCodeWriter.draw(FrameCode(value: value), clapLit: value.isMultiple(of: 2), into: &image)
            let reading = FrameCodeReader.read(image)
            #expect(reading.code == FrameCode(value: value))
            #expect(reading.clapLit == value.isMultiple(of: 2))
            #expect(!reading.isBlack)
        }
    }

    @Test func layoutMatchesGeneratorGeometry() {
        // Mismas cuentas que Tools/generate-testmedia.sh para 1920×1080 (s = 24).
        let layout = FrameCodeLayout(width: 1920, height: 1080)
        #expect(layout.cellSize == 24)
        #expect(layout.cellRect(0) == CGRect(x: 24, y: 1032, width: 24, height: 24))
        #expect(layout.cellRect(18) == CGRect(x: 456, y: 1032, width: 24, height: 24))
        #expect(layout.clapRect == CGRect(x: 1800, y: 960, width: 96, height: 96))
    }

    @Test func readsInsideLetterboxedContentRect() {
        // Fuente 1080×1920 encajada (fit) en un lienzo 1920×1080: ocupa 607,5×1080 centrada.
        var canvas = RGBAImage(width: 1920, height: 1080)
        let rect = CGRect(x: 656.25, y: 0, width: 607.5, height: 1080)
        canvas.fill(rect, with: .init(r: 120, g: 120, b: 120))
        let layout = FrameCodeLayout(contentRect: rect)
        FrameCodeWriter.draw(FrameCode(clipID: 8, frameIndex: 99), into: &canvas, layout: layout)
        #expect(FrameCodeReader.read(canvas, layout: layout).code == FrameCode(clipID: 8, frameIndex: 99))
    }

    @Test func toleratesCompressionLikeNoise() {
        var image = RGBAImage(width: 1280, height: 720, fill: .init(r: 128, g: 128, b: 128))
        FrameCodeWriter.draw(FrameCode(value: 0x1234), into: &image)
        var rng = SplitMix(seed: 7)
        for i in stride(from: 0, to: image.bytes.count, by: 4) {
            for c in 0..<3 {
                let noisy = Int(image.bytes[i + c]) + Int(rng.next() % 61) - 30
                image.bytes[i + c] = UInt8(clamping: noisy)
            }
        }
        #expect(FrameCodeReader.read(image).code == FrameCode(value: 0x1234))
    }

    @Test func blackAndForeignFramesHaveNoCode() {
        let black = FrameCodeReader.read(RGBAImage(width: 640, height: 360))
        #expect(black.code == nil && black.isBlack)
        let white = FrameCodeReader.read(RGBAImage(width: 640, height: 360, fill: .white))
        #expect(white.code == nil && !white.isBlack)
    }

    @Test func parityErrorIsRejected() {
        var image = RGBAImage(width: 1920, height: 1080, fill: .init(r: 60, g: 60, b: 60))
        let layout = FrameCodeLayout(width: 1920, height: 1080)
        FrameCodeWriter.draw(FrameCode(value: 5), into: &image)
        image.fill(layout.cellRect(10), with: .white) // voltea el bit 8
        #expect(FrameCodeReader.read(image).code == nil)
    }

    @Test func readsBGRAPixelBuffer() throws {
        var image = RGBAImage(width: 1280, height: 720, fill: .init(r: 200, g: 40, b: 40))
        FrameCodeWriter.draw(FrameCode(clipID: 6, frameIndex: 42), clapLit: true, into: &image)
        let buffer = try image.makePixelBuffer()
        let reading = try FrameCodeReader.read(pixelBuffer: buffer)
        #expect(reading.code == FrameCode(clipID: 6, frameIndex: 42))
        #expect(reading.clapLit)
        #expect(try RGBAImage(pixelBuffer: buffer) == image)
    }

    @Test func readsMetalTexture() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        var image = RGBAImage(width: 1920, height: 1080, fill: .init(r: 10, g: 90, b: 200))
        FrameCodeWriter.draw(FrameCode(clipID: 1, frameIndex: 124), into: &image)
        let texture = try image.makeTexture(device: device)
        #expect(try FrameCodeReader.read(texture: texture).code == FrameCode(clipID: 1, frameIndex: 124))

        // Textura privada (como las del compositor): se copia con un blit.
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: 1920, height: 1080, mipmapped: false)
        desc.storageMode = .private
        let privateTexture = try #require(device.makeTexture(descriptor: desc))
        let queue = try #require(device.makeCommandQueue())
        let commands = try #require(queue.makeCommandBuffer())
        let blit = try #require(commands.makeBlitCommandEncoder())
        blit.copy(from: texture, to: privateTexture)
        blit.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        #expect(try RGBAImage(texture: privateTexture) == image)
    }
}

@Suite("FrameSequenceAnalysis")
struct FrameSequenceAnalysisTests {
    private func reading(_ value: Int?) -> FrameCodeReading {
        FrameCodeReading(code: value.map { FrameCode(value: $0) }, clapLit: false, averageLuma: 0.5, contrast: 0.8)
    }

    @Test func cadenceWithRepeatsIsGapless() {
        // 25p sobre 50: cada frame dos veces; luego cambio de clip.
        let values = [2048, 2048, 2049, 2049, 2050, 2050, 4096, 4096, 4097]
        let analysis = FrameSequenceAnalysis(values.map { reading($0) })
        #expect(analysis.isGapless)
        #expect(analysis.repeats == 4)
        #expect(analysis.longestRun == 2)
        #expect(analysis.clipChanges.map(\.index) == [6])
    }

    @Test func detectsSkipsBlacksAndBackwardJumps() {
        var readings = [2048, 2049, 2052, 2051].map { reading($0) }
        readings.append(FrameCodeReading(code: nil, clapLit: false, averageLuma: 0, contrast: 0))
        readings.append(reading(nil))
        let analysis = FrameSequenceAnalysis(readings)
        #expect(!analysis.isGapless)
        #expect(analysis.skippedFrames == 2)
        #expect(analysis.backwardJumps == 1)
        #expect(analysis.black == 1)
        #expect(analysis.unreadable == 1)
    }
}

/// PRNG determinista para tests.
struct SplitMix: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
