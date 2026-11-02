// Main window laid out like Acer NitroSense 3 (AN515-57): header bar, Fan Control panel with two fan dials, Power Plan and
// Monitoring panels below. The gear opens a settings menu. On the ANV15-52
// only what can work is shown: Auto, Max and Custom, the three power modes, and the settings the firmware answers for.

import IOKit.ps
import ServiceManagement
import SwiftUI

func tempColor(_ t: Int) -> Color {
    t >= 90 ? .red : t >= 75 ? NS.orange : t >= 60 ? .yellow : .green
}

enum Overlay { case none, curve }

let powerModeHelp = "Goes through the firmware's own mode route, TUGM and then _Q30, and is read back from EC FANT. Quiet can stop the fans when idle."
let fanFirmwareHelp = "Goes through the firmware's gaming WMI and is read back. On this board Max speeds the fans up."

// The Iris Xe idles at 0.02 W: two decimals under one watt, or it would read as nothing.
func wattsText(_ watts: Double) -> String { String(format: watts < 1 ? "%.2f W" : "%.1f W", watts) }

func fanSummaryText(_ firmware: FirmwareReading) -> String {
    func name(_ v: Int?) -> String { v.map { L(fanBehaviorName($0)) } ?? L("not readable") }
    return firmware.fanCPU == firmware.fanGPU ? L("both %@", name(firmware.fanCPU)) : L("CPU %@, GPU %@", name(firmware.fanCPU), name(firmware.fanGPU))
}

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
                FanControlPanel(overlay: $overlay).frame(height: 200)
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
                CurvePanel { overlay = .none }
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
                HeaderIcon(icon: "gearshape.fill", help: L("Settings")) { showSettings.toggle() }
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

// Both fans together. A manual duty stays where it is put, and nitrod goes back to Auto if it runs hot; on the curve each fan follows
// its own temperature.
let fanModeItems: [(mode: String, label: String, icon: String)] = [
    ("auto", "Auto", "fan"),
    ("max", "Max", "fan.fill"),
    ("custom", "Custom", "slider.horizontal.3"),
    ("curve", "Curve", "chart.xyaxis.line"),
]

struct FanDutySliders: View {
    @Environment(NitroModel.self) private var model
    @State private var cpu = 50.0
    @State private var gpu = 50.0

    private func row(_ name: String, _ value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(name)
                Spacer()
                Text("\(Int(value.wrappedValue)) %").monospacedDigit()
            }
            .font(.system(size: 11)).foregroundStyle(NS.dim)
            Slider(value: value, in: Double(GamingWMI.fanMinPercent)...100, step: 5) { editing in
                if !editing { model.setFanDuty(cpu: Int(cpu), gpu: Int(gpu)) }
            }
            .tint(NS.red)
            .disabled(!model.control.canSetFan)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            row("CPU", $cpu)
            row("GPU", $gpu)
            Text("Back to Auto if the CPU reaches 95 °C or the RTX 87 °C. 20 % is about 3300 RPM, Auto at idle 2200.")
                .font(.system(size: 10)).foregroundStyle(NS.dim)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .onAppear {
            cpu = Double(model.config.userFanCPU)
            gpu = Double(model.config.userFanGPU)
        }
    }
}

// The curve in use, small, beside the dials; the editor is an overlay.
struct FanCurvePreview: View {
    @Environment(NitroModel.self) private var model
    @Binding var overlay: Overlay

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            CurveGraph(curve: model.config.fan.curve, cpuTemp: model.snapshot.cpuTemp, gpuTemp: model.gpuTemp, compact: true)
                .frame(height: 118)
            NSButton(label: "Edit curve", icon: "pencil") { overlay = .curve }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }
}

