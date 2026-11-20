import CGtk
import Foundation
import agtermCore

enum WatermarkRenderer {
    static func isSupportedImage(_ path: String) -> Bool {
        ["png", "jpg", "jpeg"].contains((path as NSString).pathExtension.lowercased())
    }

    static func materialize(_ watermark: BackgroundWatermark?, sessionID: UUID, paneKey: String? = nil) -> String? {
        guard let watermark else { return nil }
        switch watermark.kind {
        case .image:
            guard let path = watermark.imagePath, WatermarkConfig.isValidImagePath(path),
                  isSupportedImage(path), FileManager.default.fileExists(atPath: path) else { return nil }
            return path
        case .color:
            return nil
        case .text:
            guard let text = watermark.text, WatermarkConfig.isValidText(text) else { return nil }
            let out = WatermarkStorage.renderedTextURL(sessionID: sessionID, paneKey: paneKey, stateDir: nil)
            _ = WatermarkStorage.ensureDirectory()
            return renderText(text, colorHex: watermark.colorHex, output: out)
        }
    }

    static func renderText(_ text: String, colorHex: String?, output: URL) -> String? {
        let width = min(4096, max(1200, text.count * 150))
        let height = 420
        guard let surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, Int32(width), Int32(height)),
              let cr = cairo_create(surface),
              let layout = pango_cairo_create_layout(cr) else { return nil }
        defer {
            g_object_unref(UnsafeMutableRawPointer(layout))
            cairo_destroy(cr)
            cairo_surface_destroy(surface)
        }

        let (r, g, b) = rgb(colorHex) ?? (1, 1, 1)
        cairo_set_source_rgba(cr, r, g, b, 0.42)
        text.withCString { pango_layout_set_text(layout, $0, -1) }
        "Sans Bold 256".withCString { fontName in
            guard let desc = pango_font_description_from_string(fontName) else { return }
            pango_layout_set_font_description(layout, desc)
            pango_font_description_free(desc)
        }
        pango_layout_set_alignment(layout, PANGO_ALIGN_CENTER)

        var ink = PangoRectangle()
        pango_layout_get_pixel_extents(layout, &ink, nil)
        let textWidth = Double(max(1, ink.width)), textHeight = Double(max(1, ink.height))
        let scale = min(1, Double(width - 32) / textWidth, Double(height - 32) / textHeight)
        cairo_translate(cr, (Double(width) - textWidth * scale) / 2 - Double(ink.x) * scale,
                        (Double(height) - textHeight * scale) / 2 - Double(ink.y) * scale)
        cairo_scale(cr, scale, scale)
        cairo_move_to(cr, 0, 0)
        pango_cairo_show_layout(cr, layout)
        cairo_surface_flush(surface)
        let status = output.path.withCString { cairo_surface_write_to_png(surface, $0) }
        return status == CAIRO_STATUS_SUCCESS ? output.path : nil
    }

    private static func rgb(_ hex: String?) -> (Double, Double, Double)? {
        guard var value = hex, WatermarkConfig.isValidColorHex(value) else { return nil }
        if value.hasPrefix("#") { value.removeFirst() }
        guard let intValue = Int(value, radix: 16) else { return nil }
        let r = Double((intValue >> 16) & 0xff) / 255.0
        let g = Double((intValue >> 8) & 0xff) / 255.0
        let b = Double(intValue & 0xff) / 255.0
        return (r, g, b)
    }
}
