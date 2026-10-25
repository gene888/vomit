#if STAGECUE_PROFILING
import AppKit
import AVFoundation
import Combine
import SwiftUI
import CoreImage
import Darwin
import Testing
@testable import StageCue

private func stamp() -> Double { CACurrentMediaTime() }
private func processCPU() -> Double {
    var r = rusage(); getrusage(RUSAGE_SELF, &r)
    return Double(r.ru_utime.tv_sec + r.ru_stime.tv_sec) + Double(r.ru_utime.tv_usec + r.ru_stime.tv_usec) / 1e6
}
private func memory() -> [String: Double] {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
    }
    return ["residentMiB": result == KERN_SUCCESS ? Double(info.resident_size) / 1048576 : -1,
            "footprintMiB": result == KERN_SUCCESS ? Double(info.phys_footprint) / 1048576 : -1]
}
private final class Onset: @unchecked Sendable {
    private let lock = NSLock()
    private var at: (render: Double, callback: Double, frames: Int, sampleRate: Double)?
    func clear() { lock.lock(); at = nil; lock.unlock() }
    func read() -> (render: Double, callback: Double, frames: Int, sampleRate: Double)? { lock.lock(); defer { lock.unlock() }; return at }
    func receive(_ buffer: AVAudioPCMBuffer, time: AVAudioTime) {
        guard let samples = buffer.floatChannelData else { return }
        var index: Int?
        for i in 0..<Int(buffer.frameLength) where abs(samples[0][i]) > 1e-9 { index = i; break }
        guard let index, time.isHostTimeValid else { return }
        let now = stamp()
        let render = AVAudioTime.seconds(forHostTime: time.hostTime) + Double(index) / buffer.format.sampleRate
        lock.lock(); if at == nil { at = (render, now, Int(buffer.frameLength), buffer.format.sampleRate) }; lock.unlock()
    }
}
@MainActor private final class TimingDriver: ShowPlaybackDriver {
    var observations: [(UUID, Double)] = []
    var commandCostsMs: [Double] = []
    var executeAction: ((GroupAction) throws -> OwnedPlayback?)?
    func resource(for action: GroupAction) throws -> String? { nil }
    func execute(_ action: GroupAction) throws -> OwnedPlayback? {
        observations.append((action.id, stamp()))
        let began = stamp()
        let playback = try executeAction?(action)
        if executeAction != nil { commandCostsMs.append((stamp()-began)*1000) }
        return playback
    }
    func status(_ playback: OwnedPlayback) -> PlaybackStatus { .completed }
    func stop(_ playback: OwnedPlayback, fade: Double) {}
    func pause(_ playback: OwnedPlayback) {}
    func resume(_ playback: OwnedPlayback) {}
}

