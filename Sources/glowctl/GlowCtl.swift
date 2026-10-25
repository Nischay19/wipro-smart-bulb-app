import Foundation
import TuyaKit

let usage = """
glowctl: control the bulb over the LAN (config: ~/.config/glow/bulb.json, or $GLOW_CONFIG)

  glowctl status                     print power, mode, brightness, warmth, colour
  glowctl on | off | toggle
  glowctl glow                       whitish yellow ("My Glow": 3080 K, 85%)
  glowctl white <kelvin|0-1000> [%]  e.g. glowctl white 3000K 70
  glowctl colour <name|#rrggbb> [%]  e.g. glowctl colour red, glowctl colour #ff6600 40
  glowctl natural                    apply the Natural Light white for the current time
  glowctl notify                     ~2 s "done" signal: candle flicker if off, brightness pulse if on,
                                     then restore exactly what was there (used by a Claude Code hook)
  glowctl turn-start                 Claude Code UserPromptSubmit hook: note when a turn began
  glowctl turn-end [minutes]         Claude Code Stop hook: notify only if the turn ran ≥ minutes (default 10)
  glowctl colours                    list colour names
"""

let named: [String: Int] = [
    "red": 0, "coral": 10, "orange": 25, "amber": 40, "yellow": 55, "lime": 90, "green": 120,
    "mint": 150, "teal": 170, "cyan": 185, "sky": 200, "blue": 230, "indigo": 255, "purple": 275,
    "magenta": 300, "pink": 325, "rose": 345,
]

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func percent(_ s: String?) -> Int? {
    guard let s, let p = Int(s.trimmingCharacters(in: CharacterSet(charactersIn: "%"))) else { return nil }
    return min(max(p, 1), 100) * 10
}

func describe(_ s: BulbState) -> String {
    var parts = ["power=\(s.isOn.map { $0 ? "on" : "off" } ?? "?")", "mode=\(s.mode?.rawValue ?? "?")"]
    if let b = s.brightness, let t = s.temperature {
        parts.append("white=\(Kelvin.from(temperature: t))K/\(b / 10)%")
    }
    if let c = s.colour { parts.append("colour=h\(c.h) s\(c.s / 10)% v\(c.v / 10)%") }
    return parts.joined(separator: "  ")
}

/// A ~2 second "work is done" signal that leaves the bulb exactly as it found it.
/// Off: warm candle flicker, then off again. On: brightness dips and returns, then the original
/// mode/colour/brightness is restored.
func notifyDone(_ bulb: TuyaConnection) async throws {
    var s = BulbState()
    s.merge(try await bulb.status())
    let warm = Kelvin.toTemperature(2800)
    let end = Date().addingTimeInterval(2)

    func pause(_ ms: ClosedRange<Int>) async throws { try await Task.sleep(for: .milliseconds(Int.random(in: ms))) }

    guard s.isOn == true else {
        try await bulb.set(BulbCommand.white(brightness: 350, temperature: warm))
        while Date() < end {
            try await bulb.set([BulbDP.brightness: .int(Int.random(in: 120 ... 650))])
            try await pause(90 ... 180)
        }
        // Turn off and put back the remembered mode/white/colour, so the next "on" looks as before.
        var off: DPS = [BulbDP.power: .bool(false)]
        if let m = s.mode { off[BulbDP.mode] = .string(m.rawValue) }
        if let b = s.brightness { off[BulbDP.brightness] = .int(b) }
        if let t = s.temperature { off[BulbDP.temperature] = .int(t) }
        if let c = s.colour { off[BulbDP.colour] = .string(c.hex) }
        try await bulb.set(off)
        try await Task.sleep(for: .milliseconds(200)) // let the last frame land before disconnecting
        return
    }

    let restore: DPS
    switch s.mode {
    case .colour?:
        let c = s.colour ?? HSV(h: 40, s: 1000, v: 1000)
        restore = BulbCommand.colour(c)
        var low = true
        while Date() < end {
            try await bulb.set([BulbDP.colour: .string(HSV(h: c.h, s: c.s, v: low ? max(10, c.v / 5) : 1000).hex)])
            low.toggle()
            try await pause(250 ... 250)
        }
    case .white?:
        let b = s.brightness ?? 850
        restore = BulbCommand.white(brightness: b, temperature: s.temperature ?? warm)
        var low = true
        while Date() < end {
            try await bulb.set([BulbDP.brightness: .int(low ? max(10, b / 5) : 1000)])
            low.toggle()
            try await pause(250 ... 250)
        }
    default: // scene/music modes: blink the power instead
        restore = [BulbDP.power: .bool(true), BulbDP.mode: .string(s.mode?.rawValue ?? "white")]
        var on = false
        while Date() < end {
            try await bulb.set(BulbCommand.power(on))
            on.toggle()
            try await pause(300 ... 300)
        }
    }
    try await bulb.set(restore)
    try await Task.sleep(for: .milliseconds(200))
}

