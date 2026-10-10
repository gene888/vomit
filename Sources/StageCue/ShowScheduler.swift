import Foundation
import Combine

struct OwnedPlayback: Equatable, Sendable {
    let resource: String
    let cueID: UUID
    let survives: Bool
}
enum PlaybackStatus: Equatable { case loading, playing, completed, failed(String) }
@MainActor protocol ShowPlaybackDriver: AnyObject {
    func resource(for action: GroupAction) throws -> String?
    func execute(_ action: GroupAction) throws -> OwnedPlayback?
    func status(_ playback: OwnedPlayback) -> PlaybackStatus
    func stop(_ playback: OwnedPlayback, fade: Double)
    func pause(_ playback: OwnedPlayback)
    func resume(_ playback: OwnedPlayback)
}
struct GroupExecution: Identifiable {
    let id: UUID
    let definition: CueGroup
    let ordinal: Int
    var state: ExecutionState = .running
    var error = ""
    var elapsed: Double = 0
    var nextEvent: Double?
    var pending: [ScheduledGroupAction]
    var started: Double
    var pausedAt: Double?
    var owned: [OwnedPlayback] = []
    let ancestry: [UUID]
    var children: [(UUID, Bool)] = []
    let manualVersions: [String: Int]
}

/// Continuous monotonic deadlines, immutable launch snapshots and resource leases.
/// No SwiftUI timers or blocking waits. Engine calls are short MainActor operations.
@MainActor final class ShowScheduler: ObservableObject {
    @Published private(set) var runs: [GroupExecution] = []
    weak var driver: (any ShowPlaybackDriver)?
    var groupLookup: (UUID) -> CueGroup? = { _ in nil }
    var onAdvance: (UUID) -> Void = { _ in }
    private let now: () -> Double
    private let automatic: Bool
    private var wake: Task<Void, Never>?
    private var generation = UUID()
    private var nextOrdinal = 0
    private var manualVersions: [String: Int] = [:]
    private var leases: [String: UUID] = [:]
    private var ticking = false
    private let clock = ContinuousClock()
    private let origin = ContinuousClock.now

