import Foundation
import Testing
@testable import TestSupport

@Suite("ΔE")
struct ColorDifferenceTests {
    struct Pair {
        var lhs: LabColor
        var rhs: LabColor
        var expected: Double
        init(_ lhs: LabColor, _ rhs: LabColor, _ expected: Double) {
            self.lhs = lhs
            self.rhs = rhs
            self.expected = expected
        }
    }

    /// Pares de referencia de Sharma, Wu y Dalal (2005), tabla 1.
    static let sharmaPairs: [Pair] = [
        Pair(LabColor(l: 50, a: 2.6772, b: -79.7751), LabColor(l: 50, a: 0, b: -82.7485), 2.0425),
        Pair(LabColor(l: 50, a: 0, b: 0), LabColor(l: 50, a: -1, b: 2), 2.3669),
        Pair(LabColor(l: 50, a: 2.5, b: 0), LabColor(l: 73, a: 25, b: -18), 27.1492),
        Pair(LabColor(l: 60.2574, a: -34.0099, b: 36.2677), LabColor(l: 60.4626, a: -34.1751, b: 39.4387), 1.2644),
        Pair(LabColor(l: 2.0776, a: 0.0795, b: -1.1350), LabColor(l: 0.9033, a: -0.0636, b: -0.5514), 0.9082)
    ]

    @Test func ciede2000MatchesSharmaReferenceData() {
        for pair in Self.sharmaPairs {
            let (lhs, rhs, expected) = (pair.lhs, pair.rhs, pair.expected)
            #expect(abs(DeltaE.ciede2000(lhs, rhs) - expected) < 0.0001)
            #expect(abs(DeltaE.ciede2000(rhs, lhs) - expected) < 0.0001, "simétrico")
        }
    }

    @Test func cie76IsEuclidean() {
        #expect(DeltaE.cie76(LabColor(l: 50, a: 0, b: 0), LabColor(l: 53, a: 4, b: 0)) == 5)
    }

    @Test func srgbToLabReferencePoints() {
        let white = LabColor(srgbRed: 255, green: 255, blue: 255)
        #expect(abs(white.l - 100) < 0.01 && abs(white.a) < 0.01 && abs(white.b) < 0.01)
        let black = LabColor(srgbRed: 0, green: 0, blue: 0)
        #expect(abs(black.l) < 0.01)
        let red = LabColor(srgbRed: 255, green: 0, blue: 0)
        #expect(abs(red.l - 53.24) < 0.05 && abs(red.a - 80.09) < 0.05 && abs(red.b - 67.20) < 0.05)
    }

    @Test func identicalImagesHaveZeroDifference() throws {
        var image = RGBAImage(width: 64, height: 36, fill: .init(r: 10, g: 200, b: 30))
        FrameCodeWriter.draw(FrameCode(value: 77), into: &image)
        let diff = try #require(ImageDifference.compare(image, image))
        #expect(diff.maxDeltaE == 0 && diff.isWithin())
        #expect(diff.sampledPixels == 64 * 36)
    }

    @Test func detectsLocalisedAndGlobalChanges() throws {
        let base = RGBAImage(width: 100, height: 100, fill: .init(r: 128, g: 128, b: 128))
        var shifted = base
        shifted.fill(CGRect(x: 0, y: 0, width: 100, height: 100), with: .init(r: 129, g: 128, b: 128))
        let tiny = try #require(ImageDifference.compare(shifted, base))
        #expect(tiny.isWithin(), "1 LSB en rojo es imperceptible")

        var patched = base
        patched.fill(CGRect(x: 0, y: 0, width: 10, height: 10), with: .init(r: 255, g: 0, b: 0))
        let patch = try #require(ImageDifference.compare(patched, base))
        #expect(abs(patch.fractionAboveThreshold - 0.01) < 1e-9)
        #expect(patch.maxDeltaE > 25)
        #expect(!patch.isWithin(mean: 0.1))
        #expect(ImageDifference.compare(base, RGBAImage(width: 10, height: 10)) == nil)
    }

    @Test func pngRoundTripPreservesPixels() throws {
        var image = RGBAImage(width: 32, height: 16, fill: .init(r: 1, g: 2, b: 3, a: 255))
        image[5, 5] = .init(r: 250, g: 128, b: 7, a: 255)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("minimix-deltae-\(UUID()).png")
        defer { try? FileManager.default.removeItem(at: url) }
        try image.writePNG(to: url)
        #expect(try RGBAImage(contentsOf: url) == image)
    }
}
