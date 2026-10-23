import Core
import CoreMocks
import Foundation
import Testing

private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
    let data = try ProjectEncoder.makeJSONEncoder().encode(value)
    return try JSONDecoder().decode(T.self, from: data)
}

private let ref = MediaReference(path: "/tmp/media/a.mov", bookmark: Data([0, 1, 2, 255]))

@Suite("T10 · JSON ida y vuelta")
struct ModelCodingTests {
    static let visuals: [AudioVisual] = [.black, .lastImage, .card(ref)]
    static let contents: [InputContent] = [
        .video(ref), .audio(ref, visual: .black), .audio(ref, visual: .lastImage), .audio(ref, visual: .card(ref)),
        .image(ref), .color(RGBAColor(red: 0.25, green: 0.5, blue: 0.75, alpha: 0.5)), .playlist(fullPlaylist)
    ]
    static let sources: [ItemSource] = [.video(ref), .audio(ref), .image(ref), .color(.black)]
    static let transitions: [ItemTransition] = [.cut, .fade(seconds: 0.5)]

    static let fullPlaylist = Playlist(
        items: sources.map { PlaylistItem(source: $0, duration: 4, inPoint: 1, outPoint: 3, stopAfter: true, enabled: false) },
        mode: .stopAfterEach, loop: true, holdBehavior: .nextFirstFrame,
        itemTransition: .fade(seconds: 1.5), audioItemVisual: .card(ref)
    )

    @Test(arguments: visuals) func audioVisual(_ value: AudioVisual) throws {
        #expect(try roundTrip(value) == value)
    }

    @Test(arguments: contents) func inputContent(_ value: InputContent) throws {
        #expect(try roundTrip(value) == value)
        let input = InputDescriptor(name: "x", content: value, loop: true, inPoint: 1, outPoint: 2,
                                    fit: .fill, volume: 1.5, muted: true, audioFollowsProgram: false)
        #expect(try roundTrip(input) == input)
    }

    @Test(arguments: sources) func itemSource(_ value: ItemSource) throws {
        #expect(try roundTrip(value) == value)
        let item = PlaylistItem(source: value, duration: nil, stopAfter: false)
        #expect(try roundTrip(item) == item)
    }

    @Test(arguments: transitions) func itemTransition(_ value: ItemTransition) throws {
        #expect(try roundTrip(value) == value)
    }

    @Test(arguments: HoldBehavior.allCases) func holdBehavior(_ value: HoldBehavior) throws {
        var playlist = Playlist(holdBehavior: value)
        playlist.items = [PlaylistItem(source: .color(.clear), duration: 1)]
        #expect(try roundTrip(playlist) == playlist)
    }

    @Test(arguments: PlaybackMode.allCases) func playbackMode(_ value: PlaybackMode) throws {
        #expect(try roundTrip(Playlist(mode: value)) == Playlist(mode: value))
    }

    @Test(arguments: FitMode.allCases) func fitMode(_ value: FitMode) throws {
        #expect(try roundTrip(value) == value)
    }

    @Test func fullProjectRoundTrips() throws {
        var project = SampleData.project
        project.inputs += Self.contents.map { InputDescriptor(name: "c", content: $0) }
        project.canvas = CanvasFormat(size: .uhd4K, frameRate: .fps59_94)
        project.defaultFadeDuration = 2.5
        project.masterVolume = 0.8
        let data = try ProjectEncoder().encode(project)
        #expect(try ProjectDecoder().decode(data) == project)
    }

    @Test func encodingIsStableAndSorted() throws {
        let project = SampleData.project
        let first = try ProjectEncoder().encode(project)
        let second = try ProjectEncoder().encode(try ProjectDecoder().decode(first))
        #expect(first == second)
        let text = try #require(String(bytes: first, encoding: .utf8))
        // Claves de primer nivel en orden alfabético, con sangría y sin escapar "/".
        let keys = ["\"canvas\"", "\"defaultFadeDuration\"", "\"inputs\"", "\"masterVolume\"",
                    "\"preview\"", "\"program\"", "\"schemaVersion\""]
        let positions = keys.compactMap { text.range(of: "\n  " + $0)?.lowerBound }
        #expect(positions.count == keys.count)
        #expect(positions == positions.sorted())
        #expect(text.contains("/tmp/clip.mov"))
        #expect(!text.contains("\\/"))
    }
}

@Suite("T10 · Versión de esquema")
struct ProjectDecoderTests {
    private func json(_ version: Int) throws -> Data {
        var project = SampleData.project
        project.schemaVersion = version
        return try ProjectEncoder().encode(project)
    }

