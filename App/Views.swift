// Main window laid out like Acer NitroSense 3 (AN515-57): header bar, Fan Control panel with two fan dials, Power Plan and
// Monitoring panels below. The keyboard backlight opens as an overlay dialog; the gear opens a settings menu. On the ANV15-52
// only what can work is clickable (Auto and Max, the three power modes, marked unverified, and the login item); the rest
// says why it is not there.

import IOKit.ps
import ServiceManagement
import SwiftUI

func tempColor(_ t: Int) -> Color {
    t >= 90 ? .red : t >= 75 ? NS.orange : t >= 60 ? .yellow : .green
}

enum Overlay { case none, keyboard, curve }

let unverifiedFirmwareHelp = "Goes through the firmware's gaming WMI. It has never been tried on this board: the firmware answers with a status and the state is read back, but what it really does has to be checked."

// MARK: - Main window

struct MainView: View {
    @Environment(NitroModel.self) private var model
    @State private var overlay: Overlay = .none

    var body: some View {
        ZStack {
            NS.bg.ignoresSafeArea()
            VStack(spacing: 8) {
                HeaderBar(overlay: $overlay)
                if let error = model.error {
                    StatusStrip(text: error, color: NS.red, icon: "exclamationmark.triangle.fill")
                } else if let message = model.actionMessage {
                    StatusStrip(text: message, color: model.actionIsWarning ? NS.orange : NS.red, icon: "exclamationmark.triangle.fill")
                }
                FanControlPanel().frame(height: 200)
                HStack(spacing: 8) {
                    PowerPlanPanel().frame(width: 210)
                    MonitoringPanel()
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)

            if overlay != .none {
                Color.black.opacity(0.55).ignoresSafeArea()
                    .onTapGesture { overlay = .none }
                Group {
                    if overlay == .keyboard {
                        KeyboardPanel { overlay = .none }
                    } else {
                        CurvePanel { overlay = .none }
                    }
                }
                .transition(.opacity)
            }
        }
        .frame(width: 900, height: 560)
        .ignoresSafeArea()  // header shares the row with the window buttons, as in NitroSense
        .preferredColorScheme(.dark)
        .animation(.easeOut(duration: 0.15), value: overlay)
        .onAppear { model.requestTrustedRead() }
    }
}

struct StatusStrip: View {
    let text: String
    let color: Color
    let icon: String

    var body: some View {
        Label(text, systemImage: icon)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(4)
            .background(color.opacity(0.85), in: RoundedRectangle(cornerRadius: 4))
    }
}

// Empty header space drags the window (the title bar is hidden under the header).
struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    }
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

struct HeaderBar: View {
    @Environment(NitroModel.self) private var model
    @Binding var overlay: Overlay
    @Environment(\.snapshotMode) private var snapshotMode
    @State private var showSettings = false

    var body: some View {
        ZStack {
            HStack(spacing: 14) {
                Text("acer")
                    .font(.system(size: 24, weight: .heavy, design: .rounded))
                    .italic()
                    .foregroundStyle(Color(white: 0.82))
                    .padding(.leading, 70)  // clear of the window buttons
                Spacer()
                HeaderIcon(icon: "keyboard", help: "Keyboard backlight (read only on this model)") { overlay = .keyboard }
                HeaderIcon(icon: "gearshape.fill", help: "Settings") { showSettings.toggle() }
                    .popover(isPresented: $showSettings, arrowEdge: .bottom) {
                        SettingsMenu().environment(model)
                    }
            }
            HStack(spacing: 0) {
                Text("NITRO").fontWeight(.semibold).foregroundStyle(Color(white: 0.9))
                Text("SENSE").fontWeight(.light).foregroundStyle(Color(white: 0.75))
            }
            .font(.system(size: 19))
            .tracking(5)
        }
        .frame(height: 40)
        .background { if !snapshotMode { WindowDragArea() } }
    }
}

struct HeaderIcon: View {
    let icon: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 17)).foregroundStyle(Color(white: 0.75))
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

// MARK: - Fan Control

// Auto and Max only, both fans together. Custom duty and the curve stay out on this board: see NitroEC.cpp.
let fanModeItems: [(mode: String, label: String, icon: String)] = [
    ("auto", "Auto", "fan"),
    ("max", "Max", "fan.fill"),
]

