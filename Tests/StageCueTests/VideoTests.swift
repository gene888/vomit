import Foundation
import Testing
import AVFoundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers
@testable import StageCue

@Suite(.serialized)
struct VideoTests {
    private let files = TemporaryFiles()
    func image(_ name: String, color: CIColor, type: UTType = .png) throws -> URL {
        let url = files.directory.appendingPathComponent(name).appendingPathExtension(type == .png ? "png" : "jpg")
        let picture = CIContext().createCGImage(CIImage(color: color).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 48)), from: CGRect(x: 0, y: 0, width: 64, height: 48))!
        let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, picture, nil)
        expectTrue(CGImageDestinationFinalize(destination))
        return url
    }
    func movie(_ name: String, mp4: Bool = false, finalFrameRed: Bool = false) async throws -> URL {
        let url = files.directory.appendingPathComponent(name).appendingPathExtension(mp4 ? "mp4" : "mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: mp4 ? .mp4 : .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 48])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 48])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error! }
        writer.startSession(atSourceTime: .zero)
        let context = CIContext()
        for frame in 0..<60 {
            var waited = 0
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(10)); waited += 1
                if waited > 500 { throw MediaIssue(message: "Fixture writer stalled") }
            }
            var pixel: CVPixelBuffer?
            expectEqual(CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pixel), kCVReturnSuccess)
            context.render(CIImage(color: finalFrameRed && frame == 59 ? .red : CIColor(red: 0.2, green: 0.4, blue: 0.8)).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 48)), to: pixel!)
            expectTrue(adaptor.append(pixel!, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        if let error = writer.error { throw error }
        return url
    }
    @Test @MainActor func queuedVisualFadeAndFadeFromBlackSurviveReadiness() async throws {
        let video = VideoEngine(); defer { video.shutdown() }
        let first = Cue(filePath: try image("Old", color: .red).path, kind: .image, transition: .cut)
        video.play(first); await video.waitForLoad()
        let next = Cue(filePath: try image("New", color: .blue).path, kind: .image, transition: .fade, videoFadeIn: 2)
        video.play(next); video.fadeCue(next.id, to: 0.25, seconds: 0)
        await video.waitForLoad()
        expectEqual(video.currentCue?.id, next.id); expectEqual(video.level, 0.25)
        expectEqual(video.activeIDs, Set([next.id])); expectTrue(video.backFrame == nil)
        video.stop(); expectTrue(video.frontFrame == nil)
    }
    @Test func schemaMigratesAudioAndRoundTripsVisualSettings() throws {
        var old = try JSONDecoder().decode(SoundProject.self, from: Data("{\"schemaVersion\":1,\"cues\":[{\"title\":\"Audio\"}]}".utf8))
        old.normalize()
        expectEqual(old.schemaVersion, 4); expectEqual(old.cues[0]?.kind, .audio)
        expectEqual(old.cues[0]?.holdLastFrame, false)
        old.cues[31] = Cue(title: "Video", filePath: "/show/movie.mov", loop: true, kind: .video, transition: .cut, videoFadeIn: 2, videoFadeOut: 4, soundtrackDB: -18, holdLastFrame: true)
        old.backgroundPath = "/show/background.png"
        let url = files.directory.appendingPathComponent("show.json")
        try ProjectStore.save(old, to: url)
        let copy = try ProjectStore.load(from: url).0
        expectEqual(copy, old)
        expectThrows(try JSONDecoder().decode(SoundProject.self, from: Data("{\"schemaVersion\":5}".utf8)))
    }
    @Test func dissolveCalculationsAndVisualNormalization() {
        let fade = VisualDissolve(start: 10, duration: 2, from: 0, to: 1)
        expectEqual(fade.value(at: 9), 0); expectEqual(fade.value(at: 11), 0.5); expectEqual(fade.value(at: 12), 1)
        expectFalse(fade.finished(at: 11)); expectTrue(fade.finished(at: 12))
        var cue = Cue(kind: .video, videoFadeIn: .infinity, videoFadeOut: -1, soundtrackDB: 100)
        cue.normalize()
        expectEqual(cue.videoFadeIn, 1); expectEqual(cue.videoFadeOut, 0); expectEqual(cue.soundtrackDB, 0)
    }
    @Test @MainActor func imagesCutCrossfadePauseFadeBlackoutAndMissingMedia() async throws {
        let video = VideoEngine(); defer { video.shutdown() }
        let first = Cue(filePath: try image("A", color: .red).path, kind: .image, transition: .cut)
        let second = Cue(filePath: try image("B", color: .blue, type: .jpeg).path, kind: .image, videoFadeIn: 2)
        video.play(first); await video.waitForLoad()
        expectEqual(video.currentCue?.id, first.id); expectTrue(video.frontFrame != nil)
        video.play(second); await video.waitForLoad()
        expectEqual(video.activeIDs, Set([first.id, second.id])); expectTrue(video.backFrame != nil)
        video.tick(now: CACurrentMediaTime() + 3)
        expectEqual(video.activeIDs, Set([second.id])); expectTrue(video.backFrame == nil)
        video.pause(); expectTrue(video.paused); video.resume(); expectFalse(video.paused)
        video.blackout = true; expectEqual(video.currentCue?.id, second.id)
        video.fade(to: 0, seconds: 0); expectEqual(video.level, 0); expectTrue(video.activeIDs.contains(second.id))
        video.fade(to: 1, seconds: 0); expectEqual(video.level, 1)
        video.play(Cue(filePath: "/missing/movie.mov", kind: .video)); await video.waitForLoad()
        expectEqual(video.currentCue?.id, second.id); expectFalse(video.error.isEmpty)
        video.stop(seconds: 1); video.tick(now: CACurrentMediaTime() + 2)
        expectTrue(video.activeIDs.isEmpty); expectTrue(video.frontFrame == nil)
    }
    @Test @MainActor func movAndMP4LoopPauseConcurrentAudioAndCleanup() async throws {
        let mov = try await movie("Movie"), mp4 = try await movie("MP4", mp4: true)
        let video = VideoEngine(); defer { video.shutdown() }
        let audio = SoundEngine(offline: true); defer { audio.shutdown() }
        let audioFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let pcm = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: 4800)!
        pcm.frameLength = 4800
        for channel in 0..<2 { pcm.floatChannelData![channel].initialize(repeating: 0, count: 4800) }
        let wav = files.directory.appendingPathComponent("audio.wav")
        var settings = audioFormat.settings; settings[AVLinearPCMIsNonInterleaved] = false
        try AVAudioFile(forWriting: wav, settings: settings).write(from: pcm)
        let sound = Cue(filePath: wav.path, loop: true)
        audio.play(sound); await audio.waitForLoads()
        let first = Cue(filePath: mov.path, loop: true, kind: .video, transition: .cut, soundtrackDB: -18)
        video.play(first); await video.waitForLoad()
        expectTrue(video.error.isEmpty, video.error); expectTrue(video.frontFrame != nil)
        expectTrue((1...3).contains(video.retainedPlayerItems))
        expectEqual(video.retainedVideoOutputs, video.retainedPlayerItems)
        expectTrue(abs(video.currentSoundtrackVolume - amplitude(-18)) < 0.0001)
        video.pause(); let frozen = video.time
        try await Task.sleep(for: .milliseconds(100))
        expectTrue(abs(video.time - frozen) < 0.03)
        video.resume()
        try await Task.sleep(for: .seconds(2.2))
        expectEqual(video.currentCue?.id, first.id); expectTrue(video.activeIDs.contains(first.id))
        video.play(Cue(filePath: mp4.path, kind: .video, transition: .cut)); await video.waitForLoad()
        expectTrue(video.error.isEmpty, video.error); expectEqual(video.retainedPlayerItems, 1)
        expectTrue(audio.active.contains(sound.id))
        expectTrue(try audio.render(frames: 512).frameLength > 0)
        video.stop(); expectEqual(video.retainedPlayerItems, 0); expectEqual(video.retainedVideoOutputs, 0)
        expectTrue(audio.active.contains(sound.id))
    }
    @Test @MainActor func repeatedLoopsKeepProgramPixelsAndRespectOperatorControls() async throws {
        let state = ShowState(autosaveURL: files.directory.appendingPathComponent("loop-controls.json"))
        defer { state.stopAll(); state.sound.shutdown(); state.video.shutdown() }
        let url = try await movie("LoopControls", mp4: true, finalFrameRed: true)
        let cue = Cue(filePath: url.path, loop: true, kind: .video, transition: .cut, holdLastFrame: true)
        state.project.cues[0] = cue
        state.project.additionalPages = [SoundboardPage(title: "Other")]
        let canvas = VisualCanvas(frame: CGRect(x: 0, y: 0, width: 64, height: 48))
        canvas.connect(state.video); canvas.needsLayout = true; canvas.layoutSubtreeIfNeeded()
        func pixel() -> [UInt8] {
            var rgba = [UInt8](repeating: 0, count: 4)
            rgba.withUnsafeMutableBytes { bytes in
                let cg = CGContext(data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                cg.scaleBy(x: 1 / 64, y: 1 / 48); canvas.layer?.render(in: cg)
            }
            return rgba
        }
        state.trigger(0); await state.video.waitForLoad()
        var previous = state.video.time, wraps = 0
        // Observe actual source-time resets and rendered nonblack pixels over two
        // boundaries, rather than treating an unchanged active-ID as proof of looping.
        for n in 0..<52 {
            try await Task.sleep(for: .milliseconds(100))
            let time = state.video.time
            if time < previous - 0.5 { wraps += 1 }; previous = time
            expectTrue(state.video.frontFrame != nil)
            expectTrue((1...3).contains(state.video.retainedPlayerItems))
            expectEqual(state.video.retainedVideoOutputs, state.video.retainedPlayerItems)
            expectTrue(!state.video.holdingLastFrame, "Loop takes precedence over hold-last-frame")
            let rgba = pixel(); expectTrue(rgba[0] > 30 || rgba[2] > 100, "Loop canvas unexpectedly black")
            if n == 15 { state.changePage(1); state.project.show.showMode = true }
            if n == 25 { state.changePage(0); state.project.show.showMode = false }
        }
        expectTrue(wraps >= 2); expectTrue(state.video.error.isEmpty)
        state.video.pause(); let frozen = state.video.frontFrame, time = state.video.time
        try await Task.sleep(for: .milliseconds(150))
        expectTrue(state.video.frontFrame === frozen); expectEqual(state.video.time, time, accuracy: 0.03)
        state.video.blackout = true; try await Task.sleep(for: .milliseconds(60))
        let black = pixel(); expectTrue(black[0] < 5 && black[2] < 5)
        state.video.blackout = false; state.video.resume()
        state.video.setSoundtrackDB(-18)
        expectEqual(Double(state.video.currentSoundtrackVolume), Double(amplitude(-18)), accuracy: 0.0001)
        let saved = files.directory.appendingPathComponent("loop-project.stagecue")
        try ProjectStore.save(state.project, to: saved)
        let reopened = try ProjectStore.load(from: saved).0
        expectEqual(reopened.cues[0]?.loop, true); expectEqual(reopened.cues[0]?.id, cue.id)
        state.video.play(Cue(filePath: try image("ReplaceLoop", color: .green).path, kind: .image, transition: .crossfade, videoFadeIn: 0.1))
        await state.video.waitForLoad(); try await Task.sleep(for: .milliseconds(250))
        expectEqual(state.video.currentCue?.kind, .image); expectTrue(state.video.backFrame == nil)
        let green = pixel(); expectTrue(green[1] > 200 && green[2] < 80)
        state.video.stop(); expectEqual(state.video.retainedPlayerItems, 0)
    }

    @Test @MainActor func soundtrackLoopsAndTwoSlotCrossfadesKeepAudioIndependent() async throws {
        let fixture = AudioTests(), wav = try fixture.fixture(seconds: 2)
        let source = AVURLAsset(url: try await movie("SoundtrackSource", mp4: true))
        let audio = AVURLAsset(url: wav), composition = AVMutableComposition()
        let vt = try await source.loadTracks(withMediaType: .video)[0]
        let at = try await audio.loadTracks(withMediaType: .audio)[0]
        let range = CMTimeRange(start: .zero, duration: CMTime(seconds: 2, preferredTimescale: 30))
        try composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!.insertTimeRange(range, of: vt, at: .zero)
        try composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!.insertTimeRange(range, of: at, at: .zero)
        let url = files.directory.appendingPathComponent("soundtrack-loop.mp4")
        let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality)!
        export.outputURL = url; export.outputFileType = .mp4; await export.export()
        if let error = export.error { throw error }
        let video = VideoEngine(), sound = SoundEngine(offline: true)
        defer { video.shutdown(); sound.shutdown() }
        sound.applyMix(SoundProject()); let cue = Cue(filePath: wav.path, gainDB: 0, loop: true)
        sound.play(cue); await sound.waitForLoads()
        let first = Cue(filePath: url.path, loop: true, kind: .video, transition: .cut, soundtrackDB: -60)
        video.play(first); await video.waitForLoad()
        video.setSoundtrackDB(-18)
        for _ in 0..<24 {
            try await Task.sleep(for: .milliseconds(100))
            expectEqual(Double(video.currentSoundtrackVolume), Double(amplitude(-18)), accuracy: 0.0001)
            expectTrue((1...3).contains(video.retainedPlayerItems)); expectTrue(video.frontFrame != nil)
        }
        let next = Cue(filePath: url.path, loop: true, kind: .video, transition: .crossfade, videoFadeIn: 1, soundtrackDB: -24)
        video.play(next); await video.waitForLoad()
        expectEqual(video.activeIDs, Set([first.id, next.id])); expectTrue(video.backFrame != nil)
        expectTrue((2...6).contains(video.retainedPlayerItems)); expectEqual(video.retainedVideoOutputs, video.retainedPlayerItems)
        video.pause(); expectTrue(video.paused); video.resume()
        try await Task.sleep(for: .milliseconds(1200))
        expectEqual(video.activeIDs, Set([next.id])); expectTrue(video.backFrame == nil)
        expectTrue((1...3).contains(video.retainedPlayerItems))
        video.fade(to: 0, seconds: 0, stop: true)
        expectEqual(video.retainedPlayerItems, 0); expectEqual(video.retainedVideoOutputs, 0)
        expectEqual(video.currentSoundtrackVolume, 0)
        expectTrue(sound.active.contains(cue.id))
        var last: Float = 0
        for _ in 0..<32 { let buffer = try sound.render(frames: 128); last = buffer.floatChannelData![0][127] }
        expectEqual(last, 0.05, accuracy: 0.0003)
    }

    @Test @MainActor func loopEndCancellationCannotRestartStoppedOrReplacementMedia() async throws {
        let video = VideoEngine(); defer { video.shutdown() }
        let loop = Cue(filePath: try await movie("CancelLoop", mp4: true).path, loop: true, kind: .video, transition: .cut)
        video.play(loop); await video.waitForLoad()
        try await Task.sleep(for: .milliseconds(1900))
        // Exercise cancellation close to end/seek completion, then rapidly reuse slots.
        for _ in 0..<4 { video.play(loop); video.stop() }
        let still = Cue(filePath: try image("ReplacementAfterLoop", color: .red).path, kind: .image, transition: .cut)
        video.play(still); await video.waitForLoad()
        let image = video.frontFrame
        try await Task.sleep(for: .milliseconds(350))
        expectEqual(video.currentCue?.id, still.id); expectTrue(video.frontFrame === image)
        expectEqual(video.retainedPlayerItems, 0)
        video.stop(); try await Task.sleep(for: .milliseconds(100))
        expectTrue(video.frontFrame == nil); expectTrue(video.activeIDs.isEmpty)
        expectEqual(video.retainedPlayerItems, 0)
    }

    @Test @MainActor func staleLoadsAndMixedMediaAssignmentsAreSafe() async throws {
        let state = ShowState(autosaveURL: files.directory.appendingPathComponent("autosave.json"))
        defer { state.sound.shutdown(); state.video.shutdown(); state.output.close() }
        let png = try image("Pad", color: .green)
        expectTrue(state.assignMedia([png], to: 12)); await state.waitForMediaAssignments()
        expectEqual(state.project.cues[12]?.kind, .image)
        state.trigger(12); await state.video.waitForLoad()
        let current = state.video.currentCue?.id
        state.video.play(Cue(filePath: "/missing.mov", kind: .video))
        state.video.play(Cue(filePath: png.path, kind: .image, transition: .cut))
        await state.video.waitForLoad()
        expectFalse(state.video.currentCue?.id == current)
        expectTrue(state.video.error.isEmpty)
        state.video.play(Cue(filePath: png.path, kind: .image))
        state.video.stop(); await state.video.waitForLoad()
        expectTrue(state.video.activeIDs.isEmpty)
    }
    @Test func displayPolicyNeverUsesOperatorAndClosesOnDisconnect() {
        expectEqual(OutputDisplayPolicy.eligible([1, 2, 3], operatorID: 1), [2, 3])
        expectFalse(OutputDisplayPolicy.shouldClose(2, connected: [1, 2], operatorID: 1))
        expectTrue(OutputDisplayPolicy.shouldClose(2, connected: [1], operatorID: 1))
        expectTrue(OutputDisplayPolicy.shouldClose(2, connected: [1, 2], operatorID: 2))
        expectEqual(OutputDisplayPolicy.eligible([1], operatorID: 1), [])
    }
    @Test @MainActor func oneShotEndsAndRepeatedStillTransitionsReleaseSlots() async throws {
        let url = try await movie("OneShot")
        let video = VideoEngine(); defer { video.shutdown() }
        video.play(Cue(filePath: url.path, kind: .video, transition: .cut, videoFadeOut: 0))
        await video.waitForLoad()
        expectTrue(video.error.isEmpty, video.error)
        try await Task.sleep(for: .seconds(2.3))
        expectTrue(video.activeIDs.isEmpty); expectEqual(video.retainedPlayerItems, 0)
        let picture = try image("Still", color: .red)
        for _ in 0..<25 {
            let cue = Cue(filePath: picture.path, kind: .image, transition: .cut)
            video.play(cue); await video.waitForLoad()
            expectEqual(video.activeIDs, Set([cue.id])); expectEqual(video.retainedPlayerItems, 0)
        }
        video.stop(); expectTrue(video.frontFrame == nil); expectTrue(video.backFrame == nil)
    }

    @Test @MainActor func backgroundAndPendingCueStopDoNotInterruptCurrentVisual() async throws {
        let video = VideoEngine(); defer { video.shutdown() }
        let path = try image("Background", color: .blue).path
        video.setBackground(path); await video.waitForBackground()
        expectTrue(video.background != nil)
        let current = Cue(filePath: path, kind: .image, transition: .cut)
        video.play(current); await video.waitForLoad()
        let pending = Cue(filePath: path, mode: .toggle, kind: .image)
        video.play(pending); expectEqual(video.loadingCueID, pending.id)
        video.stopCue(pending.id); await video.waitForLoad()
        expectEqual(video.currentCue?.id, current.id); expectFalse(video.loading)
        video.play(pending); video.play(pending); await video.waitForLoad()
        expectEqual(video.currentCue?.id, current.id)
        video.setBackground(""); await video.waitForBackground()
        expectTrue(video.background == nil)
    }

    @Test @MainActor func mixedPreflightCompletesWhileMovieIsPlaying() async throws {
        let state = ShowState(autosaveURL: files.directory.appendingPathComponent("preflight.json"))
        defer { state.sound.shutdown(); state.video.shutdown() }
        state.project.cues[0] = Cue(filePath: try image("Preflight", color: .red).path, kind: .image)
        state.project.cues[1] = Cue(filePath: try await movie("PreflightMovie").path, loop: true, kind: .video)
        state.trigger(1); await state.video.waitForLoad()
        state.check()
        for _ in 0..<1500 {
            if !state.checking { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        expectFalse(state.checking)
        expectTrue(state.preflightItems.isEmpty, state.preflightItems.joined(separator: "; "))
        expectTrue(state.video.activeIDs.contains(state.project.cues[1]!.id))
    }

    @Test @MainActor func heldFinalFrameSurvivesEndBlackoutAndCanCrossfadeOrStop() async throws {
        let url = try await movie("HoldEnd", finalFrameRed: true)
        let video = VideoEngine(); defer { video.shutdown() }
        let cue = Cue(filePath: url.path, kind: .video, transition: .cut, holdLastFrame: true)
        video.play(cue); await video.waitForLoad()
        expectTrue(video.error.isEmpty, video.error)
        try await Task.sleep(for: .seconds(2.3))
        expectEqual(video.currentCue?.id, cue.id)
        expectTrue(video.frontFrame != nil)
        expectTrue(video.activeIDs.contains(cue.id))
        expectEqual(video.retainedPlayerItems, 1)
        expectTrue(video.time > 1.9)
        if let frame = video.frontFrame {
            var pixel = [UInt8](repeating: 0, count: 4)
            pixel.withUnsafeMutableBytes { bytes in
                let context = CGContext(data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                context.draw(frame, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            }
            expectTrue(pixel[0] > 200 && pixel[2] < 80, "Held picture must be the red final frame, not an earlier blue frame")
        }
        video.blackout = true; video.blackout = false
        expectTrue(video.frontFrame != nil)
        video.pause(); video.resume()
        let next = Cue(filePath: try image("Next", color: .blue).path, kind: .image, videoFadeIn: 1)
        video.play(next); await video.waitForLoad()
        expectTrue(video.backFrame != nil)
        expectTrue(video.activeIDs.contains(cue.id))
        video.tick(now: CACurrentMediaTime() + 2)
        expectEqual(video.activeIDs, Set([next.id]))
        expectEqual(video.retainedPlayerItems, 0)
        video.play(cue); await video.waitForLoad()
        try await Task.sleep(for: .seconds(2.3))
        video.stop(seconds: 1); video.tick(now: CACurrentMediaTime() + 2)
        expectTrue(video.frontFrame == nil); expectTrue(video.activeIDs.isEmpty)
        expectEqual(video.retainedPlayerItems, 0)
    }

    @Test @MainActor func heldProgramPixelsSurviveAudioPadsGroupsSequencesAndPages() async throws {
        let state = ShowState(autosaveURL: files.directory.appendingPathComponent("persistent-program.json"))
        defer { state.stopAll(); state.sound.shutdown(); state.video.shutdown() }
        let audioFixtures = AudioTests()
        let wav = try audioFixtures.fixture(seconds: 8, value: 0)
        let heldCue = Cue(filePath: try await movie("PersistentEnd", finalFrameRed: true).path,
                          kind: .video, transition: .cut, holdLastFrame: true)
        state.project.cues[0] = heldCue
        for index in 1...3 { state.project.cues[index] = Cue(title: "Audio \(index)", filePath: wav.path, loop: true) }
        let projector = VisualCanvas(frame: CGRect(x: 0, y: 0, width: 64, height: 48))
        projector.connect(state.video); projector.needsLayout = true; projector.layoutSubtreeIfNeeded()
        func pixel() -> [UInt8] {
            var rgba = [UInt8](repeating: 0, count: 4)
            rgba.withUnsafeMutableBytes { bytes in
                let cg = CGContext(data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                   space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                cg.scaleBy(x: 1 / 64, y: 1 / 48)
                projector.layer?.render(in: cg)
            }
            return rgba
        }
        state.trigger(0); await state.video.waitForLoad()
        try await Task.sleep(for: .seconds(2.4))
        guard let retained = state.video.frontFrame else { Issue.record("No held final frame"); return }
        func assertHeld() async throws {
            try await Task.sleep(for: .milliseconds(60)) // Allow the shared output canvas to render published state.
            expectTrue(state.video.holdingLastFrame)
            expectEqual(state.video.currentCue?.id, heldCue.id)
            expectTrue(state.video.frontFrame === retained, "Held program must not be replaced by decoder polling or audio UI changes")
            let rgba = pixel()
            expectTrue(rgba[0] > 200 && rgba[2] < 80, "Projector canvas must retain the actual red final-frame pixels")
        }
        try await assertHeld()
        for index in 1...3 {
            state.trigger(index); await state.sound.waitForLoads()
            expectTrue(state.sound.active.contains(state.project.cues[index]!.id))
            try await assertHeld()
        }
        state.project.manualFadeSeconds = 0
        state.fadeDown(state.project.cues[1]!); state.fadeUp(state.project.cues[1]!)
        state.fadeStop(state.project.cues[1]!); state.stopCue(state.project.cues[2]!)
        state.fadeAudio(); try await assertHeld()

        let audioID = state.project.cues[1]!.id
        let group = CueGroup(title: "Audio only", actions: [
            GroupAction(cueID: audioID), GroupAction(kind: .fade, cueID: audioID, delay: 0.02, duration: 0.02, levelDB: -18),
            GroupAction(kind: .silence, cueID: audioID, delay: 0.05, duration: 0),
            GroupAction(kind: .pause, cueID: audioID, delay: 0.06), GroupAction(kind: .resume, cueID: audioID, delay: 0.08),
            GroupAction(kind: .stop, cueID: audioID, delay: 0.1)
        ])
        state.project.groups = [group]; state.project.cues[4] = Cue(kind: .group, groupID: group.id)
        state.project.show.showMode = true
        state.trigger(4); try await Task.sleep(for: .milliseconds(200)); try await assertHeld()
        expectTrue(state.scheduler.runs.contains { $0.definition.id == group.id && $0.state == .completed })
        let sequence = CueSequence(steps: [SequenceStep(cueID: audioID)])
        state.project.sequences = [sequence]; state.loadSequence(sequence.id); state.performShowCommand(.go)
        await state.sound.waitForLoads(); try await assertHeld()
        state.performShowCommand(.pause); state.performShowCommand(.pause); state.performShowCommand(.stop)
        try await assertHeld()
        state.addPage(); state.changePage(0); state.project.show.showMode = false; try await assertHeld()

        let next = Cue(filePath: try await movie("ReplacementLoop").path, loop: true, kind: .video, transition: .cut)
        state.video.play(next); await state.video.waitForLoad()
        expectEqual(state.video.currentCue?.id, next.id); expectFalse(state.video.holdingLastFrame)
        try await Task.sleep(for: .seconds(2.3))
        expectTrue(state.video.activeIDs.contains(next.id)); expectFalse(state.video.holdingLastFrame)
        let imageCue = Cue(filePath: try image("ExplicitStill", color: .blue).path, kind: .image, videoFadeIn: 0.05)
        state.video.play(imageCue); await state.video.waitForLoad(); state.video.tick(now: CACurrentMediaTime() + 1)
        try await Task.sleep(for: .milliseconds(60))
        expectEqual(state.video.currentCue?.id, imageCue.id); expectTrue(pixel()[2] > 200)
        state.performShowCommand(.blackout); try await Task.sleep(for: .milliseconds(60))
        expectTrue(state.video.blackout); expectTrue(pixel()[0] < 10 && pixel()[2] < 10)
        state.performShowCommand(.blackout)
        state.video.stop(); try await Task.sleep(for: .milliseconds(60))
        expectTrue(state.video.frontFrame == nil); expectTrue(pixel()[0] < 10 && pixel()[2] < 10)
    }

    @Test @MainActor func audioFadeLeavesExplicitVisualAutomationRunning() async throws {
        let state = ShowState(autosaveURL: files.directory.appendingPathComponent("audio-fade-only.json"))
        defer { state.stopAll(); state.sound.shutdown(); state.video.shutdown() }
        let fixtures = AudioTests()
        state.project.cues[0] = Cue(filePath: try image("RedProgram", color: .red).path, kind: .image, transition: .cut)
        state.project.cues[1] = Cue(filePath: try fixtures.fixture(seconds: 3, value: 0).path, loop: true)
        state.project.cues[2] = Cue(filePath: try image("BlueProgram", color: .blue).path, kind: .image, transition: .cut)
        state.trigger(0); await state.video.waitForLoad()
        state.project.manualFadeSeconds = 0
        let group = CueGroup(actions: [GroupAction(cueID: state.project.cues[1]!.id),
                                      GroupAction(kind: .cut, cueID: state.project.cues[2]!.id, delay: 0.15)])
        _ = state.scheduler.launch(group)
        await state.sound.waitForLoads()
        state.fadeAudio()
        expectEqual(state.video.currentCue?.id, state.project.cues[0]?.id)
        expectTrue(state.scheduler.activeRuns.contains { $0.definition.id == group.id })
        for _ in 0..<100 {
            if state.video.currentCue?.id == state.project.cues[2]?.id { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        expectEqual(state.video.currentCue?.id, state.project.cues[2]?.id)
        expectFalse(state.sound.active.contains(state.project.cues[1]!.id))
        state.fadeAll(); state.video.tick(now: CACurrentMediaTime() + 1)
        expectTrue(state.video.frontFrame == nil, "Explicit combined fade must still stop visuals")
    }

}
