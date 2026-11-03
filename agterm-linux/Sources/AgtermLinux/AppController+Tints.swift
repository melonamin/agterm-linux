import CGtk
import Foundation
import agtermCore

@MainActor
extension AppController {
    func applySidebarTint(_ tint: SidebarTint?, icon: OpaquePointer?, name: OpaquePointer?) {
        for (part, widget) in [(TintPart.icon, icon), (.name, name)] {
            guard let widget else { continue }
            for color in TintColor.allCases { gtk_widget_remove_css_class(W(widget), "agterm-tint-\(color.rawValue)") }
            if let tint, tint.shows(part) { gtk_widget_add_css_class(W(widget), "agterm-tint-\(tint.color.rawValue)") }
        }
    }

    func appendTintMenu(to box: OpaquePointer?, sessionIDs: [UUID]? = nil, workspaceID: UUID? = nil) {
        let button = op(gtk_menu_button_new())!
        gtk_menu_button_set_label(button, "Tint")
        gtk_menu_button_set_has_frame(button, 0)
        let popover = op(gtk_popover_new())!
        let options = op(gtk_box_new(GTK_ORIENTATION_VERTICAL, 0))!
        func recolor(_ color: TintColor?) {
            if let workspaceID {
                let current = store.workspaces.first { $0.id == workspaceID }?.tint
                store.setTint(SidebarTint.recolor(current, to: color), forWorkspace: workspaceID)
            } else { store.setTintColor(color, forSessions: sessionIDs ?? []) }
            syncSidebar()
        }
        for color in TintColor.allCases {
            appendSidebarAction(to: options, title: color.rawValue.capitalized) { recolor(color) }
        }
        appendSidebarAction(to: options, title: "Clear Tint") { recolor(nil) }
        let tints = workspaceID.map { id in [store.workspaces.first { $0.id == id }?.tint] }
            ?? (sessionIDs ?? []).map { store.session(withID: $0)?.tint }
        for (title, parts) in [("Show on Icon", Set([TintPart.icon])), ("Show on Name", Set([TintPart.name])),
                               ("Show on Icon and Name", Set(TintPart.allCases))] {
            let enabled = !tints.isEmpty && tints.allSatisfy { $0 != nil }
            appendSidebarAction(to: options, title: title, enabled: enabled) {
                if let workspaceID {
                    let current = self.store.workspaces.first { $0.id == workspaceID }?.tint
                    self.store.setTint(SidebarTint.place(current, on: parts), forWorkspace: workspaceID)
                } else { self.store.setTintParts(parts, forSessions: sessionIDs ?? []) }
                self.syncSidebar()
            }
        }
        gtk_popover_set_child(cast(popover), W(options))
        gtk_menu_button_set_popover(button, cast(popover))
        gtk_box_append(cast(box), W(button))
    }

    func appendSidebarAction(to box: OpaquePointer?, title: String, enabled: Bool = true,
                             action: @escaping @MainActor () -> Void) {
        guard let button = op(gtk_button_new_with_label(title)) else { return }
        gtk_button_set_has_frame(cast(button), 0)
        gtk_widget_set_sensitive(W(button), enabled ? 1 : 0)
        connectAction(button, action)
        gtk_box_append(cast(box), W(button))
    }

    func appendSessionParityMenu(to box: OpaquePointer?, targets: [UUID]) {
        if targets.count == 1, let id = targets.first {
            appendSidebarAction(to: box, title: "New Companion") { [weak self] in
                guard let self else { return }
                self.dismissContextMenu()
                self.newCompanionFromGUI(target: id)
            }
            if store.session(withID: id)?.content == .terminal {
                appendSidebarAction(to: box, title: "Duplicate as Companion") { [weak self] in
                    guard let self else { return }
                    self.dismissContextMenu()
                    self.newCompanionFromGUI(duplicate: true, target: id)
                }
            }
        }
        if targets.contains(where: { store.session(withID: $0)?.agentIndicator.status == .idle }) {
            appendSidebarAction(to: box, title: "Mark for Attention") { [weak self] in
                guard let self else { return }
                self.dismissContextMenu()
                self.store.markForAttention(targets)
                self.syncSidebar()
            }
        }
        appendTintMenu(to: box, sessionIDs: targets)
    }

    func showSessionTintPalette() {
        guard let id = store.selectedSessionID else { return }
        showPalette()
        paletteAll = LinuxPaletteList(items: TintColor.allCases.map { color in
            (row: LinuxPaletteRow(title: color.rawValue.capitalized), run: { [weak self] in
                self?.store.setTintColor(color, forSessions: [id])
                self?.syncSidebar()
            })
        } + [(row: LinuxPaletteRow(title: "Clear Tint"), run: { [weak self] in
            self?.store.setTintColor(nil, forSessions: [id]); self?.syncSidebar()
        })])
        filterPalette("")
    }
}

@MainActor
func installLinuxTintCSS() {
    guard let display = gdk_display_get_default() else { return }
    let provider = OpaquePointer(gtk_css_provider_new())
    let colors = ["red": "red_3", "orange": "orange_3", "yellow": "yellow_4", "green": "green_4",
                  "blue": "blue_3", "purple": "purple_3", "gray": "light_5"]
    let css = colors.map { ".agterm-tint-\($0.key) { color: @\($0.value); }" }.joined(separator: "\n")
    gtk_css_provider_load_from_string(cast(provider), css)
    gtk_style_context_add_provider_for_display(display, provider, 652)
    g_object_unref(RAW(provider))
}
