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
        guard CommandLine.arguments.count > 1 else { fputs("Missing benchmark bundle path\n", stderr); exit(2) }
        let path = CommandLine.arguments[1]
        // Runtime/framework loading can synchronously request main-thread services.
        // Keep AppKit's launch callback and event loop free; measured work starts later.
        print("PROFILE HOST: AppKit launched; loading benchmark off main thread"); fflush(stdout)
        DispatchQueue.global(qos: .userInitiated).async {
            guard let bundle = dlopen(path, RTLD_NOW | RTLD_LOCAL),
                  let symbol = dlsym(bundle, "StageCueStartPerformanceProfile") else {
                let reason = dlerror().map { String(cString: $0) } ?? "No entry point"
                fputs("Profile bundle load failed: \(reason)\n", stderr); exit(2)
            }
            typealias Start = @convention(c) () -> Void
            let start = unsafeBitCast(symbol, to: Start.self)
            DispatchQueue.main.async {
                print("PROFILE HOST: starting main-actor workload"); fflush(stdout)
                start()
            }
        }
    }
}
@main enum PerformanceHostMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = ProfileHost(); app.delegate = delegate
        app.setActivationPolicy(.regular); app.run()
    }
}
