import Foundation

enum GroupStopMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case immediate = "Immediate", fade = "Fade and stop", schedulesOnly = "Cancel scheduled actions only"
    var id: String { rawValue }
}
enum ShowActionKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case play = "Play cue", stop = "Stop cue", pause = "Pause cue", resume = "Resume cue"
    case fade = "Fade cue to dB", silence = "Fade to silence", fadeStop = "Fade and stop"
    case bus = "Set bus dB", cut = "Cut to visual", crossfade = "Crossfade to visual", fadeVisual = "Fade to visual"
    case blackout = "Video blackout", wait = "Wait", triggerGroup = "Trigger group"
    case page = "Change page", advance = "Advance sequence"
    var id: String { rawValue }
    var needsCue: Bool { [.play, .stop, .pause, .resume, .fade, .silence, .fadeStop, .cut, .crossfade, .fadeVisual].contains(self) }
}
struct GroupAction: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var kind: ShowActionKind = .play
    var cueID: UUID?
    var groupID: UUID?
    var delay: Double = 0
    var duration: Double = 0
    var levelDB: Double = -6
    var overrideLevel = false
    var overrideFade = false
    var bus = 0
    var page = 0
    var enabled = true
    var survivesTermination = false
    var blackout = true
    mutating func normalize() {
        delay = bounded(delay, 0...86400, fallback: 0)
        duration = bounded(duration, 0...86400, fallback: 0)
        levelDB = bounded(levelDB, -60...6, fallback: -6)
        bus = min(5, max(0, bus)); page = max(0, page)
    }
}
struct CueGroup: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var title = "New Group"
    var actions: [GroupAction] = []
    var stopMode: GroupStopMode = .immediate
    var stopFade: Double = 3
    var automaticCompletion = true
    mutating func normalize() {
        stopFade = bounded(stopFade, 0...3600, fallback: 3)
        actions = Array(actions.prefix(512))
        var seen: Set<UUID> = []
        for i in actions.indices {
            if !seen.insert(actions[i].id).inserted { actions[i].id = UUID() }
            actions[i].normalize()
        }
    }
}
enum ExecutionState: String, Sendable { case ready = "Ready", running = "Running", paused = "Paused", completed = "Completed", error = "Error", stopped = "Stopped" }
struct ScheduledGroupAction: Equatable, Sendable {
    let action: GroupAction
    let offset: Double
    let ordinal: Int
    static func plan(_ group: CueGroup) -> [Self] {
        var cursor: Double = 0
        return group.actions.enumerated().compactMap { index, original in
            var action = original; action.normalize()
            guard action.enabled else { return nil }
            var offset = cursor + action.delay
            if action.kind == .wait { cursor = offset + action.duration; offset = cursor }
            return Self(action: action, offset: offset, ordinal: index)
        }.sorted { $0.offset == $1.offset ? $0.ordinal < $1.ordinal : $0.offset < $1.offset }
    }
}

enum AdvanceMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case manual = "Manual", timed = "Timed", follow = "Follow"
    var id: String { rawValue }
}
enum SequenceTarget: String, Codable, CaseIterable, Identifiable, Sendable {
    case cue = "Cue", group = "Group"
    var id: String { rawValue }
}
struct SequenceStep: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var title = "New step"
    var target: SequenceTarget = .cue
    var cueID: UUID?
    var groupID: UUID?
    var advancement: AdvanceMode = .manual
    var delay: Double = 1
    // Explicit completion for loops/stills/held pictures/non-completing groups.
    // It advances the sequence without terminating the media.
    var completionAfter: Double = 0
    mutating func normalize() {
        delay = bounded(delay, 0...86400, fallback: 1)
        completionAfter = bounded(completionAfter, 0...86400, fallback: 0)
    }
}
struct CueSequence: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var title = "New Sequence"
    var steps: [SequenceStep] = []
    mutating func normalize() {
        steps = Array(steps.prefix(1024)); var seen: Set<UUID> = []
        for i in steps.indices {
            if !seen.insert(steps[i].id).inserted { steps[i].id = UUID() }
            steps[i].normalize()
        }
    }
}

struct SoundboardPage: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var title = "New Page"
    var cues: [Cue?] = Array(repeating: nil, count: 32)
    var padKeys: [String] = (1...9).map(String.init) + Array(repeating: "", count: 23)
}
enum ShowCommand: String, Codable, CaseIterable, Identifiable, Sendable {
    case go = "GO", pause = "Pause / Resume", stop = "Stop sequence", next = "Skip next", previous = "Previous", emergency = "Emergency Stop All", blackout = "Video Blackout"
    var id: String { rawValue }
    var defaultKey: String {
        switch self { case .go: return "g"; case .pause: return "p"; case .stop: return "s"; case .next: return "]"; case .previous: return "["; case .emergency: return "."; case .blackout: return "b" }
    }
}
struct ShowConfiguration: Codable, Equatable, Sendable {
    var showMode = false
    var sequenceID: UUID?
    var mainPageTitle = "Main"
    var keys: [String: String] = Dictionary(uniqueKeysWithValues: ShowCommand.allCases.map { ($0.rawValue, $0.defaultKey) })
    static let availableKeys = Array("abcdefghijklmnopqrstuvwxyz0123456789[]./").map(String.init)
    mutating func normalize() {
        var seen: Set<String> = []
        for command in ShowCommand.allCases {
            let key = (keys[command.rawValue] ?? command.defaultKey).lowercased()
            keys[command.rawValue] = Self.availableKeys.contains(key) && seen.insert(key).inserted ? key : ""
        }
        keys = keys.filter { ShowCommand(rawValue: $0.key) != nil }
    }
}

extension SoundProject {
    func showReferenceIssues() -> [String] {
        var issues: [String] = []
        let mediaIDs = Set(allCues.filter { $0.kind != .group }.map(\.id))
        let groupIDs = Set(groups.map(\.id))
        for cue in allCues where cue.kind == .group {
            if cue.groupID.map({ groupIDs.contains($0) }) != true { issues.append("\(cue.title): missing pad group reference") }
        }
        for group in groups {
            for (i, action) in group.actions.enumerated() where action.enabled {
                if action.kind.needsCue, action.cueID.map({ mediaIDs.contains($0) }) != true { issues.append("\(group.title), action \(i + 1): missing media cue") }
                if action.kind == .triggerGroup, action.groupID.map({ groupIDs.contains($0) }) != true { issues.append("\(group.title), action \(i + 1): missing group") }
                if action.kind == .page, !(0...additionalPages.count).contains(action.page) { issues.append("\(group.title), action \(i + 1): missing page") }
            }
        }
        for sequence in sequences {
            for (i, step) in sequence.steps.enumerated() {
                let valid = step.target == .cue ? step.cueID.map { mediaIDs.contains($0) } : step.groupID.map { groupIDs.contains($0) }
                if valid != true { issues.append("\(sequence.title), step \(i + 1): missing target") }
            }
        }
        var checked: Set<UUID> = []
        func visit(_ id: UUID, path: Set<UUID>) {
            if path.contains(id) { issues.append("Cyclic group trigger detected"); return }
            guard !checked.contains(id), let group = groups.first(where: { $0.id == id }) else { return }
            var path = path; path.insert(id)
            for action in group.actions where action.enabled && action.kind == .triggerGroup {
                if let target = action.groupID { visit(target, path: path) }
            }
            checked.insert(id)
        }
        for group in groups { visit(group.id, path: []) }
        return issues
    }
}
