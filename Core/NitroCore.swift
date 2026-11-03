// nitroctl — command-line client for NitroEC.kext, ANV15-52 branch
//
//   nitroctl [status]      decoded sensors, fans, GPU load, keyboard bit, power mode as the EC shows it
//   nitroctl dump          hex dump of EC RAM 0x00..0xFF
//   nitroctl read <off>    one byte (hex or decimal offset)
//   nitroctl watch [sec]   status every <sec> seconds (default 1)
//   nitroctl ecdiff        learns for 5 s what moves by itself, then prints every other EC byte that changes
//   nitroctl modes         firmware mode fields and the tables behind each mode (no SMI; needs an SSDT-NITRO with RMOD)
//
//   sudo nitroctl firmware                         every GET at once, with the raw replies (reads only)
//   sudo nitroctl fan status|auto|max              both fans, firmware SetGamingFanBehavior (WMBH 0x0E), read back with 0x0F
//   sudo nitroctl mode status|quiet|balance|performance   firmware SetGamingMiscSetting 0x0B (WMBH 0x16), read back with 0x17
//   sudo nitroctl kb status                        firmware GetGamingKBBacklight (WMBH 0x15), read only
//   sudo nitroctl battery limit on|off|status      80 % charge limit (firmware WMBE 0x15 / 0x14)
//   sudo nitroctl wmbh <op> [b0 b1 ...]            call firmware WMBH, hex bytes: only the exact calls listed below pass
//
// There is no command that writes an EC byte: this branch has none, and the kext refuses them anyway.

import Foundation
import IOKit

// MARK: - Kext connection

struct NitroECError: Error, CustomStringConvertible {
    let description: String
}

final class NitroEC {
    private var connection: io_connect_t = 0

    init() throws {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(kNitroECServiceClass))
        guard service != 0 else {
            throw NitroECError(description: "NitroEC.kext is not loaded (or SSDT-NITRO is missing). Check: ioreg -c NitroEC")
        }
        defer { IOObjectRelease(service) }
        let kr = IOServiceOpen(service, mach_task_self_, 0, &connection)
        guard kr == KERN_SUCCESS else {
            throw NitroECError(description: "IOServiceOpen failed: 0x\(String(UInt32(bitPattern: kr), radix: 16))")
        }
    }

    deinit {
        IOServiceClose(connection)
    }

    func readByte(_ offset: UInt8) throws -> UInt8 {
        var input: UInt64 = UInt64(offset)
        var output: UInt64 = 0
        var outputCount: UInt32 = 1
        let kr = IOConnectCallScalarMethod(connection, UInt32(kNitroECSelReadByte.rawValue), &input, 1, &output, &outputCount)
        guard kr == KERN_SUCCESS else {
            throw NitroECError(description: "readByte(0x\(String(offset, radix: 16))) failed: 0x\(String(UInt32(bitPattern: kr), radix: 16))")
        }
        return UInt8(truncatingIfNeeded: output)
    }

    func wmbh(_ opcode: UInt8, _ bytes: [UInt8]) throws -> [UInt8] {
        try wmi(kNitroECSelWMBH, "WMBH", opcode, bytes)
    }

    func wmbe(_ method: UInt8, _ bytes: [UInt8]) throws -> [UInt8] {
        try wmi(kNitroECSelWMBE, "WMBE", method, bytes)
    }

    private func wmi(_ selector: NitroECSelector, _ name: String, _ opcode: UInt8, _ bytes: [UInt8]) throws -> [UInt8] {
        guard isAllowedFirmwareCall(selector, opcode, bytes) else {
            throw NitroECError(description: "\(name) 0x\(String(opcode, radix: 16)) \(bytes.map { hex($0) }.joined(separator: " ")): not an allowed call on the \(Reg.model)")
        }
        var input = [UInt8](repeating: 0, count: Int(kNitroECWMBHInSize))
        for (i, b) in bytes.prefix(input.count).enumerated() { input[i] = b }
        var scalar = UInt64(opcode)
        var output = [UInt8](repeating: 0, count: Int(kNitroECWMBHOutSize))
        var outSize = output.count
        let kr = IOConnectCallMethod(connection, UInt32(selector.rawValue), &scalar, 1,
                                     &input, input.count, nil, nil, &output, &outSize)
        switch kr {
        case KERN_SUCCESS:
            return Array(output.prefix(outSize))
        case kIOReturnNotPrivileged:
            throw NitroECError(description: "\(name) needs root: run with sudo")
        case kIOReturnNotPermitted:
            throw NitroECError(description: "kext refused \(name) 0x\(String(opcode, radix: 16)): the loaded NitroEC.kext is from an older branch (not whitelisted there)")
        case kIOReturnUnsupported:
            throw NitroECError(description: "\(name) 0x\(String(opcode, radix: 16)): the loaded SSDT-NITRO lacks the method for it (the SSDT of an older branch?); see 'NitroEC Gaming WMI' and 'NitroEC Battery WMI' in ioreg -c NitroEC")
        default:
            throw NitroECError(description: "\(name) 0x\(String(opcode, radix: 16)) failed: 0x\(String(UInt32(bitPattern: kr), radix: 16))")
        }
    }

    func dump() throws -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: Int(kNitroECDumpSize))
        var size = Int(kNitroECDumpSize)
        let kr = IOConnectCallStructMethod(connection, UInt32(kNitroECSelDump.rawValue), nil, 0, &buffer, &size)
        guard kr == KERN_SUCCESS, size == Int(kNitroECDumpSize) else {
            throw NitroECError(description: "dump failed: 0x\(String(UInt32(bitPattern: kr), radix: 16)), size \(size)")
        }
        return buffer
    }

    // TUGM, CCOL, IDPF, 0, then the M1..M5 tables. A plain read, no SMI, no root.
    func modeState() throws -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: Int(kNitroECModeStateSize))
        var size = Int(kNitroECModeStateSize)
        let kr = IOConnectCallStructMethod(connection, UInt32(kNitroECSelModeState.rawValue), nil, 0, &buffer, &size)
        guard kr == KERN_SUCCESS, size == Int(kNitroECModeStateSize) else {
            throw NitroECError(description: "mode fields not readable (0x\(String(UInt32(bitPattern: kr), radix: 16))): they need the NitroEC.kext and SSDT-NITRO of branch anv15-52-control")
        }
        return buffer
    }
}

