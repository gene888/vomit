import Foundation
import Testing
@testable import StageCue

@Suite(.serialized) @MainActor struct SequenceTests {
    private func setup(_ clock: TestShowClock, _ driver: TestShowDriver) -> SequenceEngine {
        let scheduler = ShowScheduler(automatic: false, now: { clock.value }); scheduler.driver = driver
        let sequence = SequenceEngine(scheduler: scheduler, automatic: false, now: { clock.value })
        sequence.resolveStep = { step in
            guard let id = step.cueID else { throw MediaIssue(message: "Missing cue") }
            return CueGroup(title: step.title, actions: [GroupAction(cueID: id)])
        }
        return sequence
    }
    @Test func manualGoDisplaysCurrentAndNextAndDoesNotStopOtherPlayback() {
        let clock = TestShowClock(), driver = TestShowDriver(), cue = UUID(), other = UUID()
        driver.statuses[other] = .playing
        let sequence = setup(clock, driver)
        sequence.select(CueSequence(steps: [SequenceStep(title: "First", cueID: cue), SequenceStep(title: "Second", cueID: UUID())]))
        expectEqual(sequence.current, -1); expectEqual(sequence.nextStep?.title, "First")
        sequence.go(); expectEqual(sequence.currentStep?.title, "First"); expectEqual(sequence.nextStep?.title, "Second")
        clock.value = 100; sequence.tick(); expectEqual(driver.events.count, 1)
        sequence.go(); expectEqual(driver.events.count, 2); expectEqual(driver.statuses[other], .playing)
        sequence.go(); expectEqual(sequence.state, .completed)
    }
    @Test func timedAdvancementAndPauseResumeDoNotConsumePausedTime() {
        let clock = TestShowClock(), driver = TestShowDriver(), sequence = setup(clock, driver)
        sequence.select(CueSequence(steps: [SequenceStep(cueID: UUID(), advancement: .timed, delay: 5), SequenceStep(cueID: UUID())]))
        sequence.go(); clock.value = 2; sequence.pause()
        clock.value = 100; sequence.tick(); expectEqual(sequence.current, 0)
        sequence.resume(); clock.value = 102.99; sequence.tick(); expectEqual(sequence.current, 0)
        clock.value = 103; sequence.tick(); expectEqual(sequence.current, 1)
        expectEqual(sequence.elapsed, 5)
    }
    @Test func naturalFollowWaitsForCompletion() {
        let clock = TestShowClock(), driver = TestShowDriver(), sequence = setup(clock, driver), cue = UUID()
        sequence.select(CueSequence(steps: [SequenceStep(cueID: cue, advancement: .follow), SequenceStep(cueID: UUID())]))
        sequence.go(); sequence.scheduler.tick(); sequence.tick(); expectEqual(sequence.current, 0)
        driver.statuses[cue] = .completed; sequence.scheduler.tick(); sequence.tick(); expectEqual(sequence.current, 1)
    }
    @Test func explicitFollowTimeAdvancesWhileLoopContinues() {
        let clock = TestShowClock(), driver = TestShowDriver(), sequence = setup(clock, driver), cue = UUID()
        sequence.select(CueSequence(steps: [SequenceStep(cueID: cue, advancement: .follow, completionAfter: 3), SequenceStep(cueID: UUID())]))
        sequence.go(); clock.value = 3; sequence.tick(); expectEqual(sequence.current, 1)
        expectEqual(driver.statuses[cue], .playing); expectTrue(driver.stopped.isEmpty)
    }
    @Test func stopResetAndRestartCancelTimersAndOnlyOwnedMedia() {
        let clock = TestShowClock(), driver = TestShowDriver(), sequence = setup(clock, driver), unrelated = UUID()
        driver.statuses[unrelated] = .playing
        sequence.select(CueSequence(steps: [SequenceStep(cueID: UUID(), advancement: .timed, delay: 1), SequenceStep(cueID: UUID())]))
        sequence.go(); sequence.stop(); clock.value = 10; sequence.tick(); expectEqual(driver.events.count, 1)
        expectEqual(driver.statuses[unrelated], .playing)
        sequence.reset(); expectEqual(sequence.current, -1); expectEqual(sequence.next, 0); expectEqual(sequence.state, .ready)
        sequence.go(); expectEqual(sequence.current, 0); expectEqual(driver.events.count, 2)
    }
    @Test func skipAndBackDoNotStopPlayingMediaOrAutoplay() {
        let clock = TestShowClock(), driver = TestShowDriver(), sequence = setup(clock, driver)
        sequence.select(CueSequence(steps: (0..<3).map { SequenceStep(title: "\($0)", cueID: UUID()) }))
        sequence.go(); sequence.skip(); expectEqual(sequence.next, 2); expectEqual(driver.events.count, 1)
        sequence.go(); expectEqual(sequence.current, 2)
        sequence.back(); expectEqual(sequence.next, 1); expectEqual(driver.events.count, 2); expectTrue(driver.stopped.isEmpty)
        sequence.go(); expectEqual(sequence.current, 1)
    }
    @Test func missingReferenceAndLoadFailureBecomeErrors() {
        let clock = TestShowClock(), driver = TestShowDriver(), sequence = setup(clock, driver)
        sequence.select(CueSequence(steps: [SequenceStep()]))
        sequence.go(); expectEqual(sequence.state, .error); expectFalse(sequence.error.isEmpty)
        sequence.go(); expectTrue(driver.events.isEmpty)
        let cue = UUID(); sequence.select(CueSequence(steps: [SequenceStep(cueID: cue)])); sequence.go()
        driver.statuses[cue] = .failed("Missing media"); sequence.scheduler.tick(); sequence.tick(); expectEqual(sequence.state, .error)
    }
    @Test func persistenceAndDuplicateIDsNormalize() throws {
        var project = SoundProject()
        let step = SequenceStep(title: "Announcement", target: .group, groupID: UUID(), advancement: .follow, delay: 4, completionAfter: 12)
        project.sequences = [CueSequence(title: "Opening", steps: [step, step])]
        project.normalize(); expectNotEqual(project.sequences[0].steps[0].id, project.sequences[0].steps[1].id)
        expectEqual(try JSONDecoder().decode(SoundProject.self, from: JSONEncoder().encode(project)), project)
    }
    @Test func persistentCueAndGroupFollowRequireExplicitCompletion() throws {
        let files = TemporaryFiles(), state = ShowState(autosaveURL: files.directory.appendingPathComponent("show.json"))
        defer { state.stopAll(); state.sound.shutdown(); state.video.shutdown() }
        let loop = Cue(loop: true), image = Cue(kind: .image), held = Cue(kind: .video, holdLastFrame: true)
        state.project.cues[0] = loop; state.project.cues[1] = image; state.project.cues[2] = held
        for cue in [loop, image, held] {
            expectThrows(try state.validateSequenceFollow(SequenceStep(cueID: cue.id, advancement: .follow)))
            try state.validateSequenceFollow(SequenceStep(cueID: cue.id, advancement: .follow, completionAfter: 2))
        }
        var group = CueGroup(actions: [GroupAction(cueID: loop.id)])
        state.project.groups = [group]
        expectThrows(try state.validateSequenceFollow(SequenceStep(target: .group, groupID: group.id, advancement: .follow)))
        group.actions.append(GroupAction(kind: .stop, cueID: loop.id, delay: 2)); state.project.groups = [group]
        try state.validateSequenceFollow(SequenceStep(target: .group, groupID: group.id, advancement: .follow))
        group.actions = [GroupAction(kind: .stop, cueID: loop.id), GroupAction(cueID: loop.id, delay: 2)]; state.project.groups = [group]
        expectThrows(try state.validateSequenceFollow(SequenceStep(target: .group, groupID: group.id, advancement: .follow)))
    }
}
