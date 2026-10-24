import Core

/// T80: entrega al render el estado de buses que necesita para componer.
///
/// Se publica una sola vez por lote de efectos (al final de `apply(_:)`) y en los caminos que no
/// pasan por él (alta de entradas, baja, encaje). Publicar dentro de `handle(_:)` expondría
/// estados intermedios (p. ej. `transition == nil` con el Programa antiguo entre
/// `transitionCompleted` y `busesChanged`), que el render podría componer como un fotograma.
extension AppViewModel {
    var busState: BusState {
        var state = BusState(preview: project.preview, program: project.program)
        if case let .running(kind, progress) = switcher.transition {
            state.transition = BusState.Transition(
                from: transitionInputs?.from ?? project.program,
                to: transitionInputs?.to ?? project.preview,
                kind: kind, progress: progress)
        }
        for input in project.inputs { state.fits[input.id] = input.fit }
        return state
    }

    func publishBusState() {
        services.busStateSink?(busState)
    }
}
