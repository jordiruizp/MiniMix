import Core
import CoreGraphics
import Foundation
import Metal
import Render
import TestSupport

/// Búfer de lectura de una ranura: solo lo toca la GPU (blit) y después el completion handler de
/// ese mismo command buffer; la ranura no se reutiliza hasta que ese fotograma ha terminado.
private struct Readback: @unchecked Sendable {
    let buffer: MTLBuffer
}

/// Buses que compone el renderer (equivalente a `BusState` de la app).
struct HarnessBus: Sendable, Equatable {
    struct Transition: Sendable, Equatable {
        var from: InputID?
        var to: InputID?
        var kind: TransitionKind
        var progress: Double
    }

    var preview: InputID?
    var program: InputID?
    var transition: Transition?
}

/// Réplica del bucle de `LiveRenderer` (App, T80) con el `Compositor` real: Programa (estadísticas
/// `.external`) + Preview por tick, máx. 3 command buffers en vuelo. Además copia (blit) la esquina
/// del código de fotograma de Programa a un búfer compartido y la lee al completarse la GPU: así
/// mide fotogramas negros/saltados/repetidos y la latencia de Cut sin bloquear el render.
final class LiveFrameRenderer: @unchecked Sendable {
    // @unchecked: estado mutable tras `LockedBox`; recursos Metal inmutables tras init.
    static let maxFramesInFlight = 3
    private static let ringSize = maxFramesInFlight + 1

    struct PendingCut {
        var clipID: Int
        var frameIndex: Int
        var issuedAt: ContinuousClock.Instant
    }

    /// Lo que se acumula al completar cada fotograma.
    struct Probe {
        var analysis = FrameSequenceAnalysis(keepsCodes: false)
        var inFlight = 0
        /// Envíos admitidos (elige la ranura del anillo: con ≤ 3 en vuelo y 4 ranuras nunca se pisan).
        var submitted = 0
        var completed = 0
        var lastCompletedIndex = -1
        var outOfOrder = 0
        var gpuSeconds = 0.0
        var gpuMs = Histogram(binWidth: 0.05, upperBound: 100)
        var transitionFrames = 0
        var foreignClipFrames = 0
        var firstCodedFrameAt: ContinuousClock.Instant?
        var pendingCut: PendingCut?
        var cutLatencyFrames = Histogram(binWidth: 1, upperBound: 120)
        var cutLatencyMs = Histogram(binWidth: 1, upperBound: 2000)
        var unmatchedCuts = 0
    }

    let context: MetalContext
    let program: Compositor
    private let preview: Compositor
    private let programTargets: [MTLTexture]
    private let previewTargets: [MTLTexture]
    private let readbacks: [MTLBuffer]
    private let region: MTLRegion
    private let layout: FrameCodeLayout
    private let expectedProgramClips: Set<Int>?
    let probe = LockedBox(Probe())

