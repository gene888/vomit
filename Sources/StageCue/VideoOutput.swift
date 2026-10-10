import SwiftUI
import AppKit
import Combine
import CoreGraphics

@MainActor final class VisualCanvas: NSView {
    private let backgroundLayer = CALayer()
    private let contentLayer = CALayer()
    private let backLayer = CALayer()
    private let frontLayer = CALayer()
    private let blackoutLayer = CALayer()
    private var changes: AnyCancellable?
    private weak var engine: VideoEngine?
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(backgroundLayer); layer?.addSublayer(contentLayer)
        contentLayer.addSublayer(backLayer); contentLayer.addSublayer(frontLayer)
        layer?.addSublayer(blackoutLayer)
        for l in [backgroundLayer, backLayer, frontLayer] {
            l.contentsGravity = .resizeAspect
            l.backgroundColor = NSColor.black.cgColor
        }
        blackoutLayer.backgroundColor = NSColor.black.cgColor
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func connect(_ engine: VideoEngine) {
        self.engine = engine
        changes = engine.objectWillChange.sink { [weak self] _ in
            // Published notifications precede the new values; render on the next main turn.
            DispatchQueue.main.async { self?.render() }
        }
        render()
    }
    private func render() {
        guard let engine else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        backgroundLayer.contents = engine.background
        backLayer.contents = engine.backFrame; backLayer.isHidden = engine.backFrame == nil
        frontLayer.contents = engine.frontFrame; frontLayer.isHidden = engine.frontFrame == nil
        frontLayer.opacity = Float(engine.frontOpacity)
        contentLayer.opacity = Float(engine.level)
        blackoutLayer.isHidden = !engine.blackout
        CATransaction.commit()
    }
    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for l in [backgroundLayer, contentLayer, backLayer, frontLayer, blackoutLayer] { l.frame = bounds }
        CATransaction.commit()
    }
}
struct VideoPreview: NSViewRepresentable {
    let engine: VideoEngine
    func makeNSView(context: Context) -> VisualCanvas {
        let view = VisualCanvas(frame: .zero); view.connect(engine); return view
    }
    func updateNSView(_ view: VisualCanvas, context: Context) {}
}
struct OutputDisplay: Identifiable, Equatable {
    let id: UInt32
    let name: String
}

enum OutputDisplayPolicy {
    static func eligible(_ ids: [UInt32], operatorID: UInt32?) -> [UInt32] { ids.filter { $0 != operatorID } }
    static func shouldClose(_ target: UInt32, connected: [UInt32], operatorID: UInt32?) -> Bool {
        !connected.contains(target) || target == operatorID
    }
}

