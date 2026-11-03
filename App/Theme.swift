// NitroSense look: near-black background, dark panels with slanted header tabs,
// red accents, hexagon toggles/radios, red sliders and bladed fan dials.

import SwiftUI

enum NS {
    static let red = Color(red: 0.91, green: 0.14, blue: 0.11)
    static let redDark = Color(red: 0.45, green: 0.05, blue: 0.04)
    static let orange = Color(red: 1.0, green: 0.45, blue: 0.16)
    static let yellow = Color(red: 1.0, green: 0.82, blue: 0.25)
    static let bg = Color(white: 0.07)
    static let panel = Color(white: 0.115)
    static let panelBorder = Color(white: 0.24)
    static let inset = Color(white: 0.085)
    static let text = Color(white: 0.92)
    static let dim = Color(white: 0.52)
    static let faint = Color(white: 0.3)
    static let tab = LinearGradient(colors: [Color(white: 0.33), Color(white: 0.2)], startPoint: .top, endPoint: .bottom)
}

// MARK: - Shapes

// Header tab: rectangle whose right edge slants down-right, like NitroSense panel titles.
struct TabShape: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.minY + 4))
        p.addQuadCurve(to: CGPoint(x: r.minX + 4, y: r.minY), control: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - r.height, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

// Hexagon with pointed left/right ends.
struct HexShape: Shape {
    var point: CGFloat = 0.3  // how far the points stick out, relative to height

    func path(in r: CGRect) -> Path {
        let d = min(r.height * point * 1.6, r.width / 2)
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.midY))
        p.addLine(to: CGPoint(x: r.minX + d, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - d, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.midY))
        p.addLine(to: CGPoint(x: r.maxX - d, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX + d, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

// MARK: - Panel

struct NSPanel<Content: View, Accessory: View>: View {
    let title: String
    @ViewBuilder var content: Content
    @ViewBuilder var accessory: Accessory

    init(_ title: String, @ViewBuilder content: () -> Content, @ViewBuilder accessory: () -> Accessory = { EmptyView() }) {
        self.title = title
        self.content = content()
        self.accessory = accessory()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                Text(L(title))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(NS.text)
                    .padding(.leading, 10)
                    .padding(.trailing, 34)
                    .frame(height: 22)
                    .background(TabShape().fill(NS.tab))
                Spacer()
                accessory.padding(.top, 6).padding(.trailing, 10)
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(LinearGradient(colors: [Color(white: 0.13), NS.panel], startPoint: .top, endPoint: .bottom))
        )
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(NS.panelBorder, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - Controls

// Long hexagon switch (zone on/off, settings toggles).
struct HexToggle: View {
    let isOn: Bool
    let action: (Bool) -> Void

    var body: some View {
        Button { action(!isOn) } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                HexShape(point: 0.35)
                    .fill(isOn ? NS.redDark : Color(white: 0.18))
                    .overlay(HexShape(point: 0.35).stroke(isOn ? NS.red.opacity(0.7) : Color(white: 0.32), lineWidth: 1))
                HexShape(point: 0.35)
                    .fill(isOn ? LinearGradient(colors: [Color(red: 1, green: 0.3, blue: 0.25), NS.red], startPoint: .top, endPoint: .bottom)
                               : LinearGradient(colors: [Color(white: 0.45), Color(white: 0.3)], startPoint: .top, endPoint: .bottom))
                    .frame(width: 22, height: 14)
                    .padding(.horizontal, 2)
                    .shadow(color: isOn ? NS.red.opacity(0.8) : .clear, radius: 4)
            }
            .frame(width: 42, height: 16)
            .animation(.easeOut(duration: 0.15), value: isOn)
        }
        .buttonStyle(.plain)
    }
}

// Small hexagon radio with a label (Static/Dynamic, light effects).
struct HexRadio: View {
    let label: String
    let selected: Bool
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                HexShape(point: 0.35)
                    .fill(selected ? NS.red : Color(white: 0.22))
                    .overlay(HexShape(point: 0.35).stroke(selected ? Color(red: 1, green: 0.4, blue: 0.35) : Color(white: 0.36), lineWidth: 1))
                    .frame(width: 18, height: 12)
                    .shadow(color: selected ? NS.red : .clear, radius: 3)
                Text(L(label)).font(.system(size: 12)).foregroundStyle(selected ? NS.text : NS.dim)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
    }
}

// Red-filled slider with a round red knob; reports only when the drag ends.
struct RedSlider: View {
    let value: Double
    let range: ClosedRange<Double>
    var step: Double = 1
    let onCommit: (Double) -> Void
    @State private var dragValue: Double?

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width - 14
            let v = dragValue ?? value
            let frac = (v - range.lowerBound) / (range.upperBound - range.lowerBound)
            ZStack(alignment: .leading) {
                Capsule().fill(Color(white: 0.22)).frame(height: 4).padding(.horizontal, 7)
                Capsule().fill(LinearGradient(colors: [NS.redDark, NS.red], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(0, w * frac), height: 4).padding(.leading, 7)
                HexShape(point: 0.25)
                    .fill(LinearGradient(colors: [Color(red: 1, green: 0.35, blue: 0.3), NS.red], startPoint: .top, endPoint: .bottom))
                    .frame(width: 16, height: 12)
                    .shadow(color: NS.red.opacity(0.8), radius: 3)
                    .offset(x: w * frac - 1)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        let f = min(max((g.location.x - 7) / w, 0), 1)
                        let raw = range.lowerBound + f * (range.upperBound - range.lowerBound)
                        dragValue = (raw / step).rounded() * step
                    }
                    .onEnded { _ in
                        if let dragValue { onCommit(dragValue) }
                        dragValue = nil
                    }
            )
        }
        .frame(height: 18)
    }
}

