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
    /// The glyph label a row, dashboard tile or picker row owns for its whole life, built even for an
    /// idle indicator — which renders as hidden and cleared (`agterm-linux/docs/sidebar.md`).
    static func makeStatusGlyphLabel(
        _ indicator: AgentIndicator, settings: AppSettings, phase: Bool
    ) -> OpaquePointer? {
        guard let label = op(gtk_label_new(nil)) else { return nil }
        applyStatusGlyph(indicator, settings: settings, phase: phase, to: label)
        return label
    }

    static func applyStatusGlyph(
        _ indicator: AgentIndicator, settings: AppSettings, phase: Bool, to label: OpaquePointer
    ) {
        applyStatusGlyph(LinuxStatusGlyphPresentation(indicator: indicator, settings: settings),
                         blink: indicator.blink, phase: phase, to: label)
    }

    /// The blink marker is the timer's only carrier, so this owns both ends of the opacity: a label that
    /// starts blinking takes the pulse's CURRENT phase (the timer writes marked labels only, and not until
    /// its next tick), and one that stops goes back to full — a label faded by the last tick would
    /// otherwise stay dim with nothing left to un-dim it.
    static func applyStatusGlyph(
        _ presentation: LinuxStatusGlyphPresentation?, blink: Bool, phase: Bool,
        to label: OpaquePointer
    ) {
        if LinuxBlinkPolicy.shouldMark(presentation: presentation, blink: blink) {
            gtk_widget_add_css_class(W(label), LinuxBlinkPolicy.markerClass)
            gtk_widget_set_opacity(W(label), LinuxBlinkPolicy.opacity(phase: phase))
        } else {
            gtk_widget_remove_css_class(W(label), LinuxBlinkPolicy.markerClass)
            gtk_widget_set_opacity(W(label), 1)
        }
        guard let presentation else {
            gtk_widget_set_visible(W(label), 0)
            gtk_label_set_text(label, "")
            gtk_widget_set_tooltip_text(W(label), nil)
            return
        }
        "<span foreground=\"\(presentation.colorHex)\">\(presentation.glyph)</span>".withCString {
            gtk_label_set_markup(label, $0)
        }
        presentation.tooltip.withCString { gtk_widget_set_tooltip_text(W(label), $0) }
        gtk_widget_set_visible(W(label), 1)
    }
}
