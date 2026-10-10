import Foundation
import AVFoundation
import AppKit
import Testing
@testable import StageCue

@Suite(.serialized) @MainActor struct ShowModeTests {
    private let files = TemporaryFiles()
    private func fixture() throws -> URL {
        let url = files.directory.appendingPathComponent(UUID().uuidString + ".wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800)!; buffer.frameLength = 4800
        for c in 0..<2 { for i in 0..<4800 { buffer.floatChannelData![c][i] = 0 } }
        let file = try AVAudioFile(forWriting: url, settings: format.settings); try file.write(from: buffer)
        return url
    }
    private func state() -> ShowState { ShowState(autosaveURL: files.directory.appendingPathComponent(UUID().uuidString + ".json")) }
    private func shutdown(_ state: ShowState) { state.stopAll(); state.sound.shutdown(); state.video.shutdown() }
    @Test func modeAndPageSwitchesKeepAudioAndVisualPlaybackAlive() async throws {
        let state = state(); defer { shutdown(state) }
        let cue = Cue(filePath: try fixture().path, loop: true)
        let url = files.directory.appendingPathComponent("red.png")
        let image = NSImage(size: NSSize(width: 32, height: 32)); image.lockFocus(); NSColor.red.setFill(); NSRect(x: 0, y: 0, width: 32, height: 32).fill(); image.unlockFocus()
        let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!; try rep.representation(using: .png, properties: [:])!.write(to: url)
        let visual = Cue(filePath: url.path, kind: .image, transition: .cut)
        state.project.cues[0] = cue; state.project.cues[1] = visual
        state.trigger(0); state.trigger(1); await state.sound.waitForLoads(); await state.video.waitForLoad()
        expectTrue(state.sound.active.contains(cue.id)); expectTrue(state.video.activeIDs.contains(visual.id))
        let frame = state.video.frontFrame
        state.project.show.showMode = true; state.addPage(); state.project.show.showMode = false; state.changePage(0)
        expectTrue(state.sound.active.contains(cue.id)); expectTrue(state.video.frontFrame === frame)
        expectEqual(state.pads[0]?.id, cue.id)
    }
    @Test func assigningMediaToGroupPadClearsTheGroupReference() async throws {
        let state = state(); defer { shutdown(state) }
        let group = CueGroup(); state.project.groups = [group]
        state.project.cues[0] = Cue(title: "Replace group", kind: .group, groupID: group.id)
        expectTrue(state.assignMedia([try fixture()], to: 0)); await state.waitForMediaAssignments()
        expectEqual(state.project.cues[0]?.kind, .audio)
        expectTrue(state.project.cues[0]?.groupID == nil)
    }
    @Test func groupPadTriggersAcrossPagesAndReferencesRemainStable() async throws {
        let state = state(); defer { shutdown(state) }
        let cue = Cue(filePath: try fixture().path, loop: true); state.project.cues[0] = cue
        let group = CueGroup(actions: [GroupAction(cueID: cue.id)])
        state.project.groups = [group]; state.addPage()
        state.pads[0] = Cue(title: "Group pad", kind: .group, groupID: group.id)
        state.trigger(0); await state.sound.waitForLoads()
        expectTrue(state.sound.active.contains(cue.id)); expectEqual(state.scheduler.activeRuns.count, 1)
        state.changePage(0); state.stopAll(); expectTrue(state.scheduler.activeRuns.isEmpty)
    }
    @Test func showShortcutsPersistRejectDuplicatesAndEmergencyStopsEverything() async throws {
        let state = state(); defer { shutdown(state) }
        let cue = Cue(filePath: try fixture().path, loop: true); state.project.cues[0] = cue
        state.setShowKey("z", command: .go)
        expectEqual(state.project.show.keys[ShowCommand.go.rawValue], "z")
        state.setShowKey("z", command: .pause); expectEqual(state.project.show.keys[ShowCommand.pause.rawValue], "p")
        let sequence = CueSequence(steps: [SequenceStep(cueID: cue.id)]); state.project.sequences = [sequence]; state.loadSequence(sequence.id)
        expectTrue(state.performShowKey("z")); await state.sound.waitForLoads(); expectTrue(state.sound.active.contains(cue.id))
        _ = state.scheduler.launch(CueGroup(actions: [GroupAction(cueID: cue.id, delay: 0.05)]))
        state.project.show.showMode = false
        expectTrue(state.performShowKey(".")); expectTrue(state.sound.active.isEmpty); expectTrue(state.scheduler.activeRuns.isEmpty); expectEqual(state.sequence.state, .stopped)
        try await Task.sleep(for: .milliseconds(120)); expectTrue(state.sound.active.isEmpty)
        expectEqual(try JSONDecoder().decode(SoundProject.self, from: JSONEncoder().encode(state.project)), state.project)
    }
    @Test func automatedPageAndBusActionsAndManualOverrides() throws {
        let state = state(); defer { shutdown(state) }
        state.addPage(); state.changePage(0)
        _ = state.scheduler.launch(CueGroup(actions: [GroupAction(kind: .page, page: 1), GroupAction(kind: .bus, levelDB: -18, bus: 2)]))
        expectEqual(state.page, 1); expectEqual(state.project.busDB[2], -18)
        expectThrows(try state.execute(GroupAction(kind: .page, page: 99)))
        expectThrows(try state.referencedCue(UUID()))
    }
    @Test func pendingAssignmentCanceledOnPageChange() async throws {
        let state = state(); defer { shutdown(state) }
        let url = try fixture(); expectTrue(state.assignMedia([url], to: 0))
        state.addPage(); await state.waitForMediaAssignments()
        expectTrue(state.project.cues[0] == nil); expectTrue(state.pads[0] == nil)
    }
    @Test func manualOverridePropagatesToDelayedChildrenAndAutomaticSequenceSteps() {
        let clock = TestShowClock(), driver = TestShowDriver(), cue = UUID()
        let scheduler = ShowScheduler(automatic: false, now: { clock.value }); scheduler.driver = driver
        let child = CueGroup(actions: [GroupAction(cueID: cue)])
        scheduler.groupLookup = { $0 == child.id ? child : nil }
        _ = scheduler.launch(CueGroup(actions: [GroupAction(kind: .triggerGroup, groupID: child.id, delay: 2)]))
        scheduler.manualOverride("audio:\(cue)"); clock.value = 3; scheduler.tick(); scheduler.tick(); expectTrue(driver.events.isEmpty)
        let sequence = SequenceEngine(scheduler: scheduler, automatic: false, now: { clock.value })
        sequence.resolveStep = { step in CueGroup(actions: [GroupAction(cueID: step.cueID)]) }
        sequence.select(CueSequence(steps: [SequenceStep(cueID: UUID(), advancement: .timed, delay: 1), SequenceStep(cueID: cue)]))
        sequence.go(); scheduler.manualOverride("audio:\(cue)"); clock.value = 4; sequence.tick()
        expectEqual(driver.events.count, 1)
        sequence.reset(); sequence.go(manual: true); clock.value = 5; sequence.tick(); expectEqual(driver.events.count, 3)
    }
    @Test func audioDeviceChangeCancelsPendingAutomation() async throws {
        let state = state(); defer { shutdown(state) }
        let cue = Cue(filePath: try fixture().path, loop: true); state.project.cues[0] = cue
        _ = state.scheduler.launch(CueGroup(actions: [GroupAction(cueID: cue.id, delay: 0.05)]))
        state.sound.handleConfigurationChange()
        try await Task.sleep(for: .milliseconds(120))
        expectTrue(state.scheduler.activeRuns.isEmpty); expectTrue(state.sound.active.isEmpty)
    }
}

@Suite(.serialized) @MainActor struct ShowControlReliabilityTests {
    @Test func historyRetirementPreservesErroredOwnershipAndCurrentFollow() async {
        let clock = TestShowClock(), driver = TestShowDriver(), scheduler = ShowScheduler(automatic: false, now: { clock.value })
        scheduler.driver = driver
        let cue = UUID()
        let errorRun = scheduler.launch(CueGroup(actions: [GroupAction(cueID: cue), GroupAction()]))!
        expectEqual(scheduler.state(of: errorRun), .error)
        let sequence = SequenceEngine(scheduler: scheduler, automatic: false, now: { clock.value })
        sequence.resolveStep = { step in CueGroup(actions: [GroupAction(cueID: step.cueID)]) }
        let follow = UUID()
        sequence.select(CueSequence(steps: [SequenceStep(cueID: follow, advancement: .follow), SequenceStep(cueID: UUID())]))
        sequence.go(); driver.statuses[follow] = .completed; scheduler.tick()
        for i in 0..<600 {
            _ = scheduler.launch(CueGroup(actions: [GroupAction(kind: .bus)]))
            if i % 10 == 0 { await Task.yield() }
        }
        expectEqual(scheduler.state(of: errorRun), .error)
        sequence.tick(); expectEqual(sequence.current, 1)
        scheduler.stop(errorRun); expectEqual(driver.stopped.first?.0, cue)
    }
    @Test func preflightDetectsMissingTargetsAndCyclesWithoutMediaCopies() {
        var project = SoundProject()
        var group = CueGroup(actions: [GroupAction(cueID: UUID())])
        group.actions.append(GroupAction(kind: .triggerGroup, groupID: group.id))
        project.groups = [group]; project.sequences = [CueSequence(steps: [SequenceStep()])]
        expectEqual(project.showReferenceIssues().count, 3)
    }
    @Test func childFailurePropagatesToParentAndErrorStopCancelsOwnedMedia() {
        let driver = TestShowDriver(), scheduler = ShowScheduler(automatic: false)
        scheduler.driver = driver
        let child = CueGroup(actions: [GroupAction()])
        scheduler.groupLookup = { $0 == child.id ? child : nil }
        let cue = UUID()
        let parent = scheduler.launch(CueGroup(actions: [GroupAction(cueID: cue), GroupAction(kind: .triggerGroup, groupID: child.id)]))!
        scheduler.tick(); expectEqual(scheduler.state(of: parent), .error)
        scheduler.stop(parent); expectEqual(driver.stopped.first?.0, cue)
    }
    @Test func controlAdvanceAndEmergencyNeverExecuteStaleCommands() {
        let clock = TestShowClock(), driver = TestShowDriver(), scheduler = ShowScheduler(automatic: false, now: { clock.value })
        scheduler.driver = driver
        var advanced = 0; scheduler.onAdvance = { _ in advanced += 1 }
        _ = scheduler.launch(CueGroup(actions: [GroupAction(kind: .advance, delay: 2)]))
        scheduler.manualOverride("sequence"); clock.value = 3; scheduler.tick(); expectEqual(advanced, 0)
        _ = scheduler.launch(CueGroup(actions: [GroupAction(kind: .advance, delay: 1)])); scheduler.cancelAll()
        clock.value = 10; scheduler.tick(); expectEqual(advanced, 0)
        _ = scheduler.launch(CueGroup(actions: [GroupAction(kind: .advance)])); expectEqual(advanced, 1)
    }
    @Test func allPageIDsAndShowKeysNormalizeAndRoundTrip() throws {
        var project = SoundProject()
        let cue = Cue(); project.cues[0] = cue
        project.additionalPages = [SoundboardPage(cues: [cue], padKeys: ["x", "z", "z"])]
        project.show.keys[ShowCommand.go.rawValue] = "B"; project.show.keys[ShowCommand.pause.rawValue] = "b"
        project.normalize()
        expectNotEqual(project.cues[0]?.id, project.additionalPages[0].cues[0]?.id)
        expectEqual(project.additionalPages[0].cues.count, 32)
        expectEqual(project.additionalPages[0].padKeys.prefix(3).map { $0 }, ["", "z", ""])
        expectEqual(project.show.keys[ShowCommand.go.rawValue], "b"); expectEqual(project.show.keys[ShowCommand.pause.rawValue], "")
        expectEqual(try JSONDecoder().decode(SoundProject.self, from: JSONEncoder().encode(project)), project)
        expectTrue(project.normalize().isEmpty)
    }
    @Test func priorSequenceAdvanceDoesNotAdvanceNewCurrentRow() {
        let clock = TestShowClock(), driver = TestShowDriver(), scheduler = ShowScheduler(automatic: false, now: { clock.value })
        scheduler.driver = driver
        let sequence = SequenceEngine(scheduler: scheduler, automatic: false, now: { clock.value })
        sequence.resolveStep = { step in CueGroup(actions: [GroupAction(cueID: step.cueID)]) }
        sequence.select(CueSequence(steps: (0..<3).map { _ in SequenceStep(cueID: UUID()) }))
        sequence.go(); let old = scheduler.runs[0].id; sequence.go()
        sequence.advanceFromGroup(old); expectEqual(sequence.current, 1)
    }
}
