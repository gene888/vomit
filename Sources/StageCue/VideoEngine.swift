import Foundation
import AVFoundation
import AppKit
import Combine
import CoreImage
import ImageIO
import UniformTypeIdentifiers

actor VisualMediaLoader {
    static func kind(for url: URL) -> CueKind {
        switch url.pathExtension.lowercased() {
        case "mov", "mp4": return .video
        case "png", "jpg", "jpeg": return .image
        default: return .audio
        }
    }
    func inspect(_ path: String, kind: CueKind) async throws -> CGImage? {
        guard FileManager.default.fileExists(atPath: path) else { throw MediaIssue(message: "Missing visual media") }
        let url = URL(fileURLWithPath: path)
        if kind == .image {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let type = CGImageSourceGetType(source) as String?,
                  [UTType.png.identifier, UTType.jpeg.identifier].contains(type),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  width > 0, height > 0, Double(width) * Double(height) <= 33_554_432,
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 4096,
                    kCGImageSourceCreateThumbnailWithTransform: true
                  ] as CFDictionary) else { throw MediaIssue(message: "Unsupported or oversized PNG/JPEG (maximum 32 megapixels)") }
            try Task.checkCancellation()
            return image
        }
        let asset = AVURLAsset(url: url)
        let watchdog = Task {
            try await Task.sleep(for: .seconds(10))
            asset.cancelLoading()
        }
        defer { watchdog.cancel() }
        guard try await asset.load(.isPlayable), !(try await asset.loadTracks(withMediaType: .video)).isEmpty else {
            throw MediaIssue(message: "No playable video track")
        }
        for track in try await asset.loadTracks(withMediaType: .video) {
            let size = try await track.load(.naturalSize)
            guard abs(size.width) <= 4096, abs(size.height) <= 4096 else { throw MediaIssue(message: "Video dimensions exceed 4096 pixels") }
        }
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else { throw MediaIssue(message: "Video has no finite duration") }
        try Task.checkCancellation()
        return nil
    }
    func transform(_ path: String) async throws -> CGAffineTransform {
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { return .identity }
        return try await track.load(.preferredTransform)
    }
}

struct VisualDissolve: Equatable {
    var start: Double
    let duration: Double
    let from: Double
    let to: Double
    func value(at time: Double) -> Double {
        let t = bounded(duration > 0 ? (time - start) / duration : 1, 0...1, fallback: 1)
        return from + (to - from) * t * t * (3 - 2 * t)
    }
    func finished(at time: Double) -> Bool { duration <= 0 || time >= start + duration }
}

@MainActor final class VideoEngine: ObservableObject {
    @Published private(set) var activeIDs: Set<UUID> = []
    @Published private(set) var loading = false
    @Published private(set) var loadingCueID: UUID?
    @Published private(set) var error = ""
    @Published private(set) var paused = false
    private(set) var failedCueID: UUID?
    private var pauseWhenReady = false
    private var readyFade: (UUID, Double, Double)?
    @Published var blackout = false
    @Published private(set) var frontFrame: CGImage?
    @Published private(set) var backFrame: CGImage?
    @Published private(set) var frontOpacity: Double = 1
    @Published private(set) var level: Double = 1
    @Published private(set) var background: CGImage?
    private final class Slot {
        let player = AVQueuePlayer()
        var looper: AVPlayerLooper?
        // Outputs are not copied from AVPlayerLooper's template. Own one per
        // replica and bind reads to currentItem; keep the last valid frame at wrap.
        var loopOutputs: [(item: AVPlayerItem, output: AVPlayerItemVideoOutput)] = []
        func refreshLoopOutputs() {
            guard let looper else { return }
            let replicas = looper.loopingPlayerItems
            for pair in loopOutputs where !replicas.contains(where: { $0 === pair.item }) {
                pair.item.remove(pair.output)
            }
            loopOutputs.removeAll { pair in !replicas.contains(where: { $0 === pair.item }) }
            for item in replicas where !loopOutputs.contains(where: { $0.item === item }) {
                let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
                item.add(output); loopOutputs.append((item, output))
            }
            output = loopOutputs.first(where: { $0.item === player.currentItem })?.output
        }
        var output: AVPlayerItemVideoOutput?
        var frame: CGImage?
        var transform = CGAffineTransform.identity
        var cue: Cue?
        var endObserver: NSObjectProtocol?
        var holdingEnd = false
        func clear() {
            if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
            endObserver = nil
            player.pause(); looper?.disableLooping(); looper = nil
            for pair in loopOutputs { pair.item.remove(pair.output) }
            loopOutputs.removeAll(); player.removeAllItems()
            output = nil; frame = nil; cue = nil; holdingEnd = false
        }
        deinit { if let endObserver { NotificationCenter.default.removeObserver(endObserver) } }
    }
    private let slots = [Slot(), Slot()]
    private let loader = VisualMediaLoader()
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var current: Int?
    private var outgoing: Int?
    private var dissolve: VisualDissolve?
    private var manualFade: VisualDissolve?
    private var stopAfterFade = false
    private var request = UUID()
    private var backgroundRequest = UUID()
    private var loadTask: Task<Void, Never>?
    private var backgroundTask: Task<Void, Never>?
    private var timer: Timer?
    private var pausedAt: Double?
    var currentCue: Cue? { current.flatMap { slots[$0].cue } }
#if STAGECUE_PROFILING
    // Decoded output PTS, before compositor/physical display presentation.
    var profileFrame: ((UUID, Double, Double) -> Void)?
    var profileDecodedImage: ((CGImage, Double, Double) -> Void)?
    var profileLoop: ((String, Double, Double) -> Void)?
    var profileTransitionStart: Double? { dissolve?.start }
#endif
    var holdingLastFrame: Bool { current.map { slots[$0].holdingEnd } ?? false }
    // Count all looper replicas, including one temporarily outside the queue.
    var retainedPlayerItems: Int { slots.reduce(0) { $0 + ($1.looper?.loopingPlayerItems.count ?? $1.player.items().count) } }
    var retainedVideoOutputs: Int { slots.reduce(0) { $0 + ($1.looper == nil ? ($1.output == nil ? 0 : 1) : $1.loopOutputs.count) } }
    var currentSoundtrackVolume: Float { current.map { slots[$0].player.volume } ?? 0 }
    var time: Double { current.map { slots[$0].player.currentTime().seconds } ?? 0 }

