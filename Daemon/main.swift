// nitrod — root LaunchDaemon for NitroEC.kext, ANV15-52 branch
//
// Serves the app and nitroctl over /var/run/nitrod.sock (root:admin 0660), one JSON request per connection, and reads the
// CPU package power from powermetrics:
//   {"cmd":"status"}                 -> config, live EC dump, mode fields, last firmware reading, CPU power. No firmware call.
//   {"cmd":"firmware"}               -> runs the GET calls, once every few seconds at most
//   {"cmd":"fan","mode":"auto|max"}  -> SetGamingFanBehavior, then read back; the choice is remembered
//   {"cmd":"fan","mode":"custom","cpu":N,"gpu":N} -> manual duty, 30 to 100 %; remembered; back to Auto if it runs hot
//   {"cmd":"usb","value":0|10|20|30} -> USB charging when powered off, read back
//   {"cmd":"backlight","mode":"on|off"} -> keyboard backlight off after 30 s, read back
//   {"cmd":"power","mode":"quiet|balance|performance"} -> TUGM and _Q30, then read back from FANT; the choice is remembered
//     (both refused until the matching GET has answered: a write that cannot be read back proves nothing)
//   {"cmd":"battery"}                -> reads the 80 % charge limit (WMBE 0x14), once every few seconds at most
//   {"cmd":"battery","mode":"on|off"} -> sets it (WMBE 0x15) and reads it back; works with the battery-limit kext and SSDT too
//   {"cmd":"apply"}                  -> re-apply what the user chose
//
// Nothing has been tested on this board, so nitrod never calls the firmware by itself until the user chose a setting with
// this version: no write, and no read either, at start or at wake. After that it re-applies only that choice, at start
// and after wake: it reads first and writes only if the firmware moved. There is no curve: in Auto the EC keeps its own fan
// control, Max can only cool more, and with a manual duty nitrod goes back to Auto if the CPU or the RTX runs hot. When it
// stops, it brings the fans back to Auto if it took them off.
// No byte of the EC is written. The charge limit is never re-applied at all: the firmware keeps it across reboots, so it
// changes only when the user asks for it, and what is reported comes from the firmware's reply, never from config.json.

import Foundation
import IOKit
import IOKit.pwr_mgt

// Every firmware call is an SMI: a stuck client must not be able to hammer them.
let minFirmwareReadInterval = 3.0
let minFirmwareCommandInterval = 1.0

func log(_ message: String) {
    let stamp = ISO8601DateFormatter().string(from: Date())
    FileHandle.standardError.write("\(stamp) nitrod: \(message)\n".data(using: .utf8)!)
}

// CPU package power from a long-running `powermetrics --samplers cpu_power` child
// ("Intel energy model derived package power (CPUs+GT+SA): 26.57W", and "GPU Active: 4.07%" for the Iris Xe, a hardware residency
// that does not depend on the driver's statistics, which stay at 0 here). Restarts it if it exits.
final class PowerMeter {
    private var process: Process?
    private var buffer = Data()
    private let onSample: (Double) -> Void
    private let onGPUActive: (Double) -> Void
    private var stopped = false

    init(onSample: @escaping (Double) -> Void, onGPUActive: @escaping (Double) -> Void) {
        self.onSample = onSample
        self.onGPUActive = onGPUActive
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
                if line.hasPrefix("GPU Active:") {
                    let value = line.dropFirst("GPU Active:".count).trimmingCharacters(in: .whitespaces)
                    if let percent = Double(value.replacingOccurrences(of: "%", with: "")) {
                        DispatchQueue.main.async { self.onGPUActive(percent) }
                    }
                    continue
                }
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

    // The termination handler starts it again.
    func restart() {
        process?.terminate()
    }

    func stop() {
        stopped = true
        process?.terminate()
    }
}

final class Daemon {
    let ec: NitroEC
    var config: NitroConfig
    var firmware: FirmwareReading?
    var lastFirmwareRead = Date.distantPast
    var lastFirmwareCommand = Date.distantPast
    var fanOffAuto = false              // the fans are off Auto because of this daemon
    var hotTicks = 0                    // manual duty: consecutive samples over the limits
    var fanWatch: DispatchSourceTimer?
    var batteryLimit: BatteryLimitReading?
    var lastBatteryRead = Date.distantPast
    var cpuPower: Double?
    var cpuPowerAt = Date.distantPast
    var igpuChecks = 0
    var igpuActive: Double?
    var igpuActiveAt = Date.distantPast
    let pcuMeter = PCUMeter()
    lazy var hasPCU = nitroECOffers("NitroEC PCU")
    var curveSent: (cpu: Int, gpu: Int)?  // the duties the curve last sent; nil while the firmware's Auto runs
    let smc = SMCReader()
    lazy var powerMeter = PowerMeter(onSample: { [weak self] watts in
        self?.cpuPower = watts
        self?.cpuPowerAt = Date()
    }, onGPUActive: { [weak self] percent in
        self?.igpuActive = percent
        self?.igpuActiveAt = Date()
    })

