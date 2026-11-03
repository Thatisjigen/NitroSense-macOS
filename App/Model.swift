// App state: polls nitrod over its socket and asks it for the few firmware calls this board has; reads the GPU load from
// the IORegistry itself. The app never opens the kext, so it needs no root.

import AppKit
import Foundation
import IOKit
import Observation
import SwiftUI

struct Snapshot: Equatable {
    var fromEC = false        // false until the EC was read: no value below means anything then, 0 least of all
    var cpuTemp = 0, sysTemp = 0
    var cpuRPM = 0, gpuRPM = 0
    var acPlugged = false
    var keyboardBit = false   // KBBL, EC 0x48 bit 0
    var fant: UInt8 = 0       // FANT, EC 0x54

    init() {}

    init(_ ec: [UInt8]) {
        fromEC = true
        cpuTemp = Int(ec[Reg.cpuTemp])
        sysTemp = Int(ec[Reg.sysTemp])
        cpuRPM = be16(ec, Reg.cpuFanRPM)   // ANV15-52: big-endian
        gpuRPM = be16(ec, Reg.gpuFanRPM)
        acPlugged = ec[Reg.acStatus] & 0x01 == 1
        keyboardBit = ec[Reg.kbBacklight] & 0x01 == 1
        fant = ec[Reg.fanTable] & 0x0F
    }
}

struct Sample {
    let date: Date
    let cpuTemp: Int
    let gpuTemp: Int?
    let cpuLoad: Int?
    let cpuPower: Double?
    let rtxLoad: Int?
    let rtxPower: Double?
}

// What nitrod says about the firmware controls. Nothing here comes from a guess: until a reading exists, a control shows no
// selection. An older nitrod sends no "control" key at all.
struct ControlState: Equatable {
    var daemonGone = false
    var daemonKnowsControls = false
    var gamingWMI = false
    var batteryWMI = false
    var firmwareReadOK = false
    var batteryLimit: BatteryLimitReading?
    var modeState: [UInt8]?
    var firmware: FirmwareReading?

    var canRead: Bool { daemonKnowsControls && gamingWMI }
    // A write needs its GET to have answered: nitrod refuses it otherwise, so the button says it first.
    var canSetFan: Bool { canRead && firmware?.fanCPU != nil && firmware?.fanGPU != nil }
    var canSetMode: Bool { canRead && firmware?.profile != nil }

    // Why a control is greyed out, when it is.
    var readBlockedReason: String? {
        if daemonGone { return "nitrod is not reachable" }
        if !daemonKnowsControls { return "needs the nitrod of this build" }
        if !gamingWMI { return "needs the kext and SSDT of this build, then a reboot" }
        return nil
    }

    private func writeBlockedReason(_ can: Bool, _ what: String) -> String? {
        if let reason = readBlockedReason { return reason }
        if firmware == nil { return "press Read firmware first" }
        return can ? nil : "the firmware did not answer the \(what) read"
    }

    // The charge limit needs only what the battery-limit kext and SSDT already offer, so it does not wait for a reboot.
    var canSetBatteryLimit: Bool { daemonKnowsControls && batteryWMI && batteryLimit != nil }

    var batteryBlockedReason: String? {
        if daemonGone { return "nitrod is not reachable" }
        if !daemonKnowsControls { return "needs the nitrod of this build" }
        if !batteryWMI { return "the loaded kext and SSDT offer no battery WMI" }
        return batteryLimit == nil ? "not read yet" : nil
    }

    var fanBlockedReason: String? { writeBlockedReason(canSetFan, "fan") }
    var modeBlockedReason: String? { writeBlockedReason(canSetMode, "mode") }
}

