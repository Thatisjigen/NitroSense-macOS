import Foundation

// MARK: - main

let args = Array(CommandLine.arguments.dropFirst())
let usage = "usage: nitroctl [status | dump | read <offset> | watch [seconds]]\n       sudo nitroctl fan [--wmi] [cpu|gpu|all] auto|max|manual <20-100>\n       sudo nitroctl psee on|off\n       sudo nitroctl wmbh <op> [hex bytes...]\n       sudo nitroctl mode quiet|default|extreme\n       sudo nitroctl battery limit on|off|status\n       sudo nitroctl led init | restore | zone <1-4|all> <RRGGBB> | effect <name> [speed] [RRGGBB] [dir1|dir2] | brightness <0-100> | off\n       sudo nitroctl usb-charge on|off\n       sudo nitroctl kb-timeout on|off\n       nitroctl daemon [status | apply | set '<json>'] [--json]"

func ledCommand(_ ec: NitroEC, _ args: [String]) throws {
    guard let sub = args.first else {
        throw NitroECError(description: usage)
    }
    try initLED(ec)
    var led = LEDState(try ec.dump())

    switch sub {
    case "init":
        let state = try ec.wmbh(0x04, [0x08])
        print("SetGamingLED done; GetGamingLED -> \(state.map { hex($0) }.joined(separator: " "))")
    case "restore":
        // The keyboard controller resets to the BIOS default (red) on some boots while
        // EC RAM keeps the last values written, so re-send the stored state.
        let ec0 = try ec.dump()
        try applyLED(ec, led)
        if led.effect == 0 {
            for i in 0..<4 {
                let o = Reg.zoneColors + i * 3
                try checkWMBH(try ec.wmbh(0x06, [UInt8(1 << i), ec0[o], ec0[o + 1], ec0[o + 2]]), "zone colour")
            }
        }
        print("LED restored from EC: effect \(ledEffect(led.effect)), brightness \(led.brightness)")
    case "zone":
        guard args.count == 3 else { throw NitroECError(description: usage) }
        let zones: [UInt8]
        if args[1] == "all" {
            zones = [1, 2, 4, 8]
        } else if let n = Int(args[1]), (1...4).contains(n) {
            zones = [UInt8(1 << (n - 1))]
        } else {
            throw NitroECError(description: "zone must be 1-4 or all")
        }
        let (r, g, b) = try parseRGB(args[2])
        if led.effect != 0 || led.brightness == 0 {
            led.effect = 0
            if led.brightness == 0 { led.brightness = 100 }
            try applyLED(ec, led)
        }
        for zone in zones {
            try checkWMBH(try ec.wmbh(0x06, [zone, r, g, b]), "zone colour")
        }
    case "effect":
        guard args.count >= 2, let index = ledEffects.firstIndex(of: args[1].lowercased()) else {
            throw NitroECError(description: "effect must be one of: \(ledEffects.joined(separator: " "))")
        }
        led.effect = UInt8(index)
        for extra in args.dropFirst(2) {
            if let n = UInt8(extra), (1...9).contains(n) {
                led.speed = n
            } else if extra == "dir1" || extra == "dir2" {
                led.direction = extra == "dir1" ? 1 : 2
            } else {
                led.color = try parseRGB(extra)
            }
        }
        if led.brightness == 0 { led.brightness = 100 }
        try applyLED(ec, led)
    case "brightness":
        guard args.count == 2, let n = UInt8(args[1]), n <= 100 else {
            throw NitroECError(description: "brightness must be 0-100")
        }
        led.brightness = n
        try applyLED(ec, led)
    case "off":
        led.brightness = 0
        try applyLED(ec, led)
    default:
        throw NitroECError(description: usage)
    }
}

