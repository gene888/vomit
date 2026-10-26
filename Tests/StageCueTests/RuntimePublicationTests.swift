import Foundation
import Combine
import Testing
@testable import StageCue

@Suite(.serialized) @MainActor struct RuntimePublicationTests {
    private let files = TemporaryFiles()
    private func makeState() -> ShowState { ShowState(autosaveURL: files.directory.appendingPathComponent(UUID().uuidString + ".json")) }
    private func close(_ state: ShowState) { state.stopAll(); state.sound.shutdown(); state.video.shutdown(); state.output.close() }

    @Test func selectionIsImmediateAndOneBurstPublishesLatestStateOnce() async throws {
        let state = makeState(); defer { close(state) }
        var observed: [Int] = []
        let token = state.objectWillChange.sink { [weak state] in observed.append(state?.selected ?? -1) }
        defer { token.cancel() }
        for index in 0..<100 { state.selected = index % 32 }
        expectEqual(state.selected, 3)
        expectTrue(observed.isEmpty)
        // Parallel AV engine setup can occupy MainActor longer than a frame. Observe
        // delivery rather than treating a UI refresh interval as a hard realtime bound.
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while observed.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        expectEqual(observed, [3])
        state.selected = 3 // No-op selection must not invalidate the view again.
        try await Task.sleep(for: .milliseconds(30))
        expectEqual(observed, [3])
    }

    @Test func continuousRuntimeChangesDoNotPostponePublicationUntilTheEnd() async throws {
        let state = makeState(); defer { close(state) }
        var notifications = 0
        let token = state.objectWillChange.sink { notifications += 1 }; defer { token.cancel() }
        for index in 1...15 {
            state.selected = index
            try await Task.sleep(for: .milliseconds(3))
            if index == 10 { expectTrue(notifications > 0) }
        }
        try await Task.sleep(for: .milliseconds(30))
        expectTrue(notifications >= 2 && notifications < 15)
        expectEqual(state.selected, 15)
        let settled = notifications
        try await Task.sleep(for: .milliseconds(40))
        expectEqual(notifications, settled)
    }

    @Test func loadingCancellationAndErrorsRemainImmediatelyReadable() async throws {
        let state = makeState(); defer { close(state) }
        var notifications = 0
        let token = state.objectWillChange.sink { notifications += 1 }; defer { token.cancel() }
        let cue = Cue(filePath: files.directory.appendingPathComponent("missing.wav").path)
        state.project.cues[0] = cue
        notifications = 0
        state.trigger(0)
        expectTrue(state.sound.loading.contains(cue.id))
        expectEqual(notifications, 0)
        state.stopCue(cue)
        expectTrue(state.sound.loading.isEmpty)
        expectTrue(state.sound.active.isEmpty)
        await state.sound.waitForLoads()
        try await Task.sleep(for: .milliseconds(40))
        expectTrue(state.sound.failed.isEmpty) // Canceled work cannot publish a late error.
        expectEqual(state.sound.voiceCount, 0)
        state.sound.play(cue); await state.sound.waitForLoads()
        expectTrue(state.sound.failed.contains(cue.id))
        expectFalse(state.sound.errors.isEmpty)
        try await Task.sleep(for: .milliseconds(40))
        expectTrue(notifications > 0)
    }

    @Test func closingWithPendingUIWorkDoesNotRetainProjectOrSchedulePlayback() async throws {
        weak var released: ShowState?
        do {
            let state = makeState(); released = state
            state.selected = 7
            close(state)
        }
        expectTrue(released == nil)
        try await Task.sleep(for: .milliseconds(30))
        expectTrue(released == nil)
    }
}
