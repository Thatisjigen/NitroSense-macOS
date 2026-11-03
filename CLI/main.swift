import Foundation

// MARK: - main

let args = Array(CommandLine.arguments.dropFirst())
let usage = """
usage: nitroctl [status | dump | read <offset> | watch [seconds] | ecdiff | modes]
       sudo nitroctl firmware
       sudo nitroctl fan status|auto|max|custom <cpu %> <gpu %>
       sudo nitroctl usb status|0|10|20|30
       sudo nitroctl backlight status|on|off
       sudo nitroctl mode status|quiet|balance|performance
       sudo nitroctl kb status
       sudo nitroctl battery limit on|off|status
       sudo nitroctl wmbh <op> [hex bytes...]   (only the exact GET calls of this branch pass)
       nitroctl daemon [status | apply | firmware | fan auto|max | power quiet|balance|performance | battery [on|off]] [--json]
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write("nitroctl: \(message)\n".data(using: .utf8)!)
    exit(2)
}

// Prints what the firmware and the EC say about the power mode, without stopping on what cannot be read.
func printPowerMode(_ ec: NitroEC, _ label: String) {
    let fant = ((try? ec.dump())?[Reg.fanTable] ?? 0xFF) & 0x0F
    var line = "\(label) EC FANT \(fant): \(profileNameFromFANT(fant))"
    if let state = try? ec.modeState() { line += "   TUGM \(state[0])   CCOL \(state[1])   IDPF \(hex(state[2]))" }
    print(line)
}

// Runs one firmware write and says how it went; true if it failed.
func attempt(_ what: String, _ write: () throws -> Void) -> Bool {
    do {
        try write()
        print("\(what): firmware status 0")
        return false
    } catch {
        print("\(what) FAILED: \(error)")
        return true
    }
}

func printFans(_ ec: NitroEC, _ label: String) {
    func text(_ gpu: Bool) -> String {
        do {
            return fanBehaviorName(try readFanBehavior(ec, gpu: gpu))
        } catch {
            return "not readable (\(error))"
        }
    }
    var line = "\(label) CPU \(text(false))   GPU \(text(true))"
    if let d = try? ec.dump() { line += "   \(be16(d, Reg.cpuFanRPM)) / \(be16(d, Reg.gpuFanRPM)) RPM" }
    print(line)
}

// Learns for 5 s which EC bytes move by themselves, then prints every other byte that changes. Reads only, no root: press a
// key and see which byte follows it (keyboard light, mode key), or run a mode change in another window.
func ecDiff(_ ec: NitroEC) throws -> Never {
    setvbuf(stdout, nil, _IOLBF, 0)  // line by line, also through tee
    print("Learning for 5 s what moves by itself: touch nothing...")
    var last = try ec.dump()
    var noisy = Set<Int>()
    for _ in 0..<25 {
        Thread.sleep(forTimeInterval: 0.2)
        let now = try ec.dump()
        for i in 0..<now.count where now[i] != last[i] { noisy.insert(i) }
        last = now
    }
    print("Ignored because they moved: \(noisy.sorted().map { String(format: "%02X", $0) }.joined(separator: " "))")
    print("Now press the key. Ctrl-C to stop.")
    let clock = DateFormatter()
    clock.dateFormat = "HH:mm:ss"
    while true {
        Thread.sleep(forTimeInterval: 0.1)
        let now = try ec.dump()
        for i in 0..<now.count where now[i] != last[i] && !noisy.contains(i) {
            let name = Reg.names[i].map { " \($0)" } ?? ""
            print("\(clock.string(from: Date()))  0x\(String(format: "%02X", i))\(name): \(hex(last[i])) -> \(hex(now[i]))")
        }
        last = now
    }
}

// nitroctl daemon [status | apply | firmware | fan <mode> | power <mode> | battery [on|off]]   talk to nitrod (no sudo; admin group)
if args.first == "daemon" {
    do {
        let rawJSON = args.contains("--json")
        let dargs = args.filter { $0 != "--json" }
        var request: [String: Any] = ["cmd": dargs.count > 1 ? dargs[1] : "status"]
        if dargs.count > 2 { request["mode"] = dargs[2] }
        var reply = try nitrodRequest(request)
        if rawJSON {
            print(String(decoding: try JSONSerialization.data(withJSONObject: reply), as: UTF8.self))
            exit(reply["ok"] as? Bool == true ? 0 : 1)
        }
        let ecBytes = (reply.removeValue(forKey: "ec") as? [Int])?.map { UInt8($0) }
        let pretty = try JSONSerialization.data(withJSONObject: reply, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: pretty, as: UTF8.self))
        if let ecBytes, ecBytes.count == 256 { printStatus(ecBytes) }
        exit(reply["ok"] as? Bool == true ? 0 : 1)
    } catch {
        FileHandle.standardError.write("nitroctl: \(error)\n".data(using: .utf8)!)
        exit(1)
    }
}

do {
    let ec = try NitroEC()
    switch args.first ?? "status" {
    case "status":
        printStatus(try ec.dump())
    case "dump":
        printDump(try ec.dump())
    case "read":
        guard args.count == 2, let offset = parseOffset(args[1]) else { fail(usage) }
        print("\(hex(offset)) = \(hex(try ec.readByte(offset)))")
    case "watch":
        let interval = args.count > 1 ? (Double(args[1]) ?? 1) : 1
        while true {
            print("\u{1B}[2J\u{1B}[H", terminator: "")
            printStatus(try ec.dump())
            Thread.sleep(forTimeInterval: max(interval, 0.2))
        }
    case "ecdiff":
        try ecDiff(ec)
    case "modes":
        printModeState(try ec.modeState())
    case "firmware":
        printFirmware(FirmwareReading(ec))
        do {
            let (on, raw) = try batteryLimitStatus(ec)
            print("Charge limit   \(on ? "on" : "off")   (WMBE 0x14 reply \(raw.map { hex($0) }.joined(separator: " ")))")
        } catch {
            print("Charge limit   not readable (\(error))")
        }
    case "usb":
        guard args.count == 2 else { fail(usage) }
        if args[1] != "status" {
            guard let value = Int(args[1]), GamingWMI.usbChargeSet[value] != nil else { fail("usb takes status, 0, 10, 20 or 30") }
            print("Before \(try readUSBCharge(ec))")
            try setUSBCharge(ec, value)
            Thread.sleep(forTimeInterval: 0.5)
        }
        print("USB charging when powered off: \(try readUSBCharge(ec))   (0 off, otherwise the battery level it stops at)")
    case "backlight":
        guard args.count == 2 else { fail(usage) }
        if args[1] != "status" {
            guard args[1] == "on" || args[1] == "off" else { fail("backlight takes status, on or off") }
            print("Before \(try readKBTimeout(ec))")
            try setKBTimeout(ec, args[1] == "on")
            Thread.sleep(forTimeInterval: 0.5)
        }
        print("Backlight off after 30 s: \(try readKBTimeout(ec))")
    case "fan":
        if args.count == 4, args[1] == "custom" {
            guard let cpu = Int(args[2]), let gpu = Int(args[3]) else { fail("fan custom takes two percentages") }
            printFans(ec, "Before")
            let failure = attempt("Fan duty CPU \(cpu) %, GPU \(gpu) %") { try setFanCustom(ec, cpu: cpu, gpu: gpu) }
            Thread.sleep(forTimeInterval: 0.5)
            printFans(ec, "After ")
            print("'sudo nitroctl fan auto' gives the fans back to the EC. nitroctl does not watch the temperature; the app and nitrod do.")
            if failure { exit(1) }
            exit(0)
        }
        guard args.count == 2 else { fail(usage) }
        switch args[1] {
        case "status":
            printFans(ec, "Fan behaviour")
        case "auto", "max":
            // Reads first: a write that could not be read back would prove nothing.
            _ = try readFanBehavior(ec, gpu: false)
            _ = try readFanBehavior(ec, gpu: true)
            printFans(ec, "Before")
            // A refusal or an error is still followed by the read-back: the firmware may have moved anyway.
            let failure = attempt("SetGamingFanBehavior \(args[1])") { try setFanBehavior(ec, max: args[1] == "max") }
            Thread.sleep(forTimeInterval: 0.5)
            printFans(ec, "After ")
            if failure { exit(1) }
        default:
            fail("fan takes status, auto, max or custom <cpu %> <gpu %>")
        }
    case "mode":
        guard args.count == 2 else { fail(usage) }
        if args[1] == "status" {
            printPowerMode(ec, "Power mode")
        } else if let value = powerModes[args[1]] {
            printPowerMode(ec, "Before")
            let failure = attempt("Power mode \(profileName(value)) through TUGM and _Q30") { try setPlatformProfile(ec, value) }
            Thread.sleep(forTimeInterval: 0.5)
            printPowerMode(ec, "After ")
            if failure { exit(1) }
        } else {
            fail("mode takes status, quiet, balance or performance")
        }
    case "kb":
        guard args.count == 2, args[1] == "status" else {
            fail("kb takes status only: this keyboard is single-colour and the Fn keys drive it; no write route is verified on the \(Reg.model)")
        }
        let reply = try ec.wmbh(GamingWMI.getKBBacklight, [1])
        print("GetGamingKBBacklight reply: \(reply.map { hex($0) }.joined(separator: " "))")
        print("(first byte is the firmware status, \(reply.first.map(firmwareStatusText) ?? "none"); then mode, speed, brightness, 0, direction, R, G, B in the layout Linuwu-Sense uses on RGB models)")
        print("EC: KBBL bit \(try ec.readByte(UInt8(Reg.kbBacklight)) & 0x01)")
    case "battery":
        guard args.count == 3, args[1] == "limit", ["on", "off", "status"].contains(args[2]) else { fail(usage) }
        if args[2] != "status" {
            _ = try batteryLimitStatus(ec)  // reads first, as for the fans and the mode
            try setBatteryLimit(ec, args[2] == "on")
        }
        let (on, raw) = try batteryLimitStatus(ec)
        // ANV15-52: no EC byte is known to mirror the limit (0x03 is an AN515-57 field), so only the firmware reply is shown.
        print("80% charge limit: \(on ? "on" : "off")   (WMBE 0x14 reply \(raw.map { hex($0) }.joined(separator: " ")))")
    case "wmbh":
        guard args.count >= 2, let op = parseOffset(args[1]) else { fail(usage) }
        guard ![GamingWMI.setFanBehavior, GamingWMI.setMisc].contains(op) else {
            fail("the writes go through 'fan' and 'mode', which read first and read back")
        }
        let bytes = args.dropFirst(2).compactMap { UInt8($0.lowercased().replacingOccurrences(of: "0x", with: ""), radix: 16) }
        let result = try ec.wmbh(op, bytes)
        print("WMBH \(hex(op)) [\(bytes.map { hex($0) }.joined(separator: " "))] -> \(result.map { hex($0) }.joined(separator: " "))")
    case "led":
        fail("this keyboard is single-colour: no colours, zones or effects exist on the \(Reg.model). 'sudo nitroctl kb status' reads what the firmware reports")
    case "psee", "usb-charge", "kb-timeout":
        fail("'\(args[0])' is an AN515-57 EC field: nothing of the kind is verified on the \(Reg.model), and no EC byte is written on this branch")
    default:
        print(usage)
        exit(2)
    }
} catch {
    FileHandle.standardError.write("nitroctl: \(error)\n".data(using: .utf8)!)
    exit(1)
}
