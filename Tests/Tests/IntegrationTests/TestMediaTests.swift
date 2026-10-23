import AVFoundation
import Foundation
import Testing
@testable import TestSupport

/// El manifiesto está versionado: se comprueba aunque TestMedia no esté generado.
@Test func manifestAudioCodecsUseFormatNames() throws {
    let codecs = Set(try TestMediaLocator.manifest().files.compactMap { $0.audio?.codec })
    #expect(codecs.isSubset(of: ["aac", "mp3", "pcm_s16le", "pcm_s16be"]), "\(codecs)")
    #expect(codecs.contains("mp3"))
}

/// Comprueba TestMedia generado (T60) con los lectores de TestSupport (T61).
/// Se desactiva si no se ha ejecutado `Tools/generate-testmedia.sh`.
@Suite("TestMedia", .enabled(if: TestMediaLocator.isGenerated, "TestMedia sin generar"))
struct TestMediaTests {
    @Test func manifestIsVersionedAndDescribesExistingFiles() throws {
        let manifest = try TestMediaLocator.manifest()
        #expect(manifest.schemaVersion == 1)
        #expect(manifest.files.count >= 40)
        for file in manifest.files {
            #expect(FileManager.default.fileExists(atPath: file.url.path), "falta \(file.file)")
        }
        let ids = manifest.files.compactMap { $0.frameCode?.clipID }
        let videoIDs = manifest.files.filter { $0.kind == "video" }.compactMap { $0.frameCode?.clipID }
        #expect(Set(videoIDs).count == videoIDs.count, "clipID únicos por vídeo")
        #expect(!ids.isEmpty)
        let playlist = try #require(manifest.set("playlist_mixed"))
        #expect(playlist.items.map(\.type) == ["video", "image", "video", "color"])
    }

    @Test(arguments: ["video/h264_1080p2997.mp4", "video/hevc_720p2997.mp4", "video/h264_vertical_1080x1920p30.mp4",
                      "video/prores4444_alpha_1080p25.mov", "video/hevc_alpha_1080p25.mov"])
    func everyDecodedFrameCarriesItsCode(path: String) async throws {
        let entry = try #require(try TestMediaLocator.manifest().file(path))
        let range = try #require(entry.frameCode)
        let alpha = entry.alpha
        let readings = try await decodeFrames(entry.url, bgra: alpha)
        #expect(readings.count == entry.frames)
        let analysis = FrameSequenceAnalysis(readings)
        #expect(analysis.isGapless && analysis.repeats == 0)
        #expect(analysis.codes.first?.value == range.first)
        #expect(analysis.codes.last?.value == range.last)
        // Claqueta: encendida exactamente en el primer frame de cada segundo.
        let fps = try #require(entry.fps)
        let lit = readings.indices.filter { readings[$0].clapLit }
        let expected = readings.indices.filter { i in
            let t = Double(i) / fps
            return t - t.rounded(.down) < 1 / fps - 1e-6
        }
        #expect(lit == expected)
    }

    @Test(arguments: ["image/png_alpha_1920x1080.png", "image/jpeg_1920x1080.jpg", "image/tiff_1920x1080.tif",
                      "image/heic_1920x1080.heic", "image/png_alpha_1080x1920.png"])
    func stillImagesCarryTheirCode(path: String) throws {
        let entry = try #require(try TestMediaLocator.manifest().file(path))
        let image = try RGBAImage(contentsOf: entry.url)
        #expect(image.width == entry.width && image.height == entry.height)
        #expect(FrameCodeReader.read(image).code?.value == entry.frameCode?.first)
        if entry.alpha {
            #expect(image[0, 0].a == 0, "esquina transparente")
            #expect(image[image.width / 2, image.height / 2].a == 255, "centro opaco")
        }
    }

    @Test func mediaDurationsMatchManifest() async throws {
        for entry in try TestMediaLocator.manifest().files where entry.kind != "image" {
            let asset = AVURLAsset(url: entry.url)
            let seconds = try await asset.load(.duration).seconds
            let expected = try #require(entry.duration)
            // MP3/AAC añaden retardo o relleno del codificador.
            #expect(abs(seconds - expected) < 0.1, "\(entry.file): \(seconds) s")
        }
    }

    /// Decodifica todos los fotogramas con AVAssetReader y lee su código.
    private func decodeFrames(_ url: URL, bgra: Bool) async throws -> [FrameCodeReading] {
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let reader = try AVAssetReader(asset: asset)
        let format = bgra ? kCVPixelFormatType_32BGRA : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        let output = AVAssetReaderTrackOutput(
            track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: format])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        #expect(reader.startReading())
        var readings: [FrameCodeReading] = []
        while let sample = output.copyNextSampleBuffer() {
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            readings.append(try FrameCodeReader.read(pixelBuffer: buffer))
        }
        #expect(reader.status == .completed)
        return readings
    }
}
