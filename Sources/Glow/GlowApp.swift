import AppKit
import SwiftUI

@main
struct GlowApp: App {
    @State private var model = BulbModel()

    init() {
        // Menu-bar only (also set via LSUIElement in the bundled app's Info.plist).
        NSApplication.shared.setActivationPolicy(.accessory)

        // Dev aid: `Glow --snapshot out.png` renders the panel (light + dark) to an image and exits.
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            Self.snapshot(model: model, to: URL(fileURLWithPath: args[i + 1]))
        }
    }

    private static func snapshot(model: BulbModel, to url: URL) {
        RunLoop.main.run(until: Date().addingTimeInterval(2)) // let the first status arrive
        let pair = HStack(alignment: .top, spacing: 24) {
            ForEach([ColorScheme.light, .dark], id: \.self) { scheme in
                PanelView(model: model)
                    .background(scheme == .dark ? Color(white: 0.16) : Color(white: 0.97))
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .environment(\.colorScheme, scheme)
            }
        }
        .padding(24)
        .background(Color(white: 0.5))
        let renderer = ImageRenderer(content: pair)
        renderer.scale = 2
        if let tiff = renderer.nsImage?.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: url)
        }
        exit(0)
    }

    var body: some Scene {
        MenuBarExtra {
            PanelView(model: model)
        } label: {
            Image(systemName: model.isOn ? "lightbulb.max.fill" : "lightbulb")
        }
        .menuBarExtraStyle(.window)
    }
}
