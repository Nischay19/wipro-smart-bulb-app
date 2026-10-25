import Foundation
import Network
import Observation
import TuyaKit

struct WhitePreset: Identifiable, Equatable {
    var id: String { name }
    var name: String
    var temperature: Int
    var brightness: Int
}

/// App state: the bulb's last known state plus what the UI is asking for.
/// Edits are applied optimistically and coalesced, so dragging a slider sends a few updates per
/// second instead of flooding the bulb.
@Observable @MainActor
final class BulbModel {
    enum Link: Equatable {
        case notConfigured(String)
        case connecting
        case connected
        case failed(String)
    }

    private(set) var link: Link = .connecting
    let config: BulbConfig?

    // What the panel shows (kept in sync with the bulb's reports).
    var isOn = false
    var mode: BulbMode = .white
    var temperature = 100          // 0 warm ... 1000 cool
    var whiteBrightness = 850      // 10 ... 1000
    var hue = 0.0                  // 0 ... 360
    var saturation = 1000.0        // 0 ... 1000
    var colourBrightness = 1000.0  // 10 ... 1000
    var presetName: String? = "My Glow"

    // Natural Light
    private(set) var naturalLight = false
    private(set) var naturalStatus = "Follows the time of day"

    private(set) var myGlow: WhitePreset
    var presets: [WhitePreset] {
        [myGlow,
         WhitePreset(name: "Candle", temperature: 0, brightness: 350),
         WhitePreset(name: "Reading", temperature: 450, brightness: 1000),
         WhitePreset(name: "Daylight", temperature: 1000, brightness: 1000)]
    }

    private let connection: TuyaConnection?
    private var pending: DPS = [:]
    private var flushing = false
    private var lastEdit = Date.distantPast
    private let defaults = UserDefaults.standard

    init() {
        let t = defaults.object(forKey: "myGlow.temperature") as? Int ?? Kelvin.toTemperature(3080)
        let b = defaults.object(forKey: "myGlow.brightness") as? Int ?? 850
        myGlow = WhitePreset(name: "My Glow", temperature: t, brightness: b)

        guard let config = try? BulbConfig.load(), let connection = try? config.makeConnection() else {
            config = nil
            connection = nil
            link = .notConfigured(BulbConfig.defaultURL.path)
            return
        }
        self.config = config
        self.connection = connection
        listen()
        refresh()
        startNaturalLightClock()
        if defaults.bool(forKey: "naturalLight") { setNaturalLight(true) }
    }

    // MARK: - Bulb I/O

    /// (Re)connects and asks for the full state; called on launch and whenever the panel opens.
    func refresh() {
        guard let connection else { return }
        Task {
            if !(await connection.isConnected) { link = .connecting }
            do {
                try await connection.connect()
                try await connection.query()
                link = .connected
            } catch {
                link = .failed(Self.explain(error))
            }
        }
    }

    /// Turns network errors into something actionable.
    static func explain(_ error: Error) -> String {
        if let nw = error as? NWError, case .posix(let code) = nw,
           [.EHOSTUNREACH, .ENETUNREACH, .ENETDOWN, .ECONNREFUSED].contains(code) {
            return "Can't reach the bulb: allow Local Network for Glow (System Settings › Privacy & Security), check it's powered"
        }
        if case TuyaError.timeout = error {
            return "Bulb didn't answer: allow Local Network for Glow, or the bulb's IP changed"
        }
        return String(describing: error)
    }

    private func listen() {
        guard let connection else { return }
        Task { [weak self] in
            for await dps in connection.updates {
                self?.absorb(dps)
            }
        }
    }