    init(ec: NitroEC) {
        self.ec = ec
        if let data = FileManager.default.contents(atPath: nitrodConfigPath),
           let saved = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let cfg = try? NitroConfig().merged(with: saved), (try? cfg.validate()) != nil {
            config = cfg
            if config.fan.curve == upstreamDefaultCurve { config.fan.curve = FanConfig().curve }
            log("loaded \(nitrodConfigPath); user choices: fan '\(cfg.userFan)', power '\(cfg.userMode)'")
        } else {
            config = NitroConfig()
            log("no valid config, starting from defaults")
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

    var gamingWMI: Bool { nitroECOffers("NitroEC Gaming WMI") }
    var batteryWMI: Bool { nitroECOffers("NitroEC Battery WMI") }

    // The firmware's answer, or the error. A failed read forgets the last answer: it may no longer be true.
    @discardableResult
    func readBatteryLimit() -> String? {
        lastBatteryRead = Date()
        do {
            let (on, raw) = try batteryLimitStatus(ec)
            batteryLimit = BatteryLimitReading(on: on, raw: raw.map(Int.init))
            return nil
        } catch {
            batteryLimit = nil
            log("battery limit read: \(error)")
            return "\(error)"
        }
    }

    func readFirmware() {
        let reading = FirmwareReading(ec)
        firmware = reading
        lastFirmwareRead = Date()
        if (reading.fanCPU != nil && reading.fanGPU != nil) || reading.profile != nil, !config.firmwareReadOK {
            config.firmwareReadOK = true
            save()
        }
        log("firmware read: fans \(reading.fanSummary), power mode \(reading.profile.map { profileName(UInt8(truncatingIfNeeded: $0)) } ?? "not readable")\(reading.errors.isEmpty ? "" : "; \(reading.errors.count) errors: \(reading.errors.joined(separator: "; "))")")
    }

    // Only what the user chose with this version; reads first, writes only if the firmware moved. Nothing otherwise, not
    // even a read: a board on which this has never run stays untouched until the user tries it.
    func applyAll(reason: String) {
        guard !config.userFan.isEmpty || !config.userMode.isEmpty else {
            log("apply (\(reason)): nothing, no setting was chosen by the user with this version")
            return
        }
        guard gamingWMI else {
            log("apply (\(reason)): skipped, the loaded kext and SSDT offer no gaming WMI")
            return
        }
        if let wanted = powerModes[config.userMode] {
            do {
                let now = try currentProfile(ec)
                // A wake can reset PL1 and PL2 in the CPU without FANT showing it.
                if now != wanted || reason == "wake" {
                    log("apply (\(reason)): power mode \(profileName(now)) -> \(profileName(wanted))")
                    try setPlatformProfile(ec, wanted)
                }
            } catch {
                log("apply (\(reason)): power mode: \(error)")
            }
        }
        // The curve's next tick decides: it sends everything again after this.
        if config.userFan == "curve" {
            log("apply (\(reason)): fans follow the curve")
            curveSent = nil
            fanOffAuto = true
            checkFanCurve()
        } else if !config.userFan.isEmpty {
            let wanted = config.userFan == "custom" ? 3 : config.userFan == "max" ? 2 : 1
            do {
                let cpu = try readFanBehavior(ec, gpu: false), gpu = try readFanBehavior(ec, gpu: true)
                // 0 is the firmware's own default before anyone set it: that is Auto too, for a choice of Auto.
                let alreadyThere = wanted == 1 ? cpu <= 1 && gpu <= 1 : cpu == wanted && gpu == wanted
                if wanted == 3 {
                    // The firmware does not report the duty: it is sent again every time, and a wake may have reset it.
                    log("apply (\(reason)): fans at CPU \(config.userFanCPU) %, GPU \(config.userFanGPU) %")
                    try setFanCustom(ec, cpu: config.userFanCPU, gpu: config.userFanGPU)
                } else if !alreadyThere {
                    log("apply (\(reason)): fans CPU \(fanBehaviorName(cpu)), GPU \(fanBehaviorName(gpu)) -> \(fanBehaviorName(wanted))")
                    try setFanBehavior(ec, max: wanted != 1)
                }
                fanOffAuto = wanted != 1
            } catch {
                log("apply (\(reason)): fans: \(error)")
            }
        }
        readFirmware()
    }

    // With a manual duty the EC no longer decides the fans. Over these limits for three samples in a row they go back to Auto.
    func startFanWatch() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in
            self?.checkFanLimits()
            self?.checkFanCurve()
            self?.checkIGPUReading()
        }
        timer.resume()
        fanWatch = timer
    }

