import AppKit
import SwiftUI

/// Uses official color artwork in app surfaces; menu-bar rendering remains monochrome.
struct ProviderBrandIcon: View {
    let id: String
    let mark: ProviderMark
    let inset: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    // https://antigravity.google/press — Icon - Full Color.
    private static let antigravityImage: NSImage = {
        let url = Bundle.openUsageResources.url(
            forResource: "antigravity-color", withExtension: "png", subdirectory: "ProviderIcons"
        )!
        return NSImage(contentsOf: url)!
    }()

    // Paths and fills from https://pi.dev/logo-auto.svg.
    private static let piLayers: [(ProviderMark, Color)] = [
        (ProviderMark(path: "M165.29 165.29H517.36V400H400V282.65H165.29Z"), hex(0xF09082)),
        (ProviderMark(path: "M165.29 282.65H282.65V400H400V517.36H282.65V634.72H165.29Z"), hex(0x4D9ABF)),
        (ProviderMark(path: "M517.36 400H634.72V634.72H517.36Z"), hex(0xF1BE58))
    ]

    var body: some View {
        switch id {
        case "antigravity":
            Image(nsImage: Self.antigravityImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .scaleEffect((1 - 2 * inset) * 540 / 404)
        case "pi":
            ZStack {
                ForEach(Self.piLayers.indices, id: \.self) { index in
                    ProviderIconShape(mark: Self.piLayers[index].0, inset: inset, normalizationBounds: mark.bounds)
                        .fill(Self.piLayers[index].1)
                }
            }
        case "omp":
            // The header mark and gradient colors come from https://omp.sh/ and its favicon.
            ProviderIconShape(mark: mark, inset: inset)
                .fill(LinearGradient(
                    colors: [Self.hex(0xED4ABF), Self.hex(0x9B4DFF), Self.hex(0x5AD8E6)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ))
        case "claude":
            ProviderIconShape(mark: mark, inset: inset).fill(Self.hex(0xD97757))
        case "openrouter":
            // https://openrouter.ai/brand — grape and volt glyphs for light and dark surfaces.
            ProviderIconShape(mark: ProviderMarks.mark(for: "openrouter-brand")!, inset: inset)
                .fill(Self.hex(colorScheme == .dark ? 0xC8FF00 : 0x7624F4))
        case "openusage":
            ProviderIconShape(mark: mark, inset: inset).fill(Theme.iconGray)
        default:
            ProviderIconShape(mark: mark, inset: inset).fill(.primary)
        }
    }

    private static func hex(_ value: UInt32) -> Color {
        Color(red: Double((value >> 16) & 0xFF) / 255,
              green: Double((value >> 8) & 0xFF) / 255,
              blue: Double(value & 0xFF) / 255)
    }
}
