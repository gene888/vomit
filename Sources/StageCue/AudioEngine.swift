import Foundation
import AVFoundation
import Combine
import Darwin

#if STAGECUE_PROFILING
import QuartzCore

/// Bounded, lock-protected diagnostic events; absent from ordinary app builds.
final class AudioTriggerTrace: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(UUID, String, Double)] = []
    func mark(_ id: UUID, _ phase: String, at time: Double = CACurrentMediaTime()) {
        lock.lock(); defer { lock.unlock() }
        if entries.count < 20000 { entries.append((id, phase, time)) }
    }
    func take() -> [(UUID, String, Double)] {
        lock.lock(); defer { lock.unlock() }; let value = entries; entries.removeAll(keepingCapacity: true); return value
    }
}
// Opt-in benchmark hook. Not compiled into ordinary application builds.
extension SoundEngine {
    func profileOutput(_ callback: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void) {
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 256, format: nil) { buffer, time in callback(buffer, time) }
    }
    var profileAudioConfiguration: [String: Double] {
        ["outputSampleRate": engine.outputNode.outputFormat(forBus: 0).sampleRate, "outputPresentationLatencySeconds": engine.outputNode.presentationLatency]
    }
    func removeProfileOutput() { engine.mainMixerNode.removeTap(onBus: 0) }
}
#endif

struct MediaIssue: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Decoded on a serial loader actor, then immutable. Only the audio engine reads this buffer.
/// AVAudioPCMBuffer has no Sendable conformance; this wrapper never exposes a mutable cross-actor operation.
final class LoadedMedia: @unchecked Sendable {
    fileprivate let buffer: AVAudioPCMBuffer
    let bytes: Int
    let sourceIdentity: String
    var frameCount: AVAudioFrameCount { buffer.frameLength }
    var duration: Double { Double(buffer.frameLength) / buffer.format.sampleRate }
    init(buffer: AVAudioPCMBuffer, bytes: Int, sourceIdentity: String) { self.buffer = buffer; self.bytes = bytes; self.sourceIdentity = sourceIdentity }
}

/// Observed allocations include media retained by voices, scheduled callbacks and
/// async return values. Reuse index and allocation ledger contain only weak refs.
struct AudioResourceSnapshot: Sendable {
    var uniqueBytes: Int
    var liveBuffers: Int
    var reservedBytes: Int
    var peakBytes: Int
    var hits: Int
    var misses: Int
    var decodes: Int
    var budgetRejections: Int
}

