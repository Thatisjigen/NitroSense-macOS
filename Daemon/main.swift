// nitrod — root LaunchDaemon for NitroEC.kext
//
// Keeps NitroConfig in /Library/Application Support/NitroSense/config.json and
// re-applies it at start and after wake (the keyboard controller and PSEE reset on
// boot). Runs the fan curve every 2 s with a failsafe (fan.failsafeTemp, default
// 95 °C: both fans max until 10 °C below). Puts fans back to Auto on exit. Clients talk to it over
// /var/run/nitrod.sock (root:admin 0660), one JSON request per connection:
//   {"cmd":"status"}                     -> config, live EC dump, failsafe, duties
//   {"cmd":"set","config":{...partial}}  -> merge, validate, save, apply
//   {"cmd":"apply"}                      -> re-apply everything

import Foundation
import IOKit
import IOKit.pwr_mgt

let tickInterval = 2.0
let lowerAfterTicks = 5  // curve lowers duty only after 10 s below the current step

func log(_ message: String) {
    let stamp = ISO8601DateFormatter().string(from: Date())
    FileHandle.standardError.write("\(stamp) nitrod: \(message)\n".data(using: .utf8)!)
}

// CPU package power from a long-running `powermetrics --samplers cpu_power` child
// ("Intel energy model derived package power (CPUs+GT+SA): 26.57W"). Restarts it if it exits.
final class PowerMeter {
    private var process: Process?
    private var buffer = Data()
    private let onSample: (Double) -> Void
    private var stopped = false

    init(onSample: @escaping (Double) -> Void) {
        self.onSample = onSample
    }

    func start() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/powermetrics")
        p.arguments = ["-i", "2000", "--samplers", "cpu_power"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard let self, !data.isEmpty else { return }
            self.buffer.append(data)
            while let nl = self.buffer.firstIndex(of: 0x0A) {
                let line = String(decoding: self.buffer[self.buffer.startIndex..<nl], as: UTF8.self)
                self.buffer.removeSubrange(self.buffer.startIndex...nl)
                guard line.hasPrefix("Intel energy model derived package power"),
                      let value = line.split(separator: ":").last.map({ $0.trimmingCharacters(in: .whitespaces) }),
                      let watts = Double(value.replacingOccurrences(of: "W", with: "")) else { continue }
                DispatchQueue.main.async { self.onSample(watts) }
            }
        }
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
                guard let self, !self.stopped else { return }
                log("powermetrics exited, restarting")
                self.start()
            }
        }
        do {
            try p.run()
            process = p
        } catch {
            log("powermetrics: \(error)")
        }
    }

    func stop() {
        stopped = true
        process?.terminate()
    }
}

final class Daemon {
    let ec: NitroEC
    var config: NitroConfig
    var failsafe = false
    var duty: [FanUnit: Int] = [:]      // last duty written by the curve
    var lowerCount: [FanUnit: Int] = [:]
    var cpuPower: Double?
    var cpuPowerAt = Date.distantPast
    lazy var powerMeter = PowerMeter { [weak self] watts in
        self?.cpuPower = watts
        self?.cpuPowerAt = Date()
    }

    init(ec: NitroEC) {
        self.ec = ec
        if let data = FileManager.default.contents(atPath: nitrodConfigPath),
           let saved = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let cfg = try? NitroConfig().merged(with: saved), (try? cfg.validate()) != nil {
            config = cfg
            log("loaded \(nitrodConfigPath)")
        } else {
            config = (try? ec.dump()).map { NitroConfig(fromEC: $0) } ?? NitroConfig()
            log("no valid config, seeded from EC")
            save()
        }
    }

