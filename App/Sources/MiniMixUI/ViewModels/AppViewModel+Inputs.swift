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

    /// Motivo por el que no se pueden añadir playlists (modo real sin `PlaylistInput`), o nil.
    public var playlistsUnavailableReason: String? {
        services.supportsPlaylists ? nil
            : "Las playlists aún no están disponibles con los módulos reales (falta PlaylistInput)."
    }

    public func addPlaylistInput() {
        if let reason = playlistsUnavailableReason {
            errorMessage = reason
            return
        }
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
        unsubscribeEvents(id)
        playlists.unregister(id)
        mixer.recordSolo(false, for: id)
        if selectedInputID == id { selectedInputID = nil }
        updateVisibility()
        publishBusState(sourcesChanged: true)
        track { await $0.services.inputs.remove(id) }
    }

    /// Baja en el switcher (`SwitcherStateMachine.removeInput`, contracts-v2).
    private func removeFromSwitcher(_ id: InputID) -> [Effect]? {
        switcher.removeInput(id, at: services.clock.now)
    }

    public func rename(_ id: InputID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        updateInput(id) { $0.name = trimmed }
    }

    /// Ajuste fit/fill/stretch (no hay `Command`: lo lee el compositor del descriptor en T80).
    public func setFit(_ fit: FitMode, for id: InputID) {
        guard descriptor(id)?.fit != fit else { return }
        updateInput(id) { $0.fit = fit }
        publishBusState()
        applyLiveEdit(id)
    }

    /// Bucle de la entrada (vídeo/audio): se guarda y se aplica en directo.
    func setLoop(_ loop: Bool, for id: InputID) {
        guard descriptor(id)?.loop != loop else { return }
        updateInput(id) { $0.loop = loop }
        applyLiveEdit(id)
    }

    /// Recortes In/Out de la entrada (s; nil = sin recorte). Se ignoran si Out ≤ In.
    public func setTrim(inPoint: Double?, outPoint: Double?, for id: InputID) {
        if let inPoint, let outPoint, outPoint <= inPoint { return }
        updateInput(id) {
            $0.inPoint = inPoint.map { max(0, $0) }
            $0.outPoint = outPoint.map { max(0, $0) }
        }
        applyLiveEdit(id)
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

    /// Punto único de propagación a Media de una entrada editada: `InputManaging.update` (v2)
    /// aplica loop, In/Out, fit y color en sitio, o sustituye la fuente si cambió el contenido. Tras
    /// actualizar se vuelve a suscribir a sus eventos y el render vuelve a resolver la fuente.
    /// Las ediciones de una misma entrada se encadenan: cada `update` espera al anterior, así
    /// Media nunca recibe un descriptor viejo después de uno nuevo.
    func applyLiveEdit(_ id: InputID) {
        let previous = liveEditChains[id]
        liveEditChains[id] = track { app in
            await previous?.value
            guard let current = app.descriptor(id) else { return }
            do {
                try await app.services.inputs.update(current)
                app.subscribeEvents(id)
                app.publishBusState(sourcesChanged: true)
            } catch {
                app.errorMessage = "No se pudo aplicar el cambio en «\(current.name)»: \(error.localizedDescription)"
            }
        }
    }

    // MARK: Gestor de entradas (InputManaging)

    func registerAllInputs() async {
        for input in project.inputs { await add(input, publish: false) }
        for input in project.inputs where input.kind.hasAudio {
            services.audio.setVolume(input.volume, for: input.id)
            services.audio.setMute(input.muted, for: input.id)
            services.audio.setAudioFollowsProgram(input.audioFollowsProgram, for: input.id)
        }
        services.audio.setMasterVolume(project.masterVolume)
        services.inputs.setVisible(Set([project.preview, project.program].compactMap { $0 }))
        publishBusState(sourcesChanged: true)
        // El Programa inicial (o el del proyecto abierto) también debe sonar.
        services.audio.transition(from: nil, to: project.program, progress: 1)
    }

    private func register(_ descriptor: InputDescriptor) {
        track { await $0.add(descriptor) }
    }

    func add(_ descriptor: InputDescriptor, publish: Bool = true) async {
        do {
            try await services.inputs.add(descriptor)
            subscribeEvents(descriptor.id)
            if publish { publishBusState(sourcesChanged: true) }
        } catch {
            errorMessage = "No se pudo cargar «\(descriptor.name)»: \(error.localizedDescription)"
        }
    }

    // MARK: Proyecto (ProjectStoring)

    /// Guarda con `ProjectStore.write` (si existe) y adopta el proyecto devuelto (con bookmarks)
    /// para no regenerarlos en cada guardado.
    public func saveProject(to url: URL) {
        do {
            if let write = services.writeProject {
                let stored = try write(project, url)
                adoptStoredReferences(from: stored)
            } else {
                try services.store.save(project, to: url)
            }
            projectURL = url
        } catch {
            errorMessage = "No se pudo guardar: \(error.localizedDescription)"
        }
    }

    /// Adopta solo las referencias de medios del proyecto guardado (bookmarks): el resto del estado
    /// (buses, volúmenes…) es el actual, aunque coincida con lo guardado.
    private func adoptStoredReferences(from stored: Project) {
        for input in stored.inputs { updateInput(input.id) { $0.content = input.content } }
    }

    public func openProject(from url: URL) async {
        do {
            let loaded = try services.store.load(from: url)
            await replaceProject(with: loaded)
            projectURL = url
            missingReferences = services.store.unresolvedReferences(in: project)
        } catch {
            errorMessage = "No se pudo abrir: \(error.localizedDescription)"
        }
    }

    /// Reenlaza los archivos perdidos buscándolos por nombre en `folder` (elegida con un panel de
    /// carpeta para que el sandbox dé acceso a todos). Devuelve cuántas rutas se reenlazaron.
    @discardableResult
    public func relinkMissing(in folder: URL) async -> Int {
        guard let relink = services.relinkProject else { return 0 }
        var working = project
        var pending = missingReferences
        var relinked: [String] = []
        var tried = Set<String>()
        while let reference = pending.first(where: { !tried.contains($0.path) }) {
            tried.insert(reference.path)
            let candidate = folder.appendingPathComponent(URL(fileURLWithPath: reference.path).lastPathComponent)
            guard FileManager.default.fileExists(atPath: candidate.path),
                  let outcome = try? relink(reference, candidate, working, folder) else { continue }
            working = outcome.project
            relinked += outcome.relinkedPaths
            pending = outcome.stillUnresolved
        }
        if !relinked.isEmpty {
            let url = projectURL
            await replaceProject(with: working)
            projectURL = url
        }
        missingReferences = services.store.unresolvedReferences(in: project)
        return relinked.count
    }

    func replaceProject(with newProject: Project) async {
        pendingTasks.forEach { $0.cancel() }
        pendingTasks.removeAll()
        liveEditChains = [:]
        for input in project.inputs {
            unsubscribeEvents(input.id)
            await services.inputs.remove(input.id)
        }
        if newProject.canvas != project.canvas { services.reconfigureCanvas?(newProject.canvas) }
        project = newProject
        switcher = services.makeSwitcher(newProject)
        resetTransitionState()
        playback = [:]
        playlists.reset(for: newProject)
        mixer.reset()
        selectedInputID = newProject.preview
        await registerAllInputs()
        // Después de sustituir las entradas (los lectores del proyecto anterior ya no existen).
        services.activateProject?(project)
    }
}