struct FanControlPanel: View {
    @Environment(NitroModel.self) private var model

    var body: some View {
        let s = model.snapshot
        let control = model.control
        NSPanel("Fan Control") {
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    ForEach(Array(fanModeItems.enumerated()), id: \.offset) { i, item in
                        if i > 0 { NSDivider() }
                        NSListItem(label: item.label, icon: item.icon, selected: model.currentFan == item.mode, enabled: control.canSetFan) {
                            model.setFan(item.mode)
                        }
                        .help(control.fanBlockedReason ?? unverifiedFirmwareHelp)
                    }
                }
                .frame(width: 170)
                .padding(.vertical, 6)

                Spacer()
                HStack(spacing: 22) {
                    FanSide(name: "CPU", temp: s.cpuTemp, alignment: .trailing)
                    FanDial(rpm: s.cpuRPM)
                    FanDial(rpm: s.gpuRPM)
                    FanSide(name: "GPU", temp: model.gpuTemp, alignment: .leading, tempHelp: model.gpu.tempNote)
                }
                Spacer()
            }
        } accessory: {
            HStack(spacing: 8) {
                Text(statusLine).font(.system(size: 11)).foregroundStyle(NS.dim).monospacedDigit()
                UnverifiedTag(help: unverifiedFirmwareHelp)
                NSButton(label: "Read firmware", icon: "arrow.clockwise", enabled: control.canRead) { model.readFirmware() }
                    .help(control.readBlockedReason ?? "Asks the firmware for the fan, mode, keyboard and charge limit state through nitrod. Each call is one SMI, so it never runs by itself until the first read has answered.")
            }
        }
    }

    private var statusLine: String {
        if let firmware = model.control.firmware, model.control.canSetFan {
            return "Firmware: \(firmware.fanSummary), read \(firmware.at.formatted(date: .omitted, time: .shortened))"
        }
        return model.control.fanBlockedReason ?? "State not read yet"
    }
}

struct FanSide: View {
    let name: String
    let temp: Int?
    let alignment: HorizontalAlignment
    var tempHelp: String?

    var body: some View {
        VStack(alignment: alignment, spacing: 6) {
            Text(name).font(.system(size: 14, weight: .medium)).foregroundStyle(NS.text)
            if let temp {
                Text("\(temp)°C").font(.system(size: 11)).foregroundStyle(tempColor(temp)).monospacedDigit()
            } else {
                Text("--°C").font(.system(size: 11)).foregroundStyle(NS.dim).help(tempHelp ?? "No source for this temperature")
            }
        }
        .frame(width: 130, alignment: alignment == .leading ? .leading : .trailing)
    }
}

// MARK: - Power Plan

let powerItems: [(mode: String, label: String, icon: String)] = [
    ("quiet", "Quiet", "leaf.fill"),
    ("balance", "Balance", "gauge.with.dots.needle.50percent"),
    ("performance", "Performance", "bolt.fill"),
]

struct PowerPlanPanel: View {
    @Environment(NitroModel.self) private var model

    var body: some View {
        let ac = model.snapshot.acPlugged
        let control = model.control
        NSPanel("Power Plan") {
            VStack(alignment: .leading, spacing: 0) {
                Text("Mode").font(.system(size: 11)).foregroundStyle(NS.dim).padding(.horizontal, 12).padding(.top, 6)
                HStack(spacing: 0) {
                    SourceTab(label: "AC", active: ac)
                    SourceTab(label: "Battery", active: !ac)
                }
                .padding(.horizontal, 8)
                .padding(.top, 4)
                .help("Current power source: an indicator, not a switch")
                VStack(spacing: 0) {
                    ForEach(Array(powerItems.enumerated()), id: \.offset) { i, item in
                        if i > 0 { NSDivider() }
                        NSListItem(label: item.label, icon: item.icon, selected: model.currentProfile == powerModes[item.mode], enabled: control.canSetMode) {
                            model.setPower(item.mode)
                        }
                        .help(control.modeBlockedReason ?? unverifiedFirmwareHelp)
                    }
                }
                .padding(.vertical, 4)
                Text(statusLine)
                    .font(.system(size: 10)).foregroundStyle(NS.dim)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12).padding(.bottom, 6)
            }
        } accessory: {
            UnverifiedTag(help: unverifiedFirmwareHelp)
        }
    }

    private var statusLine: String {
        guard let value = model.currentProfile else { return "Mode unknown (EC FANT \(model.snapshot.fant))" }
        var line: String
        if let firmware = model.control.firmware, firmware.profile != nil {
            line = "\(profileName(value)), firmware at \(firmware.at.formatted(date: .omitted, time: .shortened))"
            if let fant = profileValueFromFANT(model.snapshot.fant), fant != value { line += "; EC FANT says \(profileName(fant))" }
        } else {
            line = "\(profileName(value)), read from EC FANT"
        }
        if !powerModes.values.contains(value) { line += " (not offered here)" }
        if let reason = model.control.modeBlockedReason { line += ". To change it: \(reason)." }
        return line
    }
}

