import Foundation

/// Circadian white, inspired by Philips Hue's "Natural Light": cool and bright around midday,
/// progressively warmer and dimmer through the evening, very warm and low at night.
public enum NaturalLight {
    /// (minute of day, warmth 0...1000, brightness 10...1000), linearly interpolated.
    static let keyframes: [(minute: Double, temperature: Double, brightness: Double)] = [
        (0, 0, 100),
        (5 * 60 + 30, 0, 100),     // night
        (6 * 60 + 30, 250, 500),   // sunrise
        (8 * 60, 700, 900),        // morning
        (12 * 60, 1000, 1000),     // midday
        (15 * 60, 1000, 1000),
        (17 * 60, 600, 900),       // afternoon
        (19 * 60, 250, 750),       // evening
        (21 * 60, 80, 500),        // wind-down
        (22 * 60 + 30, 0, 200),
        (24 * 60, 0, 100),
    ]

    public struct Target: Sendable, Equatable {
        public var temperature: Int
        public var brightness: Int
        public var phase: String
        public var kelvin: Int { Kelvin.from(temperature: temperature) }
    }

    public static func target(at date: Date = Date(), calendar: Calendar = .current) -> Target {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        let minute = Double((c.hour ?? 0) * 60 + (c.minute ?? 0))
        var t = 0.0, b = 100.0
        for (a, z) in zip(keyframes, keyframes.dropFirst()) where minute >= a.minute && minute <= z.minute {
            let f = (minute - a.minute) / (z.minute - a.minute)
            t = a.temperature + (z.temperature - a.temperature) * f
            b = a.brightness + (z.brightness - a.brightness) * f
            break
        }
        return Target(temperature: Int(t.rounded()), brightness: max(10, Int(b.rounded())), phase: phase(minute))
    }

    static func phase(_ m: Double) -> String {
        switch m {
        case ..<330: "Night"
        case ..<480: "Sunrise"
        case ..<720: "Morning"
        case ..<900: "Midday"
        case ..<1140: "Afternoon"
        case ..<1260: "Evening"
        default: "Wind-down"
        }
    }
}
