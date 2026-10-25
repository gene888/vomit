import Foundation

enum AssetStatus: String, Sendable { case available = "Available", relinked = "Automatically Relinked", missing = "Missing", ambiguous = "Ambiguous Matches" }
struct MediaCandidate: Identifiable, Equatable, Sendable {
    var id: String { path }
    var path: String
    var evidence: String
    var reliable: Bool
}
struct AssetResolution: Identifiable, Equatable, Sendable {
    var id: UUID { asset.id }
    var asset: MediaAsset
    var status: AssetStatus
    var candidates: [MediaCandidate] = []
    var detail = ""
}
struct MediaReport: Equatable, Sendable {
    var items: [AssetResolution] = []
    var notes: [String] = []
    func count(_ status: AssetStatus) -> Int { items.filter { $0.status == status }.count }
    var summary: String {
        "Total Media Assets: \(items.count)\nAvailable: \(count(.available))\nAutomatically Relinked: \(count(.relinked))\nMissing: \(count(.missing))\nAmbiguous Matches: \(count(.ambiguous))"
    }
}
struct MediaResolutionResult: Sendable { var project: SoundProject; var report: MediaReport }

actor MediaResolver {
    let library = MediaLibrary()
    /// Bounded enumeration searches only supplied roots. Spotlight is an optional candidate provider.
    func resolve(_ input: SoundProject, root: URL?, folders: [URL] = [], spotlight: [URL] = [],
                 progress: @Sendable (String) -> Void = { _ in }) async throws -> MediaResolutionResult {
        var project = try await library.catalog(input, root: root, refresh: false, progress: progress)
        var report = MediaReport()
        var roots = root.map { [$0.appendingPathComponent("Media", isDirectory: true)] } ?? []
        roots += folders
        var scoped: [URL] = []
        for folder in roots where folder.startAccessingSecurityScopedResource() { scoped.append(folder) }
        defer { for folder in scoped { folder.stopAccessingSecurityScopedResource() } }
        var files: [URL] = []
        let names = Set(project.media.assets.map { $0.filename.lowercased() })
        for folder in roots {
            try Task.checkCancellation()
            progress("Searching \(folder.lastPathComponent)…")
            guard let en = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, _ in true }) else { continue }
            var visited = 0
            for case let url as URL in en {
                try Task.checkCancellation(); visited += 1
                if visited > 100_000 { report.notes.append("Folder search reached 100000 entries; choose a narrower folder"); break }
                if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { en.skipDescendants(); continue }
                if names.contains(url.lastPathComponent.lowercased()), MediaPaths.readable(url) { files.append(url) }
            }
        }
        files += spotlight.filter { MediaPaths.readable($0) }
        // Fingerprints are cached only for this operation, avoiding stale evidence after file replacement.
        var fingerprints: [String: MediaLibrary.Fingerprint] = [:]
        for asset in project.media.assets {
            try Task.checkCancellation()
            progress("Resolving \(asset.filename)…")
            var preferred: [URL] = []
            if let root, let relative = asset.relativePath { preferred.append(try MediaPaths.relativeURL(relative, root: root)) }
            let current = project.allCues.first(where: { asset.cueIDs.contains($0.id) })?.filePath ?? (asset.background ? project.backgroundPath : asset.originalPath)
            if current.hasPrefix("/") { preferred.append(URL(fileURLWithPath: current)) }
            if asset.originalPath.hasPrefix("/") { preferred.append(URL(fileURLWithPath: asset.originalPath)) }
            var bookmarkScope: URL?
            if let bookmark = asset.bookmark {
                var stale = false
                if let url = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale), !stale {
                    if url.startAccessingSecurityScopedResource() { bookmarkScope = url }
                    preferred.append(url)
                }
            }
            defer { bookmarkScope?.stopAccessingSecurityScopedResource() }
            var candidates: [MediaCandidate] = []
            var seen: Set<String> = []
            var winner: URL?
            var moved = false
            for (index, url) in (preferred + files).enumerated() {
                try Task.checkCancellation()
                let path = url.standardizedFileURL.resolvingSymlinksInPath().path
                guard seen.insert(path).inserted, MediaPaths.readable(url) else { continue }
                if index >= preferred.count && url.lastPathComponent.lowercased() != asset.filename.lowercased() { continue }
                let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
                // Wrong byte size is never a suggested automatic match.
                if let expected = asset.bytes, let size, Int64(size) != expected { continue }
                let fp: MediaLibrary.Fingerprint
                if let cached = fingerprints[path] { fp = cached }
                else {
                    guard let value = try? MediaLibrary.fingerprint(url) else { continue }
                    fp = value; fingerprints[path] = value
                }
                if let hash = asset.sha256 {
                    if hash == fp.hash {
                        winner = url; moved = index >= preferred.count || path != current; break
                    }
                    // Same filename and size but different bytes needs explicit operator review.
                    candidates.append(MediaCandidate(path: path, evidence: "Name and size match; content differs — review required", reliable: false))
                } else if index < preferred.count {
                    winner = url; moved = path != current; break
                } else {
                    candidates.append(MediaCandidate(path: path, evidence: "Filename matches; original content identity unavailable — review required", reliable: false))
                }
            }
            if let winner {
                project.connect(asset, to: winner)
                if let i = project.media.assets.firstIndex(where: { $0.id == asset.id }), let fp = fingerprints[winner.standardizedFileURL.resolvingSymlinksInPath().path] {
                    project.media.assets[i].sha256 = fp.hash; project.media.assets[i].bytes = fp.bytes
                    project.media.assets[i].modified = fp.modified
                }
                report.items.append(AssetResolution(asset: asset, status: moved ? .relinked : .available))
            } else {
                report.items.append(AssetResolution(asset: asset, status: candidates.isEmpty ? .missing : .ambiguous,
                                                   candidates: Array(candidates.prefix(100)), detail: "Original file missing, unreadable, or identity changed"))
            }
        }
        return MediaResolutionResult(project: project, report: report)
    }
}

