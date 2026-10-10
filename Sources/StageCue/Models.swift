import Foundation

enum CueMode: String, Codable, CaseIterable, Identifiable, Sendable {
    // Hold is retained for decoding old files, but is not offered until release handling exists.
    case oneShot = "One-shot", toggle = "Toggle", hold = "Hold"
    var id: String { rawValue }
    static var supported: [CueMode] { [.oneShot, .toggle] }
}
enum FadeCurve: String, Codable, CaseIterable, Identifiable, Sendable {
    case linear = "Linear amplitude", smooth = "Smooth S-curve", equalPower = "Equal-power"
    var id: String { rawValue }
}

func bounded(_ value: Double, _ range: ClosedRange<Double>, fallback: Double) -> Double {
    value.isFinite ? min(range.upperBound, max(range.lowerBound, value)) : fallback
}
func amplitude(_ decibels: Double) -> Float {
    Float(pow(10, bounded(decibels, -60...6, fallback: 0) / 20))
}

enum CueKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case audio = "Audio", video = "Video", image = "Image", group = "Group"
    var id: String { rawValue }
}
enum VisualTransition: String, Codable, CaseIterable, Identifiable, Sendable {
    case cut = "Cut", crossfade = "Crossfade"
    var id: String { rawValue }
}

struct Cue: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var title = "Untitled"
    var filePath = ""
    var gainDB: Double = -6
    var bus = 0
    var mode: CueMode = .oneShot
    var loop = false
    var autoFadeIn = false
    var fadeInSeconds: Double = 2
    var autoFadeOut = false
    var fadeOutSeconds: Double = 2
    var curve: FadeCurve = .smooth
    var tint = "blue"
    var kind: CueKind = .audio
    var transition: VisualTransition = .crossfade
    var videoFadeIn: Double = 1
    var videoFadeOut: Double = 1
    var soundtrackDB: Double = -6
    var holdLastFrame = false
    var groupID: UUID?

    mutating func normalize() {
        gainDB = bounded(gainDB, -60...6, fallback: -6)
        bus = min(5, max(0, bus))
        fadeInSeconds = bounded(fadeInSeconds, 0...3600, fallback: 2)
        fadeOutSeconds = bounded(fadeOutSeconds, 0...3600, fallback: 2)
        videoFadeIn = bounded(videoFadeIn, 0...3600, fallback: 1)
        videoFadeOut = bounded(videoFadeOut, 0...3600, fallback: 1)
        soundtrackDB = bounded(soundtrackDB, -60...0, fallback: -6)
        if mode == .hold { mode = .oneShot }
    }
}

extension Cue {
    enum CodingKeys: String, CodingKey {
        case id, title, filePath, gainDB, bus, mode, loop, autoFadeIn, fadeInSeconds
        case autoFadeOut, fadeOutSeconds, curve, tint, kind, transition, videoFadeIn, videoFadeOut, soundtrackDB, holdLastFrame, groupID
    }
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? id
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? title
        filePath = try c.decodeIfPresent(String.self, forKey: .filePath) ?? filePath
        gainDB = try c.decodeIfPresent(Double.self, forKey: .gainDB) ?? gainDB
        bus = try c.decodeIfPresent(Int.self, forKey: .bus) ?? bus
        mode = try c.decodeIfPresent(CueMode.self, forKey: .mode) ?? mode
        loop = try c.decodeIfPresent(Bool.self, forKey: .loop) ?? loop
        autoFadeIn = try c.decodeIfPresent(Bool.self, forKey: .autoFadeIn) ?? autoFadeIn
        fadeInSeconds = try c.decodeIfPresent(Double.self, forKey: .fadeInSeconds) ?? fadeInSeconds
        autoFadeOut = try c.decodeIfPresent(Bool.self, forKey: .autoFadeOut) ?? autoFadeOut
        fadeOutSeconds = try c.decodeIfPresent(Double.self, forKey: .fadeOutSeconds) ?? fadeOutSeconds
        curve = try c.decodeIfPresent(FadeCurve.self, forKey: .curve) ?? curve
        tint = try c.decodeIfPresent(String.self, forKey: .tint) ?? tint
        kind = try c.decodeIfPresent(CueKind.self, forKey: .kind) ?? .audio
        transition = try c.decodeIfPresent(VisualTransition.self, forKey: .transition) ?? transition
        videoFadeIn = try c.decodeIfPresent(Double.self, forKey: .videoFadeIn) ?? videoFadeIn
        videoFadeOut = try c.decodeIfPresent(Double.self, forKey: .videoFadeOut) ?? videoFadeOut
        soundtrackDB = try c.decodeIfPresent(Double.self, forKey: .soundtrackDB) ?? soundtrackDB
        groupID = try c.decodeIfPresent(UUID.self, forKey: .groupID)
        holdLastFrame = try c.decodeIfPresent(Bool.self, forKey: .holdLastFrame) ?? false
    }
}

struct SoundProject: Codable, Equatable, Sendable {
    static let migrationNotice = "Project upgraded to schema 3"
    var schemaVersion = 3
    var groups: [CueGroup] = []
    var title = "Untitled Show"
    var backgroundPath = ""
    var cues: [Cue?] = Array(repeating: nil, count: 32)
    var busDB: [Double] = Array(repeating: 0, count: 6)
    var masterDB: Double = 0
    var manualFadeSeconds: Double = 3
    // Shortcuts belong to pad positions; moving a cue does not move keyboard layout.
    var padKeys: [String] = (1...9).map(String.init) + Array(repeating: "", count: 23)
    static let availablePadKeys = Array("0123456789abcdefghijklmnopqrstuvwyz").map(String.init)