struct SourceTab: View {
    let label: String
    let active: Bool

    var body: some View {
        Text(label)
            .font(.system(size: 11))
            .foregroundStyle(active ? NS.text : NS.dim)
            .frame(maxWidth: .infinity)
            .frame(height: 22)
            .background(active ? Color(white: 0.26) : Color(white: 0.15))
            .overlay(Rectangle().stroke(Color(white: 0.28), lineWidth: 0.5))
    }
}

// MARK: - Monitoring

struct MonitoringPanel: View {
    @Environment(NitroModel.self) private var model

    var body: some View {
        let h = model.history
        NSPanel("Monitoring") {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    Text("Temperature (°C)").foregroundStyle(NS.red)
                    Text("/").foregroundStyle(NS.dim)
                    Text("Loading (%)").foregroundStyle(NS.orange)
                    Text("/").foregroundStyle(NS.dim)
                    Text("Power (W)").foregroundStyle(NS.yellow)
                    Text("/").foregroundStyle(NS.dim)
                    Text("Iris Xe (%)").foregroundStyle(NS.iris)
                    Spacer()
                    if let w = model.batteryPower {
                        Label(String(format: "On battery: %.1f W", w), systemImage: "battery.50percent")
                            .foregroundStyle(NS.yellow)
                            .help("Whole-machine draw from the battery")
                    }
                }
                .font(.system(size: 11))
                MonitorRow(name: "CPU", times: h.map(\.date), temps: h.map(\.cpuTemp), loads: h.map { $0.cpuLoad ?? 0 },
                           powers: h.map { $0.cpuPower ?? -1 },
                           temp: model.snapshot.cpuTemp, load: model.cpuLoad, power: model.cpuPower)
                    .help("CPU power = Intel package (cores + iGPU + system agent), from powermetrics")
                MonitorRow(name: "RTX 5050", times: h.map(\.date), temps: h.map { $0.gpuTemp ?? -1 }, loads: h.map { $0.rtxLoad ?? 0 }, powers: [],
                           temp: model.gpuTemp, load: model.gpu.rtxLoad, power: model.gpu.rtxPower,
                           secondLoads: h.map { $0.irisLoad ?? 0 }, secondLoad: model.gpu.irisLoad)
                    .help("Load read from the IORegistry: RTX 5050 from NVAccel, Iris Xe from IntelAccelerator. "
                          + (model.gpuTemp == nil ? "No temperature shown: \(model.gpu.tempNote ?? "no source")." : ""))
            }
            .padding(.horizontal, 12)
            .padding(.top, 6)
            .padding(.bottom, 10)
        }
    }
}

