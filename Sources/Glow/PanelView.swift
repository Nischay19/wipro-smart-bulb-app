import SwiftUI
import TuyaKit

struct PanelView: View {
    @Bindable var model: BulbModel

    static let swatchHues: [Double] = [0, 15, 30, 45, 60, 90, 120, 160, 180, 200, 220, 245, 270, 290, 310, 335]

    var body: some View {
        VStack(spacing: 14) {
            header
            if case .notConfigured(let path) = model.link {
                setupHint(path)
            } else {
                warmWhite
                colour
                naturalLight
            }
            footer
        }
        .padding(14)
        .frame(width: 340)
        .onAppear { model.refresh() }
    }

    // MARK: Header

    private var currentGlow: Color {
        guard model.isOn else { return .secondary }
        return model.mode == .colour
            ? Color(bulbHue: model.hue, saturation: model.saturation)
            : Color(perceivedKelvin: Kelvin.from(temperature: model.temperature))
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: model.isOn ? "lightbulb.max.fill" : "lightbulb")
                .font(.system(size: 22))
                .foregroundStyle(currentGlow)
                .shadow(color: model.isOn ? currentGlow : .clear, radius: 6)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.config?.name ?? "Glow").font(.headline)
                HStack(spacing: 5) {
                    Circle().fill(linkColour).frame(width: 7, height: 7)
                    Text(linkText).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            Toggle("Power", isOn: Binding(get: { model.isOn }, set: { model.setPower($0) }))
                .toggleStyle(.switch)
                .labelsHidden()
                .disabled(model.config == nil)
        }
    }

    private var linkColour: Color {
        switch model.link {
        case .connected: .green
        case .connecting: .orange
        case .failed, .notConfigured: .red
        }
    }

    private var linkText: String {
        switch model.link {
        case .connected: "\(model.config?.ip ?? "") · local"
        case .connecting: "Connecting…"
        case .failed(let why): why
        case .notConfigured: "Not set up"
        }
    }

    // MARK: Warm white (hero)

    private var warmWhite: some View {
        let kelvin = Kelvin.from(temperature: model.temperature)
        let white = Color(perceivedKelvin: kelvin)
        let active = model.mode == .white
        return VStack(alignment: .leading, spacing: 6) {
            SectionLabel(title: "Warm White", trailing: "\(kelvin) K")
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text(model.presetName ?? "Custom").font(.title3.weight(.bold))
                    Spacer()
                    Text("\(model.whiteBrightness / 10)%").font(.callout.monospacedDigit()).opacity(0.7)
                }
                LabeledSlider(label: "Warmth", detail: "\(kelvin) K",
                              value: Binding(get: { Double(model.temperature) }, set: { model.temperature = Int($0) }),
                              range: 0 ... 1000,
                              gradient: Gradient(colors: [Color(kelvin: 2700), Color(kelvin: 4000), Color(kelvin: 6500)])) {
                    model.setWhite(temperature: Int($0))
                }
                LabeledSlider(label: "Brightness", detail: "\(model.whiteBrightness / 10)%",
                              value: Binding(get: { Double(model.whiteBrightness) }, set: { model.whiteBrightness = Int($0) }),
                              range: 10 ... 1000,
                              gradient: Gradient(colors: [white.opacity(0.25), white])) {
                    model.setWhite(brightness: Int($0))
                }
                HStack(spacing: 6) {
                    ForEach(model.presets) { p in
                        Chip(title: p.name == "My Glow" ? "★ My Glow" : p.name,
                             selected: active && model.presetName == p.name) { model.apply(p) }
                    }
                }
                if model.isMyGlowDirty {
                    Button("Save as My Glow") { model.saveMyGlow() }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
            .padding(14)
            .foregroundStyle(Color(red: 0.23, green: 0.16, blue: 0.07))
            .background(
                // A cream base tinted by the current white, so the card reads like the light itself.
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(red: 1, green: 0.985, blue: 0.95))
                    .overlay(RoundedRectangle(cornerRadius: 12)
                        .fill(LinearGradient(colors: [white, white.opacity(0.35)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing)))
                    .shadow(color: white.opacity(active && model.isOn ? 0.9 : 0.3), radius: active ? 14 : 4, y: 4)
            )
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(active ? Color.orange.opacity(0.7) : .clear, lineWidth: 2))
            .contentShape(RoundedRectangle(cornerRadius: 12))
            .onTapGesture { if !active { model.setWhite() } }
        }
    }

    // MARK: Colour

    private var colour: some View {
        let active = model.mode == .colour
        return VStack(alignment: .leading, spacing: 6) {
            SectionLabel(title: "Colour",
                         trailing: active ? "H \(Int(model.hue))° · S \(Int(model.saturation / 10))%" : "")
            VStack(spacing: 12) {
                HStack(alignment: .center, spacing: 12) {
                    ColourWheel(hue: model.hue, saturation: model.saturation, showsKnob: active) { h, s in
                        model.setColour(hue: h, saturation: s)
                    }
                    .frame(width: 128, height: 128)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 7), count: 4), spacing: 7) {
                        ForEach(Self.swatchHues, id: \.self) { h in
                            Swatch(hue: h, selected: active && abs(model.hue - h) < 1 && model.saturation > 950) {
                                model.setColour(hue: h, saturation: 1000)
                            }
                        }
                    }
                }
                LabeledSlider(label: "Brightness", detail: "\(Int(model.colourBrightness / 10))%",
                              value: $model.colourBrightness, range: 10 ... 1000,
                              gradient: Gradient(colors: [.black.opacity(0.6),
                                                          Color(bulbHue: model.hue, saturation: model.saturation)])) {
                    model.setColour(brightness: $0)
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12).fill(.background.opacity(0.6)))
            .overlay(RoundedRectangle(cornerRadius: 12)
                .strokeBorder(active ? Color(bulbHue: model.hue, saturation: model.saturation) : .primary.opacity(0.08),
                              lineWidth: active ? 2 : 1))
        }
    }

    // MARK: Natural Light

    private var naturalLight: some View {
        HStack(spacing: 10) {
            Image(systemName: "sun.horizon.fill")
                .font(.title3)
                .foregroundStyle(.orange, .yellow)
            VStack(alignment: .leading, spacing: 1) {
                Text("Natural Light").font(.callout.weight(.semibold))
                Text(model.naturalStatus).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("Natural Light", isOn: Binding(get: { model.naturalLight }, set: { model.setNaturalLight($0) }))
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 12).fill(.background.opacity(0.6)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.08)))
        .help("Cool and bright at midday, warm and dim in the evening. Any manual change pauses it.")
    }

    // MARK: Footer / setup

    private var footer: some View {
        HStack {
            Text("Glow · LAN 3.5").font(.caption2).foregroundStyle(.tertiary)
            Spacer()
            Button("Refresh") { model.refresh() }.buttonStyle(.borderless).font(.caption)
            Button("Quit") { NSApplication.shared.terminate(nil) }.buttonStyle(.borderless).font(.caption)
        }
    }

    private func setupHint(_ path: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No bulb configured").font(.headline)
            Text("Run `scripts/setup-key.sh` from the repo. It fetches your bulb's key from your Tuya project and writes:")
                .font(.caption)
            Text(path).font(.caption.monospaced()).textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(.background.opacity(0.6)))
    }
}
