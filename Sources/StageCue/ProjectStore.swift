import Foundation

enum ProjectFileIssue: LocalizedError, Equatable {
    case capacity(Int), malformed, unsupportedVersion(Int), unsupportedManifest(Int), encoding
    var errorDescription: String? {
        switch self {
        case .capacity(let bytes): return "Project exceeds the supported size of \(bytes / 1024 / 1024) MiB. Reduce project metadata or split the production into smaller projects."
        case .malformed: return "Project data is malformed or contains invalid settings. The original file has not been changed."
        case .unsupportedVersion(let version): return "Project format version \(version) is not supported by this StageCue build."
        case .unsupportedManifest(let version): return "Media manifest version \(version) is not supported by this StageCue build."
        case .encoding: return "Project could not be serialized. Check its media metadata and settings before saving again."
        }
    }
}

enum ProjectStore {
    // Independent of model-count normalization; bounds input before JSON allocation.
    static let maximumBytes = 16 * 1024 * 1024
    static func load(from url: URL) throws -> (SoundProject, [String]) {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) <= maximumBytes else {
            throw ProjectFileIssue.capacity(maximumBytes)
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var data = Data()
        data.reserveCapacity(min(maximumBytes, (attributes[.size] as? NSNumber)?.intValue ?? 0))
        // Bound the actual read too: a file can grow after the attributes check.
        while data.count <= maximumBytes {
            guard let chunk = try handle.read(upToCount: min(65536, maximumBytes + 1 - data.count)), !chunk.isEmpty else { break }
            data.append(chunk)
        }
        guard data.count <= maximumBytes else { throw ProjectFileIssue.capacity(maximumBytes) }
        var project: SoundProject
        do { project = try JSONDecoder().decode(SoundProject.self, from: data) }
        catch let error as ProjectFileIssue { throw error }
        catch { throw ProjectFileIssue.malformed }
        var assetIDs: Set<UUID> = [], cueAssets: Set<UUID> = []
        guard project.media.assets.filter(\.background).count <= 1 else { throw MediaIssue(message: "Multiple background asset records") }
        for asset in project.media.assets {
            guard assetIDs.insert(asset.id).inserted, asset.kind != .group,
                  asset.bytes.map({ $0 >= 0 }) ?? true,
                  asset.sha256.map({ $0.count == 64 && $0.allSatisfy({ $0.isHexDigit }) }) ?? true else { throw MediaIssue(message: "Invalid media manifest record") }
            for cue in asset.cueIDs {
                guard cueAssets.insert(cue).inserted else { throw MediaIssue(message: "A cue is associated with more than one media asset") }
            }
        }
        let notes = project.normalize()
        let root = url.deletingLastPathComponent()
        try project.mapMediaPaths { try MediaPaths.resolve($0, root: root) }
        for i in project.media.assets.indices {
            if let relative = project.media.assets[i].relativePath { _ = try MediaPaths.relativeURL(relative, root: root) }
            project.media.assets[i].originalPath = try MediaPaths.resolve(project.media.assets[i].originalPath, root: root)
        }
        return (project, notes)
    }
    static func save(_ project: SoundProject, to url: URL) throws {
        var validated = project
        validated.normalize()
        let root = url.deletingLastPathComponent()
        validated.mapMediaPaths { path in
            guard !path.isEmpty, path.hasPrefix("/") else { return path }
            return MediaPaths.relative(URL(fileURLWithPath: path), root: root) ?? path
        }
        for i in validated.media.assets.indices {
            let path = validated.media.assets[i].originalPath
            if path.hasPrefix("/") {
                validated.media.assets[i].relativePath = MediaPaths.relative(URL(fileURLWithPath: path), root: root)
                if let relative = validated.media.assets[i].relativePath { validated.media.assets[i].originalPath = relative }
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data: Data
        do { data = try encoder.encode(validated) }
        catch { throw ProjectFileIssue.encoding }
        guard data.count <= maximumBytes else { throw ProjectFileIssue.capacity(maximumBytes) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}

/// Serializes writes away from the UI actor; atomic replacement preserves the previous file on failure.
actor ProjectWriter {
    private var revisions: [URL: Int] = [:]
    func save(_ project: SoundProject, to url: URL, revision: Int) throws {
        guard revision >= (revisions[url] ?? -1) else { return }
        try ProjectStore.save(project, to: url)
        revisions[url] = revision
    }
}
