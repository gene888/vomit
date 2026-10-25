import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Combine

@MainActor final class ShowState: ObservableObject {
    @Published var project = SoundProject() { didSet { scheduleAutosave() } }
    @Published private(set) var page = 0
    var pads: [Cue?] {
        get { page == 0 ? project.cues : project.additionalPages[page - 1].cues }
        set { if page == 0 { project.cues = newValue } else { project.additionalPages[page - 1].cues = newValue } }
    }
    var padKeys: [String] {
        get { page == 0 ? project.padKeys : project.additionalPages[page - 1].padKeys }
        set { if page == 0 { project.padKeys = newValue } else { project.additionalPages[page - 1].padKeys = newValue } }
    }
    func changePage(_ index: Int, manual: Bool = true) {
        guard (0...project.additionalPages.count).contains(index) else { message = "Missing soundboard page"; return }
        if manual { scheduler.manualOverride("page") }
        for request in mediaAssignments.values { request.1.cancel() }; mediaAssignments.removeAll()
        page = index; selected = 0
    }
    func addPage() {
        guard project.additionalPages.count < 31 else { message = "Maximum 32 pages"; return }
        project.additionalPages.append(SoundboardPage(title: "Page \(project.additionalPages.count + 2)"))
        changePage(project.additionalPages.count)
    }
    @Published var editingShowKeys = false
    @Published var selected = 0
    var selectedCue: Cue? {
        guard pads.indices.contains(selected) else { return nil }
        return pads[selected]
    }
    @Published var message = ""
    @Published var preflightItems: [String] = []
    @Published var checking = false
    @Published var mediaReport = MediaReport()
    @Published var mediaBusy = false
    @Published var mediaProgress = ""
    @Published var editingMedia = false
    var projectRoot: URL?
    let mediaLibrary = MediaLibrary()
    let mediaResolver = MediaResolver()
    let spotlightSearch = SpotlightMediaSearch()
    var mediaTask: Task<Void, Never>?
    var mediaOperation = UUID()
    let sound = SoundEngine()
    let video = VideoEngine()
    let scheduler = ShowScheduler()
    lazy var sequence = SequenceEngine(scheduler: scheduler)
    private var sequenceChanges: AnyCancellable?
    @Published var editingSequences = false
    private var schedulerChanges: AnyCancellable?
    @Published var editingGroups = false
    lazy var output = VideoOutputController(engine: video)
    private let visualLoader = VisualMediaLoader()
    private var videoChanges: AnyCancellable?
    private var saveURL: URL?
    private let writer = ProjectWriter()
    private var autosaveTask: Task<Void, Never>?
    private var revision = 0
    private var engineChanges: AnyCancellable?
    private var terminationObserver: NSObjectProtocol?
    private var keyboardMonitor: Any?
    private var recoveredAutosave = true
    private let assignmentLoader = MediaLoader()
    private var documentToken = UUID()
    private var mediaAssignments: [Int: (UUID, Task<Void, Never>)] = [:]
    private let autosaveURL: URL

