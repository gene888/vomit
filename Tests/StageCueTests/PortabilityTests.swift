import Foundation
import Testing
import AVFoundation
@testable import StageCue

@Suite(.serialized)
struct PortabilityTests {
    private let temporaryFiles = TemporaryFiles()
    func folder(_ name: String) throws -> URL {
        let url = temporaryFiles.directory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.resolvingSymlinksInPath()
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
    @Test func batchRelinkWithoutSpotlightRejectsWrongContentAndPersists() async throws {
        let original = try folder("Alice/Original"), replacement = try folder("Bob/Replacement")
        let a = original.appendingPathComponent("A 音.wav"), b = original.appendingPathComponent("B.wav")
        try Data([1,2,3]).write(to: a); try Data([4,5,6]).write(to: b)
        var p = SoundProject(); p.cues[0] = Cue(filePath: a.path); p.cues[1] = Cue(filePath: b.path)
        p = try await MediaLibrary().catalog(p, root: original)
        let nested = replacement.appendingPathComponent("Nested"); try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: a, to: nested.appendingPathComponent(a.lastPathComponent))
        try Data([6,5,4]).write(to: nested.appendingPathComponent(b.lastPathComponent))
        try FileManager.default.removeItem(at: original)
        let result = try await MediaResolver().resolve(p, root: nil, folders: [replacement])
        expectEqual(result.report.count(.relinked), 1); expectEqual(result.report.count(.ambiguous), 1)
        expectTrue(MediaPaths.relative(URL(fileURLWithPath: result.project.cues[0]!.filePath), root: replacement) != nil)
        expectEqual(result.project.cues[1]?.filePath, b.path)
        let save = replacement.appendingPathComponent("Relinked.stagecue")
        try ProjectStore.save(result.project, to: save)
        let read = try ProjectStore.load(from: save).0
        expectEqual(read.cues[0]?.id, p.cues[0]?.id)
        expectTrue(MediaPaths.readable(URL(fileURLWithPath: read.cues[0]!.filePath)))
    }
    @Test func duplicateNamesChooseContentIdentityAndLegacyNamesNeedReview() async throws {
        let source = try folder("Names/Source"), good = try folder("Names/Replacement/Good"), bad = try folder("Names/Replacement/Bad")
        let a = source.appendingPathComponent("Thunder.wav")
        try Data([1,2,3,4]).write(to: a)
        var p = SoundProject(); p.cues[0] = Cue(filePath: a.path)
        p = try await MediaLibrary().catalog(p, root: nil)
        try Data([1,2,3,4]).write(to: good.appendingPathComponent("Thunder.wav"))
        try Data([4,3,2,1]).write(to: bad.appendingPathComponent("Thunder.wav"))
        try FileManager.default.removeItem(at: source)
        let result = try await MediaResolver().resolve(p, root: nil, folders: [bad,good])
        expectEqual(result.report.count(.relinked), 1)
        expectTrue(MediaPaths.relative(URL(fileURLWithPath: result.project.cues[0]!.filePath), root: good) != nil)
        p.media = MediaManifest()
        let legacy = try await MediaResolver().resolve(p, root: nil, folders: [good,bad])
        expectEqual(legacy.report.count(.ambiguous), 1); expectEqual(legacy.report.items.first?.candidates.count, 2)
        expectEqual(legacy.project.cues[0]?.filePath, a.path)
    }
    @Test func validRelativePathWinsOverOriginalMacAndChangedFileIsFlagged() async throws {
        let source = try folder("Priority/Alice"), moved = try folder("Priority/Bob")
        let a = source.appendingPathComponent("music.wav"), b = moved.appendingPathComponent("music.wav")
        try Data([1,2]).write(to: a); try Data([1,2]).write(to: b)
        var p = SoundProject(); p.cues[0] = Cue(filePath: a.path)
        p = try await MediaLibrary().catalog(p, root: source)
        let r = try await MediaResolver().resolve(p, root: moved)
        expectEqual(r.project.cues[0]?.filePath, b.path)
        try Data([2,1]).write(to: a); try Data([2,1]).write(to: b)
        let changed = try await MediaResolver().resolve(p, root: moved)
        expectEqual(changed.report.count(.ambiguous), 1)
        expectEqual(changed.report.count(.available), 0)
    }
    @Test @MainActor func realAudioVideoAndBackgroundPlayAfterSourceRootIsRemoved() async throws {
        let alice = try folder("Playback/Users/Alice"), bob = try folder("Playback/Users/Bob")
        let audioFixtures = AudioTests(), visualFixtures = VideoTests()
        let wav = try audioFixtures.fixture(), movie = try await visualFixtures.movie("Portable", mp4: true)
        let image = try visualFixtures.image("Portable", color: .red)
        for url in [wav,movie,image] { try FileManager.default.copyItem(at: url, to: alice.appendingPathComponent(url.lastPathComponent)) }
        var p = SoundProject(); p.cues[0] = Cue(filePath: alice.appendingPathComponent(wav.lastPathComponent).path, loop: true)
        p.cues[1] = Cue(filePath: alice.appendingPathComponent(movie.lastPathComponent).path, kind: .video, transition: .cut)
        p.cues[2] = Cue(filePath: alice.appendingPathComponent(image.lastPathComponent).path, kind: .image, transition: .cut)
        p.backgroundPath = p.cues[2]!.filePath
        _ = try await MediaLibrary().exportPortable(p, to: alice.appendingPathComponent("Export"))
        try FileManager.default.copyItem(at: alice.appendingPathComponent("Export"), to: bob.appendingPathComponent("Imported"))
        try FileManager.default.removeItem(at: alice)
        let url = bob.appendingPathComponent("Imported/Project.stagecue")
        let read = try ProjectStore.load(from: url).0
        let result = try await MediaResolver().resolve(read, root: url.deletingLastPathComponent())
        expectEqual(result.report.items.count, 3); expectEqual(result.report.count(.available), 3)
        expectEqual(result.project.media.assets.first(where: { $0.background })?.cueIDs, [p.cues[2]!.id])
        let audio = SoundEngine(offline: true), video = VideoEngine()
        defer { audio.shutdown(); video.shutdown() }
        audio.play(result.project.cues[0]!); await audio.waitForLoads()
        expectTrue(audio.errors.isEmpty); expectTrue(audio.active.contains(p.cues[0]!.id))
        video.play(result.project.cues[2]!); await video.waitForLoad(); expectTrue(video.frontFrame != nil)
        video.play(result.project.cues[1]!); await video.waitForLoad()
        expectTrue(video.error.isEmpty, video.error); expectTrue(video.frontFrame != nil)
        expectTrue(audio.active.contains(p.cues[0]!.id)); expectTrue(try audio.render(frames: 512).frameLength > 0)
    }
    @Test func manifestVersionAndLegacyMissingReferencesArePreserved() async throws {
        let root = try folder("Migration"), url = root.appendingPathComponent("legacy.json")
        let original = Data("{\"schemaVersion\":3,\"cues\":[{\"title\":\"Lost\",\"filePath\":\"/Volumes/Disconnected/Lost.wav\"}]}".utf8)
        try original.write(to: url)
        let (read, notes) = try ProjectStore.load(from: url)
        let result = try await MediaResolver().resolve(read, root: root)
        expectTrue(notes.contains(SoundProject.migrationNotice)); expectEqual(result.report.count(.missing), 1)
        expectEqual(result.project.cues[0]?.id, read.cues[0]?.id)
        expectEqual(result.report.items.first?.asset.originalPath, "/Volumes/Disconnected/Lost.wav")
        expectEqual(try Data(contentsOf: url), original)
        expectThrows(try JSONDecoder().decode(SoundProject.self, from: Data("{\"schemaVersion\":4,\"media\":{\"version\":99,\"assets\":[]}}".utf8)))
    }
    @Test func sameNamesRemainDistinctAndInterruptedSecondCopyCleansUp() async throws {
        let root = try folder("DuplicateExport"), a = try folder("DuplicateExport/A"), b = try folder("DuplicateExport/B")
        let x = a.appendingPathComponent("Thunder.wav"), y = b.appendingPathComponent("Thunder.wav")
        try Data([1,2]).write(to: x); try Data([3,4]).write(to: y)
        var p = SoundProject(); p.cues[0] = Cue(filePath: x.path); p.cues[1] = Cue(filePath: y.path)
        let dest = root.appendingPathComponent("Good")
        _ = try await MediaLibrary().exportPortable(p, to: dest)
        let loaded = try ProjectStore.load(from: dest.appendingPathComponent("Project.stagecue")).0
        expectEqual(loaded.media.assets.count, 2)
        expectFalse(loaded.cues[0]?.filePath == loaded.cues[1]?.filePath)
        expectEqual(try Data(contentsOf: URL(fileURLWithPath: loaded.cues[0]!.filePath)), Data([1,2]))
        let canceled = root.appendingPathComponent("Canceled")
        do { _ = try await MediaLibrary().exportPortable(p, to: canceled, beforeCopy: { if $0 == 1 { throw CancellationError() } }); Issue.record("Ignored mid-export cancellation") } catch is CancellationError { }
        expectFalse(FileManager.default.fileExists(atPath: canceled.path))
        expectFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".stagecue-export") })
    }
    @Test @MainActor func mediaChoicesAreStagedAndStaleApplyCannotOverwriteEdits() async throws {
        let state = ShowState(autosaveURL: temporaryFiles.directory.appendingPathComponent("isolated-autosave.json"))
        defer { state.sound.shutdown(); state.video.shutdown() }
        state.project.cues[0] = Cue(filePath: "/missing/Expected.wav")
        let original = state.project
        let model = MediaManagementModel(project: original, root: nil)
        model.scan(); await model.waitForOperation()
        expectEqual(model.report.count(.missing), 1); expectEqual(state.project, original)
        let fixtures = AudioTests(), replacement = try fixtures.fixture()
        model.accept(model.report.items[0].asset, url: replacement)
        await model.waitForOperation()
        expectEqual(state.project, original)
        expectEqual(model.report.count(.available), 1)
        expectTrue(model.apply(to: state))
        expectEqual(state.project.cues[0]?.filePath, replacement.path)
        let changed = MediaManagementModel(project: state.project, root: nil)
        state.project.title = "Operator edit"
        expectFalse(changed.apply(to: state)); expectEqual(state.project.title, "Operator edit")
        let cancel = MediaManagementModel(project: state.project, root: nil)
        let before = state.project; cancel.scan(); cancel.cancel(); await cancel.waitForOperation()
        expectEqual(state.project, before)
    }
    @Test @MainActor func applicationExportLeavesWorkingProjectUnchangedAndOpenRebases() async throws {
        let root = try folder("Application/Alice"), bob = try folder("Application/Bob")
        let fixtures = AudioTests(), source = try fixtures.fixture()
        let file = root.appendingPathComponent("Opening.wav"); try FileManager.default.copyItem(at: source, to: file)
        let state = ShowState(autosaveURL: temporaryFiles.directory.appendingPathComponent("export-state.json"))
        defer { state.sound.shutdown(); state.video.shutdown() }
        state.project.cues[0] = Cue(title: "Opening", filePath: file.path)
        let original = state.project
        state.exportPortable(to: root.appendingPathComponent("Export")); await state.mediaTask?.value
        expectEqual(state.project, original); expectFalse(state.mediaBusy)
        let moved = bob.appendingPathComponent("Show")
        try FileManager.default.copyItem(at: root.appendingPathComponent("Export"), to: moved)
        try FileManager.default.removeItem(at: root)
        await state.openProject(moved.appendingPathComponent("Project.stagecue")).value
        await state.mediaTask?.value
        expectEqual(state.mediaReport.count(.available), 1)
        expectTrue(MediaPaths.relative(URL(fileURLWithPath: state.project.cues[0]!.filePath), root: moved) != nil)
        expectEqual(state.project.cues[0]?.id, original.cues[0]?.id)
    }
    @Test func malformedManifestCannotAssociateOneCueWithDifferentAssets() throws {
        let root = try folder("Malformed"), url = root.appendingPathComponent("bad.stagecue")
        let cue = Cue(filePath: "/missing/a.wav")
        var p = SoundProject(); p.cues[0] = cue
        p.media.assets = [MediaAsset(filename: "a.wav", originalPath: cue.filePath, kind: .audio, cueIDs: [cue.id]), MediaAsset(filename: "b.wav", originalPath: "/missing/b.wav", kind: .audio, cueIDs: [cue.id])]
        try JSONEncoder().encode(p).write(to: url)
        expectThrows(try ProjectStore.load(from: url))
    }
}