    /// - Parameter expectedProgramClips: si se da, los códigos de Programa fuera de este conjunto se
    ///   cuentan como `foreignClipFrames` (escenario de playlist).
    init(context: MetalContext, canvas: CanvasFormat, expectedProgramClips: Set<Int>?) throws {
        self.context = context
        program = try Compositor(context: context, frameRate: canvas.frameRate, statsMode: .external)
        preview = try Compositor(context: context, frameRate: canvas.frameRate, statsMode: .disabled)
        let size = canvas.size
        func target() throws -> MTLTexture {
            let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: size.width,
                                                                height: size.height, mipmapped: false)
            desc.usage = [.renderTarget, .shaderRead]
            desc.storageMode = .private
            guard let texture = context.device.makeTexture(descriptor: desc) else { throw RenderError.textureAllocationFailed }
            return texture
        }
        programTargets = try (0..<Self.ringSize).map { _ in try target() }
        previewTargets = try (0..<Self.ringSize).map { _ in try target() }
        // Esquina inferior izquierda: tira del código (23 celdas) con margen.
        let cell = Double(min(size.width, size.height)) / 45
        let width = min(size.width, Int((26 * cell).rounded(.up)))
        let height = min(size.height, Int((7 * cell).rounded(.up)))
        region = MTLRegionMake2D(0, size.height - height, width, height)
        layout = FrameCodeLayout(contentRect: CGRect(x: 0, y: -(size.height - height), width: size.width, height: size.height))
        readbacks = try (0..<Self.ringSize).map { _ in
            guard let buffer = context.device.makeBuffer(length: width * height * 4, options: .storageModeShared) else {
                throw RenderError.textureAllocationFailed
            }
            return buffer
        }
        self.expectedProgramClips = expectedProgramClips
    }

    /// Registra un Cut hacia un clip con código: la latencia se mide hasta el primer fotograma completado
    /// de Programa que lo muestra.
    func expectCut(to clipID: Int, at frameIndex: Int) {
        probe.withLock { state in
            if state.pendingCut != nil { state.unmatchedCuts += 1 }
            state.pendingCut = PendingCut(clipID: clipID, frameIndex: frameIndex, issuedAt: .now)
        }
    }

    /// Compone un fotograma. false = descartado porque ya hay `maxFramesInFlight` en vuelo.
    func render(bus: HarnessBus, sources: [InputID: FrameSource], at time: HostTime, frameIndex: Int) -> Bool {
        let slot = probe.withLock { state -> Int? in
            guard state.inFlight < Self.maxFramesInFlight else { return nil }
            state.inFlight += 1
            state.submitted += 1
            return state.submitted % Self.ringSize
        }
        guard let slot else { return false }
        guard let commands = context.commandQueue.makeCommandBuffer() else {
            probe.withLock { $0.inFlight -= 1 }
            return false
        }
        let programTarget = programTargets[slot]
        program.encode(programFrame(bus, sources, time), into: programTarget, commandBuffer: commands)
        preview.encode(CompositorFrame(a: bus.preview.flatMap { sources[$0]?.texture(for: time) }, b: nil, mix: 0, kind: .cut),
                       into: previewTargets[slot], commandBuffer: commands)
        let buffer = readbacks[slot]
        if let blit = commands.makeBlitCommandEncoder() {
            blit.copy(from: programTarget, sourceSlice: 0, sourceLevel: 0, sourceOrigin: region.origin,
                      sourceSize: region.size, to: buffer, destinationOffset: 0,
                      destinationBytesPerRow: region.size.width * 4, destinationBytesPerImage: buffer.length)
            blit.endEncoding()
        }
        let readback = Readback(buffer: buffer)
        let inTransition = bus.transition != nil
        let probe = probe
        let layout = layout
        let size = region.size
        let expected = expectedProgramClips
        commands.addCompletedHandler { cb in
            let reading = FrameCodeReader.read(
                BGRALumaSampler(base: readback.buffer.contents(), width: size.width, height: size.height, bytesPerRow: size.width * 4),
                layout: layout)
            let gpu = max(0, cb.gpuEndTime - cb.gpuStartTime)
            let frame = CompletedFrame(index: frameIndex, inTransition: inTransition, gpuSeconds: gpu)
            probe.withLock { Self.record(reading, frame, expected: expected, into: &$0) }
        }
        program.frameSubmitted(at: time.seconds)
        commands.commit()
        return true
    }

    struct CompletedFrame {
        var index: Int
        var inTransition: Bool
        var gpuSeconds: Double
    }

    private static func record(_ reading: FrameCodeReading, _ frame: CompletedFrame, expected: Set<Int>?,
                               into state: inout Probe) {
        let frameIndex = frame.index
        let gpu = frame.gpuSeconds
        state.inFlight -= 1
        state.completed += 1
        state.gpuSeconds += gpu
        state.gpuMs.add(gpu * 1000)
        if frameIndex < state.lastCompletedIndex { state.outOfOrder += 1 }
        state.lastCompletedIndex = max(state.lastCompletedIndex, frameIndex)
        if reading.code != nil, state.firstCodedFrameAt == nil { state.firstCodedFrameAt = .now }
        if let pending = state.pendingCut, frameIndex >= pending.frameIndex {
            if reading.code?.clipID == pending.clipID {
                state.cutLatencyFrames.add(Double(frameIndex - pending.frameIndex))
                state.cutLatencyMs.add(pending.issuedAt.duration(to: .now).seconds * 1000)
                state.pendingCut = nil
            } else if frameIndex - pending.frameIndex > 30 {
                state.unmatchedCuts += 1
                state.pendingCut = nil
            }
        }
        // Las mezclas de una transición no llevan código legible (por diseño): fuera del análisis.
        guard !frame.inTransition else {
            state.transitionFrames += 1
            return
        }
        if let expected, let clip = reading.code?.clipID, !expected.contains(clip) { state.foreignClipFrames += 1 }
        // Sin código, uniforme y no negro: entrada/item de color (relleno esperado).
        let filler = reading.code == nil && !reading.isBlack && abs(reading.contrast) < 0.05
        state.analysis.append(reading, isFiller: filler)
    }

    private func programFrame(_ bus: HarnessBus, _ sources: [InputID: FrameSource], _ time: HostTime) -> CompositorFrame {
        if let transition = bus.transition {
            return CompositorFrame(a: transition.from.flatMap { sources[$0]?.texture(for: time) },
                                   b: transition.to.flatMap { sources[$0]?.texture(for: time) },
                                   mix: Float(TransitionCurve.videoMix(transition.progress)),
                                   kind: transition.kind == .cut ? .fade : transition.kind)
        }
        return CompositorFrame(a: bus.program.flatMap { sources[$0]?.texture(for: time) }, b: nil, mix: 0, kind: .cut)
    }
}