    // powermetrics started at boot, before the Iris Xe driver is up, leaves its GPU lines out for as long as it runs. Every 30 s,
    // for five minutes at most, start it again until one arrives.
    private func checkIGPUReading() {
        guard igpuActive == nil, igpuChecks < 60 else { return }
        igpuChecks += 1
        guard igpuChecks % 6 == 0 else { return }
        log("powermetrics: no GPU Active line yet, starting it again")
        powerMeter.restart()
    }

    // Curve: each fan follows its own temperature, CPU the CPU and GPU the RTX. Under the curve's first point for both, the firmware's
    // Auto, which runs slower than any manual duty. A duty goes down only 3 °C after it could: no back and forth around a step. Each
    // change is one SMI, so only changes are sent. A failure leaves the fans to Auto, for good until the user chooses again.
    private func checkFanCurve() {
        guard config.userFan == "curve", gamingWMI else { curveSent = nil; return }
        guard let dump = try? ec.dump() else { return }
        let cpuTemp = Int(dump[Reg.cpuTemp])
        guard cpuTemp > 0 else { return }
        // SMCNvidiaGPU binds to one NVRM build: after a driver update, until it is rebuilt too, the key does not answer. Then RM's page; with
        // no RTX reading at all, as hot as the CPU, on the safe side.
        let gpuTemp = smc?.temperature("TG0D") ?? readRTXTelemetry().tempC ?? cpuTemp
        let curve = config.fan.curve
        func wanted(_ temp: Int, _ now: Int?) -> Int? {
            let rising = curvePercent(curve, temp: temp)
            guard let now else { return rising }
            let falling = curvePercent(curve, temp: temp + 3) ?? GamingWMI.fanMinPercent
            return (rising ?? 0) > now ? rising : min(now, falling)
        }
        let cpu = wanted(cpuTemp, curveSent?.cpu), gpu = wanted(gpuTemp, curveSent?.gpu)
        do {
            if curveSent != nil, cpuTemp + 3 < curve[0].temp, gpuTemp + 3 < curve[0].temp {
                log("fan curve: CPU \(cpuTemp) C, RTX \(gpuTemp) C under the first point: Auto")
                try setFanBehavior(ec, max: false)
                curveSent = nil
                fanOffAuto = false
                readFirmware()
            } else if let sent = curveSent {
                let nextCPU = cpu ?? sent.cpu, nextGPU = gpu ?? sent.gpu
                if nextCPU != sent.cpu { try setFanSpeed(ec, gpu: false, percent: nextCPU) }
                if nextGPU != sent.gpu { try setFanSpeed(ec, gpu: true, percent: nextGPU) }
                if nextCPU != sent.cpu || nextGPU != sent.gpu { log("fan curve: CPU \(cpuTemp) C \(nextCPU) %, RTX \(gpuTemp) C \(nextGPU) %") }
                curveSent = (nextCPU, nextGPU)
            } else if cpu != nil || gpu != nil {
                // The other fan may be under the first point: both modes change together, so it takes the lowest duty there is.
                let nextCPU = cpu ?? GamingWMI.fanMinPercent, nextGPU = gpu ?? GamingWMI.fanMinPercent
                log("fan curve: CPU \(cpuTemp) C \(nextCPU) %, RTX \(gpuTemp) C \(nextGPU) %")
                try setFanCustom(ec, cpu: nextCPU, gpu: nextGPU)
                curveSent = (nextCPU, nextGPU)
                fanOffAuto = true
                readFirmware()
            } else if fanOffAuto {
                // Chosen, or back from a wake, under the first point.
                try setFanBehavior(ec, max: false)
                fanOffAuto = false
                readFirmware()
            }
        } catch {
            log("fan curve: \(error); back to Auto")
            do { try setFanBehavior(ec, max: false) } catch { log("fans back to Auto: \(error)") }
            curveSent = nil
            fanOffAuto = false
            config.userFan = "auto"
            save()
            readFirmware()
        }
    }

