import Foundation
import Testing
@testable import StageCue

@Suite(.serialized)
struct PersistenceTests {
    private let temporaryFiles = TemporaryFiles()
    private func temporary() throws -> URL {
        let dir = temporaryFiles.directory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    @Test func testProjectRoundTripPreservesEverySettingAndMediaReference() throws {
        let cue = Cue(title: "Ambience", filePath: "/missing/original media.wav", gainDB: -13.2, bus: 5, mode: .toggle,
                      loop: true, autoFadeIn: true, fadeInSeconds: 1.5, autoFadeOut: true, fadeOutSeconds: 7,
                      curve: .equalPower, tint: "purple")
        var project = SoundProject(title: "Local Show", busDB: [-1, -2, -3, -4, -5, -6], masterDB: -2, manualFadeSeconds: 1)
        project.cues[31] = cue
        project.padKeys[31] = "z"
        let url = try temporary().appendingPathComponent("nested/show.json")
        try ProjectStore.save(project, to: url)
        let (read, notes) = try ProjectStore.load(from: url)
        expectEqual(read, project)
        expectTrue(notes.isEmpty)
        expectFalse(FileManager.default.fileExists(atPath: cue.filePath))
    }
    @Test func testLegacyAndPartialProjectDefaults() throws {
        let data = Data("{\"title\":\"Legacy\",\"cues\":[{\"title\":\"Clip\",\"gainDB\":-9}]}".utf8)
        var project = try JSONDecoder().decode(SoundProject.self, from: data)
        project.normalize()
        expectEqual(project.title, "Legacy")
        expectEqual(project.cues[0]?.gainDB, -9)
        expectEqual(project.cues[0]?.fadeInSeconds, 2)
        expectEqual(project.cues.count, 32)
        expectEqual(project.busDB.count, 6)
    }
    @Test func testCorruptAndFutureProjectsRejectedWithoutRewriting() throws {
        let url = try temporary().appendingPathComponent("show.json")
        for text in ["not JSON", "{\"schemaVersion\":999}", "{\"cues\":[{\"mode\":\"FutureMode\"}]}", "{\"busDB\":\"wrong type\"}"] {
            let bytes = Data(text.utf8)
            try bytes.write(to: url)
            expectThrows(try ProjectStore.load(from: url))
            expectEqual(try Data(contentsOf: url), bytes)
        }
    }
    @Test func testOversizedProjectRejected() throws {
        let url = try temporary().appendingPathComponent("huge.json")
        try Data(repeating: 32, count: ProjectStore.maximumBytes + 1).write(to: url)
        expectThrows(try ProjectStore.load(from: url))
    }
    @Test func testWriteFailurePreservesExistingFile() throws {
        let dir = try temporary()
        let url = dir.appendingPathComponent("show.json")
        let original = SoundProject(title: "Original")
        try ProjectStore.save(original, to: url)
        let tooLarge = SoundProject(title: String(repeating: "x", count: ProjectStore.maximumBytes + 1))
        expectThrows(try ProjectStore.save(tooLarge, to: url))
        expectEqual(try ProjectStore.load(from: url).0, original)
        let blockingFile = dir.appendingPathComponent("not-a-directory")
        try Data().write(to: blockingFile)
        expectThrows(try ProjectStore.save(original, to: blockingFile.appendingPathComponent("show.json")))
    }
    @Test func testAutosaveWriterRejectsStaleRevision() async throws {
        let url = try temporary().appendingPathComponent("show.json")
        let writer = ProjectWriter()
        try await writer.save(SoundProject(title: "New"), to: url, revision: 2)
        try await writer.save(SoundProject(title: "Old"), to: url, revision: 1)
        expectEqual(try ProjectStore.load(from: url).0.title, "New")
    }
}
