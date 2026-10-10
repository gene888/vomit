import Foundation
import AVFoundation
import Testing
@testable import StageCue

@Suite(.serialized)
struct PadLayoutTests {
    @Test func allPadsSupportDistinctKeysAndLegacyDefaults() throws {
        var project = SoundProject()
        expectEqual(Array(project.padKeys.prefix(9)), (1...9).map(String.init))
        project.padKeys = Array(SoundProject.availablePadKeys.prefix(32))
        expectTrue(project.normalize().isEmpty)
        let copy = try JSONDecoder().decode(SoundProject.self, from: JSONEncoder().encode(project))
        expectEqual(copy, project)
        let old = try JSONDecoder().decode(SoundProject.self, from: Data("{}".utf8))
        expectEqual(old.padKeys, SoundProject().padKeys)
    }
    @Test func conflictingReservedAndMalformedKeysAreRepaired() {
        var project = SoundProject()
        project.padKeys = ["A", "a", "x", "Option-z", " ", " Z "]
        expectFalse(project.normalize().isEmpty)
        expectEqual(Array(project.padKeys.prefix(6)), ["a", "", "", "", "", "z"])
        expectEqual(project.padKeys.count, 32)
        expectTrue(project.normalize().isEmpty)
    }
    @Test func swappingPreservesEverySettingAndPositionShortcuts() {
        let first = Cue(title: "First", filePath: "/a", gainDB: -12, bus: 5, loop: true, autoFadeIn: true)
        let second = Cue(title: "Second", filePath: "/b", curve: .equalPower)
        var project = SoundProject()
        project.cues[0] = first; project.cues[31] = second
        let keys = project.padKeys
        expectTrue(project.swapPads(0, 31))
        expectEqual(project.cues[31], first); expectEqual(project.cues[0], second)
        expectEqual(project.padKeys, keys)
        expectTrue(project.swapPads(31, 5))
        expectEqual(project.cues[5], first); expectEqual(project.cues[31], nil)
        let unchanged = project
        expectFalse(project.swapPads(-1, 2)); expectFalse(project.swapPads(1, 32)); expectFalse(project.swapPads(5, 5))
        expectEqual(project, unchanged)
    }
    @Test @MainActor func movingLiveCuesKeepsPlaybackAndCancelsStaleDrop() async throws {
        let files = TemporaryFiles()
        let url = files.directory.appendingPathComponent("loop.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800)!
        buffer.frameLength = 4800
        for channel in 0..<2 { buffer.floatChannelData![channel].initialize(repeating: 0, count: 4800) }
        var settings = format.settings; settings[AVLinearPCMIsNonInterleaved] = false
        try AVAudioFile(forWriting: url, settings: settings).write(from: buffer)
        let state = ShowState(autosaveURL: files.directory.appendingPathComponent("show.json"))
        defer { state.sound.shutdown() }
        let first = Cue(title: "First", filePath: url.path, loop: true)
        let second = Cue(title: "Second", filePath: url.path, loop: true)
        state.project.cues[0] = first; state.project.cues[31] = second
        state.setPadKey("z", at: 31)
        expectFalse(state.performPadKey("z", shift: true))
        expectTrue(state.performPadKey("z", execute: false))
        expectEqual(state.selected, 0)
        expectTrue(state.performPadKey("z"))
        expectEqual(state.selected, 31)
        state.trigger(0)
        await state.sound.waitForLoads()
        expectTrue(state.assignMedia([url], to: 0))
        state.movePad(to: 31)
        await state.waitForMediaAssignments()
        expectEqual(state.selected, 31)
        expectEqual(state.selectedCue, first)
        expectEqual(state.project.cues[0], second)
        expectEqual(state.sound.active, Set([first.id, second.id]))
        expectTrue(state.performPadKey("x"))
        expectTrue(state.sound.active.contains(second.id))
        expectFalse(state.sound.active.contains(first.id))
    }
    @Test @MainActor func duplicateAndReservedShortcutChangesAreRejected() {
        let files = TemporaryFiles()
        let state = ShowState(autosaveURL: files.directory.appendingPathComponent("show.json"))
        defer { state.sound.shutdown() }
        state.setPadKey("1", at: 31)
        expectEqual(state.project.padKeys[31], "")
        state.setPadKey("x", at: 31)
        expectEqual(state.project.padKeys[31], "")
        state.setPadKey("z", at: 31)
        expectEqual(state.project.padKeys[31], "z")
        state.setPadKey("", at: 31)
        expectEqual(state.project.padKeys[31], "")
    }
}
