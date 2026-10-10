import Foundation
import AVFoundation
import Testing
@testable import StageCue

@MainActor final class TestShowDriver: ShowPlaybackDriver {
    var events: [GroupAction] = []
    var stopped: [(UUID, Double)] = []
    var paused: Set<UUID> = []
    var statuses: [UUID: PlaybackStatus] = [:]
    func resource(for action: GroupAction) throws -> String? {
        if action.kind.needsCue {
            guard let id = action.cueID else { throw MediaIssue(message: "Missing cue") }
            return "audio:\(id)"
        }
        return action.kind == .bus ? "bus:\(action.bus)" : nil
    }
    func execute(_ action: GroupAction) throws -> OwnedPlayback? {
        _ = try resource(for: action); events.append(action)
        if action.kind == .play, let id = action.cueID {
            statuses[id] = .playing
            return OwnedPlayback(resource: "audio:\(id)", cueID: id, survives: action.survivesTermination)
        }
        if action.kind == .stop, let id = action.cueID { statuses[id] = .completed }
        return nil
    }
    func status(_ playback: OwnedPlayback) -> PlaybackStatus { statuses[playback.cueID] ?? .completed }
    func stop(_ playback: OwnedPlayback, fade: Double) { stopped.append((playback.cueID, fade)); statuses[playback.cueID] = .completed }
    func pause(_ playback: OwnedPlayback) { paused.insert(playback.cueID) }
    func resume(_ playback: OwnedPlayback) { paused.remove(playback.cueID) }
}
@MainActor final class TestShowClock { var value: Double = 0 }

