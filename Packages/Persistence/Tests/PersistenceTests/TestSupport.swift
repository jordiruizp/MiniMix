import Core
import Foundation
import Persistence

/// Directorio temporal propio de un test; se borra al destruirse.
final class TempDir {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MiniMixPersistence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    func folder(_ name: String) throws -> URL {
        let folder = url.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Crea un archivo con contenido único en `folder`.
    @discardableResult
    func file(_ name: String, in folder: URL) throws -> URL {
        let file = folder.appendingPathComponent(name)
        try Data("MiniMix test \(name) \(UUID())".utf8).write(to: file)
        return file
    }
}

enum Fixtures {
    /// Proyecto que usa todos los sitios donde puede haber una `MediaReference`.
    static func project(media: URL, other: URL) -> Project {
        func ref(_ name: String, in folder: URL = media) -> MediaReference {
            MediaReference(path: folder.appendingPathComponent(name).path)
        }
        let playlist = Playlist(
            items: [
                PlaylistItem(source: .video(ref("clip.mov"))),
                PlaylistItem(source: .image(ref("logo.png")), duration: 5),
                PlaylistItem(source: .audio(ref("music.wav"))),
                PlaylistItem(source: .color(.black), duration: 3)
            ],
            loop: true, itemTransition: .fade(seconds: 0.5), audioItemVisual: .card(ref("card.png")))
        let video = InputDescriptor(name: "Vídeo", content: .video(ref("clip.mov")), loop: true, inPoint: 1.5)
        let audio = InputDescriptor(name: "Audio", content: .audio(ref("music.wav"), visual: .card(ref("card.png"))))
        let image = InputDescriptor(name: "Otra", content: .image(ref("still.png", in: other)), fit: .fill)
        let color = InputDescriptor(name: "Color", content: .color(RGBAColor(red: 0.1, green: 0.2, blue: 0.3)))
        let list = InputDescriptor(name: "Lista", content: .playlist(playlist))
        return Project(canvas: CanvasFormat(size: .hd720, frameRate: .fps29_97),
                       inputs: [video, audio, image, color, list],
                       preview: image.id, program: video.id, defaultFadeDuration: 0.8, masterVolume: 0.9)
    }

    static let mediaNames = ["clip.mov", "logo.png", "music.wav", "card.png"]
}

/// Proyecto con archivos reales en `media/` y `other/` de un directorio temporal.
struct MediaFixture {
    let dir: TempDir
    let media: URL
    let other: URL
    let project: Project

    init() throws {
        dir = try TempDir()
        media = try dir.folder("media")
        other = try dir.folder("other")
        for name in Fixtures.mediaNames { try dir.file(name, in: media) }
        try dir.file("still.png", in: other)
        project = Fixtures.project(media: media, other: other)
    }
}

/// Proyecto guardado cuyos archivos de `media/` se han «perdido» y reabierto con `store`.
struct LostFixture {
    let dir: TempDir
    let found: URL
    let project: Project
    let store: ProjectStore
}
