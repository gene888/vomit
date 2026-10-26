#if STAGECUE_PROFILING
import AppKit
import AVFoundation
import SwiftUI
@testable import StageCue

/// Samples this process without touching project/UI state. Shorter peaks can be missed.
private final class ResourceMemoryPeak: @unchecked Sendable {
    private let lock = NSLock()
    private var peak = memory()
    private let timer: DispatchSourceTimer
    init() {
        timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "StageCue.capacity-memory", qos: .utility))
        timer.schedule(deadline: .now(), repeating: .milliseconds(5))
        timer.setEventHandler { [weak self] in self?.observe() }
        timer.resume()
    }
    private func observe() {
        let current = memory()
        lock.lock(); defer { lock.unlock() }
        for (key, value) in current { peak[key] = max(peak[key] ?? 0, value) }
    }
    func finish() -> [String: Double] {
        timer.cancel(); observe()
        lock.lock(); defer { lock.unlock() }; return peak
    }
    deinit { timer.cancel() }
}

@MainActor enum ResourceBaseline {
    static func project(root: URL, count: Int, bookmarkBytes: Int) -> SoundProject {
        var p = SoundProject(title: "Resource capacity fixture")
        let cues = (0..<count).map { i in Cue(title: "Cue \(i)", filePath: root.appendingPathComponent("Media/Production \(String(repeating: "long-name-", count: 10))/Asset \(i).wav").path, gainDB: -18, bus: i % 6, loop: true) }
        p.cues = Array(cues.prefix(32)).map(Optional.some)
        for start in stride(from: 32, to: count, by: 32) { p.additionalPages.append(SoundboardPage(title: "Page \(start / 32)", cues: Array(cues[start..<min(start+32,count)]).map(Optional.some))) }
        p.groups = (0..<(count == 32 ? 2 : 64)).map { g in CueGroup(title: "Automation \(g)", actions: (0..<32).map { GroupAction(kind: .fade, cueID: cues[$0 % count].id, delay: Double($0), duration: 2, levelDB: -24) }) }
        p.sequences = (0..<(count == 32 ? 2 : 16)).map { n in CueSequence(title: "Act \(n)", steps: (0..<64).map { SequenceStep(cueID: cues[$0 % count].id) }) }
        p.media.assets = cues.map { MediaAsset(filename: URL(fileURLWithPath: $0.filePath).lastPathComponent, originalPath: $0.filePath, kind: .audio, bytes: 1024, sha256: String(repeating: "a", count: 64), cueIDs: [$0.id], bookmark: bookmarkBytes == 0 ? nil : Data(repeating: 3, count: bookmarkBytes)) }
        p.normalize(); return p
    }
    static func measure() async throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["STAGECUE_PROFILE_ROOT"]!)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var result: [String: Any] = ["date": ISO8601DateFormatter().string(from: Date()), "status": "running", "configuration": "native AppKit Release -O; actual MainView; stereo Float32 48kHz; 30Hz video; no physical latency claim"]
        func save() throws { try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted,.sortedKeys]).write(to: root.appendingPathComponent("resources.json"), options: .atomic) }
        try save()
        let source = root.appendingPathComponent("resource-60s.wav")
        if !FileManager.default.fileExists(atPath: source.path) {
            let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
            var settings = format.settings; settings[AVLinearPCMIsNonInterleaved] = false
            let file = try AVAudioFile(forWriting: source, settings: settings)
            let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48000)!; b.frameLength = 48000
            for ch in 0..<2 { for n in 0..<48000 { b.floatChannelData![ch][n] = Float(sin(Double(n)*2 * .pi * 330/48000))*0.005 } }
            for _ in 0..<60 { try file.write(from: b) }
        }
        var files = [source]
        for i in 1..<8 {
            let url = root.appendingPathComponent("resource-unique-\(i).wav")
            if !FileManager.default.fileExists(atPath: url.path) { try FileManager.default.copyItem(at: source, to: url) }
            files.append(url)
        }
        let autosave = root.appendingPathComponent("resource-autosave.json")
        // Match the original empty-project baseline. Reusing yesterday's test
        // autosave would trigger background media resolution during measurements.
        if FileManager.default.fileExists(atPath: autosave.path) { try FileManager.default.removeItem(at: autosave) }
        result["freshIsolatedAutosave"] = true
        let state = ShowState(autosaveURL: autosave), sound = state.sound
        defer { state.scheduler.reset(); state.sequence.emergencyCancel(); sound.shutdown(); state.video.shutdown(); state.output.close() }
        state.project.masterDB = -48; sound.applyMix(state.project)
        let window = NSWindow(contentRect: NSRect(x: 20, y: 20, width: 1220, height: 960), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: MainView().environmentObject(state)); window.orderFront(nil)
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .seconds(1))
        let onset = Onset(); sound.profileOutput { onset.receive($0, time: $1) }
        defer { sound.removeProfileOutput() }
        var audio: [[String: Any]] = []
        for repeated in [true, false, true, false] {
            sound.stopAll(); try await Task.sleep(for: .milliseconds(300))
            _ = sound.triggerTrace.take()
            var cues: [Cue] = []
            onset.clear()
            let before = memory(), began = stamp()
            for n in 0..<8 {
                let c = Cue(filePath: (repeated ? source : files[n]).path, gainDB: -18, bus: n % 6, loop: true)
                cues.append(c); state.project.cues[n] = c
                sound.play(c)
            }
            await sound.waitForLoads(); let ready = stamp()
            guard sound.voiceCount == 8 else { throw MediaIssue(message: "Eight voices failed: \(sound.errors)") }
            let deadline = stamp() + 5
            while onset.read() == nil && stamp() < deadline { try await Task.sleep(for: .milliseconds(5)) }
            guard let first = onset.read() else { throw MediaIssue(message: "No rendered onset") }
            let phases = sound.triggerTrace.take()
            let cpu = processCPU(), start = stamp()
            for i in 0..<40 {
                if i % 10 == 0 { for (n,c) in cues.enumerated() { sound.fadeToDB(c.id, decibels: n % 2 == 0 ? -24 : -12, seconds: 0.2) } }
                try await Task.sleep(for: .milliseconds(100))
            }
            audio.append(["scenario": repeated ? "eight-shared-file" : "eight-unique-files", "loadAndGraphMs": (ready-began)*1000,
                "firstMixerRenderMs": (first.render-began)*1000, "resources": sound.profileResources, "decodedBytes": sound.decodedBytes, "memoryBefore": before, "memoryActive": memory(),
                "cpuPercentOneCore": (processCPU()-cpu)/(stamp()-start)*100,
                "actualDecodeReads": phases.filter { $0.1 == "loader.read.begin" }.count])
            let pool = await sound.resourceSnapshot()
            audio[audio.count-1]["pool"] = ["liveUniqueBytes":pool.uniqueBytes,"buffers":pool.liveBuffers,"reservedBytes":pool.reservedBytes,"peakBytes":pool.peakBytes,"hits":pool.hits,"misses":pool.misses,"decodes":pool.decodes,"budgetRejections":pool.budgetRejections,"inactiveCacheBytes":0]
            sound.stopAll(); try await Task.sleep(for: .milliseconds(200))
            let stopped = await sound.resourceSnapshot()
            audio[audio.count-1]["poolAfterStop"] = ["uniqueBytes":stopped.uniqueBytes,"buffers":stopped.liveBuffers,"reservedBytes":stopped.reservedBytes]
            audio[audio.count-1]["afterStop"] = sound.profileResources; audio[audio.count-1]["memoryAfterStop"] = memory()
            result["audio"] = audio; try save()
        }
        // Repeated stop/start checks bounded live resource accounting, not long-term leak freedom.
        var cycles: [[String: Any]] = []
        for i in 0..<20 {
            let c = Cue(filePath: source.path, loop: true)
            sound.play(c); await sound.waitForLoads(); sound.stopAll()
            try await Task.sleep(for: .milliseconds(50))
            if i % 4 == 0 { cycles.append(["cycle":i, "resources":sound.profileResources,"memory":memory()]) }
        }
        result["cycles"] = cycles
        var capacities: [[String: Any]] = []
        for (count, bookmarks) in [(32,0),(256,0),(1024,0),(1024,512),(1024,2048)] {
            let peak = ResourceMemoryPeak()
            let p = project(root: root, count: count, bookmarkBytes: bookmarks)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
            let t = stamp(); let bytes = try encoder.encode(p); let encodeEnd = stamp()
            let before = memory(); let parseStart = stamp(); var restored = try JSONDecoder().decode(SoundProject.self, from: bytes); let parseEnd = stamp()
            restored.normalize(); let normalizeEnd = stamp()
            let url = root.appendingPathComponent("capacity-\(count)-\(bookmarks).stagecue")
            var row: [String: Any] = ["cues":count,"assets":p.media.assets.count,"bookmarkBytesPerAsset":bookmarks,"encodedBytes":bytes.count,
                "encodeMs":(encodeEnd-t)*1000,"parseMs":(parseEnd-parseStart)*1000,"normalizeMs":(normalizeEnd-parseEnd)*1000,
                "memoryBefore":before,"memoryAfterParsing":memory(),"restoredEqual":restored==p]
            do {
                let a=stamp(); try ProjectStore.save(p,to:url); let b=stamp(); let loaded=try ProjectStore.load(from:url).0
                row["saveMs"]=(b-a)*1000; row["loadMs"]=(stamp()-b)*1000;row["roundTripEqual"]=loaded==p
                var expected = p
                for i in expected.media.assets.indices { expected.media.assets[i].relativePath = MediaPaths.relative(URL(fileURLWithPath: expected.media.assets[i].originalPath), root: root) }
                row["restorationEquivalent"] = loaded == expected
            } catch { row["error"]=error.localizedDescription; row["errorDomain"]=(error as NSError).domain;row["errorCode"]=(error as NSError).code }
            row["sampledPeakMemory"] = peak.finish(); row["memorySamplingIntervalMs"] = 5
            capacities.append(row); result["capacity"]=capacities;try save()
        }
        let movie = try await VideoLoopBaseline.movie(root: root, atmosphere: false, seconds: 4)
        let audioCues = (0..<4).map { Cue(filePath:source.path,gainDB:-18,bus:$0,loop:true) }
        for (i,c) in audioCues.enumerated() { state.project.cues[i]=c; sound.play(c) }
        await sound.waitForLoads()
        state.video.play(Cue(filePath:movie.path,loop:true,kind:.video,transition:.cut));await state.video.waitForLoad()
        let group = CueGroup(actions:(0..<3).map { GroupAction(kind:.bus,delay:Double($0)*0.2,levelDB:-18+Double($0),bus:$0) })
        state.project.groups=[group]
        let sequence = CueSequence(steps:(0..<32).map { SequenceStep(title:"Step \($0)",target:.group,groupID:group.id,advancement:.timed,delay:2) })
        state.sequence.select(sequence);state.sequence.go()
        var commandMs:[Double]=[], samples:[[String:Double]]=[]
        let stressStart=stamp(),stressCPU=processCPU();var n=0
        while stamp()-stressStart<60 {
            let t=stamp();_=try state.execute(GroupAction(kind:.bus,levelDB:Double(n%12)-24,bus:n%6));commandMs.append((stamp()-t)*1000)
            if n%50==0 { var m=memory();m["elapsed"]=stamp()-stressStart;m["uniqueDecodedBytes"]=Double(sound.decodedBytes);m["voices"]=Double(sound.voiceCount);m["nodes"]=Double(sound.attachedNodeCount);samples.append(m) }
            n += 1;try await Task.sleep(for:.milliseconds(100))
        }
        let stressDuration=stamp()-stressStart
        result["avShowControlStress"]=["seconds":stressDuration,"cpuPercentOneCore":(processCPU()-stressCPU)/stressDuration*100,"mixerCommandMs":commandMs,"memory":samples,"sequenceCurrent":state.sequence.current,"audioErrors":sound.errors,"videoError":state.video.error,"videoItems":state.video.retainedPlayerItems]
        state.stopAll();try await Task.sleep(for:.milliseconds(200))
        let finalPool=await sound.resourceSnapshot()
        result["finalResources"]=["uniqueBytes":finalPool.uniqueBytes,"buffers":finalPool.liveBuffers,"reservedBytes":finalPool.reservedBytes,"nodes":sound.attachedNodeCount,"videoItems":state.video.retainedPlayerItems]
        result["status"]="complete";try save(); print("RESOURCES: complete");fflush(stdout)
    }
}
#endif
