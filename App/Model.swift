// App state: polls nitrod over its socket and sends partial config patches.
// The app never opens the kext itself, so it needs no root.

import AppKit
import Foundation
import IOKit
import Observation
import SwiftUI

struct Snapshot: Equatable {
    var cpuTemp = 0, gpuTemp = 0, sysTemp = 0
    var cpuRPM = 0, gpuRPM = 0
    var cpuFanMode: UInt8 = 0, gpuFanMode: UInt8 = 0
    var cpuDuty = 0, gpuDuty = 0
    var acPlugged = false
    var batteryState = ""
    var psee = false

    init() {}

    init(_ ec: [UInt8]) {
        cpuTemp = Int(ec[Reg.cpuTemp])
        gpuTemp = Int(ec[Reg.gpuTemp])
        sysTemp = Int(ec[Reg.sysTemp])
        cpuRPM = be16(ec, Reg.cpuFanRPM)   // ANV15-52: big-endian
        gpuRPM = be16(ec, Reg.gpuFanRPM)
        cpuFanMode = ec[Reg.cpuFanMode]
        gpuFanMode = ec[Reg.gpuFanMode]
        cpuDuty = Int(ec[Reg.cpuFanSpeed])
        gpuDuty = Int(ec[Reg.gpuFanSpeed])
        acPlugged = ec[Reg.acStatus] & 0x01 == 1
        batteryState = batteryStatus(ec[Reg.batteryStatus])
        psee = ec[Reg.battery] & 0x10 != 0
    }
}

struct Sample {
    let date: Date
    let cpuTemp: Int
    let gpuTemp: Int
    let cpuLoad: Int?
    let cpuPower: Double?
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
    var failsafe = false
    var connected = false
    var error: String?
    var history: [Sample] = []   // last 5 min
    var cpuLoad: Int?
    var cpuPower: Double?      // CPU package W from nitrod (powermetrics)
    var batteryPower: Double?  // whole machine W while on battery
    private let loadMeter = CPULoadMeter()

    private let queue = DispatchQueue(label: "nitro.socket")
    private var timer: Timer?
    private var pending: [String: Any] = [:]
    private var pendingWork: DispatchWorkItem?
    // Status polls that were queued before a set can carry the old config; ignore
    // their config for a moment so controls do not flick back.
    private var holdConfigUntil = Date.distantPast

    init(preview: Bool = false) {
        if preview { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        send(["cmd": "status"])
    }

    // Debounced: colour pickers and sliders fire many changes; only the last one is sent.
    func set(_ patch: [String: Any], delay: Double = 0.25) {
        holdConfigUntil = Date().addingTimeInterval(delay + 1.5)
        pending = deepMergePatch(pending, patch)
        pendingWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let patch = self.pending
            self.pending = [:]
            self.send(["cmd": "set", "config": patch])
        }
        pendingWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func reapply() {
        send(["cmd": "apply"])
    }

    private func send(_ request: [String: Any]) {
        let payload = try? JSONSerialization.data(withJSONObject: request)
        let isStatus = request["cmd"] as? String == "status"
        queue.async {
            var data: Data?
            var failure: String?
            do {
                let req = try JSONSerialization.jsonObject(with: payload ?? Data()) as? [String: Any] ?? [:]
                data = try JSONSerialization.data(withJSONObject: try nitrodRequest(req))
            } catch {
                failure = "\(error)"
            }
            Task { @MainActor in self.apply(replyData: data, failure: failure, isStatus: isStatus) }
        }
    }

    private func apply(replyData: Data?, failure: String?, isStatus: Bool) {
        guard let replyData, let reply = try? JSONSerialization.jsonObject(with: replyData) as? [String: Any] else {
            connected = false
            error = failure ?? "no reply from nitrod"
            return
        }
        connected = true
        if reply["ok"] as? Bool != true {
            error = reply["error"] as? String ?? "daemon error"
            return
        }
        error = nil
        failsafe = reply["failsafe"] as? Bool ?? false
        if pending.isEmpty, !isStatus || Date() > holdConfigUntil, let cfg = reply["config"] as? [String: Any],
           let data = try? JSONSerialization.data(withJSONObject: cfg),
           let decoded = try? JSONDecoder().decode(NitroConfig.self, from: data), decoded != config {
            config = decoded
        }
        if let ec = (reply["ec"] as? [Int])?.map({ UInt8(truncatingIfNeeded: $0) }), ec.count == 256 {
            snapshot = Snapshot(ec)
            if isStatus {
                cpuLoad = loadMeter.sample() ?? cpuLoad
                cpuPower = reply["cpuPower"] as? Double
                batteryPower = batteryDischargeWatts()
            }
            history.append(Sample(date: Date(), cpuTemp: snapshot.cpuTemp, gpuTemp: snapshot.gpuTemp,
                                  cpuLoad: cpuLoad, cpuPower: cpuPower))
            if history.count > 150 { history.removeFirst(history.count - 150) }
        }
    }
}

private func deepMergePatch(_ a: [String: Any], _ b: [String: Any]) -> [String: Any] {
    var out = a
    for (k, v) in b {
        if let ad = out[k] as? [String: Any], let bd = v as? [String: Any] {
            out[k] = deepMergePatch(ad, bd)
        } else {
            out[k] = v
        }
    }
    return out
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