    init(autosaveURL: URL? = nil) {
        self.autosaveURL = autosaveURL ?? Self.defaultURL
        if FileManager.default.fileExists(atPath: self.autosaveURL.path) {
            do {
                let (saved, notes) = try ProjectStore.load(from: self.autosaveURL)
                project = saved
                if !notes.isEmpty { message = notes.joined(separator: "; ") }
            } catch {
                recoveredAutosave = false
                message = "Autosave could not be opened. Original preserved; open a project or explicitly Save to replace it. \(error.localizedDescription)"
            }
        }
        sequence.resolveStep = { [weak self] step in
            guard let self else { throw MediaIssue(message: "Project closed") }; return try self.sequenceGroup(for: step)
        }
        sequence.validateFollow = { [weak self] step in try self?.validateSequenceFollow(step) }
        scheduler.onAdvance = { [weak self] id in
            Task { @MainActor [weak self] in
                guard let self, let run = self.scheduler.runs.first(where: { $0.id == id }), run.state != .stopped, run.state != .error,
                      self.scheduler.resourceVersions["sequence", default: 0] == run.manualVersions["sequence", default: 0] else { return }
                self.sequence.advanceFromGroup(id)
            }
        }
        sequenceChanges = sequence.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
        sound.onConfigurationChange = { [weak self] in self?.sequence.emergencyCancel(); self?.scheduler.cancelAll() }
        scheduler.driver = self
        scheduler.groupLookup = { [weak self] id in self?.project.groups.first { $0.id == id } }
        schedulerChanges = scheduler.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
        if let id = project.show.sequenceID, let item = project.sequences.first(where: { $0.id == id }) { sequence.select(item) }
        sound.applyMix(project)
        video.setBackground(project.backgroundPath)
        videoChanges = Publishers.Merge3(
            video.$activeIDs.dropFirst().map { _ in () },
            video.$paused.dropFirst().map { _ in () },
            video.$loading.dropFirst().map { _ in () }
        ).sink { [weak self] _ in self?.objectWillChange.send() }
        // Catch performance Option shortcuts before text fields interpret them as symbols.
        keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated {
                let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                guard let key = event.charactersIgnoringModifiers?.lowercased(), let self else { return false }
                if flags == [.command], key == "." {
                    if !event.isARepeat { self.stopAll() }; return true
                }
                guard NSApp.modalWindow == nil, let window = event.window,
                      window == NSApp.keyWindow, window.sheetParent == nil, window.attachedSheet == nil else { return false }
                if flags == [.command, .option] { return self.performShowKey(key, execute: !event.isARepeat) }
                guard flags.contains(.option), !flags.contains(.command), !flags.contains(.control) else { return false }
                // Ignore held-key repeats once a recognized command has been handled.
                return self.performPadKey(key, shift: flags.contains(.shift), execute: !event.isARepeat)
            }
            return handled ? nil : event
        }
        // Forward nested engine changes so pads, loading indicators and errors update immediately.
        engineChanges = sound.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
        terminationObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.autosaveTask?.cancel(); self.mediaTask?.cancel(); self.spotlightSearch.finish([])
                if self.recoveredAutosave { try? ProjectStore.save(self.project, to: self.autosaveURL) }
                self.sequence.emergencyCancel(); self.scheduler.cancelAll(); self.sound.shutdown(); self.video.shutdown(); self.output.close()
            }
        }
    }
    isolated deinit {
        autosaveTask?.cancel()
        mediaTask?.cancel()
        for request in mediaAssignments.values { request.1.cancel() }
        if let terminationObserver { NotificationCenter.default.removeObserver(terminationObserver) }
        if let keyboardMonitor { NSEvent.removeMonitor(keyboardMonitor) }
    }
    static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("StageCue", isDirectory: true).appendingPathComponent("autosave-v0.4.json")
    }
    private func scheduleAutosave() {
        guard recoveredAutosave else { return }
        autosaveTask?.cancel()
        revision += 1
        let version = revision
        let snapshot = project
        let destination = autosaveURL
        autosaveTask = Task { [weak self, writer] in
            do {
                try await Task.sleep(for: .milliseconds(350))
                try Task.checkCancellation()
                try await writer.save(snapshot, to: destination, revision: version)
            } catch is CancellationError { }
            catch { self?.message = "Autosave failed: \(error.localizedDescription)" }
        }
    }
    func save() { saveProject(to: saveURL) }
    func saveProject(to destination: URL?) {
        let snapshot = project
        let token = documentToken
        revision += 1
        let version = revision
        Task {
            do {
                let prepared = try await mediaLibrary.catalog(snapshot, root: destination?.deletingLastPathComponent() ?? projectRoot)
                guard token == documentToken else { return }
                try await writer.save(prepared, to: autosaveURL, revision: version)
                if let destination { try await writer.save(prepared, to: destination, revision: version) }
                if token == documentToken {
                    if project == snapshot { project = prepared }
                    recoveredAutosave = true
                    if let destination { saveURL = destination; projectRoot = destination.deletingLastPathComponent() }
                    message = destination == nil ? "Saved local autosave. Use Export Project Only for a named project file." : "Project saved; media remains in its existing locations"
                }
            } catch { message = "Save failed: \(error.localizedDescription)" }
        }
    }
    func export() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.stagecueProject, .json]
        panel.nameFieldStringValue = "\(project.title).stagecue"
        if panel.runModal() == .OK, let url = panel.url { saveProject(to: url) }
    }
    func open() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.stagecueProject, .json]
        if panel.runModal() == .OK, let url = panel.url { openProject(url) }
    }
    func openProject(_ url: URL) {
        let oldToken = documentToken
        Task {
            do {
                let (decoded, notes) = try await Task.detached { try ProjectStore.load(from: url) }.value
                guard documentToken == oldToken else { return }
                stopAll()
                mediaTask?.cancel(); spotlightSearch.finish([])
                documentToken = UUID(); mediaOperation = UUID()
                for request in mediaAssignments.values { request.1.cancel() }; mediaAssignments.removeAll()
                recoveredAutosave = true; page = 0
                scheduler.reset(); sequence.unload()
                project = decoded; mediaReport = MediaReport()
                projectRoot = url.deletingLastPathComponent()
                if let id = project.show.sequenceID, let item = project.sequences.first(where: { $0.id == id }) { sequence.select(item) }
                let migrated = notes.contains(SoundProject.migrationNotice)
                saveURL = migrated ? nil : url
                sound.applyMix(project); video.setBackground(project.backgroundPath)
                message = migrated ? "Older project opened. Export Project Only to a new 0.4 copy to preserve the original." : "Project opened"
                resolveMediaAutomatically()
            } catch { message = "Open failed: \(error.localizedDescription)" }
        }
    }
    func resolveMediaAutomatically() {
        mediaTask?.cancel()
        let snapshot = project, root = projectRoot, token = documentToken
        let operation = UUID(); mediaOperation = operation; mediaBusy = true
        mediaTask = Task {
            defer { if mediaOperation == operation { mediaBusy = false } }
            do {
                var result = try await mediaResolver.resolve(snapshot, root: root)
                let missing = result.report.items.filter { $0.status == .missing || $0.status == .ambiguous }
                if !missing.isEmpty {
                    mediaProgress = "Searching Spotlight for missing media…"
                    let urls = await spotlightSearch.search(filenames: missing.map { $0.asset.filename })
                    try Task.checkCancellation()
                    if !urls.isEmpty { result = try await mediaResolver.resolve(snapshot, root: root, spotlight: urls) }
                }
                guard documentToken == token, mediaOperation == operation else { return }
                guard project == snapshot else { message = "Project changed during media check; open Media to check again"; return }
                project = result.project; mediaReport = result.report
                video.setBackground(project.backgroundPath)
                mediaProgress = result.report.summary
                message = "Media check: \(result.report.count(.missing)) missing, \(result.report.count(.ambiguous)) need review. Open Media for details."
            } catch is CancellationError { }
            catch { if documentToken == token { message = "Media check failed: \(error.localizedDescription)" } }
        }
    }
    func unavailable(_ cue: Cue) -> Bool {
        mediaReport.items.contains { ($0.status == .missing || $0.status == .ambiguous) && $0.asset.cueIDs.contains(cue.id) }
    }
    func detachMedia(_ cueID: UUID) {
        for i in project.media.assets.indices { project.media.assets[i].cueIDs.removeAll { $0 == cueID } }
        project.media.assets.removeAll { $0.cueIDs.isEmpty && !$0.background }
        mediaReport.items.removeAll { $0.asset.cueIDs.contains(cueID) }
    }
    func setCue(_ cue: Cue?) {
        guard pads.indices.contains(selected) else { return }
        mediaAssignments.removeValue(forKey: selected)?.1.cancel()
        if let old = pads[selected] { stopCue(old) }
        if let old = pads[selected] { detachMedia(old.id) }
        pads[selected] = cue
    }
    @discardableResult func performPadKey(_ key: String, shift: Bool = false, execute: Bool = true) -> Bool {
        if key == "x" {
            if execute, let cue = selectedCue {
                if shift { fadeStop(cue) }
                else { stopCue(cue) }
            }
            return true
        }
        guard !shift else { return false }
        if key == "\u{F700}" || key == "\u{F701}" {
            if execute, let cue = selectedCue {
                if key == "\u{F700}" { fadeUp(cue) }
                else { fadeDown(cue) }
            }
            return true
        }
        guard !key.isEmpty, let index = padKeys.firstIndex(of: key) else { return false }
        if execute { trigger(index) }
        return true
    }
    @discardableResult func performShowKey(_ key: String, execute: Bool = true) -> Bool {
        guard !key.isEmpty, let command = ShowCommand.allCases.first(where: { project.show.keys[$0.rawValue] == key }) else { return false }
        if execute { performShowCommand(command) }
        return true
    }
    func performShowCommand(_ command: ShowCommand) {
        switch command {
        case .go: scheduler.manualOverride("sequence"); sequence.go(manual: true)
        case .pause: scheduler.manualOverride("sequence"); sequence.state == .paused ? sequence.resume() : sequence.pause()
        case .stop: scheduler.manualOverride("sequence"); sequence.stop()
        case .next: scheduler.manualOverride("sequence"); sequence.skip()
        case .previous: scheduler.manualOverride("sequence"); sequence.back()
        case .emergency: stopAll()
        case .blackout: scheduler.manualOverride("video"); video.blackout.toggle()
        }
    }
    func loadSequence(_ id: UUID?) {
        guard let id, let item = project.sequences.first(where: { $0.id == id }) else { return }
        project.show.sequenceID = id; sequence.select(item)
    }
    func setShowKey(_ key: String, command: ShowCommand) {
        guard key.isEmpty || ShowConfiguration.availableKeys.contains(key) else { return }
        guard key.isEmpty || !project.show.keys.contains(where: { $0.key != command.rawValue && $0.value == key }) else { message = "Show shortcut already assigned"; return }
        project.show.keys[command.rawValue] = key
    }
    func setPadKey(_ key: String, at index: Int) {
        guard padKeys.indices.contains(index),
              key.isEmpty || SoundProject.availablePadKeys.contains(key) else { return }
        guard key.isEmpty || !padKeys.enumerated().contains(where: { $0.offset != index && $0.element == key }) else {
            message = "Option–\(key.uppercased()) is already assigned to another pad"
            return
        }
        padKeys[index] = key
    }
    func movePad(to destination: Int) {
        let source = selected
        guard pads.indices.contains(source), pads.indices.contains(destination), source != destination else { return }
        // Invalidate loads tied to these positions before changing their occupants.
        mediaAssignments.removeValue(forKey: source)?.1.cancel()
        mediaAssignments.removeValue(forKey: destination)?.1.cancel()
        var moved = pads; moved.swapAt(source, destination); pads = moved
        selected = destination
        message = "Swapped pads \(source + 1) and \(destination + 1)"
    }
    /// Keep the old cue playing until validation succeeds; never autoplay dropped media.
    @discardableResult func assignMedia(_ urls: [URL], to index: Int) -> Bool {
        guard pads.indices.contains(index), urls.count == 1, let url = urls.first, url.isFileURL else {
            message = "Drop one local media file onto a pad"
            return false
        }
        let request = UUID()
        let document = documentToken
        let cueID = pads[index]?.id
        mediaAssignments.removeValue(forKey: index)?.1.cancel()
        message = "Checking \(url.lastPathComponent)…"
        let task = Task { [weak self, assignmentLoader, visualLoader] in
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let values = try url.resourceValues(forKeys: [.isRegularFileKey])
                guard values.isRegularFile == true else { throw MediaIssue(message: "Choose an audio file, not a folder") }
                // Use the existing bounded decoder off the UI actor, rather than trusting the extension.
                let kind = VisualMediaLoader.kind(for: url)
                if kind == .audio { _ = try await assignmentLoader.load(url.path) }
                else { _ = try await visualLoader.inspect(url.path, kind: kind) }
                guard let self, self.documentToken == document, self.mediaAssignments[index]?.0 == request,
                      self.pads[index]?.id == cueID else { return }
                var cue = self.pads[index] ?? Cue(title: url.deletingPathExtension().lastPathComponent)
                if cue.filePath.isEmpty && cue.title == "Cue \(index + 1)" { cue.title = url.deletingPathExtension().lastPathComponent }
                if let old = self.pads[index] { self.stopCue(old) }
                self.detachMedia(cue.id)
                cue.filePath = url.path
                cue.kind = kind
                cue.groupID = nil
                self.pads[index] = cue
                self.selected = index
                self.mediaAssignments.removeValue(forKey: index)
                self.message = "Assigned \(url.lastPathComponent) to pad \(index + 1)"
            } catch {
                guard let self, self.documentToken == document, self.mediaAssignments[index]?.0 == request else { return }
                self.mediaAssignments.removeValue(forKey: index)
                self.message = "Cannot assign \(url.lastPathComponent): \(error.localizedDescription)"
            }
        }
        mediaAssignments[index] = (request, task)
        return true
    }
    func waitForMediaAssignments() async {
        let tasks = mediaAssignments.values.map { $0.1 }
        for task in tasks { await task.value }
    }
    func trigger(_ index: Int) {
        guard pads.indices.contains(index), let cue = pads[index] else { return }
        selected = index
        guard !unavailable(cue) else { message = "Media unavailable or changed; open Media to relink or confirm it"; return }
        if cue.kind == .group {
            guard let id = cue.groupID, let group = project.groups.first(where: { $0.id == id }) else { message = "Missing cue group"; return }
            _ = scheduler.launch(group)
        } else {
            scheduler.manualOverride(cue.kind == .audio ? "audio:\(cue.id)" : "video")
            if cue.kind == .audio { sound.play(cue) } else { video.play(cue) }
        }
    }
    func stopCue(_ cue: Cue) {
        if cue.kind == .group {
            for run in scheduler.runs where run.definition.id == cue.groupID && [.running, .paused, .error].contains(run.state) { scheduler.stop(run.id) }
            return
        }
        scheduler.manualOverride(cue.kind == .audio ? "audio:\(cue.id)" : "video")
        if cue.kind == .audio { sound.stop(cue.id) } else { video.stopCue(cue.id) }
    }
    func fadeUp(_ cue: Cue) {
        if cue.kind == .group { message = "Use the group Pause/Resume controls"; return }
        scheduler.manualOverride(cue.kind == .audio ? "audio:\(cue.id)" : "video")
        if cue.kind == .audio { sound.fadeIn(cue.id, seconds: project.manualFadeSeconds) }
        else if video.currentCue?.id == cue.id { video.fade(to: 1, seconds: project.manualFadeSeconds) }
    }
    func fadeDown(_ cue: Cue) {
        if cue.kind == .group { message = "Use the group Pause/Resume controls"; return }
        scheduler.manualOverride(cue.kind == .audio ? "audio:\(cue.id)" : "video")
        if cue.kind == .audio { sound.fadeToSilence(cue.id, seconds: project.manualFadeSeconds) }
        else if video.currentCue?.id == cue.id { video.fade(to: 0, seconds: project.manualFadeSeconds) }
    }
    func fadeStop(_ cue: Cue) {
        if cue.kind == .group {
            for run in scheduler.runs where run.definition.id == cue.groupID && [.running, .paused, .error].contains(run.state) { scheduler.stop(run.id, mode: .fade) }
            return
        }
        scheduler.manualOverride(cue.kind == .audio ? "audio:\(cue.id)" : "video")
        if cue.kind == .audio { sound.fadeOutAndStop(cue.id, seconds: project.manualFadeSeconds) }
        else { video.stopCue(cue.id, seconds: project.manualFadeSeconds) }
    }
    func stopAll() { sequence.emergencyCancel(); scheduler.cancelAll(); sound.stopAll(); video.stop() }
    func fadeAll() { sequence.emergencyCancel(); scheduler.cancelAll(); sound.fadeAll(seconds: project.manualFadeSeconds); video.stop(seconds: project.manualFadeSeconds) }
    func check() {
        guard !checking else { return }
        checking = true
        let snapshot = project
        let token = documentToken
        Task {
            var checkedProject = snapshot
            do {
                let result = try await mediaResolver.resolve(snapshot, root: projectRoot)
                if documentToken == token, project == snapshot {
                    project = result.project; checkedProject = result.project; mediaReport = result.report
                }
                preflightItems = result.report.items.filter { $0.status == .missing || $0.status == .ambiguous }.map { "\($0.asset.filename): \($0.status.rawValue) — \($0.detail)" }
                preflightItems += result.report.notes
            } catch { preflightItems = ["Media resolution failed: \(error.localizedDescription)"] }
            var audioProject = checkedProject
            audioProject.cues = checkedProject.allCues.filter { $0.kind == .audio }.map(Optional.some)
            message = "Checking audio…"
            preflightItems += await sound.preflight(audioProject)
            preflightItems += checkedProject.showReferenceIssues()
            for (index, cue) in checkedProject.allCues.enumerated() {
                guard cue.kind == .video || cue.kind == .image else { continue }
                message = "Checking pad \(index + 1): \(cue.title)…"
                do { _ = try await visualLoader.inspect(cue.filePath, kind: cue.kind) }
                catch { preflightItems.append("Pad \(index + 1): \(error.localizedDescription)") }
            }
            if !checkedProject.backgroundPath.isEmpty {
                do { _ = try await visualLoader.inspect(checkedProject.backgroundPath, kind: .image) }
                catch { preflightItems.append("Background: \(error.localizedDescription)") }
            }
            if project != checkedProject { preflightItems.append("Project changed during preflight; run it again") }
            checking = false
            message = preflightItems.isEmpty ? "Preflight passed: media validated and engine running" : "Preflight: \(preflightItems.count) issue(s)"
        }
    }
}

