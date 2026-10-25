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

@main
struct GlowCtl {
    static func main() async {
        var args = Array(CommandLine.arguments.dropFirst())
        guard let verb = args.first?.lowercased() else { print(usage); return }
        args.removeFirst()
        if verb == "colours" || verb == "colors" {
            print(named.sorted { $0.value < $1.value }.map(\.key).joined(separator: " ")); return
        }
        if ["-h", "--help", "help"].contains(verb) { print(usage); return }

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