struct MonitorRow: View {
    let name: String
    let times: [Date]
    let temps: [Int]            // -1 = no sample
    let loads: [Int]
    let powers: [Double]
    let temp: Int?
    let load: Int?
    let power: Double?
    var secondLoads: [Int] = []  // the Iris Xe in the GPU row
    var secondLoad: Int?

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .trailing, spacing: 2) {
                Text(rangeText).font(.system(size: 10)).foregroundStyle(NS.dim).monospacedDigit()
                ZStack(alignment: .topLeading) {
                    HistoryGraph(temps: temps, loads: loads, powers: powers, times: times, secondLoads: secondLoads,
                                 loadLabel: secondLoads.isEmpty ? "Load" : "RTX")
                    Text(name).font(.system(size: 11, weight: .medium)).foregroundStyle(NS.text).padding(6)
                }
            }
            VStack(alignment: .trailing, spacing: 2) {
                if let temp {
                    Text("\(temp)°").font(.system(size: 22, weight: .light)).foregroundStyle(NS.red).monospacedDigit()
                }
                Text(load.map { "\($0) %" } ?? "-- %").font(.system(size: 15, weight: .light)).foregroundStyle(NS.orange).monospacedDigit()
                if !powers.isEmpty || power != nil {
                    Text(power.map { String(format: "%.1f W", $0) } ?? "-- W")
                        .font(.system(size: 15, weight: .light)).foregroundStyle(NS.yellow).monospacedDigit()
                }
                if !secondLoads.isEmpty {
                    Text(secondLoad.map { "Iris \($0) %" } ?? "Iris -- %")
                        .font(.system(size: 12, weight: .light)).foregroundStyle(NS.iris).monospacedDigit()
                }
            }
            .frame(width: 64, alignment: .trailing)
        }
    }

    private var rangeText: String {
        var parts: [String] = []
        let validTemps = temps.filter { $0 >= 0 }
        if !secondLoads.isEmpty {
            if let minT = validTemps.min(), let maxT = validTemps.max() { parts.append("Min : \(minT)°    Max : \(maxT)°") }
            parts.append("Peak : \(loads.max().map { "\($0) %" } ?? "--")    Iris : \(secondLoads.max().map { "\($0) %" } ?? "--")")
        } else {
            parts.append("Min : \(validTemps.min().map { "\($0)°" } ?? "--")    Max : \(validTemps.max().map { "\($0)°" } ?? "--")")
        }
        if let maxW = powers.filter({ $0 >= 0 }).max() { parts.append(String(format: "Peak : %.0f W", maxW)) }
        return parts.joined(separator: "    ")
    }
}

// Dark plot with faint red vertical grid; temperature line and load area, 0-100 scale.
struct HistoryGraph: View {
    let temps: [Int]
    let loads: [Int]
    var powers: [Double] = []   // -1 = no sample; scaled to max(60 W, peak)
    var times: [Date] = []
    var secondLoads: [Int] = [] // a second load drawn as a thin line: the Iris Xe in the GPU row
    var loadLabel = "Load"
    var capacity = 150
    @State private var hoverX: CGFloat?
    @Environment(\.snapshotMode) private var snapshotMode

    private var count: Int { max(temps.count, loads.count, powers.count, secondLoads.count) }

    private func x0(_ width: CGFloat) -> CGFloat { width - CGFloat(count - 1) * width / CGFloat(capacity - 1) }

    // Sample under the pointer (nil left of the first sample or with no data).
    private func hoverIndex(_ width: CGFloat) -> Int? {
        guard count > 0, let x = hoverX ?? (snapshotMode ? width * 0.72 : nil) else { return nil }
        let step = width / CGFloat(capacity - 1)
        let start = x0(width)
        guard x >= start - step / 2 else { return nil }
        return min(max(Int(((x - start) / step).rounded()), 0), count - 1)
    }

