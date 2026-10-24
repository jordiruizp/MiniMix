import Core
import Foundation
import Testing
@testable import Persistence

@Suite("ProjectStore: reenlace, resolutor y accesos")
struct RelinkAndAccessTests {
    /// Guarda el proyecto, «pierde» `media/` (copia a `found/` con inodos nuevos y borra los originales,
    /// así ni el bookmark ni la ruta lo encuentran) y devuelve el proyecto reabierto.
    private func lostProject() throws -> LostFixture {
        let fixture = try MediaFixture()
        let dir = fixture.dir
        let media = fixture.media
        let file = dir.url.appendingPathComponent("show.minimix")
        try ProjectStore().save(fixture.project, to: file)

        let found = try dir.folder("found")
        for name in Fixtures.mediaNames {
            try FileManager.default.copyItem(at: media.appendingPathComponent(name),
                                             to: found.appendingPathComponent(name))
        }
        try FileManager.default.removeItem(at: media)
        let store = ProjectStore()
        return LostFixture(dir: dir, found: found, project: try store.load(from: file), store: store)
    }

    @Test func relinkingOneResolvesSiblingsFromSameFolder() throws {
        let lost = try lostProject()
        let unresolved = lost.store.unresolvedReferences(in: lost.project)
        #expect(Set(unresolved.map { ($0.path as NSString).lastPathComponent }) == Set(Fixtures.mediaNames))

        let clip = try #require(unresolved.first { $0.path.hasSuffix("clip.mov") })
        let result = try lost.store.relinkReporting(clip, to: lost.found.appendingPathComponent("clip.mov"),
                                                    in: lost.project)
        #expect(result.relinkedPaths.count == Fixtures.mediaNames.count)
        #expect(result.stillUnresolved.isEmpty)
        #expect(result.project.mediaReferences.allSatisfy { $0.bookmark != nil })
        // Lo que no era media (colores, ids, ajustes) no cambia.
        #expect(result.project.inputs.map(\.id) == lost.project.inputs.map(\.id))
        #expect(result.project.inputs[3] == lost.project.inputs[3])

        // El proyecto reenlazado se guarda y reabre idéntico.
        let file = lost.dir.url.appendingPathComponent("relinked.minimix")
        let stored = try lost.store.write(result.project, to: file)
        #expect(try ProjectStore().load(from: file) == stored)
    }

    @Test func siblingsMissingInNewFolderStayUnresolved() throws {
        let lost = try lostProject()
        try FileManager.default.removeItem(at: lost.found.appendingPathComponent("music.wav"))
        let clip = try #require(lost.store.unresolvedReferences(in: lost.project).first { $0.path.hasSuffix("clip.mov") })
        let relinked = try lost.store.relink(clip, to: lost.found.appendingPathComponent("clip.mov"), in: lost.project)
        let remaining = lost.store.unresolvedReferences(in: relinked)
        #expect(remaining.map { ($0.path as NSString).lastPathComponent } == ["music.wav"])
    }

    @Test func siblingsAreSearchedInExplicitFolder() throws {
        let lost = try lostProject()
        // La elegida en `found/`; las hermanas, en otra carpeta que la App pidió al usuario.
        let elsewhere = try lost.dir.folder("elsewhere")
        for name in Fixtures.mediaNames where name != "clip.mov" {
            try FileManager.default.moveItem(at: lost.found.appendingPathComponent(name),
                                             to: elsewhere.appendingPathComponent(name))
        }
        let clip = try #require(lost.store.unresolvedReferences(in: lost.project).first { $0.path.hasSuffix("clip.mov") })
        let target = lost.found.appendingPathComponent("clip.mov")

        let withoutFolder = try lost.store.relinkReporting(clip, to: target, in: lost.project)
        #expect(withoutFolder.relinkedPaths == [clip.path])
        #expect(withoutFolder.stillUnresolved.count == Fixtures.mediaNames.count - 1)

        let withFolder = try lost.store.relinkReporting(clip, to: target, in: lost.project, searchingIn: elsewhere)
        #expect(withFolder.relinkedPaths.count == Fixtures.mediaNames.count)
        #expect(withFolder.stillUnresolved.isEmpty)
        #expect(withFolder.bookmarkFailures.isEmpty)
    }

