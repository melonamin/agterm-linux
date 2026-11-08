import CGtk
import Foundation
import agtermCore

@MainActor
extension AppController {
    func applySessionInfo(_ widgets: SessionRowWidgets, content: SidebarSnapshot.RowContent) {
        guard let label = widgets.info else { return }
        let density = linuxSettingsStore().load().effectiveSidebarDensity
        gtk_widget_set_visible(W(label), content.info == nil ? 0 : 1)
        gtk_widget_set_size_request(W(widgets.box), -1,
                                   content.info == nil ? -1 : Int32(AppSettings.sidebarRowHeight(fontSize: content.infoFontSize, density: density)))
        guard let info = content.info else { gtk_label_set_text(label, ""); return }
        gtk_widget_set_margin_start(W(label), 6 + (content.iconVisible ? 22 : 0) + (content.indented ? (density == .compact ? 20 : 24) : 0))
        let size = Int(max(9, content.infoFontSize - 1.5) * Double(PANGO_SCALE))
        let markup = info.spans.map { span in
            var attributes = ["size=\"\(size)\""]
            if span.bold { attributes.append("weight=\"bold\"") }
            if span.italic { attributes.append("style=\"italic\"") }
            if span.code { attributes.append("font_family=\"monospace\"") }
            if span.dim { attributes.append("alpha=\"60%\"") }
            if let color = span.color, let foreground = Self.infoColor(color, widget: label) {
                attributes.append("foreground=\"\(foreground)\"")
            }
            let text = span.text.withCString { source -> String in
                guard let escaped = g_markup_escape_text(source, -1) else { return "" }
                defer { g_free(escaped) }
                return String(cString: escaped)
            }
            return "<span \(attributes.joined(separator: " "))>\(text)</span>"
        }.joined()
        gtk_label_set_markup(label, markup)
        gtk_widget_set_tooltip_text(W(label), info.spans.map(\.text).joined())
    }

    private static func infoColor(_ color: TintColor, widget: OpaquePointer) -> String? {
        let custom: [TintColor: String] = [.teal: "#219080", .pink: "#d56199", .indigo: "#6364c9", .mint: "#69c9a1"]
        if let value = custom[color] { return value }
        let names: [TintColor: String] = [.red: "red_3", .orange: "orange_3", .yellow: "yellow_4", .green: "green_4",
                                         .blue: "blue_3", .purple: "purple_3", .gray: "light_5", .brown: "brown_3"]
        guard let name = names[color] else { return nil }
        var rgba = GdkRGBA()
        guard gtk_style_context_lookup_color(gtk_widget_get_style_context(W(widget)), name, &rgba) != 0 else { return nil }
        return String(format: "#%02x%02x%02x", Int(rgba.red * 255), Int(rgba.green * 255), Int(rgba.blue * 255))
    }
}
