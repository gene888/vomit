import AppKit
import Foundation

/// Runs the compiled Swift Testing bundle with normal macOS audio-component access.
/// It requests no permissions, performs no networking, and only writes test results under work/.
@MainActor final class ValidationRunner: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var label: NSTextField?
    private var process: Process?
    private var button: NSButton?
    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu()
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu; menu.addItem(appMenuItem)
        NSApplication.shared.mainMenu = menu
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 240), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "StageCue Audio Validation"
        let label = NSTextField(wrappingLabelWithString: "Preparing automated tests…")
        label.frame = NSRect(x: 24, y: 64, width: 632, height: 152)
        window.contentView?.addSubview(label)
        let button = NSButton(title: "Run Again", target: self, action: #selector(runTests))
        button.frame = NSRect(x: 24, y: 20, width: 130, height: 32)
        window.contentView?.addSubview(button)
        self.button = button; self.label = label; self.window = window
        window.center(); window.makeKeyAndOrderFront(nil)
        runTests()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    @objc private func runTests() {
        guard process == nil || process?.isRunning == false,
              let sourceRoot = Bundle.main.object(forInfoDictionaryKey: "StageCueSourceRoot") as? String else { return }
        button?.isEnabled = false
        label?.stringValue = "Running StageCue automated tests in native macOS context…"
        let root = URL(fileURLWithPath: sourceRoot)
        let log = root.appendingPathComponent("work/native-tests.log")
        try? FileManager.default.removeItem(at: root.appendingPathComponent("work/native-tests.exit"))
        FileManager.default.createFile(atPath: log.path, contents: nil)
        do {
            let file = try FileHandle(forWritingTo: log)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/libexec/swift/pm/swiftpm-testing-helper")
            let candidates = ["work/SwiftBuild/out/Products/Debug/StageCueTests.xctest/Contents/MacOS/StageCueTests", "work/SwiftBuild/arm64-apple-macosx/debug/StageCuePackageTests.xctest/Contents/MacOS/StageCuePackageTests"]
            guard let bundle = candidates.map({ root.appendingPathComponent($0) }).first(where: { FileManager.default.fileExists(atPath: $0.path) }) else { throw CocoaError(.fileNoSuchFile) }
            process.arguments = ["--test-bundle-path", bundle.path, "--testing-library", "swift-testing"]
            var environment = ProcessInfo.processInfo.environment
            environment["DYLD_FRAMEWORK_PATH"] = "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/Library/Frameworks"
            environment["DYLD_LIBRARY_PATH"] = "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/usr/lib:/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/macosx"
            process.environment = environment
            process.currentDirectoryURL = root
            process.standardOutput = file; process.standardError = file
            process.terminationHandler = { [weak self] process in
                let status = process.terminationStatus
                try? file.close()
                try? String(status).write(to: root.appendingPathComponent("work/native-tests.exit"), atomically: true, encoding: .utf8)
                Task { @MainActor [weak self] in
                    self?.label?.stringValue = "Test runner finished with exit status \(status).\nResults: \(log.path)"
                    self?.button?.isEnabled = true
                }
            }
            self.process = process
            try process.run()
        } catch {
            label?.stringValue = "Test launch failed: \(error.localizedDescription)"
            button?.isEnabled = true
        }
    }
}
@main enum ValidationMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        let runner = ValidationRunner()
        app.delegate = runner
        app.setActivationPolicy(.regular)
        app.run()
    }
}
