import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Combine

@MainActor final class ShowState: ObservableObject {
    @Published var project = SoundProject() { didSet { scheduleAutosave() } }
    @Published var selected = 0
    @Published var message = ""
    @Published var preflightItems: [String] = []
    @Published var checking = false
    let sound = SoundEngine()
    private var saveURL: URL?
    private let writer = ProjectWriter()
    private var autosaveTask: Task<Void, Never>?
    private var revision = 0
    private var engineChanges: AnyCancellable?
    private var terminationObserver: NSObjectProtocol?
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
        sound.applyMix(project)
        // Forward nested engine changes so pads, loading indicators and errors update immediately.
        engineChanges = sound.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
        terminationObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.autosaveTask?.cancel()
                if self.recoveredAutosave { try? ProjectStore.save(self.project, to: self.autosaveURL) }
                self.sound.shutdown()
            }
        }
    }
    isolated deinit {
        autosaveTask?.cancel()
        for request in mediaAssignments.values { request.1.cancel() }
        if let terminationObserver { NotificationCenter.default.removeObserver(terminationObserver) }
    }
    static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("StageCue", isDirectory: true).appendingPathComponent("autosave.json")
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
    func save() {
        project.normalize()
        recoveredAutosave = true
        autosaveTask?.cancel()
        revision += 1
        let version = revision
        let snapshot = project
        let destination = saveURL
        let autosave = autosaveURL
        Task {
            do {
                try await writer.save(snapshot, to: autosave, revision: version)
                if let destination { try await writer.save(snapshot, to: destination, revision: version) }
                message = "Project saved"
            } catch { message = "Save failed: \(error.localizedDescription)" }
        }
    }
    func export() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "\(project.title).json"
        if panel.runModal() == .OK, let url = panel.url {
            saveURL = url
            save()
        }
    }
    func open() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        if panel.runModal() == .OK, let url = panel.url {
            do {
                let (decoded, notes) = try ProjectStore.load(from: url)
                sound.stopAll()
                documentToken = UUID()
                for request in mediaAssignments.values { request.1.cancel() }
                mediaAssignments.removeAll()
                recoveredAutosave = true
                project = decoded
                saveURL = url
                sound.applyMix(project)
                message = notes.isEmpty ? "Project opened" : notes.joined(separator: "; ")
                // Opening never rewrites the imported document. Only explicit Save/Export does.
            } catch { message = "Open failed: \(error.localizedDescription)" }
        }
    }
    func setCue(_ cue: Cue?) {
        guard project.cues.indices.contains(selected) else { return }
        mediaAssignments.removeValue(forKey: selected)?.1.cancel()
        if let old = project.cues[selected] { sound.stop(old.id) }
        project.cues[selected] = cue
    }
    /// Keep the old cue playing until validation succeeds; never autoplay dropped media.
    @discardableResult func assignMedia(_ urls: [URL], to index: Int) -> Bool {
        guard project.cues.indices.contains(index), urls.count == 1, let url = urls.first, url.isFileURL else {
            message = "Drop one local audio file onto a pad"
            return false
        }
        let request = UUID()
        let document = documentToken
        let cueID = project.cues[index]?.id
        mediaAssignments.removeValue(forKey: index)?.1.cancel()
        message = "Checking \(url.lastPathComponent)…"
        let task = Task { [weak self, assignmentLoader] in
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let values = try url.resourceValues(forKeys: [.isRegularFileKey])
                guard values.isRegularFile == true else { throw MediaIssue(message: "Choose an audio file, not a folder") }
                // Use the existing bounded decoder off the UI actor, rather than trusting the extension.
                _ = try await assignmentLoader.load(url.path)
                guard let self, self.documentToken == document, self.mediaAssignments[index]?.0 == request,
                      self.project.cues[index]?.id == cueID else { return }
                var cue = self.project.cues[index] ?? Cue(title: url.deletingPathExtension().lastPathComponent)
                if cue.filePath.isEmpty && cue.title == "Cue \(index + 1)" { cue.title = url.deletingPathExtension().lastPathComponent }
                if let old = self.project.cues[index] { self.sound.stop(old.id) }
                cue.filePath = url.path
                self.project.cues[index] = cue
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
        guard project.cues.indices.contains(index), let cue = project.cues[index] else { return }
        sound.play(cue)
    }
    func check() {
        guard !checking else { return }
        checking = true
        let snapshot = project
        Task {
            preflightItems = await sound.preflight(snapshot)
            if project != snapshot { preflightItems.append("Project changed during preflight; run it again") }
            checking = false
            message = preflightItems.isEmpty ? "Preflight passed: media decoded and engine running" : "Preflight: \(preflightItems.count) issue(s)"
        }
    }
}