struct FanControlPanel: View {
    @Environment(NitroModel.self) private var model
    @Binding var overlay: Overlay

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
                        .help(control.fanBlockedReason ?? L(fanFirmwareHelp))
                    }
                }
                .frame(width: 150)
                .padding(.vertical, 6)

                if model.currentFan == "custom" { FanDutySliders().frame(width: 190) }
                if model.currentFan == "curve" { FanCurvePreview(overlay: $overlay).frame(width: 190) }

                Spacer(minLength: 0)
                HStack(spacing: 14) {
                    FanSide(name: "CPU", temp: s.fromEC ? s.cpuTemp : nil, alignment: .trailing, tempHelp: L("nitrod is not reachable"))
                    FanDial(rpm: s.fromEC ? s.cpuRPM : nil)
                    FanDial(rpm: s.fromEC ? s.gpuRPM : nil)
                    FanSide(name: "GPU", temp: model.gpuTemp, alignment: .leading, tempHelp: model.gpuProblem)
                }
                Spacer(minLength: 0)
            }
        } accessory: {
            HStack(spacing: 8) {
                Text(statusLine).font(.system(size: 11)).foregroundStyle(NS.dim).monospacedDigit()
                NSButton(label: "Read firmware", icon: "arrow.clockwise", enabled: control.canRead) { model.readFirmware() }
                    .help(control.readBlockedReason ?? L("Asks the firmware for the fan, mode, keyboard and charge limit state through nitrod. Each call is one SMI, so it never runs by itself until the first read has answered."))
            }
        }
    }

    private var statusLine: String {
        if let firmware = model.control.firmware, model.control.canSetFan {
            return L("Firmware: %@, read %@", fanSummaryText(firmware), firmware.at.formatted(date: .omitted, time: .shortened))
        }
        return model.control.fanBlockedReason ?? L("State not read yet")
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
                Text("--°C").font(.system(size: 11)).foregroundStyle(NS.dim).help(tempHelp ?? L("No source for this temperature"))
            }
        }
        .frame(width: 66, alignment: alignment == .leading ? .leading : .trailing)
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
                .help(L("Current power source: an indicator, not a switch"))
                VStack(spacing: 0) {
                    ForEach(Array(powerItems.enumerated()), id: \.offset) { i, item in
                        if i > 0 { NSDivider() }
                        NSListItem(label: item.label, icon: item.icon, selected: model.currentProfile == powerModes[item.mode], enabled: control.canSetMode) {
                            model.setPower(item.mode)
                        }
                        .help(control.modeBlockedReason ?? L(powerModeHelp))
                    }
                }
                .padding(.vertical, 4)
                Text(statusLine)
                    .font(.system(size: 10)).foregroundStyle(NS.dim)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12).padding(.bottom, 6)
            }
        }
    }

    private var statusLine: String {
        guard let value = model.currentProfile else {
            let why = model.snapshot.fromEC ? "EC FANT \(model.snapshot.fant)" : L("no EC data")
            return L("Mode unknown (%@)", why) + (model.control.modeBlockedReason.map { L(". To change it: %@.", $0) } ?? "")
        }
        var line: String
        if let firmware = model.control.firmware, firmware.profile != nil {
            line = L("%@, firmware at %@", L(profileName(value)), firmware.at.formatted(date: .omitted, time: .shortened))
            if let fant = profileValueFromFANT(model.snapshot.fant), fant != value { line += L("; EC FANT says %@", L(profileName(fant))) }
        } else {
            line = L("%@, read from EC FANT", L(profileName(value)))
        }
        if !powerModes.values.contains(value) { line += L(" (not offered here)") }
        if let reason = model.control.modeBlockedReason { line += L(". To change it: %@.", reason) }
        return line
    }
}

struct SourceTab: View {
    let label: String
    let active: Bool

    var body: some View {
        Text(L(label))
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
                    Spacer()
                    if let w = model.batteryPower {
                        Label(L("On battery: %.1f W", w), systemImage: "battery.50percent")
                            .foregroundStyle(NS.yellow)
                            .help(L("Whole-machine draw from the battery"))
                    }
                }
                .font(.system(size: 11))
                MonitorRow(name: "CPU", times: h.map(\.date), temps: h.map(\.cpuTemp), loads: h.map { $0.cpuLoad ?? 0 },
                           powers: h.map { $0.cpuPower ?? -1 },
                           temp: model.snapshot.fromEC ? model.snapshot.cpuTemp : nil, load: model.cpuLoad, power: model.cpuPower)
                    .help(L("CPU power = Intel package (cores + iGPU + system agent), from powermetrics"))
                MonitorRow(name: "RTX 5050", times: h.map(\.date), temps: h.map { $0.gpuTemp ?? -1 }, loads: h.map { $0.rtxLoad ?? -1 },
                           powers: h.map { $0.rtxPower ?? -1 },
                           temp: model.gpuTemp, load: model.rtxLoad, power: model.gpuPower, detail: model.gpuDetail)
                    .help(L("Load from the IORegistry (NVAccel). Temperature, power and clock from RM's shared data page, every 5 s with this window open, every minute otherwise.")
                          + (model.gpuTemp == nil ? " " + L("No RTX numbers now: %@.", model.gpuProblem) : ""))
                MonitorRow(name: "Iris Xe", times: h.map(\.date), temps: h.map { $0.igpuTemp ?? -1 }, loads: h.map { $0.igpuLoad ?? -1 },
                           powers: h.map { $0.igpuPower ?? -1 }, temp: model.igpuTemp, load: model.igpuLoad, power: model.igpuPower, powerScale: 20)
                    .help(L("Load: share of time the Iris Xe is active, from powermetrics (GPU Active). Temperature and power: the CPU's own registers for its graphics plane. This power is also inside the CPU figure."))
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
    let loads: [Int]            // same
    let powers: [Double]
    let temp: Int?
    let load: Int?
    let power: Double?
    var detail: String?
    var powerScale = 60.0

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .trailing, spacing: 2) {
                Text(rangeText.isEmpty ? " " : rangeText).font(.system(size: 10)).foregroundStyle(NS.dim).monospacedDigit()
                ZStack(alignment: .topLeading) {
                    HistoryGraph(temps: temps, loads: loads, powers: powers, times: times, powerScaleMin: powerScale)
                    Text(name).font(.system(size: 11, weight: .medium)).foregroundStyle(NS.text).padding(6)
                }
            }
            VStack(alignment: .trailing, spacing: 2) {
                if let temp {
                    Text("\(temp)°").font(.system(size: 22, weight: .light)).foregroundStyle(NS.red).monospacedDigit()
                }
                // A figure that has never arrived takes no place; one that stopped arriving shows as --.
                if load != nil || loads.contains(where: { $0 >= 0 }) {
                    Text(load.map { "\($0) %" } ?? "-- %").font(.system(size: 15, weight: .light)).foregroundStyle(NS.orange).monospacedDigit()
                }
                if power != nil || powers.contains(where: { $0 >= 0 }) {
                    Text(power.map(wattsText) ?? "-- W")
                        .font(.system(size: 15, weight: .light)).foregroundStyle(NS.yellow).monospacedDigit()
                }
                if let detail {
                    Text(detail).font(.system(size: 10)).foregroundStyle(NS.dim).monospacedDigit().fixedSize()
                }
            }
            .frame(width: 64, alignment: .trailing)
        }
    }

    private var rangeText: String {
        let validTemps = temps.filter { $0 >= 0 }
        var parts: [String] = []
        if let low = validTemps.min(), let high = validTemps.max() { parts.append("Min : \(low)°    Max : \(high)°") }
        if let maxW = powers.filter({ $0 >= 0 }).max() { parts.append(L("Peak : %.0f W", maxW)) }
        return parts.joined(separator: "    ")
    }
}