// True when the loaded kext and SSDT publish this capability. A plain registry read, no root.
func nitroECOffers(_ capability: String) -> Bool {
    let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(kNitroECServiceClass))
    guard service != 0 else { return false }
    defer { IOObjectRelease(service) }
    return IORegistryEntryCreateCFProperty(service, capability as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool == true
}

// MARK: - ANV15-52 EC map (Acer Nitro V 15, i9-13900H + RTX 5050; DSDT ERAM at 0xFE708500)
//
// From an EC dump decoded against this board's DSDT field names: five snapshots (idle on AC, 60 s load, after load, on battery, lid closed).
// Only the fields below are understood, and only for reading: the fan, mode, LED and charge bytes of the AN515-57 map do
// not exist here, and no byte of this EC is ever written. What can change goes through the firmware WMI (see below).
enum Reg {
    static let model = "ANV15-52"
    static let cpuTemp: Int = 0x58        // CTMP, °C (50 idle, 97 under load, like Linux acpitz)
    static let sysTemp: Int = 0x51        // ETP1, °C (45-62 in the dump; sensor unverified)
    static let extraTemps: [(String, Int)] = [("ETP2", 0x52), ("ETP3", 0x5A), ("ETP4", 0x5B), ("ETP5", 0x5E), ("ETP6", 0x5F)]
    static let cpuFanRPM: Int = 0x5C      // CPUF, 16-bit BIG-endian (1909 idle, 3743 under load)
    static let gpuFanRPM: Int = 0x6A      // GPUF, 16-bit big-endian (2132 idle, 3993 under load)
    static let acStatus: Int = 0x40       // ACDF bit 0: AC present
    static let lid: Int = 0x4C            // LIDT bit 6: lid closed
    static let pl1: Int = 0x14            // PL1H:PL1L, tenths of a watt (56 W on AC, 32 W on battery)
    static let pl2: Int = 0x16            // PL2H:PL2L, tenths of a watt (92 W on AC, 36 W on battery)
    static let kbBacklight: Int = 0x48    // KBBL bit 0: GOTS in SSDT10 reports it for hotkey event 0x84 (keyboard light). Never seen at 0 yet
    static let fanTable: Int = 0x54       // FANT, low nibble: _Q30 of the DSDT sets it to TUGM, the mode index
    // Names for 'nitroctl ecdiff': the fields of the DSDT that are not plain sensors.
    static let names: [Int: String] = [0x40: "ACDF", 0x41: "APBF", 0x46: "DGDX", 0x48: "KBBL/BTST", 0x4C: "LIDT", 0x4E: "CPUT/GPUT/VGAF",
                                       0x54: "FANT", 0x61: "HIDL/DPBL/TOHP", 0x69: "KBST", 0x6D: "ACTP", 0xF5: "NPWM", 0xF6: "KHID"]
}
func be16(_ ec: [UInt8], _ at: Int) -> Int { Int(ec[at]) << 8 | Int(ec[at + 1]) }