    var body: some View {
        GeometryReader { geo in
            let hover = hoverIndex(geo.size.width)
            Canvas { ctx, size in
                ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(NS.inset))
                var x: CGFloat = 0
                while x < size.width {
                    ctx.stroke(Path { $0.move(to: CGPoint(x: x, y: 0)); $0.addLine(to: CGPoint(x: x, y: size.height)) },
                               with: .color(NS.red.opacity(0.13)), lineWidth: 1)
                    x += 14
                }
                for frac in [0.25, 0.5, 0.75] {
                    let y = size.height * frac
                    ctx.stroke(Path { $0.move(to: CGPoint(x: 0, y: y)); $0.addLine(to: CGPoint(x: size.width, y: y)) },
                               with: .color(Color(white: 0.16)), lineWidth: 1)
                }
                func point(_ i: Int, _ v: Int, _ n: Int) -> CGPoint {
                    let step = size.width / CGFloat(capacity - 1)
                    let start = size.width - CGFloat(n - 1) * step
                    return CGPoint(x: start + CGFloat(i) * step, y: size.height * (1 - CGFloat(min(max(v, 0), 100)) / 100))
                }
                let powerScale = max(60, powers.filter { $0 >= 0 }.max() ?? 60)
                func powerPoint(_ i: Int) -> CGPoint { point(i, Int((powers[i] / powerScale * 100).rounded()), powers.count) }
                if loads.count > 1 {
                    var area = Path()
                    area.move(to: CGPoint(x: point(0, 0, loads.count).x, y: size.height))
                    for (i, v) in loads.enumerated() { area.addLine(to: point(i, v, loads.count)) }
                    area.addLine(to: CGPoint(x: size.width, y: size.height))
                    area.closeSubpath()
                    ctx.fill(area, with: .color(NS.orange.opacity(0.35)))
                }
                if powers.filter({ $0 >= 0 }).count > 1 {
                    var line = Path()
                    var started = false
                    for i in powers.indices where powers[i] >= 0 {
                        if started { line.addLine(to: powerPoint(i)) } else { line.move(to: powerPoint(i)); started = true }
                    }
                    ctx.stroke(line, with: .color(NS.yellow), style: StrokeStyle(lineWidth: 1.3, dash: [4, 2]))
                }
                if secondLoads.count > 1 {
                    var line = Path()
                    for (i, v) in secondLoads.enumerated() {
                        i == 0 ? line.move(to: point(i, v, secondLoads.count)) : line.addLine(to: point(i, v, secondLoads.count))
                    }
                    ctx.stroke(line, with: .color(NS.iris), lineWidth: 1.2)
                }
                if temps.filter({ $0 >= 0 }).count > 1 {
                    var line = Path()
                    var started = false
                    for (i, v) in temps.enumerated() where v >= 0 {
                        if started { line.addLine(to: point(i, v, temps.count)) } else { line.move(to: point(i, v, temps.count)); started = true }
                    }
                    ctx.stroke(line, with: .color(NS.red), lineWidth: 1.5)
                }
                if let hover {
                    let hx = point(hover, 0, count).x
                    ctx.stroke(Path { $0.move(to: CGPoint(x: hx, y: 0)); $0.addLine(to: CGPoint(x: hx, y: size.height)) },
                               with: .color(Color(white: 0.75)), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                    func dot(_ p: CGPoint, _ c: Color) {
                        ctx.fill(Path(ellipseIn: CGRect(x: p.x - 3.5, y: p.y - 3.5, width: 7, height: 7)), with: .color(c))
                    }
                    if hover < loads.count { dot(point(hover, loads[hover], loads.count), NS.orange) }
                    if hover < powers.count, powers[hover] >= 0 { dot(powerPoint(hover), NS.yellow) }
                    if hover < secondLoads.count { dot(point(hover, secondLoads[hover], secondLoads.count), NS.iris) }
                    if hover < temps.count, temps[hover] >= 0 { dot(point(hover, temps[hover], temps.count), NS.red) }
                }
            }
            .overlay(alignment: .topLeading) {
                if let hover {
                    let hx = x0(geo.size.width) + CGFloat(hover) * geo.size.width / CGFloat(capacity - 1)
                    let tipWidth: CGFloat = 118
                    tooltip(hover)
                        .frame(width: tipWidth, alignment: .leading)
                        .offset(x: hx + 10 + tipWidth > geo.size.width ? hx - tipWidth - 10 : hx + 10, y: 6)
                        .allowsHitTesting(false)
                }
            }
            .onContinuousHover { phase in
                switch phase {
                case .active(let p): hoverX = p.x
                case .ended: hoverX = nil
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 2))
        .overlay(RoundedRectangle(cornerRadius: 2).stroke(Color(white: 0.2), lineWidth: 1))
    }

    private func tooltip(_ i: Int) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if i < times.count {
                Text(times[i], format: .dateTime.hour().minute().second())
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(NS.dim)
            }
            if i < temps.count, temps[i] >= 0 { tipRow("Temp", "\(temps[i]) °C", NS.red) }
            if i < loads.count { tipRow(loadLabel, "\(loads[i]) %", NS.orange) }
            if i < secondLoads.count { tipRow("Iris Xe", "\(secondLoads[i]) %", NS.iris) }
            if i < powers.count { tipRow("Power", powers[i] >= 0 ? String(format: "%.1f W", powers[i]) : "--", NS.yellow) }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 4).fill(Color(white: 0.1).opacity(0.94)))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color(white: 0.35), lineWidth: 1))
    }

    private func tipRow(_ label: String, _ value: String, _ color: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label).foregroundStyle(Color(white: 0.75))
            Spacer(minLength: 4)
            Text(value).foregroundStyle(NS.text).monospacedDigit()
        }
        .font(.system(size: 11))
    }
}