actor MediaLoader {
#if DEBUG || STAGECUE_PROFILING
    private var beforeRead: (@Sendable () throws -> Void)?
    private var afterRead: (@Sendable () throws -> Void)?
    func setReadHooks(before: (@Sendable () throws -> Void)? = nil, after: (@Sendable () throws -> Void)? = nil) {
        beforeRead = before; afterRead = after
    }
#endif
#if STAGECUE_PROFILING
    private var traceContext: (AudioTriggerTrace, UUID)?
    func profileSize(_ path: String, id: UUID, trace: AudioTriggerTrace) throws -> Int {
        trace.mark(id, "loader.inspect.enter"); defer { trace.mark(id, "loader.inspect.exit") }
        return try size(path)
    }
    func profileLoad(_ path: String, expectedBytes: Int, id: UUID, trace: AudioTriggerTrace) throws -> LoadedMedia {
        traceContext = (trace, id); trace.mark(id, "loader.load.enter")
        defer { trace.mark(id, "loader.load.exit"); traceContext = nil }
        return try load(path, expectedBytes: expectedBytes)
    }
#endif
    static let maximumClipBytes = 512 * 1024 * 1024
    private let maximumBytes: Int
    private final class WeakMedia {
        weak var value: LoadedMedia?
        init(_ value: LoadedMedia) { self.value = value }
    }
    private struct Identity: Hashable {
        let device: Int64, inode: UInt64, fileBytes: Int64
        let modifiedSeconds: Int64, modifiedNanos: Int64, changedSeconds: Int64, changedNanos: Int64
        let frames: Int64, rate: Double
        let formatID: UInt32, flags: UInt32, channels: UInt32, bits: UInt32, bytesPerFrame: UInt32, layout: UInt32
    }
    private var reusable: [Identity: WeakMedia] = [:]
    // Separate from lookup eligibility: evicting an index entry cannot erase a
    // live allocation from budget accounting or shorten a voice's ownership.
    private var allocations: [ObjectIdentifier: WeakMedia] = [:]
    private var reservedBytes = 0
    private var peakBytes = 0, hits = 0, misses = 0, decodes = 0, budgetRejections = 0
    init(memoryBudgetBytes: Int = 1024 * 1024 * 1024) { maximumBytes = max(0, memoryBudgetBytes) }

    static func inspect(_ path: String) throws -> (AVAudioFile, Int) {
        guard !path.isEmpty else { throw MediaIssue(message: "No media assigned") }
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        let format = file.processingFormat
        guard file.length > 0, file.length <= AVAudioFramePosition(UInt32.max),
              format.sampleRate.isFinite, format.sampleRate > 0, (1...2).contains(format.channelCount) else {
            throw MediaIssue(message: "Only nonempty mono/stereo audio is supported")
        }
        let bytes = Double(file.length) * (format.isInterleaved ? 1 : Double(format.channelCount)) * Double(format.streamDescription.pointee.mBytesPerFrame)
        guard bytes.isFinite, bytes <= Double(maximumClipBytes) else {
            throw MediaIssue(message: "Decoded audio exceeds 512 MiB; use a shorter clip (about 23 minutes at 48 kHz stereo)")
        }
        return (file, Int(bytes))
    }
    private func sourceStamp(_ url: URL) throws -> String {
        var info = stat()
        guard url.withUnsafeFileSystemRepresentation({ Darwin.fstatat(AT_FDCWD, $0!, &info, 0) }) == 0 else { throw CocoaError(.fileReadUnknown) }
        return "\(info.st_dev):\(info.st_ino):\(info.st_size):\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec):\(info.st_ctimespec.tv_sec):\(info.st_ctimespec.tv_nsec)"
    }
    private func identity(_ url: URL, file: AVAudioFile) throws -> Identity {
        let attributes = try url.resourceValues(forKeys: [.isRegularFileKey])
        guard attributes.isRegularFile == true else { throw MediaIssue(message: "Audio source must be a regular local file") }
        var info = stat()
        guard url.withUnsafeFileSystemRepresentation({ Darwin.fstatat(AT_FDCWD, $0!, &info, 0) }) == 0 else { throw CocoaError(.fileReadUnknown) }
        let f = file.processingFormat, asbd = f.streamDescription.pointee
        return Identity(device: Int64(info.st_dev), inode: UInt64(info.st_ino), fileBytes: info.st_size,
            modifiedSeconds: Int64(info.st_mtimespec.tv_sec), modifiedNanos: Int64(info.st_mtimespec.tv_nsec),
            changedSeconds: Int64(info.st_ctimespec.tv_sec), changedNanos: Int64(info.st_ctimespec.tv_nsec),
            frames: file.length, rate: f.sampleRate, formatID: asbd.mFormatID, flags: asbd.mFormatFlags,
            channels: f.channelCount, bits: asbd.mBitsPerChannel, bytesPerFrame: asbd.mBytesPerFrame,
            layout: f.channelLayout?.layoutTag ?? 0)
    }
    private func prune() {
        reusable = reusable.filter { $0.value.value != nil }
        allocations = allocations.filter { $0.value.value != nil }
    }
    func snapshot() -> AudioResourceSnapshot {
        prune()
        let live = allocations.values.compactMap(\.value)
        return AudioResourceSnapshot(uniqueBytes: live.reduce(0) { $0 + $1.bytes }, liveBuffers: live.count,
            reservedBytes: reservedBytes, peakBytes: peakBytes, hits: hits, misses: misses, decodes: decodes, budgetRejections: budgetRejections)
    }
    /// Eviction affects future reuse only. Active/scheduled references remain valid
    /// and remain charged in allocations. There is no strong inactive cache.
    func invalidateReuse() { reusable.removeAll(); prune() }
    func size(_ path: String) throws -> Int { try Self.inspect(path).1 }
    func load(_ path: String, expectedBytes: Int? = nil) throws -> LoadedMedia {
        try Task.checkCancellation(); prune()
        let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
#if STAGECUE_PROFILING
        if let (trace, id) = traceContext { trace.mark(id, "loader.open.begin") }
#endif
        let beforeOpen = try sourceStamp(url)
        let (file, bytes) = try Self.inspect(url.path)
        guard try sourceStamp(url) == beforeOpen else { throw MediaIssue(message: "Media changed while opening; retrigger") }
        let key = try identity(url, file: file)
#if STAGECUE_PROFILING
        if let (trace, id) = traceContext { trace.mark(id, "loader.open.end") }
#endif
        if let expectedBytes, bytes != expectedBytes { throw MediaIssue(message: "Media changed while loading; retrigger") }
        if let media = reusable[key]?.value {
            hits += 1
#if STAGECUE_PROFILING
            if let (trace, id) = traceContext { trace.mark(id, "loader.shared.hit") }
#endif
            try Task.checkCancellation(); return media
        }
        misses += 1
        // Synchronous decode does not suspend this actor. Every unique allocation
        // reserves against all surviving owners before allocating, even if a
        // caller on MainActor cancelled/removed its pending cue in the meantime.
        let live = allocations.values.compactMap(\.value)
        let used = live.reduce(0) { $0 + $1.bytes }
        guard bytes <= maximumBytes - used - reservedBytes else {
            budgetRejections += 1
            throw MediaIssue(message: "Active and loading audio exceed the decoded memory budget")
        }
        reservedBytes += bytes; peakBytes = max(peakBytes, used + reservedBytes)
        defer { reservedBytes -= bytes }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw MediaIssue(message: "Cannot allocate decoded audio")
        }
#if STAGECUE_PROFILING
        if let (trace, id) = traceContext { trace.mark(id, "loader.read.begin") }
#endif
#if DEBUG || STAGECUE_PROFILING
        try beforeRead?()
#endif
        try Task.checkCancellation()
        try file.read(into: buffer); decodes += 1
#if DEBUG || STAGECUE_PROFILING
        try afterRead?()
#endif
#if STAGECUE_PROFILING
        if let (trace, id) = traceContext { trace.mark(id, "loader.read.end") }
#endif
        try Task.checkCancellation()
        guard buffer.frameLength > 0 else { throw MediaIssue(message: "Empty audio file") }
        guard try sourceStamp(url) == beforeOpen, try identity(url, file: file) == key else { throw MediaIssue(message: "Media changed while loading; retrigger") }
        let media = LoadedMedia(buffer: buffer, bytes: bytes, sourceIdentity: String(describing: key))
        let reference = WeakMedia(media)
        reusable[key] = reference; allocations[ObjectIdentifier(media)] = reference
        return media
    }
}

