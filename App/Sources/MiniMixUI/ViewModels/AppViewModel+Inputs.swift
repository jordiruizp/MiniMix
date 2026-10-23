import Core
import Foundation

/// Alta/baja/edición de entradas, proyecto (guardar/abrir) y salida de Programa.
extension AppViewModel {
    // MARK: Entradas

    /// Añade entradas a partir de archivos (Finder); ignora extensiones desconocidas.
    @discardableResult
    public func addInputs(from urls: [URL]) -> Int {
        let descriptors = urls.compactMap(InputFactory.descriptor(for:))
        descriptors.forEach(addInput)
        return descriptors.count
    }

    public func addInput(_ descriptor: InputDescriptor) {
        project.inputs.append(descriptor)
        if let playlist = descriptor.content.playlist { playlists.register(descriptor.id, playlist: playlist) }
        register(descriptor)
    }

    public func addColorInput() {
        addInput(InputFactory.colorInput(number: project.inputs.count + 1))
    }

    public func addPlaylistInput() {
        let descriptor = InputFactory.playlistInput(number: project.inputs.count + 1)
        addInput(descriptor)
        selectedInputID = descriptor.id
    }

    /// `true` si la entrada participa en la transición en curso (saliente o entrante).
    public func isInTransition(_ id: InputID) -> Bool {
        guard transitionProgress != nil else { return false }
        return id == transitionInputs?.from || id == transitionInputs?.to
            || id == project.preview || id == project.program
    }

    /// Quita una entrada: primero de los buses del switcher (`SwitcherState.removeInput`), luego
    /// del proyecto y del gestor de entradas. No se permite durante una transición que la use.
    public func removeInput(_ id: InputID) {
        guard descriptor(id) != nil else { return }
        guard !isInTransition(id) else {
            errorMessage = "No se puede quitar una entrada que está en una transición en curso."
            return
        }
        let effects = removeFromSwitcher(id)
        apply(effects ?? [])
        project.removeInput(id)
        if effects == nil {
            // Implementación sin `removeInput`: se reconstruye desde el proyecto ya sin la entrada
            // (es seguro porque la baja está prohibida durante una transición).
            switcher = services.makeSwitcher(project)
        }
        playback[id] = nil
        playlists.unregister(id)
        mixer.recordSolo(false, for: id)
        if selectedInputID == id { selectedInputID = nil }
        updateVisibility()
        track { await $0.services.inputs.remove(id) }
    }

    /// Baja en el switcher. `removeInput(_:at:)` no está en el protocolo del contrato (PC):
    /// devuelve nil si la implementación no es `SwitcherState`.
    private func removeFromSwitcher(_ id: InputID) -> [Effect]? {
        guard var concrete = switcher as? SwitcherState else { return nil }
        let effects = concrete.removeInput(id, at: services.clock.now)
        switcher = concrete
        return effects
    }

    public func rename(_ id: InputID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        updateInput(id) { $0.name = trimmed }
    }

    /// Ajuste fit/fill/stretch (no hay `Command`: lo lee el compositor del descriptor en T80).
    public func setFit(_ fit: FitMode, for id: InputID) {
        updateInput(id) { $0.fit = fit }
    }

    /// Cambia el color de una entrada de color y la vuelve a registrar en el gestor de entradas.
    public func setColor(_ color: RGBAColor, for id: InputID) {
        guard let input = descriptor(id), input.kind == .color, input.content != .color(color) else { return }
        updateInput(id) { $0.content = .color(color) }
        applyLiveEdit(id)
    }

    /// Modifica la playlist de una entrada y sincroniza su secuenciador.
    func updatePlaylist(_ id: InputID, _ body: (inout Playlist) -> Void) {
        guard var playlist = descriptor(id)?.content.playlist else { return }
        body(&playlist)
        updateInput(id) { $0.content = .playlist(playlist) }
        playlists.sync(id, playlist: playlist)
        applyLiveEdit(id)
    }

    /// Punto único de propagación a Media de una entrada editada (color, playlist, fit, recortes…).
    ///
    /// `InputManaging` (contracts-v1) no tiene `update(_:)`; la decisión está pendiente (PC3).
    /// Mientras tanto: el color se propaga dando de baja y de alta la entrada; el resto de ediciones
    /// solo quedan en el proyecto (el compositor/T80 lee `fit` del descriptor; la playlist sigue
    /// el secuenciador de la UI). Cuando exista `update`, sustituir este cuerpo por esa llamada.
    func applyLiveEdit(_ id: InputID) {
        guard let input = descriptor(id) else { return }
        switch input.kind {
        case .color:
            track { app in
                await app.services.inputs.remove(id)
                if let current = app.descriptor(id) { await app.add(current) }
            }
        case .video, .audio, .image, .playlist:
            break
        }
    }

    // MARK: Gestor de entradas (InputManaging)

    func registerAllInputs() async {
        for input in project.inputs { await add(input) }
        for input in project.inputs where input.kind.hasAudio {
            services.audio.setVolume(input.volume, for: input.id)
            services.audio.setMute(input.muted, for: input.id)
            services.audio.setAudioFollowsProgram(input.audioFollowsProgram, for: input.id)
        }
        services.audio.setMasterVolume(project.masterVolume)
        services.inputs.setVisible(Set([project.preview, project.program].compactMap { $0 }))
        // El Programa inicial (o el del proyecto abierto) también debe sonar.
        services.audio.transition(from: nil, to: project.program, progress: 1)
    }

    private func register(_ descriptor: InputDescriptor) {
        track { await $0.add(descriptor) }
    }

    func add(_ descriptor: InputDescriptor) async {
        do {
            try await services.inputs.add(descriptor)
        } catch {
            errorMessage = "No se pudo cargar «\(descriptor.name)»: \(error.localizedDescription)"
        }
    }

    // MARK: Proyecto (ProjectStoring)

    public func saveProject(to url: URL) {
        do {
            try services.store.save(project, to: url)
            projectURL = url
        } catch {
            errorMessage = "No se pudo guardar: \(error.localizedDescription)"
        }
    }

    public func openProject(from url: URL) async {
        do {
            let loaded = try services.store.load(from: url)
            await replaceProject(with: loaded)
            projectURL = url
            let missing = services.store.unresolvedReferences(in: loaded)
            if !missing.isEmpty { errorMessage = "Faltan \(missing.count) archivo(s) por reenlazar." }
        } catch {
            errorMessage = "No se pudo abrir: \(error.localizedDescription)"
        }
    }

    func replaceProject(with newProject: Project) async {
        pendingTasks.forEach { $0.cancel() }
        pendingTasks.removeAll()
        for input in project.inputs { await services.inputs.remove(input.id) }
        project = newProject
        switcher = services.makeSwitcher(newProject)
        resetTransitionState()
        playback = [:]
        playlists.reset(for: newProject)
        mixer.reset()
        selectedInputID = newProject.preview
        await registerAllInputs()
    }

    // MARK: Salida de Programa (OutputPresenting)

    /// Muestra u oculta la salida de Programa (en la primera pantalla externa si la hay).
    public func toggleProgramOutput() {
        let output = services.output
        if output.activeDisplay != nil {
            output.hide()
        } else if let display = output.displays.first(where: { !$0.isBuiltIn }) ?? output.displays.first {
            output.show(on: display.id)
        }
        programOutputDisplay = output.activeDisplay
    }

    public var outputDisplays: [DisplayInfo] { services.output.displays }
}
