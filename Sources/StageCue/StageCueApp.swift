import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Combine

@MainActor final class ShowState: ObservableObject {
    @Published var project = SoundProject() { didSet { scheduleAutosave() } }
    @Published var selected = 0
    var selectedCue: Cue? {
        guard project.cues.indices.contains(selected) else { return nil }
        return project.cues[selected]
    }
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
        sound.applyMix(project)
        // Catch performance Option shortcuts before text fields interpret them as symbols.
        keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated {
                let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                guard flags.contains(.option), !flags.contains(.command), !flags.contains(.control),
                      NSApp.modalWindow == nil, let window = event.window,
                      window == NSApp.keyWindow, window.sheetParent == nil, window.attachedSheet == nil,
                      let key = event.charactersIgnoringModifiers?.lowercased(), let self else { return false }
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
        if let keyboardMonitor { NSEvent.removeMonitor(keyboardMonitor) }
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
    @discardableResult func performPadKey(_ key: String, shift: Bool = false, execute: Bool = true) -> Bool {
        if key == "x" {
            if execute, let cue = selectedCue {
                if shift { sound.fadeOutAndStop(cue.id, seconds: project.manualFadeSeconds) }
                else { sound.stop(cue.id) }
            }
            return true
        }
        guard !shift else { return false }
        if key == "\u{F700}" || key == "\u{F701}" {
            if execute, let cue = selectedCue {
                if key == "\u{F700}" { sound.fadeIn(cue.id, seconds: project.manualFadeSeconds) }
                else { sound.fadeToSilence(cue.id, seconds: project.manualFadeSeconds) }
            }
            return true
        }
        guard !key.isEmpty, let index = project.padKeys.firstIndex(of: key) else { return false }
        if execute { trigger(index) }
        return true
    }
    func setPadKey(_ key: String, at index: Int) {
        guard project.padKeys.indices.contains(index),
              key.isEmpty || SoundProject.availablePadKeys.contains(key) else { return }
        guard key.isEmpty || !project.padKeys.enumerated().contains(where: { $0.offset != index && $0.element == key }) else {
            message = "Option–\(key.uppercased()) is already assigned to another pad"
            return
        }
        project.padKeys[index] = key
    }
    func movePad(to destination: Int) {
        let source = selected
        guard project.cues.indices.contains(source), project.cues.indices.contains(destination), source != destination else { return }
        // Invalidate loads tied to these positions before changing their occupants.
        mediaAssignments.removeValue(forKey: source)?.1.cancel()
        mediaAssignments.removeValue(forKey: destination)?.1.cancel()
        guard project.swapPads(source, destination) else { return }
        selected = destination
        message = "Swapped pads \(source + 1) and \(destination + 1)"
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
        selected = index
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
                Button("Fade Up Selected Pad") {
                    if let cue = state.selectedCue { state.sound.fadeIn(cue.id, seconds: state.project.manualFadeSeconds) }
                }
                .keyboardShortcut(.upArrow, modifiers: [.option])
                .disabled(state.selectedCue == nil)
                Button("Fade to Silence Selected Pad") {
                    if let cue = state.selectedCue { state.sound.fadeToSilence(cue.id, seconds: state.project.manualFadeSeconds) }
                }
                .keyboardShortcut(.downArrow, modifiers: [.option])
                .disabled(state.selectedCue == nil)
                Button("Stop Selected Pad") {
                    if let cue = state.selectedCue { state.sound.stop(cue.id) }
                }
                .keyboardShortcut("x", modifiers: [.option])
                .disabled(state.selectedCue == nil)
                Button("Fade Out & Stop Selected Pad") {
                    if let cue = state.selectedCue { state.sound.fadeOutAndStop(cue.id, seconds: state.project.manualFadeSeconds) }
                }
                .keyboardShortcut("x", modifiers: [.option, .shift])
                .disabled(state.selectedCue == nil)
                Divider()
                ForEach(0..<32, id: \.self) { n in
                    if let key = state.project.padKeys[n].first {
                        Button("Trigger Pad \(n + 1)") { state.trigger(n) }
                            .keyboardShortcut(KeyEquivalent(key), modifiers: [.option])
                            .disabled(state.project.cues[n] == nil)
                    } else {
                        Button("Trigger Pad \(n + 1)") { state.trigger(n) }
                            .disabled(state.project.cues[n] == nil)
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
                                GainSlider(value: $state.project.busDB[index])
                                    .onChange(of: state.project.busDB[index]) { _, _ in
                                        state.sound.applyMix(state.project)
                                    }
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
                CueInspector().frame(width: 280)
            }
            HStack {
                Text(state.message).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("StageCue 0.1 • 32 pads • configurable Option shortcuts • ⌘. = emergency stop")
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
                        if !state.project.padKeys[index].isEmpty {
                            Text("⌥" + state.project.padKeys[index].uppercased()).font(.caption2.monospaced())
                        }
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
    @State private var moveDestination = 0
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("PAD \(state.selected + 1) • SETTINGS").font(.headline)
            Picker("Trigger shortcut", selection: Binding(
                get: { state.project.padKeys[state.selected] },
                set: { state.setPadKey($0, at: state.selected) }
            )) {
                Text("None").tag("")
                ForEach(SoundProject.availablePadKeys.filter { key in
                    key == state.project.padKeys[state.selected] || !state.project.padKeys.contains(key)
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
        GainSlider(value: bind(\.gainDB))
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
