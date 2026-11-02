// nitroctl — command-line client for NitroEC.kext
//
//   nitroctl [status]      decoded sensors, fans, modes, keyboard LED
//   nitroctl dump          hex dump of EC RAM 0x00..0xFF
//   nitroctl read <off>    one byte (hex or decimal offset)
//   nitroctl watch [sec]   status every <sec> seconds (default 1)
//
//   sudo nitroctl fan [cpu|gpu|all] auto
//   sudo nitroctl fan [cpu|gpu|all] max
//   sudo nitroctl fan [cpu|gpu|all] manual <20-100>   (percent)
//        (fan commands set PSEE first; add --wmi to set manual duty via firmware WMBH 0x10)
//   sudo nitroctl psee on|off            gaming-software flag (EC 0x03 bit4)
//   sudo nitroctl wmbh <op> [b0 b1 ...]  call firmware WMBH (whitelisted opcodes), hex bytes
//
//   sudo nitroctl mode quiet|default|extreme       firmware operating mode (WMBH 0x16 sub 0x0B)
//   sudo nitroctl battery limit on|off|status       80 % charge limit (firmware WMBE 0x15 / 0x14)
//   sudo nitroctl led init                         enable the 4-zone keyboard (done before every led command)
//   sudo nitroctl led restore                      re-send the colours/effect stored in EC (after boot)
//   sudo nitroctl led zone <1-4|all> <RRGGBB>      static colour per zone (switches to Static)
//   sudo nitroctl led effect <name> [speed 1-9] [RRGGBB] [dir 1|2]
//        name: static breathing neon wave shifting zoom meteor twinkling
//   sudo nitroctl led brightness <0-100>           keeps the current effect
//   sudo nitroctl led off
//   sudo nitroctl usb-charge on|off                USB charging while off/asleep (EC 0x08)
//   sudo nitroctl kb-timeout on|off                keyboard backlight off after 30 s idle (EC 0x06)

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

    @discardableResult
    func writeByte(_ offset: Int, _ value: Int) throws -> UInt8 {
        if Reg.readOnlyModel { throw NitroECError(description: readOnlyMessage) }
        var input: [UInt64] = [UInt64(offset), UInt64(value)]
        var output: UInt64 = 0
        var outputCount: UInt32 = 1
        let kr = IOConnectCallScalarMethod(connection, UInt32(kNitroECSelWriteByte.rawValue), &input, 2, &output, &outputCount)
        switch kr {
        case KERN_SUCCESS:
            return UInt8(truncatingIfNeeded: output)
        case kIOReturnNotPrivileged:
            throw NitroECError(description: "writing needs root: run with sudo")
        case kIOReturnNotPermitted:
            throw NitroECError(description: "kext refused 0x\(String(offset, radix: 16)) = 0x\(String(value, radix: 16)) (not whitelisted)")
        default:
            throw NitroECError(description: "writeByte(0x\(String(offset, radix: 16))) failed: 0x\(String(UInt32(bitPattern: kr), radix: 16))")
        }
    }

    func wmbh(_ opcode: UInt8, _ bytes: [UInt8]) throws -> [UInt8] {
        try wmi(kNitroECSelWMBH, "WMBH", opcode, bytes)
    }

    func wmbe(_ method: UInt8, _ bytes: [UInt8]) throws -> [UInt8] {
        try wmi(kNitroECSelWMBE, "WMBE", method, bytes)
    }

    private func wmi(_ selector: NitroECSelector, _ name: String, _ opcode: UInt8, _ bytes: [UInt8]) throws -> [UInt8] {
        if Reg.readOnlyModel && !isBatteryLimitCall(selector, opcode, bytes) { throw NitroECError(description: readOnlyMessage) }
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
            throw NitroECError(description: "kext refused \(name) 0x\(String(opcode, radix: 16)) (not whitelisted)")
        case kIOReturnUnsupported:
            throw NitroECError(description: "\(name) 0x\(String(opcode, radix: 16)): the loaded SSDT-NITRO has no WMEX method (the read-only SSDT of branch anv15-52?); see 'NitroEC Battery WMI' in ioreg -c NitroEC")
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
}

