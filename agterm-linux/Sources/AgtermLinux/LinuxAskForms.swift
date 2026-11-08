import CGtk
import Foundation
import agtermCore

@MainActor
final class LinuxAskFormWidgets {
    weak var controller: AppController?
    let ask: PendingAsk
    var editor: OpaquePointer?
    var buffer: OpaquePointer?
    var choices: [OpaquePointer] = []
    var buttons: [OpaquePointer] = []
    var updating = false
    var composing = false

    init(ask: PendingAsk, controller: AppController) {
        self.ask = ask
        self.controller = controller
    }

    var draft: AskDraft? { controller?.draft(forAsk: ask.id) }

    func bind(_ object: OpaquePointer) {
        g_object_set_data_full(cast(object), "agterm-ask-form", Unmanaged.passRetained(self).toOpaque(), releaseAskForm)
    }

    func update(_ change: (inout AskDraft) -> Void) {
        controller?.updateDraft(forAsk: ask.id, change)
        refreshChoices()
    }

    func refreshChoices() {
        guard let draft, case .choices(let list) = ask.form else { return }
        updating = true
        defer { updating = false }
        for (index, button) in choices.enumerated() {
            let active = index < list.choices.count ? draft.checked.contains(list.choices[index].id) : draft.otherSelected
            gtk_check_button_set_active(cast(button), active ? 1 : 0)
            if index == list.choices.count { gtk_widget_set_sensitive(W(button), draft.otherEnabled ? 1 : 0) }
        }
    }

    func textChanged() {
        guard !updating, let editor, let previous = draft?.text else { return }
        let text: String
        if let buffer {
            var first = GtkTextIter(), last = GtkTextIter()
            gtk_text_buffer_get_bounds(cast(buffer), &first, &last)
            let pointer = gtk_text_buffer_get_text(cast(buffer), &first, &last, 1)
            text = pointer.map { String(cString: $0) } ?? ""
            g_free(pointer)
        } else {
            text = gtk_editable_get_text(editor).map { String(cString: $0) } ?? ""
        }
        let mode: ControlAskInputMode
        if case .input(let input) = ask.form { mode = input.mode } else { mode = .line }
        guard text.utf8.count <= AskInputForm.maxTextBytes, !AskInputForm.hasForbiddenControls(text, mode: mode) else {
            updating = true
            if let buffer { gtk_text_buffer_set_text(cast(buffer), previous, -1) } else { gtk_editable_set_text(editor, previous) }
            updating = false
            return
        }
        update { $0.text = text }
    }

    private func containsFocus(_ widget: OpaquePointer) -> Bool {
        guard let root = gtk_widget_get_root(W(widget)), let focus = gtk_root_get_focus(root) else { return false }
        return focus == W(widget) || gtk_widget_is_ancestor(focus, W(widget)) != 0
    }

    var editorHasFocus: Bool { editor.map(containsFocus) ?? false }
    var buttonHasFocus: Bool { buttons.contains(where: containsFocus) }

    func focusCursor() {
        guard let draft else { return }
        let target = draft.cursorOnOther ? editor : choices.indices.contains(draft.cursor) ? choices[draft.cursor] : nil
        if let target { _ = gtk_widget_grab_focus(W(target)) }
    }
}

@MainActor
extension AppController {
    func draft(forAsk id: String) -> AskDraft? {
        if pickController.pendingAsk?.id == id { return pickController.askDraft }
        return store.workspaces.flatMap(\.sessions).first { $0.askPending?.id == id }?.askDraft
    }

    func updateDraft(forAsk id: String, _ change: (inout AskDraft) -> Void) {
        if pickController.pendingAsk?.id == id {
            pickController.updateAskDraft(id: id, change)
        } else {
            store.workspaces.flatMap(\.sessions).first { $0.askPending?.id == id }?.updateAskDraft(id: id, change)
        }
    }

