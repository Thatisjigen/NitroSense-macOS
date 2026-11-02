// Overlay dialogs: the keyboard backlight, read only on this model, and the fan curve editor, which nothing opens on this
// branch (no manual duty on this board yet).

import SwiftUI

struct DialogFrame<Content: View>: View {
    let title: String
    let close: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title).font(.system(size: 14, weight: .medium)).foregroundStyle(NS.text)
                Spacer()
                Button(action: close) {
                    Image(systemName: "xmark").font(.system(size: 15, weight: .light)).foregroundStyle(Color(white: 0.75))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
            }
            content
        }
        .padding(16)
        .frame(width: 680)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(LinearGradient(colors: [Color(white: 0.15), Color(white: 0.1)], startPoint: .top, endPoint: .bottom))
        )
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(white: 0.32), lineWidth: 1))
        .overlay(alignment: .top) {
            Capsule().fill(Color(white: 0.35)).frame(width: 120, height: 3).offset(y: -1)
        }
        .shadow(color: .black.opacity(0.6), radius: 20)
    }
}

// MARK: - Keyboard backlight (ANV15-52: single colour)

// This keyboard has one colour: on, off and variable brightness, driven by the Fn keys through the EC. So there are no
// zones, colours or effects here, and no control either: the firmware declares SetGamingKBBacklight (WMBH 0x14), but
// nothing shows what it does on a single-colour keyboard, so only what can be read is shown.
struct KeyboardPanel: View {
    @Environment(NitroModel.self) private var model
    let close: () -> Void

    var body: some View {
        let on = model.snapshot.fromEC && model.snapshot.keyboardBit
        DialogFrame(title: "Keyboard  Backlight", close: close) {
            Text("This keyboard is single-colour: on, off and variable brightness. The Fn keys drive it; this panel only reads.")
                .font(.system(size: 12)).foregroundStyle(Color(white: 0.8))
            KeyboardDrawing(colors: Array(repeating: Color(white: 0.95), count: 4), brightness: on ? 100 : 0)
                .frame(height: 190)
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color(white: 0.07)))
            VStack(alignment: .leading, spacing: 8) {
                row("Backlight bit", model.snapshot.fromEC ? (on ? "On" : "Off") : "unknown", "KBBL, EC 0x48 bit 0") {
                    UnverifiedTag(help: "The firmware reports this bit with the keyboard-light hotkey event, but it has never been seen at 0: check that it follows the Fn key.")
                }
                row("Brightness level", "not exposed", "no EC byte identified yet: 'nitroctl ecdiff' finds it when the Fn key is pressed") { EmptyView() }
                row("Firmware report", firmwareText, "GetGamingKBBacklight, WMBH 0x15, read through nitrod") {
                    NSButton(label: "Read firmware", icon: "arrow.clockwise", enabled: model.control.canRead) { model.readFirmware() }
                        .help(model.control.readBlockedReason ?? "Asks the firmware through nitrod: one SMI per call")
                }
            }
        }
    }

    private var firmwareText: String {
        guard let firmware = model.control.firmware else { return model.control.readBlockedReason ?? "not read yet" }
        guard let k = firmware.keyboard, k.count >= 4 else { return "no answer" }
        return "brightness byte \(k[3]), mode \(k[1])   raw \(k.prefix(9).map { String(format: "%02X", $0) }.joined(separator: " "))"
    }

    private func row<Tag: View>(_ label: String, _ value: String, _ note: String, @ViewBuilder tag: () -> Tag) -> some View {
        HStack(spacing: 10) {
            Text(label).font(.system(size: 12)).foregroundStyle(NS.dim).frame(width: 120, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(value).font(.system(size: 12)).foregroundStyle(NS.text).monospacedDigit()
                Text(note).font(.system(size: 10)).foregroundStyle(NS.dim)
            }
            Spacer()
            tag()
        }
    }
}

// MARK: - Keyboard drawing (15.6" layout with numpad, 4 zones left to right)

struct KeyRect {
    let x: Double, y: Double, w: Double, h: Double
}