    init(automatic: Bool = true, now: (() -> Double)? = nil) {
        self.automatic = automatic
        let origin = ContinuousClock.now
        self.now = now ?? { let d = origin.duration(to: .now).components; return Double(d.seconds) + Double(d.attoseconds) / 1e18 }
    }
    isolated deinit { wake?.cancel() }
    var activeRuns: [GroupExecution] { runs.filter { $0.state == .running || $0.state == .paused } }
    @discardableResult func launch(_ group: CueGroup, ancestry: [UUID] = []) -> UUID? {
        guard !ancestry.contains(group.id), ancestry.count < 32, activeRuns.count < 128 else { return nil }
        // Keep a bounded history without evicting active instances.
        if runs.count >= 512 { runs.removeAll { $0.state != .running && $0.state != .paused } }
        var safe = group; safe.normalize()
        let id = UUID(); nextOrdinal += 1
        runs.append(GroupExecution(id: id, definition: safe, ordinal: nextOrdinal,
                                   pending: ScheduledGroupAction.plan(safe), started: now(),
                                   ancestry: ancestry + [safe.id], manualVersions: manualVersions))
        if !ticking { tick() }
        return id
    }
    func manualOverride(_ resource: String) {
        manualVersions[resource, default: 0] += 1
        leases.removeValue(forKey: resource)
        for i in runs.indices { runs[i].owned.removeAll { $0.resource == resource } }
    }
    func stop(_ id: UUID, mode: GroupStopMode? = nil) {
        guard let index = runs.firstIndex(where: { $0.id == id }), [.running, .paused, .error].contains(runs[index].state) else { return }
        let run = runs[index]; let behavior = mode ?? run.definition.stopMode
        runs[index].state = .stopped; runs[index].pending = []; runs[index].nextEvent = nil
        for media in run.owned where leases[media.resource] == id {
            if !media.survives && behavior != .schedulesOnly { driver?.stop(media, fade: behavior == .fade ? run.definition.stopFade : 0) }
            else if run.state == .paused { driver?.resume(media) }
            leases.removeValue(forKey: media.resource)
        }
        runs[index].owned = []
        for (child, survives) in run.children where !survives { stop(child, mode: behavior) }
        arm()
    }
    func pause(_ id: UUID) {
        guard let i = runs.firstIndex(where: { $0.id == id }), runs[i].state == .running else { return }
        runs[i].state = .paused; runs[i].pausedAt = now()
        for media in runs[i].owned where leases[media.resource] == id { driver?.pause(media) }
        for (child, _) in runs[i].children { pause(child) }
        arm()
    }
    func resume(_ id: UUID) {
        guard let i = runs.firstIndex(where: { $0.id == id }), runs[i].state == .paused else { return }
        runs[i].started += max(0, now() - (runs[i].pausedAt ?? now()))
        runs[i].pausedAt = nil; runs[i].state = .running
        for media in runs[i].owned where leases[media.resource] == id { driver?.resume(media) }
        for (child, _) in runs[i].children { resume(child) }
        tick()
    }
    func cancelAll() {
        generation = UUID(); wake?.cancel(); wake = nil
        for id in runs.filter({ [.running, .paused, .error].contains($0.state) }).map(\.id) { stop(id, mode: .schedulesOnly) }
        leases.removeAll()
    }
    func reset() { cancelAll(); runs.removeAll(); manualVersions.removeAll() }
    func state(of id: UUID) -> ExecutionState? { runs.first { $0.id == id }?.state }
    func tick() {
        guard !ticking else { return }
        ticking = true
        defer { ticking = false; arm() }
        let time = now()
        // Gather all due actions and sort globally, so concurrent groups are deterministic.
        var due: [(Double, Int, Int, UUID, ScheduledGroupAction)] = []
        for i in runs.indices where runs[i].state == .running {
            runs[i].elapsed = max(0, time - runs[i].started)
            for event in runs[i].pending where event.offset <= runs[i].elapsed {
                due.append((runs[i].started + event.offset, runs[i].ordinal, event.ordinal, runs[i].id, event))
            }
        }
        due.sort { a, b in a.0 != b.0 ? a.0 < b.0 : a.1 != b.1 ? a.1 < b.1 : a.2 < b.2 }
        for (_, _, _, id, event) in due {
            guard let i = runs.firstIndex(where: { $0.id == id }), runs[i].state == .running,
                  runs[i].pending.contains(where: { $0.action.id == event.action.id }) else { continue }
            runs[i].pending.removeAll { $0.action.id == event.action.id }
            let action = event.action
            do {
                if action.kind == .wait { continue }
                if action.kind == .triggerGroup {
                    guard let target = action.groupID, let group = groupLookup(target),
                          let child = launch(group, ancestry: runs[i].ancestry) else { throw MediaIssue(message: "Missing group, cyclic trigger or execution limit") }
                    runs[i].children.append((child, action.survivesTermination))
                    continue
                }
                if action.kind == .advance {
                    if manualVersions["sequence", default: 0] == runs[i].manualVersions["sequence", default: 0] { onAdvance(id) }
                    continue
                }
                guard let driver else { throw MediaIssue(message: "Playback driver unavailable") }
                if let resource = try driver.resource(for: action),
                   manualVersions[resource, default: 0] != runs[i].manualVersions[resource, default: 0] { continue }
                if let media = try driver.execute(action) {
                    if let previous = leases[media.resource], previous != id,
                       let old = runs.firstIndex(where: { $0.id == previous }) { runs[old].owned.removeAll { $0.resource == media.resource } }
                    leases[media.resource] = id
                    runs[i].owned.removeAll { $0.resource == media.resource }
                    runs[i].owned.append(media)
                }
            } catch {
                runs[i].error = error.localizedDescription
                runs[i].state = .error; runs[i].pending = []
            }
        }
        for i in runs.indices where runs[i].state == .running {
            runs[i].nextEvent = runs[i].pending.first.map { max(0, $0.offset - runs[i].elapsed) }
            for media in runs[i].owned {
                if case .failed(let error) = driver?.status(media) { runs[i].state = .error; runs[i].error = error; runs[i].pending = []; break }
            }
            if runs[i].state == .running, runs[i].pending.isEmpty, runs[i].definition.automaticCompletion,
               runs[i].owned.allSatisfy({ driver?.status($0) == .completed }),
               runs[i].children.allSatisfy({ ![ExecutionState.running, .paused].contains(state(of: $0.0) ?? .completed) }) {
                runs[i].state = .completed
                for media in runs[i].owned where leases[media.resource] == runs[i].id { leases.removeValue(forKey: media.resource) }
            }
        }
    }
    private func arm() {
        guard automatic else { return }
        wake?.cancel(); wake = nil
        guard activeRuns.contains(where: { $0.state == .running }) else { return }
        let time = now()
        let next = runs.filter { $0.state == .running }.compactMap { run in run.pending.first.map { run.started + $0.offset } }.min()
        let seconds = min(0.025, max(0.001, (next ?? (time + 0.025)) - time))
        let token = generation
        wake = Task { [weak self, clock] in
            do { try await clock.sleep(for: .seconds(seconds)) } catch { return }
            guard !Task.isCancelled, let self, self.generation == token else { return }
            self.tick()
        }
    }
}

