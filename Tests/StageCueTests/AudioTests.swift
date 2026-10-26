import Testing
import AVFoundation
@testable import StageCue

@Suite(.serialized)
struct AudioTests {
    private let temporaryFiles = TemporaryFiles()
    func fixture(seconds: Double = 1, rate: Double = 48_000, channels: AVAudioChannelCount = 2, value: Float = 0.05) throws -> URL {
        let url = temporaryFiles.directory.appendingPathComponent("stagecue-\(UUID()).wav")
        let layout = AVAudioChannelLayout(layoutTag: channels == 4 ? kAudioChannelLayoutTag_Quadraphonic : channels == 1 ? kAudioChannelLayoutTag_Mono : kAudioChannelLayoutTag_Stereo)!
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, interleaved: false, channelLayout: layout)
        let frames = AVAudioFrameCount(seconds * rate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for channel in 0..<Int(channels) {
            for sample in 0..<Int(frames) { buffer.floatChannelData![channel][sample] = value }
        }
        var settings = format.settings
        settings[AVLinearPCMIsNonInterleaved] = false
        let file = try AVAudioFile(forWriting: url, settings: settings)
        try file.write(from: buffer)
        return url
    }
    @MainActor private func render(_ engine: SoundEngine, frames: Int) throws -> Float {
        var remaining = frames
        var last: Float = 0
        while remaining > 0 {
            let n = min(128, remaining)
            let buffer = try engine.render(frames: AVAudioFrameCount(n))
            last = buffer.floatChannelData![0][Int(buffer.frameLength) - 1]
            remaining -= n
        }
        return last
    }
    @MainActor private func start(_ engine: SoundEngine, _ cues: [Cue]) async {
        for cue in cues { engine.play(cue) }
        await engine.waitForLoads()
        expectTrue(engine.errors.isEmpty, engine.errors.joined(separator: "\n"))
        expectEqual(engine.active, Set(cues.map(\.id)))
    }
    @Test @MainActor func fadesDuringLoadApplyAfterDecode() async throws {
        let engine = SoundEngine(offline: true); defer { engine.shutdown() }
        let cue = Cue(filePath: try fixture().path, gainDB: 0, loop: true)
        engine.play(cue)
        engine.fadeToDB(cue.id, decibels: -18, seconds: 0)
        await engine.waitForLoads()
        expectEqual(engine.playingLevels[cue.id]!, amplitude(-18), accuracy: 0.0001)
    }
    @Test @MainActor func individualPauseAndArbitraryFadePreserveAudioContinuity() async throws {
        let engine = SoundEngine(offline: true); defer { engine.shutdown() }
        let a = Cue(filePath: try fixture().path, gainDB: 0, loop: true, curve: .linear)
        let b = Cue(filePath: a.filePath, gainDB: -6, bus: 1, loop: true)
        engine.play(a); engine.play(b); await engine.waitForLoads()
        engine.fadeToDB(a.id, decibels: -20, seconds: 1)
        for _ in 0..<10 { _ = try engine.render(frames: 1024) }
        let before = engine.playingLevels[a.id]!
        engine.pause(a.id)
        for _ in 0..<20 { _ = try engine.render(frames: 1024) }
        expectEqual(engine.playingLevels[a.id]!, before)
        expectTrue(engine.active.contains(b.id))
        engine.resume(a.id)
        engine.fadeToDB(a.id, decibels: -6, seconds: 0.5)
        expectEqual(engine.playingLevels[a.id]!, before)
        for _ in 0..<25 { _ = try engine.render(frames: 1024) }
        expectEqual(engine.playingLevels[a.id]!, amplitude(-6), accuracy: 0.0001)
        expectEqual(engine.active.count, 2)
    }
    @Test @MainActor func testSimultaneousCuesClipBusAndMasterGain() async throws {
        let engine = SoundEngine(offline: true); defer { engine.shutdown() }
        let path = try fixture().path
        var project = SoundProject(busDB: [-6, 0, 0, 0, 0, 0], masterDB: -6)
        engine.applyMix(project)
        let a = Cue(filePath: path, gainDB: -6, bus: 0, loop: true)
        let b = Cue(filePath: path, gainDB: 0, bus: 1, loop: true)
        await start(engine, [a, b])
        let sample = try render(engine, frames: 4096)
        let expected = 0.05 * (amplitude(-6) * amplitude(-6) + 1) * amplitude(-6)
        expectEqual(sample, expected, accuracy: 0.0003)
        project.busDB[1] = -60
        engine.applyMix(project)
        let changed = try render(engine, frames: 4096)
        expectEqual(changed, 0.05 * (amplitude(-6) * amplitude(-6) + amplitude(-60)) * amplitude(-6), accuracy: 0.0003)
    }
    @Test @MainActor func testPositiveClipBusAndMasterGain() async throws {
        let engine = SoundEngine(offline: true); defer { engine.shutdown() }
        let path = try fixture().path
        let cue = Cue(filePath: path, gainDB: 6, loop: true)
        await start(engine, [cue])
        expectEqual(try render(engine, frames: 4096), 0.05 * amplitude(6), accuracy: 0.0003)
        var project = SoundProject(busDB: [6, 0, 0, 0, 0, 0])
        engine.applyMix(project)
        expectEqual(try render(engine, frames: 4096), 0.05 * amplitude(6) * amplitude(6), accuracy: 0.0003)
        project.masterDB = 6
        engine.applyMix(project)
        expectEqual(try render(engine, frames: 4096), 0.05 * amplitude(6) * amplitude(6) * amplitude(6), accuracy: 0.0003)
    }
    @Test @MainActor func testEachOfSixBusesRoutesIndependently() async throws {
        let engine = SoundEngine(offline: true); defer { engine.shutdown() }
        let path = try fixture().path
        let cues = (0..<6).map { Cue(filePath: path, gainDB: 0, bus: $0, loop: true) }
        await start(engine, cues)
        for bus in 0..<6 {
            var project = SoundProject(busDB: Array(repeating: -60, count: 6))
            project.busDB[bus] = 0
            engine.applyMix(project)
            expectEqual(try render(engine, frames: 2048), 0.05 * (1 + Float(5 - bus) * 0.001), accuracy: 0.00003)
            engine.stop(cues[bus].id)
            expectEqual(try render(engine, frames: 2048), 0.05 * Float(5 - bus) * 0.001, accuracy: 0.0003)
        }
    }
    @Test @MainActor func testFadeToSilenceKeepsLoopAndFadeInRestoresIt() async throws {
        let engine = SoundEngine(offline: true); defer { engine.shutdown() }
        let cue = Cue(filePath: try fixture(seconds: 0.05).path, gainDB: 0, loop: true, curve: .linear)
        await start(engine, [cue])
        _ = try render(engine, frames: 2048)
        engine.fadeToSilence(cue.id, seconds: 0.1)
        let midway = try render(engine, frames: 2400)
        expectGreaterThan(midway, 0.015)
        expectLessThan(midway, 0.04)
        _ = try render(engine, frames: 4096)
        expectTrue(engine.active.contains(cue.id))
        expectEqual(engine.playingLevels[cue.id], 0)
        expectEqual(try render(engine, frames: 1024), 0, accuracy: 0.00001)
        engine.fadeIn(cue.id, seconds: 0.1)
        expectEqual(try render(engine, frames: 6000), 0.05, accuracy: 0.0003)
    }
    @Test @MainActor func testIndependentFadesAndFadeStopDetachOnlyTarget() async throws {
        let engine = SoundEngine(offline: true); defer { engine.shutdown() }
        let path = try fixture().path
        let a = Cue(filePath: path, gainDB: 0, loop: true, curve: .linear)
        let b = Cue(filePath: path, gainDB: 0, loop: true, curve: .linear)
        await start(engine, [a, b])
        _ = try render(engine, frames: 2048)
        engine.fadeOutAndStop(a.id, seconds: 0.05)
        engine.fadeToSilence(b.id, seconds: 0.1)
        _ = try render(engine, frames: 3000)
        expectFalse(engine.active.contains(a.id))
        expectTrue(engine.active.contains(b.id))
        expectGreaterThan(engine.playingLevels[b.id] ?? 0, 0)
        _ = try render(engine, frames: 3000)
        expectEqual(engine.playingLevels[b.id], 0)
        expectEqual(engine.voiceCount, 1)
    }
    @Test @MainActor func testAutomaticInAndNaturalEndOut() async throws {
        let engine = SoundEngine(offline: true); defer { engine.shutdown() }
        let cue = Cue(filePath: try fixture(seconds: 0.4).path, gainDB: 0, autoFadeIn: true, fadeInSeconds: 0.1,
                      autoFadeOut: true, fadeOutSeconds: 0.1, curve: .linear)
        await start(engine, [cue])
        let incoming = try render(engine, frames: 2400)
        expectGreaterThan(incoming, 0.015)
        expectLessThan(incoming, 0.04)
        expectEqual(try render(engine, frames: 9600), 0.05, accuracy: 0.0003)
        let outgoing = try render(engine, frames: 4800)
        expectGreaterThan(outgoing, 0.015)
        expectLessThan(outgoing, 0.04)
        _ = try render(engine, frames: 3000)
        expectFalse(engine.active.contains(cue.id))
        expectEqual(engine.decodedBytes, 0)
    }
    @Test @MainActor func testShortClipWithOverlappingConfiguredFadesIsAudible() async throws {
        let engine = SoundEngine(offline: true); defer { engine.shutdown() }
        let cue = Cue(filePath: try fixture(seconds: 0.1).path, gainDB: 0, autoFadeIn: true, fadeInSeconds: 2,
                      autoFadeOut: true, fadeOutSeconds: 2, curve: .linear)
        await start(engine, [cue])
        expectGreaterThan(try render(engine, frames: 2400), 0.04)
        expectGreaterThan(try render(engine, frames: 1200), 0.015)
        _ = try render(engine, frames: 1600)
        expectTrue(engine.active.isEmpty)
    }
    @Test @MainActor func testManualFadeCancelsPreviousEnvelopeAndOwnsRemainingPlayback() async throws {
        let engine = SoundEngine(offline: true); defer { engine.shutdown() }
        let cue = Cue(filePath: try fixture(seconds: 0.4).path, gainDB: 0, autoFadeOut: true, fadeOutSeconds: 0.3, curve: .linear)
        await start(engine, [cue])
        _ = try render(engine, frames: 9600)
        engine.fadeOutAndStop(cue.id, seconds: 0.1)
        _ = try render(engine, frames: 1200)
        let before = engine.playingLevels[cue.id]!
        engine.fadeIn(cue.id, seconds: 0.05)
        expectEqual(engine.playingLevels[cue.id], before)
        _ = try render(engine, frames: 5000)
        expectTrue(engine.active.contains(cue.id))
        expectEqual(engine.playingLevels[cue.id], 1)
    }
    @Test @MainActor func testOneShotCompletionLoopingAndConfiguredToggleStop() async throws {
        let engine = SoundEngine(offline: true); defer { engine.shutdown() }
        let path = try fixture(seconds: 0.05).path
        let one = Cue(filePath: path, gainDB: 0)
        let loop = Cue(filePath: path, gainDB: 0, mode: .toggle, loop: true, autoFadeOut: true, fadeOutSeconds: 0.05)
        await start(engine, [one, loop])
        _ = try render(engine, frames: 5000)
        expectFalse(engine.active.contains(one.id))
        expectTrue(engine.active.contains(loop.id))
        engine.play(loop)
        expectTrue(engine.active.contains(loop.id))
        _ = try render(engine, frames: 3000)
        expectTrue(engine.active.isEmpty)
    }
    @Test @MainActor func testRetriggerStopAllAndPendingLoadCancellation() async throws {
        let engine = SoundEngine(offline: true); defer { engine.shutdown() }
        let cue = Cue(filePath: try fixture().path, loop: true)
        engine.play(cue)
        engine.stopAll()
        await engine.waitForLoads()
        await Task.yield()
        expectTrue(engine.active.isEmpty)
        expectTrue(engine.loading.isEmpty)
        engine.play(cue)
        engine.play(cue)
        await engine.waitForLoads()
        expectEqual(engine.voiceCount, 1)
        _ = try render(engine, frames: 1000)
        engine.play(cue)
        await engine.waitForLoads()
        expectEqual(engine.voiceCount, 1)
        engine.fadeAll(seconds: 0)
        expectEqual(engine.voiceCount, 0)
        expectEqual(engine.decodedBytes, 0)
    }
    @Test @MainActor func testInvalidMediaAndPreflightReportErrorsWithoutVoices() async throws {
        let engine = SoundEngine(offline: true); defer { engine.shutdown() }
        let bad = Cue(filePath: "/nonexistent/stagecue.wav")
        engine.play(bad)
        await engine.waitForLoads()
        expectFalse(engine.errors.isEmpty)
        expectTrue(engine.active.isEmpty)
        let multi = Cue(filePath: try fixture(channels: 4).path)
        engine.play(multi)
        await engine.waitForLoads()
        expectEqual(engine.voiceCount, 0)
        var project = SoundProject()
        project.cues[0] = bad
        project.cues[1] = multi
        let warnings = await engine.preflight(project)
        expectEqual(warnings.count, 2)
    }
    @Test @MainActor func testRepeatedRetriggersReleaseNodesAndDecodedBuffers() async throws {
        let engine = SoundEngine(offline: true); defer { engine.shutdown() }
        let baseNodes = engine.attachedNodeCount
        let cue = Cue(filePath: try fixture(seconds: 0.05).path, loop: true)
        for _ in 0..<100 {
            engine.play(cue)
            await engine.waitForLoads()
            expectEqual(engine.attachedNodeCount, baseNodes + 3)
            _ = try render(engine, frames: 256)
            engine.stop(cue.id)
            expectEqual(engine.attachedNodeCount, baseNodes)
            expectEqual(engine.decodedBytes, 0)
        }
        expectTrue(engine.errors.isEmpty)
    }
    @Test @MainActor func testMixedSampleRatesAndMonoStereoAreFinite() async throws {
        let engine = SoundEngine(offline: true); defer { engine.shutdown() }
        let mono = Cue(filePath: try fixture(rate: 44_100, channels: 1).path, gainDB: -6, loop: true)
        let stereo = Cue(filePath: try fixture(rate: 96_000).path, gainDB: -6, bus: 5, loop: true)
        await start(engine, [mono, stereo])
        let sample = try render(engine, frames: 4096)
        expectTrue(sample.isFinite)
        expectGreaterThan(sample, 0.02)
        expectLessThan(sample, 0.06)
    }
    @Test @MainActor func testConfigurationChangeStopsWithoutUnexpectedRestart() async throws {
        let engine = SoundEngine(offline: true); defer { engine.shutdown() }
        let cue = Cue(filePath: try fixture().path, loop: true)
        await start(engine, [cue])
        engine.handleConfigurationChange()
        expectFalse(engine.isRunning)
        expectTrue(engine.active.isEmpty)
        expectEqual(engine.decodedBytes, 0)
        expectFalse(engine.errors.isEmpty)
        engine.clearErrors()
        await start(engine, [cue])
        expectTrue(engine.isRunning)
    }
    @Test @MainActor func testMixBoundaryAcceptsShortArraysAndInvalidNumbers() {
        let engine = SoundEngine(offline: true); defer { engine.shutdown() }
        engine.applyMix(SoundProject(busDB: [], masterDB: .nan))
        expectTrue(engine.errors.isEmpty)
    }
}