    @Test func fileMovedToTrashCountsAsLost() throws {
        let dir = try TempDir()
        let folder = try dir.folder("m")
        let file = try dir.file("a.mov", in: folder)
        let store = ProjectStore()
        let project = store.withFreshBookmarks(
            Project(inputs: [InputDescriptor(name: "a", content: .video(MediaReference(path: file.path)))]))
        #expect(store.unresolvedReferences(in: project).isEmpty)

        // Papelera simulada en el directorio temporal (no se toca la del usuario); el bookmark la sigue.
        let trash = try dir.folder(".Trashes")
        try FileManager.default.moveItem(at: file, to: trash.appendingPathComponent("a.mov"))
        #expect(store.unresolvedReferences(in: project).count == 1)
        #expect(throws: PersistenceError.self) { try store.resolveURL(for: project.mediaReferences[0]) }
    }

    @Test func relinkToMissingFileThrows() throws {
        let lost = try lostProject()
        let clip = try #require(lost.store.unresolvedReferences(in: lost.project).first)
        let bogus = lost.found.appendingPathComponent("nope.mov")
        #expect(throws: PersistenceError.relinkTargetMissing(path: bogus.path)) {
            try lost.store.relink(clip, to: bogus, in: lost.project)
        }
    }

    @Test func urlResolverResolvesBookmarksAndPaths() throws {
        let dir = try TempDir()
        let folder = try dir.folder("m")
        let file = try dir.file("a.mov", in: folder)
        let store = ProjectStore()
        let resolver = store.urlResolver

        // Solo ruta.
        let byPath = try resolver(MediaReference(path: file.path))
        #expect(BookmarkCodec.samePath(byPath.path, file.path))

        // Bookmark que sigue al archivo aunque la ruta guardada ya no exista.
        let input = InputDescriptor(name: "a", content: .video(MediaReference(path: file.path)))
        let stored = store.withFreshBookmarks(Project(inputs: [input]))
        let reference = try #require(stored.mediaReferences.first)
        let moved = folder.appendingPathComponent("b.mov")
        try FileManager.default.moveItem(at: file, to: moved)
        #expect(BookmarkCodec.samePath(try resolver(reference).path, moved.path))

        // Perdido del todo.
        try FileManager.default.removeItem(at: moved)
        #expect(throws: PersistenceError.unresolvedReference(path: reference.path)) { try resolver(reference) }
        store.stopAccessingAll()
        #expect(store.access.activeCount == 0)
    }

    @Test func loadKeepsPreviousAccessUntilActivate() throws {
        let dir = try TempDir()
        let folder = try dir.folder("m")
        let first = try dir.file("one.mov", in: folder)
        let second = try dir.file("two.mov", in: folder)
        let store = ProjectStore()
        func save(_ url: URL, as name: String) throws -> URL {
            let doc = dir.url.appendingPathComponent(name)
            let project = Project(inputs: [
                InputDescriptor(name: "x", content: .video(MediaReference(path: url.path))),
                InputDescriptor(name: "y", content: .image(MediaReference(path: url.path)))
            ])
            try store.save(project, to: doc)
            return doc
        }
        let docA = try save(first, as: "a.minimix")
        let docB = try save(second, as: "b.minimix")

        _ = try store.load(from: docA)
        _ = try store.load(from: docA)
        let afterA = store.access.activeCount
        // Fuera del sandbox el sistema puede no conceder acceso (0); nunca más de uno por archivo.
        #expect(afterA <= 1)

        // Abrir B no cierra el acceso de A (Media puede seguir leyéndolo; la App puede cancelar).
        let projectB = try store.load(from: docB)
        #expect(store.access.activeCount == 2 * afterA)
        if afterA == 1 { #expect(store.access.activePaths.contains { $0.hasSuffix("one.mov") }) }

        // Al activar B, solo quedan sus accesos.
        store.activate(projectB)
        #expect(store.access.activeCount == afterA)
        #expect(!store.access.activePaths.contains { $0.hasSuffix("one.mov") })
        store.activate(projectB)
        #expect(store.access.activeCount == afterA)

        store.stopAccessingAll()
        #expect(store.access.activeCount == 0)
    }

    @Test func accessRegistryIsBalanced() throws {
        let dir = try TempDir()
        let file = try dir.file("x.mov", in: dir.url)
        let access = SecurityScopedAccess()
        let first = access.begin(file)
        _ = access.begin(file)
        #expect(access.activeCount == (first ? 1 : 0))
        access.end(file)
        access.end(file)
        #expect(access.activeCount == 0)
    }
}