// nitroctl daemon [status | apply | set '<json>']   talk to nitrod (no sudo; admin group)
if args.first == "daemon" {
    do {
        let rawJSON = args.contains("--json")
        let dargs = args.filter { $0 != "--json" }
        var request: [String: Any] = ["cmd": dargs.count > 1 ? dargs[1] : "status"]
        if dargs.count > 2 {
            guard let patch = try JSONSerialization.jsonObject(with: Data(dargs[2].utf8)) as? [String: Any] else {
                throw NitroECError(description: "set needs a JSON object, e.g. '{\"fan\":{\"mode\":\"curve\"}}'")
            }
            request["config"] = patch
        }
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
        guard args.count == 2, let offset = parseOffset(args[1]) else {
            print(usage)
            exit(2)
        }
        print("\(hex(offset)) = \(hex(try ec.readByte(offset)))")
    case "fan":
        var rest = Array(args.dropFirst())
        let viaWMI = rest.first == "--wmi"
        if viaWMI { rest.removeFirst() }
        var units = FanUnit.allCases
        if let first = rest.first, ["cpu", "gpu", "all"].contains(first) {
            units = first == "cpu" ? [.cpu] : first == "gpu" ? [.gpu] : FanUnit.allCases
            rest.removeFirst()
        }
        guard let mode = rest.first else {
            print(usage)
            exit(2)
        }
        try setFan(ec, units, mode: mode, percent: rest.count > 1 ? Int(rest[1]) : nil, viaWMI: viaWMI)
        printStatus(try ec.dump())
    case "psee":
        guard args.count == 2, ["on", "off"].contains(args[1]) else {
            print(usage)
            exit(2)
        }
        try setPSEE(ec, args[1] == "on")
        print("PSEE \(args[1]) (0x03 = \(hex(try ec.readByte(UInt8(Reg.battery)))))")
    case "mode":
        guard args.count == 2 else {
            print(usage)
            exit(2)
        }
        try setNitroMode(ec, args[1].lowercased())
        printStatus(try ec.dump())
    case "battery":
        guard args.count == 3, args[1] == "limit", ["on", "off", "status"].contains(args[2]) else {
            print(usage)
            exit(2)
        }
        if args[2] != "status" {
            try setBatteryLimit(ec, args[2] == "on")
        }
        let (on, raw) = try batteryLimitStatus(ec)
        // ANV15-52: no EC byte is known to mirror the limit (0x03 is an AN515-57 field), so only the firmware reply is shown.
        print("80% charge limit: \(on ? "on" : "off")   (WMBE 0x14 reply \(raw.map { hex($0) }.joined(separator: " ")))")
    case "usb-charge", "kb-timeout":
        guard args.count == 2, ["on", "off"].contains(args[1]) else {
            print(usage)
            exit(2)
        }
        if args[0] == "usb-charge" {
            try setUSBCharge(ec, args[1] == "on")
        } else {
            try setKBTimeout(ec, args[1] == "on")
        }
        let ecNow = try ec.dump()
        print("USB off-charge \(hex(ecNow[Reg.usbCharge]))   KB timeout \(hex(ecNow[Reg.kbTimeout]))")
    case "led":
        try ledCommand(ec, Array(args.dropFirst()))
        printStatus(try ec.dump())
    case "wmbh":
        guard args.count >= 2, let op = parseOffset(args[1]) else {
            print(usage)
            exit(2)
        }
        let bytes = args.dropFirst(2).compactMap { UInt8($0.lowercased().replacingOccurrences(of: "0x", with: ""), radix: 16) }
        let result = try ec.wmbh(op, bytes)
        print("WMBH \(hex(op)) [\(bytes.map { hex($0) }.joined(separator: " "))] -> \(result.map { hex($0) }.joined(separator: " "))")
    case "watch":
        let interval = args.count > 1 ? (Double(args[1]) ?? 1) : 1
        while true {
            print("\u{1B}[2J\u{1B}[H", terminator: "")
            printStatus(try ec.dump())
            Thread.sleep(forTimeInterval: max(interval, 0.2))
        }
    default:
        print(usage)
        exit(2)
    }
} catch {
    FileHandle.standardError.write("nitroctl: \(error)\n".data(using: .utf8)!)
    exit(1)
}