// Whole-machine draw while on battery: Voltage (mV) × Amperage (mA, negative when
// discharging) from AppleSmartBattery. nil on AC (the battery then reads ~0 A).
func batteryDischargeWatts() -> Double? {
    let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
    guard svc != 0 else { return nil }
    defer { IOObjectRelease(svc) }
    func prop(_ key: String) -> Any? { IORegistryEntryCreateCFProperty(svc, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() }
    guard prop("ExternalConnected") as? Bool == false,
          let mv = prop("Voltage") as? Int,
          let ma = (prop("InstantAmperage") as? Int) ?? (prop("Amperage") as? Int) else { return nil }
    let signed = ma > 0x7FFF_FFFF ? ma - 0x1_0000_0000 : ma  // some drivers report it unsigned
    return abs(Double(mv) * Double(signed)) / 1_000_000
}

// Whole-machine CPU load from host_statistics tick deltas.
final class CPULoadMeter {
    private var last: (busy: UInt64, total: UInt64)?

    func sample() -> Int? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        let t = info.cpu_ticks  // user, system, idle, nice
        let busy = UInt64(t.0) + UInt64(t.1) + UInt64(t.3)
        let total = busy + UInt64(t.2)
        defer { last = (busy, total) }
        guard let last, total > last.total else { return nil }
        return Int((busy - last.busy) * 100 / (total - last.total))
    }
}

@MainActor
@Observable
final class NitroModel {
    var config = NitroConfig()
    var snapshot = Snapshot()
    var connected = false
    var error: String?
    var actionMessage: String?   // what the last click answered, kept for a while: the next poll would clear `error`
    var actionIsWarning = false
    var history: [Sample] = []   // last 5 min
    var cpuLoad: Int?
    var cpuPower: Double?      // CPU package W from nitrod (powermetrics)
    var batteryPower: Double?  // whole machine W while on battery
    var rtxLoad: Int?
    var rtx = RTXTelemetry(at: .distantPast)
    var rtxFastSampling = false  // the main window is open
    var control = ControlState()
    private let loadMeter = CPULoadMeter()

    private let queue = DispatchQueue(label: "nitro.socket")
    // RM calls can block on RM's locks: they keep to their own queue, one at a time, and to low rates, so that RM polls for a
    // few milliseconds every so often and not at all in between.
    private let rmQueue = DispatchQueue(label: "nitro.rm")
    private var rmBusy = false
    private var rmPaused = false
    private var rmResume: DispatchWorkItem?
    private let rtxFastInterval = 5.0, rtxSlowInterval = 60.0
    private var timer: Timer?
    // A window just asked, but nitrod's answer about what it can do was not in yet. Good for a few seconds only: later nobody
    // is looking any more, and the firmware is not to be asked by itself.
    private var wantsTrustedRead = Date.distantPast
    private var wantsBatteryRead = Date.distantPast
    private let wantsLifetime = 10.0
    private var clearAction: DispatchWorkItem?

