// GPU load and temperature for app and nitroctl: plain reads of the IORegistry and of sysctl, no root, no kext of ours.
//
// Load (observed on this machine): NVAccel publishes "GPU Core Utilization %", steady, and "Device
// Utilization %", which often drops to 0 between two reads while the other one holds; IntelAccelerator publishes "Device
// Utilization %" only. Neither publishes a temperature.
//
// Temperature: there is no real source of the RTX temperature today, so none is shown. EC GTMP (0x59) reads 0 under macOS
// with the RTX on, and SMCNvidiaGPU 1.6 is loaded but reads nothing: kern.nvgpustate says that this NVRM "matches none of
// the 4 known builds", kern.nvgputemp stays 0 and its SMC keys TG0x are not readable. kern.nvgputemp is what is read below,
// so the value appears by itself the day that kext reads.

import Foundation
import IOKit

struct GPUStats: Equatable {
    var rtxLoad: Int?       // %, nil when NVAccel is not there
    var irisLoad: Int?      // %, nil when IntelAccelerator is not there
    var rtxTemp: Int?       // °C, nil unless a source really reads
    var rtxPower: Double?   // W, nil unless a source really reads
    var tempNote: String?   // why there is no temperature, when the source says so
}

private func acceleratorStatistics(_ className: String) -> [String: Any]? {
    let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(className))
    guard service != 0 else { return nil }
    defer { IOObjectRelease(service) }
    return IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
        .takeRetainedValue() as? [String: Any]
}

private func percent(_ statistics: [String: Any]?, _ keys: [String]) -> Int? {
    for key in keys {
        if let value = statistics?[key] as? Int { return min(max(value, 0), 100) }
    }
    return nil
}

private func sysctlInteger(_ name: String) -> Int? {
    var value: Int64 = 0
    var size = MemoryLayout<Int64>.size
    guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
    return size == MemoryLayout<Int32>.size ? Int(Int32(truncatingIfNeeded: value)) : Int(value)
}

private func sysctlString(_ name: String) -> String? {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
    var buffer = [CChar](repeating: 0, count: size)
    guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
    return String(cString: buffer)
}

func readGPUStats() -> GPUStats {
    var stats = GPUStats()
    stats.rtxLoad = percent(acceleratorStatistics("NVAccel"), ["GPU Core Utilization %", "Device Utilization %"])
    stats.irisLoad = percent(acceleratorStatistics("IntelAccelerator"), ["Device Utilization %"])
    if let temp = sysctlInteger("kern.nvgputemp"), (1...125).contains(temp) { stats.rtxTemp = temp }
    if let milliwatts = sysctlInteger("kern.nvgpupower"), milliwatts > 0 { stats.rtxPower = Double(milliwatts) / 1000 }
    if stats.rtxTemp == nil {
        stats.tempNote = sysctlString("kern.nvgpustate").map { "SMCNvidiaGPU: \($0)" }
            ?? "no source: EC GTMP reads 0 and SMCNvidiaGPU is not loaded"
    }
    return stats
}