// MARK: - ANV15-52 EC map (Acer Nitro V 15, i9-13900H + RTX 5050; DSDT ERAM at 0xFE708500)
//
// From an EC dump decoded against this board's DSDT field names: five snapshots (idle on AC, 60 s load, after load, on battery, lid
// closed). Only the fields below are understood. The fan mode, Nitro mode, keyboard LED, USB charge, keyboard
// timeout and battery flags of the AN515-57 map are NOT identified on this board, so the EC is read-only on this branch:
// the kext refuses every EC write and every gaming WMI call (WMBH), and the shared code below refuses them before asking
// the kext. The one exception is the firmware battery-health WMI for the charge limit (Reg.batteryLimitWMI).
enum Reg {
    static let model = "ANV15-52"
    static let readOnlyModel = true
    // Branch anv15-52-battery: the one firmware call that may pass, the battery-health WMI (\_SB.PC00.WMID.WMBE, GUID
    // 79772EC5-04B1-4BFD-843C-61E7F77B6CC9, the one Acer's NitroSense uses on Windows for the 80 % charge limit):
    // 0x14 reads the status with [battery 1, query 1], 0x15 sets it with [battery 1, mask 1 (limit), 0|1]. Same shape
    // as the kext whitelist (NitroEC.cpp, isWMBEAllowed). Set by hand with nitroctl only: nitrod never applies it.
    static let batteryLimitWMI = true
    static let cpuTemp: Int = 0x58        // CTMP, °C (50 idle, 97 under load, like Linux acpitz)
    static let gpuTemp: Int = 0x59        // GTMP, °C (name from the DSDT; which sensor it is was not verified)
    static let sysTemp: Int = 0x51        // ETP1, °C (45-62 in the dump; sensor unverified)
    static let extraTemps: [(String, Int)] = [("ETP2", 0x52), ("ETP3", 0x5A), ("ETP4", 0x5B), ("ETP5", 0x5E), ("ETP6", 0x5F)]
    static let cpuFanRPM: Int = 0x5C      // CPUF, 16-bit BIG-endian (1909 idle, 3743 under load)
    static let gpuFanRPM: Int = 0x6A      // GPUF, 16-bit big-endian (2132 idle, 3993 under load)
    static let acStatus: Int = 0x40       // ACDF bit 0: AC present
    static let lid: Int = 0x4C            // LIDT bit 6: lid closed
    static let pl1: Int = 0x14            // PL1H:PL1L, tenths of a watt (56 W on AC, 32 W on battery)
    static let pl2: Int = 0x16            // PL2H:PL2L, tenths of a watt (92 W on AC, 36 W on battery)
    static let kbBacklight: Int = 0x48    // KBBL bit 0
    static let modeCandidateA: Int = 0x6D // ACTP, 2 in every snapshot: Nitro mode candidate, to confirm with Windows snapshots
    static let modeCandidateB: Int = 0x70 // BTMD, 1 in every snapshot: same
    // AN515-57 names kept so the shared code (config, daemon, app) compiles; all point at byte 0x00 (ECTM, the EC
    // version), which is harmless to read, and nothing is ever written on this branch.
    static let unknown: Int = 0x00
    static let battery = unknown, kbTimeout = unknown, usbCharge = unknown
    static let ledEffect = unknown, ledSpeed = unknown, ledBright = unknown, ledDir = unknown, ledColor = unknown, zoneColors = unknown
    static let gpuFanMode = unknown, cpuFanMode = unknown, nitroMode = unknown, cpuFanSpeed = unknown, gpuFanSpeed = unknown
    static let batteryStatus = unknown
}
func be16(_ ec: [UInt8], _ at: Int) -> Int { Int(ec[at]) << 8 | Int(ec[at + 1]) }
let readOnlyMessage = "read-only on the \(Reg.model): the fan and mode bytes of this EC are not identified yet (branch anv15-52-battery writes only the battery charge limit, through the firmware WMI)"

