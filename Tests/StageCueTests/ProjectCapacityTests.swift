import Foundation
import Testing
@testable import StageCue

@Suite(.serialized) struct ProjectCapacityTests {
    private let files = TemporaryFiles()
    @Test func aboveFormerLimitRoundTripsHundredsOfUniqueAssetsAndAutomation() throws {
        let root = files.directory
        var p = SoundProject(title: "Large production")
        let cues = (0..<1024).map { n in Cue(title: "Cue \(n)", filePath: root.appendingPathComponent("Media/\(String(repeating:"long-name",count:10))/asset-\(n).wav").path, gainDB: -18, bus: n % 6) }
        p.cues = Array(cues.prefix(32)).map(Optional.some)
        for start in stride(from:32,to:1024,by:32) { p.additionalPages.append(SoundboardPage(cues:Array(cues[start..<start+32]).map(Optional.some))) }
        p.media.assets = cues.map { MediaAsset(filename:URL(fileURLWithPath:$0.filePath).lastPathComponent, originalPath:$0.filePath, kind:.audio, sha256:String(repeating:"a",count:64), cueIDs:[$0.id], bookmark:Data(repeating:3,count:1536)) }
        p.groups = (0..<64).map { _ in CueGroup(actions:(0..<32).map { GroupAction(kind:.fade,cueID:cues[$0].id,duration:2,levelDB:-18) }) }
        p.sequences = [CueSequence(steps:cues.map { SequenceStep(cueID:$0.id) })]
        p.normalize()
        let url=root.appendingPathComponent("large.stagecue")
        try ProjectStore.save(p,to:url)
        expectTrue(try Data(contentsOf:url).count > 2*1024*1024)
        let copy=try ProjectStore.load(from:url).0
        var expected = p
        for i in expected.media.assets.indices {
            expected.media.assets[i].relativePath = MediaPaths.relative(URL(fileURLWithPath: expected.media.assets[i].originalPath), root: root)
        }
        expectEqual(copy,expected);expectEqual(copy.schemaVersion,4);expectEqual(copy.allCues.count,1024)
    }
    @Test func exactCapacityBoundaryIsAcceptedAndOneByteMoreIsRejectedWithoutReplacement() throws {
        let url=files.directory.appendingPathComponent("boundary.stagecue")
        var p=SoundProject(title: "")
        let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
        let overhead=try encoder.encode(p).count
        p.title=String(repeating:"a",count:ProjectStore.maximumBytes-overhead)
        try ProjectStore.save(p,to:url)
        expectEqual(try Data(contentsOf:url).count,ProjectStore.maximumBytes)
        expectEqual(try ProjectStore.load(from:url).0.title.count,p.title.count)
        p.title += "a"
        do { try ProjectStore.save(p,to:url);Issue.record("Oversize save succeeded") }
        catch { expectEqual(error as? ProjectFileIssue,.capacity(ProjectStore.maximumBytes)) }
        expectEqual(try Data(contentsOf:url).count,ProjectStore.maximumBytes)
        // Sparse oversize input is rejected by size before allocating/decoding it.
        let oversized=files.directory.appendingPathComponent("oversize.stagecue")
        FileManager.default.createFile(atPath:oversized.path,contents:nil)
        let h=try FileHandle(forWritingTo:oversized);try h.truncate(atOffset:UInt64(ProjectStore.maximumBytes+1));try h.close()
        do { _=try ProjectStore.load(from:oversized);Issue.record("Oversize input loaded") }
        catch { expectEqual(error as? ProjectFileIssue,.capacity(ProjectStore.maximumBytes)) }
    }
    @Test func errorKindsDistinguishMalformedUnsupportedSerializationAndFileAccess() throws {
        let url=files.directory.appendingPathComponent("invalid.stagecue")
        for (text, expected) in [("not JSON",ProjectFileIssue.malformed),("{\"schemaVersion\":999}",.unsupportedVersion(999)),("{\"media\":{\"version\":99,\"assets\":[]}}",.unsupportedManifest(99))] {
            try Data(text.utf8).write(to:url)
            do { _=try ProjectStore.load(from:url);Issue.record("Invalid input loaded") }
            catch { expectEqual(error as? ProjectFileIssue,expected) }
            expectEqual(try String(contentsOf:url,encoding:.utf8),text)
        }
        var p=SoundProject();p.media.assets=[MediaAsset(filename:"bad",originalPath:"",kind:.audio,duration:.nan)]
        do { try ProjectStore.save(p,to:url);Issue.record("Nonfinite media metadata saved") }
        catch { expectEqual(error as? ProjectFileIssue,.encoding) }
        do { _=try ProjectStore.load(from:files.directory.appendingPathComponent("missing.stagecue"));Issue.record("Missing file loaded") }
        catch { expectTrue(error is CocoaError);expectFalse(error is ProjectFileIssue) }
        expectTrue(ProjectFileIssue.capacity(ProjectStore.maximumBytes).localizedDescription.contains("16 MiB"))
        expectFalse(ProjectFileIssue.capacity(ProjectStore.maximumBytes).localizedDescription.contains("disk"))
    }
    @Test func portableLargeProjectWorksAfterMovingToUnrelatedRoot() async throws {
        let original=files.directory.appendingPathComponent("Users/A/Source")
        let destination=files.directory.appendingPathComponent("OtherVolume/Users/B/Imported")
        try FileManager.default.createDirectory(at:original,withIntermediateDirectories:true)
        try FileManager.default.createDirectory(at:destination,withIntermediateDirectories:true)
        let media=original.appendingPathComponent("clip.wav");try Data("local test media".utf8).write(to:media)
        var p=SoundProject(title:String(repeating:"Production",count:240000));p.cues[0]=Cue(filePath:media.path)
        let package=original.appendingPathComponent("Package")
        _=try await MediaLibrary().exportPortable(p,to:package)
        let moved=destination.appendingPathComponent("Moved")
        try FileManager.default.copyItem(at:package,to:moved);try FileManager.default.removeItem(at:original)
        let copy=try ProjectStore.load(from:moved.appendingPathComponent("Project.stagecue")).0
        expectEqual(copy.title,p.title);expectEqual(copy.cues[0]?.id,p.cues[0]?.id)
        expectTrue(copy.cues[0]!.filePath.hasPrefix(moved.path))
        expectEqual(try Data(contentsOf:URL(fileURLWithPath:copy.cues[0]!.filePath)),Data("local test media".utf8))
    }
}
