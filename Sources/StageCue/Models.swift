import Foundation

// Paths are intentionally absolute for v0.1. Preflight catches missing assets.
enum CueMode: String, Codable, CaseIterable, Identifiable {
    case oneShot = "One-shot", toggle = "Toggle", hold = "Hold"
    var id: String { rawValue }
}
enum FadeCurve: String, Codable, CaseIterable, Identifiable {
    case linear = "Linear amplitude", smooth = "Smooth S-curve", equalPower = "Equal-power"
    var id: String { rawValue }
}
struct Cue: Identifiable, Codable, Equatable {
    var id = UUID()
    var title = "Untitled"
    var filePath = ""
    var gainDB: Double = -6
    var bus = 0
    var mode: CueMode = .oneShot
    var loop = false
    var autoFadeIn = false
    var fadeInSeconds: Double = 2
    var autoFadeOut = false
    var fadeOutSeconds: Double = 2
    var curve: FadeCurve = .smooth
    var tint = "blue"
}
struct SoundProject: Codable {
    var title = "Untitled Show"
    var cues: [Cue?] = Array(repeating: nil, count: 32)
    var busDB: [Double] = Array(repeating: 0, count: 6)
    var masterDB: Double = 0
    var manualFadeSeconds: Double = 3
    mutating func normalize() {
        if cues.count < 32 { cues += Array(repeating: nil, count: 32 - cues.count) }
        if cues.count > 32 { cues = Array(cues.prefix(32)) }
        if busDB.count < 6 { busDB += Array(repeating: 0, count: 6 - busDB.count) }
        if busDB.count > 6 { busDB = Array(busDB.prefix(6)) }
    }
}
func amplitude(_ decibels: Double) -> Float { Float(pow(10, decibels / 20)) }
