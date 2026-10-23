import Core
import CoreGraphics
import Metal
import Testing
@testable import Render

/// Snapshots del compositor (T21) contra valores de píxel calculados, tolerancia ΔE < 1.
@Suite("Compositor", .enabled(if: hasGPU))
struct CompositorTests {
    static let canvasWidth = 160
    static let canvasHeight = 90

    let compositor: Compositor

    init() throws {
        compositor = try Compositor(context: GPU.context, collectsStats: false)
    }

    private func render(_ frame: CompositorFrame) -> MTLTexture {
        let target = GPU.target(width: Self.canvasWidth, height: Self.canvasHeight)
        GPU.run { compositor.encode(frame, into: target, commandBuffer: $0) }
        return target
    }

    private let redSource = GPU.solid(width: 32, height: 18, Pixel(red: 255, green: 0, blue: 0, alpha: 255))
    private let blueSource = GPU.solid(width: 32, height: 18, Pixel(red: 0, green: 0, blue: 255, alpha: 255))

    // MARK: Mezcla

    @Test(arguments: [Float(0), 0.5, 1])
    func fadeMix(mix: Float) {
        let out = render(CompositorFrame(a: redSource, b: blueSource, mix: mix, kind: .fade))
        let m = Double(mix)
        let want = Expected(red: 255 * (1 - m), green: 0, blue: 255 * m)
        let result = compare(out) { _, _ in want }
        #expect(result.maxDeltaE < 1, "\(result)")
        #expect(result.maxAlphaError <= 1, "\(result)")
    }

    @Test func cutSelectsWholeInput() {
        let atStart = render(CompositorFrame(a: redSource, b: blueSource, mix: 0, kind: .cut))
        let atEnd = render(CompositorFrame(a: redSource, b: blueSource, mix: 1, kind: .cut))
        #expect(compare(atStart) { _, _ in .red }.maxDeltaE < 1)
        #expect(compare(atEnd) { _, _ in .blue }.maxDeltaE < 1)
    }

