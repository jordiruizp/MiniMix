import AVFoundation
import CoreVideo
import ImageIO
import Foundation

/// Genera medios de prueba con AVAssetWriter en un directorio temporal
/// (TestMedia/ es de H y no se usa aquí). Cada archivo se genera una vez por proceso.
actor TestMediaFactory {
    static let shared = TestMediaFactory()

    struct VideoSpec: Hashable, Sendable {
        var codec: Codec = .h264
        var width = 1920
        var height = 1080
        var fps: Int32 = 60
        var seconds: Double = 4
        var audio = false
        var container: AVFileType = .mov

        enum Codec: String, Sendable { case h264, hevc, hevcAlpha, proRes422 }

        var name: String {
            let ext = container == .mp4 ? "mp4" : container == .m4v ? "m4v" : "mov"
            return "\(codec.rawValue)-\(width)x\(height)-\(fps)-\(seconds)-\(audio ? "a" : "na").\(ext)"
        }
    }

    enum AudioFormatSpec: String, Sendable {
        case wav, aiff, m4a

        var fileType: AVFileType {
            switch self {
            case .wav: .wav
            case .aiff: .aiff
            case .m4a: .m4a
            }
        }
    }

    let directory: URL
    private var cache: [String: Task<URL, Error>] = [:]

    init() {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("minimix-media-tests-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func video(_ spec: VideoSpec) async throws -> URL {
        try await cached(spec.name) { url in try await Self.writeVideo(spec, to: url) }
    }

    /// Copia de un archivo con otro nombre (para cargar N entradas distintas).
    func copy(of url: URL, index: Int) throws -> URL {
        let target = directory.appendingPathComponent("copy\(index)-\(url.lastPathComponent)")
        if !FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.copyItem(at: url, to: target)
        }
        return target
    }

    func audio(_ format: AudioFormatSpec, seconds: Double = 2, sampleRate: Double = 48_000) async throws -> URL {
        try await cached("tone-\(seconds)-\(Int(sampleRate)).\(format.rawValue)") { url in
            try await Self.writeAudio(format, seconds: seconds, sampleRate: sampleRate, to: url)
        }
    }

    func png(width: Int = 400, height: Int = 200) async throws -> URL {
        try await cached("image-\(width)x\(height).png") { url in
            try Self.writePNG(width: width, height: height, to: url)
        }
    }

    private func cached(_ name: String, _ make: @escaping @Sendable (URL) async throws -> Void) async throws -> URL {
        if let task = cache[name] { return try await task.value }
        let url = directory.appendingPathComponent(name)
        let task = Task {
            try? FileManager.default.removeItem(at: url)
            try await make(url)
            return url
        }
        cache[name] = task
        return try await task.value
    }

    // MARK: Vídeo

    private static func writeVideo(_ spec: VideoSpec, to url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: spec.container)
        let codec: AVVideoCodecType = switch spec.codec {
        case .h264: .h264
        case .hevc: .hevc
        case .hevcAlpha: .hevcWithAlpha
        case .proRes422: .proRes422
        }
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: codec, AVVideoWidthKey: spec.width, AVVideoHeightKey: spec.height
        ])
        videoInput.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: spec.width, kCVPixelBufferHeightKey as String: spec.height
        ])
        writer.add(videoInput)
        var audioInput: AVAssetWriterInput?
        if spec.audio {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 128_000
            ])
            input.expectsMediaDataInRealTime = false
            writer.add(input)
            audioInput = input
        }
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)

        let frames = Int(Double(spec.fps) * spec.seconds)
        for frame in 0..<frames {
            while !videoInput.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            guard let pool = adaptor.pixelBufferPool else { throw CocoaError(.fileWriteUnknown) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { throw CocoaError(.fileWriteUnknown) }
            fill(buffer, frame: frame, alpha: spec.codec == .hevcAlpha)
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: spec.fps))
        }
        videoInput.markAsFinished()

        if let audioInput {
            let sampleRate = 48_000
            let total = Int(spec.seconds * Double(sampleRate))
            var written = 0
            while written < total {
                while !audioInput.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
                let count = min(1024, total - written)
                audioInput.append(try sineSampleBuffer(start: written, count: count, sampleRate: sampleRate))
                written += count
            }
            audioInput.markAsFinished()
        }
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    }

    /// Color plano que cambia con el fotograma (escritura CPU solo para generar el medio de prueba).
    private static func fill(_ buffer: CVPixelBuffer, frame: Int, alpha: Bool) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let value = UInt32(frame % 256)
        let a: UInt32 = alpha ? 128 : 255
        let pixel = (a << 24) | ((255 - value) << 16) | (value << 8) | 0x40
        for y in 0..<height {
            let row = (base + y * bytesPerRow).assumingMemoryBound(to: UInt32.self)
            row.update(repeating: pixel, count: width)
        }
    }

    private static func sineSampleBuffer(start: Int, count: Int, sampleRate: Int) throws -> CMSampleBuffer {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: Float64(sampleRate), mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 2,
            mBitsPerChannel: 32, mReserved: 0)
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil,
                                       magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
        var samples = [Float](repeating: 0, count: count * 2)
        for i in 0..<count {
            let v = Float(sin(2 * Double.pi * 440 * Double(start + i) / Double(sampleRate))) * 0.5
            samples[2 * i] = v
            samples[2 * i + 1] = v
        }
        var block: CMBlockBuffer?
        let bytes = samples.count * 4
        CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil,
                                           customBlockSource: nil, offsetToData: 0, dataLength: bytes, flags: 0,
                                           blockBufferOut: &block)
        guard let block, let format else { throw CocoaError(.fileWriteUnknown) }
        samples.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block,
                                                                     offsetIntoDestination: 0, dataLength: bytes) }
        var sample: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: count,
            presentationTimeStamp: CMTime(value: CMTimeValue(start), timescale: CMTimeScale(sampleRate)),
            packetDescriptions: nil, sampleBufferOut: &sample)
        guard let sample else { throw CocoaError(.fileWriteUnknown) }
        return sample
    }

    // MARK: Audio

    private static func writeAudio(_ format: AudioFormatSpec, seconds: Double, sampleRate: Double, to url: URL) async throws {
        let settings: [String: Any] = switch format {
        case .wav: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 2,
                    AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
        case .aiff: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 2,
                     AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: true]
        case .m4a: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 2]
        }
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let frames = AVAudioFrameCount(seconds * sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames) else {
            throw CocoaError(.fileWriteUnknown)
        }
        buffer.frameLength = frames
        for ch in 0..<Int(file.processingFormat.channelCount) {
            let data = buffer.floatChannelData![ch]
            for i in 0..<Int(frames) { data[i] = Float(sin(2 * Double.pi * 440 * Double(i) / sampleRate)) * 0.5 }
        }
        try file.write(from: buffer)
    }

    // MARK: Imagen

    private static func writePNG(width: Int, height: Int, to url: URL) throws {
        let space = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw CocoaError(.fileWriteUnknown)
        }
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
    }
}
