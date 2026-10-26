#if STAGECUE_PROFILING
import AppKit
import AVFoundation
import CoreImage
import SwiftUI
@testable import StageCue

/// Local, repeatable 1080p30 fixtures. Atmospheric motion and a precise moving bar
/// exercise different perceptual failure modes; neither is licensed stock footage.
@MainActor enum VideoLoopBaseline {
    static func movie(root: URL, atmosphere: Bool, seconds: Int) async throws -> URL {
        let url = root.appendingPathComponent("\(atmosphere ? "atmosphere" : "motion")-\(seconds)s.mp4")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 1920, AVVideoHeightKey: 1080,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 8_000_000, AVVideoExpectedSourceFrameRateKey: 30, AVVideoMaxKeyFrameIntervalKey: 30]])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 1920, kCVPixelBufferHeightKey as String: 1080])
        writer.add(input); guard writer.startWriting() else { throw writer.error! }; writer.startSession(atSourceTime: .zero)
        let context = CIContext(), bounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let noise = CIFilter(name: "CIRandomGenerator")!.outputImage!.cropped(to: CGRect(x: -240, y: -240, width: 2400, height: 1600))
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 24])
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0, kCIInputContrastKey: 2.5, kCIInputBrightnessKey: -0.38])
        for frame in 0..<(seconds * 30) {
            let deadline = stamp() + 15
            while !input.isReadyForMoreMediaData {
                guard stamp() < deadline else { throw MediaIssue(message: "Loop fixture writer stalled") }
                try await Task.sleep(for: .milliseconds(2))
            }
            var pixel: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pixel) == kCVReturnSuccess, let pixel else { throw MediaIssue(message: "Loop fixture allocation") }
            let phase = Double(frame) / Double(seconds * 30) * 2 * .pi
            let picture: CIImage
            if atmosphere {
                // Closed elliptical advection: first/last frames are adjacent in motion.
                picture = noise.transformed(by: CGAffineTransform(translationX: sin(phase) * 180, y: cos(phase) * 140)).cropped(to: bounds)
            } else {
                let base = CIImage(color: CIColor(red: 0.03, green: 0.04, blue: 0.09)).cropped(to: bounds)
                let x = Double(frame) / Double(seconds * 30) * 1920
                let bar = CIImage(color: .white).cropped(to: CGRect(x: x, y: 0, width: 16, height: 1080))
                let wrapped = bar.transformed(by: CGAffineTransform(translationX: -1920, y: 0))
                picture = wrapped.composited(over: bar.composited(over: base)).cropped(to: bounds)
            }
            context.render(picture, to: pixel)
            guard adaptor.append(pixel, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)) else { throw writer.error! }
        }
        input.markAsFinished(); await writer.finishWriting(); if let error = writer.error { throw error }
        return url
    }
    static func measure() async throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["STAGECUE_PROFILE_ROOT"]!)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var result: [String: Any] = ["status": "running", "date": ISO8601DateFormatter().string(from: Date()), "pid": ProcessInfo.processInfo.processIdentifier,
            "configuration": "release -O native AppKit; 1080p30 H264; MainView preview plus 960x540 program canvas; software CALayer assignment, not physical scanout"]
        func save() throws { try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("video-loops.json"), options: .atomic) }
        try save()
        print("LOOP: generating 30 fps fixtures"); fflush(stdout)
        let atmosphere = try await movie(root: root, atmosphere: true, seconds: 4)
        let motion = try await movie(root: root, atmosphere: false, seconds: 4)
        let long = try await movie(root: root, atmosphere: false, seconds: 32)
        let wav = root.appendingPathComponent("loop-tone.wav")
        if !FileManager.default.fileExists(atPath: wav.path) {
            let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
            let file = try AVAudioFile(forWriting: wav, settings: format.settings)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48000)!; buffer.frameLength = 48000
            for c in 0..<2 { for n in 0..<48000 { buffer.floatChannelData![c][n] = Float(sin(Double(n) * 2 * .pi * 220 / 48000)) * 0.001 } }
            for _ in 0..<4 { try file.write(from: buffer) }
        }
        let soundtrack = root.appendingPathComponent("motion-soundtrack.mp4")
        if !FileManager.default.fileExists(atPath: soundtrack.path) {
            let composition = AVMutableComposition()
            let video = AVURLAsset(url: motion), audio = AVURLAsset(url: wav)
            let vt = try await video.loadTracks(withMediaType: .video)[0], at = try await audio.loadTracks(withMediaType: .audio)[0]
            try composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!.insertTimeRange(CMTimeRange(start: .zero, duration: CMTime(seconds: 4, preferredTimescale: 30)), of: vt, at: .zero)
            try composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!.insertTimeRange(CMTimeRange(start: .zero, duration: CMTime(seconds: 4, preferredTimescale: 48000)), of: at, at: .zero)
            let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality)!
            export.outputURL = soundtrack; export.outputFileType = .mp4
            await export.export(); if let error = export.error { throw error }
        }
        let state = ShowState(autosaveURL: root.appendingPathComponent("loop-autosave.json")), video = state.video
        defer { state.scheduler.reset(); state.sound.shutdown(); video.shutdown(); state.output.close() }
        state.project.additionalPages = [SoundboardPage(title: "Second page")]; state.project.masterDB = -60; state.sound.applyMix(state.project)
        let window = NSWindow(contentRect: NSRect(x: 40, y: 40, width: 1220, height: 960), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: MainView().environmentObject(state)); window.orderFront(nil)
        let output = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 960, height: 540), styleMask: [.titled], backing: .buffered, defer: false)
        let canvas = VisualCanvas(frame: NSRect(x: 0, y: 0, width: 960, height: 540)); canvas.connect(video); output.contentView = canvas; output.orderFront(nil)
        defer { window.orderOut(nil); output.orderOut(nil) }
        var cases: [[String: Any]] = []
        // Two repetitions of each type; total timed playback exceeds four minutes.
        let probe = ProcessInfo.processInfo.environment["STAGECUE_PROFILE_MODE"] == "video-loop-probe"
        let fixtures = probe ? [atmosphere, motion] : [atmosphere, motion, long, soundtrack, atmosphere, motion]
        for (index, url) in fixtures.enumerated() {
            print("LOOP: case \(index) \(url.lastPathComponent)"); fflush(stdout)
            video.stop(); state.sound.stopAll(); state.scheduler.reset()
            var cue = Cue(filePath: url.path, loop: true, kind: .video, transition: .cut); cue.soundtrackDB = -60
            state.project.cues[0] = cue
            for i in 1...4 { let c = Cue(filePath: wav.path, loop: true); state.project.cues[i] = c; state.sound.play(c) }
            await state.sound.waitForLoads()
            video.play(cue); await video.waitForLoad(); try await Task.sleep(for: .seconds(1))
            guard video.error.isEmpty else { throw MediaIssue(message: video.error) }
            var decoded: [[String: Double]] = [], presented: [[String: Double]] = [], loops: [[String: Any]] = [], samples: [[String: Double]] = []
            var latest: (CGImage, Double, Double)?; var lastImage: CGImage?
            video.profileDecodedImage = { image, pts, host in latest = (image, pts, host); decoded.append(["pts": pts, "host": host]) }
            video.profileLoop = { phase, host, cost in loops.append(["phase": phase, "host": host, "costMs": cost * 1000]) }
            var missing = 0
            canvas.profilePresentation = { image, host in
                guard let image else { missing += 1; return }
                guard image !== lastImage else { return }; lastImage = image
                if let latest, latest.0 === image { presented.append(["pts": latest.1, "host": host, "decodedHost": latest.2]) }
            }
            let began = stamp(), cpu = processCPU(), duration = probe ? 20.0 : (url == long ? 70.0 : 36.0)
            var nextAutomation = began, nextSample = began
            while stamp() - began < duration {
                if stamp() >= nextAutomation {
                    let group = CueGroup(actions: (0..<6).map { GroupAction(kind: .bus, delay: Double($0) * 0.08, levelDB: -18 + Double($0), bus: $0) })
                    _ = state.scheduler.launch(group); nextAutomation += 3
                    state.changePage(1 - state.page)
                }
                if stamp() >= nextSample { var sample = memory(); sample["host"] = stamp(); sample["items"] = Double(video.retainedPlayerItems); samples.append(sample); nextSample += 5 }
                try await Task.sleep(for: .milliseconds(20))
            }
            let elapsed = stamp() - began
            video.profileDecodedImage = nil; video.profileLoop = nil; canvas.profilePresentation = nil
            cases.append(["name": url.lastPathComponent, "index": index, "elapsed": elapsed, "cpuPercentOneCore": (processCPU()-cpu)/elapsed*100,
                "decoded": decoded, "presented": presented, "loops": loops, "missingCanvasUpdates": missing, "memory": samples,
                "videoError": video.error, "audioErrors": state.sound.errors, "voices": state.sound.voiceCount])
            result["cases"] = cases; try save()
        }
        video.stop(); state.sound.stopAll(); try await Task.sleep(for: .seconds(2))
        result["memoryAfterStop"] = memory(); result["itemsAfterStop"] = video.retainedPlayerItems
        result["status"] = "complete"; try save(); print("LOOP: complete"); fflush(stdout)
    }
}
#endif
