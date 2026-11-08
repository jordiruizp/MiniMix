import Audio
import Core
import Foundation
import Media
import Metal
import Render

/// Resultado de una medición de sincronismo A/V con la claqueta de TestMedia.
public struct AVSyncResult: Codable, Sendable {
    public struct Pair: Codable, Sendable {
        /// Instante de host (s) en que el fotograma con la claqueta encendida llega a la pantalla
        /// (tick en que se compone + `videoPresentationLatency`).
        public var videoHost: Double
        /// Instante de host (s) en que suena el pitido (`AudioOnset.presentationHostTime`).
        public var audioHost: Double
        /// audio − vídeo (ms): positivo = el audio llega tarde.
        public var offsetMs: Double
    }

    public var file: String
    public var measuredSeconds: Double
    public var pairs: [Pair]
    public var meanMs: Double
    public var minMs: Double
    public var maxMs: Double
    public var maxAbsMs: Double
    public var stdDevMs: Double
    /// «audio tarde», «audio adelantado» o «alineado» (|media| < 1 ms).
    public var sign: String
    public var unpairedFlashes: Int
    public var unpairedOnsets: Int
    public var outputLatencyMs: Double
    public var videoPresentationLatencyMs: Double
    public var inputDelayMs: Double
    public var syncProfile: String

    public var summary: String {
        String(format: "A/V %@: media %+.1f ms, mín %+.1f, máx %+.1f, |máx| %.1f ms, σ %.1f ms (%d pares; HAL %.1f ms, retardo %.1f ms)",
               sign, meanMs, minMs, maxMs, maxAbsMs, stdDevMs, pairs.count, outputLatencyMs, inputDelayMs)
    }
}

public enum AVSyncProbeError: Error, CustomStringConvertible {
    case noMetal
    case noAudio(String)
    case noAudioTrack

    public var description: String {
        switch self {
        case .noMetal: "sin dispositivo Metal"
        case .noAudio(let detail): "sin dispositivo de audio: \(detail)"
        case .noAudioTrack: "el archivo no tiene pista de audio"
        }
    }
}

/// Mide el desfase A/V con la cadena real de la App (T80 + perfil `.playerTap`, #15/#22):
/// `InputManager` → `VideoInput` (tap de audio alineado) → `AudioEngine` (perfil `.playerTap`,
/// `videoPresentationLatency` = 1 fotograma, sigue a Programa) y `MasterClock` → `Compositor`.
///
/// Vídeo: se lee (blit) el parche de la claqueta de cada fotograma compuesto; el primer fotograma
/// encendido de cada segundo se presenta en `tick + videoPresentationLatency` (como supone Audio).
/// Audio: `AudioEngine.startOnsetDetection` da el instante de presentación de cada pitido
/// (render + latencia del dispositivo). Desfase = audio − vídeo.
public enum AVSyncProbe {
    private struct Flash: Sendable {
        var index: Int
        var tickSeconds: Double
        var lit: Bool
    }

    private struct Readback: @unchecked Sendable {
        let buffer: MTLBuffer
    }

