import Foundation
import Combine

/// Sequences launch groups through the same ownership/cancellation system as pads.
@MainActor final class SequenceEngine: ObservableObject {
    @Published private(set) var definition: CueSequence?
    @Published private(set) var state: ExecutionState = .ready
    @Published private(set) var current = -1
    @Published private(set) var next = 0
    @Published private(set) var stepStates: [UUID: ExecutionState] = [:]
    @Published private(set) var error = ""
    @Published private(set) var elapsed: Double = 0
    @Published private(set) var countdown: Double?
    let scheduler: ShowScheduler
    var resolveStep: (SequenceStep) throws -> CueGroup = { _ in throw MediaIssue(message: "No project") }
    var validateFollow: (SequenceStep) throws -> Void = { _ in }
    private var manualSnapshot: [String: Int]?
    private var launched: [UUID] = []
    private var currentRun: UUID?
    private var started: Double?
    private var stepStarted: Double = 0
    private var pausedAt: Double?
    private var wake: Task<Void, Never>?
    private var generation = UUID()
    private let automatic: Bool
    private let now: () -> Double
    private let clock = ContinuousClock()

    init(scheduler: ShowScheduler, automatic: Bool = true, now: (() -> Double)? = nil) {
        self.scheduler = scheduler; self.automatic = automatic
        let origin = ContinuousClock.now
        self.now = now ?? { let d = origin.duration(to: .now).components; return Double(d.seconds) + Double(d.attoseconds) / 1e18 }
    }
    isolated deinit { wake?.cancel() }
    var currentStep: SequenceStep? { guard let definition, definition.steps.indices.contains(current) else { return nil }; return definition.steps[current] }
    var nextStep: SequenceStep? { guard let definition, definition.steps.indices.contains(next) else { return nil }; return definition.steps[next] }
    func select(_ sequence: CueSequence) {
        stop(); manualSnapshot = nil; var safe = sequence; safe.normalize(); definition = safe; current = -1; next = 0; stepStates = [:]; error = ""; state = .ready; elapsed = 0; started = nil
    }
    func unload() { stop(); definition = nil; current = -1; next = 0; stepStates = [:]; started = nil; elapsed = 0; error = ""; state = .ready; manualSnapshot = nil }
    func go(manual: Bool = false) {
        guard state != .paused, let definition else { return }
        if state == .error { return } // Fix/reset deliberately; never advance silently through errors.
        guard definition.steps.indices.contains(next) else {
            finish(); return
        }
        if let currentStep { stepStates[currentStep.id] = .completed }
        current = next; next += 1
        let step = definition.steps[current]
        do {
            if step.advancement == .follow { try validateFollow(step) }
            let group = try resolveStep(step)
            if manual || manualSnapshot == nil { manualSnapshot = scheduler.resourceVersions }
            guard let id = scheduler.launch(group, manualSnapshot: manualSnapshot) else { throw MediaIssue(message: "Execution limit reached") }
            if let previous = currentRun { scheduler.protectedRunIDs.remove(previous) }
            scheduler.protectedRunIDs.insert(id)
            currentRun = id; launched.append(id)
            started = started ?? now(); stepStarted = now()
            state = .running; stepStates[step.id] = .running; error = ""
            if scheduler.state(of: id) == .error { fail(scheduler.runs.first { $0.id == id }?.error ?? "Cue failed") }
            arm()
        } catch { fail(error.localizedDescription) }
    }
    func advanceFromGroup(_ id: UUID) {
        if launched.contains(id), id != currentRun { return }
        go()
    }
    func pause() {
        guard state == .running else { return }
        state = .paused; pausedAt = now()
        if let currentStep { stepStates[currentStep.id] = .paused }
        for id in launched { scheduler.pause(id) }
        wake?.cancel(); wake = nil
    }
    func resume() {
        guard state == .paused else { return }
        let interval = max(0, now() - (pausedAt ?? now()))
        started = started.map { $0 + interval }; stepStarted += interval; pausedAt = nil
        state = .running
        if let currentStep { stepStates[currentStep.id] = .running }
        for id in launched { scheduler.resume(id) }
        tick()
    }
    func stop() {
        generation = UUID(); wake?.cancel(); wake = nil
        for id in launched { scheduler.stop(id, mode: .immediate) }
        if let currentRun { scheduler.protectedRunIDs.remove(currentRun) }
        launched = []; currentRun = nil; countdown = nil
        if let currentStep { stepStates[currentStep.id] = .stopped }
        state = .stopped
    }
    func emergencyCancel() {
        generation = UUID(); wake?.cancel(); wake = nil
        if let currentRun { scheduler.protectedRunIDs.remove(currentRun) }
        launched = []; currentRun = nil; countdown = nil; state = .stopped
        if let currentStep { stepStates[currentStep.id] = .stopped }
    }
    func reset() {
        stop(); current = -1; next = 0; stepStates = [:]; elapsed = 0; started = nil; error = ""; state = .ready; manualSnapshot = nil
    }
    /// Skip the upcoming row without playing it. Existing playback remains alone.
    func skip() {
        guard let definition, definition.steps.indices.contains(next), state != .paused else { return }
        stepStates[definition.steps[next].id] = .completed; next += 1
    }
    /// Cancel current scheduled follow/automation and prepare the previous row for GO.
    func back() {
        guard definition != nil else { return }
        if let id = currentRun { scheduler.stop(id, mode: .schedulesOnly) }
        generation = UUID(); wake?.cancel(); wake = nil
        if let currentRun { scheduler.protectedRunIDs.remove(currentRun) }
        next = max(0, current - 1); current = -1; currentRun = nil; countdown = nil; state = .ready
    }
    func tick() {
        guard state == .running, let step = currentStep else { return }
        elapsed = max(0, now() - (started ?? now()))
        let age = max(0, now() - stepStarted)
        if let id = currentRun, scheduler.state(of: id) == .error {
            fail(scheduler.runs.first { $0.id == id }?.error ?? "Cue failed"); return
        }
        switch step.advancement {
        case .manual: countdown = nil
        case .timed:
            countdown = max(0, step.delay - age)
            if age >= step.delay { go(); return }
        case .follow:
            countdown = step.completionAfter > 0 ? max(0, step.completionAfter - age) : nil
            let finished = step.completionAfter > 0 ? age >= step.completionAfter : currentRun.map { scheduler.state(of: $0) == .completed } ?? false
            if finished { go(); return }
        }
        arm()
    }
    private func finish() {
        if let currentStep { stepStates[currentStep.id] = .completed }
        state = .completed; countdown = nil; wake?.cancel(); wake = nil
    }
    private func fail(_ message: String) {
        error = message; state = .error; countdown = nil
        if let currentStep { stepStates[currentStep.id] = .error }
        wake?.cancel(); wake = nil
    }
    private func arm() {
        guard automatic, state == .running else { return }
        wake?.cancel(); let token = generation
        wake = Task { [weak self, clock] in
            do { try await clock.sleep(for: .milliseconds(25)) } catch { return }
            guard !Task.isCancelled, let self, self.generation == token else { return }
            self.tick()
        }
    }
}

