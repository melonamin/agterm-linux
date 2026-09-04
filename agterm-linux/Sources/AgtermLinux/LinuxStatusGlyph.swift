import CGtk
import Foundation
import agtermCore

struct LinuxStatusGlyphPresentation: Equatable {
    let glyph: String
    let colorHex: String
    let tooltip: String

    init?(indicator: AgentIndicator, settings: AppSettings) {
        let status = indicator.status
        guard let tooltip = status.tooltipText else { return nil }
        let shape = indicator.shape ?? settings.effectiveStatusShape(for: status) ?? .circle
        glyph = switch shape {
        case .circle: "●"
        case .square: "■"
        case .triangle: "▲"
        case .diamond: "◆"
        case .capsule: "▬"
        case .star: "★"
        }
        let configured = switch status {
        case .active: settings.activeStatusColorHex ?? "#DBD9E6"
        case .blocked: settings.blockedStatusColorHex ?? "#E5A50A"
        case .completed: settings.completedStatusColorHex ?? "#2EC27E"
        case .idle: "#000000"
        }
        colorHex = indicator.color.flatMap {
            WatermarkConfig.isValidColorHex($0) ? $0 : nil
        } ?? configured
        self.tooltip = tooltip
    }
}

@MainActor
extension AppController {
    static func makeStatusGlyph(
        _ indicator: AgentIndicator, settings: AppSettings
    ) -> OpaquePointer? {
        guard let presentation = LinuxStatusGlyphPresentation(
            indicator: indicator, settings: settings
        ), let label = op(gtk_label_new(nil)) else { return nil }
        applyStatusGlyph(presentation, blink: indicator.blink, to: label)
        return label
    }

    static func applyStatusGlyph(
        _ indicator: AgentIndicator, settings: AppSettings, to label: OpaquePointer
    ) {
        guard let presentation = LinuxStatusGlyphPresentation(
            indicator: indicator, settings: settings
        ) else {
            gtk_widget_set_visible(W(label), 0)
            return
        }
        applyStatusGlyph(presentation, blink: indicator.blink, to: label)
        gtk_widget_set_visible(W(label), 1)
    }

    private static func applyStatusGlyph(
        _ presentation: LinuxStatusGlyphPresentation, blink: Bool, to label: OpaquePointer
    ) {
        "<span foreground=\"\(presentation.colorHex)\">\(presentation.glyph)</span>".withCString {
            gtk_label_set_markup(label, $0)
        }
        presentation.tooltip.withCString { gtk_widget_set_tooltip_text(W(label), $0) }
        if blink {
            gtk_widget_add_css_class(W(label), "agterm-blink")
        } else {
            gtk_widget_remove_css_class(W(label), "agterm-blink")
        }
    }
}
