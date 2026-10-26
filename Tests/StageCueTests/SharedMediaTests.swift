import Foundation
import AVFoundation
import Testing
@testable import StageCue

#if DEBUG || STAGECUE_PROFILING
private final class DecodeGate: @unchecked Sendable {
    let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var entered = false
    var waiting: Bool { lock.lock(); defer { lock.unlock() }; return entered }
    func blockOnce() {
        lock.lock(); if entered { lock.unlock(); return }; entered = true; lock.unlock()
        _ = semaphore.wait(timeout: .now() + 5)
    }
    func release() { semaphore.signal() }
}
#endif

@Suite(.serialized) struct SharedMediaTests {
    private let files = TemporaryFiles()
    @MainActor private func sample(_ sound: SoundEngine, blocks: Int = 32) throws -> Float {
        var last: Float = 0
        for _ in 0..<blocks { let b = try sound.render(frames: 128); last = b.floatChannelData![0][127] }
        return last
    }
    @Test @MainActor func simultaneousSameFileFitsOneBufferBudgetAndKeepsEightNodesIndependent() async throws {
        let fixture = AudioTests(), url = try fixture.fixture(seconds: 1)
        let sound = SoundEngine(offline: true, memoryBudgetBytes: 384000); defer { sound.shutdown() }
        var cues: [Cue] = []
        for n in 0..<8 { let c = Cue(filePath: url.path, gainDB: 0, bus: n % 6, loop: true); cues.append(c); sound.play(c) }
        await sound.waitForLoads()
        expectEqual(sound.voiceCount, 8); expectEqual(sound.attachedNodeCount, 40)
        let handles = cues.compactMap { sound.retainedMedia(for: $0.id) }
        defer { withExtendedLifetime(handles) {} }
        expectEqual(Set(handles.map(ObjectIdentifier.init)).count, 1)
        expectEqual(sound.decodedBytes, 384000); expectTrue(sound.errors.isEmpty)
        let stats = await sound.resourceSnapshot()
        expectEqual(stats.decodes, 1); expectEqual(stats.hits, 7); expectEqual(stats.uniqueBytes, 384000)
        expectEqual(try sample(sound), 0.4, accuracy: 0.0003)
        sound.pause(cues[0].id); expectEqual(try sample(sound), 0.35, accuracy: 0.0003)
        sound.fadeToSilence(cues[1].id, seconds: 0); expectEqual(try sample(sound), 0.3, accuracy: 0.0003)
        sound.stop(cues[2].id); expectEqual(try sample(sound), 0.25, accuracy: 0.0003)
        sound.resume(cues[0].id); expectEqual(try sample(sound), 0.3, accuracy: 0.0003)
        sound.stopAll(); expectEqual(sound.attachedNodeCount, 16)
        // Test-held handles deliberately own the allocation after voices stop.
        expectEqual((await sound.resourceSnapshot()).uniqueBytes, 384000)
    }
    @Test @MainActor func stoppingAndEvictingOneOwnerCannotDisposeOfAnotherVoicesPCM() async throws {
        let fixture = AudioTests(), url = try fixture.fixture(seconds: 1)
        let sound = SoundEngine(offline: true, memoryBudgetBytes: 768000); defer { sound.shutdown() }
        let a = Cue(filePath: url.path, gainDB: 0, loop: true), b = Cue(filePath: url.path, gainDB: -6, bus: 3, loop: true)
        sound.play(a); sound.play(b); await sound.waitForLoads()
        weak var original = sound.retainedMedia(for: a.id)
        expectTrue(original === sound.retainedMedia(for: b.id))
        await sound.invalidateDecodedReuse(); sound.stop(a.id)
        expectTrue(original != nil); expectEqual(try sample(sound), 0.05 * amplitude(-6), accuracy: 0.0003)
        // Lookup eviction creates a new allocation, but must still charge the old live buffer.
        let c = Cue(filePath: url.path, gainDB: 0, loop: true)
        sound.play(c); await sound.waitForLoads()
        expectTrue(original !== sound.retainedMedia(for: c.id)); expectEqual(sound.decodedBytes, 768000)
        let d = Cue(filePath: try fixture.fixture(seconds: 1).path, loop: true)
        sound.play(d); await sound.waitForLoads(); expectTrue(sound.failed.contains(d.id))
        sound.stop(b.id); sound.stop(c.id)
        for _ in 0..<100 where original != nil { try await Task.sleep(for: .milliseconds(5)) }
        expectTrue(original == nil); expectEqual((await sound.resourceSnapshot()).uniqueBytes, 0)
    }
    @Test @MainActor func samePathReplacementAndRelinkKeepExistingPCMUnchanged() async throws {
        let fixture = AudioTests(), url = try fixture.fixture(seconds: 1, value: 0.05), other = try fixture.fixture(seconds: 1, value: 0.1)
        let sound = SoundEngine(offline: true); defer { sound.shutdown() }
        let a = Cue(filePath: url.path, gainDB: 0, loop: true)
        sound.play(a); await sound.waitForLoads()
        weak var old = sound.retainedMedia(for: a.id)
        let date = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as! Date
        // In-place same-size rewrite, then restore mtime. Change-time still invalidates.
        try Data(contentsOf: other).write(to: url)
        try FileManager.default.setAttributes([.modificationDate:date], ofItemAtPath: url.path)
        let b = Cue(filePath: url.path, gainDB: 0, loop: true)
        sound.play(b); await sound.waitForLoads()
        expectTrue(old !== sound.retainedMedia(for: b.id))
        expectEqual(try sample(sound), 0.15, accuracy: 0.0003)
        var relinked = a; relinked.filePath = other.path
        sound.play(relinked); await sound.waitForLoads()
        expectEqual(try sample(sound), 0.2, accuracy: 0.0003)
        sound.stopAll()
    }
    @Test @MainActor func symlinkUsesCanonicalSourceAndShutdownDoesNotRetainIdleMedia() async throws {
        let fixture = AudioTests(), url = try fixture.fixture(seconds: 1)
        let alias = files.directory.appendingPathComponent("alias.wav")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: url)
        let sound = SoundEngine(offline: true)
        let a = Cue(filePath: url.path, loop: true), b = Cue(filePath: alias.path, loop: true)
        sound.play(a); sound.play(b); await sound.waitForLoads()
        expectTrue(sound.retainedMedia(for: a.id) === sound.retainedMedia(for: b.id))
        weak var media = sound.retainedMedia(for: a.id)
        sound.handleConfigurationChange(); expectEqual(sound.voiceCount, 0); expectEqual(sound.attachedNodeCount, 16)
        sound.clearErrors(); sound.play(a); await sound.waitForLoads(); expectEqual(sound.voiceCount, 1)
        sound.shutdown()
        for _ in 0..<100 where media != nil { try await Task.sleep(for: .milliseconds(5)) }
        expectTrue(media == nil); expectEqual((await sound.resourceSnapshot()).uniqueBytes, 0)
    }
    @Test @MainActor func newlyStartedPlayerHasItsOwnPositionInSharedRamp() async throws {
        let url = files.directory.appendingPathComponent("ramp.wav")
        let f = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        var settings = f.settings; settings[AVLinearPCMIsNonInterleaved] = false
        let b = AVAudioPCMBuffer(pcmFormat: f, frameCapacity: 48000)!; b.frameLength = 48000
        for ch in 0..<2 { for n in 0..<48000 { b.floatChannelData![ch][n] = Float(n) / 48000 * 0.1 } }
        try AVAudioFile(forWriting: url, settings: settings).write(from: b)
        let sound = SoundEngine(offline: true); defer { sound.shutdown() }
        let a = Cue(filePath: url.path, gainDB: 0, loop: true), c = Cue(filePath: url.path, gainDB: 0, loop: true)
        sound.play(a); await sound.waitForLoads(); _ = try sample(sound, blocks: 75) // 0.2 seconds
        sound.play(c); await sound.waitForLoads()
        expectTrue(sound.retainedMedia(for: a.id) === sound.retainedMedia(for: c.id))
        let mixed = try sample(sound, blocks: 32)
        // At 0.2853s the first player contributes ~.02853, the newer one ~.00853.
        expectEqual(mixed, 0.03706, accuracy: 0.001)
    }
    @Test @MainActor func oneShotCompletionDoesNotStopAnotherPlayerSharingItsBuffer() async throws {
        let fixture = AudioTests(), url = try fixture.fixture(seconds: 0.1)
        let sound = SoundEngine(offline: true); defer { sound.shutdown() }
        let one = Cue(filePath:url.path,gainDB:0), loop = Cue(filePath:url.path,gainDB:0,loop:true)
        sound.play(one);sound.play(loop);await sound.waitForLoads()
        expectTrue(sound.retainedMedia(for:one.id) === sound.retainedMedia(for:loop.id))
        _ = try sample(sound,blocks:50)
        expectFalse(sound.active.contains(one.id));expectTrue(sound.active.contains(loop.id))
        expectEqual(try sample(sound),0.05,accuracy:0.0003)
        expectEqual(sound.decodedBytes,38400)
    }
    @Test @MainActor func replacingProjectReleasesSharedPlaybackAndPendingOwnership() async throws {
        let fixture = AudioTests(), url = try fixture.fixture(seconds:1)
        let state = ShowState(autosaveURL:files.directory.appendingPathComponent("isolated-autosave.json"))
        defer { state.stopAll();state.sound.shutdown();state.video.shutdown();state.output.close() }
        state.project.masterDB = -60;state.sound.applyMix(state.project)
        state.project.cues[0]=Cue(filePath:url.path,loop:true);state.project.cues[1]=Cue(filePath:url.path,loop:true)
        state.trigger(0);state.trigger(1);await state.sound.waitForLoads()
        weak var old = state.sound.retainedMedia(for:state.project.cues[0]!.id)
        expectTrue(old != nil);expectEqual(state.sound.voiceCount,2)
        let next=files.directory.appendingPathComponent("next.stagecue")
        try ProjectStore.save(SoundProject(title:"Next production"),to:next)
        await state.openProject(next).value
        for _ in 0..<100 where old != nil { try await Task.sleep(for:.milliseconds(5)) }
        expectEqual(state.project.title,"Next production");expectTrue(old == nil)
        expectEqual(state.sound.voiceCount,0);expectEqual(state.sound.attachedNodeCount,16)
        expectEqual((await state.sound.resourceSnapshot()).uniqueBytes,0)
    }
