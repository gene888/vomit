import AppKit
import Darwin

/// Native event-loop host for the opt-in optimized benchmark bundle.
@MainActor final class ProfileHost: NSObject, NSApplicationDelegate {
    var window: NSWindow?
    func applicationDidFinishLaunching(_ notification: Notification) {
        let window = NSWindow(contentRect: NSRect(x: 50, y: 50, width: 500, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "StageCue Performance Workload"
        let text = NSTextField(labelWithString: "Running local synthetic performance measurements…")
        text.frame = NSRect(x: 20, y: 45, width: 470, height: 24); window.contentView?.addSubview(text)
        self.window = window; window.makeKeyAndOrderFront(nil)
        guard CommandLine.arguments.count > 1, let bundle = dlopen(CommandLine.arguments[1], RTLD_NOW | RTLD_LOCAL),
              let symbol = dlsym(bundle, "StageCueStartPerformanceProfile") else {
            fputs("Profile bundle load failed: \(String(cString: dlerror()))\n", stderr); exit(2)
        }
        typealias Start = @convention(c) () -> Void
        unsafeBitCast(symbol, to: Start.self)()
    }
}
@main enum PerformanceHostMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = ProfileHost(); app.delegate = delegate
        app.setActivationPolicy(.regular); app.run()
    }
}
