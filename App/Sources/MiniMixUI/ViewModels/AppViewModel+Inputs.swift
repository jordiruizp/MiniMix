import Core
import Foundation
import Media

/// Alta/baja/edición de entradas, proyecto (guardar/abrir) y salida de Programa.
extension AppViewModel {
    // MARK: Entradas

    /// Añade entradas a partir de archivos (Finder); ignora extensiones desconocidas.
    @discardableResult
    public func addInputs(from urls: [URL]) -> Int {
        let descriptors = urls.compactMap(InputFactory.descriptor(for:))
        descriptors.forEach(addInput)
        let rejected = urls.filter { InputFactory.kind(for: $0) == nil }.map(\.lastPathComponent)
        if !rejected.isEmpty {
            errorMessage = "No se añadieron \(rejected.count) archivo(s) de un formato no admitido "
                + "(\(rejected.prefix(3).joined(separator: ", "))\(rejected.count > 3 ? "…" : "")). "
                + "Admite vídeo (mov, mp4…), audio (wav, mp3, m4a…) e imagen (png, jpg, heic…)."
        }
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
        // La baja espera a las ediciones en vuelo de esa entrada (si no, un `update` tardío
        // fallaría o resucitaría la fuente).
        let edits = liveEditChains.removeValue(forKey: id)
        track { app in
            await edits?.value
            await app.services.inputs.remove(id)
        }
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
            guard !Task.isCancelled, let current = app.descriptor(id) else { return }
            do {
                try await app.services.inputs.update(current)
                // La entrada pudo quitarse mientras Media aplicaba el cambio.
                guard app.descriptor(id) != nil else { return }
                app.subscribeEvents(id)
                app.publishBusState(sourcesChanged: true)
            } catch where !Self.isCancellation(error) {
                app.errorMessage = "No se pudo aplicar el cambio en «\(current.name)»: \(error.localizedDescription)"
            } catch {
                // Cancelada (baja de la entrada, proyecto nuevo): no es un error para el usuario.
            }
        }
    }

    nonisolated static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if case .cancelled? = error as? MediaError { return true }
        return false
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
    @discardableResult
    public func saveProject(to url: URL) -> Bool {
        do {
            if let write = services.writeProject {
                let stored = try write(project, url)
                adoptStoredReferences(from: stored)
            } else {
                try services.store.save(project, to: url)
            }
            projectURL = url
            markSaved()
            return true
        } catch {
            errorMessage = "No se pudo guardar: \(error.localizedDescription)"
            return false
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
            markSaved()
            missingReferences = services.store.unresolvedReferences(in: project)
        } catch {
            errorMessage = "No se pudo abrir: \(error.localizedDescription)"
        }
    }

    /// Reenlaza los archivos perdidos buscándolos por nombre en `folder` y sus subcarpetas (elegida
    /// con un panel de carpeta para que el sandbox dé acceso a todo su contenido). Sin cortar el
    /// directo: solo se actualizan las entradas reenlazadas. Devuelve cuántas rutas se reenlazaron.
    @discardableResult
    public func relinkMissing(in folder: URL) async -> Int {
        guard let relink = services.relinkProject else { return 0 }
        var working = project
        var pending = missingReferences
        var relinked: [String] = []
        var tried = Set<String>()
        while let reference = pending.first(where: { !tried.contains($0.path) }) {
            tried.insert(reference.path)
            let name = URL(fileURLWithPath: reference.path).lastPathComponent
            guard let candidate = Self.findFile(named: name, in: folder),
                  let outcome = try? relink(reference, candidate, working, folder) else { continue }
            working = outcome.project
            relinked += outcome.relinkedPaths
            pending = outcome.stillUnresolved
        }
        if !relinked.isEmpty {
            adoptRelinked(working)
            services.activateProject?(project)
        }
        missingReferences = services.store.unresolvedReferences(in: project)
        return relinked.count
    }

    /// Primer archivo llamado `name` en `folder` o, si no está, en sus subcarpetas.
    nonisolated static func findFile(named name: String, in folder: URL) -> URL? {
        let fm = FileManager.default
        let direct = folder.appendingPathComponent(name)
        if fm.fileExists(atPath: direct.path) { return direct }
        guard let walker = fm.enumerator(at: folder, includingPropertiesForKeys: nil,
                                         options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return nil }
        for case let url as URL in walker where url.lastPathComponent == name { return url }
        return nil
    }

    /// Adopta las referencias reenlazadas entrada a entrada (sin `replaceProject`): conserva las
    /// duraciones conocidas en la ruta nueva y aplica el cambio en directo (o da de alta la entrada
    /// si no llegó a cargarse por faltar el archivo).
    private func adoptRelinked(_ relinked: Project) {
        for input in relinked.inputs {
            guard let old = descriptor(input.id), old.content != input.content else { continue }
            for (before, after) in zip(Self.references(in: old.content), Self.references(in: input.content))
            where before.path != after.path {
                if let seconds = mediaDurations[before.path] { mediaDurations[after.path] = seconds }
            }
            updateInput(input.id) { $0.content = input.content }
            if let playlist = input.content.playlist { playlists.sync(input.id, playlist: playlist) }
            if services.inputs.frameSource(for: input.id) == nil {
                if let current = descriptor(input.id) { register(current) }
            } else {
                applyLiveEdit(input.id)
            }
        }
    }

    /// Referencias de medios de un contenido, en orden estable (playlist: por item).
    static func references(in content: InputContent) -> [MediaReference] {
        if let playlist = content.playlist { return playlist.items.compactMap(\.source.mediaReference) }
        return content.mediaReference.map { [$0] } ?? []
    }

    func replaceProject(with newProject: Project) async {
        pendingTasks.values.forEach { $0.cancel() }
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
