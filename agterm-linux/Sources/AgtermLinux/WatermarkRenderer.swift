import CGtk
import Foundation
import agtermCore

enum WatermarkRenderer {
    static func materialize(_ watermark: BackgroundWatermark?, sessionID: UUID) -> String? {
        guard let watermark else { return nil }
        switch watermark.kind {
        case .image:
            guard let path = watermark.imagePath, WatermarkConfig.isValidImagePath(path) else { return nil }
            return path
        case .color:
            return nil
        case .text:
            guard let text = watermark.text, WatermarkConfig.isValidText(text) else { return nil }
            return renderText(text, colorHex: watermark.colorHex, sessionID: sessionID)
        }
    }

    private static func renderText(_ text: String, colorHex: String?, sessionID: UUID) -> String? {
        let out = WatermarkStorage.renderedTextURL(sessionID: sessionID, stateDir: nil)
        _ = WatermarkStorage.ensureDirectory()
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

        var textWidth: Int32 = 0
        var textHeight: Int32 = 0
        pango_layout_get_pixel_size(layout, &textWidth, &textHeight)
        cairo_move_to(cr, Double(width - Int(textWidth)) / 2, Double(height - Int(textHeight)) / 2)
        pango_cairo_show_layout(cr, layout)
        cairo_surface_flush(surface)
        let status = out.path.withCString { cairo_surface_write_to_png(surface, $0) }
        return status == CAIRO_STATUS_SUCCESS ? out.path : nil
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