@main struct StageCueApp: App {
    @StateObject private var state = ShowState()
    var body: some Scene {
        WindowGroup("StageCue") {
            MainView().environmentObject(state)
                .frame(minWidth: 1220, minHeight: 740)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Project…") { state.open() }.keyboardShortcut("o")
                Button("Save Project") { state.save() }.keyboardShortcut("s")
                Button("Export Project Only…") { state.export() }.keyboardShortcut("e", modifiers: [.command, .shift])
            }
            CommandMenu("Performance") {
                Button("Fade All & Stop") { state.fadeAll() }
                    .keyboardShortcut("f", modifiers: [.command, .shift])
                Button("Emergency Stop All") { state.stopAll() }
                    .keyboardShortcut(".", modifiers: [.command])
                Divider()
                Button("Fade Up Selected Pad") {
                    if let cue = state.selectedCue { state.fadeUp(cue) }
                }
                .keyboardShortcut(.upArrow, modifiers: [.option])
                .disabled(state.selectedCue == nil)
                Button("Fade to Silence Selected Pad") {
                    if let cue = state.selectedCue { state.fadeDown(cue) }
                }
                .keyboardShortcut(.downArrow, modifiers: [.option])
                .disabled(state.selectedCue == nil)
                Button("Stop Selected Pad") {
                    if let cue = state.selectedCue { state.stopCue(cue) }
                }
                .keyboardShortcut("x", modifiers: [.option])
                .disabled(state.selectedCue == nil)
                Button("Fade Out & Stop Selected Pad") {
                    if let cue = state.selectedCue { state.fadeStop(cue) }
                }
                .keyboardShortcut("x", modifiers: [.option, .shift])
                .disabled(state.selectedCue == nil)
                Divider()
                ForEach(ShowCommand.allCases) { command in
                    Button(command.rawValue + " (Show Control)") { state.performShowCommand(command) }
                }
                Button("Configure Show Shortcuts…") { state.editingShowKeys = true }
                Divider()
                ForEach(0..<32, id: \.self) { n in
                    if let key = state.padKeys[n].first {
                        Button("Trigger Pad \(n + 1)") { state.trigger(n) }
                            .keyboardShortcut(KeyEquivalent(key), modifiers: [.option])
                            .disabled(state.pads[n] == nil)
                    } else {
                        Button("Trigger Pad \(n + 1)") { state.trigger(n) }
                            .disabled(state.pads[n] == nil)
                    }
                }
            }
        }
    }
}