// The only call that passes the read-only gate of this branch: see Reg.batteryLimitWMI.
func isBatteryLimitCall(_ selector: NitroECSelector, _ opcode: UInt8, _ bytes: [UInt8]) -> Bool {
    guard Reg.batteryLimitWMI, selector.rawValue == kNitroECSelWMBE.rawValue, bytes.count >= 2, bytes[0] == 1, bytes[1] == 1 else { return false }
    switch opcode {
    case 0x14: return bytes.count == 2
    case 0x15: return bytes.count == 3 && bytes[2] <= 1
    default: return false
    }
}

func hex(_ v: UInt8) -> String { String(format: "0x%02X", v) }

func fanMode(_ v: UInt8, cpu: Bool) -> String {
    switch (cpu, v) {
    case (_, 0x00): return "Auto (EC default, never set)"
    case (true, 0x04), (false, 0x10): return "Auto"
    case (true, 0x08), (false, 0x20): return "Max"
    case (true, 0x0C), (false, 0x30): return "Manual"
    default: return "? \(hex(v))"
    }
}

func nitroMode(_ v: UInt8) -> String {
    switch v {
    case 0x00: return "Quiet"
    case 0x01: return "Default"
    case 0x04: return "Extreme"
    default: return "? \(hex(v))"
    }
}

func ledEffect(_ v: UInt8) -> String {
    switch v {
    case 0x00: return "Static"
    case 0x01: return "Breathing"
    case 0x02: return "Neon"
    case 0x03: return "Wave"
    case 0x04: return "Shifting"
    case 0x05: return "Zoom"
    case 0x06: return "Meteor"
    case 0x07: return "Twinkling"
    default: return "? \(hex(v))"
    }
}

func batteryStatus(_ v: UInt8) -> String {
    switch v {
    case 0x00: return "Idle"
    case 0x01: return "Discharging"
    case 0x02: return "Charging"
    default: return "? \(hex(v))"
    }
}

func rgb(_ ec: [UInt8], _ at: Int) -> String {
    String(format: "#%02X%02X%02X", ec[at], ec[at + 1], ec[at + 2])
}