/// Engine restore snapshot only; the project remains the document's source of truth.
/// Validating seven mixer values never visits cue, page, group or sequence metadata.
private struct MixerSettings {
    var busDB: [Double] = Array(repeating: 0, count: 6)
    var masterDB: Double = 0
    init() {}
    init(_ project: SoundProject) {
        for index in busDB.indices where project.busDB.indices.contains(index) {
            busDB[index] = bounded(project.busDB[index], -60...6, fallback: 0)
        }
        masterDB = bounded(project.masterDB, -60...6, fallback: 0)
    }
}

/// One output, six stereo virtual buses. All graph and voice mutation stays on MainActor.
/// Live fades use a common-mode control timer; offline tests drive the same envelopes from sample time.
@MainActor final class SoundEngine: ObservableObject {
#if STAGECUE_PROFILING
    var profileResources: [String: Int] {
        let media = Dictionary(voices.values.map { (ObjectIdentifier($0.media), $0.media) }, uniquingKeysWith: { a, _ in a })
        return ["uniqueBuffers": media.count, "uniqueDecodedBytes": media.values.reduce(0) { $0 + $1.bytes },
                "voiceReferencedBytes": voices.values.reduce(0) { $0 + $1.media.bytes }, "reservedBytes": 0,
                "voices": voiceCount, "nodes": attachedNodeCount]
    }
    let triggerTrace = AudioTriggerTrace()
    var profileVoiceOutput: (@Sendable (UUID, AVAudioPCMBuffer, AVAudioTime) -> Void)?
    var profilePhase: ((UUID, String) -> Void)?
#endif
    @Published private(set) var active: Set<UUID> = []
    @Published private(set) var paused: Set<UUID> = []
    @Published private(set) var failed: Set<UUID> = []
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
    private let loader: MediaLoader
    private let offline: Bool
    private let mixFormat: AVAudioFormat
    private var controlTimer: Timer?
    private var routeObserver: NSObjectProtocol?
    private var pending: [UUID: (UUID, Task<Void, Never>)] = [:]
    private let maximumActiveBytes: Int
    private var currentMix = MixerSettings()
    private var requestedFades: [UUID: (Float, Double, Bool, Bool)] = [:]