struct MainView: View {
    @EnvironmentObject var state: ShowState
    @State private var showPreflight = false
    private let busNames = ["Music", "Ambience", "Effects", "Voice", "Stingers", "Special"]
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                ProjectTitle(title: $state.project.title)

                Spacer()
                Picker("Mode", selection: $state.project.show.showMode) {
                    Text("Soundboard").tag(false); Text("Show Mode").tag(true)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 230)
                Button("Sequences") { state.editingSequences = true }
                Button("Cue Groups") { state.editingGroups = true }
                Button("Open") { state.open() }
                Button("Save") { state.save() }
                Button("Export Project Only") { state.export() }
                Button(state.checking ? "Checking…" : "Preflight") { state.check() }.disabled(state.checking)
                Button("FADE ALL") { state.fadeAll() }
                Button("STOP ALL") { state.stopAll() }.tint(.red).buttonStyle(.borderedProminent)
            }
            if state.project.show.showMode {
                ShowPerformanceView().environmentObject(state)
            } else {
            HStack(alignment: .top, spacing: 14) {
                VStack(spacing: 9) {
                    HStack {
                        Picker("Page", selection: Binding(get: { state.page }, set: { state.changePage($0) })) {
                            Text(state.project.show.mainPageTitle).tag(0)
                            ForEach(Array(state.project.additionalPages.enumerated()), id: \.element.id) { i, item in Text(item.title).tag(i + 1) }
                        }.frame(maxWidth: 260)
                        TextField("Page name", text: Binding(get: { state.page == 0 ? state.project.show.mainPageTitle : state.project.additionalPages[state.page - 1].title }, set: {
                            if state.page == 0 { state.project.show.mainPageTitle = $0 } else { state.project.additionalPages[state.page - 1].title = $0 }
                        })).finishEditingOnCommit().frame(maxWidth: 200)
                        Button("New Page") { state.addPage() }
                        Spacer()
                    }
                    ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 9), count: 8), spacing: 9) {
                        ForEach(0..<32, id: \.self) { index in
                            Pad(index: index)
                        }
                    }
                    }
                    Divider()
                    HStack(spacing: 10) {
                        Text("Mixer").font(.headline)
                        Spacer()
                        Text("Manual fade duration")
                        TextField("Seconds", value: $state.project.manualFadeSeconds, format: .number.precision(.fractionLength(1)))
                            .finishEditingOnCommit()
                            .frame(width: 52)

                        Text("sec")
                    }
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(0..<6, id: \.self) { index in
                            VStack(alignment: .leading) {
                                Text(busNames[index]).font(.caption.bold())
                                GainSlider(value: Binding(get: { state.project.busDB[index] }, set: {
                                    state.scheduler.manualOverride("bus:\(index)")
                                    state.project.busDB[index] = $0; state.sound.applyMix(state.project)
                                }))
                                Text(String(format: "%.1f dB", state.project.busDB[index])).font(.caption.monospacedDigit())
                            }.frame(maxWidth: .infinity)
                        }
                    }
                    HStack {
                        Text("MASTER").bold()
                        GainSlider(value: $state.project.masterDB)
                            .onChange(of: state.project.masterDB) { _, _ in
                                state.sound.applyMix(state.project)
                            }
                        Text(String(format: "%.1f dB", state.project.masterDB)).monospacedDigit()
                    }
                }
                .frame(maxWidth: .infinity)
                Divider()
                ScrollView { CueInspector().frame(width: 280) }.frame(width: 300)
            }
            }
            Divider()
            VideoControls(video: state.video, output: state.output, project: $state.project, onManualControl: { state.scheduler.manualOverride("video") })
            HStack {
                Text(state.message).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("StageCue 0.4 • 32 pads • configurable Option shortcuts • ⌘. = emergency stop")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .overlay(alignment: .bottomLeading) {
            if let error = state.sound.errors.last {
                HStack {
                    Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                    Button("Dismiss") { state.sound.clearErrors() }
                }.padding(8).background(.regularMaterial).offset(y: -28)
            }
        }
        .padding(16)
        .sheet(isPresented: $state.editingShowKeys) { ShowKeyEditor().environmentObject(state) }
        .sheet(isPresented: $state.editingSequences) { SequenceEditor().environmentObject(state) }
        .sheet(isPresented: $state.editingGroups) { GroupEditor().environmentObject(state) }
        .alert("Preflight", isPresented: $showPreflight) {
            Button("OK") {}
        } message: {
            Text(state.preflightItems.isEmpty ? "All assigned media validated and the audio engine is running. Hardware output still needs a listening check." : state.preflightItems.joined(separator: "\n"))
        }
        .onChange(of: state.project.backgroundPath) { _, path in state.video.setBackground(path) }
        .onChange(of: state.checking) { old, new in if old && !new { showPreflight = true } }
    }
}