/// NSMetadataQuery must live on the main run loop. Gathering is done by Spotlight;
/// candidate validation and hashing remain on MediaResolver, never on this actor.
@MainActor final class SpotlightMediaSearch {
    private var query: NSMetadataQuery?
    private var observer: NSObjectProtocol?
    private var continuation: CheckedContinuation<[URL], Never>?
    private var timeout: Task<Void, Never>?
    func search(filenames: [String]) async -> [URL] {
        finish([])
        guard !filenames.isEmpty else { return [] }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                let query = NSMetadataQuery()
                // Exact filenames only; no shell commands or query-string interpolation.
                query.predicate = NSCompoundPredicate(orPredicateWithSubpredicates: Array(Set(filenames)).prefix(512).map {
                    NSPredicate(format: "%K ==[c] %@", NSMetadataItemFSNameKey, $0)
                })
                query.searchScopes = [NSMetadataQueryLocalComputerScope]
                self.query = query
                observer = NotificationCenter.default.addObserver(forName: .NSMetadataQueryDidFinishGathering, object: query, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self, let query = self.query else { return }
                        query.disableUpdates()
                        let urls = (0..<min(query.resultCount, 5000)).compactMap { i -> URL? in
                            guard let item = query.result(at: i) as? NSMetadataItem,
                                  let path = item.value(forAttribute: NSMetadataItemPathKey) as? String else { return nil }
                            return URL(fileURLWithPath: path)
                        }
                        self.finish(urls)
                    }
                }
                if !query.start() { finish([]); return }
                timeout = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(8)); self?.finish([]) } catch { }
                }
                if Task.isCancelled { finish([]) }
            }
        } onCancel: { Task { @MainActor [weak self] in self?.finish([]) } }
    }
    func finish(_ urls: [URL]) {
        query?.stop(); query = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }; observer = nil
        timeout?.cancel(); timeout = nil
        let continuation = continuation; self.continuation = nil; continuation?.resume(returning: urls)
    }
}
