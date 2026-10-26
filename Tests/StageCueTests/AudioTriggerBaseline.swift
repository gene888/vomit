#if STAGECUE_PROFILING
import AppKit
import AVFoundation
import Foundation
import SwiftUI
@testable import StageCue

private final class VoiceOnsets: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UUID: Onset] = [:]
    func reset(_ ids: [UUID]) { lock.lock(); values = Dictionary(uniqueKeysWithValues: ids.map { ($0, Onset()) }); lock.unlock() }
    func receive(_ id: UUID, _ buffer: AVAudioPCMBuffer, _ time: AVAudioTime) {
        lock.lock(); let onset = values[id]; lock.unlock(); onset?.receive(buffer, time: time)
    }
    func read(_ id: UUID) -> Double? { lock.lock(); let onset = values[id]; lock.unlock(); return onset?.read()?.render }
}

@MainActor enum AudioTriggerBaseline {
    static func measure(root: URL, state: ShowState, short: URL, long: URL, compressed: URL, movie: URL, onset: Onset, operatorWindow: NSWindow) async throws {
        let sound = state.sound
        var result: [String: Any] = ["status": "running", "date": ISO8601DateFormatter().string(from: Date()),
            "configuration": "Release -O -enable-testing STAGECUE_PROFILING; actual MainView plus two additional canvases; no PCM cache", "audioConfiguration": sound.profileAudioConfiguration,
            "memoryBefore": memory(), "sampleEndpoint": "First nonzero main-mixer render timestamp; physical output and input-event delivery excluded from automatic trials"]
        var rows: [[String: Any]] = []
        func save() throws {
            result["trials"] = rows
            try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .prettyPrinted]).write(to: root.appendingPathComponent("audio-trigger-results.json"), options: .atomic)
        }
        func wait(_ condition: () -> Bool) async throws {
            let deadline = stamp()+15
            while !condition() {
                guard stamp() < deadline else { throw MediaIssue(message: "Audio benchmark timed out") }
                try await Task.sleep(for: .milliseconds(1))
            }
        }
        func clear() async throws {
            state.scheduler.reset(); sound.stopAll()
            try await Task.sleep(for: .milliseconds(150))
            onset.clear(); _ = sound.triggerTrace.take()
        }
        func single(_ label: String, _ cues: [Cue], path: String, count: Int = 20) async throws {
            print("AUDIO PROFILE: \(label)"); fflush(stdout)
            for i in 0..<count {
                try await clear()
                let slot = i % cues.count, cue = cues[slot]
                let started = stamp()
                if path == "engine" { sound.play(cue) }
                else if path == "group" { state.scheduler.launch(CueGroup(actions: [GroupAction(cueID: cue.id)])) }
                else if path == "pad" {
                    // Same synchronous selection + trigger route as the current Button action.
                    // This is a model-entry benchmark, not synthetic mouse-event automation.
                    sound.triggerTrace.mark(cue.id, "ui.action.modelEntry")
                    state.selected = slot; state.trigger(slot)
                } else { state.trigger(slot) }
                let submitted = stamp()
                await sound.waitForLoads()
                try await wait({ onset.read() != nil || sound.failed.contains(cue.id) })
                guard let first = onset.read(), !sound.failed.contains(cue.id) else { throw MediaIssue(message: "Audio profile failed") }
                let events = sound.triggerTrace.take().filter { $0.0 == cue.id }.map { ["phase": $0.1, "ms": ($0.2-started)*1000] as [String: Any] }
                rows.append(["scenario": label, "path": path, "trial": i, "file": URL(fileURLWithPath: cue.filePath).lastPathComponent,
                    "renderMs": (first.render-started)*1000, "callbackMs": (first.callback-started)*1000, "synchronousSubmitMs": (submitted-started)*1000, "events": events])
                try save()
            }
        }
        func assign(_ cues: [Cue]) async throws {
            state.project.cues = Array(cues.map { Optional($0) } + Array(repeating: nil, count: 32-cues.count))
            try await Task.sleep(for: .milliseconds(500))
        }
        try save()
        let shortCue = Cue(title: "Profile short", filePath: short.path, gainDB: 0)
        state.setMasterGain(decibels: -60)
        try await assign([shortCue])
        if ProcessInfo.processInfo.environment["STAGECUE_PROFILE_MODE"] == "audio-interactive" {
            operatorWindow.makeKeyAndOrderFront(nil)
            for trial in 0..<10 {
                try await clear()
                result["readyForClick"] = trial; try save()
                print("AUDIO UI READY: \(trial)"); fflush(stdout)
                let deadline = stamp() + 300
                while onset.read() == nil {
                    guard stamp() < deadline else { throw MediaIssue(message: "Waiting for actual pad click timed out") }
                    try await Task.sleep(for: .milliseconds(5))
                }
                let events = sound.triggerTrace.take().filter { $0.0 == shortCue.id }
                guard let action = events.first(where: { $0.1 == "ui.pad.action" })?.2 else { throw MediaIssue(message: "Expected actual Pad Button action") }
                var row: [String: Any] = ["scenario": "actual-pad-click", "trial": trial, "renderMs": (onset.read()!.render-action)*1000,
                    "events": events.map { ["phase": $0.1, "ms": ($0.2-action)*1000] as [String: Any] }]
                if let received = events.first(where: { $0.1 == "ui.event.timestamp" })?.2 {
                    row["eventToActionMs"] = (action-received)*1000
                    row["eventToRenderMs"] = (onset.read()!.render-received)*1000
                }
                rows.append(row); result["readyForClick"] = NSNull(); try save()
            }
            sound.stopAll()
            result["memoryAfter"] = memory(); result["audioNodesAfterStop"] = sound.attachedNodeCount
            result["audioErrors"] = sound.errors; result["videoError"] = state.video.error
            result["cache"] = ["implemented": false]; result["status"] = "complete"; try save(); return
        }
        if ProcessInfo.processInfo.environment["STAGECUE_PROFILE_MODE"] == "audio-probe" {
            try await single("relay-normal-direct", [shortCue], path: "engine")
            state.profileSuppressAudioPublications = true
            try await single("relay-suppressed-direct", [shortCue], path: "engine")
            state.profileSuppressAudioPublications = false; state.objectWillChange.send()
            result["memoryAfter"] = memory(); result["audioNodesAfterStop"] = sound.attachedNodeCount
            result["audioErrors"] = sound.errors; result["videoError"] = state.video.error
            result["cache"] = ["implemented": false]
            result["status"] = "complete"; try save(); return
        }
        try await single("short-state", [shortCue], path: "state")
        try await single("short-pad-model", [shortCue], path: "pad")
        try await single("short-direct-engine", [shortCue], path: "engine")
        try await single("short-scheduled-group", [shortCue], path: "group")
        for (url, label) in [(long, "long-wav"), (compressed, "long-aac")] {
            let cue = Cue(title: label, filePath: url.path, gainDB: 0)
            try await assign([cue]); try await single(label, [cue], path: "state", count: 10)
        }
        var different: [Cue] = []
        for index in 0..<6 {
            let copy = root.appendingPathComponent("different-short-\(index).wav")
            try? FileManager.default.removeItem(at: copy); try FileManager.default.copyItem(at: short, to: copy)
            different.append(Cue(title: "Effect \(index)", filePath: copy.path, gainDB: 0))
        }
        try await assign(different); try await single("different-short-files", different, path: "state", count: 18)
        state.video.play(Cue(filePath: movie.path, loop: true, kind: .video, transition: .cut)); await state.video.waitForLoad()
        try await assign([shortCue]); try await single("short-during-video", [shortCue], path: "state")
        // Concurrent real bus actions, with the audio cue routed to bus 5 so level automation
        // cannot alter onset detection at the mixer. This timer is benchmark load, not production scheduling.
        let mixer = Task { @MainActor in
            var step = 0
            while !Task.isCancelled {
                _ = try? state.execute(GroupAction(kind: .bus, levelDB: Double(step%24)-24, bus: step%4))
                step += 1
                do { try await Task.sleep(for: .milliseconds(10)) } catch { return }
            }
        }
        var automationCue = shortCue; automationCue.bus = 5
        try await assign([automationCue]); try await single("short-during-mixer-and-video", [automationCue], path: "state")
        mixer.cancel(); await mixer.value
        let voices = VoiceOnsets()
        sound.profileVoiceOutput = { voices.receive($0, $1, $2) }
        try await assign(different)
        print("AUDIO PROFILE: simultaneous four-voice groups"); fflush(stdout)
        for trial in 0..<10 {
            try await clear()
            let cues = Array(different.prefix(4)); voices.reset(cues.map(\.id))
            let began = stamp()
            state.scheduler.launch(CueGroup(actions: cues.map { GroupAction(cueID: $0.id) }))
            await sound.waitForLoads()
            try await wait({ cues.allSatisfy { voices.read($0.id) != nil } })
            let starts = cues.map { voices.read($0.id)! }
            rows.append(["scenario": "four-voice-group", "trial": trial, "renderMs": (starts.min()!-began)*1000,
                "lastVoiceRenderMs": (starts.max()!-began)*1000, "onsetSpreadMs": (starts.max()!-starts.min()!)*1000,
                "events": sound.triggerTrace.take().map { ["cueID": $0.0.uuidString, "phase": $0.1, "ms": ($0.2-began)*1000] as [String: Any] }])
        }
        sound.stopAll(); sound.profileVoiceOutput = nil; state.video.stop(seconds: 0)
        // First trigger after actual project decode + a fresh engine. OS file cache is not purged.
        print("AUDIO PROFILE: cold-project first triggers (warm OS filesystem cache)"); fflush(stdout)
        var project = SoundProject(); project.cues[0] = shortCue; project.masterDB = -60
        let url = root.appendingPathComponent("cold-trigger.stagecue"); try ProjectStore.save(project, to: url)
        for trial in 0..<10 {
            let fresh = ShowState(autosaveURL: url)
            operatorWindow.contentView = NSHostingView(rootView: MainView().environmentObject(fresh))
            try await Task.sleep(for: .milliseconds(300))
            let first = Onset(); fresh.sound.profileOutput { first.receive($0, time: $1) }
            let began = stamp(); fresh.trigger(0); await fresh.sound.waitForLoads()
            try await wait({ first.read() != nil })
            rows.append(["scenario": "fresh-project-first-trigger", "trial": trial, "renderMs": (first.read()!.render-began)*1000,
                "events": fresh.sound.triggerTrace.take().map { ["phase": $0.1, "ms": ($0.2-began)*1000] as [String: Any] }])
            fresh.sound.removeProfileOutput(); fresh.stopAll(); fresh.sound.shutdown(); fresh.video.shutdown(); fresh.output.close()
        }
        result["memoryAfter"] = memory(); result["audioNodesAfterStop"] = sound.attachedNodeCount
        result["audioErrors"] = sound.errors; result["videoError"] = state.video.error
        result["cache"] = ["implemented": false, "hitRate": NSNull(), "preparationOverheadMs": 0] as [String: Any]
        result["status"] = "complete"; try save()
        print("AUDIO PROFILE: finished"); fflush(stdout)
    }
}
#endif