    init() {
        for slot in slots { slot.player.actionAtItemEnd = .pause }
        timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer!, forMode: .common)
    }
    isolated deinit {
        timer?.invalidate(); loadTask?.cancel(); backgroundTask?.cancel()
        for slot in slots { slot.clear() }
    }
    func clearError() { error = "" }
    func play(_ original: Cue) {
        guard original.kind != .audio else { return }
        if original.mode == .toggle, loadingCueID == original.id { stopCue(original.id); return }
        if original.mode == .toggle, activeIDs.contains(original.id) { stop(seconds: original.videoFadeOut); return }
        loadTask?.cancel()
        for index in slots.indices where index != current && index != outgoing { slots[index].clear() }
        request = UUID()
        let token = request
        var cue = original; cue.normalize()
        loading = true; loadingCueID = cue.id; error = ""
        failedCueID = nil; pauseWhenReady = false; readyFade = nil
        loadTask = Task { [weak self, loader] in
            do {
                let image = try await loader.inspect(cue.filePath, kind: cue.kind)
                try Task.checkCancellation()
                guard let self, self.request == token else { return }
                // A third trigger resolves the previous transition before reusing a slot.
                self.retireOutgoing()
                let incoming = self.current == 0 ? 1 : 0
                let slot = self.slots[incoming]
                slot.clear(); slot.cue = cue; slot.frame = image
                slot.transform = .identity
                if cue.kind == .video {
                    let transform = try await loader.transform(cue.filePath)
                    try Task.checkCancellation()
                    guard self.request == token else { return }
                    slot.transform = transform
                    let item = AVPlayerItem(url: URL(fileURLWithPath: cue.filePath))
                    slot.player.volume = 0
                    if cue.loop {
                        slot.player.actionAtItemEnd = .advance
                        slot.looper = AVPlayerLooper(player: slot.player, templateItem: item)
                        slot.refreshLoopOutputs()
                    } else {
                        slot.player.actionAtItemEnd = .pause
                        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
                        item.add(output); slot.output = output
                        slot.player.replaceCurrentItem(with: item)
                    }
                    slot.player.play()
                    let deadline = CACurrentMediaTime() + 10
                    while slot.frame == nil {
                        try Task.checkCancellation()
                        guard self.request == token else { return }
                        if slot.looper?.status == .failed { throw slot.looper?.error ?? MediaIssue(message: "Video looper failed") }
                        if let current = slot.player.currentItem, current.status == .failed { throw current.error ?? MediaIssue(message: "Video decoder failed") }
                        self.readFrame(slot)
                        if CACurrentMediaTime() > deadline { throw MediaIssue(message: "Video first-frame readiness timed out") }
                        try await Task.sleep(for: .milliseconds(20))
                    }
                    if !cue.loop {
                        slot.endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
                            Task { @MainActor in self?.didEnd(incoming, item: item) }
                        }
                    }
                }
                guard self.request == token else { slot.clear(); return }
                self.outgoing = self.current
                self.current = incoming
                if cue.transition == .fade { self.retireOutgoing() }
                self.paused = false; self.pausedAt = nil
                self.level = 1; self.manualFade = nil; self.stopAfterFade = false
                let seconds = cue.transition == .cut ? 0 : cue.videoFadeIn
                self.dissolve = VisualDissolve(start: CACurrentMediaTime(), duration: seconds, from: 0, to: 1)
                self.activeIDs.insert(cue.id)
                self.loading = false; self.loadingCueID = nil
                self.tick()
                if let fade = self.readyFade, fade.0 == cue.id { self.readyFade = nil; self.fade(to: fade.1, seconds: fade.2) }
                if self.pauseWhenReady { self.pause() }
            } catch {
                guard let self, self.request == token else { return }
                for index in self.slots.indices where index != self.current && index != self.outgoing { self.slots[index].clear() }
                self.loading = false; self.loadingCueID = nil
                if !(error is CancellationError) { self.failedCueID = cue.id; self.error = "\(cue.title): \(error.localizedDescription)" }
            }
        }
    }
    func waitForLoad() async { await loadTask?.value }
    private func readFrame(_ slot: Slot, completingHold: Bool = false) {
        // Completed video is persistent program content. Never poll its decoder
        // again because an unrelated audio start can change AVFoundation timing.
        guard !slot.holdingEnd || completingHold else { return }
#if STAGECUE_PROFILING
        let refreshStart = CACurrentMediaTime(), previousOutput = slot.output
#endif
        slot.refreshLoopOutputs()
#if STAGECUE_PROFILING
        if previousOutput !== slot.output { profileLoop?("queueOutputChange", CACurrentMediaTime(), CACurrentMediaTime() - refreshStart) }
#endif
        guard let output = slot.output else { return }
        let time = slot.player.currentTime()
        var displayedTime = CMTime.invalid
        if output.hasNewPixelBuffer(forItemTime: time), let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: &displayedTime) {
            autoreleasepool {
                let image = CIImage(cvPixelBuffer: buffer).transformed(by: slot.transform)
                if let decoded = context.createCGImage(image, from: image.extent) {
                    slot.frame = decoded
#if STAGECUE_PROFILING
                    if let id = slot.cue?.id { profileFrame?(id, displayedTime.seconds, CACurrentMediaTime()) }
                    profileDecodedImage?(decoded, displayedTime.seconds, CACurrentMediaTime())
#endif
                }
            }
        }
    }
    private func freezeFrame(_ slot: Slot) {
        guard let frame = slot.frame,
              let bitmap = CGContext(data: nil, width: frame.width, height: frame.height,
                  bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        // Materialize owned pixels instead of retaining decoder/IOSurface backing.
        bitmap.draw(frame, in: CGRect(x: 0, y: 0, width: frame.width, height: frame.height))
        if let retained = bitmap.makeImage() { slot.frame = retained }
    }
    private func didEnd(_ index: Int, item: AVPlayerItem) {
#if STAGECUE_PROFILING
        let handlerStart = CACurrentMediaTime()
        defer { profileLoop?("endHandlerWork", CACurrentMediaTime(), CACurrentMediaTime() - handlerStart) }
#endif
        let slot = slots[index]
        guard slot.player.currentItem === item, index == current || index == outgoing, let cue = slot.cue else { return }
        guard !slot.holdingEnd else { return }
        if cue.holdLastFrame {
            slot.holdingEnd = true
            slot.player.pause()
            freezeFrame(slot)
            // Seek just inside the end to retain the final decoded sample rather
            // than an empty frame at the exclusive duration boundary.
            let end = item.duration
            if end.isNumeric, end.seconds > 0 {
                let lastSample = CMTimeMaximum(.zero, CMTimeSubtract(end, CMTime(value: 1, timescale: 6000)))
                slot.player.seek(to: lastSample, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
                    Task { @MainActor in
                        guard let self, finished, self.slots[index].player.currentItem === item,
                              self.slots[index].holdingEnd else { return }
                        self.readFrame(self.slots[index], completingHold: true)
                        self.freezeFrame(self.slots[index])
                        self.tick()
                    }
                }
            }
        } else if index == current { stop(seconds: cue.videoFadeOut) }
    }
    private func retireOutgoing() {
        if let outgoing {
            if let id = slots[outgoing].cue?.id, id != currentCue?.id { activeIDs.remove(id) }
            slots[outgoing].clear()
        }
        outgoing = nil; dissolve = nil; backFrame = nil; frontOpacity = 1
    }
    func pause() {
        pauseWhenReady = true
        guard current != nil, !paused else { return }
        paused = true; pausedAt = CACurrentMediaTime()
        for slot in slots { slot.player.pause() }
    }
    func resume() {
        pauseWhenReady = false
        guard paused else { return }
        let interval = CACurrentMediaTime() - (pausedAt ?? CACurrentMediaTime())
        dissolve?.start += interval; manualFade?.start += interval
        paused = false; pausedAt = nil
        for index in [current, outgoing].compactMap({ $0 }) where slots[index].cue?.kind == .video && !slots[index].holdingEnd { slots[index].player.play() }
    }
    func fadeCue(_ id: UUID, to target: Double, seconds: Double) {
        if loadingCueID == id { readyFade = (id, target, seconds); pauseWhenReady = false }
        else if currentCue?.id == id { fade(to: target, seconds: seconds) }
    }
    func setSoundtrackDB(_ decibels: Double) {
        guard let current else { return }
        slots[current].cue?.soundtrackDB = bounded(decibels, -60...0, fallback: -6)
        manualFade = nil; stopAfterFade = false
        tick()
    }
    func fade(to target: Double, seconds: Double, stop: Bool = false) {
        resume()
        manualFade = VisualDissolve(start: CACurrentMediaTime(), duration: bounded(seconds, 0...3600, fallback: 1), from: level, to: target)
        stopAfterFade = stop
        tick()
    }
    func stop(seconds: Double = 0) {
        readyFade = nil
        loadTask?.cancel(); request = UUID(); loading = false; loadingCueID = nil
        if seconds > 0 && current != nil { fade(to: 0, seconds: seconds, stop: true) }
        else { clearPlayback() }
    }
    private func clearPlayback() {
        for slot in slots { slot.clear() }
        current = nil; outgoing = nil; dissolve = nil; manualFade = nil
        activeIDs = []; frontFrame = nil; backFrame = nil; level = 1; frontOpacity = 1
        paused = false; pausedAt = nil; stopAfterFade = false
    }
    func stopCue(_ id: UUID, seconds: Double = 0) {
        if loadingCueID == id {
            readyFade = nil
        loadTask?.cancel(); request = UUID(); loading = false; loadingCueID = nil
            for index in slots.indices where index != current && index != outgoing { slots[index].clear() }
        }
        if currentCue?.id == id { stop(seconds: seconds) }
        else if let outgoing, slots[outgoing].cue?.id == id { retireOutgoing() }
    }
    func tick(now: Double = CACurrentMediaTime()) {
        guard !paused else { return }
        if let manualFade {
            level = manualFade.value(at: now)
            if manualFade.finished(at: now) {
                self.manualFade = nil
                if stopAfterFade { clearPlayback(); return }
            }
        }
        if let current {
            if let looper = slots[current].looper, looper.status == .failed {
                failedCueID = slots[current].cue?.id
                let message = "Video looping failed: \(looper.error?.localizedDescription ?? "Decoder error")"
                if error != message { error = message }
                slots[current].player.pause()
            }
            if let item = slots[current].player.currentItem, item.status == .failed {
                failedCueID = slots[current].cue?.id
                let message = "Video playback failed: \(item.error?.localizedDescription ?? "Decoder error")"
                if error != message { error = message }
                slots[current].player.pause()
            }
            readFrame(slots[current])
            frontFrame = slots[current].frame
            if let dissolve {
                frontOpacity = dissolve.value(at: now)
                if dissolve.finished(at: now) { retireOutgoing() }
            }
            slots[current].player.volume = Float(level * frontOpacity) * amplitude(slots[current].cue?.soundtrackDB ?? -60)
        }
        if let outgoing {
            readFrame(slots[outgoing]); backFrame = slots[outgoing].frame
            slots[outgoing].player.volume = Float(level * (1 - frontOpacity)) * amplitude(slots[outgoing].cue?.soundtrackDB ?? -60)
        }
    }
    func setBackground(_ path: String) {
        backgroundTask?.cancel(); backgroundRequest = UUID()
        let token = backgroundRequest
        if path.isEmpty { background = nil; return }
        backgroundTask = Task { [weak self, loader] in
            do {
                let image = try await loader.inspect(path, kind: .image)
                guard let self, self.backgroundRequest == token else { return }
                self.background = image
            } catch {
                guard let self, self.backgroundRequest == token else { return }
                self.error = "Background: \(error.localizedDescription)"
            }
        }
    }
    func waitForBackground() async { await backgroundTask?.value }
    func shutdown() {
        stop(); backgroundTask?.cancel(); backgroundRequest = UUID()
        timer?.invalidate(); timer = nil; background = nil
    }
}