    func makeAskForm(_ ask: PendingAsk, in content: OpaquePointer) -> LinuxAskFormWidgets? {
        guard let form = ask.form else { return nil }
        let widgets = LinuxAskFormWidgets(ask: ask, controller: self)
        let scroller = op(gtk_scrolled_window_new())
        gtk_scrolled_window_set_policy(scroller, GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
        gtk_scrolled_window_set_max_content_height(scroller, 320)
        gtk_scrolled_window_set_propagate_natural_height(scroller, 1)
        gtk_scrolled_window_set_max_content_width(scroller, 480)
        gtk_scrolled_window_set_propagate_natural_width(scroller, 1)
        let body = op(gtk_box_new(GTK_ORIENTATION_VERTICAL, 8))!
        switch form {
        case .input(let input):
            if input.mode == .multiline {
                gtk_scrolled_window_set_has_frame(scroller, 1)
                let editor = op(gtk_text_view_new())!
                let buffer = OpaquePointer(gtk_text_view_get_buffer(cast(editor)))!
                gtk_text_view_set_wrap_mode(cast(editor), GTK_WRAP_WORD_CHAR)
                gtk_text_view_set_top_margin(cast(editor), 8)
                gtk_text_view_set_bottom_margin(cast(editor), 8)
                gtk_text_view_set_left_margin(cast(editor), 8)
                gtk_text_view_set_right_margin(cast(editor), 8)
                gtk_widget_set_size_request(W(editor), 280, 100)
                gtk_text_buffer_set_text(cast(buffer), widgets.draft?.text ?? input.value, -1)
                widgets.editor = editor
                widgets.buffer = buffer
                widgets.bind(buffer)
                connect(buffer, "changed", unsafeBitCast(onAskFormText as @convention(c) (OpaquePointer?, gpointer?) -> Void, to: GCallback.self))
                gtk_box_append(cast(body), W(editor))
            } else {
                installAskEntry(widgets, in: body, placeholder: input.placeholder)
            }
        case .choices(let list):
            for (index, choice) in list.choices.enumerated() {
                let button = op(gtk_check_button_new())!
                let label = op(gtk_label_new(choice.label))!
                gtk_label_set_wrap(label, 1)
                gtk_label_set_wrap_mode(label, PANGO_WRAP_WORD_CHAR)
                gtk_label_set_max_width_chars(label, 48)
                gtk_label_set_xalign(label, 0)
                gtk_check_button_set_child(cast(button), W(label))
                if !list.multiple, let first = widgets.choices.first { gtk_check_button_set_group(cast(button), cast(first)) }
                gtk_widget_set_name(W(button), "ask-choice-\(index)")
                widgets.choices.append(button)
                widgets.bind(button)
                connect(button, "toggled", unsafeBitCast(onAskFormChoice as @convention(c) (OpaquePointer?, gpointer?) -> Void, to: GCallback.self))
                gtk_box_append(cast(body), W(button))
                if let subtitle = choice.subtitle, let label = op(gtk_label_new(subtitle)) {
                    gtk_label_set_wrap(label, 1)
                    gtk_label_set_xalign(label, 0)
                    gtk_widget_set_margin_start(W(label), 28)
                    gtk_widget_add_css_class(W(label), "dim-label")
                    gtk_box_append(cast(body), W(label))
                }
            }
            if let other = list.other {
                let button = op(gtk_check_button_new_with_label("Other"))!
                if !list.multiple, let first = widgets.choices.first { gtk_check_button_set_group(cast(button), cast(first)) }
                gtk_widget_set_name(W(button), "ask-choice-\(list.choices.count)")
                widgets.choices.append(button)
                widgets.bind(button)
                connect(button, "toggled", unsafeBitCast(onAskFormChoice as @convention(c) (OpaquePointer?, gpointer?) -> Void, to: GCallback.self))
                gtk_box_append(cast(body), W(button))
                installAskEntry(widgets, in: body, placeholder: other)
            }
        }
        if let editor = widgets.editor {
            gtk_widget_add_css_class(W(editor), "view")
            let preedit = widgets.buffer != nil ? editor : gtk_editable_get_delegate(editor) ?? editor
            widgets.bind(preedit)
            connect(preedit, "preedit-changed", unsafeBitCast(onAskFormPreedit as @convention(c)
                (OpaquePointer?, UnsafePointer<CChar>?, gpointer?) -> Void, to: GCallback.self))
        }
        widgets.refreshChoices()
        gtk_scrolled_window_set_child(scroller, W(body))
        gtk_box_append(cast(content), W(scroller))
        return widgets
    }

    private func installAskEntry(_ widgets: LinuxAskFormWidgets, in body: OpaquePointer, placeholder: String?) {
        let entry = op(gtk_entry_new())!
        widgets.editor = entry
        gtk_editable_set_text(entry, widgets.draft?.text ?? "")
        if let placeholder { gtk_entry_set_placeholder_text(cast(entry), placeholder) }
        widgets.bind(entry)
        connect(entry, "changed", unsafeBitCast(onAskFormText as @convention(c) (OpaquePointer?, gpointer?) -> Void, to: GCallback.self))
        gtk_box_append(cast(body), W(entry))
    }

    /// nil leaves button navigation to the plain-ask handler; false lets an editor consume its text keys.
    func handleAskFormKey(_ widget: OpaquePointer, key: UInt32, modifiers: UInt32) -> Bool? {
        let form = widget == guiAskWindow ? guiAskForm : terminalAskSurfaces.values.first { $0.root == widget }?.form
        guard let form else { return nil }
        let control = modifiers & UInt32(GDK_CONTROL_MASK.rawValue) != 0
        if form.composing { return control && (key == 119 || key == 87) }
        if key == 0xFF09 || key == 0xFE20 { return false }
        if key == 0xFF1B { return nil }
        if form.buttonHasFocus, key == 32 || key == 0xFF0D || key == 0xFF8D { return false }
        if key == 0xFF0D || key == 0xFF8D {
            if case .input(let input) = form.ask.form, input.mode == .multiline, !control { return false }
            return nil
        }
        if case .choices = form.ask.form {
            if form.editorHasFocus, key != 0xFF52 && key != 0xFF54 { return false }
            if key == 0xFF52 || key == 0xFF54 {
                form.update { $0.moveCursor(by: key == 0xFF52 ? -1 : 1) }
                form.focusCursor()
                return true
            }
            if key == 32 { form.update { $0.toggleCursor() }; return true }
            return nil
        }
        return false
    }
}

private let releaseAskForm: @convention(c) (gpointer?) -> Void = { data in
    if let data { Unmanaged<LinuxAskFormWidgets>.fromOpaque(data).release() }
}

@MainActor private func askForm(_ object: OpaquePointer?) -> LinuxAskFormWidgets? {
    guard let object, let data = g_object_get_data(cast(object), "agterm-ask-form") else { return nil }
    return Unmanaged<LinuxAskFormWidgets>.fromOpaque(data).takeUnretainedValue()
}

private let onAskFormText: @MainActor @convention(c) (OpaquePointer?, gpointer?) -> Void = { object, _ in
    askForm(object)?.textChanged()
}

private let onAskFormPreedit: @MainActor @convention(c) (OpaquePointer?, UnsafePointer<CChar>?, gpointer?) -> Void = { object, text, _ in
    askForm(object)?.composing = text.map { $0.pointee != 0 } ?? false
}

private let onAskFormChoice: @MainActor @convention(c) (OpaquePointer?, gpointer?) -> Void = { button, _ in
    guard let form = askForm(button), !form.updating, let button,
          let index = form.choices.firstIndex(of: button) else { return }
    if case .choices(let list) = form.ask.form, !list.multiple, gtk_check_button_get_active(cast(button)) == 0 { return }
    form.update { $0.toggle(at: index) }
}
