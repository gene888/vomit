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
    private func image(_ name: String, color: CIColor, type: UTType = .png) throws -> URL {
        let url = files.directory.appendingPathComponent(name).appendingPathExtension(type == .png ? "png" : "jpg")
        let picture = CIContext().createCGImage(CIImage(color: color).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 48)), from: CGRect(x: 0, y: 0, width: 64, height: 48))!
        let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, picture, nil)
        expectTrue(CGImageDestinationFinalize(destination))
        return url
    }
    private func movie(_ name: String, mp4: Bool = false) async throws -> URL {
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
            context.render(CIImage(color: CIColor(red: 0.2, green: 0.4, blue: 0.8)).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 48)), to: pixel!)
            expectTrue(adaptor.append(pixel!, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        if let error = writer.error { throw error }
        return url
    }
    @Test func schemaMigratesAudioAndRoundTripsVisualSettings() throws {
        var old = try JSONDecoder().decode(SoundProject.self, from: Data("{\"schemaVersion\":1,\"cues\":[{\"title\":\"Audio\"}]}".utf8))
        old.normalize()
        expectEqual(old.schemaVersion, 2); expectEqual(old.cues[0]?.kind, .audio)
        old.cues[31] = Cue(title: "Video", filePath: "/show/movie.mov", loop: true, kind: .video, transition: .cut, videoFadeIn: 2, videoFadeOut: 4, soundtrackDB: -18)
        old.backgroundPath = "/show/background.png"
        let url = files.directory.appendingPathComponent("show.json")
        try ProjectStore.save(old, to: url)
        let copy = try ProjectStore.load(from: url).0
        expectEqual(copy, old)
        expectThrows(try JSONDecoder().decode(SoundProject.self, from: Data("{\"schemaVersion\":3}".utf8)))
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
        expectEqual(video.retainedPlayerItems, 1)
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
        video.stop(); expectEqual(video.retainedPlayerItems, 0)
        expectTrue(audio.active.contains(sound.id))
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

}