@MainActor final class VideoOutputController: ObservableObject {
    @Published private(set) var displays: [OutputDisplay] = []
    @Published var selectedDisplay: UInt32 = 0
    @Published private(set) var showing = false
    @Published private(set) var message = ""
    private weak var engine: VideoEngine?
    private var window: NSWindow?
    private var screenObserver: NSObjectProtocol?
    private var operatorObserver: NSObjectProtocol?
    private var outputDisplay: UInt32?
    private var presentationActivity: NSObjectProtocol?
    init(engine: VideoEngine) {
        self.engine = engine
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        operatorObserver = NotificationCenter.default.addObserver(forName: NSWindow.didChangeScreenNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refresh()
    }
    static func id(_ screen: NSScreen) -> UInt32 { (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0 }
    var operatorScreenID: UInt32? {
        guard let application = NSApp else { return nil }
        return application.windows.first(where: { $0 !== window && $0.isVisible && $0.canBecomeKey })?.screen.map(Self.id)
    }
    func refresh() {
        let operatorID = operatorScreenID ?? NSScreen.main.map(Self.id)
        let eligible = OutputDisplayPolicy.eligible(NSScreen.screens.map(Self.id), operatorID: operatorID)
        displays = NSScreen.screens.filter { eligible.contains(Self.id($0)) }.map { OutputDisplay(id: Self.id($0), name: $0.localizedName) }
        if !displays.contains(where: { $0.id == selectedDisplay }) { selectedDisplay = displays.first?.id ?? 0 }
        if let outputDisplay, OutputDisplayPolicy.shouldClose(outputDisplay, connected: NSScreen.screens.map(Self.id), operatorID: operatorID) {
            close(); message = "Video output closed: display disconnected or now used by the operator"
        } else if let outputDisplay, let screen = NSScreen.screens.first(where: { Self.id($0) == outputDisplay }) {
            window?.setFrame(screen.frame, display: true)
        }
    }
    func present() {
        refresh()
        guard let engine, displays.contains(where: { $0.id == selectedDisplay }),
              let screen = NSScreen.screens.first(where: { Self.id($0) == selectedDisplay }) else {
            message = "Connect an external display separate from the operator screen"; return
        }
        close()
        // Borderless, non-key output: no controls, no focus theft, no fullscreen Space switch.
        let view = VisualCanvas(frame: NSRect(origin: .zero, size: screen.frame.size)); view.connect(engine)
        let output = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        output.isReleasedWhenClosed = false; output.backgroundColor = .black
        output.contentView = view; output.level = .statusBar
        output.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        output.ignoresMouseEvents = true
        output.setFrame(screen.frame, display: true); output.orderFrontRegardless()
        window = output; outputDisplay = selectedDisplay; showing = true; message = ""
        presentationActivity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleDisplaySleepDisabled], reason: "StageCue projector presentation")
    }
    func close() {
        if let presentationActivity { ProcessInfo.processInfo.endActivity(presentationActivity); self.presentationActivity = nil }
        window?.orderOut(nil); window?.close(); window = nil
        outputDisplay = nil; showing = false
    }
    isolated deinit {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        if let operatorObserver { NotificationCenter.default.removeObserver(operatorObserver) }
        if let presentationActivity { ProcessInfo.processInfo.endActivity(presentationActivity) }
        window?.close()
    }
}

struct VideoControls: View {
    @ObservedObject var video: VideoEngine
    @ObservedObject var output: VideoOutputController
    @Binding var project: SoundProject
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VideoPreview(engine: video).frame(width: 224, height: 126).clipShape(RoundedRectangle(cornerRadius: 5))
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("VIDEO").font(.headline)
                    Text(video.currentCue?.title ?? "No visual cue").lineLimit(1)
                    if video.loading { ProgressView().controlSize(.small) }
                    Button(video.paused ? "Resume" : "Pause") { video.paused ? video.resume() : video.pause() }
                    Button("Stop Video") { video.stop() }
                    Toggle("Blackout", isOn: $video.blackout).toggleStyle(.button)
                }
                HStack {
                    Picker("Output display", selection: $output.selectedDisplay) {
                        Text("Select external display").tag(UInt32(0))
                        ForEach(output.displays) { display in Text(display.name).tag(display.id) }
                    }.frame(maxWidth: 360)
                    Button(output.showing ? "Update Output" : "Show Output") { output.present() }
                        .disabled(output.selectedDisplay == 0)
                    if output.showing { Button("Close Output") { output.close() } }
                    Button("Refresh") { output.refresh() }
                }
                HStack {
                    Button("Background…") {
                        let panel = NSOpenPanel(); panel.allowedContentTypes = [.png, .jpeg]
                        if panel.runModal() == .OK, let url = panel.url { project.backgroundPath = url.path }
                    }
                    Button("Clear Background") { project.backgroundPath = "" }.disabled(project.backgroundPath.isEmpty)
                    Text("Soundtrack uses macOS audio output; separate from audio buses.").font(.caption).foregroundStyle(.secondary)
                }
                if !video.error.isEmpty { HStack { Text(video.error).font(.caption).foregroundStyle(.red); Button("Dismiss") { video.clearError() } } }
                if !output.message.isEmpty { Text(output.message).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .onAppear { output.refresh() }
    }
}