@main struct StageCueApp: App {
    @StateObject private var state = ShowState()
    var body: some Scene {
        WindowGroup("StageCue") {
            MainView().environmentObject(state)
                .frame(minWidth: 1160, minHeight: 700)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Project…") { state.open() }.keyboardShortcut("o")
                Button("Save Project") { state.save() }.keyboardShortcut("s")
                Button("Export Project…") { state.export() }.keyboardShortcut("e", modifiers: [.command, .shift])
            }
            CommandMenu("Performance") {
                Button("Fade All & Stop") { state.sound.fadeAll(seconds: state.project.manualFadeSeconds) }
                    .keyboardShortcut("f", modifiers: [.command, .shift])
                Button("Emergency Stop All") { state.sound.stopAll() }
                    .keyboardShortcut(".", modifiers: [.command])
                Divider()
                ForEach(0..<9, id: \.self) { n in
                    Button("Trigger Pad \(n + 1)") { state.trigger(n) }
                        .keyboardShortcut(KeyEquivalent(Character(String(n + 1))), modifiers: [.option])
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
                TextField("Show name", text: $state.project.title)
                    .font(.title2.bold()).textFieldStyle(.plain)

                Spacer()
                Button("Open") { state.open() }
                Button("Save") { state.save() }
                Button("Export") { state.export() }
                Button(state.checking ? "Checking…" : "Preflight") { state.check() }.disabled(state.checking)
                Button("FADE ALL") { state.sound.fadeAll(seconds: state.project.manualFadeSeconds) }
                Button("STOP ALL") { state.sound.stopAll() }.tint(.red).buttonStyle(.borderedProminent)
            }
            HStack(alignment: .top, spacing: 14) {
                VStack(spacing: 9) {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 9), count: 8), spacing: 9) {
                        ForEach(0..<32, id: \.self) { index in
                            Pad(index: index)
                        }
                    }
                    Divider()
                    HStack(spacing: 10) {
                        Text("Mixer").font(.headline)
                        Spacer()
                        Text("Manual fade duration")
                        TextField("Seconds", value: $state.project.manualFadeSeconds, format: .number.precision(.fractionLength(1)))
                            .frame(width: 52)

                        Text("sec")
                    }
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(0..<6, id: \.self) { index in
                            VStack(alignment: .leading) {
                                Text(busNames[index]).font(.caption.bold())
                                Slider(value: $state.project.busDB[index], in: -60...6)
                                    .onChange(of: state.project.busDB[index]) { _, _ in
                                        state.sound.applyMix(state.project)
                                    }
                                Text(String(format: "%.1f dB", state.project.busDB[index])).font(.caption.monospacedDigit())
                            }.frame(maxWidth: .infinity)
                        }
                    }
                    HStack {
                        Text("MASTER").bold()
                        Slider(value: $state.project.masterDB, in: -60...6)
                            .onChange(of: state.project.masterDB) { _, _ in
                                state.sound.applyMix(state.project)
                            }
                        Text(String(format: "%.1f dB", state.project.masterDB)).monospacedDigit()
                    }
                }
                .frame(maxWidth: .infinity)
                Divider()
                CueInspector().frame(width: 280)
            }
            HStack {
                Text(state.message).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("StageCue 0.1 • 32 pads • shortcuts ⌥1–9 • ⌘. = emergency stop")
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
        .alert("Preflight", isPresented: $showPreflight) {
            Button("OK") {}
        } message: {
            Text(state.preflightItems.isEmpty ? "All assigned media decoded successfully and the audio engine is running. Hardware output still needs a listening check." : state.preflightItems.joined(separator: "\n"))
        }
        .onChange(of: state.checking) { old, new in if old && !new { showPreflight = true } }
    }
}

