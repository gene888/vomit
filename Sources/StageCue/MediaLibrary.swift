import Foundation
import AVFoundation
import CryptoKit
import UniformTypeIdentifiers

extension UTType { static let stagecueProject = UTType(exportedAs: "local.StageCue.project", conformingTo: .json) }

struct MediaAsset: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var filename: String
    var originalPath: String
    var relativePath: String?
    var kind: CueKind
    var bytes: Int64?
    var duration: Double?
    var modified: Date?
    var sha256: String?
    var cueIDs: [UUID] = []
    var background = false
    var bookmark: Data?
}

struct MediaManifest: Codable, Equatable, Sendable {
    var version = 1
    var assets: [MediaAsset] = []
}

enum MediaPaths {
    /// Reject lexical traversal and resolved symlinks leaving the designated root.
    static func relativeURL(_ path: String, root: URL) throws -> URL {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"), !path.contains("\0"),
              !path.split(separator: "/").contains("..") else { throw MediaIssue(message: "Unsafe relative media path: \(path)") }
        let base = root.standardizedFileURL.resolvingSymlinksInPath()
        var result = base
        for component in path.split(separator: "/") {
            result = result.appendingPathComponent(String(component)).standardizedFileURL.resolvingSymlinksInPath()
            guard result.path.hasPrefix(base.path + "/") else { throw MediaIssue(message: "Media path escapes project directory") }
        }
        return result
    }
    static func relative(_ url: URL, root: URL) -> String? {
        let base = root.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        return path.hasPrefix(base) ? String(path.dropFirst(base.count)) : nil
    }
    static func readable(_ url: URL) -> Bool {
        guard let v = try? url.resourceValues(forKeys: [.isRegularFileKey]), v.isRegularFile == true else { return false }
        return FileManager.default.isReadableFile(atPath: url.path)
    }
    static func resolve(_ path: String, root: URL) throws -> String {
        guard !path.isEmpty else { return path }
        return path.hasPrefix("/") ? path : try relativeURL(path, root: root).path
    }
}

extension SoundProject {
    mutating func mapMediaPaths(_ transform: (String) throws -> String) rethrows {
        for i in cues.indices where cues[i]?.kind != .group {
            if let path = cues[i]?.filePath { cues[i]?.filePath = try transform(path) }
        }
        for p in additionalPages.indices {
            for i in additionalPages[p].cues.indices where additionalPages[p].cues[i]?.kind != .group {
                if let path = additionalPages[p].cues[i]?.filePath { additionalPages[p].cues[i]?.filePath = try transform(path) }
            }
        }
        backgroundPath = try transform(backgroundPath)
    }
    mutating func connect(_ asset: MediaAsset, to url: URL) {
        for i in cues.indices where cues[i].map({ asset.cueIDs.contains($0.id) }) == true { cues[i]?.filePath = url.path }
        for p in additionalPages.indices {
            for i in additionalPages[p].cues.indices where additionalPages[p].cues[i].map({ asset.cueIDs.contains($0.id) }) == true {
                additionalPages[p].cues[i]?.filePath = url.path
            }
        }
        if asset.background { backgroundPath = url.path }
        if let i = media.assets.firstIndex(where: { $0.id == asset.id }) { media.assets[i].originalPath = url.path }
    }
}