struct Pad: View {
    @EnvironmentObject var state: ShowState
    @State private var dropTargeted = false
    let index: Int
    var body: some View {
        let cue = state.pads[index]
        let running = cue.map { item in state.sound.active.contains(item.id) || state.video.activeIDs.contains(item.id) || state.scheduler.activeRuns.contains { $0.definition.id == item.groupID } } ?? false
        VStack(spacing: 5) {
            Button {
                state.selected = index
                if cue != nil { state.trigger(index) }
            } label: {
                VStack {
                    HStack {
                        Text(String(format: "%02d", index + 1)).font(.caption2.monospaced())
                        if !state.padKeys[index].isEmpty {
                            Text("⌥" + state.padKeys[index].uppercased()).font(.caption2.monospaced())
                        }
                        Spacer()
                        if running { Image(systemName: "waveform").foregroundStyle(.green) }
                        else if cue.map({ state.sound.loading.contains($0.id) || state.video.loadingCueID == $0.id }) == true { ProgressView().controlSize(.mini) }
                    }
                    Spacer()
                    Text(cue?.title ?? "+ Assign")
                        .font(.system(size: 13, weight: .semibold))
                        .multilineTextAlignment(.center).lineLimit(2)
                    Spacer()
                    Text(cue.map { $0.kind == .audio ? String(format: "%.0f dB", $0.gainDB) : $0.kind.rawValue } ?? "")
                        .font(.caption2.monospacedDigit())
                }
                .frame(maxWidth: .infinity).frame(height: 86)
            }
            .buttonStyle(.borderedProminent)
            .tint(dropTargeted ? .blue : running ? .green : state.selected == index ? .indigo : .gray)
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(dropTargeted ? Color.accentColor : .clear, lineWidth: 3)
                    .allowsHitTesting(false)
            }
            .help("Drop one media file here to assign it. Existing cue settings are preserved.")
            .dropDestination(for: URL.self) { urls, _ in
                state.assignMedia(urls, to: index)
            } isTargeted: { dropTargeted = $0 }
            HStack(spacing: 2) {
                Button("Edit") { state.selected = index }.help("Select settings without triggering playback")
                Button("▲") { if let cue { state.fadeUp(cue) } }
                    .help("Manual fade up to configured level")
                Button("▼") { if let cue { state.fadeDown(cue) } }
                    .help("Fade to silence/black, keep playback running")
                Button("■") { if let cue { state.fadeStop(cue) } }
                    .help("Fade out and stop")
                Button("✕") { if let cue { state.stopCue(cue) } }.help("Immediate stop")
            }.buttonStyle(.borderless).font(.caption2)
        }
    }
}

