import AVFoundation
import Core
import CoreMocks
import Foundation
import Testing
@testable import Media

extension MediaSerialTests {
    @Suite(.enabled(if: GPU.available), .timeLimit(.minutes(2)))
    struct InputManagerTests {
        let context = GPU.context!

        func smallVideo() async throws -> URL {
            try await TestMediaFactory.shared.video(Spec(width: 320, height: 180, fps: 30, seconds: 2))
        }

        @Test func addsEveryKind() async throws {
            let manager = InputManager(context: context, canvasSize: .hd720)
            let video = InputDescriptor(name: "v", content: .video(MediaReference(path: try await smallVideo().path)))
            let audioURL = try await TestMediaFactory.shared.audio(.wav)
            let pngURL = try await TestMediaFactory.shared.png()
            let audio = InputDescriptor(name: "a", content: .audio(MediaReference(path: audioURL.path), visual: .black))
            let card = InputDescriptor(name: "c", content: .audio(MediaReference(path: audioURL.path),
                                                                  visual: .card(MediaReference(path: pngURL.path))))
            let image = InputDescriptor(name: "i", content: .image(MediaReference(path: pngURL.path)))
            let color = InputDescriptor(name: "k", content: .color(.black))
            for d in [video, audio, card, image, color] { try await manager.add(d) }

            #expect(manager.inputIDs == [video.id, audio.id, card.id, image.id, color.id])
            #expect(manager.frameSource(for: video.id) is VideoInput)
            #expect(manager.frameSource(for: audio.id) is AudioInput)
            #expect(manager.frameSource(for: image.id) is ImageInput)
            #expect(manager.frameSource(for: color.id) is ColorInput)
            #expect(manager.frameSource(for: color.id)?.nativeSize == .hd720)
            #expect(manager.frameSource(for: card.id)?.nativeSize == PixelSize(width: 400, height: 200))
            #expect(manager.audioSource(for: audio.id)?.node is AVAudioPlayerNode)
            #expect(manager.audioSource(for: video.id) == nil) // vídeo sin pista de audio
            #expect(manager.audioSource(for: color.id) == nil)

            await #expect(throws: MediaError.duplicate(color.id.description)) { try await manager.add(color) }
            await manager.remove(video.id)
            #expect(manager.frameSource(for: video.id) == nil)
        }

        @Test func appliesDescriptorTransportSettings() async throws {
            let manager = InputManager(context: context)
            let d = InputDescriptor(name: "v", content: .video(MediaReference(path: try await smallVideo().path)),
                                    loop: true, inPoint: 0.5, outPoint: 1.5)
            try await manager.add(d)
            let video = try #require(manager.frameSource(for: d.id) as? VideoInput)
            let known = await firstEvent(video.events) { if case .durationKnown = $0 { true } else { false } }
            #expect(known == .durationKnown(1.0))
        }

        @Test func playlistNeedsFactory() async throws {
            let playlist = InputDescriptor(name: "p", content: .playlist(Playlist()))
            let bare = InputManager(context: context)
            await #expect(throws: MediaError.self) { try await bare.add(playlist) }

            let withFactory = InputManager(context: context, playlistFactory: { MockFrameSource(id: $0.id) })
            try await withFactory.add(playlist)
            #expect(withFactory.frameSource(for: playlist.id) is MockFrameSource)
        }

        @Test func missingMediaThrowsAndIsNotAdded() async {
            let manager = InputManager(context: context)
            let d = InputDescriptor(name: "x", content: .video(MediaReference(path: "/nonexistent.mov")))
            await #expect(throws: MediaError.self) { try await manager.add(d) }
            #expect(manager.frameSource(for: d.id) == nil)
        }

        @Test func visibilityAndDecoderCap() async throws {
            let manager = InputManager(context: context)
            let url = try await smallVideo()
            var ids: [InputID] = []
            for i in 0..<6 {
                let copy = try await TestMediaFactory.shared.copy(of: url, index: 100 + i)
                let d = InputDescriptor(name: "v\(i)", content: .video(MediaReference(path: copy.path)), loop: true)
                try await manager.add(d)
                ids.append(d.id)
            }
            let audio = InputDescriptor(name: "a", content: .audio(MediaReference(path: try await TestMediaFactory.shared.audio(.wav).path),
                                                                   visual: .black))
            try await manager.add(audio)
            let videos = ids.compactMap { manager.frameSource(for: $0) as? VideoInput }
            videos.forEach { $0.play() }

            // Sin setVisible todas cuentan como visibles: decodifican las 4 primeras.
            #expect(manager.activeDecoderIDs == Set(ids.prefix(4)))
            try await Task.sleep(for: .milliseconds(200))
            #expect(videos.map(\.isDecoding) == [true, true, true, true, false, false])

            manager.setVisible([ids[5], ids[1], audio.id])
            #expect(manager.activeDecoderIDs == [ids[1], ids[5]])
            try await Task.sleep(for: .milliseconds(200))
            #expect(videos.map(\.isDecoding) == [false, true, false, false, false, true])
            // El estado lógico no cambia al ocultar.
            #expect(videos.allSatisfy { $0.playbackState == .playing })

            manager.setVisible([])
            #expect(manager.activeDecoderIDs.isEmpty)
            try await Task.sleep(for: .milliseconds(200))
            #expect(videos.allSatisfy { !$0.isDecoding })
            videos.forEach { $0.pause() }
        }
    }
}

/// Aceptación T32: entradas no visibles a 0 % de CPU.
extension MediaSerialTests {
    @Suite(.serialized, .enabled(if: GPU.available), .timeLimit(.minutes(3)))
    struct HiddenInputsCPUTests {
        @Test func hiddenInputsUseNoCPU() async throws {
            let manager = InputManager(context: GPU.context!)
            let master = try await TestMediaFactory.shared.video(Spec(codec: .h264, fps: 60, seconds: 8))
            let baseline = await measureCPU(seconds: 3)

            var videos: [VideoInput] = []
            for i in 0..<8 {
                let url = try await TestMediaFactory.shared.copy(of: master, index: 200 + i)
                let d = InputDescriptor(name: "v\(i)", content: .video(MediaReference(path: url.path)), loop: true)
                try await manager.add(d)
                videos.append(try #require(manager.frameSource(for: d.id) as? VideoInput))
            }
            videos.forEach { $0.play() }
            // Visibles (4 decodificando) y consumidas a 60 Hz como haría el render.
            let consumer = Task {
                while !Task.isCancelled {
                    let now = HostClock.hostTime(nanos: HostClock.nowNanos())
                    for v in videos { _ = v.texture(for: now) }
                    try? await Task.sleep(for: .milliseconds(16))
                }
            }
            try await Task.sleep(for: .milliseconds(500))
            let visible = await measureCPU(seconds: 3)
            consumer.cancel()

            manager.setVisible([])
            try await Task.sleep(for: .milliseconds(500))
            let hidden = await measureCPU(seconds: 3)
            print("""
                [T32] CPU proceso (% de un núcleo): base sin entradas \(String(format: "%.2f", baseline)) · \
                8 cargadas/4 decodificando visibles \(String(format: "%.2f", visible)) · \
                8 ocultas (lógicamente en play) \(String(format: "%.2f", hidden)) · \
                delta ocultas − base \(String(format: "%.2f", hidden - baseline))
                """)
            #expect(videos.allSatisfy { !$0.isDecoding && $0.playbackState == .playing })
            PerfGate.check(hidden - baseline < 1.0, "CPU ocultas − base \(hidden - baseline) % < 1")
            videos.forEach { $0.pause() }
        }
    }
}
