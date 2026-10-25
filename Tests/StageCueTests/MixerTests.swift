import Foundation
import AVFoundation
import CoreImage
import AppKit
import Testing
@testable import StageCue

@Suite(.serialized) @MainActor struct MixerTests {
    private let files = TemporaryFiles()
    private func audio() throws -> URL {
        let url = files.directory.appendingPathComponent(UUID().uuidString + ".wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48000)!
        buffer.frameLength = 48000
        for c in 0..<2 { for i in 0..<48000 { buffer.floatChannelData![c][i] = 0.05 } }
        var settings = format.settings; settings[AVLinearPCMIsNonInterleaved] = false
        try AVAudioFile(forWriting: url, settings: settings).write(from: buffer)
        return url
    }
    private func sample(_ engine: SoundEngine, blocks: Int = 4) throws -> Float {
        var value: Float = 0
        for _ in 0..<blocks {
            let buffer = try engine.render(frames: 1024)
            value = buffer.floatChannelData![0][1023]
        }
        return value
    }
    private func close(_ state: ShowState) { state.stopAll(); state.sound.shutdown(); state.video.shutdown() }

    @Test func incrementalBusAndMasterProduceExpectedPCMWithoutGraphChanges() async throws {
        let engine = SoundEngine(offline: true); defer { engine.shutdown() }
        let path = try audio().path
        let a = Cue(filePath: path, gainDB: 0, bus: 0, loop: true)
        let b = Cue(filePath: path, gainDB: -6, bus: 1, loop: true)
        engine.play(a); engine.play(b); await engine.waitForLoads()
        let nodes = engine.attachedNodeCount, bytes = engine.decodedBytes
        expectEqual(try sample(engine), 0.05 * (1 + amplitude(-6)), accuracy: 0.0003)
        expectEqual(engine.setBusGain(0, decibels: -12), -12)
        expectEqual(try sample(engine), 0.05 * (amplitude(-12) + amplitude(-6)), accuracy: 0.0003)
        engine.setMasterGain(decibels: -6)
        engine.setBusGain(1, decibels: 6)
        let expected = 0.05 * (amplitude(-12) + amplitude(-6) * amplitude(6)) * amplitude(-6)
        expectEqual(try sample(engine), expected, accuracy: 0.0003)
        expectTrue(engine.setBusGain(-1, decibels: 0) == nil)
        expectTrue(engine.setBusGain(6, decibels: 0) == nil)
        expectEqual(try sample(engine), expected, accuracy: 0.0003)
        expectEqual(engine.attachedNodeCount, nodes); expectEqual(engine.decodedBytes, bytes)
        expectEqual(engine.voiceCount, 2)
    }

    @Test func boundsAttenuationRestoreAndEngineRestartUseTheSameMixerValues() async throws {
        let engine = SoundEngine(offline: true); defer { engine.shutdown() }
        let cue = Cue(filePath: try audio().path, gainDB: 0, loop: true)
        engine.applyMix(SoundProject(busDB: [.nan, .infinity, -90, 90], masterDB: .nan))
        engine.play(cue); await engine.waitForLoads()
        expectEqual(try sample(engine), 0.05, accuracy: 0.0003)
        expectEqual(engine.setBusGain(0, decibels: -90), -60)
        expectEqual(try sample(engine), 0.05 * amplitude(-60), accuracy: 0.00001)
        engine.setBusGain(0, decibels: 0)
        expectEqual(try sample(engine), 0.05, accuracy: 0.0003)
        engine.setMasterGain(decibels: -90)
        expectEqual(try sample(engine), 0.05 * amplitude(-60), accuracy: 0.00001)
        expectEqual(engine.setMasterGain(decibels: .infinity), 0)
        expectEqual(engine.setBusGain(0, decibels: .nan), 0)
        expectEqual(engine.setBusGain(0, decibels: 90), 6)
        expectEqual(try sample(engine), 0.05 * amplitude(6), accuracy: 0.0003)
        engine.setBusGain(0, decibels: -18); engine.setMasterGain(decibels: -9)
        engine.handleConfigurationChange()
        engine.play(cue); await engine.waitForLoads()
        expectEqual(try sample(engine), 0.05 * amplitude(-18) * amplitude(-9), accuracy: 0.0003)
    }

    @Test func rapidUpdatesAcrossSixBusesDoNotResetClipFadesOrSilence() async throws {
        let engine = SoundEngine(offline: true); defer { engine.shutdown() }
        let cue = Cue(filePath: try audio().path, gainDB: 0, loop: true, curve: .linear)
        engine.play(cue); await engine.waitForLoads()
        _ = try sample(engine)
        let nodes = engine.attachedNodeCount
        engine.fadeToSilence(cue.id, seconds: 1)
        for step in 0..<30 {
            for bus in 0..<6 { engine.setBusGain(bus, decibels: Double((step + bus) % 18) - 18) }
            _ = try sample(engine, blocks: 1)
        }
        let halfway = engine.playingLevels[cue.id]!
        expectTrue(halfway > 0 && halfway < 1)
        engine.setBusGain(0, decibels: -6) // A manual bus change must not seize the clip's fade.
        _ = try sample(engine, blocks: 30)
        expectEqual(engine.playingLevels[cue.id]!, 0, accuracy: 0.00001)
        expectEqual(try sample(engine), 0, accuracy: 0.00001)
        expectTrue(engine.active.contains(cue.id))
        engine.fadeIn(cue.id, seconds: 0.2)
        _ = try sample(engine, blocks: 12)
        expectEqual(try sample(engine), 0.05 * amplitude(-6), accuracy: 0.0003)
        engine.fadeOutAndStop(cue.id, seconds: 0.1)
        _ = try sample(engine, blocks: 6)
        expectEqual(engine.voiceCount, 0)
        expectEqual(nodes - engine.attachedNodeCount, 3)
    }

    @Test func groupRampsRespectPauseManualOverrideCancellationAndNewRuns() throws {
        let state = ShowState(autosaveURL: files.directory.appendingPathComponent("automation.json")); defer { close(state) }
        let clock = TestShowClock(), scheduler = ShowScheduler(automatic: false, now: { clock.value })
        scheduler.driver = state
        let group = CueGroup(actions: [-18.0, -12, -6, 0].enumerated().map {
            GroupAction(kind: .bus, delay: Double($0.offset), levelDB: $0.element, bus: 2)
        })
        let id = scheduler.launch(group)!
        expectEqual(state.project.busDB[2], -18)
        scheduler.pause(id); clock.value = 10; scheduler.tick()
        expectEqual(state.project.busDB[2], -18)
        scheduler.resume(id); clock.value = 11; scheduler.tick()
        expectEqual(state.project.busDB[2], -12)
        // The production manual control publishes an override to the production scheduler.
        // The injected test clock scheduler receives the same resource override explicitly.
        expectTrue(state.setBusGain(2, decibels: -24))
        scheduler.manualOverride("bus:2"); clock.value = 20; scheduler.tick()
        expectEqual(state.project.busDB[2], -24)
        let newer = scheduler.launch(group)!
        expectEqual(state.project.busDB[2], -18)
        scheduler.stop(newer, mode: .schedulesOnly); clock.value = 40; scheduler.tick()
        expectEqual(state.project.busDB[2], -18)
        let before = state.project
        expectFalse(state.setBusGain(6, decibels: 0)); expectFalse(state.setBusGain(-1, decibels: 0))
        expectEqual(state.project, before)
        expectThrows(try state.execute(GroupAction(kind: .bus, bus: 6)))
    }

    @Test func productionManualOverrideAndSequenceMixerActionsKeepProjectStateConsistent() async throws {
        let state = ShowState(autosaveURL: files.directory.appendingPathComponent("sequence.json")); defer { close(state) }
        let group = CueGroup(actions: [GroupAction(kind: .bus, levelDB: -18, bus: 1), GroupAction(kind: .bus, delay: 0.05, levelDB: -6, bus: 1)])
        state.scheduler.launch(group)
        expectTrue(state.setBusGain(1, decibels: -24))
        try await Task.sleep(for: .milliseconds(100))
        expectEqual(state.project.busDB[1], -24)
        let second = CueGroup(actions: [GroupAction(kind: .bus, levelDB: -9, bus: 3)])
        state.project.groups = [second]
        let sequence = CueSequence(steps: [SequenceStep(target: .group, groupID: second.id)])
        state.project.sequences = [sequence]; state.loadSequence(sequence.id); state.sequence.go()
        expectEqual(state.project.busDB[3], -9)
        state.sequence.stop(); state.setMasterGain(decibels: -12)
        expectEqual(state.project.busDB[1], -24); expectEqual(state.project.masterDB, -12)
    }

    @Test func autosavePersistsFinalGainAndProjectLoadRestoresActualAudio() async throws {
        let url = files.directory.appendingPathComponent("saved.json")
        let state = ShowState(autosaveURL: url); defer { close(state) }
        for step in 0..<200 { state.setBusGain(step % 6, decibels: Double(step % 60) - 60) }
        state.setBusGain(0, decibels: -13); state.setMasterGain(decibels: -7)
        let expected = state.project
        let until = ProcessInfo.processInfo.systemUptime + 5
        while true {
            if let saved = try? ProjectStore.load(from: url).0, saved == expected { break }
            guard ProcessInfo.processInfo.systemUptime < until else { throw MediaIssue(message: "Final mixer autosave not written") }
            try await Task.sleep(for: .milliseconds(20))
        }
        let restored = ShowState(autosaveURL: url); defer { close(restored) }
        expectEqual(restored.project.busDB, expected.busDB); expectEqual(restored.project.masterDB, -7)
        let engine = SoundEngine(offline: true); defer { engine.shutdown() }
        engine.applyMix(restored.project)
        engine.play(Cue(filePath: try audio().path, gainDB: 0, loop: true)); await engine.waitForLoads()
        expectEqual(try sample(engine), 0.05 * amplitude(-13) * amplitude(-7), accuracy: 0.0003)
    }
    @Test func liveAudioAndVisualPixelsContinueDuringRapidMixerChanges() async throws {
        let state = ShowState(autosaveURL: files.directory.appendingPathComponent("av.json")); defer { close(state) }
        let visuals = VideoTests()
        state.setMasterGain(decibels: -60)
        let cue = Cue(filePath: try audio().path, gainDB: -60, loop: true)
        state.sound.play(cue); await state.sound.waitForLoads()
        state.video.play(Cue(filePath: try visuals.image("MixerHold", color: .red).path, kind: .image, transition: .cut))
        await state.video.waitForLoad()
        let canvas = VisualCanvas(frame: CGRect(x: 0, y: 0, width: 64, height: 48))
        canvas.connect(state.video); canvas.needsLayout = true; canvas.layoutSubtreeIfNeeded()
        let frame = state.video.frontFrame
        let nodes = state.sound.attachedNodeCount
        state.sound.fadeToSilence(cue.id, seconds: 0.05)
        for step in 0..<120 { state.setBusGain(step % 6, decibels: -Double(step % 60)) }
        try await Task.sleep(for: .milliseconds(120))
        expectTrue(state.sound.active.contains(cue.id)); expectEqual(state.sound.attachedNodeCount, nodes)
        expectEqual(state.sound.playingLevels[cue.id]!, 0, accuracy: 0.00001)
        expectTrue(state.video.frontFrame === frame); expectFalse(state.video.blackout)
        var pixel = [UInt8](repeating: 0, count: 4)
        pixel.withUnsafeMutableBytes { bytes in
            let context = CGContext(data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.scaleBy(x: 1/64, y: 1/48); canvas.layer?.render(in: context)
        }
        expectTrue(pixel[0] > 200 && pixel[1] < 20 && pixel[2] < 20)
    }

}