// Bladed fan ring with the RPM in the middle.
struct FanDial: View {
    let rpm: Int?
    var size: CGFloat = 112

    var body: some View {
        ZStack {
            Canvas { ctx, sz in
                let c = CGPoint(x: sz.width / 2, y: sz.height / 2)
                let r = min(sz.width, sz.height) / 2
                let blades = 36
                for i in 0..<blades {
                    let a = Double(i) / Double(blades) * 2 * .pi
                    var p = Path()
                    let r0 = r * 0.74, r1 = r * 0.99
                    p.move(to: CGPoint(x: c.x + r0 * cos(a), y: c.y + r0 * sin(a)))
                    p.addQuadCurve(
                        to: CGPoint(x: c.x + r1 * cos(a + 0.22), y: c.y + r1 * sin(a + 0.22)),
                        control: CGPoint(x: c.x + r * 0.9 * cos(a + 0.02), y: c.y + r * 0.9 * sin(a + 0.02)))
                    ctx.stroke(p, with: .color(Color(white: 0.42)), style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
                }
                let inner = Path(ellipseIn: CGRect(x: c.x - r * 0.68, y: c.y - r * 0.68, width: r * 1.36, height: r * 1.36))
                ctx.fill(inner, with: .color(Color(white: 0.06)))
                ctx.stroke(inner, with: .color(NS.red.opacity(0.75)), lineWidth: 1.5)
            }
            VStack(spacing: 0) {
                Text(rpm.map(String.init) ?? "--").font(.system(size: size * 0.18, weight: .bold)).foregroundStyle(NS.text).monospacedDigit()
                Text("RPM").font(.system(size: size * 0.075)).foregroundStyle(NS.dim)
            }
        }
        .frame(width: size, height: size)
    }
}

// Row in a selectable list (Fan Control, Power Plan): icon + label, red when selected.
struct NSListItem: View {
    let label: String
    let icon: String
    let selected: Bool
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 17))
                    .frame(width: 24)
                    .foregroundStyle(selected ? NS.red : NS.faint)
                    .shadow(color: selected ? NS.red.opacity(0.7) : .clear, radius: 4)
                Text(L(label)).font(.system(size: 12)).foregroundStyle(selected ? NS.red : NS.dim)
                Spacer()
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
    }
}

struct NSDivider: View {
    var body: some View { Rectangle().fill(Color(white: 0.2)).frame(height: 1).padding(.horizontal, 8) }
}

// Flat dark button with a thin border (Auto under the fan sliders, More color...).
struct NSButton: View {
    let label: String
    var icon: String?
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let icon { Image(systemName: icon) }
                Text(L(label))
            }
            .font(.system(size: 11))
            .foregroundStyle(NS.dim)
            .padding(.horizontal, 10)
            .frame(height: 20)
            .background(RoundedRectangle(cornerRadius: 3).fill(Color(white: 0.16)))
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color(white: 0.28), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
    }
}

// Small tag beside a control that has never been verified on this board.
struct UnverifiedTag: View {
    var text = "UNVERIFIED"
    let help: String

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(NS.yellow)
            .padding(.horizontal, 5)
            .frame(height: 14)
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(NS.yellow.opacity(0.55), lineWidth: 1))
            .help(help)
    }
}

// MARK: - App icon (rendered by `NitroSense --icon <dir>`, packed with iconutil)

struct AppIconView: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 185, style: .continuous)
                .fill(LinearGradient(colors: [Color(white: 0.2), Color(white: 0.06)], startPoint: .top, endPoint: .bottom))
                .overlay(RoundedRectangle(cornerRadius: 185, style: .continuous).stroke(Color(white: 0.3), lineWidth: 6))
                .frame(width: 824, height: 824)
            Canvas { ctx, sz in
                let c = CGPoint(x: sz.width / 2, y: sz.height / 2)
                let r = sz.width / 2
                for i in 0..<36 {
                    let a = Double(i) / 36 * 2 * .pi
                    var p = Path()
                    let r0 = r * 0.72, r1 = r * 0.99
                    p.move(to: CGPoint(x: c.x + r0 * cos(a), y: c.y + r0 * sin(a)))
                    p.addQuadCurve(to: CGPoint(x: c.x + r1 * cos(a + 0.22), y: c.y + r1 * sin(a + 0.22)),
                                   control: CGPoint(x: c.x + r * 0.9 * cos(a + 0.02), y: c.y + r * 0.9 * sin(a + 0.02)))
                    ctx.stroke(p, with: .color(Color(white: 0.55)), style: StrokeStyle(lineWidth: 13, lineCap: .round))
                }
                let inner = Path(ellipseIn: CGRect(x: c.x - r * 0.66, y: c.y - r * 0.66, width: r * 1.32, height: r * 1.32))
                ctx.fill(inner, with: .color(Color(white: 0.05)))
                ctx.stroke(inner, with: .color(NS.red), lineWidth: 12)
            }
            .frame(width: 600, height: 600)
            HexShape(point: 0.3)
                .fill(LinearGradient(colors: [Color(red: 1, green: 0.32, blue: 0.27), NS.red, NS.redDark], startPoint: .top, endPoint: .bottom))
                .frame(width: 260, height: 150)
                .shadow(color: NS.red.opacity(0.9), radius: 30)
        }
        .frame(width: 1024, height: 1024)
    }
}
