import Core
import Foundation

/// Acción de teclado de la ventana principal (independiente de AppKit para poder testearla).
public enum ShortcutAction: Hashable, Sendable {
    /// Entrada N (1…9) a Preview.
    case selectInput(Int)
    case cut
    /// Fundido con la duración actual.
    case fade
    /// Playlist en Programa: item anterior / siguiente.
    case programPlaylistPrevious
    case programPlaylistNext
    /// Play/pause de la entrada en Preview.
    case togglePreviewPlayback
}

/// Tecla pulsada, reducida a lo que necesita el mapa de atajos.
public struct KeyInput: Hashable, Sendable {
    public enum Special: Hashable, Sendable { case space, enter, left, right }
    public var characters: String
    public var special: Special?
    /// ⌘, ⌃ u ⌥ pulsadas: entonces no es un atajo de la ventana (lo gestionan los menús).
    public var hasCommandModifiers: Bool

    public init(characters: String = "", special: Special? = nil, hasCommandModifiers: Bool = false) {
        self.characters = characters
        self.special = special
        self.hasCommandModifiers = hasCommandModifiers
    }
}

public enum ShortcutMap {
    public static func action(for key: KeyInput) -> ShortcutAction? {
        guard !key.hasCommandModifiers else { return nil }
        switch key.special {
        case .space: return .cut
        case .enter: return .fade
        case .left: return .programPlaylistPrevious
        case .right: return .programPlaylistNext
        case nil: break
        }
        let chars = key.characters.lowercased()
        if chars == "p" { return .togglePreviewPlayback }
        if let digit = Int(chars), (1...9).contains(digit) { return .selectInput(digit) }
        return nil
    }
}

extension AppViewModel {
    /// Comandos que produce un atajo con el estado actual (puro: no los envía).
    public func commands(for action: ShortcutAction) -> [Command] {
        switch action {
        case .selectInput(let number):
            guard project.inputs.indices.contains(number - 1) else { return [] }
            return [.selectPreview(project.inputs[number - 1].id)]
        case .cut:
            return [.cut]
        case .fade:
            return [.fade(duration: fadeDuration)]
        case .programPlaylistPrevious:
            guard let program = project.program, descriptor(program)?.kind == .playlist else { return [] }
            return [.playlistPrevious(program)]
        case .programPlaylistNext:
            guard let program = project.program, descriptor(program)?.kind == .playlist else { return [] }
            return [.playlistNext(program)]
        case .togglePreviewPlayback:
            guard let preview = project.preview, descriptor(preview) != nil else { return [] }
            return [isPlaying(preview) ? .pause(preview) : .play(preview)]
        }
    }

    /// Ejecuta un atajo: envía sus comandos y sincroniza la selección.
    public func perform(_ action: ShortcutAction) {
        for command in commands(for: action) {
            if case .selectPreview(let id) = command { selectedInputID = id }
            send(command)
        }
    }
}
