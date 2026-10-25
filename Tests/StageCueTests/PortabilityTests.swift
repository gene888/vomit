import Foundation
import Testing
@testable import StageCue

@Suite(.serialized)
struct PortabilityTests {
    private let temporaryFiles = TemporaryFiles()
    func folder(_ name: String) throws -> URL {
        let url = temporaryFiles.directory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    @Test func portableExportMovesBetweenDifferentHomesWithOriginalsRemoved() async throws {
        let alice = try folder("Users/Alice/Productions/Séance")
        let bob = try folder("Users/Bob/Imported")
        let media = alice.appendingPathComponent("Thunder 音.wav")
        try Data("test fixture bytes".utf8).write(to: media)
        let cue = Cue(title: "Thunder", filePath: media.path, gainDB: -18, bus: 4, autoFadeIn: true)
        var project = SoundProject(title: "Séance")
        project.cues[0] = cue
        var duplicate = cue; duplicate.id = UUID(); project.cues[1] = duplicate
        let group = CueGroup(title: "Opening", actions: [GroupAction(cueID: cue.id)])
        project.groups = [group]
        project.sequences = [CueSequence(steps: [SequenceStep(target: .group, groupID: group.id)])]
        let exported = alice.appendingPathComponent("Portable")
        _ = try await MediaLibrary().exportPortable(project, to: exported)
        let moved = bob.appendingPathComponent("Show")
        try FileManager.default.copyItem(at: exported, to: moved)
        try FileManager.default.removeItem(at: alice)
        let loaded = try ProjectStore.load(from: moved.appendingPathComponent("Project.stagecue")).0
        expectEqual(loaded.media.assets.count, 1)
        expectEqual(loaded.cues[0]?.filePath, loaded.cues[1]?.filePath)
        expectTrue(loaded.cues[0]!.filePath.hasPrefix(bob.path))
        expectEqual(loaded.cues[0]?.gainDB, -18); expectEqual(loaded.cues[0]?.bus, 4)
        expectEqual(loaded.groups, project.groups); expectEqual(loaded.sequences, project.sequences)
        expectEqual(try Data(contentsOf: URL(fileURLWithPath: loaded.cues[0]!.filePath)), Data("test fixture bytes".utf8))
        expectTrue(FileManager.default.fileExists(atPath: moved.appendingPathComponent("MediaManifest.json").path))
        let json = try String(contentsOf: moved.appendingPathComponent("Project.stagecue"), encoding: .utf8)
        expectFalse(json.contains(alice.path))
    }
    @Test func ordinaryProjectCanReferenceOutsideMediaAndRelativeInsideMedia() throws {
        let root = try folder("Project"), external = try folder("External")
        let inside = root.appendingPathComponent("inside.wav"), outside = external.appendingPathComponent("outside.wav")
        try Data([1]).write(to: inside); try Data([2]).write(to: outside)
        var p = SoundProject(); p.cues[0] = Cue(filePath: inside.path); p.cues[1] = Cue(filePath: outside.path)
        let url = root.appendingPathComponent("Show.stagecue"); try ProjectStore.save(p, to: url)
        let stored = try JSONDecoder().decode(SoundProject.self, from: Data(contentsOf: url))
        expectEqual(stored.cues[0]?.filePath, "inside.wav"); expectEqual(stored.cues[1]?.filePath, outside.path)
        expectEqual(try ProjectStore.load(from: url).0, p)
    }
    @Test func traversalAndEscapingSymlinksAreRejected() throws {
        let root = try folder("Package"), outside = try folder("Outside")
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape"), withDestinationURL: outside)
        for path in ["../outside.wav", "/absolute.wav", "escape/secret.wav", "a/../../secret.wav"] {
            expectThrows(try MediaPaths.relativeURL(path, root: root))
        }
    }
    @Test func missingAndCopyFailureNeverPublishOrDamageOriginals() async throws {
        let root = try folder("Failure"), file = root.appendingPathComponent("same.wav")
        try Data([1,2,3]).write(to: file)
        var p = SoundProject(); p.cues[0] = Cue(filePath: file.path)
        let output = root.appendingPathComponent("Export")
        do { _ = try await MediaLibrary().exportPortable(p, to: output, beforeCopy: { _ in throw CocoaError(.fileWriteOutOfSpace) }); Issue.record("Copy failure was ignored") }
        catch { }
        expectFalse(FileManager.default.fileExists(atPath: output.path))
        expectEqual(try Data(contentsOf: file), Data([1,2,3]))
        expectFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".stagecue-export") })
        p.cues[0]?.filePath = root.appendingPathComponent("disconnected-drive.wav").path
        do { _ = try await MediaLibrary().exportPortable(p, to: output); Issue.record("Missing media accepted") } catch { }
        expectFalse(FileManager.default.fileExists(atPath: output.path))
    }
    @Test func cancellationAndExistingDestinationAreSafe() async throws {
        let root = try folder("Cancel"), output = root.appendingPathComponent("Portable")
        let task = Task { try Task.checkCancellation(); return try await MediaLibrary().exportPortable(SoundProject(), to: output) }
        task.cancel()
        do { _ = try await task.value; Issue.record("Cancellation ignored") } catch is CancellationError { }
        expectFalse(FileManager.default.fileExists(atPath: output.path))
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try Data([42]).write(to: output.appendingPathComponent("keep"))
        do { _ = try await MediaLibrary().exportPortable(SoundProject(), to: output); Issue.record("Overwrote destination") } catch { }
        expectEqual(try Data(contentsOf: output.appendingPathComponent("keep")), Data([42]))
    }
}
