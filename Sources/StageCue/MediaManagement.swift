import SwiftUI
import AppKit
import AVFoundation

@MainActor final class MediaManagementModel: ObservableObject {
    let original: SoundProject
    let root: URL?
    @Published var draft: SoundProject
    @Published var report = MediaReport()
    @Published var busy = false
    @Published var progress = ""
    @Published var filter = ""
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private let resolver = MediaResolver()
    private let library = MediaLibrary()
    private let spotlight = SpotlightMediaSearch()
    private var folders: [URL] = []
    init(project: SoundProject, root: URL?) { original = project; draft = project; self.root = root }
    var visible: [AssetResolution] {
        report.items.filter { filter.isEmpty || $0.asset.filename.localizedCaseInsensitiveContains(filter) || $0.asset.originalPath.localizedCaseInsensitiveContains(filter) }
    }
    func waitForOperation() async { await task?.value }
    @discardableResult func apply(to state: ShowState) -> Bool {
        guard !busy, state.project == original else { progress = "Project changed while this window was open. Cancel and reopen to protect those edits."; return false }
        state.project = draft; state.mediaReport = report
        state.video.setBackground(state.project.backgroundPath)
        state.message = "Media choices applied. Save Project to keep them in the named file."
        return true
    }
    func cancel() { generation = UUID(); task?.cancel(); spotlight.finish([]); busy = false }
    func scan(useSpotlight: Bool = false) {
        cancel(); let token = generation; busy = true
        let snapshot = draft
        task = Task {
            defer { if generation == token { busy = false } }
            do {
                var urls: [URL] = []
                if useSpotlight {
                    progress = "Searching Spotlight… It may be unavailable or have no indexed matches."
                    let names = report.items.filter { $0.status == .missing || $0.status == .ambiguous }.map { $0.asset.filename }
                    urls = await spotlight.search(filenames: names)
                }
                let result = try await resolver.resolve(snapshot, root: root, folders: folders, spotlight: urls, progress: { [weak self] value in
                    Task { @MainActor in if self?.generation == token { self?.progress = value } }
                })
                try Task.checkCancellation()
                guard generation == token else { return }
                draft = result.project; report = result.report
                progress = useSpotlight && urls.isEmpty ? "Spotlight returned no accessible candidates. Folder search remains available." : "Search complete. Review matches, then Apply or Cancel."
            } catch is CancellationError { }
            catch { if generation == token { progress = "Search failed: \(error.localizedDescription)" } }
        }
    }
    func chooseFolder() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.prompt = "Search Folder"; panel.message = "Search this directory and its subdirectories for all missing assets. Changes remain staged until Apply."
        if panel.runModal() == .OK, let url = panel.url { folders.append(url); scan() }
    }
    func chooseFile(_ asset: MediaAsset) {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.canChooseFiles = true
        panel.prompt = "Use Selected File"; panel.message = "Replace \(asset.filename). This explicit choice can accept different content; related cue assignments will be updated together."
        if panel.runModal() == .OK, let url = panel.url { accept(asset, url: url) }
    }
    func accept(_ asset: MediaAsset, url: URL) {
        cancel(); let token = generation; busy = true
        task = Task {
            defer { if generation == token { busy = false } }
            do {
                progress = "Validating selected file…"
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                var duration: Double?
                if asset.kind == .image { _ = try await VisualMediaLoader().inspect(url.path, kind: .image) }
                else {
                    let av = AVURLAsset(url: url)
                    let watchdog = Task {
                        do { try await Task.sleep(for: .seconds(10)); av.cancelLoading() } catch { }
                    }
                    defer { watchdog.cancel() }
                    let tracks = try await withTaskCancellationHandler {
                        try await av.loadTracks(withMediaType: asset.kind == .audio ? .audio : .video)
                    } onCancel: { av.cancelLoading() }
                    guard !tracks.isEmpty else { throw MediaIssue(message: "Selected file has no matching media track") }
                    let seconds = try await withTaskCancellationHandler { try await av.load(.duration).seconds } onCancel: { av.cancelLoading() }
                    guard seconds.isFinite, seconds > 0 else { throw MediaIssue(message: "Selected media has no finite duration") }
                    duration = seconds
                }
                let fp = try await Task.detached { try MediaLibrary.fingerprint(url) }.value
                try Task.checkCancellation(); guard generation == token else { return }
                draft.connect(asset, to: url)
                if let i = draft.media.assets.firstIndex(where: { $0.id == asset.id }) {
                    draft.media.assets[i].filename = url.lastPathComponent
                    draft.media.assets[i].sha256 = fp.hash; draft.media.assets[i].bytes = fp.bytes; draft.media.assets[i].modified = fp.modified
                    draft.media.assets[i].duration = duration
                    draft.media.assets[i].relativePath = root.flatMap { MediaPaths.relative(url, root: $0) }
                    draft.media.assets[i].bookmark = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
                }
                // A located file supplies a nearby folder for safe batch recovery of the rest.
                folders.append(url.deletingLastPathComponent())
                let result = try await resolver.resolve(draft, root: root, folders: folders)
                try Task.checkCancellation(); guard generation == token else { return }
                draft = result.project; report = result.report; progress = "Choice staged. Nearby media checked; Apply to keep changes."
            } catch is CancellationError { }
            catch { if generation == token { progress = "Cannot use file: \(error.localizedDescription)" } }
        }
    }
}