func hex(_ v: UInt8) -> String { String(format: "0x%02X", v) }

private var lastTelemetry = RTXTelemetry(at: .distantPast)

func printStatus(_ ec: [UInt8]) {
    let extras = Reg.extraTemps.map { "\($0.0) \(ec[$0.1])" }.joined(separator: "  ")
    // Not on every line of 'watch': one RM read every few seconds is plenty.
    if Date().timeIntervalSince(lastTelemetry.at) >= 5 { lastTelemetry = readRTXTelemetry() }
    let rtx = lastTelemetry.summary.map { "\($0) (RM shared data page)" } ?? "-- (\(lastTelemetry.problem ?? "not read"))"
    let load = readRTXLoad().map { "\($0) %" } ?? "--"
    let fant = ec[Reg.fanTable] & 0x0F
    print("""
    \(Reg.model) EC (no EC byte is written on this branch; fields from an EC dump)
    Temperatures   CPU \(ec[Reg.cpuTemp]) °C (CTMP)   ETP1 \(ec[Reg.sysTemp])   \(extras) °C
    RTX            \(rtx)
    Fans           CPU \(be16(ec, Reg.cpuFanRPM)) RPM (0x5C, big-endian)   GPU \(be16(ec, Reg.gpuFanRPM)) RPM (0x6A)
    GPU load       RTX \(load) (NVAccel); the Iris Xe publishes no real figure
    Power          AC \(ec[Reg.acStatus] & 0x01 == 1 ? "plugged" : "unplugged")   PL1 \(Double(be16(ec, Reg.pl1)) / 10) W   PL2 \(Double(be16(ec, Reg.pl2)) / 10) W
    Lid            \(ec[Reg.lid] & 0x40 != 0 ? "closed" : "open")
    Keyboard       backlight bit KBBL \(ec[Reg.kbBacklight] & 0x01) (EC 0x48 bit 0, unverified; the Fn keys drive the backlight)
    Power mode     FANT 0x54 = \(fant): \(profileNameFromFANT(fant)) (table of _Q30 in the DSDT, unverified; 'sudo nitroctl mode status' asks the firmware)
    """)
}

func printDump(_ ec: [UInt8]) {
    print("     " + (0..<16).map { String(format: "%02X", $0) }.joined(separator: " "))
    for row in 0..<16 {
        let bytes = ec[row * 16 ..< row * 16 + 16].map { String(format: "%02X", $0) }.joined(separator: " ")
        print(String(format: "%02X:  ", row * 16) + bytes)
    }
}

func parseOffset(_ s: String) -> UInt8? {
    s.lowercased().hasPrefix("0x") ? UInt8(s.dropFirst(2), radix: 16) : UInt8(s)
}

// MARK: - Firmware WMI: the only calls that exist on this branch
//
// Same list as the kext (NitroEC.cpp, isWMBHAllowed and isWMBEAllowed). IDs and types: the MOF of this firmware, WQAB in
// SSDT10 of the ACPI tables. Layouts: Linux drivers/platform/x86/acer-wmi.c for fan behaviour and misc settings (it runs
// the same methods on the ANV15-51 among others, not on this board), Linuwu-Sense for the battery health and the
// keyboard backlight. All of them go to the firmware SMI, so they stop every CPU for as long as the handler runs: nothing
// here polls them.
enum GamingWMI {
    static let setFanBehavior: UInt8 = 0x0E   // SetGamingFanBehavior
    static let getFanBehavior: UInt8 = 0x0F   // GetGamingFanBehavior
    static let getKBBacklight: UInt8 = 0x15   // GetGamingKBBacklight
    static let setMisc: UInt8 = 0x16          // SetGamingMiscSetting
    static let getMisc: UInt8 = 0x17          // GetGamingMiscSetting
    static let fanCPU: UInt8 = 0x01, fanGPU: UInt8 = 0x08
    static let fanAutoBoth: [UInt8] = [0x09, 0x00, 0x41]  // 0x410009: bitmap CPU|GPU, CPU mode 1 (bits 17:16), GPU mode 1 (bits 23:22)
    static let fanMaxBoth: [UInt8] = [0x09, 0x00, 0x82]   // 0x820009: same with mode 2, the firmware's "turbo"
    static let miscSupportedProfiles: UInt8 = 0x0A        // Linux: "unreliable on some models"
    static let miscPlatformProfile: UInt8 = 0x0B
    static let batteryGet: UInt8 = 0x14, batterySet: UInt8 = 0x15  // WMBE
}

