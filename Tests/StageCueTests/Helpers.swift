import Foundation
import Testing

final class TemporaryFiles {
    let directory: URL
    init() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("stagecue-tests-\(UUID())")
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: directory) }
}
func expectEqual<T: Equatable>(_ a: T, _ b: T, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(a == b, sourceLocation: sourceLocation)
}
func expectEqual<T: BinaryFloatingPoint>(_ a: T, _ b: T, accuracy: T, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(abs(a - b) <= accuracy, sourceLocation: sourceLocation)
}
func expectNotEqual<T: Equatable>(_ a: T, _ b: T, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(a != b, sourceLocation: sourceLocation)
}
func expectTrue(_ condition: Bool, _ message: String = "", sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(condition, Comment(rawValue: message), sourceLocation: sourceLocation)
}
func expectFalse(_ condition: Bool, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(!condition, sourceLocation: sourceLocation)
}
func expectGreaterThan<T: Comparable>(_ a: T, _ b: T, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(a > b, sourceLocation: sourceLocation)
}
func expectLessThan<T: Comparable>(_ a: T, _ b: T, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(a < b, sourceLocation: sourceLocation)
}
func expectThrows<T>(_ expression: @autoclosure () throws -> T, sourceLocation: SourceLocation = #_sourceLocation) {
    var caught = false
    do { _ = try expression() } catch { caught = true }
    #expect(caught, sourceLocation: sourceLocation)
}
