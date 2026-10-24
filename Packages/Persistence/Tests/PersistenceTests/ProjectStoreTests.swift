import Core
import Foundation
import Testing
@testable import Persistence

@Suite("ProjectStore: guardar y abrir")
struct ProjectStoreTests {
    private func makeFixture() throws -> MediaFixture { try MediaFixture() }

    @Test(arguments: [BookmarkMode.securityScoped, .plain])
    func reopensIdenticalAfterRestart(mode: BookmarkMode) throws {
        let fixture = try makeFixture()
        let file = fixture.dir.url.appendingPathComponent("show.minimix")

        let stored = try ProjectStore(bookmarkMode: mode).write(fixture.project, to: file)
        #expect(stored.mediaReferences.allSatisfy { $0.bookmark != nil })
        #expect(stored.mediaReferences.map(\.path) == fixture.project.mediaReferences.map(\.path))

        // «Reinicio»: un store nuevo, sin estado compartido.
        let reopenedStore = ProjectStore(bookmarkMode: mode)
        let reopened = try reopenedStore.load(from: file)
        #expect(reopened == stored)
        #expect(reopenedStore.unresolvedReferences(in: reopened).isEmpty)

        // Guardar lo reabierto produce los mismos bytes (JSON estable, bookmarks no regenerados).
        let again = fixture.dir.url.appendingPathComponent("again.minimix")
        try reopenedStore.save(reopened, to: again)
        #expect(try Data(contentsOf: again) == Data(contentsOf: file))
        reopenedStore.stopAccessingAll()
    }

    @Test func projectWithoutMediaRoundTripsExactly() throws {
        let dir = try TempDir()
        let project = Project(inputs: [InputDescriptor(name: "Rojo", content: .color(RGBAColor(red: 1, green: 0, blue: 0)))])
        let file = dir.url.appendingPathComponent("p.minimix")
        try ProjectStore().save(project, to: file)
        #expect(try ProjectStore().load(from: file) == project)
    }

    @Test func atomicSaveReplacesFileWithoutLeftovers() throws {
        let fixture = try makeFixture()
        let file = fixture.dir.url.appendingPathComponent("show.minimix")
        let store = ProjectStore()
        try store.save(fixture.project, to: file)
        var changed = fixture.project
        changed.masterVolume = 0.25
        try store.save(changed, to: file)
        #expect(try store.load(from: file).masterVolume == 0.25)
        let entries = try FileManager.default.contentsOfDirectory(atPath: fixture.dir.url.path)
        #expect(Set(entries) == ["media", "other", "show.minimix"])
    }

    @Test func missingFileKeepsReferenceWithoutBookmark() throws {
        let dir = try TempDir()
        let ghost = MediaReference(path: dir.url.appendingPathComponent("ghost.mov").path)
        let project = Project(inputs: [InputDescriptor(name: "G", content: .video(ghost))])
        let store = ProjectStore()
        let stored = try store.write(project, to: dir.url.appendingPathComponent("p.minimix"))
        #expect(stored == project)
        #expect(store.unresolvedReferences(in: stored) == [ghost])
    }

    @Test func bookmarksFollowMovedFolder() throws {
        let fixture = try makeFixture()
        let file = fixture.dir.url.appendingPathComponent("show.minimix")
        try ProjectStore().save(fixture.project, to: file)

        let moved = fixture.dir.url.appendingPathComponent("renamed", isDirectory: true)
        try FileManager.default.moveItem(at: fixture.media, to: moved)

        let store = ProjectStore()
        let reopened = try store.load(from: file)
        #expect(store.unresolvedReferences(in: reopened).isEmpty)
        let movedPaths = reopened.mediaReferences.map(\.path).filter { !$0.hasSuffix("still.png") }
        #expect(!movedPaths.isEmpty)
        #expect(movedPaths.allSatisfy { BookmarkCodec.samePath(ProjectStore.folder(of: $0), moved.path) })
        store.stopAccessingAll()
    }

    @Test func futureSchemaIsRejected() throws {
        let dir = try TempDir()
        let file = dir.url.appendingPathComponent("future.minimix")
        var project = Project()
        project.schemaVersion = Project.currentSchemaVersion + 1
        try ProjectEncoder().encode(project).write(to: file)
        #expect(throws: ProjectCodingError.unsupportedFutureVersion(found: Project.currentSchemaVersion + 1,
                                                                    supported: Project.currentSchemaVersion)) {
            try ProjectStore().load(from: file)
        }
    }

    @Test func mediaReferencesCoverEveryLocation() throws {
        let fixture = try makeFixture()
        // vídeo, audio + cartela, imagen, 3 items de playlist + cartela de playlist.
        #expect(fixture.project.mediaReferences.count == 8)
        let renamed = fixture.project.mapMediaReferences { MediaReference(path: $0.path + ".x") }
        #expect(renamed.mediaReferences.allSatisfy { $0.path.hasSuffix(".x") })
        #expect(renamed.inputs[3] == fixture.project.inputs[3])
    }
}