    private func checkFanLimits() {
        guard config.userFan == "custom", fanOffAuto else { hotTicks = 0; return }
        let cpu = (try? ec.dump())?[Reg.cpuTemp] ?? 0
        let rtx = smc?.temperature("TG0D") ?? readRTXTelemetry().tempC ?? 0
        hotTicks = cpu >= 95 || rtx >= 87 ? hotTicks + 1 : 0
        guard hotTicks >= 3 else { return }
        log("fan: CPU \(cpu) C, RTX \(rtx) C with a manual duty: back to Auto")
        hotTicks = 0
        do {
            try setFanBehavior(ec, max: false)
            fanOffAuto = false
            config.userFan = "auto"
            save()
            readFirmware()
        } catch {
            log("fans back to Auto: \(error)")
        }
    }

    func shutdown() {
        if fanOffAuto {
            log("stopping: fans back to Auto")
            do { try setFanBehavior(ec, max: false) } catch { log("fans back to Auto: \(error)") }
        }
        powerMeter.stop()
        unlink(nitrodSocketPath)
        exit(0)
    }

    // MARK: socket requests

    func statusReply() -> [String: Any] {
        var reply: [String: Any] = ["ok": true]
        if let data = try? JSONEncoder().encode(config), let obj = try? JSONSerialization.jsonObject(with: data) {
            reply["config"] = obj
        }
        if let d = try? ec.dump() { reply["ec"] = d.map { Int($0) } }
        if let cpuPower, Date().timeIntervalSince(cpuPowerAt) < 6 { reply["cpuPower"] = cpuPower }
        if let igpuActive, Date().timeIntervalSince(igpuActiveAt) < 6 { reply["igpuActive"] = igpuActive }
        if hasPCU, let pcu = pcuMeter.sample(ec) {
            var d: [String: Any] = ["raw": pcu.raw.map { Int($0) }]
            d["packageW"] = pcu.packageWatts; d["coreW"] = pcu.coreWatts; d["igpuW"] = pcu.igpuWatts
            d["packageT"] = pcu.packageTemp; d["coreT"] = pcu.coreTemp; d["igpuT"] = pcu.igpuTemp
            reply["pcu"] = d
        }
        var control: [String: Any] = ["gamingWMI": gamingWMI, "batteryWMI": batteryWMI, "firmwareReadOK": config.firmwareReadOK]
        if let batteryLimit, let data = try? JSONEncoder().encode(batteryLimit), let obj = try? JSONSerialization.jsonObject(with: data) {
            control["batteryLimit"] = obj
        }
        if let state = try? ec.modeState() { control["modeState"] = state.map { Int($0) } }
        if let firmware, let data = try? JSONEncoder().encode(firmware), let obj = try? JSONSerialization.jsonObject(with: data) {
            control["firmware"] = obj
        }
        reply["control"] = control
        return reply
    }