struct Pad: View {
    @EnvironmentObject var state: ShowState
    @State private var dropTargeted = false
    let index: Int
    var body: some View {
        let cue = state.project.cues[index]
        let running = cue.map { state.sound.active.contains($0.id) } ?? false
        VStack(spacing: 5) {
            Button {
                state.selected = index
                if cue != nil { state.trigger(index) }
            } label: {
                VStack {
                    HStack {
                        Text(String(format: "%02d", index + 1)).font(.caption2.monospaced())
                        Spacer()
                        if running { Image(systemName: "waveform").foregroundStyle(.green) }
                        else if cue.map({ state.sound.loading.contains($0.id) }) == true { ProgressView().controlSize(.mini) }
                    }
                    Spacer()
                    Text(cue?.title ?? "+ Assign")
                        .font(.system(size: 13, weight: .semibold))
                        .multilineTextAlignment(.center).lineLimit(2)
                    Spacer()
                    Text(cue.map { String(format: "%.0f dB", $0.gainDB) } ?? "")
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
            .help("Drop one audio file here to assign it. Existing cue settings are preserved.")
            .dropDestination(for: URL.self) { urls, _ in
                state.assignMedia(urls, to: index)
            } isTargeted: { dropTargeted = $0 }
            HStack(spacing: 2) {
                Button("Edit") { state.selected = index }.help("Select settings without triggering audio")
                Button("▲") { if let cue { state.sound.fadeIn(cue.id, seconds: state.project.manualFadeSeconds) } }
                    .help("Manual fade in to configured clip level")
                Button("▼") { if let cue { state.sound.fadeToSilence(cue.id, seconds: state.project.manualFadeSeconds) } }
                    .help("Fade to silence, keep playback running")
                Button("■") { if let cue { state.sound.fadeOutAndStop(cue.id, seconds: state.project.manualFadeSeconds) } }
                    .help("Fade out and stop")
                Button("✕") { if let cue { state.sound.stop(cue.id) } }.help("Immediate stop")
            }.buttonStyle(.borderless).font(.caption2)
        }
    }
}

struct CueInspector: View {
    @EnvironmentObject var state: ShowState
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("PAD \(state.selected + 1) • SETTINGS").font(.headline)
            if let cue = state.project.cues[state.selected] {
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
        TextField("Cue name", text: bind(\.title))
        HStack {
            Text(current.filePath.isEmpty ? "No audio assigned" : URL(fileURLWithPath: current.filePath).lastPathComponent)
                .lineLimit(1).font(.caption)
            Spacer()
            Button("Browse…") { chooseFile() }
        }
        HStack {
            Text("Clip level")
            Spacer()
            Text(String(format: "%.1f dB", current.gainDB)).monospacedDigit()
        }
        Slider(value: bind(\.gainDB), in: -60...6)
        Picker("Bus", selection: bind(\.bus)) {
            ForEach(0..<6, id: \.self) { index in Text(["Music", "Ambience", "Effects", "Voice", "Stingers", "Special"][index]).tag(index) }
        }
        Picker("Playback", selection: bind(\.mode)) {
            ForEach(CueMode.supported) { mode in Text(mode.rawValue).tag(mode) }
        }
        Toggle("Loop continuously", isOn: bind(\.loop))
        Divider()
        Toggle("Auto fade in on play", isOn: bind(\.autoFadeIn))
        HStack {
            Text("In (sec)")
            TextField("Fade in", value: bind(\.fadeInSeconds), format: .number).frame(width: 65)
        }
        Toggle("Auto fade out at end / configured Stop", isOn: bind(\.autoFadeOut))
        HStack {
            Text("Out (sec)")
            TextField("Fade out", value: bind(\.fadeOutSeconds), format: .number).frame(width: 65)
        }
        Picker("Fade curve", selection: bind(\.curve)) {
            ForEach(FadeCurve.allCases) { curve in Text(curve.rawValue).tag(curve) }
        }
        Divider()
        Button("Stop using cue's fade setting") {
            state.sound.configuredStop(current.id)
        }
        Button("Clear Pad", role: .destructive) {
            state.sound.stop(current.id)
            state.setCue(nil)
        }
    }
    private func bind<T>(_ key: WritableKeyPath<Cue, T>) -> Binding<T> {
        let index = state.selected
        let fallback = Cue()[keyPath: key]
        return Binding(get: {
            guard state.project.cues.indices.contains(index) else { return fallback }
            return state.project.cues[index]?[keyPath: key] ?? fallback
        }, set: { newValue in
            guard state.project.cues.indices.contains(index), var cue = state.project.cues[index] else { return }
            cue[keyPath: key] = newValue
            cue.normalize()
            state.project.cues[index] = cue
        })
    }
    private func chooseFile() {
        let index = state.selected
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        if panel.runModal() == .OK, let url = panel.url {
            state.assignMedia([url], to: index)
        }
    }
}
