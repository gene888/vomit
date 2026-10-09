import Foundation

enum ProjectStore {
    static let maximumBytes = 2 * 1024 * 1024
    static func load(from url: URL) throws -> (SoundProject, [String]) {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) <= maximumBytes else {
            throw CocoaError(.fileReadTooLarge)
        }
        let data = try Data(contentsOf: url)
        guard data.count <= maximumBytes else { throw CocoaError(.fileReadTooLarge) }
        var project = try JSONDecoder().decode(SoundProject.self, from: data)
        let notes = project.normalize()
        return (project, notes)
    }
    static func save(_ project: SoundProject, to url: URL) throws {
        var validated = project
        validated.normalize()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(validated)
        guard data.count <= maximumBytes else { throw CocoaError(.fileWriteOutOfSpace) }
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