struct MediaManagementView: View {
    @EnvironmentObject var state: ShowState
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: MediaManagementModel
    init(project: SoundProject, root: URL?) { _model = StateObject(wrappedValue: MediaManagementModel(project: project, root: root)) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Media Management").font(.title2.bold())
            Text("Project files can reference media anywhere. Portable folders collect every required asset for another Mac.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("Relink Missing Media") { model.chooseFolder() }
                Button("Locate Media Folder") { model.chooseFolder() }
                Button("Search with Spotlight") { model.scan(useSpotlight: true) }
                Button("Refresh Report") { model.scan() }
                Spacer()
                Button("Export Portable Project…") { state.exportPortable() }
                    .disabled(model.draft != model.original)
                    .help("Apply staged media choices before exporting the active project")
            }.disabled(model.busy || state.mediaBusy)
            Text(model.report.summary).font(.system(.body, design: .monospaced)).textSelection(.enabled)
            TextField("Filter filename or original location", text: $model.filter).textFieldStyle(.roundedBorder)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(model.visible) { item in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(item.asset.filename).bold()
                                Text(item.asset.kind.rawValue).font(.caption)
                                Spacer()
                                Text(item.status.rawValue).foregroundStyle(item.status == .missing || item.status == .ambiguous ? Color.orange : Color.green)
                                Button("Choose File…") { model.chooseFile(item.asset) }.disabled(model.busy || state.mediaBusy)
                            }
                            Text("Expected: " + item.asset.originalPath).font(.caption).textSelection(.enabled)
                            Text("\(item.asset.cueIDs.count) cue reference(s)" + (item.asset.background ? " • Background" : "")).font(.caption).foregroundStyle(.secondary)
                            ForEach(item.candidates) { candidate in
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(candidate.path).font(.caption).textSelection(.enabled)
                                        Text(candidate.evidence).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Button("Use This File") { model.accept(item.asset, url: URL(fileURLWithPath: candidate.path)) }.disabled(model.busy || state.mediaBusy)
                                }
                            }
                            Divider()
                        }
                    }
                }
            }
            if model.busy || state.mediaBusy {
                HStack { ProgressView().controlSize(.small); Text(state.mediaBusy ? state.mediaProgress : model.progress); Spacer(); Button("Cancel Operation") { model.cancel(); state.cancelMediaOperation() } }
            } else { Text(model.progress).font(.caption).textSelection(.enabled) }
            ForEach(model.report.notes, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
            HStack {
                Button("Cancel") { model.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
                Text("Missing media can be skipped; other cues remain usable.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Apply Reliable Matches and Choices") {
                    if model.apply(to: state) { dismiss() }
                }.buttonStyle(.borderedProminent).disabled(model.busy || state.mediaBusy)
            }
        }.padding(20).frame(minWidth: 1000, idealWidth: 1100, minHeight: 650)
            .task { model.scan() }
            .onDisappear { model.cancel() }
    }
}

extension ShowState {
    func cancelMediaOperation() {
        mediaOperation = UUID(); mediaTask?.cancel(); spotlightSearch.finish([])
        mediaBusy = false; mediaProgress = "Cancellation requested. Unfinished exports are removed; an export already published remains valid."
    }
    func exportPortable() {
        guard !mediaBusy else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = project.title + " Portable"
        panel.title = "Export Portable Project"
        panel.prompt = "Export Portable Project"
        panel.message = "Choose a NEW folder name. StageCue will collect media there and leave your project and original files unchanged."
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        exportPortable(to: url)
    }
    func exportPortable(to url: URL) {
        guard !mediaBusy else { return }
        let snapshot = project, operation = UUID()
        mediaOperation = operation; mediaBusy = true; mediaProgress = "Preparing portable project…"
        mediaTask = Task {
            defer { if mediaOperation == operation { mediaBusy = false } }
            do {
                let file = try await mediaLibrary.exportPortable(snapshot, to: url, progress: { [weak self] value in
                    Task { @MainActor in if self?.mediaOperation == operation { self?.mediaProgress = value } }
                })
                guard mediaOperation == operation else { return }
                mediaProgress = "Portable project verified: \(file.path)"
                message = mediaProgress
            } catch is CancellationError {
                if mediaOperation == operation { mediaProgress = "Export canceled; working project unchanged" }
            } catch {
                if mediaOperation == operation { mediaProgress = "Export failed: \(error.localizedDescription)"; message = mediaProgress }
            }
        }
    }
}