@Suite(.serialized)
struct SafetyAudioTests {
    private let temporaryFiles = TemporaryFiles()
    private func silence(seconds: Double) throws -> URL {
        let url = temporaryFiles.directory.appendingPathComponent("silence-\(UUID()).wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let frames = AVAudioFrameCount(seconds * 48_000)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for channel in 0..<2 { buffer.floatChannelData![channel].initialize(repeating: 0, count: Int(frames)) }
        var settings = format.settings
        settings[AVLinearPCMIsNonInterleaved] = false
        let file = try AVAudioFile(forWriting: url, settings: settings)
        try file.write(from: buffer)
        return url
    }
    @Test @MainActor func testMemoryBudgetRejectsAdditionalCueWithoutInterruptingExistingCue() async throws {
        let path = try silence(seconds: 0.1).path
        let engine = SoundEngine(offline: true, memoryBudgetBytes: 40_000); defer { engine.shutdown() }
        let first = Cue(filePath: path, loop: true)
        let second = Cue(filePath: try silence(seconds: 0.1).path, loop: true)
        engine.play(first)
        await engine.waitForLoads()
        expectTrue(engine.active.contains(first.id))
        engine.play(second)
        await engine.waitForLoads()
        expectTrue(engine.active.contains(first.id))
        expectFalse(engine.active.contains(second.id))
        expectFalse(engine.errors.isEmpty)
        expectTrue(engine.loading.isEmpty)
        engine.stopAll()
        expectEqual(engine.decodedBytes, 0)
        engine.clearErrors()
        engine.play(second)
        await engine.waitForLoads()
        expectTrue(engine.active.contains(second.id))
        expectTrue(engine.errors.isEmpty)
    }
    @Test @MainActor func testSimultaneousLoadsReserveMemoryBeforeDecode() async throws {
        let path = try silence(seconds: 0.1).path
        let engine = SoundEngine(offline: true, memoryBudgetBytes: 40_000); defer { engine.shutdown() }
        for i in 0..<8 {
            let copy = temporaryFiles.directory.appendingPathComponent("unique-budget-\(i).wav")
            try FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: copy)
            engine.play(Cue(filePath: copy.path, loop: true))
        }
        await engine.waitForLoads()
        expectEqual(engine.voiceCount, 1)
        expectTrue(engine.loading.isEmpty)
        expectTrue(engine.decodedBytes <= 40_000)
        expectEqual(engine.errors.count, 7)
    }
    @Test func testSparseOversizedClipIsRejectedBeforeAllocation() async throws {
        let url = temporaryFiles.directory.appendingPathComponent("large.wav")
        let byteCount: UInt32 = 270 * 1024 * 1024
        var header = Data()
        func text(_ string: String) { header.append(Data(string.utf8)) }
        func u16(_ value: UInt16) { var v = value.littleEndian; withUnsafeBytes(of: &v) { header.append(contentsOf: $0) } }
        func u32(_ value: UInt32) { var v = value.littleEndian; withUnsafeBytes(of: &v) { header.append(contentsOf: $0) } }
        text("RIFF"); u32(byteCount + 36); text("WAVEfmt "); u32(16)
        u16(1); u16(2); u32(48_000); u32(192_000); u16(4); u16(16)
        text("data"); u32(byteCount)
        try header.write(to: url)
        let file = try FileHandle(forWritingTo: url)
        try file.truncate(atOffset: UInt64(byteCount) + 44); try file.close()
        expectThrows(try MediaLoader.inspect(url.path))
        // A file above the old 64 MiB decoded limit is now accepted.
        let smallerBytes: UInt32 = 40 * 1024 * 1024
        var riffSize = (smallerBytes + 36).littleEndian
        var dataSize = smallerBytes.littleEndian
        withUnsafeBytes(of: &riffSize) { header.replaceSubrange(4..<8, with: $0) }
        withUnsafeBytes(of: &dataSize) { header.replaceSubrange(40..<44, with: $0) }
        try header.write(to: url)
        let smallerFile = try FileHandle(forWritingTo: url)
        try smallerFile.truncate(atOffset: UInt64(smallerBytes) + 44); try smallerFile.close()
        let (_, decodedSize) = try MediaLoader.inspect(url.path)
        expectEqual(decodedSize, Int(smallerBytes) * 2)
        let decoded = try await MediaLoader().load(url.path)
        expectEqual(decoded.bytes, decodedSize)
        expectTrue(decoded.frameCount > 0)
    }
    @Test @MainActor func testLiveCompletionAndTimerFadesUsingSilentAudio() async throws {
        let engine = SoundEngine(); defer { engine.shutdown() }
        expectTrue(engine.isRunning, engine.errors.joined(separator: "\n"))
        let one = Cue(filePath: try silence(seconds: 0.05).path)
        engine.play(one)
        await engine.waitForLoads()
        expectTrue(engine.active.contains(one.id))
        try await Task.sleep(for: .milliseconds(300))
        expectFalse(engine.active.contains(one.id))
        let loop = Cue(filePath: try silence(seconds: 0.05).path, loop: true)
        engine.play(loop)
        await engine.waitForLoads()
        engine.fadeToSilence(loop.id, seconds: 0.05)
        try await Task.sleep(for: .milliseconds(150))
        expectTrue(engine.active.contains(loop.id))
        expectEqual(engine.playingLevels[loop.id], 0)
        engine.fadeIn(loop.id, seconds: 0.05)
        try await Task.sleep(for: .milliseconds(150))
        expectEqual(engine.playingLevels[loop.id], amplitude(loop.gainDB))
        engine.fadeOutAndStop(loop.id, seconds: 0.05)
        try await Task.sleep(for: .milliseconds(150))
        expectTrue(engine.active.isEmpty)
        expectEqual(engine.decodedBytes, 0)
    }
}
