// Settings that nitrod keeps, plus the socket client used by nitroctl and the app to talk to the daemon.
//
// ANV15-52: only userFan and userMode mean anything, and they stay empty until the user chooses with this version. The
// other keys are the upstream shape, kept so that the config.json of an earlier install still loads; nothing reads them.

import Foundation

let nitrodSocketPath = "/var/run/nitrod.sock"
let nitrodConfigDir = "/Library/Application Support/NitroSense"
let nitrodConfigPath = nitrodConfigDir + "/config.json"

struct FanCurvePoint: Codable, Equatable {
    var temp: Int     // °C
    var percent: Int  // duty 20-100
}

struct FanConfig: Codable, Equatable {
    var mode = "auto"  // auto | max | manual | curve
    var cpuPercent = 60
    var gpuPercent = 60
    // The EC keeps the GPU fan above ~4500 RPM in manual (20 % -> 4545 RPM, Auto ~4100),
    // so by default the curve drives only the CPU fan and leaves the GPU fan on Auto.
    var curveGPU = false
    // Both fans go to max at this temperature (any mode) until 10 °C below it.
    var failsafeTemp = 95
    var curve = [FanCurvePoint(temp: 50, percent: 30), FanCurvePoint(temp: 60, percent: 40),
                 FanCurvePoint(temp: 70, percent: 55), FanCurvePoint(temp: 80, percent: 75),
                 FanCurvePoint(temp: 88, percent: 100)]
}

struct LEDConfig: Codable, Equatable {
    var effect = "static"
    var speed = 5
    var brightness = 100
    var direction = 0
    var color = "FFFFFF"
    var zones = ["FF0000", "00FF00", "0000FF", "FFFFFF"]
}

struct NitroConfig: Codable, Equatable {
    var fan = FanConfig()
    var nitroMode = "default"
    var batteryLimit = false
    var usbCharge = true
    var kbTimeout = true
    var led = LEDConfig()
    // The only settings nitrod may re-apply, at start and after wake, and only once the user chose them with this version.
    var userFan = ""          // "" (never chosen) | auto | max
    var userMode = ""         // "" (never chosen) | quiet | balance | performance
    // The GET calls answered at least once on this machine: from then on the app may ask for them by itself.
    var firmwareReadOK = false

    func validate() throws {
        func check(_ ok: Bool, _ what: String) throws {
            if !ok { throw NitroECError(description: "invalid config: \(what)") }
        }
        try check(["", "auto", "max"].contains(userFan), "userFan must be empty, auto or max")
        try check(userMode.isEmpty || powerModes[userMode] != nil, "userMode must be empty, quiet, balance or performance")
    }

    init() {}

    // Decode `patch` (a partial config as a JSON object) on top of `self`.
    // Unknown keys are rejected so typos do not silently do nothing.
    func merged(with patch: [String: Any]) throws -> NitroConfig {
        let base = try JSONSerialization.jsonObject(with: JSONEncoder().encode(self)) as! [String: Any]
        let merged = try deepMerge(base, patch, path: "")
        let data = try JSONSerialization.data(withJSONObject: merged)
        return try JSONDecoder().decode(NitroConfig.self, from: data)
    }
}

private func deepMerge(_ base: [String: Any], _ patch: [String: Any], path: String) throws -> [String: Any] {
    var out = base
    for (key, value) in patch {
        guard let old = base[key] else {
            throw NitroECError(description: "unknown config key '\(path)\(key)'")
        }
        if let oldDict = old as? [String: Any], let newDict = value as? [String: Any] {
            out[key] = try deepMerge(oldDict, newDict, path: path + key + ".")
        } else {
            out[key] = value
        }
    }
    return out
}

// One request per connection: a JSON object terminated by newline; the reply is one JSON object.
func nitrodRequest(_ request: [String: Any]) throws -> [String: Any] {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw NitroECError(description: "socket() failed") }
    defer { close(fd) }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &addr.sun_path) { buf in
        for (i, b) in nitrodSocketPath.utf8.prefix(buf.count - 1).enumerated() { buf[i] = b }
    }
    let ok = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard ok == 0 else {
        throw NitroECError(description: "cannot reach nitrod at \(nitrodSocketPath) (\(String(cString: strerror(errno)))); is the daemon installed?")
    }
    var payload = try JSONSerialization.data(withJSONObject: request)
    payload.append(0x0A)
    _ = payload.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    var reply = Data()
    var chunk = [UInt8](repeating: 0, count: 4096)
    while true {
        let n = read(fd, &chunk, chunk.count)
        if n <= 0 { break }
        reply.append(contentsOf: chunk[0..<n])
    }
    guard let obj = try JSONSerialization.jsonObject(with: reply) as? [String: Any] else {
        throw NitroECError(description: "bad reply from nitrod")
    }
    return obj
}
