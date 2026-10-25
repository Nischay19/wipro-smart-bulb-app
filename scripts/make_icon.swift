// Renders the app icon (warm glowing bulb on a dusk gradient) into an .iconset folder.
// Usage: swift scripts/make_icon.swift <out.iconset>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let inset = s * 0.1
    let rect = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let tile = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)
    NSGradient(colors: [NSColor(red: 0.16, green: 0.12, blue: 0.20, alpha: 1),
                        NSColor(red: 0.36, green: 0.20, blue: 0.16, alpha: 1)])!.draw(in: tile, angle: -90)

    // glow
    let center = NSPoint(x: s / 2, y: s * 0.55)
    NSGradient(colors: [NSColor(red: 1, green: 0.86, blue: 0.58, alpha: 0.95),
                        NSColor(red: 1, green: 0.75, blue: 0.4, alpha: 0)])!
        .draw(fromCenter: center, radius: 0, toCenter: center, radius: rect.width * 0.42, options: [])

    // bulb symbol
    let config = NSImage.SymbolConfiguration(pointSize: s * 0.42, weight: .semibold)
        .applying(.init(paletteColors: [NSColor(red: 1, green: 0.97, blue: 0.88, alpha: 1)]))
    if let bulb = NSImage(systemSymbolName: "lightbulb.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) {
        let size = bulb.size
        bulb.draw(in: NSRect(x: (s - size.width) / 2, y: (s - size.height) / 2, width: size.width, height: size.height))
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try render(base).write(to: out.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(base * 2).write(to: out.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