    func handle(_ request: [String: Any]) -> [String: Any] {
        switch request["cmd"] as? String {
        case "status":
            return statusReply()
        case "apply":
            guard commandAllowedNow() else { return tooSoon() }
            applyAll(reason: "client")
            return statusReply()
        case "firmware":
            guard gamingWMI else { return noGamingWMI() }
            if Date().timeIntervalSince(lastFirmwareRead) >= minFirmwareReadInterval { readFirmware() }
            return statusReply()
        case "fan":
            guard let mode = request["mode"] as? String, ["auto", "max", "custom", "curve"].contains(mode) else {
                return ["ok": false, "error": "fan mode must be auto, max, custom or curve"]
            }
            let cpuDuty = request["cpu"] as? Int ?? config.userFanCPU, gpuDuty = request["gpu"] as? Int ?? config.userFanGPU
            guard gamingWMI else { return noGamingWMI() }
            guard answered({ $0.fanCPU != nil && $0.fanGPU != nil }) else { return notRead("fan behaviour") }
            guard commandAllowedNow() else { return tooSoon() }
            do {
                if mode == "curve" {
                    // Its first tick sets the fans, from whatever state they are in.
                    config.userFan = mode
                    curveSent = nil
                    fanOffAuto = true
                    hotTicks = 0
                    save()
                    log("fan: curve, asked by a client")
                    checkFanCurve()
                    return statusReply()
                }
                if mode == "custom" {
                    try setFanCustom(ec, cpu: cpuDuty, gpu: gpuDuty)
                    config.userFanCPU = cpuDuty
                    config.userFanGPU = gpuDuty
                } else {
                    try setFanBehavior(ec, max: mode == "max")
                }
                fanOffAuto = mode != "auto"
                hotTicks = 0
                config.userFan = mode
                save()
                log("fan: \(mode)\(mode == "custom" ? " CPU \(cpuDuty) %, GPU \(gpuDuty) %" : ""), asked by a client")
                readFirmware()
                var reply = statusReply()
                let wanted = mode == "custom" ? 3 : mode == "max" ? 2 : 1
                if firmware?.fanCPU != wanted || firmware?.fanGPU != wanted {
                    reply["warning"] = "the firmware accepted fan \(mode) but now reports \(firmware?.fanSummary ?? "nothing")"
                }
                return reply
            } catch {
                log("fan \(mode): \(error)")
                // A manual duty half sent must not stay: mode 3 may already be on.
                if mode == "custom" {
                    do { try setFanBehavior(ec, max: false); fanOffAuto = false } catch { log("fans back to Auto: \(error)") }
                }
                readFirmware()
                return refused("fan \(mode): \(error)")
            }
        case "fancurve":
            guard let points = request["curve"] as? [[String: Int]] else {
                return ["ok": false, "error": "fancurve takes a list of points"]
            }
            let curve = points.compactMap { p in p["temp"].flatMap { t in p["percent"].map { FanCurvePoint(temp: t, percent: $0) } } }
            do {
                guard curve.count == points.count else { throw NitroECError(description: "a point of the curve has no temperature or duty") }
                try validateFanCurve(curve)
            } catch {
                return ["ok": false, "error": "\(error)"]
            }
            config.fan.curve = curve
            save()
            log("fan curve: \(curve.map { "\($0.temp) C \($0.percent) %" }.joined(separator: ", "))")
            if config.userFan == "curve" { checkFanCurve() }
            return statusReply()
        case "usb":
            guard let value = request["value"] as? Int, GamingWMI.usbChargeSet[value] != nil else {
                return ["ok": false, "error": "USB charging takes 0, 10, 20 or 30"]
            }
            guard commandAllowedNow() else { return tooSoon() }
            do {
                try setUSBCharge(ec, value)
                log("USB charging: \(value), asked by a client")
                readFirmware()
                var reply = statusReply()
                if firmware?.usbCharge != value { reply["warning"] = "the firmware accepted USB charging \(value) but now reports \(firmware?.usbCharge.map(String.init) ?? "nothing")" }
                return reply
            } catch {
                log("USB charging \(value): \(error)")
                return refused("USB charging: \(error)")
            }
        case "backlight":
            guard let mode = request["mode"] as? String, ["on", "off"].contains(mode) else {
                return ["ok": false, "error": "backlight takes on or off"]
            }
            guard commandAllowedNow() else { return tooSoon() }
            do {
                try setKBTimeout(ec, mode == "on")
                log("backlight timeout: \(mode), asked by a client")
                readFirmware()
                var reply = statusReply()
                if firmware?.kbTimeout != (mode == "on") { reply["warning"] = "the firmware accepted the backlight timeout but reads back differently" }
                return reply
            } catch {
                log("backlight timeout \(mode): \(error)")
                return refused("backlight timeout: \(error)")
            }
        case "power":
            guard let mode = request["mode"] as? String, let value = powerModes[mode] else {
                return ["ok": false, "error": "power mode must be quiet, balance or performance"]
            }
            guard nitroECOffers("NitroEC Power Mode") else {
                return ["ok": false, "error": "the loaded NitroEC.kext and SSDT-NITRO offer no power mode route: they need the build of this branch and a reboot"]
            }
            guard answered({ $0.profile != nil }) else { return notRead("power mode") }
            guard commandAllowedNow() else { return tooSoon() }
            do {
                try setPlatformProfile(ec, value)
                config.userMode = mode
                save()
                log("power: \(mode), asked by a client")
                readFirmware()
                var reply = statusReply()
                if firmware?.profile != Int(value) {
                    reply["warning"] = "the firmware accepted \(mode) but now reports \(firmware?.profile.map { profileName(UInt8(truncatingIfNeeded: $0)) } ?? "nothing")"
                }
                return reply
            } catch {
                log("power \(mode): \(error)")
                return refused("power \(mode): \(error)")
            }
        case "battery":
            guard batteryWMI else {
                return ["ok": false, "error": "the loaded NitroEC.kext and SSDT-NITRO offer no battery WMI: they need the build of branch anv15-52-battery or later, and a reboot"]
            }
            guard let mode = request["mode"] as? String else {
                let error = Date().timeIntervalSince(lastBatteryRead) >= minFirmwareReadInterval ? readBatteryLimit() : nil
                var reply = statusReply()
                if let error {
                    reply["ok"] = false
                    reply["error"] = "reading the charge limit: \(error)"
                }
                return reply
            }
            guard ["on", "off"].contains(mode) else { return ["ok": false, "error": "battery mode must be on or off"] }
            guard commandAllowedNow() else { return tooSoon() }
            if batteryLimit == nil, let error = readBatteryLimit() {
                return ["ok": false, "error": "not writing the charge limit: the firmware did not answer the read (\(error))"]
            }
            let wanted = mode == "on"
            do {
                try setBatteryLimit(ec, wanted)
            } catch {
                log("charge limit \(mode): \(error)")
                readBatteryLimit()
                var reply = statusReply()
                reply["ok"] = false
                reply["error"] = "charge limit \(mode): \(error)"
                return reply
            }
            let readBackError = readBatteryLimit()
            log("charge limit: \(mode), asked by a client; read back: \(batteryLimit.map { $0.on ? "on" : "off" } ?? "no answer")")
            var reply = statusReply()
            if batteryLimit?.on != wanted {
                reply["ok"] = false
                reply["error"] = "the firmware accepted charge limit \(mode) but the read-back says \(batteryLimit.map { $0.on ? "on" : "off" } ?? "nothing: \(readBackError ?? "")")"
            }
            return reply
        case "set":
            // The upstream way of changing settings. An older app may still send it: nothing it asks for exists on this board.
            return ["ok": false, "error": "nitrod does not take config patches on the \(Reg.model): use the fan, power and battery commands"]
        default:
            return ["ok": false, "error": "cmd must be status, firmware, fan, power, battery or apply"]
        }
    }