    @Test func wipeHalfway() {
        let out = render(CompositorFrame(a: redSource, b: blueSource, mix: 0.5, kind: .wipe))
        // B entra por la izquierda; se omite la banda suave alrededor de x = 80.
        let result = compare(out) { x, _ in
            if abs(x - 80) <= 2 { return nil }
            return x < 80 ? .blue : .red
        }
        #expect(result.maxDeltaE < 1, "\(result)")
        #expect(compare(render(CompositorFrame(a: redSource, b: blueSource, mix: 0, kind: .wipe))) { _, _ in .red }
            .maxDeltaE < 1)
        #expect(compare(render(CompositorFrame(a: redSource, b: blueSource, mix: 1, kind: .wipe))) { _, _ in .blue }
            .maxDeltaE < 1)
    }

    // MARK: Entradas nil y alfa

    @Test func nilInputsAreTransparentOverBackground() {
        let both = render(CompositorFrame(a: nil, b: nil, mix: 0.3, kind: .fade))
        #expect(compare(both) { _, _ in .black }.maxDeltaE < 1)

        let halfB = render(CompositorFrame(a: nil, b: redSource, mix: 0.5, kind: .fade))
        let result = compare(halfB) { _, _ in Expected(red: 127.5, green: 0, blue: 0) }
        #expect(result.maxDeltaE < 1, "\(result)")
    }

    @Test func clearBackgroundKeepsTransparency() throws {
        let transparent = try Compositor(context: GPU.context, collectsStats: false)
        transparent.backgroundColor = .clear
        let target = GPU.target(width: 16, height: 9)
        GPU.run { transparent.encode(CompositorFrame(a: nil, b: nil, mix: 0, kind: .cut), into: target, commandBuffer: $0) }
        #expect(GPU.read(target).allSatisfy { $0 == Pixel(red: 0, green: 0, blue: 0, alpha: 0) })
    }

    @Test func premultipliedAlphaOverWhite() throws {
        let white = try Compositor(context: GPU.context, collectsStats: false)
        white.backgroundColor = RGBAColor(red: 1, green: 1, blue: 1)
        // Rojo al 50 % premultiplicado: (128, 0, 0, 128).
        let halfRed = GPU.solid(width: 16, height: 9, Pixel(red: 128, green: 0, blue: 0, alpha: 128))
        let target = GPU.target(width: 32, height: 18)
        GPU.run { white.encode(CompositorFrame(a: halfRed, b: nil, mix: 0, kind: .fade), into: target, commandBuffer: $0) }
        let k = 1 - 128.0 / 255
        let result = compare(target) { _, _ in Expected(red: 128 + 255 * k, green: 255 * k, blue: 255 * k) }
        #expect(result.maxDeltaE < 1, "\(result)")
    }

    // MARK: Encaje fit / fill / stretch

    /// Fuente con una banda magenta de `band` filas arriba y el resto verde.
    private func bandSource(width: Int, height: Int, band: Int) -> MTLTexture {
        GPU.texture(width: width, height: height) { _, y in
            y < band ? Pixel(red: 255, green: 0, blue: 255, alpha: 255) : Pixel(red: 0, green: 255, blue: 0, alpha: 255)
        }
    }

    /// Valor esperado para una fuente de banda colocada en `rect` (píxeles del lienzo).
    /// Se omiten los píxeles a < 1,5 px de los bordes del rectángulo y los de la frontera de la banda.
    private func expectedBand(rect: CGRect, sourceHeight: Double,
                              band: Double) -> (Int, Int) -> Expected? {
        { x, y in
            let px = Double(x) + 0.5
            let py = Double(y) + 0.5
            let (minX, minY, maxX, maxY) = (rect.minX, rect.minY, rect.maxX, rect.maxY)
            let nearEdge = abs(px - minX) < 1.5 || abs(px - maxX) < 1.5 || abs(py - minY) < 1.5 || abs(py - maxY) < 1.5
            if nearEdge { return nil }
            if px < minX || px > maxX || py < minY || py > maxY { return .black }
            let sourceY = (py - minY) / rect.height * sourceHeight
            if abs(sourceY - band) < 1 { return nil }
            return sourceY < band ? .magenta : .green
        }
    }

    @Test func fitFillStretchFourByThree() {
        let source = bandSource(width: 120, height: 90, band: 10)
        let cases: [(FitMode, CGRect)] = [
            (.fit, CGRect(x: 20, y: 0, width: 120, height: 90)),        // pillarbox de 20 px
            (.fill, CGRect(x: 0, y: -15, width: 160, height: 120)),    // recorta 15 px arriba y abajo
            (.stretch, CGRect(x: 0, y: 0, width: 160, height: 90))
        ]
        for (mode, rect) in cases {
            let out = render(CompositorFrame(a: source, b: nil, mix: 0, kind: .cut, fitA: mode))
            let result = compare(out, expectedBand(rect: rect, sourceHeight: 90, band: 10))
            #expect(result.maxDeltaE < 1, "\(mode): \(result)")
            #expect(result.compared > 10_000, "\(mode): \(result)")
        }
    }

    @Test func fitFillStretchVertical() {
        let source = bandSource(width: 36, height: 64, band: 8)
        let fitWidth = 90.0 * 36 / 64
        let fillHeight = 160.0 * 64 / 36
        let cases: [(FitMode, CGRect)] = [
            (.fit, CGRect(x: (160 - fitWidth) / 2, y: 0, width: fitWidth, height: 90)),
            (.fill, CGRect(x: 0, y: (90 - fillHeight) / 2, width: 160, height: fillHeight)),
            (.stretch, CGRect(x: 0, y: 0, width: 160, height: 90))
        ]
        for (mode, rect) in cases {
            let out = render(CompositorFrame(a: source, b: nil, mix: 0, kind: .cut, fitA: mode))
            let result = compare(out, expectedBand(rect: rect, sourceHeight: 64, band: 8))
            #expect(result.maxDeltaE < 1, "\(mode): \(result)")
            #expect(result.compared > 9_000, "\(mode): \(result)")
        }
    }

    @Test func eachInputUsesItsOwnFit() {
        // A 4:3 en fit (pillarbox negro), B 16:9 en fill; a mitad de fundido.
        let a = GPU.solid(width: 120, height: 90, Pixel(red: 255, green: 0, blue: 0, alpha: 255))
        let out = render(CompositorFrame(a: a, b: blueSource, mix: 0.5, kind: .fade, fitA: .fit, fitB: .fill))
        let result = compare(out) { x, _ in
            if abs(x - 20) <= 1 || abs(x - 140) <= 1 { return nil }
            return x < 20 || x >= 140 ? Expected(red: 0, green: 0, blue: 127.5) : Expected(red: 127.5, green: 0, blue: 127.5)
        }
        #expect(result.maxDeltaE < 1, "\(result)")
    }

    // MARK: Pipelines no preparados

    @Test func unpreparedFormatClearsWithoutCompiling() throws {
        let local = try Compositor(context: GPU.context, collectsStats: false)
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 16, height: 9,
                                                            mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .shared
        let target = try #require(GPU.context.device.makeTexture(descriptor: desc))
        let frame = CompositorFrame(a: redSource, b: nil, mix: 0, kind: .cut)

        GPU.run { local.encode(frame, into: target, commandBuffer: $0) }
        #expect(local.missingPipelineFrames == 1)
        // Respaldo: fondo negro (rgba8: bytes R,G,B,A).
        var bytes = [UInt8](repeating: 9, count: 4)
        target.getBytes(&bytes, bytesPerRow: 16 * 4, from: MTLRegionMake2D(8, 4, 1, 1), mipmapLevel: 0)
        #expect(bytes == [0, 0, 0, 255])

        try local.prepare(pixelFormat: .rgba8Unorm)
        GPU.run { local.encode(frame, into: target, commandBuffer: $0) }
        #expect(local.missingPipelineFrames == 1)
        target.getBytes(&bytes, bytesPerRow: 16 * 4, from: MTLRegionMake2D(8, 4, 1, 1), mipmapLevel: 0)
        #expect(bytes == [255, 0, 0, 255])
    }

    // MARK: Color sólido

    @Test func solidColorTextureCoversCanvas() {
        let color = RGBAColor(red: 0.2, green: 0.4, blue: 0.6)
        let texture = GPU.context.makeSolidColorTexture(color, aspect: PixelSize(width: 160, height: 90))!
        #expect(texture.width == 16 && texture.height == 9)
        #expect(texture.storageMode == .private)
        for mode in FitMode.allCases {
            let out = render(CompositorFrame(a: texture, b: nil, mix: 0, kind: .cut, fitA: mode))
            let result = compare(out) { _, _ in Expected(red: 51, green: 102, blue: 153) }
            #expect(result.maxDeltaE < 1, "\(mode): \(result)")
        }
    }

    @Test func encodeSolidColorIsPremultiplied() {
        let target = GPU.target(width: 8, height: 8)
        GPU.run { GPU.context.encodeSolidColor(RGBAColor(red: 1, green: 0, blue: 0, alpha: 0.5), into: target,
                                               commandBuffer: $0) }
        let pixel = GPU.read(target)[0]
        #expect(abs(Int(pixel.red) - 128) <= 1 && pixel.green == 0 && abs(Int(pixel.alpha) - 128) <= 1)
    }

    @Test func reducedAspect() {
        #expect(MetalContext.reducedAspect(.hd1080) == PixelSize(width: 16, height: 9))
        #expect(MetalContext.reducedAspect(PixelSize(width: 1080, height: 1920)) == PixelSize(width: 9, height: 16))
        #expect(MetalContext.reducedAspect(PixelSize(width: 0, height: 5)) == PixelSize(width: 1, height: 5))
    }

    // MARK: Estadísticas

    @Test func encodeFeedsStats() throws {
        let tracked = try Compositor(context: GPU.context)
        let target = GPU.target(width: 64, height: 36)
        for _ in 0..<3 {
            GPU.run { tracked.encode(CompositorFrame(a: redSource, b: nil, mix: 0, kind: .cut), into: target,
                                     commandBuffer: $0) }
        }
        // El completion handler se ejecuta tras waitUntilCompleted; se da margen.
        for _ in 0..<100 where tracked.stats.gpuTimeMs == 0 { usleep(1_000) }
        #expect(tracked.stats.gpuTimeMs > 0)
        #expect(tracked.stats.fps > 0)
    }
}

@Suite("FitMode geometry")
struct FitGeometryTests {
    @Test func rects() {
        let canvas = PixelSize(width: 160, height: 90)
        let fourThree = PixelSize(width: 4, height: 3)
        #expect(FitMode.fit.normalizedRect(source: fourThree, destination: canvas) == SIMD4(0.125, 0, 0.75, 1))
        #expect(FitMode.fill.normalizedRect(source: fourThree, destination: canvas)
                    == SIMD4(0, Float(1 - 4.0 / 3) / 2, 1, Float(4.0 / 3)))
        #expect(FitMode.stretch.normalizedRect(source: fourThree, destination: canvas) == SIMD4(0, 0, 1, 1))
        #expect(FitMode.fit.normalizedRect(source: canvas, destination: canvas) == SIMD4(0, 0, 1, 1))
        #expect(FitMode.fit.normalizedRect(source: PixelSize(width: 0, height: 0), destination: canvas) == SIMD4(0, 0, 1, 1))
    }
}
