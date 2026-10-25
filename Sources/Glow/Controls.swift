import SwiftUI

// MARK: - Colour helpers

extension Color {
    /// Approximate RGB of a black-body white (Tanner Helland's fit), for previews of the bulb's whites.
    init(kelvin: Int) {
        let t = Double(kelvin) / 100
        let r = t <= 66 ? 255 : 329.698727446 * pow(t - 60, -0.1332047592)
        let g = t <= 66 ? 99.4708025861 * log(t) - 161.1195681661 : 288.1221695283 * pow(t - 60, -0.0755148492)
        let b = t >= 66 ? 255 : (t <= 19 ? 0 : 138.5177312231 * log(t - 10) - 305.0447927307)
        func c(_ v: Double) -> Double { min(max(v, 0), 255) / 255 }
        self.init(red: c(r), green: c(g), blue: c(b))
    }

    /// How a white *looks* in a room: black-body RGB pulled most of the way toward cream, because the eye
    /// adapts to warm light and sees 3000 K as whitish yellow rather than orange.
    init(perceivedKelvin kelvin: Int) {
        let t = Double(kelvin) / 100
        let r = t <= 66 ? 255 : 329.698727446 * pow(t - 60, -0.1332047592)
        let g = t <= 66 ? 99.4708025861 * log(t) - 161.1195681661 : 288.1221695283 * pow(t - 60, -0.0755148492)
        let b = t >= 66 ? 255 : (t <= 19 ? 0 : 138.5177312231 * log(t - 10) - 305.0447927307)
        func mix(_ v: Double, _ cream: Double) -> Double { (min(max(v, 0), 255) / 255) * 0.3 + cream * 0.7 }
        self.init(red: mix(r, 1), green: mix(g, 1), blue: mix(b, 0.8))
    }

    init(bulbHue h: Double, saturation s: Double, value v: Double = 1000) {
        self.init(hue: h / 360, saturation: s / 1000, brightness: 0.35 + 0.65 * v / 1000)
    }
}

// MARK: - Gradient slider

/// A capsule slider whose track is a gradient (warm→cool, dim→bright).
struct GradientSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double>
    var gradient: Gradient
    var onChange: (Double) -> Void

    @State private var dragging = false

    var body: some View {
        GeometryReader { geo in
            let knob: CGFloat = 20
            let fraction = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
            let x = knob / 2 + CGFloat(fraction) * (geo.size.width - knob)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(LinearGradient(gradient: gradient, startPoint: .leading, endPoint: .trailing))
                    .overlay(Capsule().strokeBorder(.black.opacity(0.08)))
                    .frame(height: 8)
                Circle()
                    .fill(.white)
                    .shadow(color: .black.opacity(0.3), radius: dragging ? 4 : 2, y: 1)
                    .overlay(Circle().strokeBorder(.black.opacity(0.12)))
                    .frame(width: knob, height: knob)
                    .scaleEffect(dragging ? 1.12 : 1)
                    .position(x: x, y: geo.size.height / 2)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                dragging = true
                let f = min(max((g.location.x - knob / 2) / (geo.size.width - knob), 0), 1)
                value = range.lowerBound + Double(f) * (range.upperBound - range.lowerBound)
                onChange(value)
            }.onEnded { _ in dragging = false })
            .animation(.easeOut(duration: 0.12), value: dragging)
        }
        .frame(height: 22)
    }
}

struct LabeledSlider: View {
    var label: String
    var detail: String
    @Binding var value: Double
    var range: ClosedRange<Double>
    var gradient: Gradient
    var onChange: (Double) -> Void

    var body: some View {
        VStack(spacing: 2) {
            HStack {
                Text(label).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(detail).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            GradientSlider(value: $value, range: range, gradient: gradient, onChange: onChange)
        }
    }
}

// MARK: - Colour wheel

/// Hue around the circle, saturation from the centre (white) to the rim. Drag anywhere.
struct ColourWheel: View {
    var hue: Double            // 0...360
    var saturation: Double     // 0...1000
    var showsKnob: Bool
    var onPick: (_ hue: Double, _ saturation: Double) -> Void

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let radius = side / 2
            let angle = Angle(degrees: hue)
            let r = CGFloat(saturation / 1000) * radius
            ZStack {
                Circle().fill(AngularGradient(
                    gradient: Gradient(colors: stride(from: 0, through: 360, by: 30).map {
                        Color(hue: Double($0) / 360, saturation: 1, brightness: 1)
                    }),
                    center: .center))
                Circle().fill(RadialGradient(colors: [.white, .white.opacity(0)], center: .center,
                                             startRadius: 0, endRadius: radius))
                Circle().strokeBorder(.black.opacity(0.08))
                if showsKnob {
                    Circle()
                        .fill(Color(bulbHue: hue, saturation: saturation))
                        .frame(width: 20, height: 20)
                        .overlay(Circle().strokeBorder(.white, lineWidth: 3))
                        .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                        .position(x: radius + cos(angle.radians) * r, y: radius + sin(angle.radians) * r)
                }
            }
            .frame(width: side, height: side)
            .contentShape(Circle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                let dx = g.location.x - radius, dy = g.location.y - radius
                var deg = atan2(dy, dx) * 180 / .pi
                if deg < 0 { deg += 360 }
                let sat = min(hypot(dx, dy) / radius, 1) * 1000
                onPick(deg, sat)
            })
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

// MARK: - Small pieces

struct Swatch: View {
    var hue: Double
    var selected: Bool
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            RoundedRectangle(cornerRadius: 7)
                .fill(Color(hue: hue / 360, saturation: 0.95, brightness: 0.95))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(selected ? Color.primary : .black.opacity(0.08),
                                                                        lineWidth: selected ? 2 : 1))
                .aspectRatio(1, contentMode: .fit)
                .scaleEffect(hovering ? 1.08 : 1)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.1), value: hovering)
        .help("Hue \(Int(hue))°")
    }
}

struct Chip: View {
    var title: String
    var selected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(selected ? .semibold : .regular))
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(Capsule().fill(.white.opacity(selected ? 0.85 : 0.5)))
                .overlay(Capsule().strokeBorder(.black.opacity(selected ? 0.25 : 0.1)))
                .foregroundStyle(Color(red: 0.23, green: 0.16, blue: 0.07))
        }
        .buttonStyle(.plain)
    }
}

struct SectionLabel: View {
    var title: String
    var trailing: String = ""
    var body: some View {
        HStack {
            Text(title.uppercased()).font(.caption2.weight(.semibold)).tracking(0.5)
            Spacer()
            Text(trailing).font(.caption2.monospacedDigit())
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 2)
    }
}
