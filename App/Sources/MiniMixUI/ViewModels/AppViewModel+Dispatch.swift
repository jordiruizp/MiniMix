import Core
import Foundation

/// Despacho de los comandos que el switcher reenvía (`Effect.forward`) a fuentes, audio y playlists.
extension AppViewModel {
    func dispatch(_ command: Command) {
        if dispatchTransport(command) { return }
        if dispatchAudio(command) { return }
        dispatchPlaylist(command)
    }

    private func dispatchTransport(_ command: Command) -> Bool {
        switch command {
        case .play(let id):
            play(id)
        case .pause(let id):
            services.inputs.frameSource(for: id)?.pause()
            playback[id, default: PlaybackInfo()].pause(at: now)
            if descriptor(id)?.kind == .playlist { playlists.pauseClock(for: id) }
        case .restart(let id):
            let source = services.inputs.frameSource(for: id)
            Task { await source?.seek(to: 0) }
            if descriptor(id)?.kind == .playlist {
                playlists.handle(.restartItem, for: id)
            } else {
                playback[id, default: PlaybackInfo()].reset(at: now, playing: isPlaying(id))
            }
        case let .seek(id, seconds):
            let source = services.inputs.frameSource(for: id)
            Task { await source?.seek(to: seconds) }
            // `seconds` es tiempo del archivo; el reloj de la UI cuenta desde el punto In.
            var info = playback[id, default: PlaybackInfo()]
            info.reset(at: now, playing: info.state == .playing)
            info.accumulated = max(0, seconds - (descriptor(id)?.inPoint ?? 0))
            playback[id] = info
        case let .setLoop(id, loop):
            updateInput(id) { $0.loop = loop }
        default:
            return false
        }
        return true
    }

    private func play(_ id: InputID) {
        guard let input = descriptor(id) else { return }
        let wasPaused = playback[id]?.state == .paused
        if playback[id]?.state == .ended { playback[id]?.reset(at: now, playing: false) }
        services.inputs.frameSource(for: id)?.play()
        playback[id, default: PlaybackInfo()].play(at: now)
        if input.kind == .playlist {
            // Reanudar solo si el secuenciador sigue en un item; una pausa explícita en held
            // (o tras terminar) debe pasar `.play` al secuenciador para arrancar el item en cola.
            if wasPaused, case .playing = playlists.state(for: id) {
                playlists.resumeClock(for: id)
            } else {
                playlists.handle(.play, for: id)
            }
        }
    }

    private func dispatchAudio(_ command: Command) -> Bool {
        switch command {
        case let .setVolume(id, volume):
            let clamped = Self.clampVolume(volume)
            services.audio.setVolume(clamped, for: id)
            updateInput(id) { $0.volume = clamped }
        case let .setMute(id, muted):
            services.audio.setMute(muted, for: id)
            updateInput(id) { $0.muted = muted }
        case let .setSolo(id, solo):
            services.audio.setSolo(solo, for: id)
            mixer.recordSolo(solo, for: id)
        case let .setAudioFollowsProgram(id, follows):
            services.audio.setAudioFollowsProgram(follows, for: id)
            updateInput(id) { $0.audioFollowsProgram = follows }
        case .setMasterVolume(let volume):
            let clamped = Self.clampVolume(volume)
            services.audio.setMasterVolume(clamped)
            project.masterVolume = clamped
        default:
            return false
        }
        return true
    }

    private func dispatchPlaylist(_ command: Command) {
        switch command {
        case .playlistNext(let id):
            playlists.handle(.next, for: id)
        case .playlistPrevious(let id):
            playlists.handle(.previous, for: id)
        case let .playlistJump(id, item):
            playlists.handle(.jump(item), for: id)
        default:
            // selectPreview/cut/fade/tbar los consume el switcher; nunca llegan aquí.
            break
        }
    }

    /// Modifica una entrada del proyecto en sitio.
    func updateInput(_ id: InputID, _ body: (inout InputDescriptor) -> Void) {
        project.updateInput(id, body)
    }

    nonisolated static func clampVolume(_ volume: Float) -> Float {
        guard volume.isFinite else { return 1 }
        return min(max(volume, ModelLimits.volume.lowerBound), ModelLimits.volume.upperBound)
    }

    /// Pone a reproducir una entrada sin pasar por el secuenciador (p. ej. una playlist que estaba
    /// en espera y salta a otro item con siguiente/anterior/saltar).
    func startPlayback(_ id: InputID) {
        services.inputs.frameSource(for: id)?.play()
        playback[id, default: PlaybackInfo()].play(at: now)
    }
}