// MARK: - Settings menu (gear)

enum LoginItem {
    // Bundled agent (Contents/Library/LaunchAgents) that starts the app with --background.
    static let agent = SMAppService.agent(plistName: "com.nitrosense.app.agent.plist")

    static var enabled: Bool { agent.status == .enabled }

    static func set(_ on: Bool) {
        do {
            if on { try agent.register() } else { try agent.unregister() }
        } catch {
            NSLog("NitroSense: login item \(on ? "register" : "unregister") failed: \(error)")
        }
    }

    // First launch from /Applications turns it on once; after that the user's choice sticks.
    static func configureOnFirstRun() {
        guard Bundle.main.bundlePath.hasPrefix("/Applications/") else { return }
        // Earlier builds used the main-app login item, which opened the window at login.
        if SMAppService.mainApp.status == .enabled {
            try? SMAppService.mainApp.unregister()
            set(true)
        }
        let key = "loginItemConfigured"
        if !UserDefaults.standard.bool(forKey: key) {
            set(true)
            UserDefaults.standard.set(true, forKey: key)
        }
    }
}

struct SettingsMenu: View {
    @Environment(NitroModel.self) private var model
    @State private var launchAtLogin = LoginItem.enabled

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Section("Power Settings") {
                InfoRow(label: "Battery charge limit (80%)", value: batteryLimitText,
                        note: "Set by hand: sudo nitroctl battery limit on|off")
                InfoRow(label: "USB charging when powered off", value: "not here",
                        note: "No firmware route verified on this board")
            }
            Divider().overlay(Color(white: 0.25))
            Section("Keyboard Settings") {
                InfoRow(label: "Backlight off after 30 seconds", value: "not here",
                        note: "No firmware route verified on this board")
            }
            Divider().overlay(Color(white: 0.25))
            Section("General") {
                SettingRow(label: "Launch at login", isOn: launchAtLogin) { on in
                    LoginItem.set(on)
                    launchAtLogin = LoginItem.enabled
                }
            }
            Divider().overlay(Color(white: 0.25))
            Section("Service") {
                HStack {
                    Text(model.connected ? "nitrod running" : "nitrod not reachable")
                        .foregroundStyle(model.connected ? NS.dim : NS.red)
                    Spacer()
                    NSButton(label: "Re-apply my settings", enabled: model.control.canRead && hasChoices) { model.reapply() }
                        .help(choicesHelp)
                }
                .font(.system(size: 12))
            }
        }
        .padding(12)
        .frame(width: 290)
        .preferredColorScheme(.dark)
    }

    private var batteryLimitText: String {
        guard let limit = model.control.firmware?.batteryLimit else { return "not read" }
        return limit ? "on" : "off"
    }

    private var hasChoices: Bool { !model.config.userFan.isEmpty || !model.config.userMode.isEmpty }

    private var choicesHelp: String {
        guard hasChoices else { return "Nothing to re-apply: nitrod re-applies only what you chose in this version, at start and after wake." }
        return "Fan: \(model.config.userFan.isEmpty ? "not chosen" : model.config.userFan). Power mode: \(model.config.userMode.isEmpty ? "not chosen" : model.config.userMode)."
    }

    struct Section<Content: View>: View {
        let title: String
        @ViewBuilder var content: Content
        init(_ title: String, @ViewBuilder content: () -> Content) {
            self.title = title
            self.content = content()
        }
        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.system(size: 12, weight: .bold)).foregroundStyle(NS.text)
                content
            }
        }
    }
}

// Something that cannot be changed from here: shown as text, with the reason, so it does not look clickable.
struct InfoRow: View {
    let label: String
    let value: String
    let note: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label).font(.system(size: 12)).foregroundStyle(NS.dim)
                Spacer()
                Text(value).font(.system(size: 12)).foregroundStyle(NS.dim)
            }
            Text(note).font(.system(size: 10)).foregroundStyle(NS.faint)
        }
    }
}

