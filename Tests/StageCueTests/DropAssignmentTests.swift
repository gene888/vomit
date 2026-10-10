import Foundation
import AVFoundation
import Testing
@testable import StageCue

@Suite(.serialized)
struct DropAssignmentTests {
    private let files = TemporaryFiles()
    private func audio(_ name: String) throws -> URL {
        let url = files.directory.appendingPathComponent(name).appendingPathExtension("wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800)!
        buffer.frameLength = 4800
        for channel in 0..<2 { buffer.floatChannelData![channel].initialize(repeating: 0, count: 4800) }
        var settings = format.settings; settings[AVLinearPCMIsNonInterleaved] = false
        try AVAudioFile(forWriting: url, settings: settings).write(from: buffer)
        return url
    }
    @MainActor private func state() -> ShowState {
        ShowState(autosaveURL: files.directory.appendingPathComponent("\(UUID()).json"))
    }
    @Test @MainActor func emptyPadGetsFilenameAndDoesNotAutoplay() async throws {
        let state = state(); defer { state.sound.shutdown() }
        let url = try audio("New Clip")
        expectTrue(state.assignMedia([url], to: 4))
        await state.waitForMediaAssignments()
        expectEqual(state.project.cues[4]?.title, "New Clip")
        expectEqual(state.project.cues[4]?.filePath, url.path)
        expectEqual(state.selected, 4)
        expectTrue(state.sound.active.isEmpty)
    }
    @Test @MainActor func replacementPreservesSettingsAndStopsOnlyAffectedCue() async throws {
        let state = state(); defer { state.sound.shutdown() }
        let a = try audio("A"), b = try audio("B")
        let original = Cue(title: "Custom Name", filePath: a.path, gainDB: -12, bus: 5, mode: .toggle, loop: true,
                           autoFadeIn: true, fadeInSeconds: 0.2, autoFadeOut: true, fadeOutSeconds: 0.3, curve: .equalPower)
        let other = Cue(filePath: a.path, loop: true)
        state.project.cues[0] = original
        state.project.cues[1] = other
        state.sound.play(original); state.sound.play(other)
        await state.sound.waitForLoads()
        expectTrue(state.assignMedia([b], to: 0))
        await state.waitForMediaAssignments()
        var expected = original; expected.filePath = b.path
        expectEqual(state.project.cues[0], expected)
        expectFalse(state.sound.active.contains(original.id))
        expectTrue(state.sound.active.contains(other.id))
    }
    @Test @MainActor func invalidFileAndInvalidDropsLeaveExistingCueUnchanged() async throws {
        let state = state(); defer { state.sound.shutdown() }
        let valid = try audio("Original")
        let original = Cue(filePath: valid.path, loop: true)
        state.project.cues[0] = original
        state.sound.play(original); await state.sound.waitForLoads()
        let bad = files.directory.appendingPathComponent("not-audio.txt")
        try Data("not audio".utf8).write(to: bad)
        for url in [bad, files.directory, files.directory.appendingPathComponent("missing.wav")] {
            expectTrue(state.assignMedia([url], to: 0))
            await state.waitForMediaAssignments()
            expectEqual(state.project.cues[0], original)
            expectTrue(state.sound.active.contains(original.id))
            expectTrue(state.message.hasPrefix("Cannot assign"))
        }
        expectFalse(state.assignMedia([], to: 0))
        expectFalse(state.assignMedia([valid, valid], to: 0))
        expectFalse(state.assignMedia([URL(string: "https://example.com/audio.wav")!], to: 0))
        expectFalse(state.assignMedia([valid], to: 99))
        expectEqual(state.project.cues[0], original)
    }
    @Test @MainActor func newerDropWinsAndClearedPadCannotBeRepopulatedByOldValidation() async throws {
        let state = state(); defer { state.sound.shutdown() }
        let a = try audio("A"), b = try audio("B")
        state.assignMedia([a], to: 0); state.assignMedia([b], to: 0)
        await state.waitForMediaAssignments()
        expectEqual(state.project.cues[0]?.filePath, b.path)
        state.assignMedia([a], to: 0)
        state.selected = 0; state.setCue(nil)
        await state.waitForMediaAssignments()
        try await Task.sleep(for: .milliseconds(50))
        expectEqual(state.project.cues[0], nil)
    }
}