    @Test func rejectsFutureVersion() throws {
        let data = try json(Project.currentSchemaVersion + 1)
        #expect(throws: ProjectCodingError.unsupportedFutureVersion(found: 2, supported: 1)) {
            try ProjectDecoder().decode(data)
        }
        #expect(ProjectCodingError.unsupportedFutureVersion(found: 2, supported: 1).description.contains("2"))
    }

    @Test func rejectsInvalidAndMissingVersion() throws {
        #expect(throws: ProjectCodingError.invalidSchemaVersion(0)) { try ProjectDecoder().decode(try json(0)) }
        #expect(throws: ProjectCodingError.missingSchemaVersion) { try ProjectDecoder().decode(Data("{}".utf8)) }
        #expect(throws: ProjectCodingError.missingSchemaVersion) { try ProjectDecoder().decode(Data("[1]".utf8)) }
        #expect(throws: ProjectCodingError.self) { try ProjectDecoder().decode(Data("not json".utf8)) }
        #expect(throws: ProjectCodingError.self) {
            try ProjectDecoder().decode(Data(#"{"schemaVersion":1,"inputs":3}"#.utf8))
        }
    }

    @Test func olderVersionWithoutMigrationFails() throws {
        let data = try json(1)
        #expect(throws: ProjectCodingError.migrationUnavailable(from: 1, to: 2)) {
            try ProjectDecoder(supportedVersion: 2).decode(data)
        }
    }

    @Test func migrationHookIsCalled() throws {
        let data = try json(1)
        let decoder = ProjectDecoder(supportedVersion: 2) { data, from in
            #expect(from == 1)
            var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            object["schemaVersion"] = 2
            return try JSONSerialization.data(withJSONObject: object)
        }
        let project = try decoder.decode(data)
        #expect(project.schemaVersion == 2)
        #expect(project.inputs == SampleData.project.inputs)
    }

    @Test func migrationErrorsAreWrapped() throws {
        let data = try json(1)
        struct Boom: Error {}
        #expect(throws: ProjectCodingError.self) {
            try ProjectDecoder(supportedVersion: 2) { _, _ in throw Boom() }.decode(data)
        }
        // Migración que no sube la versión.
        #expect(throws: ProjectCodingError.migrationFailed(from: 1, reason: "resultado en esquema 1")) {
            try ProjectDecoder(supportedVersion: 2) { data, _ in data }.decode(data)
        }
    }
}

@Suite("T10 · RGBAColor hex")
struct ColorHexTests {
    @Test func parsesRGBAndRGBA() throws {
        let rgb = try #require(RGBAColor(hex: "#FF8000"))
        #expect(rgb == RGBAColor(red: 1, green: 128.0 / 255, blue: 0, alpha: 1))
        let rgba = try #require(RGBAColor(hex: "00ff0080"))
        #expect(rgba.green == 1 && rgba.alpha == 128.0 / 255)
    }

    @Test(arguments: ["", "#", "#FFF", "#GG0000", "#12345", "#1234567", "#123456789", "# 123456"])
    func rejectsInvalid(_ text: String) {
        #expect(RGBAColor(hex: text) == nil)
    }

    @Test(arguments: ["#000000", "#FFFFFF", "#1A2B3C", "#1A2B3C4D", "#00000000"])
    func roundTrips(_ text: String) throws {
        #expect(try #require(RGBAColor(hex: text)).hexString == text)
    }

    @Test func formatsAndClamps() {
        #expect(RGBAColor.black.hexString == "#000000")
        #expect(RGBAColor.black.hexString(includingAlpha: true) == "#000000FF")
        #expect(RGBAColor.clear.hexString == "#00000000")
        #expect(RGBAColor(red: 2, green: -1, blue: .nan).hexString == "#FF0000")
    }
}

@Suite("T10 · Validación y búsqueda")
struct ValidationTests {
    @Test func sampleProjectIsValid() throws {
        try SampleData.project.validate()
        #expect(SampleData.project.normalized() == SampleData.project)
    }

    @Test func stillItemsNeedDuration() {
        let image = PlaylistItem(source: .image(ref))
        let color = PlaylistItem(source: .color(.black))
        let video = PlaylistItem(source: .video(ref))
        #expect(image.validationIssues() == [.missingStillDuration(image.id)])
        #expect(color.effectiveDuration == PlaylistItem.defaultStillDuration)
        #expect(video.effectiveDuration == nil && video.validationIssues().isEmpty)
        #expect(image.normalized().duration == PlaylistItem.defaultStillDuration)
        #expect(video.normalized().duration == nil)
    }

