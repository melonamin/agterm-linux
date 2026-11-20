import CGtk
import Foundation
import Testing
@testable import AgtermLinux

@Suite("Linux text watermark rasterization")
struct WatermarkRendererTests {
    @Test(arguments: ["VISUAL CHECK", String(repeating: "W", count: 120), "Καλημέρα 日本語\nSecond line"])
    func glyphsFitInsideTheBitmap(_ text: String) throws {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("watermark-\(UUID()).png")
        defer { try? FileManager.default.removeItem(at: output) }
        #expect(WatermarkRenderer.renderText(text, colorHex: "#ff00ff", output: output) == output.path)
        let surface = try #require(output.path.withCString { cairo_image_surface_create_from_png($0) })
        defer { cairo_surface_destroy(surface) }
        #expect(cairo_surface_status(surface) == CAIRO_STATUS_SUCCESS)
        let pixels = try #require(cairo_image_surface_get_data(surface))
        let width = Int(cairo_image_surface_get_width(surface)), height = Int(cairo_image_surface_get_height(surface))
        let stride = Int(cairo_image_surface_get_stride(surface))
        var left = width, top = height, right = -1, bottom = -1
        for y in 0..<height {
            for x in 0..<width where pixels[y * stride + x * 4 + 3] != 0 {
                left = min(left, x)
                right = max(right, x)
                top = min(top, y)
                bottom = max(bottom, y)
            }
        }
        #expect(right >= left && bottom >= top, "The watermark must contain drawn glyphs")
        #expect(left >= 8 && top >= 8 && right < width - 8 && bottom < height - 8,
                "Glyphs must have transparent padding on all four sides instead of being clipped")
    }
}
