import Carbon
import SwiftUI

// Starts in the background (menu bar only, no Dock icon) when launched with
// --background by the login agent; any other launch, a click on the app while it
// runs (reopen), or "Open NitroSense" in the menu shows the main window. Closing the
// window goes back to background.
@main
struct NitroSenseApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent().environment(delegate.model)
        } label: {
            MenuBarLabel(model: delegate.model)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    static private(set) weak var shared: AppDelegate?
    static let closeMenuNotification = Notification.Name("NitroSenseCloseMenu")
    let model: NitroModel
    private var window: NSWindow?
    private var nitroKey: NitroKeyWatcher?
    private var lastToggle = Date.distantPast
    private var hideDockIcon: DispatchWorkItem?
    private let args = CommandLine.arguments

    override init() {
        model = NitroModel(preview: CommandLine.arguments.contains("--icon"))
        super.init()
        AppDelegate.shared = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // NitroSense --icon <png>: render the app icon. --snapshot <dir>: render pages to PNG.
        if let i = args.firstIndex(of: "--icon"), i + 1 < args.count {
            let renderer = ImageRenderer(content: AppIconView())
            renderer.scale = 1
            if let tiff = renderer.nsImage?.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: args[i + 1]))
            }
            exit(0)
        }
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            let dir = URL(fileURLWithPath: args[i + 1])
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                renderSnapshots(self.model, to: dir)
                exit(0)
            }
            return
        }
        // launchd starts the agent copy directly, so it can race an instance that is
        // already running: keep the first one.
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        if let other = others.first {
            if !args.contains("--background") { other.activate() }
            exit(0)
        }
        LoginItem.configureOnFirstRun()
        nitroKey = NitroKeyWatcher { [weak self] in self?.toggleMainWindow() }
        if !args.contains("--background") {
            showMainWindow()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func showMainWindow() {
        // The menu bar panel stays open otherwise, whichever way the window was opened.
        NotificationCenter.default.post(name: AppDelegate.closeMenuNotification, object: nil)
        if window == nil {
            let host = NSHostingController(rootView: MainView().environment(model))
            host.sizingOptions = [.preferredContentSize]
            host.safeAreaRegions = []  // no title bar inset: the header shares the row with the window buttons
            let w = NSWindow(contentViewController: host)
            w.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.title = "NitroSense"
            w.isMovableByWindowBackground = false  // custom SwiftUI sliders would drag the window
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.center()
            window = w
        }
        model.requestBatteryRead()  // here and not in the view: this also runs when a closed window comes back
        model.rtxFastSampling = true
        model.sampleRTXNow()
        hideDockIcon?.cancel()
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // The NitroSense key opens the window, or closes it when it is already in front.
    // Presses closer than 0.5 s are dropped: flipping the activation policy that fast
    // leaves stale NitroSense tiles in the Dock.
    func toggleMainWindow() {
        let now = Date()
        guard now.timeIntervalSince(lastToggle) > 0.5 else { return }
        lastToggle = now
        if let window, window.isVisible, window.isKeyWindow, NSApp.isActive {
            window.performClose(nil)
        } else {
            showMainWindow()
        }
    }

    func windowWillClose(_ notification: Notification) {
        model.rtxFastSampling = false
        // Drop the Dock icon a moment later, unless the window comes back first.
        let work = DispatchWorkItem { [weak self] in
            guard self?.window?.isVisible != true else { return }
            NSApp.setActivationPolicy(.accessory)
        }
        hideDockIcon = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }
}

// The NitroSense key sends PS/2 scancode e0 75, which SSDT-NITRO maps to F20 for
// VoodooPS2Keyboard. A Carbon hotkey catches it without Accessibility permission.
final class NitroKeyWatcher {
    private let onPress: () -> Void
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?

    init?(onPress: @escaping () -> Void) {
        self.onPress = onPress
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, _, refcon in
            guard let refcon else { return OSStatus(eventNotHandledErr) }
            Unmanaged<NitroKeyWatcher>.fromOpaque(refcon).takeUnretainedValue().onPress()
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard status == noErr,
              RegisterEventHotKey(UInt32(kVK_F20), 0, EventHotKeyID(signature: 0x4E54524F, id: 1),
                                  GetApplicationEventTarget(), 0, &hotKey) == noErr
        else { return nil }
    }

    deinit {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
    }
}

@MainActor
func renderSnapshots(_ model: NitroModel, to dir: URL) {
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    // The controls as they look with the nitrod, kext and SSDT of this build. A made-up reading, only to check the layout.
    let ready = NitroModel(preview: true)
    ready.snapshot = model.snapshot
    ready.connected = true
    ready.rtx = model.rtx
    ready.rtxLoad = model.rtxLoad
    var reading = FirmwareReading()
    reading.fanCPU = 1
    reading.fanGPU = 1
    reading.profile = 1
    ready.control.batteryLimit = BatteryLimitReading(on: true, raw: [3, 0, 0, 1, 0, 0, 0, 0])
    ready.control.batteryWMI = true
    reading.keyboard = [0, 0, 5, 100, 0, 0, 255, 255, 255]
    ready.control.daemonKnowsControls = true
    ready.control.gamingWMI = true
    ready.control.firmwareReadOK = true
    ready.control.firmware = reading
    var customReading = reading
    customReading.fanCPU = 3
    customReading.fanGPU = 3
    customReading.usbCharge = 10
    customReading.kbTimeout = false
    let custom = NitroModel(preview: true)  // the manual duty, and the settings the firmware may answer for
    custom.config = model.config
    custom.snapshot = model.snapshot
    custom.rtx = model.rtx
    custom.rtxLoad = model.rtxLoad
    custom.igpuLoad = 12
    custom.igpuTemp = 48
    custom.igpuPower = 3.4
    custom.control = ready.control
    custom.control.firmware = customReading
    let curve = NitroModel(preview: true)  // the curve, and its editor
    curve.config = model.config
    curve.config.userFan = "curve"
    curve.snapshot = model.snapshot
    curve.rtx = model.rtx
    curve.rtxLoad = model.rtxLoad
    curve.control = ready.control
    let busy = NitroModel(preview: true)  // 5 min of made-up samples to check the hover tooltip
    busy.config = model.config
    busy.snapshot = model.snapshot
    busy.rtx = model.rtx
    busy.rtxLoad = model.rtxLoad
    busy.history = (0..<150).map { i in
        let t = Double(i)
        return Sample(date: Date().addingTimeInterval(Double(i - 150) * 2), cpuTemp: 60 + Int(15 * sin(t / 12)), gpuTemp: nil,
                      cpuLoad: 30 + Int(25 * sin(t / 9)), cpuPower: 20 + 15 * sin(t / 10),
                      rtxLoad: 25 + Int(20 * sin(t / 7)), rtxPower: 18 + 8 * sin(t / 8),
                      igpuLoad: 20 + Int(15 * sin(t / 5)), igpuTemp: 50 + Int(6 * sin(t / 11)), igpuPower: 4 + 3 * sin(t / 6))
    }
    let pages: [(String, AnyView, NitroModel)] = [
        ("monitoring-hover", AnyView(MonitoringPanel().frame(width: 680, height: 300)), busy),
        ("main", AnyView(MainView()), model),
        ("main-ready", AnyView(MainView()), ready),
        ("main-custom", AnyView(MainView()), custom),
        ("main-curve", AnyView(MainView()), curve),
        ("curve-editor", AnyView(CurvePanel(close: {})), curve),
        ("settings-custom", AnyView(SettingsMenu().background(Color(white: 0.16))), custom),
        ("settings", AnyView(SettingsMenu().background(Color(white: 0.16))), model),
        ("settings-ready", AnyView(SettingsMenu().background(Color(white: 0.16))), ready),
        ("menu", AnyView(MenuContent()), model),
        ("menu-ready", AnyView(MenuContent()), ready),
    ]
    for (name, view, m) in pages {
        let content = view
            .environment(m)
            .environment(\.snapshotMode, true)
            .padding(12)
            .background(NS.bg)
            .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: dir.appendingPathComponent("\(name).png"))
        }
    }
}