/// All enumeration, hashing and copy work runs on this actor, outside the UI actor.
actor MediaLibrary {
    struct Fingerprint: Sendable {
        var bytes: Int64
        var modified: Date
        var hash: String
    }
    static func fingerprint(_ url: URL) throws -> Fingerprint {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard MediaPaths.readable(url) else { throw MediaIssue(message: "Media unavailable: \(url.lastPathComponent)") }
        let before = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        var count: Int64 = 0
        while true {
            try Task.checkCancellation()
            let data = try handle.read(upToCount: 1024 * 1024) ?? Data()
            if data.isEmpty { break }
            count += Int64(data.count); hash.update(data: data)
        }
        let after = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        guard before.fileSize == after.fileSize, before.contentModificationDate == after.contentModificationDate,
              count == Int64(after.fileSize ?? -1) else { throw MediaIssue(message: "Media changed while reading: \(url.lastPathComponent)") }
        return Fingerprint(bytes: count, modified: after.contentModificationDate ?? .distantPast,
                           hash: hash.finalize().map { String(format: "%02x", $0) }.joined())
    }
    func catalog(_ input: SoundProject, root: URL?, refresh: Bool = true, progress: @Sendable (String) -> Void = { _ in }) async throws -> SoundProject {
        var project = input
        var paths: [(String, CueKind, UUID?, Bool)] = project.allCues.filter { $0.kind != .group && !$0.filePath.isEmpty }.map { ($0.filePath, $0.kind, $0.id, false) }
        if !project.backgroundPath.isEmpty { paths.append((project.backgroundPath, .image, nil, true)) }
        var assets: [MediaAsset] = []
        var identities: [String: Int] = [:]
        for (path, kind, cueID, background) in paths {
            try Task.checkCancellation()
            let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
            if let i = identities[url.path] {
                if let cueID { assets[i].cueIDs.append(cueID) }; assets[i].background = assets[i].background || background
                continue
            }
            let old = project.media.assets.first { a in cueID.map { a.cueIDs.contains($0) } ?? (background && a.background) }
            var asset = old ?? MediaAsset(filename: url.lastPathComponent, originalPath: url.path, kind: kind)
            asset.cueIDs = cueID.map { [$0] } ?? []; asset.background = background; asset.kind = kind
            // Keep an unresolved record's expected metadata and original location.
            if MediaPaths.readable(url), refresh || old == nil {
                progress("Reading \(url.lastPathComponent)")
                let fp = try Self.fingerprint(url)
                asset.filename = url.lastPathComponent; asset.originalPath = url.path
                asset.relativePath = root.flatMap { MediaPaths.relative(url, root: $0) }
                asset.bytes = fp.bytes; asset.modified = fp.modified; asset.sha256 = fp.hash
                if kind != .image {
                    let av = AVURLAsset(url: url)
                    let watchdog = Task {
                        do { try await Task.sleep(for: .seconds(10)); av.cancelLoading() } catch { }
                    }
                    let duration = try? await withTaskCancellationHandler {
                        try await av.load(.duration).seconds
                    } onCancel: { av.cancelLoading() }
                    watchdog.cancel()
                    try Task.checkCancellation()
                    asset.duration = duration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
                }
            }
            // Content deduplication preserves shared cue references and an existing asset ID.
            if let hash = asset.sha256, let i = assets.firstIndex(where: { $0.sha256 == hash && $0.kind == kind }) {
                assets[i].cueIDs += asset.cueIDs; assets[i].background = assets[i].background || background
                identities[url.path] = i
            } else { identities[url.path] = assets.count; assets.append(asset) }
        }
        project.media = MediaManifest(assets: assets)
        return project
    }

    /// The destination must not exist. A hidden sibling is atomically published only after verification.
    func exportPortable(_ input: SoundProject, to destination: URL,
                        progress: @Sendable (String) -> Void = { _ in },
                        beforeCopy: @Sendable (Int) throws -> Void = { _ in }) async throws -> URL {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: destination.path) else { throw MediaIssue(message: "Choose a new portable folder; existing items are never replaced") }
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".stagecue-export-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        var published = false
        defer { if !published { try? fm.removeItem(at: staging) } }
        var project = try await catalog(input, root: nil, refresh: false, progress: progress)
        for i in project.media.assets.indices {
            try Task.checkCancellation(); try beforeCopy(i)
            let asset = project.media.assets[i]
            let source = URL(fileURLWithPath: asset.originalPath)
            guard MediaPaths.readable(source), let expected = asset.sha256 else { throw MediaIssue(message: "Cannot export missing media: \(asset.filename)") }
            let folder = asset.kind == .audio ? "Audio" : asset.kind == .video ? "Video" : "Images"
            let safeName = source.lastPathComponent.replacingOccurrences(of: ":", with: "_")
            let relative = "Media/\(folder)/\(asset.id.uuidString)/\(safeName)"
            let target = try MediaPaths.relativeURL(relative, root: staging)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            progress("Copying \(i + 1) of \(project.media.assets.count): \(asset.filename)")
            let scoped = source.startAccessingSecurityScopedResource()
            defer { if scoped { source.stopAccessingSecurityScopedResource() } }
            // Stream in bounded chunks for large media and responsive cancellation.
            let reader = try FileHandle(forReadingFrom: source)
            defer { try? reader.close() }
            guard fm.createFile(atPath: target.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
            let writer = try FileHandle(forWritingTo: target)
            defer { try? writer.close() }
            var copied = SHA256()
            while true {
                try Task.checkCancellation()
                let data = try reader.read(upToCount: 1024 * 1024) ?? Data()
                if data.isEmpty { break }
                try writer.write(contentsOf: data); copied.update(data: data)
            }
            try writer.synchronize(); try writer.close()
            let hash = copied.finalize().map { String(format: "%02x", $0) }.joined()
            guard hash == expected, try Self.fingerprint(target).hash == expected else { throw MediaIssue(message: "Copied media failed verification: \(asset.filename)") }
            project.connect(asset, to: target)
            project.media.assets[i].relativePath = relative
            project.media.assets[i].originalPath = relative // No dependency on the source Mac.
            project.media.assets[i].bookmark = nil
        }
        let file = staging.appendingPathComponent("Project.stagecue")
        try ProjectStore.save(project, to: file)
        let manifest = try JSONEncoder().encode(project.media)
        try manifest.write(to: staging.appendingPathComponent("MediaManifest.json"), options: .atomic)
        let loaded = try ProjectStore.load(from: file).0
        for asset in loaded.media.assets {
            guard let relative = asset.relativePath,
                  try Self.fingerprint(MediaPaths.relativeURL(relative, root: staging)).hash == asset.sha256 else {
                throw MediaIssue(message: "Export verification failed")
            }
        }
        guard loaded.allCues.filter({ $0.kind != .group && !$0.filePath.isEmpty }).allSatisfy({ MediaPaths.readable(URL(fileURLWithPath: $0.filePath)) }),
              loaded.showReferenceIssues().isEmpty else { throw MediaIssue(message: "Export has missing media or invalid show references; repair it before exporting") }
        try Task.checkCancellation()
        try fm.moveItem(at: staging, to: destination)
        published = true
        return destination.appendingPathComponent("Project.stagecue")
    }
}