extension ShowState: ShowPlaybackDriver {
    func referencedCue(_ id: UUID?) throws -> Cue {
        guard let id, let cue = project.cues.compactMap({ $0 }).first(where: { $0.id == id }), cue.kind != .group else {
            throw MediaIssue(message: "Missing media cue reference")
        }
        return cue
    }
    func resource(for action: GroupAction) throws -> String? {
        if action.kind.needsCue {
            let cue = try referencedCue(action.cueID)
            return cue.kind == .audio ? "audio:\(cue.id)" : "video"
        }
        switch action.kind {
        case .bus: return "bus:\(action.bus)"
        case .blackout: return "video"
        case .page: return "page"
        default: return nil
        }
    }
    func execute(_ action: GroupAction) throws -> OwnedPlayback? {
        if action.kind == .bus {
            project.busDB[action.bus] = action.levelDB; sound.applyMix(project); return nil
        }
        if action.kind == .blackout { video.blackout = action.blackout; return nil }
        if action.kind == .page { throw MediaIssue(message: "Soundboard pages will be available in milestone 0.3C") }
        var cue = try referencedCue(action.cueID)
        let audio = cue.kind == .audio
        switch action.kind {
        case .play, .cut, .crossfade:
            guard action.kind == .play || !audio else { throw MediaIssue(message: "Cut/crossfade requires video or image") }
            cue.mode = .oneShot // Automation starts explicitly rather than toggling existing playback.
            if action.overrideLevel { cue.gainDB = action.levelDB; cue.soundtrackDB = min(0, action.levelDB) }
            if action.overrideFade { cue.autoFadeIn = true; cue.fadeInSeconds = action.duration; cue.videoFadeIn = action.duration }
            if action.kind == .cut { cue.transition = .cut }
            if action.kind == .crossfade { cue.transition = .crossfade; cue.videoFadeIn = action.duration }
            if audio { sound.play(cue) } else { video.play(cue) }
            return OwnedPlayback(resource: audio ? "audio:\(cue.id)" : "video", cueID: cue.id, survives: action.survivesTermination)
        case .stop:
            if audio { sound.stop(cue.id) } else { video.stopCue(cue.id) }
        case .pause:
            if audio { sound.pause(cue.id) } else if video.currentCue?.id == cue.id || video.loadingCueID == cue.id { video.pause() }
        case .resume:
            if audio { sound.resume(cue.id) } else if video.currentCue?.id == cue.id || video.loadingCueID == cue.id { video.resume() }
        case .fade:
            if audio { sound.fadeToDB(cue.id, decibels: action.levelDB, seconds: action.duration) }
            else if video.currentCue?.id == cue.id { video.fade(to: Double(amplitude(min(0, action.levelDB))), seconds: action.duration) }
        case .silence:
            if audio { sound.fadeToSilence(cue.id, seconds: action.duration) }
            else if video.currentCue?.id == cue.id { video.fade(to: 0, seconds: action.duration) }
        case .fadeStop:
            if audio { sound.fadeOutAndStop(cue.id, seconds: action.duration) } else { video.stopCue(cue.id, seconds: action.duration) }
        default: break
        }
        return nil
    }
    func status(_ playback: OwnedPlayback) -> PlaybackStatus {
        if playback.resource == "video" {
            if video.failedCueID == playback.cueID { return .failed(video.error) }
            if video.loadingCueID == playback.cueID { return .loading }
            return video.activeIDs.contains(playback.cueID) ? .playing : .completed
        }
        if sound.failed.contains(playback.cueID) { return .failed("Audio could not be loaded; check media and engine") }
        if sound.loading.contains(playback.cueID) { return .loading }
        return sound.active.contains(playback.cueID) ? .playing : .completed
    }
    func stop(_ playback: OwnedPlayback, fade: Double) {
        if playback.resource == "video" { video.stopCue(playback.cueID, seconds: fade) }
        else if fade > 0 { sound.fadeOutAndStop(playback.cueID, seconds: fade) }
        else { sound.stop(playback.cueID) }
    }
    func pause(_ playback: OwnedPlayback) {
        if playback.resource == "video" { video.pause() } else { sound.pause(playback.cueID) }
    }
    func resume(_ playback: OwnedPlayback) {
        if playback.resource == "video" { video.resume() } else { sound.resume(playback.cueID) }
    }
}