    func save() {
        do {
            try FileManager.default.createDirectory(atPath: nitrodConfigDir, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(config).write(to: URL(fileURLWithPath: nitrodConfigPath), options: .atomic)
        } catch {
            log("save failed: \(error)")
        }
    }

    func step(_ what: String, _ body: () throws -> Void) {
        do { try body() } catch { log("\(what): \(error)") }
    }

    // Everything the firmware forgets across boot/sleep. Each step is independent.
    func applyAll(reason: String) {
        // Branch anv15-52-battery: nothing is re-applied at start, wake or SIGHUP, the battery limit included; the firmware
        // keeps that one by itself and the user sets it by hand with 'sudo nitroctl battery limit on|off'.
        if Reg.readOnlyModel { log("apply (\(reason)): skipped, \(readOnlyMessage)"); return }
        log("apply (\(reason))")
        step("psee") { try setPSEE(ec, true) }
        step("mode") { try setNitroMode(ec, config.nitroMode) }
        step("battery limit") { try setBatteryLimit(ec, config.batteryLimit) }
        step("usb charge") { try setUSBCharge(ec, config.usbCharge) }
        step("kb timeout") { try setKBTimeout(ec, config.kbTimeout) }
        step("led") { try applyLEDConfig() }
        applyFans()
    }

    func applyLEDConfig() throws {
        let led = config.led
        try initLED(ec)
        try applyLED(ec, LEDState(effect: UInt8(ledEffects.firstIndex(of: led.effect) ?? 0),
                                  speed: UInt8(led.speed), brightness: UInt8(led.brightness),
                                  direction: UInt8(led.direction), color: try parseRGB(led.color)))
        if led.effect == "static" {
            for (i, zone) in led.zones.enumerated() {
                let (r, g, b) = try parseRGB(zone)
                try checkWMBH(try ec.wmbh(0x06, [UInt8(1 << i), r, g, b]), "zone colour")
            }
        }
    }

    func setUnit(_ unit: FanUnit, manualPercent percent: Int) throws {
        try ec.writeByte(unit.speedReg, percent)
        if Int(try ec.readByte(UInt8(unit.modeReg))) != unit.manual {
            try ec.writeByte(unit.modeReg, unit.manual)
        }
        duty[unit] = percent
    }

    func curveDrives(_ unit: FanUnit) -> Bool { unit == .cpu || config.fan.curveGPU }

    func applyFans() {
        if Reg.readOnlyModel { return }
        duty = [:]
        lowerCount = [:]
        if failsafe { return }
        step("fans") {
            try setPSEE(ec, true)
            for unit in FanUnit.allCases {
                switch config.fan.mode {
                case "max":
                    try ec.writeByte(unit.modeReg, unit.max)
                case "manual":
                    try setUnit(unit, manualPercent: unit == .cpu ? config.fan.cpuPercent : config.fan.gpuPercent)
                case "curve":
                    if !curveDrives(unit) { try ec.writeByte(unit.modeReg, unit.auto) }
                    // otherwise the next tick picks the duty
                default:
                    try ec.writeByte(unit.modeReg, unit.auto)
                }
            }
        }
        if config.fan.mode == "curve" { tick() }
    }

    func tick() {
        if Reg.readOnlyModel { return }   // no curve, no failsafe writes: this branch only reads
        guard let d = try? ec.dump() else { return }
        let temps: [FanUnit: UInt8] = [.cpu: d[Reg.cpuTemp], .gpu: d[Reg.gpuTemp]]
        let hottest = max(temps[.cpu]!, temps[.gpu]!)

        let failsafeOn = UInt8(config.fan.failsafeTemp)
        let failsafeOff = failsafeOn - 10
        if !failsafe && hottest >= failsafeOn {
            failsafe = true
            log("failsafe ON at \(hottest) °C: fans max")
        } else if failsafe && hottest <= failsafeOff {
            failsafe = false
            log("failsafe OFF at \(hottest) °C: back to \(config.fan.mode)")
            applyFans()
            return
        }
        if failsafe {
            step("failsafe") {
                try setPSEE(ec, true)
                for unit in FanUnit.allCases where Int(d[unit.modeReg]) != unit.max {
                    try ec.writeByte(unit.modeReg, unit.max)
                }
            }
            return
        }

        guard config.fan.mode == "curve" else { return }
        step("curve") {
            if d[Reg.battery] & 0x10 == 0 { try setPSEE(ec, true) }
            for unit in FanUnit.allCases where curveDrives(unit) {
                let target = curvePercent(config.fan.curve, Int(temps[unit]!))
                let current = duty[unit]
                // Someone else (nitroctl, EC after wake) changed the mode: take it back.
                let modeLost = Int(d[unit.modeReg]) != unit.manual
                if current == nil || target > current! || modeLost {
                    try setUnit(unit, manualPercent: target)
                    lowerCount[unit] = 0
                } else if target < current! {
                    lowerCount[unit, default: 0] += 1
                    if lowerCount[unit]! >= lowerAfterTicks {
                        try setUnit(unit, manualPercent: target)
                        lowerCount[unit] = 0
                    }
                } else {
                    lowerCount[unit] = 0
                }
            }
        }
    }

    func shutdown() {
        log("stopping: fans back to Auto")
        powerMeter.stop()
        for unit in FanUnit.allCases {
            _ = try? ec.writeByte(unit.modeReg, unit.auto)
        }
        unlink(nitrodSocketPath)
        exit(0)
    }

    // MARK: socket requests

    func statusReply() -> [String: Any] {
        var reply: [String: Any] = ["ok": true, "failsafe": failsafe]
        if let data = try? JSONEncoder().encode(config), let obj = try? JSONSerialization.jsonObject(with: data) {
            reply["config"] = obj
        }
        reply["duty"] = ["cpu": duty[.cpu].map { $0 as Any } ?? NSNull(), "gpu": duty[.gpu].map { $0 as Any } ?? NSNull()]
        if let d = try? ec.dump() { reply["ec"] = d.map { Int($0) } }
        if let cpuPower, Date().timeIntervalSince(cpuPowerAt) < 6 { reply["cpuPower"] = cpuPower }
        return reply
    }

    func handle(_ request: [String: Any]) -> [String: Any] {
        switch request["cmd"] as? String {
        case "status":
            return statusReply()
        case "apply":
            applyAll(reason: "client")
            return statusReply()
        case "set":
            guard let patch = request["config"] as? [String: Any] else {
                return ["ok": false, "error": "set needs a config object"]
            }
            do {
                if Reg.readOnlyModel, let wanted = patch["batteryLimit"] as? Bool, wanted != config.batteryLimit {
                    return ["ok": false, "error": "nitrod does not write on the \(Reg.model): set the charge limit with 'sudo nitroctl battery limit on|off'"]
                }
                let next = try config.merged(with: patch)
                try next.validate()
                let old = config
                config = next
                save()
                if old.nitroMode != next.nitroMode { step("mode") { try setNitroMode(ec, next.nitroMode) } }
                // batteryLimit changes are refused above on this branch: nitrod has no write path to the firmware.
                if old.usbCharge != next.usbCharge { step("usb charge") { try setUSBCharge(ec, next.usbCharge) } }
                if old.kbTimeout != next.kbTimeout { step("kb timeout") { try setKBTimeout(ec, next.kbTimeout) } }
                if old.led != next.led { step("led") { try applyLEDConfig() } }
                if old.fan != next.fan { applyFans() }
                log("config updated")
                return statusReply()
            } catch {
                return ["ok": false, "error": "\(error)"]
            }
        default:
            return ["ok": false, "error": "cmd must be status, set or apply"]
        }
    }
}

// MARK: - Socket server (root:admin 0660)

func serveClient(_ fd: Int32, _ daemon: Daemon) {
    defer { close(fd) }
    var timeout = timeval(tv_sec: 2, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    var data = Data()
    var chunk = [UInt8](repeating: 0, count: 4096)
    while data.count < 65536, !data.contains(0x0A) {
        let n = read(fd, &chunk, chunk.count)
        if n <= 0 { break }
        data.append(contentsOf: chunk[0..<n])
    }
    let reply: [String: Any]
    if let req = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        reply = daemon.handle(req)
    } else {
        reply = ["ok": false, "error": "request must be one JSON object"]
    }
    if let out = try? JSONSerialization.data(withJSONObject: reply) {
        _ = out.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    }
}

func startServer(_ daemon: Daemon) -> DispatchSourceRead? {
    unlink(nitrodSocketPath)
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &addr.sun_path) { buf in
        for (i, b) in nitrodSocketPath.utf8.prefix(buf.count - 1).enumerated() { buf[i] = b }
    }
    let bound = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard fd >= 0, bound == 0, listen(fd, 8) == 0 else {
        log("socket setup failed: \(String(cString: strerror(errno)))")
        return nil
    }
    chown(nitrodSocketPath, 0, 80)  // gid 80 = admin
    chmod(nitrodSocketPath, 0o660)
    let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
    source.setEventHandler {
        let client = accept(fd, nil, nil)
        if client >= 0 { serveClient(client, daemon) }
    }
    source.resume()
    return source
}