func printStatus(_ ec: [UInt8]) {
    let extras = Reg.extraTemps.map { "\($0.0) \(ec[$0.1])" }.joined(separator: "  ")
    print("""
    \(Reg.model) EC (read-only branch; fields from an EC dump)
    Temperatures   CPU \(ec[Reg.cpuTemp]) °C (CTMP)   GPU? \(ec[Reg.gpuTemp]) °C (GTMP, unverified)   ETP1 \(ec[Reg.sysTemp])   \(extras) °C
    Fans           CPU \(be16(ec, Reg.cpuFanRPM)) RPM (0x5C, big-endian)   GPU \(be16(ec, Reg.gpuFanRPM)) RPM (0x6A)
    Power          AC \(ec[Reg.acStatus] & 0x01 == 1 ? "plugged" : "unplugged")   PL1 \(Double(be16(ec, Reg.pl1)) / 10) W   PL2 \(Double(be16(ec, Reg.pl2)) / 10) W
    Lid            \(ec[Reg.lid] & 0x40 != 0 ? "closed" : "open")   keyboard backlight bit \(ec[Reg.kbBacklight] & 0x01)
    Mode bytes     ACTP 0x6D = \(hex(ec[Reg.modeCandidateA]))   BTMD 0x70 = \(hex(ec[Reg.modeCandidateB]))   (candidates, meaning unknown: no mode or fan control here)
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

// MARK: - Fan control

enum FanUnit: CaseIterable {
    case cpu, gpu

    var modeReg: Int { self == .cpu ? Reg.cpuFanMode : Reg.gpuFanMode }
    var speedReg: Int { self == .cpu ? Reg.cpuFanSpeed : Reg.gpuFanSpeed }
    var auto: Int { self == .cpu ? 0x04 : 0x10 }
    var max: Int { self == .cpu ? 0x08 : 0x20 }
    var manual: Int { self == .cpu ? 0x0C : 0x30 }
    var wmbhGroup: UInt8 { self == .cpu ? 0x01 : 0x04 }
}

func setPSEE(_ ec: NitroEC, _ on: Bool) throws {
    let current = Int(try ec.readByte(UInt8(Reg.battery)))
    let wanted = on ? current | 0x10 : current & ~0x10
    if wanted != current {
        try ec.writeByte(Reg.battery, wanted)
    }
}

let safeTempLimit: UInt8 = 90

// Same order as OpeNitro: duty first, then mode. Duty is a percentage (firmware
// WMBH 0x10 rejects > 100). PSEE is raised first, as NitroSense's WMBH 0x05 does.
func setFan(_ ec: NitroEC, _ units: [FanUnit], mode: String, percent: Int?, viaWMI: Bool) throws {
    if mode == "manual" {
        guard let percent, (20...100).contains(percent) else {
            throw NitroECError(description: "manual speed must be 20-100 (%)")
        }
        let status = try ec.dump()
        let hottest = max(status[Reg.cpuTemp], status[Reg.gpuTemp])
        if hottest >= safeTempLimit && percent < 100 {
            throw NitroECError(description: "refusing manual \(percent)% at \(hottest) °C (limit \(safeTempLimit) °C); use 'max'")
        }
    }

    try setPSEE(ec, true)
    for unit in units {
        switch mode {
        case "auto":
            try ec.writeByte(unit.modeReg, unit.auto)
        case "max":
            try ec.writeByte(unit.modeReg, unit.max)
        case "manual":
            if viaWMI {
                let result = try ec.wmbh(0x10, [unit.wmbhGroup, UInt8(percent!)])
                guard result.first == 0 else {
                    throw NitroECError(description: "firmware WMBH 0x10 returned status \(result.first ?? 0xFF)")
                }
            } else {
                try ec.writeByte(unit.speedReg, percent!)
            }
            try ec.writeByte(unit.modeReg, unit.manual)
        default:
            throw NitroECError(description: "fan mode must be auto, max or manual")
        }
    }
}

// MARK: - Operating mode (OPMS 0x2C, set through firmware WMBH 0x16 sub 0x0B)

let nitroModes: [String: UInt8] = ["quiet": 0x00, "default": 0x01, "extreme": 0x04]

// The firmware nudges \ODV0 relative to its current value for Quiet (-1) and
// Extreme (+1) and resets it to \ODV1 for Default, so always pass through Default
// first to keep repeated calls from drifting.
func setNitroMode(_ ec: NitroEC, _ name: String) throws {
    guard let value = nitroModes[name] else {
        throw NitroECError(description: "mode must be quiet, default or extreme")
    }
    try checkWMBH(try ec.wmbh(0x16, [0x0B, 0x01]), "mode default")
    if value != 0x01 {
        try checkWMBH(try ec.wmbh(0x16, [0x0B, value]), "mode \(name)")
    }
}

// MARK: - Simple EC toggles (values whitelisted in the kext)

// USB charging while the laptop is off/asleep: EC 0x08, 0x0F on / 0x1F off.
func setUSBCharge(_ ec: NitroEC, _ on: Bool) throws {
    try ec.writeByte(Reg.usbCharge, on ? 0x0F : 0x1F)
}

// Keyboard backlight turns off after 30 s idle: EC 0x06, 0x1E on / 0x00 off.
func setKBTimeout(_ ec: NitroEC, _ on: Bool) throws {
    try ec.writeByte(Reg.kbTimeout, on ? 0x1E : 0x00)
}

// MARK: - Battery charge limit (firmware battery-health WMI, layout from Linuwu-Sense)

// Returns uFunctionStatus[0] (1 = 80 % limit on) from GetBatteryHealthControlStatus.
func batteryLimitStatus(_ ec: NitroEC) throws -> (on: Bool, raw: [UInt8]) {
    let raw = try ec.wmbe(0x14, [0x01, 0x01])
    guard raw.count >= 4 else {
        throw NitroECError(description: "unexpected battery-health reply: \(raw.map { hex($0) })")
    }
    return (raw[3] == 1, raw)
}

func setBatteryLimit(_ ec: NitroEC, _ on: Bool) throws {
    let reply = try ec.wmbe(0x15, [0x01, 0x01, on ? 1 : 0])
    guard reply.first == 0 else {
        throw NitroECError(description: "firmware rejected battery limit (\(reply.map { hex($0) }.joined(separator: " ")))")
    }
}

// MARK: - Keyboard LED (firmware WMBH 0x06 zone colour, 0x14 effect)

let ledEffects = ["static", "breathing", "neon", "wave", "shifting", "zoom", "meteor", "twinkling"]

struct LEDState {
    var effect: UInt8
    var speed: UInt8
    var brightness: UInt8
    var direction: UInt8
    var color: (UInt8, UInt8, UInt8)

    init(effect: UInt8, speed: UInt8, brightness: UInt8, direction: UInt8, color: (UInt8, UInt8, UInt8)) {
        self.effect = effect
        self.speed = speed
        self.brightness = brightness
        self.direction = direction
        self.color = color
    }

    init(_ ec: [UInt8]) {
        effect = ec[Reg.ledEffect]
        speed = ec[Reg.ledSpeed]
        brightness = ec[Reg.ledBright]
        direction = ec[Reg.ledDir]
        color = (ec[Reg.ledColor], ec[Reg.ledColor + 1], ec[Reg.ledColor + 2])
    }
}

func parseRGB(_ s: String) throws -> (UInt8, UInt8, UInt8) {
    let hexString = s.hasPrefix("#") ? String(s.dropFirst()) : s
    guard hexString.count == 6, let v = UInt32(hexString, radix: 16) else {
        throw NitroECError(description: "colour must be RRGGBB, got '\(s)'")
    }
    return (UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF))
}

func checkWMBH(_ result: [UInt8], _ what: String) throws {
    guard result.first == 0 else {
        throw NitroECError(description: "firmware rejected \(what) (status \(result.first.map { hex($0) } ?? "none"))")
    }
}

// AN515-57 only lights its 4-zone keyboard after GetGamingSysInfo (0x05) and
// SetGamingLED(keyboard, all zones) (0x02), as the JafarAkhondali Linux module does.
func initLED(_ ec: NitroEC) throws {
    _ = try ec.wmbh(0x05, [0x00])
    try checkWMBH(try ec.wmbh(0x02, [0x08, 0, 0, 0, 0, 0x0F]), "keyboard zone enable")
}

func applyLED(_ ec: NitroEC, _ led: LEDState) throws {
    // Some Nitro ECs reject speed 0, even for Static (see negihimanshu015/NitroSense-Linux).
    let speed = led.speed == 0 ? 5 : led.speed
    // 16-byte layout from facer_rgb.py: byte 3 = 8 for Wave, byte 9 = 1.
    var bytes = [UInt8](repeating: 0, count: 16)
    bytes[0] = led.effect
    bytes[1] = speed
    bytes[2] = led.brightness
    bytes[3] = led.effect == 3 ? 8 : 0
    bytes[4] = led.direction
    (bytes[5], bytes[6], bytes[7]) = led.color
    bytes[9] = 1
    try checkWMBH(try ec.wmbh(0x14, bytes), "LED effect")
}