    @discardableResult mutating func swapPads(_ source: Int, _ destination: Int) -> Bool {
        guard cues.indices.contains(source), cues.indices.contains(destination), source != destination else { return false }
        cues.swapAt(source, destination)
        return true
    }

    @discardableResult mutating func normalize() -> [String] {
        var notes: [String] = []
        if schemaVersion < 3 { notes.append(Self.migrationNotice) }
        schemaVersion = 3
        if cues.count != 32 { notes.append("Pad count adjusted to 32") }
        cues = Array(cues.prefix(32))
        cues += Array(repeating: nil, count: 32 - cues.count)
        if busDB.count != 6 { notes.append("Bus count adjusted to six") }
        busDB = Array(busDB.prefix(6))
        busDB += Array(repeating: 0, count: 6 - busDB.count)
        if busDB.contains(where: { !$0.isFinite || !(-60...6).contains($0) }) || !masterDB.isFinite || !(-60...6).contains(masterDB) || !manualFadeSeconds.isFinite || !(0...3600).contains(manualFadeSeconds) {
            notes.append("Invalid mix or fade settings repaired")
        }
        busDB = busDB.map { bounded($0, -60...6, fallback: 0) }
        masterDB = bounded(masterDB, -60...6, fallback: 0)
        manualFadeSeconds = bounded(manualFadeSeconds, 0...3600, fallback: 3)
        let originalKeys = padKeys
        padKeys = Array(padKeys.prefix(32))
        padKeys += Array(repeating: "", count: 32 - padKeys.count)
        var usedKeys: Set<String> = []
        for index in padKeys.indices {
            let key = padKeys[index].lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            if key.isEmpty { padKeys[index] = "" }
            else if Self.availablePadKeys.contains(key), usedKeys.insert(key).inserted { padKeys[index] = key }
            else { padKeys[index] = "" }
        }
        if padKeys != originalKeys { notes.append("Invalid or duplicate pad shortcuts repaired") }
        var seen: Set<UUID> = []
        for i in cues.indices {
            guard var cue = cues[i] else { continue }
            let original = cue
            if seen.contains(cue.id) { cue.id = UUID() }
            seen.insert(cue.id)
            cue.normalize()
            if cue != original { notes.append("Pad \(i + 1): invalid or unsupported settings repaired") }
            cues[i] = cue
        }
        groups = Array(groups.prefix(256))
        var groupIDs: Set<UUID> = []
        for i in groups.indices {
            if !groupIDs.insert(groups[i].id).inserted { groups[i].id = UUID(); notes.append("Duplicate group ID repaired") }
            groups[i].normalize()
        }
        return notes
    }
}

extension SoundProject {
    enum CodingKeys: String, CodingKey { case schemaVersion, title, cues, busDB, masterDB, manualFadeSeconds, padKeys, backgroundPath, groups }
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        guard (1...3).contains(schemaVersion) else {
            throw DecodingError.dataCorruptedError(forKey: .schemaVersion, in: c, debugDescription: "Unsupported project version")
        }
        groups = try c.decodeIfPresent([CueGroup].self, forKey: .groups) ?? []
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? title
        backgroundPath = try c.decodeIfPresent(String.self, forKey: .backgroundPath) ?? ""
        cues = try c.decodeIfPresent([Cue?].self, forKey: .cues) ?? cues
        busDB = try c.decodeIfPresent([Double].self, forKey: .busDB) ?? busDB
        masterDB = try c.decodeIfPresent(Double.self, forKey: .masterDB) ?? masterDB
        manualFadeSeconds = try c.decodeIfPresent(Double.self, forKey: .manualFadeSeconds) ?? manualFadeSeconds
        padKeys = try c.decodeIfPresent([String].self, forKey: .padKeys) ?? padKeys
    }
}

/// A fade interpolates from its current gain, so interruption never jumps back to an old gain.
struct FadeEnvelope: Equatable, Sendable {
    let initial: Float
    let target: Float
    let started: Double
    let duration: Double
    let curve: FadeCurve
    let stopWhenDone: Bool

    func fraction(at time: Double) -> Double {
        guard duration > 0 else { return 1 }
        return bounded((time - started) / duration, 0...1, fallback: 1)
    }
    func level(at time: Double) -> Float {
        let t = fraction(at: time)
        if t == 0 { return initial }
        if t == 1 { return target }
        let shaped: Double
        switch curve {
        case .linear: shaped = t
        case .smooth: shaped = t * t * (3 - 2 * t)
        case .equalPower:
            shaped = target >= initial ? sin(t * .pi / 2) : 1 - cos(t * .pi / 2)
        }
        return initial + (target - initial) * Float(shaped)
    }
}

struct AutomaticFades: Equatable, Sendable {
    let fadeIn: Double
    let fadeOut: Double
    init(cue: Cue, duration: Double) {
        var safe = cue; safe.normalize()
        let incoming = safe.autoFadeIn ? safe.fadeInSeconds : 0
        let outgoing = safe.autoFadeOut && !safe.loop ? safe.fadeOutSeconds : 0
        let sum = incoming + outgoing
        let scale = !safe.loop && sum > duration && sum > 0 ? max(0, duration) / sum : 1
        fadeIn = incoming * scale
        fadeOut = outgoing * scale
    }
}
