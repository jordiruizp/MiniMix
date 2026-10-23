import Core
import Foundation
import SwiftUI

/// Edición de la playlist (T51): todo pasa por `AppViewModel.updatePlaylist`, que guarda en el
/// proyecto y asigna `playlist` al secuenciador.
extension PlaylistViewModel {
    public func moveItems(in id: InputID, from offsets: IndexSet, to destination: Int) {
        app?.updatePlaylist(id) { $0.items.move(fromOffsets: offsets, toOffset: destination) }
    }

    public func removeItems(in id: InputID, at offsets: IndexSet) {
        app?.updatePlaylist(id) { $0.items.remove(atOffsets: offsets) }
    }

    /// Añade archivos al final (o en `index`); ignora extensiones desconocidas.
    @discardableResult
    public func addItems(in id: InputID, from urls: [URL], at index: Int? = nil) -> Int {
        let items = urls.compactMap(InputFactory.playlistItem(for:))
        guard !items.isEmpty else { return 0 }
        app?.updatePlaylist(id) { playlist in
            let position = min(index ?? playlist.items.count, playlist.items.count)
            playlist.items.insert(contentsOf: items, at: position)
        }
        return items.count
    }

    public func addColorItem(in id: InputID, color: RGBAColor = .black) {
        app?.updatePlaylist(id) {
            $0.items.append(PlaylistItem(source: .color(color), duration: PlaylistItem.defaultStillDuration))
        }
    }

    public func setEnabled(_ enabled: Bool, item: ItemID, in id: InputID) {
        updateItem(item, in: id) { $0.enabled = enabled }
    }

    public func setStopAfter(_ stop: Bool, item: ItemID, in id: InputID) {
        updateItem(item, in: id) { $0.stopAfter = stop }
    }

    /// Recortes In/Out en segundos (nil = sin recorte). Se ignoran si Out ≤ In.
    public func setTrim(inPoint: Double?, outPoint: Double?, item: ItemID, in id: InputID) {
        let start = inPoint.map { max(0, $0) }
        let end = outPoint.map { max(0, $0) }
        if let start, let end, end <= start { return }
        updateItem(item, in: id) {
            $0.inPoint = start
            $0.outPoint = end
        }
    }

    /// Duración de imagen/color (mín. 0,1 s); en vídeo/audio, nil = duración del archivo.
    public func setDuration(_ seconds: Double?, item: ItemID, in id: InputID) {
        updateItem(item, in: id) { item in
            if item.source.isStill {
                item.duration = max(0.1, seconds ?? PlaylistItem.defaultStillDuration)
            } else {
                item.duration = seconds.map { max(0.1, $0) }
            }
        }
    }

    public func setMode(_ mode: PlaybackMode, in id: InputID) { app?.updatePlaylist(id) { $0.mode = mode } }
    public func setLoop(_ loop: Bool, in id: InputID) { app?.updatePlaylist(id) { $0.loop = loop } }
    public func setHoldBehavior(_ hold: HoldBehavior, in id: InputID) {
        app?.updatePlaylist(id) { $0.holdBehavior = hold }
    }

    /// Transición entre items: corte o fundido de 0…2 s.
    public func setTransition(_ transition: ItemTransition, in id: InputID) {
        let clamped: ItemTransition = switch transition {
        case .cut: .cut
        case .fade(let seconds): .fade(seconds: min(max(seconds, 0), 2))
        }
        app?.updatePlaylist(id) { $0.itemTransition = clamped }
    }

    private func updateItem(_ item: ItemID, in id: InputID, _ body: (inout PlaylistItem) -> Void) {
        app?.updatePlaylist(id) { playlist in
            guard let index = playlist.items.firstIndex(where: { $0.id == item }) else { return }
            body(&playlist.items[index])
        }
    }
}
