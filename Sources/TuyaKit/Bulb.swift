import Foundation

/// Datapoint ids of a Tuya "v2" light (category `dj`), as reported by this bulb's cloud spec.
public enum BulbDP {
    public static let power = "20"        // switch_led: bool
    public static let mode = "21"         // work_mode: white | colour | scene | music
    public static let brightness = "22"   // bright_value_v2: 10...1000
    public static let temperature = "23"  // temp_value_v2: 0 (warm) ... 1000 (cool)
    public static let colour = "24"       // colour_data_v2: hex hhhhssssvvvv
    public static let countdown = "26"    // countdown_1: seconds
}

public enum BulbMode: String, Sendable {
    case white, colour, scene, music
}

/// Hue 0...360, saturation 0...1000, value 0...1000: the bulb's own colour units.
public struct HSV: Sendable, Equatable, Codable {
    public var h: Int
    public var s: Int
    public var v: Int

    public init(h: Int, s: Int, v: Int) {
        self.h = min(max(h, 0), 360)
        self.s = min(max(s, 0), 1000)
        self.v = min(max(v, 10), 1000)
    }

    /// Parses DP 24, e.g. `000003e803e8` (red at full brightness).
    public init?(hex: String) {
        guard hex.count == 12, let h = Int(hex.prefix(4), radix: 16),
              let s = Int(hex.dropFirst(4).prefix(4), radix: 16), let v = Int(hex.suffix(4), radix: 16)
        else { return nil }
        self.init(h: h, s: s, v: v)
    }

    public var hex: String { String(format: "%04x%04x%04x", h, s, v) }

    /// From 0...255 RGB (used by the CLI for `#rrggbb`).
    public init(r: Double, g: Double, b: Double, brightness: Int = 1000) {
        let r = r / 255, g = g / 255, b = b / 255
        let mx = max(r, g, b), mn = min(r, g, b), d = mx - mn
        var hue = 0.0
        if d > 0 {
            if mx == r { hue = 60 * ((g - b) / d).truncatingRemainder(dividingBy: 6) }
            else if mx == g { hue = 60 * ((b - r) / d + 2) }
            else { hue = 60 * ((r - g) / d + 4) }
        }
        if hue < 0 { hue += 360 }
        self.init(h: Int(hue.rounded()), s: mx == 0 ? 0 : Int((d / mx * 1000).rounded()), v: brightness)
    }
}

/// What the bulb is doing, assembled from datapoint updates.
public struct BulbState: Sendable, Equatable {
    public var isOn: Bool?
    public var mode: BulbMode?
    public var brightness: Int?
    public var temperature: Int?
    public var colour: HSV?

    public init() {}

    public mutating func merge(_ dps: DPS) {
        if case .bool(let b)? = dps[BulbDP.power] { isOn = b }
        if case .string(let m)? = dps[BulbDP.mode] { mode = BulbMode(rawValue: m) }
        if case .int(let b)? = dps[BulbDP.brightness] { brightness = b }
        if case .int(let t)? = dps[BulbDP.temperature] { temperature = t }
        if case .string(let c)? = dps[BulbDP.colour], let hsv = HSV(hex: c) { colour = hsv }
    }
}

/// Datapoint payloads for common actions.
public enum BulbCommand {
    public static func power(_ on: Bool) -> DPS { [BulbDP.power: .bool(on)] }

    public static func white(brightness: Int, temperature: Int) -> DPS {
        [BulbDP.power: .bool(true), BulbDP.mode: .string(BulbMode.white.rawValue),
         BulbDP.brightness: .int(min(max(brightness, 10), 1000)),
         BulbDP.temperature: .int(min(max(temperature, 0), 1000))]
    }

    public static func colour(_ hsv: HSV) -> DPS {
        [BulbDP.power: .bool(true), BulbDP.mode: .string(BulbMode.colour.rawValue), BulbDP.colour: .string(hsv.hex)]
    }

    public static func countdown(seconds: Int) -> DPS { [BulbDP.countdown: .int(min(max(seconds, 0), 86400))] }
}

/// Approximate colour temperature: the bulb's 0...1000 warmth spans roughly 2700 K...6500 K.
public enum Kelvin {
    public static func from(temperature t: Int) -> Int { 2700 + Int((Double(t) / 1000 * 3800).rounded()) }
    public static func toTemperature(_ k: Int) -> Int { min(max(Int((Double(k - 2700) / 3800 * 1000).rounded()), 0), 1000) }
}

/// Preferences shared by Glow.app (which edits them) and glowctl (which reads them in hooks),
/// stored at ~/.config/glow/settings.json.
public struct GlowSettings: Codable, Sendable {
    /// Blink when a long Claude Code turn finishes (checked by `glowctl turn-end`).
    public var claudeAlerts: Bool

    public init(claudeAlerts: Bool = true) { self.claudeAlerts = claudeAlerts }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        claudeAlerts = try c.decodeIfPresent(Bool.self, forKey: .claudeAlerts) ?? true
    }

    public static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/glow/settings.json")
    }

    public static func load() -> GlowSettings {
        (try? JSONDecoder().decode(GlowSettings.self, from: Data(contentsOf: url))) ?? GlowSettings()
    }

    public func save() throws {
        try FileManager.default.createDirectory(at: Self.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: Self.url, options: .atomic)
    }
}

/// Connection details stored by the setup script at ~/.config/glow/bulb.json (mode 600).
public struct BulbConfig: Codable, Sendable {
    public var name: String
    public var id: String
    public var ip: String
    public var key: String
    public var version: String?

    public static var defaultURL: URL {
        if let override = ProcessInfo.processInfo.environment["GLOW_CONFIG"] { return URL(fileURLWithPath: override) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/glow/bulb.json")
    }

    public static func load(from url: URL = defaultURL) throws -> BulbConfig {
        try JSONDecoder().decode(BulbConfig.self, from: Data(contentsOf: url))
    }

    public func makeConnection() throws -> TuyaConnection {
        try TuyaConnection(host: ip, deviceID: id, localKey: key)
    }
}