    // swiftlint:disable:next function_body_length cyclomatic_complexity
    public static func measure(file relativePath: String = "video/h264_1080p25_60s.mp4", seconds: Double = 12,
                               frameRate: FrameRate = .fps60) async throws -> AVSyncResult {
        guard let context = MetalContext.shared else { throw AVSyncProbeError.noMetal }
        let canvas = PixelSize.hd1080
        let audio: AudioEngine
        do {
            audio = try AudioEngine()
            audio.videoPresentationLatency = frameRate.frameDuration
            try audio.start()
        } catch {
            throw AVSyncProbeError.noAudio("\(error)")
        }
        defer { audio.stop() }
        let clock = MasterClock(frameRate: frameRate)
        let manager = InputManager(context: context, canvasSize: canvas)
        let descriptor = InputDescriptor(name: relativePath,
                                         content: .video(MediaReference(path: TestMediaLocator.url(relativePath).path)),
                                         loop: true)
        try await manager.add(descriptor)
        guard let audioSource = manager.audioSource(for: descriptor.id),
              let frameSource = manager.frameSource(for: descriptor.id) else { throw AVSyncProbeError.noAudioTrack }
        // Igual que LiveInputs (App): perfil antes del attach y aviso de cambio de salida después.
        let profile: InputSyncProfile = frameSource is VideoInput ? .playerTap : .direct
        audio.setSyncProfile(profile, for: descriptor.id)
        try audio.attach(audioSource)
        (frameSource as? VideoInput)?.audioOutputDidChange()
        audio.setAudioFollowsProgram(true, for: descriptor.id)
        audio.setProgram(descriptor.id)

        let onsets = LockedBox<[AudioOnset]>([])
        let stream = audio.startOnsetDetection(threshold: 0.3, holdOff: 0.5)
        let collector = Task.detached { for await onset in stream { onsets.withLock { $0.append(onset) } } }

        manager.setVisible([descriptor.id])
        frameSource.play()
        let compositor = try Compositor(context: context, frameRate: frameRate, statsMode: .disabled)
        let layout = FrameCodeLayout(width: canvas.width, height: canvas.height)
        let clap = layout.clapRect
        let region = MTLRegionMake2D(Int(clap.minX), Int(clap.minY), Int(clap.width), Int(clap.height))
        let ring = 4
        let targets: [MTLTexture] = try (0..<ring).map { _ in
            let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: canvas.width,
                                                                height: canvas.height, mipmapped: false)
            desc.usage = [.renderTarget, .shaderRead]
            desc.storageMode = .private
            guard let texture = context.device.makeTexture(descriptor: desc) else { throw AVSyncProbeError.noMetal }
            return texture
        }
        let readbacks: [Readback] = try (0..<ring).map { _ in
            guard let buffer = context.device.makeBuffer(length: region.size.width * region.size.height * 4,
                                                         options: .storageModeShared) else { throw AVSyncProbeError.noMetal }
            return Readback(buffer: buffer)
        }
        let flashes = LockedBox<[Flash]>([])
        let inFlight = LockedBox(0)
        var submitted = 0
        var first: HostTime?
        let ticks = clock.ticks
        clock.start()
        for await tick in ticks {
            let start = first ?? tick
            first = start
            if tick - start >= seconds { break }
            guard inFlight.withLock({ count -> Bool in
                guard count < 3 else { return false }
                count += 1
                return true
            }), let commands = context.commandQueue.makeCommandBuffer() else { continue }
            let slot = submitted % ring
            let index = submitted
            submitted += 1
            compositor.encode(CompositorFrame(a: frameSource.texture(for: tick), b: nil, mix: 0, kind: .cut),
                              into: targets[slot], commandBuffer: commands)
            let readback = readbacks[slot]
            if let blit = commands.makeBlitCommandEncoder() {
                blit.copy(from: targets[slot], sourceSlice: 0, sourceLevel: 0, sourceOrigin: region.origin,
                          sourceSize: region.size, to: readback.buffer, destinationOffset: 0,
                          destinationBytesPerRow: region.size.width * 4, destinationBytesPerImage: readback.buffer.length)
                blit.endEncoding()
            }
            let size = region.size
            let tickSeconds = tick.seconds
            commands.addCompletedHandler { _ in
                let sampler = BGRALumaSampler(base: readback.buffer.contents(), width: size.width, height: size.height,
                                              bytesPerRow: size.width * 4)
                let lit = sampler.averageLuma > 0.5
                flashes.withLock { $0.append(Flash(index: index, tickSeconds: tickSeconds, lit: lit)) }
                inFlight.withLock { $0 -= 1 }
            }
            commands.commit()
        }
        clock.stop()
        for _ in 0..<200 where inFlight.withLock({ $0 }) > 0 { try? await Task.sleep(for: .milliseconds(5)) }
        audio.stopOnsetDetection()
        _ = await collector.value
        frameSource.pause()
        await manager.remove(descriptor.id)

        let outputLatency = audio.outputLatency?.presentationSeconds ?? 0
        return pair(flashes: flashes.withLock { $0 }, onsets: onsets.withLock { $0 }, file: relativePath, seconds: seconds,
                    videoLatency: frameRate.frameDuration, outputLatency: outputLatency,
                    inputDelayMs: audio.inputDelayMilliseconds(for: descriptor.id), profile: "\(profile)")
    }

    // swiftlint:disable:next function_parameter_count
    private static func pair(flashes: [Flash], onsets: [AudioOnset], file: String, seconds: Double,
                             videoLatency: Double, outputLatency: Double, inputDelayMs: Double,
                             profile: String) -> AVSyncResult {
        // Flancos de subida de la claqueta (el primer fotograma encendido de cada segundo).
        let ordered = flashes.sorted { $0.index < $1.index }
        var rising: [Double] = []
        for (previous, flash) in zip([Flash(index: -1, tickSeconds: 0, lit: false)] + ordered, ordered)
        where flash.lit && !previous.lit {
            rising.append(flash.tickSeconds + videoLatency)
        }
        // El primer segundo es de arranque (decodificador y motor); se descarta.
        let start = ordered.first?.tickSeconds ?? 0
        let video = rising.filter { $0 > start + 1 }
        let audio = onsets.compactMap(\.presentationHostTime).filter { $0 > start + 1 }
        var pairs: [AVSyncResult.Pair] = []
        var usedAudio = Set<Int>()
        for v in video {
            guard let (index, a) = audio.enumerated().filter({ !usedAudio.contains($0.offset) })
                .min(by: { abs($0.element - v) < abs($1.element - v) }), abs(a - v) < 0.25 else { continue }
            usedAudio.insert(index)
            pairs.append(.init(videoHost: v, audioHost: a, offsetMs: (a - v) * 1000))
        }
        let offsets = pairs.map(\.offsetMs)
        let mean = offsets.isEmpty ? 0 : offsets.reduce(0, +) / Double(offsets.count)
        let variance = offsets.isEmpty ? 0 : offsets.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(offsets.count)
        let sign = abs(mean) < 1 ? "alineado" : (mean > 0 ? "audio tarde" : "audio adelantado")
        return AVSyncResult(
            file: file, measuredSeconds: seconds, pairs: pairs, meanMs: mean, minMs: offsets.min() ?? 0,
            maxMs: offsets.max() ?? 0, maxAbsMs: offsets.map(abs).max() ?? 0, stdDevMs: variance.squareRoot(),
            sign: sign, unpairedFlashes: video.count - pairs.count, unpairedOnsets: audio.count - pairs.count,
            outputLatencyMs: outputLatency * 1000, videoPresentationLatencyMs: videoLatency * 1000,
            inputDelayMs: inputDelayMs, syncProfile: profile)
    }
}