    private func absorb(_ dps: DPS) {
        var s = BulbState()
        s.merge(dps)
        if let on = s.isOn { isOn = on }
        // While the user is dragging, their values win over the bulb's (slightly stale) echoes.
        guard Date().timeIntervalSince(lastEdit) > 0.8 else { return }
        if let m = s.mode { mode = m }
        if let t = s.temperature { temperature = t }
        if let b = s.brightness { whiteBrightness = b }
        if let c = s.colour {
            hue = Double(c.h); saturation = Double(c.s); colourBrightness = Double(c.v)
        }
        if s.temperature != nil || s.brightness != nil { presetName = matchingPreset()?.name }
    }

    private func send(_ dps: DPS) {
        guard let connection else { return }
        pending.merge(dps) { $1 }
        guard !flushing else { return }
        flushing = true
        Task {
            while !pending.isEmpty {
                let batch = pending
                pending = [:]
                do {
                    try await connection.set(batch)
                    link = .connected
                } catch {
                    link = .failed(Self.explain(error))
                }
                try? await Task.sleep(for: .milliseconds(120))
            }
            flushing = false
        }
    }

    // MARK: - User actions

    func setPower(_ on: Bool) {
        isOn = on
        lastEdit = Date()
        if on, naturalLight {
            applyNaturalTarget()
        } else {
            send(BulbCommand.power(on))
        }
    }

    func setWhite(temperature: Int? = nil, brightness: Int? = nil, preset: String? = nil, manual: Bool = true) {
        if manual { pauseNaturalLight() }
        if let temperature { self.temperature = temperature }
        if let brightness { whiteBrightness = brightness }
        mode = .white
        isOn = true
        lastEdit = Date()
        presetName = preset ?? matchingPreset()?.name
        send(BulbCommand.white(brightness: whiteBrightness, temperature: self.temperature))
    }

    func apply(_ preset: WhitePreset) {
        setWhite(temperature: preset.temperature, brightness: preset.brightness, preset: preset.name)
    }

    func saveMyGlow() {
        myGlow = WhitePreset(name: "My Glow", temperature: temperature, brightness: whiteBrightness)
        defaults.set(temperature, forKey: "myGlow.temperature")
        defaults.set(whiteBrightness, forKey: "myGlow.brightness")
        presetName = "My Glow"
    }

    func setColour(hue: Double? = nil, saturation: Double? = nil, brightness: Double? = nil) {
        pauseNaturalLight()
        if let hue { self.hue = hue }
        if let saturation { self.saturation = saturation }
        if let brightness { colourBrightness = brightness }
        mode = .colour
        isOn = true
        lastEdit = Date()
        send(BulbCommand.colour(HSV(h: Int(self.hue.rounded()), s: Int(self.saturation.rounded()),
                                    v: Int(colourBrightness.rounded()))))
    }

    var isMyGlowDirty: Bool {
        mode == .white && (temperature != myGlow.temperature || whiteBrightness != myGlow.brightness)
    }

    private func matchingPreset() -> WhitePreset? {
        presets.first { abs($0.temperature - temperature) <= 5 && abs($0.brightness - whiteBrightness) <= 5 }
    }

    // MARK: - Natural Light

    func setNaturalLight(_ enabled: Bool) {
        naturalLight = enabled
        defaults.set(enabled, forKey: "naturalLight")
        if enabled {
            applyNaturalTarget()
        } else {
            naturalStatus = "Follows the time of day"
        }
    }

    /// Like Hue: touching any control hands control back to the user.
    private func pauseNaturalLight() {
        guard naturalLight else { return }
        naturalLight = false
        defaults.set(false, forKey: "naturalLight")
        naturalStatus = "Paused by a manual change"
    }

    private func applyNaturalTarget() {
        let target = NaturalLight.target()
        naturalStatus = "\(target.phase) · \(target.kelvin) K · \(target.brightness / 10)%"
        setWhite(temperature: target.temperature, brightness: target.brightness, preset: "Natural Light", manual: false)
    }

    private func startNaturalLightClock() {
        Task { [weak self] in
            while true {
                try? await Task.sleep(for: .seconds(60))
                guard let self else { return }
                if self.naturalLight, self.isOn { self.applyNaturalTarget() }
            }
        }
    }
}