let keyboardLayout: [KeyRect] = {
    var keys: [KeyRect] = []
    // Main block, 15 units wide. Row heights: function row 0.65, others 1.
    let rows: [(y: Double, h: Double, widths: [Double])] = [
        (0, 0.65, Array(repeating: 1, count: 15)),
        (0.8, 1, Array(repeating: 1, count: 13) + [2]),
        (1.8, 1, [1.5] + Array(repeating: 1, count: 12) + [1.5]),
        (2.8, 1, [1.75] + Array(repeating: 1, count: 11) + [2.25]),
        (3.8, 1, [2.25] + Array(repeating: 1, count: 10) + [1.75, 1]),
        (4.8, 1, [1, 1, 1, 1, 5, 1, 1, 1, 1, 1, 1]),
    ]
    for row in rows {
        var x = 0.0
        for w in row.widths {
            keys.append(KeyRect(x: x, y: row.y, w: w, h: row.h))
            x += w
        }
    }
    // Numpad, 4 units, starting at 15.3.
    let n = 15.3
    for i in 0..<4 { keys.append(KeyRect(x: n + Double(i), y: 0, w: 1, h: 0.65)) }
    for i in 0..<4 { keys.append(KeyRect(x: n + Double(i), y: 0.8, w: 1, h: 1)) }
    for row in [1.8, 2.8] { for i in 0..<3 { keys.append(KeyRect(x: n + Double(i), y: row, w: 1, h: 1)) } }
    keys.append(KeyRect(x: n + 3, y: 1.8, w: 1, h: 2))         // +
    for i in 0..<3 { keys.append(KeyRect(x: n + Double(i), y: 3.8, w: 1, h: 1)) }
    keys.append(KeyRect(x: n, y: 4.8, w: 2, h: 1))             // 0
    keys.append(KeyRect(x: n + 2, y: 4.8, w: 1, h: 1))         // .
    keys.append(KeyRect(x: n + 3, y: 3.8, w: 1, h: 2))         // Enter
    return keys
}()

func zoneIndex(_ k: KeyRect) -> Int {
    let cx = k.x + k.w / 2
    return cx >= 15.15 ? 3 : min(Int(cx / 5), 2)
}

struct KeyboardDrawing: View {
    let colors: [Color]
    let brightness: Int
    var badge: String?

    var body: some View {
        Canvas { ctx, size in
            let unitsW = 19.3, unitsH = 5.8
            let u = min(size.width / unitsW, size.height / unitsH)
            let ox = (size.width - unitsW * u) / 2, oy = (size.height - unitsH * u) / 2
            let level = 0.2 + 0.8 * Double(brightness) / 100
            for k in keyboardLayout {
                let r = CGRect(x: ox + k.x * u + u * 0.07, y: oy + k.y * u + u * 0.07,
                               width: k.w * u - u * 0.14, height: k.h * u - u * 0.14)
                let shape = Path(roundedRect: r, cornerRadius: u * 0.14)
                let color = colors[zoneIndex(k)]
                ctx.fill(shape, with: .color(Color(white: 0.05)))
                ctx.fill(shape, with: .color(color.opacity(0.07 * level)))
                ctx.stroke(shape, with: .color(color.opacity(level)), lineWidth: max(1.2, u * 0.06))
            }
        }
        .overlay(alignment: .topTrailing) {
            if let badge {
                Text(badge).font(.system(size: 11, weight: .medium)).foregroundStyle(NS.text)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(Color(white: 0.2)))
            }
        }
    }
}

// MARK: - Fan curve editor

struct CurvePanel: View {
    @Environment(NitroModel.self) private var model
    let close: () -> Void
    @State private var curve: [FanCurvePoint] = []
    @State private var error: String?

    var body: some View {
        let fan = model.config.fan
        DialogFrame(title: "Fan Curve", close: close) {
            Text("Used when Fan Control is set to Curve. Fan speed (%) by temperature (°C); fans go to max at \(fan.failsafeTemp) °C regardless.")
                .font(.system(size: 11)).foregroundStyle(NS.dim)
            HStack(alignment: .top, spacing: 14) {
                CurveGraph(curve: curve, cpuTemp: model.snapshot.cpuTemp, gpuTemp: fan.curveGPU ? model.gpuTemp : nil)
                    .frame(height: 220)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(curve.indices, id: \.self) { i in
                        HStack(spacing: 6) {
                            StepField(text: "\(curve[i].temp)°", minus: { curve[i].temp = max(30, curve[i].temp - 1) },
                                      plus: { curve[i].temp = min(100, curve[i].temp + 1) })
                            StepField(text: "\(curve[i].percent)%", minus: { curve[i].percent = max(20, curve[i].percent - 5) },
                                      plus: { curve[i].percent = min(100, curve[i].percent + 5) })
                            Button { curve.remove(at: i) } label: {
                                Image(systemName: "xmark").font(.system(size: 10)).foregroundStyle(curve.count > 2 ? NS.dim : NS.faint)
                                    .frame(width: 24, height: 26)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(curve.count <= 2)
                        }
                    }
                    NSButton(label: "Add point", icon: "plus") {
                        let last = curve.last ?? FanCurvePoint(temp: 50, percent: 30)
                        curve.append(FanCurvePoint(temp: min(last.temp + 5, 100), percent: last.percent))
                    }
                    .disabled(curve.count >= 8)
                }
                .frame(width: 210, alignment: .leading)
            }
            if let error {
                Text(error).font(.system(size: 11)).foregroundStyle(NS.red)
            }
            HStack {
                SettingRow(label: "Also drive the GPU fan", isOn: fan.curveGPU) {
                    model.config.fan.curveGPU = $0
                }
                .frame(width: 250)
                Text("(off: GPU fan stays on Auto, quieter)").font(.system(size: 11)).foregroundStyle(NS.dim)
                Spacer()
                NSButton(label: "Revert") { curve = fan.curve }
                NSButton(label: "Save", icon: "checkmark") { save() }
            }
        }
        .onAppear { curve = fan.curve }
    }