/// Claude Code hook helpers: remember when a turn started (UserPromptSubmit) and, when it ends (Stop),
/// report how long it took, so the bulb only signals after long-running work.
enum TurnTimer {
    static let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/glow/turns")

    /// The hook's stdin JSON carries `session_id`; keep it filename-safe.
    static func sessionFile() -> URL {
        var id = "default"
        if isatty(STDIN_FILENO) == 0,
           let obj = try? JSONSerialization.jsonObject(with: FileHandle.standardInput.readDataToEndOfFile()) as? [String: Any],
           let raw = obj["session_id"] as? String {
            let safe = String(raw.filter { $0.isLetter || $0.isNumber || $0 == "-" }.prefix(64))
            if !safe.isEmpty { id = safe }
        }
        return dir.appendingPathComponent(id)
    }

    static func start() {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? String(Date().timeIntervalSince1970).write(to: sessionFile(), atomically: true, encoding: .utf8)
    }

    /// Seconds since the matching start, or nil if there was none. Clears the marker.
    static func end() -> TimeInterval? {
        let file = sessionFile()
        defer { try? FileManager.default.removeItem(at: file) }
        guard let text = try? String(contentsOf: file, encoding: .utf8), let start = Double(text) else { return nil }
        return Date().timeIntervalSince1970 - start
    }
}

@main
struct GlowCtl {
    static func main() async {
        var args = Array(CommandLine.arguments.dropFirst())
        guard var verb = args.first?.lowercased() else { print(usage); return }
        args.removeFirst()
        if verb == "colours" || verb == "colors" {
            print(named.sorted { $0.value < $1.value }.map(\.key).joined(separator: " ")); return
        }
        if ["-h", "--help", "help"].contains(verb) { print(usage); return }
        if verb == "turn-start" { TurnTimer.start(); return }
        if verb == "turn-end" {
            let minutes = Double(args.first ?? "") ?? 10
            guard let elapsed = TurnTimer.end(), elapsed >= minutes * 60 else { return }
            verb = "notify"
        }

        let config: BulbConfig
        do { config = try BulbConfig.load() } catch {
            fail("No bulb config at \(BulbConfig.defaultURL.path). Run scripts/setup-key.sh first.")
        }

        do {
            let bulb = try config.makeConnection()
            var command: DPS?
            switch verb {
            case "status": break
            case "on": command = BulbCommand.power(true)
            case "off": command = BulbCommand.power(false)
            case "toggle":
                var s = BulbState(); s.merge(try await bulb.status())
                command = BulbCommand.power(!(s.isOn ?? false))
            case "glow":
                command = BulbCommand.white(brightness: 850, temperature: Kelvin.toTemperature(3080))
            case "white":
                guard let raw = args.first?.uppercased() else { fail("usage: glowctl white <kelvin|0-1000> [%]") }
                let temp = raw.hasSuffix("K") ? Kelvin.toTemperature(Int(raw.dropLast()) ?? 3000) : (Int(raw) ?? 100)
                command = BulbCommand.white(brightness: percent(args.dropFirst().first) ?? 1000, temperature: temp)
            case "colour", "color":
                guard let raw = args.first?.lowercased() else { fail("usage: glowctl colour <name|#rrggbb> [%]") }
                let v = percent(args.dropFirst().first) ?? 1000
                let hsv: HSV
                if let h = named[raw] {
                    hsv = HSV(h: h, s: 1000, v: v)
                } else if raw.hasPrefix("#"), raw.count == 7, let n = Int(raw.dropFirst(), radix: 16) {
                    hsv = HSV(r: Double(n >> 16 & 0xFF), g: Double(n >> 8 & 0xFF), b: Double(n & 0xFF), brightness: v)
                } else {
                    fail("unknown colour '\(raw)'; try: glowctl colours")
                }
                command = BulbCommand.colour(hsv)
            case "natural":
                let t = NaturalLight.target()
                print("Natural Light: \(t.phase) · \(t.kelvin) K · \(t.brightness / 10)%")
                command = BulbCommand.white(brightness: t.brightness, temperature: t.temperature)
            case "notify":
                try await notifyDone(bulb)
                await bulb.disconnect()
                return
            default:
                fail(usage)
            }

            if let command { try await bulb.set(command) }
            var state = BulbState()
            state.merge(try await bulb.status())
            print(describe(state))
            await bulb.disconnect()
        } catch {
            fail("glowctl: \(error)")
        }
    }
}