    private final class Voice {
        let token = UUID()
        let player = AVAudioPlayerNode()
        let mixer = AVAudioMixerNode()
        let boost = AVAudioUnitEQ(numberOfBands: 0)
        let cue: Cue
        let media: LoadedMedia
        var started: Double
        var pausedAt: Double?
        var level: Float = 0
        var fade: FadeEnvelope?
        var tailStarted = false
        var manualOverride = false
#if STAGECUE_PROFILING
        var profileTap = false
#endif
        init(cue: Cue, media: LoadedMedia, started: Double) {
            self.cue = cue; self.media = media; self.started = started
        }
    }
    private var voices: [UUID: Voice] = [:]
    var onConfigurationChange: () -> Void = {}
    var isRunning: Bool { engine.isRunning }
    var voiceCount: Int { voices.count }
    var attachedNodeCount: Int { engine.attachedNodes.count }
    var decodedBytes: Int {
        Dictionary(voices.values.map { (ObjectIdentifier($0.media), $0.media.bytes) }, uniquingKeysWith: { a, _ in a }).values.reduce(0, +)
    }
    func retainedMedia(for id: UUID) -> LoadedMedia? { voices[id]?.media }
    func resourceSnapshot() async -> AudioResourceSnapshot { await loader.snapshot() }
    func invalidateDecodedReuse() async { await loader.invalidateReuse() }
    private var clock: Double {
        offline ? Double(engine.manualRenderingSampleTime) / mixFormat.sampleRate : ProcessInfo.processInfo.systemUptime
    }

    init(offline: Bool = false, memoryBudgetBytes: Int = 1024 * 1024 * 1024) {
        self.offline = offline
        maximumActiveBytes = max(0, memoryBudgetBytes)
        loader = MediaLoader(memoryBudgetBytes: memoryBudgetBytes)
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
        applyMixerSettings(MixerSettings(project))
    }
    private func applyMixerSettings(_ safe: MixerSettings) {
        currentMix = safe
        masterBoost.globalGain = 6
        for boost in busBoosts { boost.globalGain = 6 }
        for i in buses.indices { buses[i].outputVolume = amplitude(safe.busDB[i]) / boostScale }
        master.outputVolume = amplitude(safe.masterDB) / boostScale
    }

    /// Returns the applied, bounded dB value so the caller can persist the exact same value.
    /// Unsupported bus identifiers are rejected without touching any mixer parameter.
    @discardableResult func setBusGain(_ index: Int, decibels: Double) -> Double? {
        guard buses.indices.contains(index) else { return nil }
        let safe = bounded(decibels, -60...6, fallback: 0)
        currentMix.busDB[index] = safe
        buses[index].outputVolume = amplitude(safe) / boostScale
        return safe
    }
    @discardableResult func setMasterGain(decibels: Double) -> Double {
        let safe = bounded(decibels, -60...6, fallback: 0)
        currentMix.masterDB = safe
        master.outputVolume = amplitude(safe) / boostScale
        return safe
    }