    private func save() {
        var test = model.config
        test.fan.curve = curve
        do {
            try test.validate()
            error = nil
            model.config.fan.curve = curve
        } catch {
            self.error = "\(error)"
        }
    }
}

struct StepField: View {
    let text: String
    let minus: () -> Void
    let plus: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            StepButton(icon: "minus", action: minus)
            Text(text).frame(width: 40).monospacedDigit()
            StepButton(icon: "plus", action: plus)
        }
        .font(.system(size: 11))
        .foregroundStyle(NS.text)
        .background(RoundedRectangle(cornerRadius: 3).fill(Color(white: 0.15)))
        .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color(white: 0.28), lineWidth: 1))
    }
}

// Whole 26×26 square is clickable (a plain button only hits the glyph's pixels otherwise).
struct StepButton: View {
    let icon: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(StepPressStyle())
    }
}

struct StepPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? NS.red.opacity(0.35) : Color.clear)
            .foregroundStyle(configuration.isPressed ? Color.white : NS.text)
    }
}

struct CurveGraph: View {
    let curve: [FanCurvePoint]
    let cpuTemp: Int
    let gpuTemp: Int?

    var body: some View {
        Canvas { ctx, size in
            let pad: CGFloat = 26
            let plot = CGRect(x: pad, y: 6, width: size.width - pad - 6, height: size.height - pad - 6)
            ctx.fill(Path(plot), with: .color(NS.inset))
            func pt(_ t: Int, _ p: Int) -> CGPoint {
                CGPoint(x: plot.minX + plot.width * CGFloat(t - 30) / 70, y: plot.maxY - plot.height * CGFloat(p) / 100)
            }
            for t in stride(from: 30, through: 100, by: 10) {
                let x = pt(t, 0).x
                ctx.stroke(Path { $0.move(to: CGPoint(x: x, y: plot.minY)); $0.addLine(to: CGPoint(x: x, y: plot.maxY)) },
                           with: .color(NS.red.opacity(0.12)), lineWidth: 1)
                ctx.draw(Text("\(t)°").font(.system(size: 9)).foregroundStyle(NS.dim), at: CGPoint(x: x, y: plot.maxY + 10))
            }
            for p in stride(from: 0, through: 100, by: 25) {
                let y = pt(30, p).y
                ctx.stroke(Path { $0.move(to: CGPoint(x: plot.minX, y: y)); $0.addLine(to: CGPoint(x: plot.maxX, y: y)) },
                           with: .color(Color(white: 0.17)), lineWidth: 1)
                ctx.draw(Text("\(p)%").font(.system(size: 9)).foregroundStyle(NS.dim), at: CGPoint(x: pad / 2, y: y))
            }
            func marker(_ t: Int, _ label: String, _ color: Color) {
                let x = pt(min(max(t, 30), 100), 0).x
                ctx.stroke(Path { $0.move(to: CGPoint(x: x, y: plot.minY)); $0.addLine(to: CGPoint(x: x, y: plot.maxY)) },
                           with: .color(color), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                ctx.draw(Text(label).font(.system(size: 9)).foregroundStyle(color), at: CGPoint(x: x + 4, y: plot.minY + 8), anchor: .leading)
            }
            marker(cpuTemp, "CPU \(cpuTemp)°", NS.orange)
            if let gpuTemp { marker(gpuTemp, "GPU \(gpuTemp)°", .purple) }
            guard curve.count > 1 else { return }
            var line = Path()
            line.move(to: CGPoint(x: plot.minX, y: pt(30, curve[0].percent).y))
            for p in curve { line.addLine(to: pt(p.temp, p.percent)) }
            line.addLine(to: CGPoint(x: plot.maxX, y: pt(100, curve.last!.percent).y))
            ctx.stroke(line, with: .color(NS.red), lineWidth: 2)
            for p in curve {
                let c = pt(p.temp, p.percent)
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - 4, y: c.y - 4, width: 8, height: 8)), with: .color(NS.red))
            }
        }
    }
}