@Suite(.serialized) @MainActor struct ShowControlTests {
    @Test func simultaneousAndDelayedActionsHaveStableOrder() {
        let clock = TestShowClock(), driver = TestShowDriver()
        let scheduler = ShowScheduler(automatic: false, now: { clock.value }); scheduler.driver = driver
        let a = GroupAction(cueID: UUID()), b = GroupAction(cueID: UUID()), c = GroupAction(cueID: UUID(), delay: 2)
        _ = scheduler.launch(CueGroup(actions: [a, b, c]))
        expectEqual(driver.events.map(\.id), [a.id, b.id])
        clock.value = 1.99; scheduler.tick(); expectEqual(driver.events.count, 2)
        clock.value = 2; scheduler.tick(); expectEqual(driver.events.map(\.id), [a.id, b.id, c.id])
    }
    @Test func cancelPreventsStaleActionsAndEmergencyCancelsAll() {
        let clock = TestShowClock(), driver = TestShowDriver()
        let scheduler = ShowScheduler(automatic: false, now: { clock.value }); scheduler.driver = driver
        let id = scheduler.launch(CueGroup(actions: [GroupAction(cueID: UUID(), delay: 3)]))!
        scheduler.stop(id); clock.value = 10; scheduler.tick(); expectTrue(driver.events.isEmpty)
        _ = scheduler.launch(CueGroup(actions: [GroupAction(cueID: UUID(), delay: 2)]))
        scheduler.cancelAll(); clock.value = 20; scheduler.tick(); expectTrue(driver.events.isEmpty)
    }
    @Test func pauseResumePreservesRelativeDeadlinesAndOwnedMedia() {
        let clock = TestShowClock(), driver = TestShowDriver()
        let scheduler = ShowScheduler(automatic: false, now: { clock.value }); scheduler.driver = driver
        let cue = UUID()
        let id = scheduler.launch(CueGroup(actions: [GroupAction(cueID: cue), GroupAction(cueID: UUID(), delay: 5)]))!
        clock.value = 2; scheduler.pause(id); expectTrue(driver.paused.contains(cue))
        clock.value = 102; scheduler.tick(); expectEqual(driver.events.count, 1)
        scheduler.resume(id); expectFalse(driver.paused.contains(cue))
        clock.value = 104.99; scheduler.tick(); expectEqual(driver.events.count, 1)
        clock.value = 105; scheduler.tick(); expectEqual(driver.events.count, 2)
    }
    @Test func stopModesAndSurvivorsAffectOnlyOwnedPlayback() {
        for mode in GroupStopMode.allCases {
            let driver = TestShowDriver(), scheduler = ShowScheduler(automatic: false)
            scheduler.driver = driver
            let owned = UUID(), survivor = UUID(), unrelated = UUID()
            driver.statuses[unrelated] = .playing
            let id = scheduler.launch(CueGroup(actions: [GroupAction(cueID: owned), GroupAction(cueID: survivor, survivesTermination: true)], stopMode: mode, stopFade: 2))!
            scheduler.stop(id)
            expectEqual(driver.stopped.count, mode == .schedulesOnly ? 0 : 1)
            if let stopped = driver.stopped.first { expectEqual(stopped.0, owned); expectEqual(stopped.1, mode == .fade ? 2 : 0) }
            expectEqual(driver.statuses[survivor], .playing); expectEqual(driver.statuses[unrelated], .playing)
        }
    }
    @Test func replacementOwnershipProtectsOtherGroups() {
        let driver = TestShowDriver(), scheduler = ShowScheduler(automatic: false); scheduler.driver = driver
        let cue = UUID()
        let first = scheduler.launch(CueGroup(actions: [GroupAction(cueID: cue)], automaticCompletion: false))!
        let second = scheduler.launch(CueGroup(actions: [GroupAction(cueID: cue)], automaticCompletion: false))!
        scheduler.stop(first); expectTrue(driver.stopped.isEmpty)
        scheduler.stop(second); expectEqual(driver.stopped.count, 1)
    }
    @Test func manualOverrideSuppressesOldAutomationButAllowsNewGroup() {
        let clock = TestShowClock(), driver = TestShowDriver()
        let scheduler = ShowScheduler(automatic: false, now: { clock.value }); scheduler.driver = driver
        let cue = UUID()
        let id = scheduler.launch(CueGroup(actions: [GroupAction(cueID: cue), GroupAction(kind: .fade, cueID: cue, delay: 2)]))!
        scheduler.manualOverride("audio:\(cue)")
        clock.value = 3; scheduler.tick(); expectEqual(driver.events.count, 1)
        scheduler.stop(id); expectTrue(driver.stopped.isEmpty)
        _ = scheduler.launch(CueGroup(actions: [GroupAction(kind: .fade, cueID: cue)])); expectEqual(driver.events.count, 2)
    }
    @Test func waitsCompletionAndMissingReferences() {
        let clock = TestShowClock(), driver = TestShowDriver()
        let scheduler = ShowScheduler(automatic: false, now: { clock.value }); scheduler.driver = driver
        let cue = UUID()
        let id = scheduler.launch(CueGroup(actions: [GroupAction(kind: .wait, duration: 2), GroupAction(cueID: cue, delay: 1)]))!
        expectTrue(driver.events.isEmpty)
        clock.value = 3; scheduler.tick(); expectEqual(driver.events.count, 1); expectEqual(scheduler.state(of: id), .running)
        driver.statuses[cue] = .completed; scheduler.tick(); expectEqual(scheduler.state(of: id), .completed)
        let missing = scheduler.launch(CueGroup(actions: [GroupAction()]))!
        expectEqual(scheduler.state(of: missing), .error)
    }
    @Test func nestedGroupCycleIsRejectedAndParentStopCancelsChildren() {
        let clock = TestShowClock(), driver = TestShowDriver()
        let scheduler = ShowScheduler(automatic: false, now: { clock.value }); scheduler.driver = driver
        var child = CueGroup(actions: [GroupAction(cueID: UUID(), delay: 5)])
        let parent = CueGroup(actions: [GroupAction(kind: .triggerGroup, groupID: child.id)])
        scheduler.groupLookup = { $0 == child.id ? child : nil }
        let id = scheduler.launch(parent)!
        scheduler.stop(id); clock.value = 10; scheduler.tick(); expectTrue(driver.events.isEmpty)
        child.actions = [GroupAction(kind: .triggerGroup, groupID: child.id)]
        let cycle = scheduler.launch(child)!; expectEqual(scheduler.state(of: cycle), .error)
    }
    @Test func concurrentGroupsUseDeadlineThenLaunchOrder() {
        let clock = TestShowClock(), driver = TestShowDriver()
        let scheduler = ShowScheduler(automatic: false, now: { clock.value }); scheduler.driver = driver
        let a = GroupAction(cueID: UUID(), delay: 2), b = GroupAction(cueID: UUID(), delay: 1)
        _ = scheduler.launch(CueGroup(actions: [a])); _ = scheduler.launch(CueGroup(actions: [b]))
        clock.value = 3; scheduler.tick(); expectEqual(driver.events.map(\.id), [b.id, a.id])
    }
    @Test func schemaThreePreservesGroupsAndOlderIDs() throws {
        let cue = Cue(title: "Music", filePath: "/local/music.wav")
        var project = SoundProject(); project.cues[0] = cue
        project.groups = [CueGroup(actions: [GroupAction(cueID: cue.id, delay: 2, duration: 5, levelDB: -18, overrideLevel: true, survivesTermination: true)])]
        let data = try JSONEncoder().encode(project)
        expectEqual(try JSONDecoder().decode(SoundProject.self, from: data), project)
        for version in [1, 2] {
            var old = project; old.schemaVersion = version
            var migrated = try JSONDecoder().decode(SoundProject.self, from: JSONEncoder().encode(old))
            expectTrue(migrated.normalize().contains(SoundProject.migrationNotice))
            expectEqual(migrated.schemaVersion, 3); expectEqual(migrated.cues[0]?.id, cue.id)
        }
    }
    @Test func continuousClockFiresWithoutUITimerUnderWorkerLoad() async throws {
        let driver = TestShowDriver(), scheduler = ShowScheduler(); scheduler.driver = driver
        let start = ContinuousClock.now
        let load = Task.detached { var n: UInt64 = 1; for i in 0..<2_000_000 { n = n &* 1664525 &+ UInt64(i) }; return n }
        _ = scheduler.launch(CueGroup(actions: [GroupAction(cueID: UUID(), delay: 0.08)]))
        try await Task.sleep(for: .milliseconds(240))
        expectEqual(driver.events.count, 1)
        let elapsed = start.duration(to: .now).components
        expectTrue(Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18 < 1)
        _ = await load.value; scheduler.cancelAll()
    }
}
