import Foundation
import AVFoundation
import Combine

struct MediaIssue: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Decoded on a serial loader actor, then immutable. Only the audio engine reads this buffer.
/// AVAudioPCMBuffer has no Sendable conformance; this wrapper never exposes a mutable cross-actor operation.
final class LoadedMedia: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    let bytes: Int
    var duration: Double { Double(buffer.frameLength) / buffer.format.sampleRate }
    init(buffer: AVAudioPCMBuffer, bytes: Int) { self.buffer = buffer; self.bytes = bytes }
}

actor MediaLoader {
    static let maximumClipBytes = 512 * 1024 * 1024
    static func inspect(_ path: String) throws -> (AVAudioFile, Int) {
        guard !path.isEmpty else { throw MediaIssue(message: "No media assigned") }
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        let format = file.processingFormat
        guard file.length > 0, file.length <= AVAudioFramePosition(UInt32.max),
              format.sampleRate.isFinite, format.sampleRate > 0,
              (1...2).contains(format.channelCount) else {
            throw MediaIssue(message: "Only nonempty mono/stereo audio is supported")
        }
        let bytes = Double(file.length) * (format.isInterleaved ? 1 : Double(format.channelCount)) * Double(format.streamDescription.pointee.mBytesPerFrame)
        guard bytes.isFinite, bytes <= Double(maximumClipBytes) else {
            throw MediaIssue(message: "Decoded audio exceeds 512 MiB; use a shorter clip (about 23 minutes at 48 kHz stereo)")
        }
        return (file, Int(bytes))
    }
    func size(_ path: String) throws -> Int { try Self.inspect(path).1 }
    func load(_ path: String, expectedBytes: Int? = nil) throws -> LoadedMedia {
        try Task.checkCancellation()
        let (file, bytes) = try Self.inspect(path)
        if let expectedBytes, bytes != expectedBytes { throw MediaIssue(message: "Media changed while loading; retrigger") }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw MediaIssue(message: "Cannot allocate decoded audio")
        }
        try file.read(into: buffer)
        try Task.checkCancellation()
        guard buffer.frameLength > 0 else { throw MediaIssue(message: "Empty audio file") }
        return LoadedMedia(buffer: buffer, bytes: bytes)
    }
}

/// One output, six stereo virtual buses. All graph and voice mutation stays on MainActor.
/// Live fades use a common-mode control timer; offline tests drive the same envelopes from sample time.
@MainActor final class SoundEngine: ObservableObject {
    @Published private(set) var active: Set<UUID> = []
    @Published private(set) var loading: Set<UUID> = []
    @Published private(set) var errors: [String] = []
    @Published private(set) var playingLevels: [UUID: Float] = [:]
    private let engine = AVAudioEngine()
    private let master = AVAudioMixerNode()
    private let masterBoost = AVAudioUnitEQ(numberOfBands: 0)
    private var buses: [AVAudioMixerNode] = []
    private var busBoosts: [AVAudioUnitEQ] = []
    // Mixer outputVolume is documented as 0...1. A fixed +6 dB native gain stage lets
    // the user retain the -60...+6 dB range without relying on out-of-range mixer values.
    private let boostScale = amplitude(6)
    private let loader = MediaLoader()
    private let offline: Bool
    private let mixFormat: AVAudioFormat
    private var controlTimer: Timer?
    private var routeObserver: NSObjectProtocol?
    private var pending: [UUID: (UUID, Task<Void, Never>)] = [:]
    private let maximumActiveBytes: Int
    private var currentMix = SoundProject()
    private var retainedBytes = 0
    private var reservations: [UUID: Int] = [:]

