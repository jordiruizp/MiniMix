import CoreGraphics
import CoreVideo
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
        #expect(code.cells[2..<19].filter { $0 }.count % 2 == 0)
        // CRC-4 de referencia (mismo algoritmo que Tools/generate-testmedia.sh).
        let crcs = [1, 2048, 6174, 43690, 65535].map(FrameCode.crc4)
        #expect(crcs == [3, 1, 7, 2, 3])
        #expect(code.cells[19..<23] == [true, true, true, false][...])
    }

    @Test func halfBlendOfTwoCodesIsUnreadable() {
        // Fundido al 50 % entre dos fotogramas (o dos clips): nunca debe inventar un código.
        let pairs = [(6174, 6175), (2048, 4096), (0x5555, 0xAAAA), (100, 101)]
        for (first, second) in pairs {
            var a = RGBAImage(width: 1280, height: 720, fill: .init(r: 90, g: 90, b: 90))
            var b = a
            FrameCodeWriter.draw(FrameCode(value: first), into: &a)
            FrameCodeWriter.draw(FrameCode(value: second), into: &b)
            for mix in [0.4, 0.5, 0.6] {
                let blended = RGBAImage(width: a.width, height: a.height, bytes: zip(a.bytes, b.bytes).map {
                    UInt8((Double($0) * (1 - mix) + Double($1) * mix).rounded())
                })
                #expect(FrameCodeReader.read(blended).code == nil, "\(first)/\(second) al \(mix)")
            }
        }
    }

    @Test func crcRejectsErrorsThatParityMisses() {
        var image = RGBAImage(width: 1920, height: 1080, fill: .init(r: 60, g: 60, b: 60))
        let layout = FrameCodeLayout(width: 1920, height: 1080)
        FrameCodeWriter.draw(FrameCode(value: 5), into: &image)
        // Dos bits volteados: la paridad sigue siendo correcta, el CRC no.
        image.fill(layout.cellRect(10), with: .white)
        image.fill(layout.cellRect(11), with: .white)
        #expect(FrameCodeReader.read(image).code == nil)
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
        #expect(layout.cellRect(22) == CGRect(x: 552, y: 1032, width: 24, height: 24))
        #expect(layout.stripBackground == CGRect(x: 12, y: 1020, width: 576, height: 48))
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

    @Test func unsupportedFormatsThrow() throws {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, nil, &buffer)
        let tenBit = try #require(buffer)
        #expect(throws: RGBAImageError.self) { try FrameCodeReader.read(pixelBuffer: tenBit) }
        #expect(throws: RGBAImageError.self) { try RGBAImage(pixelBuffer: tenBit) }
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: 8, height: 8, mipmapped: false)
        let half = try #require(device.makeTexture(descriptor: desc))
        #expect(throws: RGBAImageError.self) { try FrameCodeReader.read(texture: half) }
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

    @Test func boundarySkipsAndColorFiller() {
        // Clip 1 → item de color (sin código, luma 0,3) → clip 2 empezando en su frame 3.
        var readings = [2048, 2049].map { reading($0) }
        readings += Array(repeating: FrameCodeReading(code: nil, clapLit: false, averageLuma: 0.3, contrast: 0), count: 3)
        readings += [4099, 4100].map { reading($0) }
        let strict = FrameSequenceAnalysis(readings)
        #expect(strict.unreadable == 3 && !strict.isGapless)
        let analysis = FrameSequenceAnalysis(readings, isFiller: FrameSequenceAnalysis.filler(averageLuma: 0.3))
        #expect(analysis.filler == 3 && analysis.unreadable == 0)
        #expect(analysis.boundarySkips == 3)
        #expect(!analysis.isGapless)
        var clean = readings
        clean[5] = reading(4096)
        clean[6] = reading(4097)
        #expect(FrameSequenceAnalysis(clean, isFiller: FrameSequenceAnalysis.filler(averageLuma: 0.3)).isGapless)
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