func isAllowedFirmwareCall(_ selector: NitroECSelector, _ opcode: UInt8, _ bytes: [UInt8]) -> Bool {
    if selector.rawValue == kNitroECSelWMBE.rawValue {
        switch opcode {
        case GamingWMI.batteryGet: return bytes == [1, 1]
        case GamingWMI.batterySet: return bytes == [1, 1, 0] || bytes == [1, 1, 1]
        default: return false
        }
    }
    guard selector.rawValue == kNitroECSelWMBH.rawValue else { return false }
    switch opcode {
    case GamingWMI.setFanBehavior: return bytes == GamingWMI.fanAutoBoth || bytes == GamingWMI.fanMaxBoth
    case GamingWMI.getFanBehavior: return bytes == [GamingWMI.fanCPU] || bytes == [GamingWMI.fanGPU]
    case GamingWMI.getKBBacklight: return bytes == [1]
    case GamingWMI.setMisc: return bytes.count == 2 && bytes[0] == GamingWMI.miscPlatformProfile && powerModes.values.contains(bytes[1])
    case GamingWMI.getMisc: return bytes == [GamingWMI.miscPlatformProfile] || bytes == [GamingWMI.miscSupportedProfiles]
    default: return false
    }
}

// The first byte of a reply is the firmware status; these are the texts of RETS in SSDT10. A handler that ignores the
// call leaves our input in WMIB, and WMBH returns that: an input never starts with 0, so that shows as a failure too.
func firmwareStatusText(_ status: UInt8) -> String {
    switch status {
    case 0x00: return "success"
    case 0x01: return "control method not supported"
    case 0x02: return "incorrect password"
    case 0x03: return "incorrect parameters"
    case 0x07: return "password retry count exceeded"
    case 0x08: return "success, reboot required"
    case 0xFF: return "the method is missing (WMBX or WMEX fallback)"
    default: return "unknown status"
    }
}

func checkedFirmware(_ reply: [UInt8], _ what: String, minBytes: Int = 1, statusAt: Int = 0, statusBytes: Int = 1) throws -> [UInt8] {
    let raw = reply.map { hex($0) }.joined(separator: " ")
    guard reply.count >= max(minBytes, statusAt + statusBytes) else {
        throw NitroECError(description: "\(what): short firmware reply (\(raw))")
    }
    if let status = reply[statusAt..<(statusAt + statusBytes)].first(where: { $0 != 0 }) {
        throw NitroECError(description: "\(what): firmware status \(hex(status)), \(firmwareStatusText(status)) (reply \(raw))")
    }
    return reply
}

// MARK: - Fan behaviour (both fans; Auto or Max only)

func fanBehaviorName(_ mode: Int) -> String {
    switch mode {
    case 0: return "not set (0)"
    case 1: return "Auto"
    case 2: return "Max"
    case 3: return "Custom"
    default: return "? (\(mode))"
    }
}

// Reply: status in bits 7:0, CPU mode in bits 9:8, GPU mode in bits 15:14 (Linux acer-wmi, WMID_gaming_get_fan_behavior).
func readFanBehavior(_ ec: NitroEC, gpu: Bool) throws -> Int {
    let reply = try checkedFirmware(try ec.wmbh(GamingWMI.getFanBehavior, [gpu ? GamingWMI.fanGPU : GamingWMI.fanCPU]),
                                    "GetGamingFanBehavior", minBytes: 2)
    return gpu ? Int(reply[1] >> 6) : Int(reply[1] & 0x03)
}

func setFanBehavior(_ ec: NitroEC, max: Bool) throws {
    _ = try checkedFirmware(try ec.wmbh(GamingWMI.setFanBehavior, max ? GamingWMI.fanMaxBoth : GamingWMI.fanAutoBoth),
                            "SetGamingFanBehavior")
}

// MARK: - Power mode (misc setting 0x0B)

// The values of misc setting 0x0B: the set Linux acer-wmi uses is the set of values CCOL takes in _Q30 of this DSDT, and
// HIDB sets NVWM (NVPCF) only for 0 and 6. On this firmware the order of the tables is M4 turbo, M3 performance, M2 balance,
// M1 quiet and eco. Only the first three of the app's list may be written.
let powerModes: [String: UInt8] = ["quiet": 0x00, "balance": 0x01, "performance": 0x04]