struct SettingRow: View {
    let label: String
    let isOn: Bool
    let action: (Bool) -> Void

    var body: some View {
        HStack {
            Text(label).font(.system(size: 12)).foregroundStyle(Color(white: 0.8))
            Spacer()
            HexToggle(isOn: isOn, action: action)
        }
    }
}

// MARK: - Menu bar

struct MenuBarLabel: View {
    let model: NitroModel

    var body: some View {
        if model.connected {
            Text(model.gpuTemp.map { "\(model.snapshot.cpuTemp)° · \($0)°" } ?? "\(model.snapshot.cpuTemp)°")
        } else {
            Image(systemName: "fan.slash")
        }
    }
}

struct MenuContent: View {
    @Environment(NitroModel.self) private var model

    var body: some View {
        let s = model.snapshot
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 0) {
                Text("NITRO").fontWeight(.semibold)
                Text("SENSE").fontWeight(.light).foregroundStyle(Color(white: 0.75))
            }
            .font(.system(size: 13)).tracking(3)
            .frame(maxWidth: .infinity)
            if let error = model.error {
                Text(error).font(.caption).foregroundStyle(NS.red)
            }
            HStack {
                MiniFan(name: "CPU", rpm: s.cpuRPM, temp: s.cpuTemp)
                Spacer()
                MiniFan(name: "GPU", rpm: s.gpuRPM, temp: model.gpuTemp)
            }
            .padding(.horizontal, 12)
            if let message = model.actionMessage {
                Text(message).font(.caption).foregroundStyle(model.actionIsWarning ? NS.orange : NS.red)
            }
            menuSection("Fan Control") {
                HStack(spacing: 10) {
                    ForEach(fanModeItems, id: \.mode) { item in
                        HexRadio(label: item.label, selected: model.currentFan == item.mode, enabled: model.control.canSetFan) {
                            model.setFan(item.mode)
                        }
                    }
                }
            }
            menuSection("Power Plan") {
                HStack(spacing: 10) {
                    ForEach(powerItems, id: \.mode) { item in
                        HexRadio(label: item.label, selected: model.currentProfile == powerModes[item.mode], enabled: model.control.canSetMode) {
                            model.setPower(item.mode)
                        }
                    }
                }
            }
            HStack(spacing: 6) {
                UnverifiedTag(help: unverifiedFirmwareHelp)
                Text(model.control.fanBlockedReason ?? model.control.modeBlockedReason ?? "Fan and power controls not yet proven on this board")
                    .font(.system(size: 10)).foregroundStyle(NS.dim)
            }
            Divider().overlay(Color(white: 0.25))
            HStack {
                NSButton(label: "Open NitroSense") { AppDelegate.shared?.showMainWindow() }
                Spacer()
                NSButton(label: "Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(12)
        .frame(width: 330)
        .background(NS.bg)
        .preferredColorScheme(.dark)
        .onAppear { model.requestTrustedRead() }
    }

    @ViewBuilder
    private func menuSection<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(NS.dim)
            content()
        }
    }
}

struct MiniFan: View {
    let name: String
    let rpm: Int
    let temp: Int?

    var body: some View {
        VStack(spacing: 4) {
            FanDial(rpm: rpm, size: 84)
            HStack(spacing: 6) {
                Text(name).font(.system(size: 11, weight: .medium)).foregroundStyle(NS.text)
                if let temp {
                    Text("\(temp)°C").font(.system(size: 11)).foregroundStyle(tempColor(temp)).monospacedDigit()
                } else {
                    Text("--°C").font(.system(size: 11)).foregroundStyle(NS.dim)
                }
            }
        }
    }
}

// MARK: - Snapshot support (ImageRenderer cannot draw ScrollView content)

// Written out by hand instead of SwiftUI's @Entry macro: the macro needs the SwiftUIMacros plugin that only
// Xcode ships, and this fork is built with the Command Line Tools alone.
private struct SnapshotModeKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var snapshotMode: Bool {
        get { self[SnapshotModeKey.self] }
        set { self[SnapshotModeKey.self] = newValue }
    }
}