    /// Retrigger replaces both pending loads and active voices. Stale asynchronous work cannot publish.
    func play(_ input: Cue) {
#if STAGECUE_PROFILING
        triggerTrace.mark(input.id, "engine.play.enter")
        defer { triggerTrace.mark(input.id, "engine.play.return") }
#endif
        var cue = input; cue.normalize()
        if (voices[cue.id] != nil || pending[cue.id] != nil), cue.mode == .toggle {
            configuredStop(cue.id); return
        }
#if STAGECUE_PROFILING
        triggerTrace.mark(cue.id, "engine.cleanup.begin")
#endif
        stop(cue.id)
#if STAGECUE_PROFILING
        triggerTrace.mark(cue.id, "engine.cleanup.end")
#endif
        failed.remove(cue.id)
        let token = UUID()
        loading.insert(cue.id)
#if STAGECUE_PROFILING
        triggerTrace.mark(cue.id, "engine.task.create")
#endif
        #if STAGECUE_PROFILING
        let trace = triggerTrace
        #endif
        let task = Task { [weak self, loader] in
#if STAGECUE_PROFILING
            self?.triggerTrace.mark(cue.id, "engine.task.enter")
#endif
            do {
#if STAGECUE_PROFILING
                self?.profilePhase?(cue.id, "inspectBegin")
#endif
#if STAGECUE_PROFILING
                let size = try await loader.profileSize(cue.filePath, id: cue.id, trace: trace)
#else
                let size = try await loader.size(cue.filePath)
#endif
                guard !Task.isCancelled, let self, self.pending[cue.id]?.0 == token else { return }
#if STAGECUE_PROFILING
                self.profilePhase?(cue.id, "inspectComplete")
                self.triggerTrace.mark(cue.id, "engine.inspect.return")
#endif
#if STAGECUE_PROFILING
                self.profilePhase?(cue.id, "decodeBegin")
#endif
#if STAGECUE_PROFILING
                self.triggerTrace.mark(cue.id, "engine.load.submit")
                let media = try await loader.profileLoad(cue.filePath, expectedBytes: size, id: cue.id, trace: self.triggerTrace)
                self.triggerTrace.mark(cue.id, "engine.load.return")
#else
                let media = try await loader.load(cue.filePath, expectedBytes: size)
#endif
                guard !Task.isCancelled, self.pending[cue.id]?.0 == token else { return }
#if STAGECUE_PROFILING
                self.profilePhase?(cue.id, "decodeComplete")
                self.profilePhase?(cue.id, "graphBegin")
#endif
#if STAGECUE_PROFILING
                self.triggerTrace.mark(cue.id, "engine.graph.begin")
#endif
                try self.start(cue, media: media)
#if STAGECUE_PROFILING
                self.triggerTrace.mark(cue.id, "engine.graph.end")
#endif
#if STAGECUE_PROFILING
                self.profilePhase?(cue.id, "graphComplete")
#endif
                self.pending.removeValue(forKey: cue.id)
                self.loading.remove(cue.id)
            } catch {
                guard let self, self.pending[cue.id]?.0 == token else { return }
                self.pending.removeValue(forKey: cue.id)
                self.loading.remove(cue.id)
                if !(error is CancellationError) { self.failed.insert(cue.id); self.report("\(cue.title): \(error.localizedDescription)") }
            }
        }
        pending[cue.id] = (token, task)
#if STAGECUE_PROFILING
        triggerTrace.mark(cue.id, "engine.task.stored")
#endif
    }

    /// Waits for loads in tests/preparation; UI triggering itself remains nonblocking.
    func waitForLoads() async {
        let tasks = pending.values.map { $0.1 }
        for task in tasks { await task.value }
    }

