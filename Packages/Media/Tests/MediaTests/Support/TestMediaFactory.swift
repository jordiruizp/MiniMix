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
        var audioSampleRate = 48_000
        /// Clics de 5 ms en 0,1 s + k·1 s (PCM sin compresión, sin retardo de códec):
        /// verdad de referencia para medir la sincronía A/V.
        var clicks = false

        static let clickOffset = 0.1
        static let clickInterval = 1.0
        var container: AVFileType = .mov

        enum Codec: String, Sendable { case h264, hevc, hevcAlpha, proRes422 }

        var name: String {
            let ext = container == .mp4 ? "mp4" : container == .m4v ? "m4v" : "mov"
            let audioTag = audio ? "a\(audioSampleRate)\(clicks ? "c" : "")" : "na"
            return "\(codec.rawValue)-\(width)x\(height)-\(fps)-\(seconds)-\(audioTag).\(ext)"
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

    static let ffmpeg = "/opt/homebrew/bin/ffmpeg"
    static var hasFFmpeg: Bool { FileManager.default.isExecutableFile(atPath: ffmpeg) }

    /// MP3 (AVFoundation no codifica MP3): se convierte un WAV con ffmpeg.
    func mp3(seconds: Double = 2) async throws -> URL {
        let wav = try await audio(.wav, seconds: seconds)
        return try await cached("tone-\(seconds).mp3") { url in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: Self.ffmpeg)
            process.arguments = ["-loglevel", "error", "-y", "-i", wav.path, "-codec:a", "libmp3lame", "-b:a", "128k", url.path]
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
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

    private static func codecType(_ codec: VideoSpec.Codec) -> AVVideoCodecType {
        switch codec {
        case .h264: .h264
        case .hevc: .hevc
        case .hevcAlpha: .hevcWithAlpha
        case .proRes422: .proRes422
        }
    }

    private static func writeVideo(_ spec: VideoSpec, to url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: spec.container)
        let codec = codecType(spec.codec)
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
            let settings: [String: Any] = spec.clicks
                ? [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: spec.audioSampleRate, AVNumberOfChannelsKey: 2,
                   AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false,
                   AVLinearPCMIsNonInterleaved: false]
                : [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: spec.audioSampleRate, AVNumberOfChannelsKey: 2,
                   AVEncoderBitRateKey: 128_000]
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
            input.expectsMediaDataInRealTime = false
            writer.add(input)
            audioInput = input
        }
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)

        // Escritura entrelazada: AVAssetWriter deja de aceptar vídeo si el audio
        // se queda atrás (y viceversa).
        let frames = Int(Double(spec.fps) * spec.seconds)
        let sampleRate = spec.audioSampleRate
        let totalSamples = audioInput == nil ? 0 : Int(spec.seconds * Double(sampleRate))
        var frame = 0
        var written = 0
        while frame < frames || written < totalSamples {
            var progressed = false
            if frame < frames, videoInput.isReadyForMoreMediaData {
                try appendFrame(frame, spec: spec, to: adaptor)
                frame += 1
                if frame == frames { videoInput.markAsFinished() }
                progressed = true
            }
            if let audioInput, written < totalSamples, audioInput.isReadyForMoreMediaData {
                let count = min(1024, totalSamples - written)
                audioInput.append(try sineSampleBuffer(start: written, count: count, sampleRate: sampleRate,
                                                       clicks: spec.clicks))
                written += count
                if written == totalSamples { audioInput.markAsFinished() }
                progressed = true
            }
            if !progressed { try await Task.sleep(for: .milliseconds(1)) }
        }
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    }

    private static func appendFrame(_ frame: Int, spec: VideoSpec, to adaptor: AVAssetWriterInputPixelBufferAdaptor) throws {
        guard let pool = adaptor.pixelBufferPool else { throw CocoaError(.fileWriteUnknown) }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard let buffer else { throw CocoaError(.fileWriteUnknown) }
        fill(buffer, frame: frame, alpha: spec.codec == .hevcAlpha)
        adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: spec.fps))
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

    private static func sineSampleBuffer(start: Int, count: Int, sampleRate: Int, clicks: Bool = false) throws -> CMSampleBuffer {
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
            let t = Double(start + i) / Double(sampleRate)
            var v = Float(sin(2 * Double.pi * 440 * t)) * 0.5
            if clicks {
                let phase = (t - VideoSpec.clickOffset).truncatingRemainder(dividingBy: VideoSpec.clickInterval)
                v = t >= VideoSpec.clickOffset && phase < 0.005 ? Float(sin(2 * Double.pi * 2_000 * t)) * 0.8 : 0
            }
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