// MARK: - Sleep/wake

var rootPort: io_connect_t = 0
let msgCanSystemSleep: UInt32 = 0xE000_0270
let msgSystemWillSleep: UInt32 = 0xE000_0280
let msgSystemHasPoweredOn: UInt32 = 0xE000_0300

func registerPower(_ daemon: Daemon) {
    var notifier: io_object_t = 0
    var port: IONotificationPortRef?
    let refcon = Unmanaged.passUnretained(daemon).toOpaque()
    rootPort = IORegisterForSystemPower(refcon, &port, { refcon, _, messageType, argument in
        let daemon = Unmanaged<Daemon>.fromOpaque(refcon!).takeUnretainedValue()
        switch messageType {
        case msgCanSystemSleep, msgSystemWillSleep:
            IOAllowPowerChange(rootPort, Int(bitPattern: argument))
        case msgSystemHasPoweredOn:
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { daemon.applyAll(reason: "wake") }
        default:
            break
        }
    }, &notifier)
    if rootPort == 0 {
        log("IORegisterForSystemPower failed; no re-apply on wake")
        return
    }
    IONotificationPortSetDispatchQueue(port, .main)
}

// MARK: - main

var ec: NitroEC?
while ec == nil {
    do {
        ec = try NitroEC()
    } catch {
        log("\(error); retrying in 5 s")
        Thread.sleep(forTimeInterval: 5)
    }
}

let daemon = Daemon(ec: ec!)
daemon.applyAll(reason: "start")
daemon.powerMeter.start()
let server = startServer(daemon)
registerPower(daemon)

var signalSources: [DispatchSourceSignal] = []
for sig in [SIGTERM, SIGINT, SIGHUP] {
    signal(sig, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    source.setEventHandler {
        if sig == SIGHUP { daemon.applyAll(reason: "SIGHUP") } else { daemon.shutdown() }
    }
    source.resume()
    signalSources.append(source)
}

let timer = DispatchSource.makeTimerSource(queue: .main)
timer.schedule(deadline: .now() + tickInterval, repeating: tickInterval)
timer.setEventHandler { daemon.tick() }
timer.resume()

log("running (fan mode \(daemon.config.fan.mode))")
withExtendedLifetime((server, timer, signalSources)) {
    dispatchMain()
}