    // A write needs its GET to have answered. After a restart of nitrod, on a machine where the GETs already answered once,
    // it may ask again by itself; the first read of all is always a client's.
    private func answered(_ check: (FirmwareReading) -> Bool) -> Bool {
        if firmware == nil, config.firmwareReadOK { readFirmware() }
        return firmware.map(check) ?? false
    }

    private func commandAllowedNow() -> Bool {
        guard Date().timeIntervalSince(lastFirmwareCommand) >= minFirmwareCommandInterval else { return false }
        lastFirmwareCommand = Date()
        return true
    }

    private func tooSoon() -> [String: Any] {
        ["ok": false, "error": "too soon after the last firmware command: try again in a second"]
    }

    // A write that failed is still read back: the firmware may have moved anyway. The choice is not remembered.
    private func refused(_ message: String) -> [String: Any] {
        readFirmware()
        var reply = statusReply()
        reply["ok"] = false
        reply["error"] = message
        return reply
    }

    private func notRead(_ what: String) -> [String: Any] {
        ["ok": false, "error": firmware == nil ? "read the firmware first: \(what) is not written before its state has been read"
                                               : "not writing \(what): the firmware did not answer the read (\(firmware?.errors.joined(separator: "; ") ?? ""))"]
    }

    private func noGamingWMI() -> [String: Any] {
        ["ok": false, "error": "the loaded NitroEC.kext and SSDT-NITRO offer no gaming WMI: they need the build of branch anv15-52-control and a reboot"]
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
daemon.startFanWatch()
daemon.powerMeter.start()
let server = startServer(daemon)
registerPower(daemon)

// A client that goes away before its reply must not take the daemon with it.
signal(SIGPIPE, SIG_IGN)

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

log("running")
withExtendedLifetime((server, signalSources)) {
    dispatchMain()
}