extension ShowState {
    func sequenceGroup(for step: SequenceStep) throws -> CueGroup {
        if step.target == .group {
            guard let id = step.groupID, let group = project.groups.first(where: { $0.id == id }) else { throw MediaIssue(message: "Missing sequence group") }
            return group
        }
        let cue = try referencedCue(step.cueID)
        return CueGroup(title: step.title, actions: [GroupAction(cueID: cue.id)])
    }
    func validateSequenceFollow(_ step: SequenceStep) throws {
        guard step.completionAfter == 0 else { return }
        if step.target == .cue {
            let cue = try referencedCue(step.cueID)
            guard !cue.loop, cue.kind != .image, !cue.holdLastFrame else {
                throw MediaIssue(message: "Follow requires an explicit completion time for loops, images or held frames")
            }
        } else {
            var visited: Set<UUID> = []
            func persistent(_ id: UUID?) throws -> Bool {
                guard let id, visited.insert(id).inserted,
                      let group = project.groups.first(where: { $0.id == id }) else { throw MediaIssue(message: "Missing or cyclic sequence group") }
                if !group.automaticCompletion { return true }
                for action in group.actions where action.enabled {
                    if action.kind == .triggerGroup, try persistent(action.groupID) { return true }
                    if [.play, .cut, .crossfade, .fadeVisual].contains(action.kind) {
                        let cue = try referencedCue(action.cueID)
                        let plan = ScheduledGroupAction.plan(group)
                        let played = plan.first { $0.action.id == action.id }
                        let explicitStop = plan.contains { event in
                            guard let played else { return false }
                            return event.action.cueID == cue.id && [.stop, .fadeStop].contains(event.action.kind) &&
                                (event.offset > played.offset || event.offset == played.offset && event.ordinal > played.ordinal)
                        }
                        if (cue.loop || cue.kind == .image || cue.holdLastFrame) && !explicitStop { return true }
                    }
                }
                visited.remove(id)
                return false
            }
            if try persistent(step.groupID) { throw MediaIssue(message: "Follow requires an explicit completion time for this persistent group") }
        }
    }
}
