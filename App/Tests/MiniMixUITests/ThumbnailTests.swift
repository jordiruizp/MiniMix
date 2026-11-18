import AVFoundation
import Core
import CoreGraphics
import Foundation
import ImageIO
@testable import MiniMixUI
import Testing
import UniformTypeIdentifiers

@Suite("Miniaturas de entradas")
struct ThumbnailTests {
    private let red = RGBAColor(red: 1, green: 0, blue: 0)

    @Test func colorInputShowsItsColor() {
        let input = InputDescriptor(name: "C", content: .color(red))
        #expect(input.thumbnailSource == .color(red))
    }

    @Test func imageAndVideoUseTheirFile() {
        let image = InputDescriptor(name: "I", content: .image(MediaReference(path: "/a.png")))
        #expect(image.thumbnailSource == .media(.init(path: "/a.png", kind: .image)))
        let video = InputDescriptor(name: "V", content: .video(MediaReference(path: "/v.mov")), inPoint: 2.5)
        #expect(video.thumbnailSource == .media(.init(path: "/v.mov", kind: .video, time: 2.5)))
        let audio = InputDescriptor(name: "A", content: .audio(MediaReference(path: "/a.wav"), visual: .black))
        #expect(audio.thumbnailSource == nil)
    }

    @Test func playlistUsesFirstEnabledVideo() {
        let playlist = Playlist(items: [
            PlaylistItem(source: .audio(MediaReference(path: "/a.wav"))),
            PlaylistItem(source: .image(MediaReference(path: "/i.png"))),
            PlaylistItem(source: .video(MediaReference(path: "/off.mov")), enabled: false),
            PlaylistItem(source: .video(MediaReference(path: "/v.mov")), inPoint: 1)
        ])
        #expect(playlist.thumbnailSource == .media(.init(path: "/v.mov", kind: .video, time: 1)))
    }

    @Test func playlistWithoutVideoFallsBackToFirstVisualItem() {
        let playlist = Playlist(items: [
            PlaylistItem(source: .audio(MediaReference(path: "/a.wav"))),
            PlaylistItem(source: .color(red)),
            PlaylistItem(source: .image(MediaReference(path: "/i.png")))
        ])
        #expect(playlist.thumbnailSource == .color(red))
        #expect(Playlist().thumbnailSource == nil)
    }

    @Test func imageThumbnailIsDownscaled() async throws {
        let url = try Self.writePNG(width: 1920, height: 1080)
        defer { try? FileManager.default.removeItem(at: url) }
        let image = try #require(await ThumbnailStore.generate(.init(path: url.path, kind: .image)))
        #expect(max(image.width, image.height) <= ThumbnailStore.maxPixelSize)
        #expect(image.width > image.height)
    }

    @Test func videoThumbnailIsFirstFrame() async throws {
        let url = try await Self.writeVideo(width: 640, height: 360)
        defer { try? FileManager.default.removeItem(at: url) }
        let image = try #require(await ThumbnailStore.generate(.init(path: url.path, kind: .video)))
        #expect(max(image.width, image.height) <= ThumbnailStore.maxPixelSize)
        #expect(image.width > image.height)
    }

    @MainActor @Test func storeCachesResultsAndRemembersFailures() async throws {
        let url = try Self.writePNG(width: 64, height: 36)
        defer { try? FileManager.default.removeItem(at: url) }
        let store = ThumbnailStore()
        let key = ThumbnailStore.Key(path: url.path, kind: .image)
        await store.load(key)
        #expect(store.image(for: key) != nil)
        let missing = ThumbnailStore.Key(path: "/no/existe.png", kind: .image)
        await store.load(missing)
        #expect(store.image(for: missing) == nil)
    }

    // MARK: - Medios de prueba

    private static func tempURL(_ ext: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("thumb-\(UUID().uuidString).\(ext)")
    }

    private static func writePNG(width: Int, height: Int) throws -> URL {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let url = tempURL("png")
        let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        #expect(CGImageDestinationFinalize(dest))
        return url
    }

    private static func writeVideo(width: Int, height: Int) async throws -> URL {
        let url = tempURL("mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height
        ])
        writer.add(input)
        #expect(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<10 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            let pool = try #require(adaptor.pixelBufferPool)
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            let pixels = try #require(buffer)
            CVPixelBufferLockBaseAddress(pixels, [])
            memset(CVPixelBufferGetBaseAddress(pixels), 0x80, CVPixelBufferGetDataSize(pixels))
            CVPixelBufferUnlockBaseAddress(pixels, [])
            adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 25))
        }
        input.markAsFinished()
        await writer.finishWriting()
        #expect(writer.status == .completed)
        return url
    }
}
