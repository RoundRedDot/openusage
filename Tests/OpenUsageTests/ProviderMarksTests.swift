import XCTest
import SwiftUI
@testable import OpenUsage

@MainActor
final class ProviderMarksTests: XCTestCase {
    func testProviderVectorMarksLoadWithoutFallbacks() throws {
        for id in ["antigravity", "claude", "codex", "copilot", "cursor", "devin", "grok",
                   "ollama", "omp", "opencode", "openrouter", "pi", "zai", "openrouter-brand"] {
            let mark = try XCTUnwrap(ProviderMarks.mark(for: id), "\(id) should load a vector mark")
            XCTAssertFalse(mark.path.isEmpty, "\(id) mark must carry SVG path data")
        }
    }

    func testPiUsesOfficialThreePartMark() throws {
        let mark = try XCTUnwrap(ProviderMarks.mark(for: "pi"))
        XCTAssertEqual(mark.path, "M165.29 165.29H517.36V400H400V282.65H165.29Z M165.29 282.65H282.65V400H400V517.36H282.65V634.72H165.29Z M517.36 400H634.72V634.72H517.36Z")
        XCTAssertEqual(mark.bounds.width, 469.43, accuracy: 0.01)
        XCTAssertEqual(mark.bounds.height, 469.43, accuracy: 0.01)
    }

    func testOhMyPiUsesOfficialHeaderMark() throws {
        let mark = try XCTUnwrap(ProviderMarks.mark(for: "omp"))
        XCTAssertEqual(mark.path, "M10 14h44v9H43v33h-9V23h-9v22h-9V23H10z")
        XCTAssertEqual(mark.bounds.width, 44, accuracy: 0.01)
        XCTAssertEqual(mark.bounds.height, 42, accuracy: 0.01)
    }

    func testColorMarksRenderInBothAppearances() throws {
        for appearance: ColorScheme in [.light, .dark] {
            for id in ["antigravity", "claude", "pi", "omp", "openrouter"] {
                let view = ProviderIcon(source: .providerMark(id))
                    .frame(width: 80, height: 80)
                    .environment(\.colorScheme, appearance)
                let image = try XCTUnwrap(ImageRenderer(content: view).nsImage)
                let tiff = try XCTUnwrap(image.tiffRepresentation)
                let bitmap = try XCTUnwrap(NSBitmapImageRep(data: tiff))
                let pixels = (0..<bitmap.pixelsHigh).contains { y in
                    (0..<bitmap.pixelsWide).contains { x in
                        guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                              color.alphaComponent > 0.9 else { return false }
                        return max(color.redComponent, color.greenComponent, color.blueComponent)
                            - min(color.redComponent, color.greenComponent, color.blueComponent) > 0.15
                    }
                }
                XCTAssertTrue(pixels, "\(id) should render in color in \(appearance) appearance")
            }
        }
    }

    func testAllProviderMarksRenderInBothAppearances() throws {
        for appearance: ColorScheme in [.light, .dark] {
            for id in ["antigravity", "claude", "codex", "copilot", "cursor", "devin", "grok",
                       "ollama", "omp", "opencode", "openrouter", "pi", "zai"] {
                let view = ProviderIcon(source: .providerMark(id))
                    .frame(width: 24, height: 24)
                    .environment(\.colorScheme, appearance)
                let image = try XCTUnwrap(ImageRenderer(content: view).nsImage)
                let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
                XCTAssertTrue((0..<bitmap.pixelsHigh).contains { y in
                    (0..<bitmap.pixelsWide).contains { x in
                        (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5
                    }
                }, "\(id) must be visible in \(appearance) appearance")
            }
        }
    }
}
