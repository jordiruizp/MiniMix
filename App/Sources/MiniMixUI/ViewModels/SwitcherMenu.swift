import Core
import Foundation

/// Entrada del menú Switcher con su tecla visible (T91). Las teclas sin modificador no se
/// registran como equivalentes del menú (robarían las pulsaciones a los campos de texto): las
/// gestiona `KeyboardShortcutMonitor` y el menú las muestra en el título.
public struct SwitcherMenuItem: Identifiable, Hashable, Sendable {
    public var id: String { key + title }
    public var title: String
    /// Tecla tal como se muestra («Espacio», «←», «3»…).
    public var key: String
    public var action: ShortcutAction
    public var isEnabled: Bool

    public var menuTitle: String { "\(title)  (\(key))" }

    public var selectsInput: Bool {
        if case .selectInput = action { return true }
        return false
    }
}

extension AppViewModel {
    /// Comandos del menú Switcher, en el orden de la sección 7 del plan.
    public var switcherMenuItems: [SwitcherMenuItem] {
        func item(_ title: String, _ key: String, _ action: ShortcutAction) -> SwitcherMenuItem {
            SwitcherMenuItem(title: title, key: key, action: action, isEnabled: !commands(for: action).isEmpty)
        }
        var items = project.inputs.prefix(9).enumerated().map { index, input in
            item("Entrada \(index + 1) a Preview: \(input.name)", "\(index + 1)", .selectInput(index + 1))
        }
        items += [
            item("Cut", "Espacio", .cut),
            item("Fundido de \(Formatting.seconds(fadeDuration))", "Intro", .fade),
            item("Reproducir/pausar Preview", "P", .togglePreviewPlayback),
            item("Playlist en Programa: item anterior", "←", .programPlaylistPrevious),
            item("Playlist en Programa: item siguiente", "→", .programPlaylistNext)
        ]
        return items
    }
}
