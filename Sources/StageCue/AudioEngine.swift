import Foundation
import AVFoundation
import Combine

/// Single Core Audio output device, six logical stereo buses, with one mixer per active cue.
/// v0.1 loads the decoded PCM contents of each triggered file into memory.
@MainActor final class SoundEngine: ObservableObject {
    @Published private(set) var active: Set<UUID> = []
    @Published private(set) var errors: [String] = []
    @Published private(set) var playingLevels: [UUID: Float] = [:]

    private let engine = AVAudioEngine()
    private let master = AVAudioMixerNode()
    private var buses: [AVAudioMixerNode] = []
    private class Voice {
        let player = AVAudioPlayerNode()
        let mixer = AVAudioMixerNode()
        var timer: Timer?
        var generation = 0
        var fadeTarget: Float = 1
        init() {}
    }
    private var voices: [UUID: Voice] = [:]
    private var cueConfiguration: [UUID: Cue] = [:]

    init() {
        engine.attach(master)
        engine.connect(master, to: engine.mainMixerNode, format: nil)
        for _ in 0..<6 {
            let bus = AVAudioMixerNode()
            engine.attach(bus)
            engine.connect(bus, to: master, format: nil)
            buses.append(bus)
        }
        engine.prepare()
        do { try engine.start() }
        catch { errors.append("Audio device unavailable: \(error.localizedDescription)") }
    }

    func applyMix(_ project: SoundProject) {
        for index in 0..<6 { buses[index].outputVolume = amplitude(project.busDB[index]) }
        master.outputVolume = amplitude(project.masterDB)
    }

    func play(_ cue: Cue) {
        if voices[cue.id] != nil {
            if cue.mode == .toggle { stop(cue.id) }
            else if cue.mode == .oneShot { stop(cue.id); start(cue) }
            return
        }
        start(cue)
    }

    private func start(_ cue: Cue) {
        guard !cue.filePath.isEmpty else { errors.append("No media assigned to \(cue.title)"); return }
        let url = URL(fileURLWithPath: cue.filePath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            errors.append("Missing file: \(url.lastPathComponent)"); return
        }
        do {
            if !engine.isRunning { try engine.start() }
            let file = try AVAudioFile(forReading: url)
            guard file.length > 0 && file.length <= AVAudioFramePosition(UInt32.max),
                  let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                frameCapacity: AVAudioFrameCount(file.length)) else {
                errors.append("Unsupported or oversized audio file: \(url.lastPathComponent)")
                return
            }
            try file.read(into: buffer)
            guard buffer.frameLength > 0 else { errors.append("Empty audio file: \(url.lastPathComponent)"); return }
            let voice = Voice()
            engine.attach(voice.player)
            engine.attach(voice.mixer)
            engine.connect(voice.player, to: voice.mixer, format: file.processingFormat)
            let busIndex = max(0, min(5, cue.bus))
            engine.connect(voice.mixer, to: buses[busIndex], format: file.processingFormat)
            let goal = amplitude(cue.gainDB)
            voice.mixer.outputVolume = cue.autoFadeIn ? 0 : goal
            voices[cue.id] = voice
            cueConfiguration[cue.id] = cue
            active.insert(cue.id)
            playingLevels[cue.id] = voice.mixer.outputVolume
            let options: AVAudioPlayerNodeBufferOptions = cue.loop ? [.loops] : []
            // Completion is dispatched back to main, and only retires this exact voice instance.
            voice.player.scheduleBuffer(buffer, at: nil, options: options, completionCallbackType: .dataPlayedBack) { [weak self, weak voice] _ in
                Task { @MainActor [weak self, weak voice] in
                    guard let self, let voice, self.voices[cue.id] === voice, !cue.loop else { return }
                    // A scheduled automatic tail fade must begin before playback ends;
                    // v0.1 applies auto-out on user Stop, not at end-of-file.
                    self.detach(cue.id)
                }
            }
            voice.player.play()
            if cue.autoFadeIn { fade(cue.id, to: goal, seconds: cue.fadeInSeconds, curve: cue.curve) }
        } catch { errors.append("Cannot play \(url.lastPathComponent): \(error.localizedDescription)") }
    }

    func fadeIn(_ id: UUID, seconds: Double) {
        guard let cue = cueConfiguration[id] else { return }
        fade(id, to: amplitude(cue.gainDB), seconds: seconds, curve: cue.curve)
    }
    func fadeToSilence(_ id: UUID, seconds: Double) {
        guard let cue = cueConfiguration[id] else { return }
        fade(id, to: 0, seconds: seconds, curve: cue.curve)
    }
    func fadeOutAndStop(_ id: UUID, seconds: Double) {
        guard let cue = cueConfiguration[id] else { return }
        fade(id, to: 0, seconds: seconds, curve: cue.curve, stopWhenDone: true)
    }
    func stop(_ id: UUID) { detach(id) }
    func stopAll() { for id in Array(voices.keys) { detach(id) } }
    func fadeAll(seconds: Double) { for id in Array(voices.keys) { fadeOutAndStop(id, seconds: seconds) } }

    private func fade(_ id: UUID, to target: Float, seconds: Double, curve: FadeCurve, stopWhenDone: Bool = false) {
        guard let voice = voices[id] else { return }
        voice.timer?.invalidate()
        voice.generation += 1
        let generation = voice.generation
        let initial = voice.mixer.outputVolume
        let duration = max(0, seconds)
        guard duration > 0 else {
            voice.mixer.outputVolume = target; playingLevels[id] = target
            if stopWhenDone { detach(id) }
            return
        }
        let begun = ProcessInfo.processInfo.systemUptime
        voice.timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            Task { @MainActor [weak self] in
                guard let self, let current = self.voices[id], current === voice, current.generation == generation else {
                    timer.invalidate(); return
                }
                let fraction = min(1.0, (ProcessInfo.processInfo.systemUptime - begun) / duration)
                let shaped: Double
                switch curve {
                case .linear: shaped = fraction
                case .smooth: shaped = fraction * fraction * (3 - 2 * fraction)
                case .equalPower: shaped = sin(fraction * .pi / 2)
                }
                let level = initial + (target - initial) * Float(shaped)
                current.mixer.outputVolume = level
                self.playingLevels[id] = level
                if fraction >= 1 {
                    timer.invalidate(); current.timer = nil
                    if stopWhenDone { self.detach(id) }
                }
            }
        }
    }

    private func detach(_ id: UUID) {
        guard let voice = voices.removeValue(forKey: id) else { return }
        voice.timer?.invalidate()
        voice.player.stop()
        engine.disconnectNodeOutput(voice.player)
        engine.disconnectNodeOutput(voice.mixer)
        engine.detach(voice.player)
        engine.detach(voice.mixer)
        active.remove(id)
        playingLevels.removeValue(forKey: id)
        cueConfiguration.removeValue(forKey: id)
    }

    func preflight(_ project: SoundProject) -> [String] {
        var warnings: [String] = []
        if !engine.isRunning { warnings.append("Audio engine is not running") }
        for cue in project.cues.compactMap({ $0 }) {
            if cue.filePath.isEmpty { warnings.append("\(cue.title): no file assigned") }
            else if !FileManager.default.fileExists(atPath: cue.filePath) {
                warnings.append("\(cue.title): media missing at \(cue.filePath)")
            }
        }
        return warnings
    }
    func clearErrors() { errors.removeAll() }
}