struct CueInspector: View {
    @EnvironmentObject var state: ShowState
    @State private var moveDestination = 0
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("PAD \(state.selected + 1) • SETTINGS").font(.headline)
            Picker("Trigger shortcut", selection: Binding(
                get: { state.padKeys[state.selected] },
                set: { state.setPadKey($0, at: state.selected) }
            )) {
                Text("None").tag("")
                ForEach(SoundProject.availablePadKeys.filter { key in
                    key == state.padKeys[state.selected] || !state.padKeys.contains(key)
                }, id: \.self) { key in
                    Text("Option–\(key.uppercased())").tag(key)
                }
            }
            HStack {
                Picker("Move to", selection: $moveDestination) {
                    ForEach(0..<32, id: \.self) { n in Text("Pad \(n + 1)").tag(n) }
                }
                Button("Swap") { state.movePad(to: moveDestination) }
                    .disabled(moveDestination == state.selected)
            }
            Text("Swap preserves both cues. Shortcuts stay with pad positions.")
                .font(.caption).foregroundStyle(.secondary)
            Picker("Assign group", selection: Binding(get: { state.selectedCue?.kind == .group ? state.selectedCue?.groupID : nil }, set: { id in
                if let id, let group = state.project.groups.first(where: { $0.id == id }) {
                    state.setCue(Cue(title: group.title, kind: .group, groupID: id))
                }
            })) {
                Text("Media cue / none").tag(Optional<UUID>.none)
                ForEach(state.project.groups) { Text($0.title).tag(Optional($0.id)) }
            }
            if let cue = state.pads[state.selected] {
                cueControls(cue)
            } else {
                Text("Unassigned pad").foregroundStyle(.secondary)
                Button("Create Cue") {
                    state.setCue(Cue(title: "Cue \(state.selected + 1)"))
                }
            }
            Spacer()
        }
    }
    @ViewBuilder private func cueControls(_ current: Cue) -> some View {
        // Dedicated bindings update the value-type cue in its indexed slot.
        TextField("Cue name", text: bind(\.title)).finishEditingOnCommit()
        if current.kind == .group {
            Text("Group settings are edited in Cue Groups.").font(.caption)
            ForEach(state.scheduler.activeRuns.filter { $0.definition.id == current.groupID }) { run in
                HStack {
                    Text(run.state.rawValue)
                    Button(run.state == .paused ? "Resume" : "Pause") { run.state == .paused ? state.scheduler.resume(run.id) : state.scheduler.pause(run.id) }
                    Button("Stop") { state.scheduler.stop(run.id) }
                }
            }
        } else {
        HStack {
            Text(current.filePath.isEmpty ? "No media assigned" : URL(fileURLWithPath: current.filePath).lastPathComponent)
                .lineLimit(1).font(.caption)
            Spacer()
            Button("Browse…") { chooseFile() }
        }
        Text(current.kind.rawValue).font(.caption.bold())
        if current.kind == .audio {
        HStack {
            Text("Clip level")
            Spacer()
            Text(String(format: "%.1f dB", current.gainDB)).monospacedDigit()
        }
        GainSlider(value: bind(\.gainDB))
        Picker("Bus", selection: bind(\.bus)) {
            ForEach(0..<6, id: \.self) { index in Text(["Music", "Ambience", "Effects", "Voice", "Stingers", "Special"][index]).tag(index) }
        }
        }
        Picker("Playback", selection: bind(\.mode)) {
            ForEach(CueMode.supported) { mode in Text(mode.rawValue).tag(mode) }
        }
        if current.kind != .image { Toggle("Loop continuously", isOn: bind(\.loop)) }
        Divider()
        if current.kind == .audio {
        Toggle("Auto fade in on play", isOn: bind(\.autoFadeIn))
        HStack {
            Text("In (sec)")
            TextField("Fade in", value: bind(\.fadeInSeconds), format: .number).finishEditingOnCommit().frame(width: 65)
        }
        Toggle("Auto fade out at end / configured Stop", isOn: bind(\.autoFadeOut))
        HStack {
            Text("Out (sec)")
            TextField("Fade out", value: bind(\.fadeOutSeconds), format: .number).finishEditingOnCommit().frame(width: 65)
        }
        Picker("Fade curve", selection: bind(\.curve)) {
            ForEach(FadeCurve.allCases) { curve in Text(curve.rawValue).tag(curve) }
        }
        } else {
            Picker("Transition", selection: bind(\.transition)) {
                ForEach(VisualTransition.allCases) { transition in Text(transition.rawValue).tag(transition) }
            }
            HStack { Text("Fade in (sec)"); TextField("Visual fade in", value: bind(\.videoFadeIn), format: .number).finishEditingOnCommit().frame(width: 65) }
            HStack { Text("Fade out (sec)"); TextField("Visual fade out", value: bind(\.videoFadeOut), format: .number).finishEditingOnCommit().frame(width: 65) }
            if current.kind == .video {
                Toggle("Hold last frame when finished", isOn: bind(\.holdLastFrame))
                    .disabled(current.loop)
                    .help("For non-looping video: keep the final frame until replaced or stopped. Applies on the next trigger.")
                HStack { Text("Soundtrack"); Spacer(); Text(String(format: "%.1f dB", current.soundtrackDB)) }
                Slider(value: bind(\.soundtrackDB), in: -60...0)
                Button(state.video.paused ? "Resume Video" : "Pause Video") {
                    state.scheduler.manualOverride("video")
                    if state.video.currentCue?.id == current.id { state.video.paused ? state.video.resume() : state.video.pause() }
                }
            }
        }
        }
        Divider()
        Button("Stop using cue's fade setting") {
            if current.kind == .audio { state.scheduler.manualOverride("audio:\(current.id)"); state.sound.configuredStop(current.id) }
            else { state.scheduler.manualOverride("video"); state.video.stopCue(current.id, seconds: current.videoFadeOut) }
        }
        Button("Clear Pad", role: .destructive) {
            state.stopCue(current)
            state.setCue(nil)
        }
    }
    private func bind<T>(_ key: WritableKeyPath<Cue, T>) -> Binding<T> {
        let index = state.selected
        let page = state.page
        let cueID = state.selectedCue?.id
        let fallback = Cue()[keyPath: key]
        return Binding(get: {
            guard state.page == page, state.pads.indices.contains(index), state.pads[index]?.id == cueID else { return fallback }
            return state.pads[index]?[keyPath: key] ?? fallback
        }, set: { newValue in
            guard state.page == page, state.pads.indices.contains(index), var cue = state.pads[index], cue.id == cueID else { return }
            cue[keyPath: key] = newValue
            cue.normalize()
            if key == \Cue.gainDB {
                state.scheduler.manualOverride("audio:\(cue.id)")
                state.sound.fadeToDB(cue.id, decibels: cue.gainDB, seconds: 0)
            }
            if key == \Cue.soundtrackDB {
                state.scheduler.manualOverride("video")
                if state.video.currentCue?.id == cue.id { state.video.setSoundtrackDB(cue.soundtrackDB) }
            }
            state.pads[index] = cue
        })
    }
    private func chooseFile() {
        let index = state.selected
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .movie, .png, .jpeg]
        if panel.runModal() == .OK, let url = panel.url {
            state.assignMedia([url], to: index)
        }
    }
}