func profileName(_ value: UInt8) -> String {
    switch value {
    case 0x00: return "Quiet"
    case 0x01: return "Balance"
    case 0x04: return "Performance"
    case 0x05: return "Turbo"
    case 0x06: return "Eco"
    default: return "? \(hex(value))"
    }
}

// FANT (EC 0x54) as _Q30 of the DSDT sets it: FANT = TUGM, and TUGM selects CCOL 5, 4, 1, 0, 6.
func profileValueFromFANT(_ fant: UInt8) -> UInt8? {
    switch fant {
    case 0: return 0x05
    case 1: return 0x04
    case 2: return 0x01
    case 3: return 0x00
    case 4: return 0x06
    default: return nil
    }
}

func profileNameFromFANT(_ fant: UInt8) -> String {
    profileValueFromFANT(fant).map(profileName) ?? "?"
}

// Reply: status in bits 7:0, value in bits 15:8 (Linux acer-wmi, WMID_gaming_get_misc_setting).
func readMiscSetting(_ ec: NitroEC, _ index: UInt8) throws -> UInt8 {
    try checkedFirmware(try ec.wmbh(GamingWMI.getMisc, [index]), "GetGamingMiscSetting \(hex(index))", minBytes: 2)[1]
}

func setPlatformProfile(_ ec: NitroEC, _ value: UInt8) throws {
    _ = try checkedFirmware(try ec.wmbh(GamingWMI.setMisc, [GamingWMI.miscPlatformProfile, value]), "SetGamingMiscSetting")
}

// MARK: - Battery charge limit (firmware battery-health WMI, layout from Linuwu-Sense)

// Returns uFunctionStatus[0] (1 = 80 % limit on) from GetBatteryHealthControlStatus. The MOF of this firmware gives the
// reply as uFunctionList (1 byte), uReturn (2 bytes), uFunctionStatus (5 bytes): the status is at byte 1, not 0.
func batteryLimitStatus(_ ec: NitroEC) throws -> (on: Bool, raw: [UInt8]) {
    let raw = try checkedFirmware(try ec.wmbe(GamingWMI.batteryGet, [0x01, 0x01]), "GetBatteryHealthControlStatus", minBytes: 4, statusAt: 1, statusBytes: 2)
    return (raw[3] == 1, raw)
}

// The MOF of this firmware gives uReturn as 2 bytes, but only the first has been seen at 0 on this board (an 'off'
// through the battery-limit kext): that is what is checked, and the read-back after it decides.
func setBatteryLimit(_ ec: NitroEC, _ on: Bool) throws {
    _ = try checkedFirmware(try ec.wmbe(GamingWMI.batterySet, [0x01, 0x01, on ? 1 : 0]), "SetBatteryHealthControl")
}

// The last answer of WMBE 0x14, which is the only truth about the limit: it lives in the firmware, not in config.json.
struct BatteryLimitReading: Codable, Equatable {
    var on: Bool
    var raw: [Int]
    var at = Date()
}

// MARK: - Every GET at once

// What the firmware answers to the GET calls, with the raw replies. Taken only on request: by hand, by a click in the app,
// after a write, or when re-applying a setting the user chose.
struct FirmwareReading: Codable, Equatable {
    var at = Date()
    var fanCPU: Int?
    var fanGPU: Int?
    var profile: Int?
    var supportedProfiles: Int?
    var keyboard: [Int]?        // 0x15 reply: gmReturn, mode, speed, brightness, 0, direction, R, G, B... (Linuwu-Sense's layout)
    var batteryLimit: Bool?
    var raw: [String: [Int]] = [:]
    var errors: [String] = []

    init() {}

