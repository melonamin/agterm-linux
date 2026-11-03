import CGtk
import Foundation
import agtermCore

@MainActor
extension AppController {
    func companionDisclosureHit(_ id: UUID, row: OpaquePointer, x: Double, y: Double) -> Bool {
        guard let disclosure = sidebarRuntime.rows[id]?.disclosure,
              let hit = gtk_widget_pick(W(row), x, y, GTK_PICK_DEFAULT) else { return false }
        return hit == W(disclosure) || gtk_widget_is_ancestor(hit, W(disclosure)) != 0
    }

    func installCompanionRowWidgets(_ id: UUID, widgets: SessionRowWidgets, content: SidebarSnapshot.RowContent) {
        let disclosure = op(gtk_button_new_from_icon_name(Self.disclosureIconName(expanded: content.expanded)))!
        gtk_button_set_has_frame(cast(disclosure), 0)
        gtk_widget_add_css_class(W(disclosure), "agterm-companion-disclosure")
        gtk_widget_set_focus_on_click(W(disclosure), 0)
        gtk_widget_set_tooltip_text(W(disclosure), "Fold or unfold companions")
        // A homogeneous stack measures the button even on leaf rows, keeping their icons aligned.
        let slot = op(gtk_stack_new())!
        let spacer = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0)
        gtk_stack_add_named(slot, spacer, "empty")
        gtk_stack_add_named(slot, W(disclosure), "disclosure")
        gtk_box_prepend(cast(widgets.box), W(slot))
        connectAction(disclosure) { [weak self] in
            guard let self, let session = self.store.session(withID: id) else { return }
            let expanded = session.isExpanded || self.sidebarRuntime.transientParentIDs.contains(id)
            _ = self.setSessionExpansion(id.uuidString, window: nil, expanded: !expanded)
        }
        widgets.disclosure = disclosure
        widgets.disclosureSlot = slot
        let marker = op(gtk_label_new("•"))!
        gtk_box_append(cast(widgets.box), W(marker))
        widgets.foldedMarker = marker
        applyCompanionRowWidgets(widgets, content: content)
    }

    func applyCompanionRowWidgets(_ widgets: SessionRowWidgets, content: SidebarSnapshot.RowContent) {
        gtk_widget_set_margin_start(W(widgets.box), content.indented ? 24 : 0)
        gtk_widget_set_visible(W(widgets.row), content.shown ? 1 : 0)
        if let slot = widgets.disclosureSlot {
            gtk_widget_set_visible(W(slot), store.sidebarMode == .tree ? 1 : 0)
            gtk_stack_set_visible_child_name(slot, content.hasCompanions ? "disclosure" : "empty")
        }
        if let disclosure = widgets.disclosure {
            gtk_button_set_icon_name(cast(disclosure), Self.disclosureIconName(expanded: content.expanded))
        }
        if let marker = widgets.foldedMarker {
            gtk_widget_set_visible(W(marker), content.foldedAttention == nil ? 0 : 1)
            if let text = content.foldedAttention { gtk_widget_set_tooltip_text(W(marker), text) }
        }
        applySidebarTint(content.tint, icon: widgets.lead, name: widgets.name)
    }

    func ensurePageSession(_ session: Session) {
        guard sessionStacks[session.id] == nil, let stack = op(gtk_stack_new()),
              let placeholder = op(gtk_box_new(GTK_ORIENTATION_VERTICAL, 0)) else { return }
        sessionStacks[session.id] = stack
        gtk_stack_add_named(stack, W(placeholder), "main")
        gtk_widget_set_halign(W(stack), GTK_ALIGN_FILL)
        gtk_widget_set_valign(W(stack), GTK_ALIGN_FILL)
        gtk_widget_set_hexpand(W(stack), 1)
        gtk_widget_set_vexpand(W(stack), 1)
        gtk_widget_set_opacity(W(stack), 0)
        gtk_widget_set_can_target(W(stack), 0)
        gtk_widget_set_child_visible(W(stack), 0)
        gtk_overlay_add_overlay(deck, W(stack))
    }
}