#if DEBUG || STAGECUE_PROFILING
    @Test func replacementDuringDecodeIsRejectedBeforePublication() async throws {
        let fixture = AudioTests(), a = try fixture.fixture(seconds: 1), b = try fixture.fixture(seconds: 1, value: 0.1)
        let loader = MediaLoader()
        await loader.setReadHooks(before: { try Data(contentsOf: b).write(to: a, options: .atomic) })
        do { _ = try await loader.load(a.path); Issue.record("Changed source was accepted") }
        catch { expectTrue(error.localizedDescription.contains("changed")) }
        expectEqual((await loader.snapshot()).uniqueBytes, 0)
    }
    @Test func cancelledDecoderCannotBypassUniqueReservationOrCancelAnotherCaller() async throws {
        let fixture = AudioTests(), a = try fixture.fixture(seconds: 1), b = try fixture.fixture(seconds: 1)
        let loader = MediaLoader(memoryBudgetBytes: 384000), gate = DecodeGate()
        await loader.setReadHooks(after: { gate.blockOnce() })
        let first = Task { try await loader.load(a.path) }
        let deadline = Date().addingTimeInterval(3)
        while !gate.waiting && Date() < deadline { try await Task.sleep(for: .milliseconds(2)) }
        expectTrue(gate.waiting); first.cancel()
        let next = Task { try await loader.load(b.path) }
        gate.release()
        do { _ = try await first.value; Issue.record("Cancelled decoder returned PCM") } catch is CancellationError {} catch { Issue.record("Unexpected cancellation error: \(error)") }
        let media = try await next.value
        expectEqual(media.bytes, 384000)
        let stats = await loader.snapshot(); expectEqual(stats.uniqueBytes, 384000); expectEqual(stats.peakBytes, 384000); expectEqual(stats.reservedBytes, 0)
    }
#endif
}