// Dark plot with faint red vertical grid; temperature line and load area, 0-100 scale.
struct HistoryGraph: View {
    let temps: [Int]
    let loads: [Int]
    var powers: [Double] = []   // -1 = no sample; scaled to max(60 W, peak)
    var times: [Date] = []
    var powerScaleMin = 60.0
    var capacity = 150
    @State private var hoverX: CGFloat?
    @Environment(\.snapshotMode) private var snapshotMode

    private var count: Int { max(temps.count, loads.count, powers.count) }

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
                let powerScale = max(powerScaleMin, powers.filter { $0 >= 0 }.max() ?? powerScaleMin)
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
                    if hover < loads.count, loads[hover] >= 0 { dot(point(hover, loads[hover], loads.count), NS.orange) }
                    if hover < powers.count, powers[hover] >= 0 { dot(powerPoint(hover), NS.yellow) }
                    if hover < temps.count, temps[hover] >= 0 { dot(point(hover, temps[hover], temps.count), NS.red) }
                }
            }
            .overlay(alignment: .topLeading) {
                if let hover {
                    let hx = x0(geo.size.width) + CGFloat(hover) * geo.size.width / CGFloat(capacity - 1)
                    let tipWidth: CGFloat = 128
                    tooltip(hover)
                        .frame(width: tipWidth, alignment: .leading)
                        .offset(x: hx + 10 + tipWidth > geo.size.width ? hx - tipWidth - 10 : hx + 10, y: 1)
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
        VStack(alignment: .leading, spacing: 0) {   // under 54 points high: the plots are that low with three rows
            if i < times.count {
                Text(times[i], format: .dateTime.hour().minute().second())
                    .font(.system(size: 9, weight: .medium)).foregroundStyle(NS.dim)
            }
            if i < temps.count, temps[i] >= 0 { tipRow(L("Temp"), "\(temps[i]) °C", NS.red) }
            if i < loads.count, loads[i] >= 0 { tipRow(L("Load"), "\(loads[i]) %", NS.orange) }
            if i < powers.count, powers[i] >= 0 { tipRow(L("Power"), wattsText(powers[i]), NS.yellow) }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
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
        .font(.system(size: 10))
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
                BatteryLimitRow()
                if let usb = model.control.firmware?.usbCharge {
                    HStack {
                        Text("USB power when off").font(.system(size: 12))
                        Spacer()
                        Picker("", selection: Binding(get: { usb }, set: { model.setUSBCharge($0) })) {
                            Text("Off").tag(0)
                            Text("Down to 10 %").tag(10)
                            Text("Down to 20 %").tag(20)
                            Text("Down to 30 %").tag(30)
                        }
                        .labelsHidden()
                        .frame(width: 130)
                    }
                    .help(L("USB ports stay powered with the machine off, until the battery falls to this level"))
                }
            }
            Divider().overlay(Color(white: 0.25))
            // A setting the firmware does not answer for is not shown at all.
            if let timeout = model.control.firmware?.kbTimeout {
                Section("Keyboard Settings") {
                    SettingRow(label: "Backlight off after 30 seconds", isOn: timeout) { model.setKBTimeout($0) }
                }
                Divider().overlay(Color(white: 0.25))
            }
            Section("General") {
                SettingRow(label: "Launch at login", isOn: launchAtLogin) { on in
                    LoginItem.set(on)
                    launchAtLogin = LoginItem.enabled
                }
            }
            Divider().overlay(Color(white: 0.25))
            Section("Service") {
                HStack {
                    Text(L(model.connected ? "nitrod running" : "nitrod not reachable"))
                        .foregroundStyle(model.connected ? NS.dim : NS.red)
                    Spacer()
                    NSButton(label: "Re-apply my settings", enabled: model.control.canRead && hasChoices) { model.reapply() }
                        .help(choicesHelp)
                }
                .font(.system(size: 12))
            }
        }
        .padding(12)
        .frame(width: 320)
        .preferredColorScheme(.dark)
        .onAppear {
            model.requestBatteryRead()
            if model.control.firmware == nil, model.control.canRead { model.readFirmware() }
        }
    }

    private var hasChoices: Bool { !model.config.userFan.isEmpty || !model.config.userMode.isEmpty }

    private var choicesHelp: String {
        guard hasChoices else { return L("Nothing to re-apply: nitrod re-applies only what you chose in this version, at start and after wake.") }
        return L("Fan: %@. Power mode: %@.", model.config.userFan.isEmpty ? L("not chosen") : model.config.userFan, model.config.userMode.isEmpty ? L("not chosen") : model.config.userMode)
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
                Text(L(title)).font(.system(size: 12, weight: .bold)).foregroundStyle(NS.text)
                content
            }
        }
    }
}

