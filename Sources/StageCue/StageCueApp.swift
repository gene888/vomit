import SwiftUI
import AppKit
import UniformTypeIdentifiers

@MainActor final class ShowState: ObservableObject {
    @Published var project = SoundProject()
    @Published var selected = 0
    @Published var message = ""
    @Published var preflightItems: [String] = []
    let sound = SoundEngine()
    private var saveURL: URL?

    init() {
        let url = Self.defaultURL
        if let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode(SoundProject.self, from: data) {
            project = saved; project.normalize()
        }
        sound.applyMix(project)
    }
    static var defaultURL: URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("StageCue", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("autosave.json")
    }
    func save() {
        do {
            let data = try JSONEncoder().encode(project)
            try data.write(to: Self.defaultURL, options: .atomic)
            if let saveURL { try data.write(to: saveURL, options: .atomic) }
            message = "Project saved"
        } catch { message = "Save failed: \(error.localizedDescription)" }
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
                let data = try Data(contentsOf: url)
                var decoded = try JSONDecoder().decode(SoundProject.self, from: data)
                decoded.normalize()
                sound.stopAll()
                project = decoded
                saveURL = url
                sound.applyMix(project)
                save()
            } catch { message = "Open failed: \(error.localizedDescription)" }
        }
    }
    func setCue(_ cue: Cue?) {
        project.cues[selected] = cue
        save()
    }
    func trigger(_ index: Int) {
        guard project.cues.indices.contains(index), let cue = project.cues[index] else { return }
        sound.play(cue)
    }
    func check() {
        preflightItems = sound.preflight(project)
        message = preflightItems.isEmpty ? "Preflight passed: audio engine running and all assigned media found" : "Preflight: \(preflightItems.count) issue(s)"
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
                        .keyboardShortcut(KeyEquivalent(Character(String(n + 1))), modifiers: [])
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
                    .onSubmit { state.save() }
                Spacer()
                Button("Open") { state.open() }
                Button("Save") { state.save() }
                Button("Export") { state.export() }
                Button("Preflight") { state.check(); showPreflight = true }
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
                            .onSubmit { state.save() }
                        Text("sec")
                    }
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(0..<6, id: \.self) { index in
                            VStack(alignment: .leading) {
                                Text(busNames[index]).font(.caption.bold())
                                Slider(value: $state.project.busDB[index], in: -60...6)
                                    .onChange(of: state.project.busDB[index]) { _, _ in
                                        state.sound.applyMix(state.project); state.save()
                                    }
                                Text(String(format: "%.1f dB", state.project.busDB[index])).font(.caption.monospacedDigit())
                            }.frame(maxWidth: .infinity)
                        }
                    }
                    HStack {
                        Text("MASTER").bold()
                        Slider(value: $state.project.masterDB, in: -60...6)
                            .onChange(of: state.project.masterDB) { _, _ in
                                state.sound.applyMix(state.project); state.save()
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
                Text("StageCue 0.1 • 32 pads • shortcuts 1–9 • ⌘. = emergency stop")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .alert("Preflight", isPresented: $showPreflight) {
            Button("OK") {}
        } message: {
            Text(state.preflightItems.isEmpty ? "All assigned media files are present and the audio engine is running." : state.preflightItems.joined(separator: "\n"))
        }
        .onChange(of: state.project.cues) { _, _ in state.save() }
    }
}

struct Pad: View {
    @EnvironmentObject var state: ShowState
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
            .tint(running ? .green : state.selected == index ? .indigo : .gray)
            HStack(spacing: 2) {
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
        let name = Binding<String>(get: { state.project.cues[state.selected]?.title ?? "" },
                                   set: { newValue in state.project.cues[state.selected]?.title = newValue; state.save() })
        TextField("Cue name", text: name)
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
            ForEach(CueMode.allCases) { mode in Text(mode.rawValue).tag(mode) }
        }
        Toggle("Loop continuously", isOn: bind(\.loop))
        Divider()
        Toggle("Auto fade in on play", isOn: bind(\.autoFadeIn))
        HStack {
            Text("In (sec)")
            TextField("Fade in", value: bind(\.fadeInSeconds), format: .number).frame(width: 65)
        }
        Toggle("Fade out when Stop is triggered", isOn: bind(\.autoFadeOut))
        HStack {
            Text("Out (sec)")
            TextField("Fade out", value: bind(\.fadeOutSeconds), format: .number).frame(width: 65)
        }
        Picker("Fade curve", selection: bind(\.curve)) {
            ForEach(FadeCurve.allCases) { curve in Text(curve.rawValue).tag(curve) }
        }
        Divider()
        Button("Stop using cue's fade setting") {
            if current.autoFadeOut { state.sound.fadeOutAndStop(current.id, seconds: current.fadeOutSeconds) }
            else { state.sound.stop(current.id) }
        }
        Button("Clear Pad", role: .destructive) {
            state.sound.stop(current.id)
            state.setCue(nil)
        }
    }
    private func bind<T>(_ key: WritableKeyPath<Cue, T>) -> Binding<T> {
        Binding(get: { state.project.cues[state.selected]![keyPath: key] },
                set: { newValue in
                    state.project.cues[state.selected]![keyPath: key] = newValue
                    state.save()
                })
    }
    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        if panel.runModal() == .OK, let url = panel.url {
            state.project.cues[state.selected]?.filePath = url.path
            if state.project.cues[state.selected]?.title.hasPrefix("Cue ") == true {
                state.project.cues[state.selected]?.title = url.deletingPathExtension().lastPathComponent
            }
            state.save()
        }
    }
}
