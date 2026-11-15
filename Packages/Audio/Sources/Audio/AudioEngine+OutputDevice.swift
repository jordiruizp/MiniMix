import AVFAudio
import os

extension AudioEngine {
    private static let outputLogger = Logger(subsystem: "MiniMix", category: "AudioEngine")

    /// Cambia el dispositivo físico por el que suena el motor (Preferencias › Audio): HDMI,
    /// jack, altavoces, USB… `uid` es el de `AudioOutputDevice`; nil = la salida predeterminada
    /// del sistema **en este momento** (una vez fijado un dispositivo explícito, el motor deja de
    /// seguir los cambios de predeterminada hasta el siguiente arranque de la app).
    ///
    /// Para y rearranca el motor si estaba en marcha (fuentes, canales y ajustes no se tocan);
    /// si el dispositivo nuevo tiene otra frecuencia, `mainMixerNode` convierte (como en un
    /// cambio de configuración del sistema). En modo offline no hace nada.
    public func setOutputDevice(uid: String?) throws {
        let device: AudioOutputDevice?
        if let uid {
            guard let found = AudioOutputDevice.find(uid: uid) else {
                throw AudioEngineError.outputDeviceUnavailable(uid)
            }
            device = found
        } else {
            device = AudioOutputDevice.systemDefault()
        }
        guard let device else { return } // Sin ninguna salida en el sistema: nada que cambiar.
        try state.withLock { state in
            guard !state.engine.isInManualRenderingMode else { return }
            let unit = state.engine.outputNode.auAudioUnit
            guard unit.deviceID != device.deviceID else { return }
            state.engine.stop()
            try unit.setDeviceID(device.deviceID)
            outputDeviceID.store(device.deviceID, ordering: .relaxed)
            Self.reconnectOutput(state.engine)
            if state.wantsRunning {
                state.engine.prepare()
                try state.engine.start()
            }
        }
        Self.outputLogger.info("Salida de audio cambiada a «\(device.name, privacy: .public)»")
    }
}