// The firmware's 80 % charge limit. The switch shows what the firmware last answered, and only after it answered; a click
// asks nitrod to write it and read it back. The result stays with the firmware across reboots: nothing re-applies it.
struct BatteryLimitRow: View {
    @Environment(NitroModel.self) private var model

    var body: some View {
        let control = model.control
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Battery charge limit (80%)")
                    .font(.system(size: 12))
                    .foregroundStyle(control.canSetBatteryLimit ? Color(white: 0.8) : NS.dim)
                Spacer()
                if let limit = control.batteryLimit, control.canSetBatteryLimit {
                    HexToggle(isOn: limit.on) { model.setBatteryLimit($0) }
                }
            }
            Text(note).font(.system(size: 10)).foregroundStyle(NS.dim)
            if let message = model.actionMessage {
                Text(message)
                    .font(.system(size: 10))
                    .foregroundStyle(model.actionIsWarning ? NS.orange : NS.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var note: String {
        if let limit = model.control.batteryLimit {
            return L("Firmware: %@, read %@", L(limit.on ? "on" : "off"), limit.at.formatted(date: .omitted, time: .shortened))
        }
        return model.control.batteryBlockedReason ?? L("not read")
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
            Text(L(label)).font(.system(size: 12)).foregroundStyle(Color(white: 0.8))
            Spacer()
            HexToggle(isOn: isOn, action: action)
        }
    }
}

// MARK: - Menu bar

struct MenuBarLabel: View {
    let model: NitroModel

    var body: some View {
        if model.connected, model.snapshot.fromEC {
            Text(model.gpuTemp.map { "\(model.snapshot.cpuTemp)° · \($0)°" } ?? "\(model.snapshot.cpuTemp)°")
        } else {
            Image(systemName: "fan.slash")
        }
    }
}

struct MenuContent: View {
    @Environment(NitroModel.self) private var model
    @Environment(\.dismiss) private var dismiss

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
                MiniFan(name: "CPU", rpm: s.fromEC ? s.cpuRPM : nil, temp: s.fromEC ? s.cpuTemp : nil)
                Spacer()
                MiniFan(name: "GPU", rpm: s.fromEC ? s.gpuRPM : nil, temp: model.gpuTemp)
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
            if let reason = model.control.fanBlockedReason ?? model.control.modeBlockedReason {
                Text(reason).font(.system(size: 10)).foregroundStyle(NS.dim)
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
        .onAppear {
            model.requestTrustedRead()
            model.sampleRTXNow()
        }
        .onReceive(NotificationCenter.default.publisher(for: AppDelegate.closeMenuNotification)) { _ in dismiss() }
    }

    @ViewBuilder
    private func menuSection<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L(title)).font(.system(size: 11, weight: .medium)).foregroundStyle(NS.dim)
            content()
        }
    }
}

struct MiniFan: View {
    let name: String
    let rpm: Int?
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