    private func start(_ cue: Cue, media: LoadedMedia) throws {
        if !engine.isRunning { try engine.start(); applyMixerSettings(currentMix) }
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
#if STAGECUE_PROFILING
        triggerTrace.mark(cue.id, "engine.active.publish.begin")
#endif
        active.insert(cue.id)
        playingLevels[cue.id] = voice.level
#if STAGECUE_PROFILING
        triggerTrace.mark(cue.id, "engine.active.publish.end")
#endif
#if STAGECUE_PROFILING
        if let callback = profileVoiceOutput {
            let id = cue.id
            voice.player.installTap(onBus: 0, bufferSize: 256, format: media.buffer.format) { buffer, time in callback(id, buffer, time) }
            voice.profileTap = true
        }
#endif
        let token = voice.token
        // Capture only Sendable identities, never a Voice/audio node across the callback boundary.
#if STAGECUE_PROFILING
        triggerTrace.mark(cue.id, "engine.buffer.schedule.begin")
#endif
        voice.player.scheduleBuffer(media.buffer, at: nil, options: cue.loop ? [.loops] : [], completionCallbackType: .dataPlayedBack) { [weak self, media] _ in
            // Keep the immutable buffer charged and alive through completion,
            // including the interval after stop while native callbacks retire.
            withExtendedLifetime(media) {}
            Task { @MainActor [weak self] in
                guard let self, !cue.loop, !self.offline, self.voices[cue.id]?.token == token else { return }
                self.detach(cue.id)
            }
        }
#if STAGECUE_PROFILING
        triggerTrace.mark(cue.id, "engine.buffer.schedule.end")
        triggerTrace.mark(cue.id, "engine.player.play.begin")
#endif
        voice.player.play()
#if STAGECUE_PROFILING
        triggerTrace.mark(cue.id, "engine.player.play.end")
#endif
        if paused.contains(cue.id) { voice.pausedAt = clock; voice.player.pause() }
        if cue.autoFadeIn {
            let length = AutomaticFades(cue: cue, duration: media.duration).fadeIn
            voice.fade = FadeEnvelope(initial: 0, target: goal, started: clock, duration: length,
                                      curve: cue.curve, stopWhenDone: false)
        }
        if let fade = requestedFades.removeValue(forKey: cue.id) {
            setFade(cue.id, to: fade.0, seconds: fade.1, stopWhenDone: fade.2, manual: fade.3)
        }
    }

    func pause(_ id: UUID) {
        guard voices[id] != nil || pending[id] != nil else { return }
        paused.insert(id)
        guard let voice = voices[id], voice.pausedAt == nil else { return }
        update()
        voice.pausedAt = clock
        voice.player.pause()
    }
    func resume(_ id: UUID) {
        paused.remove(id)
        guard let voice = voices[id], let at = voice.pausedAt else { return }
        let interval = max(0, clock - at)
        voice.started += interval
        if let fade = voice.fade {
            voice.fade = FadeEnvelope(initial: fade.initial, target: fade.target, started: fade.started + interval,
                                      duration: fade.duration, curve: fade.curve, stopWhenDone: fade.stopWhenDone)
        }
        voice.pausedAt = nil
        voice.player.play()
    }
    func fadeToDB(_ id: UUID, decibels: Double, seconds: Double) {
        setFade(id, to: amplitude(decibels), seconds: seconds, stopWhenDone: false, manual: true)
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
        loading.remove(id)
        paused.remove(id)
        requestedFades.removeValue(forKey: id)
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
        onConfigurationChange()
        stopAll()
        engine.stop()
        report("Audio device configuration changed. Cues stopped; check your output and retrigger explicitly.")
    }

    private func setFade(_ id: UUID, to target: Float, seconds: Double, stopWhenDone: Bool, manual: Bool) {
        if voices[id] == nil, pending[id] != nil { requestedFades[id] = (target, seconds, stopWhenDone, manual); return }
        if paused.contains(id) { resume(id) }
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
            guard let voice = voices[id], voice.pausedAt == nil else { continue }
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
#if STAGECUE_PROFILING
        if voice.profileTap { voice.player.removeTap(onBus: 0) }
#endif
        engine.disconnectNodeOutput(voice.player)
        engine.disconnectNodeOutput(voice.mixer)
        engine.disconnectNodeOutput(voice.boost)
        engine.detach(voice.player)
        engine.detach(voice.mixer)
        engine.detach(voice.boost)
        active.remove(id)
        paused.remove(id)
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
        var uniqueSources: Set<String> = []
        for cue in project.cues.compactMap({ $0 }) {
            do {
                // File inspection and decode run on the loader actor, away from the performance UI.
                let media = try await loader.load(cue.filePath)
                if uniqueSources.insert(media.sourceIdentity).inserted { total += media.bytes }
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