/// Deliberately excluded from normal builds/tests. Run Scripts/prepare-performance-profile.sh.
@MainActor enum PerformanceBaseline {
    static func measure() async throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["STAGECUE_PROFILE_ROOT"]!)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var result: [String: Any] = ["date": ISO8601DateFormatter().string(from: Date()), "pid": ProcessInfo.processInfo.processIdentifier,
            "os": ProcessInfo.processInfo.operatingSystemVersionString, "logicalCPUs": ProcessInfo.processInfo.processorCount,
            "physicalMemoryGiB": Double(ProcessInfo.processInfo.physicalMemory) / 1073741824,
            "configuration": "SwiftPM release -O, STAGECUE_PROFILING; native AppKit host; actual MainView with built-in preview, engines and two additional VisualCanvas views", "status": "running"]
        result["canvasConfiguration"] = ["operatorPreviewPoints": [224, 126], "additionalProgramCanvasPoints": [960, 540], "additionalPreviewCanvasPoints": [480, 270]]
        func save() throws {
            try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("results.json"), options: .atomic)
        }
        try save()
        func progress(_ text: String) { print("PROFILE: \(text)"); fflush(stdout) }
        func wait(_ predicate: () -> Bool, timeout: Double = 15) async throws {
            let until = stamp() + timeout
            while !predicate() {
                guard stamp() < until else { throw MediaIssue(message: "Profile timeout") }
                try await Task.sleep(for: .milliseconds(1))
            }
        }
        func wav(_ name: String, seconds: Int) throws -> URL {
            let url = root.appendingPathComponent(name + ".wav")
            try? FileManager.default.removeItem(at: url)
            let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
            var settings = format.settings; settings[AVLinearPCMIsNonInterleaved] = false
            let file = try AVAudioFile(forWriting: url, settings: settings)
            let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48000)!
            b.frameLength = 48000
            for c in 0..<2 { for n in 0..<48000 { b.floatChannelData![c][n] = Float(sin(Double(n) * 2 * .pi * 440 / 48000)) * 0.01 } }
            for _ in 0..<seconds { try file.write(from: b) }
            return url
        }
        func movie(_ fps: Int) async throws -> URL {
            let url = root.appendingPathComponent("1080p\(fps).mp4")
            try? FileManager.default.removeItem(at: url)
            let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 1920, AVVideoHeightKey: 1080])
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 1920, kCVPixelBufferHeightKey as String: 1080])
            writer.add(input); guard writer.startWriting() else { throw writer.error! }; writer.startSession(atSourceTime: .zero)
            let context = CIContext()
            for frame in 0..<(fps * 8) {
                let deadline = stamp() + 15
                while !input.isReadyForMoreMediaData {
                    guard stamp() < deadline else { throw MediaIssue(message: "Writer stalled") }
                    try await Task.sleep(for: .milliseconds(2))
                }
                var pixel: CVPixelBuffer?
                guard CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pixel) == kCVReturnSuccess, let pixel else { throw MediaIssue(message: "Pixel allocation") }
                // Changing color + moving rectangle; synthetic, low spatial complexity, not camera footage.
                let base = CIImage(color: CIColor(red: Double(frame % fps) / Double(fps), green: 0.4, blue: 0.6)).cropped(to: CGRect(x: 0, y: 0, width: 1920, height: 1080))
                let block = CIImage(color: .white).cropped(to: CGRect(x: (frame * 13) % 1700, y: 200, width: 200, height: 400))
                context.render(block.composited(over: base), to: pixel)
                guard adaptor.append(pixel, withPresentationTime: CMTime(value: Int64(frame), timescale: Int32(fps))) else { throw writer.error! }
            }
            input.markAsFinished(); await writer.finishWriting(); if let error = writer.error { throw error }
            return url
        }
        progress("generating local fixtures")
        let short = try wav("one-second", seconds: 1), long = try wav("sixty-seconds", seconds: 60)
        let compressed = root.appendingPathComponent("sixty-seconds.m4a")
        try? FileManager.default.removeItem(at: compressed)
        let convert = Process(); convert.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        convert.arguments = [long.path, compressed.path, "-f", "m4af", "-d", "aac"]
        try convert.run(); convert.waitUntilExit(); guard convert.terminationStatus == 0 else { throw MediaIssue(message: "Audio conversion failed") }
        let v30 = try await movie(30), v60 = try await movie(60)
        result["fixtureBytes"] = try [short, long, compressed, v30, v60].reduce(into: [String: Int]()) { $0[$1.lastPathComponent] = (try FileManager.default.attributesOfItem(atPath: $1.path)[.size] as! NSNumber).intValue }
        result["memoryBeforeEngines"] = memory()
        try? FileManager.default.removeItem(at: root.appendingPathComponent("profile-autosave.json"))
        let state = ShowState(autosaveURL: root.appendingPathComponent("profile-autosave.json"))
        let sound = state.sound; let video = state.video
        var tapInstalled = true
        defer { if tapInstalled { sound.removeProfileOutput() }; state.scheduler.reset(); sound.shutdown(); video.shutdown(); state.output.close() }
        var mix = SoundProject(); mix.masterDB = -60; sound.applyMix(mix)
        let onset = Onset(); sound.profileOutput { onset.receive($0, time: $1) }
        result["audioConfiguration"] = sound.profileAudioConfiguration
        // Built-in operator preview plus two additional canvases provide a repeatable rendering stress load.
        // No user output window is touched.
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 960, height: 540), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "StageCue Performance Baseline — synthetic media"
        let operatorWindow = NSWindow(contentRect: NSRect(x: 20, y: 20, width: 1220, height: 960), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        operatorWindow.title = "StageCue isolated profiling operator UI"
        operatorWindow.contentView = NSHostingView(rootView: MainView().environmentObject(state))
        operatorWindow.orderFront(nil)
        defer { operatorWindow.orderOut(nil) }
        let program = VisualCanvas(frame: NSRect(x: 0, y: 0, width: 960, height: 540)); program.connect(video)
        window.contentView = program; window.makeKeyAndOrderFront(nil)
        let previewWindow = NSWindow(contentRect: NSRect(x: 100, y: 660, width: 480, height: 270), styleMask: [.titled], backing: .buffered, defer: false)
        let preview = VisualCanvas(frame: NSRect(x: 0, y: 0, width: 480, height: 270)); preview.connect(video)
        previewWindow.contentView = preview; previewWindow.orderFront(nil)
        defer { window.orderOut(nil); previewWindow.orderOut(nil) }
        try await Task.sleep(for: .seconds(1))
        result["memoryIdleEnginesAndCanvases"] = memory()
        progress("audio trigger-to-first-nonzero-mixer-buffer")
        var audioRows: [[String: Any]] = []
        for (url, count) in [(short, 20), (long, 10), (compressed, 10)] {
            var cue = Cue(filePath: url.path); cue.gainDB = 0
            state.project.cues[0] = cue
            try await Task.sleep(for: .milliseconds(500))
            for trial in 0..<count {
                sound.stopAll(); try await Task.sleep(for: .milliseconds(150)); onset.clear()
                var phases: [String: Double] = [:]
                sound.profilePhase = { id, phase in if id == cue.id { phases[phase] = stamp() } }
                let start = stamp(); state.trigger(0); await sound.waitForLoads(); let ready = stamp()
                try await wait({ onset.read() != nil || sound.failed.contains(cue.id) })
                guard let first = onset.read(), !sound.failed.contains(cue.id) else { throw MediaIssue(message: "Audio profile failed: \(sound.errors)") }
                audioRows.append(["file": url.lastPathComponent, "trial": trial, "loadAndGraphMs": (ready-start)*1000, "firstNonzeroMixerCallbackMs": (first.callback-start)*1000, "firstNonzeroRenderTimestampMs": (first.render-start)*1000, "tapFrames": first.frames, "tapSampleRate": first.sampleRate, "triggerToLoaderTaskMs": (phases["inspectBegin"]!-start)*1000, "inspectionAndDispatchMs": (phases["inspectComplete"]!-phases["inspectBegin"]!)*1000, "decodeMs": (phases["decodeComplete"]!-phases["decodeBegin"]!)*1000, "graphSetupMs": (phases["graphComplete"]!-phases["graphBegin"]!)*1000])
            }
        }
        sound.profilePhase = nil
        sound.stopAll(); result["audio"] = audioRows; try save()
        progress("large saved show: 1024 cues, 64 groups, 16 sequences")
        var show = SoundProject(); show.title = "Synthetic maximum-pad show"
        let cueList = (0..<1024).map { i -> Cue in
            var c = Cue(title: "Cue \(i)", filePath: i % 4 == 0 ? v30.path : long.path)
            c.kind = i % 4 == 0 ? .video : .audio; return c
        }
        show.cues = Array(cueList.prefix(32)).map { Optional($0) }
        show.additionalPages = (1..<32).map { page in SoundboardPage(title: "Page \(page+1)", cues: Array(cueList[(page*32)..<(page*32+32)]).map { Optional($0) }) }
        show.groups = (0..<64).map { g in CueGroup(title: "Group \(g)", actions: (0..<16).map { GroupAction(cueID: cueList[(g*16+$0)%1024].id, delay: Double($0)) }) }
        show.sequences = (0..<16).map { s in CueSequence(title: "Sequence \(s)", steps: (0..<32).map { SequenceStep(cueID: cueList[s*32+$0].id) }) }
        show = try await MediaLibrary().catalog(show, root: root)
        let projectURL = root.appendingPathComponent("LargeShow.stagecue")
        try ProjectStore.save(show, to: projectURL)
        let loadStart = stamp(); let loaded = try ProjectStore.load(from: projectURL).0; let loadMs = (stamp()-loadStart)*1000
        // Retain loaded project for subsequent workload, independent of original serialized construction.
        show = loaded
        state.project = show; state.project.masterDB = -60; state.sound.applyMix(state.project)
        state.projectRoot = root; state.resolveMediaAutomatically()
        try await wait({ !state.mediaBusy })
        try await Task.sleep(for: .seconds(2))
        result["largeShow"] = ["cues": show.allCues.count, "groups": show.groups.count, "sequences": show.sequences.count,
            "projectBytes": (try FileManager.default.attributesOfItem(atPath: projectURL.path)[.size] as! NSNumber).intValue,
            "loadMs": loadMs, "memory": memory()] as [String: Any]
        let idleStart = stamp(), idleCPU = processCPU()
        try await Task.sleep(for: .seconds(5))
        result["largeShowIdleCPUPercentOneCore"] = (processCPU()-idleCPU)/(stamp()-idleStart)*100
        progress("video first frame: 20 trials per format")
        var videoRows: [[String: Any]] = []
        for url in [v30, v60] {
            var cue = Cue(filePath: url.path, kind: .video, transition: .cut); cue.soundtrackDB = -60
            state.project.cues[0] = cue
            try await Task.sleep(for: .milliseconds(500))
            for trial in 0..<20 {
                video.stop(seconds: 0); try await Task.sleep(for: .milliseconds(80))
                let start = stamp(); state.trigger(0)
                try await wait({ video.frontFrame != nil || !video.error.isEmpty })
                guard video.frontFrame != nil else { throw MediaIssue(message: video.error) }
                let decoded = stamp()
                // Verify the actual output canvas has pixels; GPU scanout is not observable here.
                await Task.yield()
                let bitmap = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                bitmap.scaleBy(x: 1/960.0, y: 1/540.0)
                try await wait({
                    bitmap.clear(CGRect(x: 0, y: 0, width: 960, height: 540))
                    program.layer!.render(in: bitmap)
                    let pixels = bitmap.data!.assumingMemoryBound(to: UInt8.self)
                    return pixels[0] > 8 || pixels[1] > 8 || pixels[2] > 8
                })
                videoRows.append(["file": url.lastPathComponent, "trial": trial, "framePublishedMs": (decoded-start)*1000, "canvasRenderCompletedMs": (stamp()-start)*1000])
            }
        }
        result["videoStartup"] = videoRows; try save()
        let loops = (0..<8).map { i -> Cue in var c = Cue(title: "Loop \(i)", filePath: long.path); c.loop = true; c.bus = i%6; c.gainDB = -30; return c }
        for (index, cue) in loops.enumerated() { state.project.cues[index] = cue; sound.play(cue) }; await sound.waitForLoads()
        guard sound.voiceCount == 8 else { throw MediaIssue(message: "Expected eight voices") }
        result["memoryEight60SecondAudioVoices"] = memory().merging(["decodedAudioMiB": Double(sound.decodedBytes)/1048576]) { _, b in b }
        var visual = Cue(filePath: v30.path, loop: true, kind: .video, transition: .cut)
        video.play(visual); await video.waitForLoad()
        // Remove the measurement tap before steady CPU and scheduler measurements.
        sound.removeProfileOutput(); tapInstalled = false
        var frameRows: [[String: Any]] = [], cpuRows: [[String: Any]] = []
        video.profileFrame = { id, pts, host in frameRows.append(["cueID": id.uuidString, "pts": pts, "host": host]) }
        progress("30 seconds of eight audio loops + 1080p30 video + concurrent delayed actions")
        let driver = TimingDriver(); let scheduler = ShowScheduler(now: { stamp() }); scheduler.driver = driver
        var schedulerRows: [[String: Any]] = []
        func scheduleBatch(_ label: String) async throws {
            driver.observations = []
            var targets: [UUID: Double] = [:]
            let origin = stamp()
            for groupIndex in 0..<4 {
                let actions = (0..<48).map { i -> GroupAction in
                    let a = GroupAction(kind: .bus, delay: 0.2 + Double(i/16)*0.2, bus: groupIndex)
                    return a
                }
                scheduler.launch(CueGroup(actions: actions))
                let started = scheduler.runs.last!.started
                for action in actions { targets[action.id] = started + action.delay }
            }
            try await wait({ driver.observations.count == 192 })
            let observations = driver.observations
            for (id, actual) in observations { schedulerRows.append(["scenario": label, "lateMs": (actual-targets[id]!)*1000, "actualFromBatchMs": (actual-origin)*1000, "deadline": targets[id]!, "actual": actual]) }
            scheduler.reset()
        }
        for second in 0..<30 {
            let wall = stamp(), cpu = processCPU()
            if second % 3 == 0 { try await scheduleBatch("AV loaded") }
            let remain = max(0, 1-(stamp()-wall)); try await Task.sleep(for: .seconds(remain))
            cpuRows.append(["second": second, "cpuPercentOneCore": (processCPU()-cpu)/(stamp()-wall)*100, "memory": memory()])
        }
        result["cpuSimultaneousAV"] = cpuRows
        result["frames1080p30"] = frameRows; frameRows = []
        visual.id = UUID(); visual.filePath = v60.path
        video.play(visual); await video.waitForLoad(); frameRows = []
        progress("10 seconds of 1080p60 source through 30 Hz output")
        try await Task.sleep(for: .seconds(10)); result["frames1080p60"] = frameRows
        video.profileFrame = nil
        progress("scheduler under AV + two CPU workers")
        let workers = (0..<2).map { _ in Task.detached(priority: .userInitiated) { () -> Double in
            var x = 0.1
            while !Task.isCancelled { for _ in 0..<10000 { x = sin(x)+0.1 }; await Task.yield() }
            return x
        } }
        for _ in 0..<5 { try await scheduleBatch("AV + 2 CPU workers") }
        for w in workers { w.cancel() }; for w in workers { _ = await w.value }
        progress("real mixer-bus action bursts under simultaneous AV")
        video.play(Cue(filePath: v30.path, loop: true, kind: .video, transition: .cut)); await video.waitForLoad()
        frameRows = []; video.profileFrame = { id, pts, host in frameRows.append(["cueID": id.uuidString, "pts": pts, "host": host]) }
        driver.executeAction = { try state.execute($0) }
        result["realMixerMemoryBefore"] = memory()
        result["audioNodesBeforeRealMixer"] = sound.attachedNodeCount
        let mixerWall = stamp(), mixerCPU = processCPU()
        for _ in 0..<5 { try await scheduleBatch("AV + real mixer bus actions") }
        result["realMixerWorkloadCPUPercentOneCore"] = (processCPU()-mixerCPU)/(stamp()-mixerWall)*100
        result["realMixerCommandCostMs"] = driver.commandCostsMs
        result["realMixerMemoryAfter"] = memory()
        result["audioNodesAfterRealMixer"] = sound.attachedNodeCount
        result["audioVoicesAfterRealMixer"] = sound.voiceCount
        result["decodedBytesAfterRealMixer"] = sound.decodedBytes
        result["framesDuringRealBusActions"] = frameRows; video.profileFrame = nil
        result["scheduler"] = schedulerRows
        progress("12 one-second video crossfades, eight audio voices continue")
        var transitionRows: [[String: Any]] = []
        for trial in 0..<12 {
            var c = Cue(filePath: v30.path, loop: true, kind: .video, transition: .crossfade, videoFadeIn: 1)
            c.soundtrackDB = -60
            let start = stamp(); video.play(c)
            try await wait({ video.currentCue?.id == c.id && !video.loading })
            let ready = stamp(), envelopeStart = video.profileTransitionStart ?? stamp()
            try await wait({ video.frontOpacity >= 1 && video.backFrame == nil })
            transitionRows.append(["trial": trial, "triggerToReadyMs": (ready-start)*1000, "readyToCompleteMs": (stamp()-ready)*1000, "envelopeStartToCompleteMs": (stamp()-envelopeStart)*1000, "triggerToCompleteMs": (stamp()-start)*1000])
            guard sound.voiceCount == 8 else { throw MediaIssue(message: "Expected eight voices") }
        }
        result["crossfadeOneSecond"] = transitionRows
        sound.stopAll(); video.stop(seconds: 0); try await Task.sleep(for: .seconds(2))
        result["memoryAfterStop"] = memory()
        result["audioNodesAfterStop"] = sound.attachedNodeCount
        result["audioErrors"] = sound.errors; result["videoError"] = video.error
        result["status"] = "complete"
        try save(); progress("finished; results.json written")
        guard show.allCues.count == 1024 else { throw MediaIssue(message: "Incomplete large show") }
    }
}
@_cdecl("StageCueStartPerformanceProfile")
public func startStageCuePerformanceProfile() {
    Task { @MainActor in
        do { try await PerformanceBaseline.measure(); fflush(stdout); exit(0) }
        catch { fputs("PROFILE FAILED: \(error)\n", stderr); fflush(stderr); exit(1) }
    }
}
#endif