    init(preview: Bool = false) {
        if preview { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        // No RM calls around sleep or with the screens off: the driver has enough to do, and nobody is looking.
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.pauseRM() }
            }
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.resumeRMSoon() }
            }
        }
    }

    private func pauseRM() {
        rmResume?.cancel()
        rmPaused = true
    }

    private func resumeRMSoon() {
        rmResume?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.rmPaused = false }
        rmResume = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: work)
    }

    // What RM last said, while it is recent: an old reading is no reading.
    private var rtxIsRecent: Bool { Date().timeIntervalSince(rtx.at) < rtxSlowInterval * 3 }
    var gpuTemp: Int? { rtxIsRecent ? rtx.tempC : nil }
    var gpuPower: Double? { rtxIsRecent ? rtx.powerW : nil }
    var gpuDetail: String? {
        guard rtxIsRecent, let gpc = rtx.gpcMHz else { return nil }
        return rtx.pstate.map { "\(gpc) MHz P\($0)" } ?? "\(gpc) MHz"
    }
    var gpuProblem: String { rtx.problem ?? (rtxIsRecent ? "" : "not read yet") }

    // The main window opened or the menu bar panel came up: fresh numbers now, if the last ones are older than the fast rate.
    func sampleRTXNow() { sampleRTX(olderThan: rtxFastInterval) }

    private func sampleRTX(olderThan interval: TimeInterval) {
        guard !rmBusy, !rmPaused, Date().timeIntervalSince(rtx.at) >= interval else { return }
        rmBusy = true
        rmQueue.async {
            let telemetry = readRTXTelemetry()
            Task { @MainActor in
                self.rmBusy = false
                self.rtx = telemetry
            }
        }
    }

    // Both fans in the same state, as the firmware last answered; nil when not read yet or when they differ.
    var currentFan: String? {
        guard let cpu = control.firmware?.fanCPU, let gpu = control.firmware?.fanGPU, cpu == gpu else { return nil }
        return cpu == 1 ? "auto" : cpu == 2 ? "max" : cpu == 3 ? "custom" : nil
    }

    // The firmware's answer if there is one, otherwise what the EC shows: FANT is set by _Q30 of the DSDT.
    var currentProfile: UInt8? {
        if let value = control.firmware?.profile { return UInt8(truncatingIfNeeded: value) }
        return snapshot.fromEC ? profileValueFromFANT(snapshot.fant) : nil
    }

    func refresh() {
        send(["cmd": "status"], isStatus: true)
        queue.async {
            let load = readRTXLoad()
            Task { @MainActor in self.rtxLoad = load }
        }
        sampleRTX(olderThan: rtxFastSampling ? rtxFastInterval : rtxSlowInterval)
    }

    func setFan(_ mode: String) { send(["cmd": "fan", "mode": mode], isStatus: false, isWrite: true, asksFirmware: true) }

    func setFanDuty(cpu: Int, gpu: Int) {
        send(["cmd": "fan", "mode": "custom", "cpu": cpu, "gpu": gpu], isStatus: false, isWrite: true, asksFirmware: true)
    }

    func setUSBCharge(_ value: Int) { send(["cmd": "usb", "value": value], isStatus: false, isWrite: true) }

    func setKBTimeout(_ on: Bool) { send(["cmd": "backlight", "mode": on ? "on" : "off"], isStatus: false, isWrite: true) }

    func setPower(_ mode: String) { send(["cmd": "power", "mode": mode], isStatus: false, isWrite: true, asksFirmware: true) }

    // The button: everything the firmware can tell, the charge limit included.
    func readFirmware() {
        send(["cmd": "firmware"], isStatus: false, asksFirmware: true)
        requestBatteryRead()
    }

    func reapply() { send(["cmd": "apply"], isStatus: false, isWrite: true) }

    func setBatteryLimit(_ on: Bool) { send(["cmd": "battery", "mode": on ? "on" : "off"], isStatus: false, isWrite: true) }

    // A window or the gear menu opens: ask the firmware for the charge limit. If nitrod's answer about what it can do is
    // not in yet, the next status reply does it. Never at launch by itself, and never from config.json.
    func requestBatteryRead() {
        if control.daemonKnowsControls, control.batteryWMI {
            send(["cmd": "battery"], isStatus: false)
        } else {
            wantsBatteryRead = Date()
        }
    }

    // A window opens: refresh what the firmware says, but only on a machine where these calls already answered once. The
    // first read is always a click on Read firmware. Waits for the next status reply to know.
    func requestTrustedRead() { wantsTrustedRead = Date() }

    private func send(_ request: [String: Any], isStatus: Bool, isWrite: Bool = false, asksFirmware: Bool = false) {
        let payload = try? JSONSerialization.data(withJSONObject: request)
        queue.async {
            var data: Data?
            var failure: String?
            do {
                let req = try JSONSerialization.jsonObject(with: payload ?? Data()) as? [String: Any] ?? [:]
                data = try JSONSerialization.data(withJSONObject: try nitrodRequest(req))
            } catch {
                failure = "\(error)"
            }
            Task { @MainActor in self.apply(replyData: data, failure: failure, isStatus: isStatus, isWrite: isWrite, asksFirmware: asksFirmware) }
        }
    }

    private func showAction(_ message: String, warning: Bool) {
        actionMessage = message
        actionIsWarning = warning
        clearAction?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.actionMessage = nil }
        clearAction = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: work)
    }

    private func apply(replyData: Data?, failure: String?, isStatus: Bool, isWrite: Bool, asksFirmware: Bool) {
        guard let replyData, let reply = try? JSONSerialization.jsonObject(with: replyData) as? [String: Any] else {
            connected = false
            error = failure ?? "no reply from nitrod"
            // Nothing can be asked of it, and what it said last is no longer known to be true.
            snapshot = Snapshot()
            control = ControlState(daemonGone: true)
            return
        }
        connected = true
        // Also after a refused write: nitrod reads back, and the firmware may have moved anyway.
        if reply["control"] != nil { applyControl(reply["control"] as? [String: Any]) }
        if reply["ok"] as? Bool != true {
            let message = reply["error"] as? String ?? "daemon error"
            if isStatus { error = message } else { showAction(message, warning: false) }
            return
        }
        error = nil
        if let warning = reply["warning"] as? String {
            showAction(warning, warning: true)
        } else if isWrite {
            actionMessage = nil  // a read never clears what the last click answered
        }
        if let cfg = reply["config"] as? [String: Any], let decoded = try? NitroConfig().merged(with: cfg), decoded != config {
            config = decoded
        }
        if reply["control"] == nil { applyControl(nil) }
        if asksFirmware, reply["warning"] == nil, let errors = control.firmware?.errors, !errors.isEmpty {
            showAction("Firmware: \(errors.joined(separator: "; "))", warning: true)
        }
        if let ec = (reply["ec"] as? [Int])?.map({ UInt8(truncatingIfNeeded: $0) }), ec.count == 256 {
            snapshot = Snapshot(ec)
            if isStatus {
                cpuLoad = loadMeter.sample() ?? cpuLoad
                cpuPower = reply["cpuPower"] as? Double
                batteryPower = batteryDischargeWatts()
                history.append(Sample(date: Date(), cpuTemp: snapshot.cpuTemp, gpuTemp: gpuTemp, cpuLoad: cpuLoad, cpuPower: cpuPower,
                                      rtxLoad: rtxLoad, rtxPower: gpuPower))
                if history.count > 150 { history.removeFirst(history.count - 150) }
            }
        } else if isStatus {
            snapshot = Snapshot()  // nitrod could not read the EC: the last numbers are no longer known to be true
        }
        if isStatus, Date().timeIntervalSince(wantsBatteryRead) < wantsLifetime, control.daemonKnowsControls, control.batteryWMI {
            wantsBatteryRead = .distantPast
            send(["cmd": "battery"], isStatus: false)
        }
        if isStatus, Date().timeIntervalSince(wantsTrustedRead) < wantsLifetime, control.firmwareReadOK, control.canRead {
            wantsTrustedRead = .distantPast
            send(["cmd": "firmware"], isStatus: false, asksFirmware: true)
        }
    }

    private func applyControl(_ dict: [String: Any]?) {
        var next = ControlState()
        if let dict {
            next.daemonKnowsControls = true
            next.gamingWMI = dict["gamingWMI"] as? Bool ?? false
            next.batteryWMI = dict["batteryWMI"] as? Bool ?? false
            next.firmwareReadOK = dict["firmwareReadOK"] as? Bool ?? false
            if let obj = dict["batteryLimit"], let data = try? JSONSerialization.data(withJSONObject: obj) {
                next.batteryLimit = try? JSONDecoder().decode(BatteryLimitReading.self, from: data)
            }
            next.modeState = (dict["modeState"] as? [Int])?.map { UInt8(truncatingIfNeeded: $0) }
            if let obj = dict["firmware"], let data = try? JSONSerialization.data(withJSONObject: obj) {
                next.firmware = try? JSONDecoder().decode(FirmwareReading.self, from: data)
            }
        }
        if next != control { control = next }
    }
}

// MARK: - Colour helpers

extension Color {
    init(hexRGB: String) {
        let v = UInt32(hexRGB.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0xFFFFFF
        self.init(.sRGB, red: Double(v >> 16 & 0xFF) / 255, green: Double(v >> 8 & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }

    var hexRGB: String {
        let c = NSColor(self).usingColorSpace(.sRGB) ?? .white
        func byte(_ x: CGFloat) -> Int { Int((min(max(x, 0), 1) * 255).rounded()) }
        return String(format: "%02X%02X%02X", byte(c.redComponent), byte(c.greenComponent), byte(c.blueComponent))
    }
}