    init(_ ec: NitroEC) {
        var raw: [String: [Int]] = [:]
        var errors: [String] = []
        func ask(_ label: String, minBytes: Int, statusAt: Int = 0, statusBytes: Int = 1, _ call: () throws -> [UInt8]) -> [UInt8]? {
            do {
                let reply = try call()
                raw[label] = reply.map(Int.init)
                return try checkedFirmware(reply, label, minBytes: minBytes, statusAt: statusAt, statusBytes: statusBytes)
            } catch {
                errors.append("\(error)")
                return nil
            }
        }
        if let r = ask("0F 01 fan CPU", minBytes: 2, { try ec.wmbh(GamingWMI.getFanBehavior, [GamingWMI.fanCPU]) }) { fanCPU = Int(r[1] & 0x03) }
        if let r = ask("0F 08 fan GPU", minBytes: 2, { try ec.wmbh(GamingWMI.getFanBehavior, [GamingWMI.fanGPU]) }) { fanGPU = Int(r[1] >> 6) }
        if let r = ask("17 0B profile", minBytes: 2, { try ec.wmbh(GamingWMI.getMisc, [GamingWMI.miscPlatformProfile]) }) { profile = Int(r[1]) }
        if let r = ask("17 0A supported", minBytes: 2, { try ec.wmbh(GamingWMI.getMisc, [GamingWMI.miscSupportedProfiles]) }) { supportedProfiles = Int(r[1]) }
        if let r = ask("15 01 keyboard", minBytes: 1, { try ec.wmbh(GamingWMI.getKBBacklight, [1]) }) { keyboard = r.map(Int.init) }
        if let r = ask("WMBE 14 battery", minBytes: 4, statusAt: 1, statusBytes: 2, { try ec.wmbe(GamingWMI.batteryGet, [1, 1]) }) { batteryLimit = r[3] == 1 }
        self.raw = raw
        self.errors = errors
    }

    var fanSummary: String {
        func name(_ v: Int?) -> String { v.map(fanBehaviorName) ?? "not readable" }
        return fanCPU == fanGPU ? "both \(name(fanCPU))" : "CPU \(name(fanCPU)), GPU \(name(fanGPU))"
    }
}

func printFirmware(_ reading: FirmwareReading) {
    func text(_ v: Int?, _ name: (Int) -> String) -> String { v.map(name) ?? "not readable" }
    print("Fan behaviour  CPU \(text(reading.fanCPU, fanBehaviorName))   GPU \(text(reading.fanGPU, fanBehaviorName))")
    print("Power mode     \(text(reading.profile) { profileName(UInt8(truncatingIfNeeded: $0)) })   (misc setting 0x0B)")
    print("Supported      \(text(reading.supportedProfiles) { String(format: "0x%02X", $0) })   (misc setting 0x0A, bit n = value n; Linux calls it unreliable on some models)")
    if let k = reading.keyboard, k.count >= 9 {
        print("Keyboard       status \(k[0])  mode \(k[1])  speed \(k[2])  brightness \(k[3])  direction \(k[5])  colour \(k[6]) \(k[7]) \(k[8])   (layout from Linuwu-Sense, RGB models)")
    } else {
        print("Keyboard       not readable")
    }
    print("Charge limit   \(reading.batteryLimit.map { $0 ? "on" : "off" } ?? "not readable")")
    print("Raw replies:")
    for (label, bytes) in reading.raw.sorted(by: { $0.key < $1.key }) {
        print("  \(label): \(bytes.map { String(format: "%02X", $0) }.joined(separator: " "))")
    }
    for error in reading.errors { print("  ! \(error)") }
}

// MARK: - Firmware mode fields (RMOD: no SMI)

// TUGM, CCOL, IDPF, 0, then ERM4 + 0xA0: seven bytes (N1 M1 T1 P2 DB CT CP) for each of M1, M2, M3, M4 at +0, +8, +16, +24,
// and DB CT CP of M5 at +0x24. _Q30 of the DSDT takes PL1 from M?M1 if IDPF is 0x55, otherwise from M?N1, and PL2 from M?P2.
func printModeState(_ state: [UInt8]) {
    print("Firmware fields, plain read (no SMI): TUGM \(state[0])   CCOL \(state[1])   IDPF \(hex(state[2]))")
    print("PL1 = \(state[2] == 0x55 ? "M1" : "N1") column, PL2 = P2 column (_Q30 multiplies them by 8 for the 1/8 W registers, so they should read as watts).")
    print("    N1   M1   T1   P2   DB   CT   CP")
    let rows = [("M1: CCOL 0 and 6, quiet and eco", 0), ("M2: CCOL 1, balance", 8), ("M3: CCOL 4, performance", 16), ("M4: CCOL 5, turbo", 24)]
    for (name, base) in rows {
        let values = (0..<7).map { String(format: "%4d", state[4 + base + $0]) }.joined(separator: " ")
        print("\(values)   \(name)")
    }
    print("M5: DB \(state[4 + 0x24])  CT \(state[4 + 0x25])  CP \(state[4 + 0x26])")
    print("(the mode names are read from the DSDT, not verified: compare with 'nitroctl status' and with what each mode does)")
}
