import Core

/// T80: entrega al render el estado de buses que necesita para componer.
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
