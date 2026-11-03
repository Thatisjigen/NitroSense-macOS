// GPU load and RTX telemetry for app and nitroctl, as the plain user: no root, no kext of ours, nothing written.
//
// Load (observed on this machine): NVAccel publishes "GPU Core Utilization %", steady, and "Device
// Utilization %", which often drops to 0 between two reads while the other one holds.
//
// Temperature, power, clocks and P-state come from RM's user shared data page (Core/rusd.c). The other sources are no good on
// this machine: EC GTMP reads 0 with the RTX on, the NVAccel statistics have no temperature, and SMCNvidiaGPU 1.6 does not know
// our NVRM build (kern.nvgpustate: "matches none of the 4 known builds"), so kern.nvgputemp stays 0 and its SMC keys are not
// readable.
//
// The Iris Xe has no load figure, so none is shown. With the desktop running on it (WindowServer compositing the
// panel, IOSurface traffic of 2-25 MB per sample, hardwareWaitTime moving) IntelAccelerator's "Device Utilization %", its
// units 0-5, "at cur p-state" and the IOReport channel "Overall GPU Busy" all stay at 0, while "Overall GPU total time"
// runs. hardwareWaitTime moves, but it is what clients spend waiting, not how busy the GPU is. A 0 here would be false.

import Foundation
import IOKit

func readRTXLoad() -> Int? {
    let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("NVAccel"))
    guard service != 0 else { return nil }
    defer { IOObjectRelease(service) }
    let statistics = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
        .takeRetainedValue() as? [String: Any]
    for key in ["GPU Core Utilization %", "Device Utilization %"] {
        if let value = statistics?[key] as? Int { return min(max(value, 0), 100) }
    }
    return nil
}

// One sample of RM's page, in plain units; a field RM did not fill in, or one that makes no sense, is nil.
struct RTXTelemetry: Equatable {
    var at = Date()
    var tempC: Int?
    var memTempC: Int?
    var powerW: Double?     // RM's average, steadier than the instant value; the instant value if there is no average
    var gpcMHz: Int?
    var memMHz: Int?
    var pstate: Int?
    var problem: String?    // why there is nothing, when the read failed

    var summary: String? {
        guard let tempC else { return nil }
        var parts = ["\(tempC) °C"]
        if let memTempC { parts.append("memory \(memTempC) °C") }
        if let powerW { parts.append(String(format: "%.1f W", powerW)) }
        if let gpcMHz, let memMHz { parts.append("\(gpcMHz)/\(memMHz) MHz") }
        if let pstate { parts.append("P\(pstate)") }
        return parts.joined(separator: ", ")
    }
}

// About 10 ms, and it blocks while RM holds its locks: not for the main thread, and not more often than every few seconds.
func readRTXTelemetry() -> RTXTelemetry {
    var sample = NitroRUSDSample()
    nitroRUSDSample(&sample)
    var telemetry = RTXTelemetry()
    guard sample.step == 0 else {
        telemetry.problem = String(cString: nitroRUSDStepName(sample.step))
        return telemetry
    }
    func temperature(_ value: Double) -> Int? { (1...125).contains(value) ? Int(value.rounded()) : nil }
    func power(_ value: Double) -> Double? { value > 0 && value < 400 ? value : nil }
    telemetry.tempC = temperature(sample.tempC)
    telemetry.memTempC = temperature(sample.memTempC)
    telemetry.powerW = power(sample.avgPowerW) ?? power(sample.powerW)
    telemetry.gpcMHz = sample.gpcMHz > 0 ? Int(sample.gpcMHz) : nil
    telemetry.memMHz = sample.memMHz > 0 ? Int(sample.memMHz) : nil
    telemetry.pstate = sample.pstate >= 0 ? Int(sample.pstate) : nil
    if telemetry.tempC == nil { telemetry.problem = "RM gave no plausible temperature" }
    return telemetry
}