/// Native tracking preserves dragging and keyboard control. Consume Option-click
/// before tracking starts so the click position cannot overwrite the reset value.
struct GainSlider: NSViewRepresentable {
    @Binding var value: Double

    final class ResettableSlider: NSSlider {
        override func mouseDown(with event: NSEvent) {
            if event.modifierFlags.contains(.option) {
                doubleValue = 0
                sendAction(action, to: target)
                return
            }
            super.mouseDown(with: event)
        }
    }

    @MainActor final class Coordinator: NSObject {
        var binding: Binding<Double>
        init(_ binding: Binding<Double>) { self.binding = binding }
        @objc func changed(_ sender: NSSlider) { binding.wrappedValue = sender.doubleValue }
    }

    func makeCoordinator() -> Coordinator { Coordinator($value) }
    func makeNSView(context: Context) -> ResettableSlider {
        let slider = ResettableSlider()
        slider.minValue = -60
        slider.maxValue = 6
        slider.isContinuous = true
        slider.target = context.coordinator
        slider.action = #selector(Coordinator.changed(_:))
        slider.toolTip = "Option-click to reset to 0.0 dB"
        slider.setAccessibilityLabel("Gain in decibels")
        slider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return slider
    }
    func updateNSView(_ slider: ResettableSlider, context: Context) {
        context.coordinator.binding = $value
        slider.doubleValue = value
        slider.isEnabled = context.environment.isEnabled
    }
}