    private final class Voice {
        let token = UUID()
        let player = AVAudioPlayerNode()
        let mixer = AVAudioMixerNode()
        let boost = AVAudioUnitEQ(numberOfBands: 0)
        let cue: Cue
        let media: LoadedMedia
        let started: Double
        var level: Float = 0
        var fade: FadeEnvelope?
        var tailStarted = false
        var manualOverride = false
        init(cue: Cue, media: LoadedMedia, started: Double) {
            self.cue = cue; self.media = media; self.started = started
        }
    }
    private var voices: [UUID: Voice] = [:]
    var isRunning: Bool { engine.isRunning }
    var voiceCount: Int { voices.count }
    var attachedNodeCount: Int { engine.attachedNodes.count }
    var decodedBytes: Int { retainedBytes }
    private var clock: Double {
        offline ? Double(engine.manualRenderingSampleTime) / mixFormat.sampleRate : ProcessInfo.processInfo.systemUptime
    }

    init(offline: Bool = false, memoryBudgetBytes: Int = 1024 * 1024 * 1024) {
        self.offline = offline
        maximumActiveBytes = max(0, memoryBudgetBytes)
        mixFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        do {
            if offline { try engine.enableManualRenderingMode(.offline, format: mixFormat, maximumFrameCount: 1024) }
            engine.attach(master)
            engine.attach(masterBoost)
            masterBoost.globalGain = 6
            master.outputVolume = 1 / boostScale
            engine.connect(master, to: masterBoost, format: mixFormat)
            engine.connect(masterBoost, to: engine.mainMixerNode, format: mixFormat)
            for _ in 0..<6 {
                let bus = AVAudioMixerNode()
                let boost = AVAudioUnitEQ(numberOfBands: 0)
                boost.globalGain = 6
                bus.outputVolume = 1 / boostScale
                engine.attach(bus)
                engine.attach(boost)
                engine.connect(bus, to: boost, format: mixFormat)
                engine.connect(boost, to: master, format: mixFormat)
                buses.append(bus)
                busBoosts.append(boost)
            }
            engine.prepare()
            try engine.start()
            applyMix(SoundProject())
        } catch { report("Audio engine unavailable: \(error.localizedDescription)") }
        if !offline {
            let timer = Timer(timeInterval: 1 / 120, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.update() }
            }
            controlTimer = timer
            RunLoop.main.add(timer, forMode: .common)
            routeObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.handleConfigurationChange() }
            }
        }
    }

    isolated deinit {
        controlTimer?.invalidate()
        if let routeObserver { NotificationCenter.default.removeObserver(routeObserver) }
    }

    private func report(_ message: String) {
        errors.append(message)
        if errors.count > 20 { errors.removeFirst(errors.count - 20) }
    }
    func applyMix(_ project: SoundProject) {
        var safe = project; safe.normalize()
        currentMix = safe
        masterBoost.globalGain = 6
        for boost in busBoosts { boost.globalGain = 6 }
        for i in buses.indices { buses[i].outputVolume = amplitude(safe.busDB[i]) / boostScale }
        master.outputVolume = amplitude(safe.masterDB) / boostScale
    }

    /// Retrigger replaces both pending loads and active voices. Stale asynchronous work cannot publish.
    func play(_ input: Cue) {
        var cue = input; cue.normalize()
        if (voices[cue.id] != nil || pending[cue.id] != nil), cue.mode == .toggle {
            configuredStop(cue.id); return
        }
        stop(cue.id)
        let token = UUID()
        loading.insert(cue.id)
        let task = Task { [weak self, loader] in
            do {
                let size = try await loader.size(cue.filePath)
                guard !Task.isCancelled, let self, self.pending[cue.id]?.0 == token else { return }
                guard self.retainedBytes + self.reservations.values.reduce(0, +) + size <= self.maximumActiveBytes else {
                    throw MediaIssue(message: "Active and loading audio exceed the decoded memory budget")
                }
                self.reservations[cue.id] = size
                let media = try await loader.load(cue.filePath, expectedBytes: size)
                guard !Task.isCancelled, self.pending[cue.id]?.0 == token else { return }
                try self.start(cue, media: media)
                self.pending.removeValue(forKey: cue.id)
                self.reservations.removeValue(forKey: cue.id)
                self.loading.remove(cue.id)
            } catch {
                guard let self, self.pending[cue.id]?.0 == token else { return }
                self.pending.removeValue(forKey: cue.id)
                self.reservations.removeValue(forKey: cue.id)
                self.loading.remove(cue.id)
                if !(error is CancellationError) { self.report("\(cue.title): \(error.localizedDescription)") }
            }
        }
        pending[cue.id] = (token, task)
    }

    /// Waits for loads in tests/preparation; UI triggering itself remains nonblocking.
    func waitForLoads() async {
        let tasks = pending.values.map { $0.1 }
        for task in tasks { await task.value }
    }

    private func start(_ cue: Cue, media: LoadedMedia) throws {
        guard retainedBytes + media.bytes <= maximumActiveBytes else {
            throw MediaIssue(message: "Active audio exceeds the decoded memory budget")
        }
        if !engine.isRunning { try engine.start(); applyMix(currentMix) }
        let voice = Voice(cue: cue, media: media, started: clock)
        engine.attach(voice.player)
        engine.attach(voice.mixer)
        engine.attach(voice.boost)
        voice.boost.globalGain = 6
        engine.connect(voice.player, to: voice.mixer, format: media.buffer.format)
        // Mixer converts each clip's sample rate/channel layout into the common stereo bus format.
        engine.connect(voice.mixer, to: voice.boost, format: mixFormat)
        engine.connect(voice.boost, to: buses[cue.bus], format: mixFormat)
        let goal = amplitude(cue.gainDB)
        voice.level = cue.autoFadeIn ? 0 : goal
        voice.mixer.outputVolume = voice.level / boostScale
        voices[cue.id] = voice
        retainedBytes += media.bytes
        active.insert(cue.id)
        playingLevels[cue.id] = voice.level
        let token = voice.token
        // Capture only Sendable identities, never a Voice/audio node across the callback boundary.
        voice.player.scheduleBuffer(media.buffer, at: nil, options: cue.loop ? [.loops] : [], completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !cue.loop, !self.offline, self.voices[cue.id]?.token == token else { return }
                self.detach(cue.id)
            }
        }
        voice.player.play()
        if cue.autoFadeIn {
            let length = AutomaticFades(cue: cue, duration: media.duration).fadeIn
            voice.fade = FadeEnvelope(initial: 0, target: goal, started: clock, duration: length,
                                      curve: cue.curve, stopWhenDone: false)
        }
    }

    func fadeIn(_ id: UUID, seconds: Double) {
        guard let voice = voices[id] else { return }
        setFade(id, to: amplitude(voice.cue.gainDB), seconds: seconds, stopWhenDone: false, manual: true)
    }
    func fadeToSilence(_ id: UUID, seconds: Double) { setFade(id, to: 0, seconds: seconds, stopWhenDone: false, manual: true) }
    func fadeOutAndStop(_ id: UUID, seconds: Double) {
        if pending[id] != nil { stop(id) }
        setFade(id, to: 0, seconds: seconds, stopWhenDone: true, manual: true)
    }
    func configuredStop(_ id: UUID) {
        guard let voice = voices[id], voice.cue.autoFadeOut else { stop(id); return }
        fadeOutAndStop(id, seconds: voice.cue.fadeOutSeconds)
    }
    func stop(_ id: UUID) {
        pending.removeValue(forKey: id)?.1.cancel()
        reservations.removeValue(forKey: id)
        loading.remove(id)
        detach(id)
    }
    func stopAll() {
        for id in Array(pending.keys) { stop(id) }
        for id in Array(voices.keys) { detach(id) }
    }
    func fadeAll(seconds: Double) {
        for id in Array(pending.keys) { stop(id) }
        for id in Array(voices.keys) { fadeOutAndStop(id, seconds: seconds) }
    }
    func shutdown() {
        stopAll()
        controlTimer?.invalidate(); controlTimer = nil
        if let routeObserver { NotificationCenter.default.removeObserver(routeObserver); self.routeObserver = nil }
        engine.stop()
    }
    func handleConfigurationChange() {
        stopAll()
        engine.stop()
        report("Audio device configuration changed. Cues stopped; check your output and retrigger explicitly.")
    }

    private func setFade(_ id: UUID, to target: Float, seconds: Double, stopWhenDone: Bool, manual: Bool) {
        update()
        guard let voice = voices[id] else { return }
        if manual { voice.manualOverride = true }
        let duration = bounded(seconds, 0...3600, fallback: 0)
        voice.fade = FadeEnvelope(initial: voice.level, target: target, started: clock,
                                  duration: duration, curve: voice.cue.curve, stopWhenDone: stopWhenDone)
        if duration == 0 {
            voice.level = target
            voice.mixer.outputVolume = target / boostScale
            playingLevels[id] = target
            voice.fade = nil
            if stopWhenDone { detach(id) }
        }
    }

    private func update() {
        let now = clock
        for id in Array(voices.keys) {
            guard let voice = voices[id] else { continue }
            let elapsed: Double
            if offline { elapsed = max(0, now - voice.started) }
            else if let renderTime = voice.player.lastRenderTime, let playerTime = voice.player.playerTime(forNodeTime: renderTime) {
                elapsed = max(0, Double(playerTime.sampleTime) / playerTime.sampleRate)
            } else { elapsed = 0 }
            // Evaluate the old envelope before beginning the tail: overlapping in/out fades are continuous.
            if let fade = voice.fade {
                voice.level = fade.level(at: now)
                voice.mixer.outputVolume = voice.level / boostScale
                playingLevels[id] = voice.level
                if fade.fraction(at: now) >= 1 {
                    voice.fade = nil
                    if fade.stopWhenDone { detach(id); continue }
                }
            }
            if !voice.cue.loop, voice.cue.autoFadeOut, !voice.tailStarted, !voice.manualOverride {
                let tailLength = AutomaticFades(cue: voice.cue, duration: voice.media.duration).fadeOut
                if elapsed >= voice.media.duration - tailLength {
                    voice.tailStarted = true
                    let remaining = max(0, voice.media.duration - elapsed)
                    voice.fade = FadeEnvelope(initial: voice.level, target: 0, started: now,
                                              duration: remaining, curve: voice.cue.curve, stopWhenDone: false)
                }
            }
            // Offline completion cannot depend on main-actor callback scheduling while synchronously rendering.
            if offline, !voice.cue.loop, elapsed >= voice.media.duration { detach(id) }
        }
    }

    private func detach(_ id: UUID) {
        guard let voice = voices.removeValue(forKey: id) else { return }
        voice.player.stop()
        engine.disconnectNodeOutput(voice.player)
        engine.disconnectNodeOutput(voice.mixer)
        engine.disconnectNodeOutput(voice.boost)
        engine.detach(voice.player)
        engine.detach(voice.mixer)
        engine.detach(voice.boost)
        retainedBytes -= voice.media.bytes
        active.remove(id)
        playingLevels.removeValue(forKey: id)
    }

    /// The real graph is rendered without a physical output device. Tests inspect PCM, not just settings.
    func render(frames: AVAudioFrameCount) throws -> AVAudioPCMBuffer {
        guard offline, frames > 0, frames <= 1024,
              let buffer = AVAudioPCMBuffer(pcmFormat: mixFormat, frameCapacity: frames) else {
            throw MediaIssue(message: "Invalid offline render request")
        }
        update()
        let status = try engine.renderOffline(frames, to: buffer)
        guard status == .success else { throw MediaIssue(message: "Offline rendering failed: \(status.rawValue)") }
        update()
        return buffer
    }

    func preflight(_ project: SoundProject) async -> [String] {
        var warnings: [String] = []
        if !engine.isRunning { warnings.append("Audio engine is not running; check output before triggering") }
        var total = 0
        for cue in project.cues.compactMap({ $0 }) {
            do {
                // File inspection and decode run on the loader actor, away from the performance UI.
                let media = try await loader.load(cue.filePath)
                total += media.bytes
            } catch { warnings.append("\(cue.title): \(error.localizedDescription)") }
        }
        if total > maximumActiveBytes { warnings.append("All assigned media together exceed the active audio memory budget") }
        if !engine.isRunning && !warnings.contains(where: { $0.hasPrefix("Audio engine") }) {
            warnings.append("Audio engine stopped during preflight; check output before triggering")
        }
        return warnings
    }
    func clearErrors() { errors.removeAll() }
}
