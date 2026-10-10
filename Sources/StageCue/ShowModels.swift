import Foundation

enum GroupStopMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case immediate = "Immediate", fade = "Fade and stop", schedulesOnly = "Cancel scheduled actions only"
    var id: String { rawValue }
}
enum ShowActionKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case play = "Play cue", stop = "Stop cue", pause = "Pause cue", resume = "Resume cue"
    case fade = "Fade cue to dB", silence = "Fade to silence", fadeStop = "Fade and stop"
    case bus = "Set bus dB", cut = "Cut to visual", crossfade = "Crossfade to visual"
    case blackout = "Video blackout", wait = "Wait", triggerGroup = "Trigger group"
    case page = "Change page", advance = "Advance sequence"
    var id: String { rawValue }
    var needsCue: Bool { [.play, .stop, .pause, .resume, .fade, .silence, .fadeStop, .cut, .crossfade].contains(self) }
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