    @Test func invalidDurationsAndTrims() {
        let bad = PlaylistItem(source: .video(ref), duration: -1, inPoint: 5, outPoint: 2)
        #expect(bad.validationIssues() == [.invalidItemDuration(bad.id, -1),
                                           .invalidItemTrim(bad.id, inPoint: 5, outPoint: 2)])
        let fixed = bad.normalized()
        #expect(fixed.duration == nil && fixed.inPoint == nil && fixed.outPoint == nil)
        let badStill = PlaylistItem(source: .color(.black), duration: .infinity, inPoint: -1)
        #expect(badStill.normalized().duration == PlaylistItem.defaultStillDuration)
        #expect(PlaylistItem(source: .audio(ref), outPoint: 0).validationIssues().count == 1)
    }

    @Test(arguments: [(-0.1, true), (0, false), (2, false), (2.5, true), (Double.nan, true)])
    func itemFadeRange(seconds: Double, invalid: Bool) {
        let playlist = Playlist(itemTransition: .fade(seconds: seconds))
        #expect(playlist.validationIssues().contains { if case .itemFadeOutOfRange = $0 { true } else { false } } == invalid)
    }

    @Test func itemFadeNormalization() {
        #expect(ItemTransition.fade(seconds: 3).normalized() == .fade(seconds: 2))
        #expect(ItemTransition.fade(seconds: -1).normalized() == .cut)
        #expect(ItemTransition.fade(seconds: .nan).normalized() == .cut)
        #expect(ItemTransition.cut.normalized() == .cut)
    }

    @Test func projectLevelChecks() {
        let input = InputDescriptor(name: "v", content: .video(ref), inPoint: 3, outPoint: 1, volume: 3)
        let ghost = InputID()
        let project = Project(inputs: [input, input], preview: ghost, program: input.id,
                              defaultFadeDuration: 0.05, masterVolume: -1)
        let issues = project.validationIssues()
        #expect(issues.contains(.duplicateInputID(input.id)))
        #expect(issues.contains(.unknownBusInput(ghost)))
        #expect(issues.contains(.switcherFadeOutOfRange(0.05)))
        #expect(issues.contains(.volumeOutOfRange(nil, -1)))
        #expect(issues.contains(.volumeOutOfRange(input.id, 3)))
        #expect(issues.contains(.invalidInputTrim(input.id, inPoint: 3, outPoint: 1)))
        #expect(throws: ValidationError.self) { try project.validate() }
        #expect(!ValidationError(issues: issues).description.isEmpty)
        #expect(issues.allSatisfy { !$0.description.isEmpty })

        let fixed = project.normalized()
        #expect(fixed.preview == nil && fixed.program == input.id)
        #expect(fixed.defaultFadeDuration == 0.1 && fixed.masterVolume == 0)
        #expect(fixed.inputs[0].volume == 2 && fixed.inputs[0].inPoint == nil)
        var nanProject = Project(defaultFadeDuration: .nan, masterVolume: .nan)
        nanProject = nanProject.normalized()
        #expect(nanProject.defaultFadeDuration == 1 && nanProject.masterVolume == 1)
    }

    @Test func nestedPlaylistIsValidatedAndNormalized() {
        let still = PlaylistItem(source: .image(ref))
        let input = InputDescriptor(name: "p", content: .playlist(Playlist(items: [still], itemTransition: .fade(seconds: 9))))
        #expect(Project(inputs: [input]).validationIssues() == [.missingStillDuration(still.id), .itemFadeOutOfRange(9)])
        guard case .playlist(let fixed) = input.normalized().content else { Issue.record("no playlist"); return }
        #expect(fixed.items[0].duration == PlaylistItem.defaultStillDuration)
        #expect(fixed.itemTransition == .fade(seconds: 2))
    }

    @Test func lookupHelpers() throws {
        var project = SampleData.project
        let video = project.inputs[0], playlistInput = project.inputs[3]
        #expect(project.input(withID: video.id) == video)
        #expect(project.index(ofInput: playlistInput.id) == 3)
        #expect(project.contains(video.id) && !project.contains(InputID()))
        #expect(project.inputs(ofKind: .color).map(\.name) == ["Color"])
        #expect(project.input(named: "Imagen")?.kind == .image)
        #expect(project.programInput == video && project.previewInput?.name == "Imagen")
        let playlist = try #require(project.playlist(for: playlistInput.id))
        #expect(project.playlist(for: video.id) == nil)
        #expect(playlist.enabledIndices == [0, 1, 2])
        let item = playlist.items[2]
        #expect(playlist.index(ofItem: item.id) == 2 && playlist.item(withID: item.id) == item)
        let located = try #require(project.locateItem(item.id))
        #expect(located.input == playlistInput.id && located.index == 2)
        #expect(project.locateItem(ItemID()) == nil)

        #expect(project.updateInput(video.id) { $0.name = "Cámara" })
        #expect(!project.updateInput(InputID()) { $0.name = "x" })
        #expect(project.input(withID: video.id)?.name == "Cámara")
        #expect(project.removeInput(video.id)?.id == video.id)
        #expect(project.program == nil && project.removeInput(video.id) == nil)
        let previewID = try #require(project.preview)
        project.removeInput(previewID)
        #expect(project.preview == nil)
    }
}