/// Keep the title out of the responder chain until renaming is explicitly requested.
struct ProjectTitle: View {
    @Binding var title: String
    @State private var editing = false
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if editing {
                TextField("Show name", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onSubmit { finish() }
                    .onExitCommand { editing = false; focused = false }
                    .onAppear { DispatchQueue.main.async { focused = true } }
                    .onChange(of: focused) { _, hasFocus in
                        if !hasFocus && editing { finish() }
                    }
            } else {
                Button {
                    draft = title
                    editing = true
                } label: {
                    Text(title.isEmpty ? "Untitled Show" : title)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusable(false)
                .help("Click to rename the project")
                .accessibilityLabel("Project name: \(title). Click to rename")
            }
        }
        .font(.title2.bold())
        .background {
            if editing { RenameClickBoundary(onOutsideClick: finish) }
        }
        .onChange(of: title) { _, _ in
            // Opening another project must discard any unfinished rename.
            if editing { editing = false; focused = false }
        }
    }

    private func finish() {
        guard editing else { return }
        editing = false
        focused = false
        let name = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { title = name }
    }
}

/// Observe outside clicks without swallowing pad/transport/button actions.
private struct RenameClickBoundary: NSViewRepresentable {
    let onOutsideClick: () -> Void
    final class BoundaryView: NSView {
        var onOutsideClick: (() -> Void)?
        private var monitor: Any?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                guard let self, let window = self.window else { return event }
                if event.window !== window || !self.bounds.contains(self.convert(event.locationInWindow, from: nil)) {
                    self.onOutsideClick?()
                }
                return event
            }
        }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        isolated deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
    func makeNSView(context: Context) -> BoundaryView {
        let view = BoundaryView()
        view.onOutsideClick = onOutsideClick
        return view
    }
    func updateNSView(_ view: BoundaryView, context: Context) { view.onOutsideClick = onOutsideClick }
    static func dismantleNSView(_ view: BoundaryView, coordinator: ()) { view.onOutsideClick = nil }
}

/// End the field-editor session while allowing the clicked control to act normally.
private struct FinishEditingOnCommit: ViewModifier {
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        content
            .focused($focused)
            .onSubmit { finish() }
            .background {
                if focused { RenameClickBoundary(onOutsideClick: finish) }
            }
    }

    private func finish() {
        guard focused else { return }
        // AppKit ends editing synchronously so numeric bindings commit before an
        // outside click changes the selected pad or starts a transport action.
        if let window = NSApp.keyWindow { window.makeFirstResponder(nil) }
        focused = false
    }
}

extension View {
    func finishEditingOnCommit() -> some View {
        modifier(FinishEditingOnCommit())
    }
}
