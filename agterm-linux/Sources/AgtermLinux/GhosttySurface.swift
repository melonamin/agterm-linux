// A libghostty terminal surface backed by a GtkGLArea. Conforms to agtermCore's
// TerminalSurface seam (the macOS GhosttySurfaceView is the sibling conformer).
// Owns the GtkGLArea widget + the ghostty_surface_t; drives realize/render/resize
// and routes keyboard/focus into libghostty.
import CGtk
import agtermCore
import Foundation

enum LinuxOverlayExitCapture {
    static func consume(_ file: String) -> Int? {
        defer { try? FileManager.default.removeItem(atPath: file) }
        guard let text = try? String(contentsOfFile: file, encoding: .utf8) else { return nil }
        return OverlayCapture.parseExitCode(text)
    }
}

@MainActor
final class GhosttySurface: TerminalSurface {
    /// Stable surface-local host. The GtkGLArea stays its child while the host is reparented for terminal
    /// zoom and overlays; a creation failure adds its diagnostic here and cannot cover sibling surfaces.
    let rootWidget: OpaquePointer
    /// The GtkGLArea widget (stored as OpaquePointer; cast at GTK call sites).
    let glArea: OpaquePointer
    private(set) var surface: ghostty_surface_t?
    var isRealized: Bool { surface != nil }
    /// The key controller + a GtkIMContext for composed input (dead-keys / compose / CJK): key events are
    /// filtered through the IM, which commits the composed text via the `commit` signal.
    private var keyController: OpaquePointer?
    private var imContext: OpaquePointer?
    private var creationErrorLabel: OpaquePointer?

    /// The owning session's id (so the host can route close/title back to the model).
    let sessionID: UUID
    fileprivate weak var controller: AppController?
    /// Concrete host role; unlike a split boolean this distinguishes notification and focus behavior
    /// for main, split, overlay, scratch, and quick surfaces.
    private(set) var role: LinuxSurfaceRole
    var isSplitPane: Bool { role == .split }
    /// The shell's working directory.
    private let cwd: String
    /// Optional explicit command; nil runs the user's default login shell.
    private let command: String?
    /// A fixed background owned by an overlay surface rather than the underlying session.
    private let fixedBackgroundColor: String?
    /// Program overlays use the theme default unless they explicitly own a color.
    private let usesSessionWatermark: Bool
    /// Whether command surfaces should linger on ghostty's "press any key" prompt after exit.
    private let waitAfterCommand: Bool
    /// Scratch/overlay/quick terminals are transient covers; their OSC title/PWD must not overwrite the
    /// owning session's primary/split pane state.
    private let reportsPaneState: Bool
    /// Per-session font-size override (points) to seed at creation, restoring a persisted ⌘+/⌘− zoom;
    /// nil uses the config default.
    private let fontSize: Double?
    /// Optional text fed to the shell at startup (restore-running-command re-runs the captured argv);
    /// runs INSIDE the shell so its exit returns to a prompt (unlike `command`).
    private let initialInput: String?
    /// `AGTERM_*` (and any other) env vars to inject into the spawned shell, plus the pre-launch
    /// GDK_DISABLE/GDK_DEBUG values `main()` overwrote — this init is the single choke point every
    /// surface role (main, split, scratch, overlay, quick) goes through, so the restore is merged here
    /// rather than at each construction site.
    private let env: [String: String]
    /// The last libghostty-requested pointer state. GTK may receive visibility, link-hover, and shape
    /// actions independently, so keep all three and re-apply their precedence instead of letting one
    /// callback accidentally reset another.
    private var mouseVisible = true
    private var mouseOverLink = false
    private var mouseShapeName = "text"
    /// Surface-owned C configuration buffers. libghostty may consume these after surface creation.
    private var configurationStorage: GhosttySurfaceConfigurationStorage?
    /// Per-surface overlay configs (session background/font override), retained until a newer overlay
    /// replaces them or the surface is torn down.
    private var ownedConfigs: [ghostty_config_t] = []
    private var oscBackgroundColorHex: String?
    private var pendingFontRestore: Double?
    var dashboardFontOverride: Double? {
        didSet {
            guard dashboardFontOverride != oldValue else { return }
            reapplyBackgroundOverlay(force: true)
            guard dashboardFontOverride == nil, let cleared = oldValue else {
                pendingFontRestore = nil
                return
            }
            let sessionFont = controller?.store.session(withID: sessionID)?.fontSize
            let target = sessionFont ?? linuxSettingsStore().load().fontSize
                ?? DashboardLayout.ghosttyDefaultFontSize
            pendingFontRestore = abs(cleared - target) > 0.5 ? target : nil
        }
    }

    /// A host-supplied size estimate (logical GTK units) for a surface whose GtkGLArea carries no
    /// allocation of its own. Set ONLY by `syncOverlay`'s floating branch — see `pushSize`.
    var sizeFallback: (width: Int32, height: Int32)?

    /// Set by the host: the shell process exited.
    var onExit: (() -> Void)?
    private var exitCodeFile: String?
    private var onExitCodeCaptured: ((Int) -> Void)?
    private var didHandleProcessExit = false

    isolated deinit {
        if let surface { ghostty_surface_free(surface) }
        ownedConfigs.forEach { ghostty_config_free($0) }
        configurationStorage?.release()
        if let exitCodeFile { try? FileManager.default.removeItem(atPath: exitCodeFile) }
    }

    init(sessionID: UUID, cwd: String, command: String? = nil, env: [String: String] = [:],
         controller: AppController? = nil, waitAfterCommand: Bool = false,
         role: LinuxSurfaceRole = .main, reportsPaneState: Bool = true,
         fontSize: Double? = nil, initialInput: String? = nil, backgroundColor: String? = nil,
         usesSessionWatermark: Bool = true) {
        self.sessionID = sessionID
        self.controller = controller
        self.role = role
        self.cwd = cwd
        self.command = command
        fixedBackgroundColor = backgroundColor
        self.usesSessionWatermark = usesSessionWatermark
        self.waitAfterCommand = waitAfterCommand
        self.reportsPaneState = reportsPaneState
        self.fontSize = fontSize
        self.initialInput = initialInput
        self.env = gdkEnvironment.childEnvironment(merging: env)
        rootWidget = OpaquePointer(gtk_overlay_new())
        glArea = OpaquePointer(gtk_gl_area_new())
        gtk_overlay_set_child(rootWidget, W(glArea))
        gtk_widget_set_hexpand(W(rootWidget), 1)
        gtk_widget_set_vexpand(W(rootWidget), 1)
        gtk_gl_area_set_allowed_apis(GLA(glArea), GDK_GL_API_GL)
        gtk_gl_area_set_has_depth_buffer(GLA(glArea), 0)
        gtk_widget_set_hexpand(W(glArea), 1)
        gtk_widget_set_vexpand(W(glArea), 1)
        gtk_widget_set_focusable(W(glArea), 1)

        // The GtkGLArea OWNS a retained reference to this surface (released on its "destroy"), so the
        // signal handlers' user_data can never outlive the Swift object. With passUnretained, a focus
        // controller firing "leave" during widget teardown dereferenced a freed GhosttySurface (a
        // use-after-free SIGSEGV in `wrap`). The widget lifetime now bounds the object lifetime.
        let me = Unmanaged.passRetained(self).toOpaque()
        connect(glArea, "destroy", unsafeBitCast(surfaceDestroy as @convention(c) (OpaquePointer?, gpointer?) -> Void, to: GCallback.self), me)
        connect(glArea, "realize", unsafeBitCast(surfaceRealize as @convention(c) (OpaquePointer?, gpointer?) -> Void, to: GCallback.self), me)
        connect(glArea, "render", unsafeBitCast(surfaceRender as @convention(c) (OpaquePointer?, OpaquePointer?, gpointer?) -> gboolean, to: GCallback.self), me)
        connect(glArea, "resize", unsafeBitCast(surfaceResize as @convention(c) (OpaquePointer?, Int32, Int32, gpointer?) -> Void, to: GCallback.self), me)

        let keyCtl = gtk_event_controller_key_new()
        keyController = keyCtl
        connect(keyCtl, "key-pressed", unsafeBitCast(surfaceKeyPressed as @convention(c) (OpaquePointer?, UInt32, UInt32, UInt32, gpointer?) -> gboolean, to: GCallback.self), me)
        connect(keyCtl, "key-released", unsafeBitCast(surfaceKeyReleased as @convention(c) (OpaquePointer?, UInt32, UInt32, UInt32, gpointer?) -> Void, to: GCallback.self), me)
        gtk_widget_add_controller(W(glArea), keyCtl)

        let im = OpaquePointer(gtk_im_multicontext_new())
        imContext = im
        gtk_im_context_set_client_widget(cast(im), W(glArea))
        connect(im, "commit", unsafeBitCast(surfaceIMCommit as @convention(c) (OpaquePointer?, UnsafePointer<CChar>?, gpointer?) -> Void, to: GCallback.self), me)
        connect(im, "preedit-changed", unsafeBitCast(surfacePreeditChanged as @convention(c) (OpaquePointer?, gpointer?) -> Void, to: GCallback.self), me)

        let focusCtl = gtk_event_controller_focus_new()
        connect(focusCtl, "enter", unsafeBitCast(surfaceFocusEnter as @convention(c) (OpaquePointer?, gpointer?) -> Void, to: GCallback.self), me)
        connect(focusCtl, "leave", unsafeBitCast(surfaceFocusLeave as @convention(c) (OpaquePointer?, gpointer?) -> Void, to: GCallback.self), me)
        gtk_widget_add_controller(W(glArea), focusCtl)

        let click = gtk_gesture_click_new()
        gtk_gesture_single_set_button(click, 0)   // report all buttons, not just primary
        connect(click, "pressed", unsafeBitCast(surfaceClicked as @convention(c) (OpaquePointer?, Int32, Double, Double, gpointer?) -> Void, to: GCallback.self), me)
        connect(click, "released", unsafeBitCast(surfaceReleased as @convention(c) (OpaquePointer?, Int32, Double, Double, gpointer?) -> Void, to: GCallback.self), me)
        gtk_widget_add_controller(W(glArea), click)

        let motion = gtk_event_controller_motion_new()
        connect(motion, "motion", unsafeBitCast(surfaceMotion as @convention(c) (OpaquePointer?, Double, Double, gpointer?) -> Void, to: GCallback.self), me)
        connect(motion, "enter", unsafeBitCast(surfaceMotion as @convention(c) (OpaquePointer?, Double, Double, gpointer?) -> Void, to: GCallback.self), me)
        connect(motion, "leave", unsafeBitCast(surfaceLeave as @convention(c) (OpaquePointer?, gpointer?) -> Void, to: GCallback.self), me)
        gtk_widget_add_controller(W(glArea), motion)

        let scroll = gtk_event_controller_scroll_new(GTK_EVENT_CONTROLLER_SCROLL_BOTH_AXES)
        connect(scroll, "scroll", unsafeBitCast(surfaceScroll as @convention(c) (OpaquePointer?, Double, Double, gpointer?) -> gboolean, to: GCallback.self), me)
        gtk_widget_add_controller(W(glArea), scroll)

        // File/text drops insert paths/text at the cursor, matching the macOS drag-drop behavior. Sidebar
        // reorder drags use MOVE, while these targets accept COPY, so internal row drags don't land here.
        let stringDrop = gtk_drop_target_new(GType(64) /* G_TYPE_STRING */, GDK_ACTION_COPY)
        connect(stringDrop, "drop", unsafeBitCast(surfaceDropString as @convention(c) (OpaquePointer?, UnsafePointer<GValue>?, Double, Double, gpointer?) -> gboolean, to: GCallback.self), me)
        gtk_widget_add_controller(W(glArea), stringDrop)

        let fileDrop = gtk_drop_target_new(gdk_file_list_get_type(), GDK_ACTION_COPY)
        connect(fileDrop, "drop", unsafeBitCast(surfaceDropFiles as @convention(c) (OpaquePointer?, UnsafePointer<GValue>?, Double, Double, gpointer?) -> gboolean, to: GCallback.self), me)
        gtk_widget_add_controller(W(glArea), fileDrop)
    }

    // MARK: - Lifecycle

    func realize() {
        // A second realize over a live surface means the GLArea was reparented; the pane is blank from
        // here on ([[libghostty]]) and only this line can say so, since AT-SPI cannot see a blank pane.
        if surface != nil {
            FileHandle.standardError.write(
                Data("agterm: GLArea re-realized over a live surface (\(role)); the pane is blank\n".utf8))
        }
        if LinuxSurfaceFailureInjection.failure(for: role) == .glContext {
            reportGLContextFailure(message: "injected by AGTERM_ATSPI_SURFACE_FAILURE")
            return
        }
        gtk_gl_area_make_current(GLA(glArea))
        if let error = gtk_gl_area_get_error(GLA(glArea)) {
            // The GError belongs to the GLArea (never freed here), and its message is the only place the
            // real reason is named — the overlay stays generic, so this line is the diagnostic of record.
            let message = error.pointee.message.map { String(cString: $0) }
            reportGLContextFailure(message: message)
            return
        }
        createSurface()
    }

    private func reportGLContextFailure(message: String? = nil) {
        let line = LinuxGdkPolicy.glContextErrorLine(message: message)
        FileHandle.standardError.write(Data((line + "\n").utf8))
        // Defer until window construction completes, but retain the surface's owner rather than
        // whichever window becomes frontmost before the main-loop hop runs.
        runOnMain { [weak controller] in MainActor.assumeIsolated { controller?.showGLError() } }
    }

    func realizeWidgetIfNeeded() {
        gtk_widget_realize(W(glArea))
    }

    func applyHostConfigChange() {
        controller?.applySidebarThemeColor()
    }

    private func createSurface() {
        guard surface == nil, let app = GhosttyApp.shared.app else { return }
        let scale = gtk_widget_get_scale_factor(W(glArea))
        var cfg = ghostty_surface_config_new()
        cfg.platform_tag = GHOSTTY_PLATFORM_OPENGL
        cfg.platform.opengl.userdata = Unmanaged.passUnretained(self).toOpaque()
        cfg.platform.opengl.make_current = { ud in
            guard let w = GhosttyApp.wrapper(from: ud) else { return }
            gtk_gl_area_make_current(GLA(w.glArea))
        }
        cfg.userdata = Unmanaged.passUnretained(self).toOpaque()
        cfg.scale_factor = Double(scale)
        if let fontSize { cfg.font_size = Float(fontSize) }   // restore a persisted per-session zoom
        guard let storage = GhosttySurfaceConfigurationStorage(
            workingDirectory: cwd, command: command, initialInput: initialInput, environment: env
        ) else {
            FileHandle.standardError.write(Data("agterm: could not allocate libghostty surface configuration\n".utf8))
            showCreationFailure()
            return
        }
        configurationStorage = storage
        storage.apply(to: &cfg)
        if command != nil {
            cfg.wait_after_command = waitAfterCommand
        }
        let appearanceSide = LinuxAppearanceSide(isDark: AppController.systemIsDark)
        GhosttyApp.shared.applyColorScheme(appearanceSide)
        if LinuxSurfaceFailureInjection.failure(for: role) == .creation {
            surface = nil
        } else {
            surface = ghostty_surface_new(app, &cfg)
        }
        guard let surface else {
            // libghostty exposes no error value here and may reject one surface for fonts, renderer,
            // config, terminal initialization, or allocation. Keep the diagnostic on this exact host;
            // only GtkGLArea's proven context error is display-wide.
            FileHandle.standardError.write(Data("agterm: libghostty rejected the surface\n".utf8))
            showCreationFailure()
            storage.release()
            configurationStorage = nil
            return
        }
        clearCreationFailure()
        ghostty_surface_set_content_scale(surface, Double(scale), Double(scale))
        pushSize()
        ghostty_surface_set_focus(surface, true)
        applyColorScheme(appearanceSide)   // report the system light/dark scheme (OSC color-scheme queries)
        feed(GhosttyApp.shared.currentThemeOSC)   // push theme colors the embedded GL renderer won't adopt from config
        if fixedBackgroundColor != nil
                || usesSessionWatermark && controller?.store.session(withID: sessionID)?.backgroundWatermark != nil {
            applyWatermarkFromSession()
        }
    }

    private func showCreationFailure() {
        let presentation = LinuxSurfaceFailurePresentation.resolve(.creation, role: role)
        guard presentation.scope == .surfaceLocal else { return }
        if let label = creationErrorLabel {
            gtk_label_set_text(label, presentation.message)
            return
        }
        guard let label = op(gtk_label_new(presentation.message)) else { return }
        gtk_label_set_justify(label, GTK_JUSTIFY_CENTER)
        gtk_label_set_wrap(label, 1)
        gtk_widget_set_halign(W(label), GTK_ALIGN_CENTER)
        gtk_widget_set_valign(W(label), GTK_ALIGN_CENTER)
        gtk_widget_set_can_target(W(label), 0)
        gtk_widget_add_css_class(W(label), "agterm-surface-error")
        creationErrorLabel = label
        gtk_overlay_add_overlay(rootWidget, W(label))
    }

    private func clearCreationFailure() {
        guard let label = creationErrorLabel else { return }
        gtk_overlay_remove_overlay(rootWidget, W(label))
        creationErrorLabel = nil
    }

    /// Size the surface at CREATION — the only path that reaches the fallback, since `createSurface()`
    /// is guarded by `surface == nil` and every later size change goes through `resize(width:height:)`.
    /// Precedence: the widget's own allocation, then the stored estimate, then the deck allocation, then
    /// the clamp. Only the floating overlay needs a STORED estimate — its frame is
    /// `gtk_widget_set_visible(0)` and never laid out at all while its session is backgrounded, while
    /// every other surface is in layout and is corrected by the `GtkGLArea::resize` that follows.
    private func pushSize() {
        guard let surface else { return }
        let inputs = GhosttySurfaceGeometry.InitialSizeInputs(
            gtkWidth: gtk_widget_get_width(W(glArea)),
            gtkHeight: gtk_widget_get_height(W(glArea)),
            scaleFactor: gtk_widget_get_scale_factor(W(glArea)),
            storedFallback: sizeFallback,
            deckFallback: controller?.deckAllocationSize())
        GhosttySurfaceGeometry.pushInitialSize(
            inputs, setSurfaceSize: { ghostty_surface_set_size(surface, $0, $1) })
    }

    func render() {
        guard let surface else { return }
        ghostty_surface_draw(surface)
    }

    func queueRender() {
        guard surface != nil else { return }   // ignore stray RENDER after teardown
        gtk_gl_area_queue_render(GLA(glArea))
    }

    /// Run a libghostty binding action on this surface (font size, search, etc.) —
    /// the same seam macOS's GhosttySurfaceView.performBindingAction uses.
    func performBindingAction(_ action: String) {
        guard let surface else { return }
        _ = action.withCString { ghostty_surface_binding_action(surface, $0, UInt(action.utf8.count)) }
    }

    /// Inject text as keystrokes (the control channel's session.type): printable runs go
    /// as key-with-text, each newline as a Return keypress (keycode 36 = XKB Return). NOT
    /// ghostty_surface_text, whose bracketed-paste wrapping suppresses Enter.
    @discardableResult
    func inject(text: String) -> Bool {
        guard let surface else { return false }
        // Split into printable runs + Return keys via the shared segmenter (one typing policy for both
        // platforms); send each run as text and each line break as a real Return key press.
        for segment in KeystrokeSegments.split(text) {
            switch segment {
            case .text(let run):
                run.withCString { ptr in
                    var ke = ghostty_input_key_s()
                    ke.action = GHOSTTY_ACTION_PRESS
                    ke.text = ptr
                    _ = ghostty_surface_key(surface, ke)
                }
            case .returnKey:
                var ke = ghostty_input_key_s()
                ke.keycode = 36   // Return (XKB)
                ke.action = GHOSTTY_ACTION_PRESS
                _ = ghostty_surface_key(surface, ke)
                ke.action = GHOSTTY_ACTION_RELEASE
                _ = ghostty_surface_key(surface, ke)
            }
        }
        return true
    }

    /// Feed raw bytes into the terminal as if read from the pty — used to push theme colors (OSC 11/10/4/…)
    /// that the embedded OpenGL renderer doesn't adopt from the config. `ghostty_surface_feed` runs them
    /// through the terminal parser under the renderer lock, so it's safe from the main thread.
    func feed(_ bytes: String) {
        guard let surface, !bytes.isEmpty else { return }
        bytes.withCString { ghostty_surface_feed(surface, $0, UInt(bytes.utf8.count)) }
    }

    // MARK: - In-terminal search (libghostty replies via the START/END/TOTAL/SELECTED actions)

    func applyWatermarkFromSession(windowOpacity: Double? = nil, settings: AppSettings? = nil) {
        // An explicit session.background set/clear owns the config overlay until a program emits OSC 11
        // again. Release the dedupe latch so re-emitting the same OSC color is not ignored.
        oscBackgroundColorHex = nil
        reapplyBackgroundOverlay(windowOpacity: windowOpacity, settings: settings, force: true)
    }

    private func reapplyBackgroundOverlay(windowOpacity: Double? = nil, settings: AppSettings? = nil,
                                          force: Bool = false) {
        guard let surface else { return }
        let session = controller?.store.session(withID: sessionID)
        let watermark = oscBackgroundColorHex.map {
            BackgroundWatermark(kind: .color, colorHex: $0)
        } ?? fixedBackgroundColor.map {
            BackgroundWatermark(kind: .color, colorHex: $0)
        } ?? (usesSessionWatermark ? session?.backgroundWatermark : nil)
        guard force || watermark != nil || dashboardFontOverride != nil || session?.fontSize != nil else { return }
        let resolvedImagePath = session.flatMap {
            WatermarkRenderer.materialize(watermark, sessionID: $0.id)
        }
        let effectiveWindowOpacity = windowOpacity ?? linuxSettingsStore().load().backgroundOpacity ?? 1
        let overlay = WatermarkConfig.overlayText(watermark: watermark,
                                                  resolvedImagePath: resolvedImagePath,
                                                  fontSize: dashboardFontOverride ?? session?.fontSize ?? fontSize,
                                                  windowOpacity: effectiveWindowOpacity)
        guard let config = GhosttyApp.shared.configWithOverlay(overlay, settings: settings) else { return }
        ghostty_surface_update_config(surface, config)
        ownedConfigs.forEach { ghostty_config_free($0) }
        ownedConfigs = [config]
        let osc = AppSettings.themeOSC(from: overlay.split(separator: "\n", omittingEmptySubsequences: true).map(String.init))
        if !osc.isEmpty { feed(osc) }
        queueRender()
    }

    func reapplyWatermarkIfNeeded(windowOpacity: Double? = nil, settings: AppSettings? = nil) {
        guard oscBackgroundColorHex != nil
                || fixedBackgroundColor != nil
                || usesSessionWatermark
                    && controller?.store.session(withID: sessionID)?.backgroundWatermark != nil else { return }
        reapplyBackgroundOverlay(windowOpacity: windowOpacity, settings: settings)
    }

    /// Automatic appearance reconciliation restores every per-session overlay.
    /// Explicit reloads keep the watermark-only path.
    func reapplySessionConfigIfNeeded(windowOpacity: Double? = nil, settings: AppSettings? = nil) {
        reapplyBackgroundOverlay(windowOpacity: windowOpacity, settings: settings)
    }

    /// Make a program's per-pane OSC 11 background visible through agterm's transparent surface config.
    /// libghostty already owns the live color override; this overlay supplies the matching opacity and is
    /// retained/re-applied per surface across config reloads.
    func applyOSCBackground(red: UInt8, green: UInt8, blue: UInt8) {
        let hex = String(format: "#%02X%02X%02X", red, green, blue)
        let inheritedColor = usesSessionWatermark
            ? controller?.store.session(withID: sessionID)?.backgroundWatermark
                .flatMap { $0.kind == .color ? $0.colorHex : nil }
            : nil
        let sessionColor = fixedBackgroundColor ?? inheritedColor
        let baseline = OSCBackgroundPolicy.baseline(
            oscOverlayActive: oscBackgroundColorHex != nil,
            surfaceBackground: sessionColor,
            themeBackground: GhosttyApp.shared.currentThemeBackgroundHex
        )
        switch OSCBackgroundPolicy.decide(
            incoming: hex, themeBackground: baseline, current: oscBackgroundColorHex
        ) {
        case .apply(let color):
            oscBackgroundColorHex = color
            reapplyBackgroundOverlay()
        case .reset:
            oscBackgroundColorHex = nil
            reapplyBackgroundOverlay(force: true)
        case .ignore:
            break
        }
    }

    func startSearch() { performBindingAction("start_search") }
    func endSearch() { performBindingAction("end_search") }
    func sendSearchQuery(_ needle: String) { performBindingAction("search:\(needle)") }
    func navigateSearch(_ direction: SearchDirection) { performBindingAction(direction.ghosttyAction) }

    func applySearchStart(_ needle: String?) { controller?.searchDidStart(sessionID, needle: needle) }
    func applySearchEnd() { controller?.searchDidEnd(sessionID) }
    func applyProgress(_ value: Int?) { controller?.surfaceDidReportProgress(sessionID, percent: value) }
    func applySearchTotal(_ total: Int?) { controller?.searchDidReportTotal(sessionID, total: total) }
    func applySearchSelected(_ selected: Int?) { controller?.searchDidReportSelected(sessionID, selected: selected) }

    /// The current selection text (the control channel's session.copy), or nil if none.
    func readSelection() -> String? {
        guard let surface, ghostty_surface_has_selection(surface) else { return nil }
        var out = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &out) else { return nil }
        defer { ghostty_surface_free_text(surface, &out) }
        guard let ptr = out.text else { return nil }
        let s = String(cString: ptr)
        return s.isEmpty ? nil : s
    }

    func readScreenText(all: Bool, lines: Int?) -> String? {
        guard let surface else { return nil }
        let tag = (all || lines != nil) ? GHOSTTY_POINT_SCREEN : GHOSTTY_POINT_VIEWPORT
        var sel = ghostty_selection_s()
        sel.top_left = ghostty_point_s(tag: tag, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0)
        sel.bottom_right = ghostty_point_s(tag: tag, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0)
        sel.rectangle = false
        var out = ghostty_text_s()
        guard ghostty_surface_read_text(surface, sel, &out) else { return nil }
        defer { ghostty_surface_free_text(surface, &out) }
        guard let ptr = out.text, out.text_len > 0 else { return "" }
        let full = String(decoding: UnsafeRawBufferPointer(start: ptr, count: Int(out.text_len)), as: UTF8.self)
        guard let n = lines, n > 0 else { return full }
        var rows = full.components(separatedBy: "\n")
        while let last = rows.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            rows.removeLast()
        }
        return rows.suffix(n).joined(separator: "\n")
    }

    func resize(width: Int32, height: Int32) {
        guard let surface else { return }
        let scale = gtk_widget_get_scale_factor(W(glArea))
        ghostty_surface_set_content_scale(surface, Double(scale), Double(scale))
        let viewport = GhosttySurfaceGeometry.resizedViewport(
            widthPixels: width,
            heightPixels: height
        )
        ghostty_surface_set_size(surface, viewport.width, viewport.height)
    }

    /// Forward a GTK scroll event to libghostty. ghostty's convention is "positive = up,
    /// right" while GTK's is "positive dy = down", so the Y axis is inverted. Mouse wheels
    /// (WHEEL unit) are non-precision ticks; touchpads (SURFACE unit) are precision pixel
    /// scrolls, which ghostty measures against the device-pixel cell height — hence the
    /// scale conversion.
    func scroll(controller: OpaquePointer?, dx: Double, dy: Double) {
        guard let surface else { return }
        var mods: ghostty_input_scroll_mods_t = 0
        var sx = dx, sy = dy
        if let controller, gtk_event_controller_scroll_get_unit(controller) == GDK_SCROLL_UNIT_SURFACE {
            let scale = Double(gtk_widget_get_scale_factor(W(glArea)))
            sx *= scale
            sy *= scale
            mods = 1   // precision bit (ghostty ScrollMods.precision)
        }
        // ghostty's convention is "positive = up/right"; GTK's is "positive dy = down",
        // so invert Y. The wheel/touchpad delta drives scrollback the same as macOS.
        ghostty_surface_mouse_scroll(surface, sx, -sy, mods)
    }

    /// The modifier state of the event currently being dispatched on `controller`.
    private func currentMods(_ controller: OpaquePointer?) -> ghostty_input_mods_e {
        guard let controller else { return GHOSTTY_MODS_NONE }
        return ghosttyMods(gtk_event_controller_get_current_event_state(controller).rawValue)
    }

    /// Forward the pointer position in GTK widget coordinates; the embedded libghostty API
    /// applies the surface content scale before it builds selections and mouse reports for
    /// TUIs (Claude, vim, htop). Without this, apps on the alternate screen never see the
    /// wheel/clicks. Also serves the "enter" signal (same shape), so hover state arms as soon
    /// as the pointer arrives.
    func mouseMoved(_ controller: OpaquePointer?, x: Double, y: Double) {
        guard let surface else { return }
        let point = GhosttySurfaceGeometry.pointerPosition(gtkX: x, gtkY: y)
        ghostty_surface_mouse_pos(surface, point.x, point.y, currentMods(controller))
    }

    /// Pointer left the surface: report an out-of-bounds position so libghostty clears
    /// hover state (link underline, motion-tracking highlights).
    func mouseLeft() {
        guard let surface else { return }
        ghostty_surface_mouse_pos(surface, -1, -1, GHOSTTY_MODS_NONE)
    }

    func mouseButton(_ gesture: OpaquePointer?, pressed: Bool, x: Double, y: Double) {
        guard let surface else { return }
        let point = GhosttySurfaceGeometry.pointerPosition(gtkX: x, gtkY: y)
        let mods = currentMods(gesture)
        ghostty_surface_mouse_pos(surface, point.x, point.y, mods)
        let btn = gesture.map { gtk_gesture_single_get_current_button($0) } ?? 1
        let gbtn: ghostty_input_mouse_button_e = btn == 2 ? GHOSTTY_MOUSE_MIDDLE : (btn == 3 ? GHOSTTY_MOUSE_RIGHT : GHOSTTY_MOUSE_LEFT)
        _ = ghostty_surface_mouse_button(surface, pressed ? GHOSTTY_MOUSE_PRESS : GHOSTTY_MOUSE_RELEASE, gbtn, mods)
    }

    func setFocus(_ focused: Bool) {
        guard let surface else { return }
        ghostty_surface_set_focus(surface, focused)
    }

    /// Show/hide the mouse pointer over this surface (GHOSTTY_ACTION_MOUSE_VISIBILITY): a blank "none"
    /// cursor when hidden, the inherited default when visible.
    func setMouseVisible(_ visible: Bool) {
        mouseVisible = visible
        applyMouseCursor()
    }

    /// Set the link-hover cursor (GHOSTTY_ACTION_MOUSE_OVER_LINK): the hand "pointer" over a hyperlink,
    /// the default otherwise.
    func setLinkHover(_ overLink: Bool) {
        mouseOverLink = overLink
        applyMouseCursor()
    }

    /// Set the pointer shape over this surface (GHOSTTY_ACTION_MOUSE_SHAPE). The enum→CSS-name
    /// mapping lives in `MouseShapeCursorName` (host-free, unit-tested, covers the complete
    /// libghostty set including GHOSTTY_MOUSE_SHAPE_DEFAULT → the arrow).
    func setMouseShape(_ shape: ghostty_action_mouse_shape_e) {
        mouseShapeName = MouseShapeCursorName.cssName(for: shape)
        applyMouseCursor()
    }

    private func applyMouseCursor() {
        let name = !mouseVisible ? "none" : (mouseOverLink ? "pointer" : mouseShapeName)
        name.withCString { gtk_widget_set_cursor_from_name(W(glArea), $0) }
    }

    /// Push the captured system light/dark scheme to the surface (at create + on style-manager change).
    func applyColorScheme(_ side: LinuxAppearanceSide) {
        guard let surface else { return }
        ghostty_surface_set_color_scheme(
            surface, side.isDark ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT)
    }

    func grabFocus(supersedingPopoverCapture: Bool = false) {
        // Explicit user/control transfers are newer than any search-entry owner captured before a
        // popover took the keyboard. Implicit repair grabs (window reactivation and popover dismissal)
        // deliberately keep the capture so the entry can be restored after GTK moves focus transiently.
        let mapped = gtk_widget_get_mapped(W(glArea)) != 0
        let accepted = gtk_widget_grab_focus(W(glArea)) != 0
        if mapped, accepted, supersedingPopoverCapture {
            controller?.invalidatePopoverSearchEntryCapture()
        }
    }

    /// Force libghostty to redraw this surface (e.g. after a split re-layout), mirroring the macOS
    /// `ghostty_surface_refresh` call so a pane never shows a stale frame at the old size.
    func refresh() {
        guard let surface else { return }
        ghostty_surface_refresh(surface)
    }

    // MARK: - Input

    func keyPressed(keyval: UInt32, keycode: UInt32, state: UInt32, event: OpaquePointer?) -> Bool {
        guard let surface else { return false }
        controller?.noteUserActivity()

        let control = (state & (1 << 2)) != 0
        let hasOtherModifiers = (state & ((1 << 0) | (1 << 3) | (1 << 26))) != 0
        let baseScalar = Unicode.Scalar(gdk_keyval_to_unicode(gdk_keyval_to_lower(keyval)))
        let isInterrupt = keyval == 0xFF1B || (control && !hasOtherModifiers && baseScalar?.value == 0x63)
        if let pane = role.statusPane {
            controller?.clearAttentionStatus(sessionID, pane: pane, isInterrupt: isInterrupt)
        }

        // App-level shortcuts run first via the shared keymap (rebindable built-ins + custom commands +
        // the fixed arrow/page/font fallback). All the dispatch logic lives in AppController.handleKey so
        // this handler stays thin; ghostty still gets its own binds (Ctrl+Shift+C/V) when handleKey passes.
        if controller?.handleKey(keyval: keyval, keycode: keycode, state: state,
                                 sessionID: sessionID, origin: self,
                                 context: shortcutKeyContext(event: event, keycode: keycode)) == true {
            return true
        }

        // Route through the IM context: a dead-key/compose/CJK sequence is CONSUMED here (its result
        // arrives via the `commit` signal → imCommit). Plain keys pass through (filter returns false) and
        // fall to the raw key path below, so normal typing + control sequences are unchanged.
        if let im = imContext, let ctl = keyController,
           let event = gtk_event_controller_get_current_event(ctl),
           gtk_im_context_filter_keypress(cast(im), event) != 0 {
            return true
        }

        var ke = ghostty_input_key_s()
        ke.action = GHOSTTY_ACTION_PRESS
        ke.keycode = keycode                 // GDK hardware keycode == XKB == ghostty's Linux native code
        // Modifier-only keys: X11/GDK reports the state PRIOR to the event, so the pressed key's own
        // bit is still clear — add it back (see ModifierKeyMods) or libghostty's hover/cursor-shape
        // recompute waits for the next mouse motion. Non-modifier keys pass through unchanged.
        ke.mods = ghosttyMods(ModifierKeyMods.adjustedState(forKeyval: keyval, state: state, pressing: true))
        ke.consumed_mods = GHOSTTY_MODS_NONE

        let unicode = gdk_keyval_to_unicode(keyval)
        // Ctrl/Alt/Super combos and non-printables: send no text and let libghostty
        // encode from keycode+mods (e.g. Ctrl-C -> ^C, arrows, F-keys).
        let hasCtrlAltSuper = (state & ((1 << 2) | (1 << 3) | (1 << 26))) != 0
        if unicode >= 0x20, unicode != 0x7f, !hasCtrlAltSuper, let scalar = Unicode.Scalar(unicode) {
            ke.unshifted_codepoint = unicode
            return String(scalar).withCString { ptr in
                ke.text = ptr
                return ghostty_surface_key(surface, ke)
            }
        } else {
            ke.unshifted_codepoint = unicode >= 0x20 ? unicode : 0
            ke.text = nil
            return ghostty_surface_key(surface, ke)
        }
    }

    /// Forward a modifier-only key release to libghostty (upstream macOS `keyUp` parity): the raw
    /// release state still carries the released key's bit (X11 prior-state), so it is cleared via
    /// ModifierKeyMods before the event goes out.
    func modifierKeyReleased(keyval: UInt32, keycode: UInt32, state: UInt32) {
        guard let surface else { return }
        var ke = ghostty_input_key_s()
        ke.action = GHOSTTY_ACTION_RELEASE
        ke.keycode = keycode
        ke.mods = ghosttyMods(ModifierKeyMods.adjustedState(forKeyval: keyval, state: state, pressing: false))
        ke.consumed_mods = GHOSTTY_MODS_NONE
        ke.text = nil
        ke.unshifted_codepoint = 0
        _ = ghostty_surface_key(surface, ke)
    }

    /// The IM context committed composed text (dead-key/compose/CJK result) → send it to the terminal.
    func imCommit(_ text: String) {
        guard let surface, !text.isEmpty else { return }
        controller?.noteUserActivity()
        text.withCString { ptr in
            var ke = ghostty_input_key_s()
            ke.action = GHOSTTY_ACTION_PRESS
            ke.text = ptr
            _ = ghostty_surface_key(surface, ke)
        }
    }

    /// Tell the IM context the surface gained/lost keyboard focus (so it composes only when focused).
    func imFocus(_ focused: Bool) {
        guard let im = imContext else { return }
        if focused {
            gtk_im_context_focus_in(cast(im))
        } else {
            gtk_im_context_focus_out(cast(im))
        }
    }

    /// The composition-in-progress text changed → show it as ghostty's preedit (underlined CJK/compose
    /// candidate). An empty string clears it (on commit/cancel).
    func imPreeditChanged() {
        guard let surface, let im = imContext else { return }
        var str: UnsafeMutablePointer<CChar>?
        var cursor: Int32 = 0
        gtk_im_context_get_preedit_string(cast(im), &str, nil, &cursor)
        if let str {
            ghostty_surface_preedit(surface, str, UInt(strlen(str)))
            g_free(UnsafeMutableRawPointer(str))
        }
    }

    // MARK: - Actions from libghostty

    func applyTitle(_ title: String) {
        guard reportsPaneState, !title.isEmpty else { return }
        controller?.sessionDidReportTitle(sessionID, title, isSplit: isSplitPane)
    }

    func applyPwd(_ pwd: String) {
        guard reportsPaneState else { return }
        controller?.sessionDidReportPwd(sessionID, pwd, isSplit: isSplitPane)
    }

    /// CELL_SIZE fired (a font-size change via Ctrl+/-, or a DPI change): read the live font size and
    /// persist it on the session so a relaunch restores the zoom. setFontSize no-ops when unchanged,
    /// so a pure DPI change doesn't write. Per-session (both panes share the size).
    func reportFontSize() {
        guard dashboardFontOverride == nil else { return }
        guard let size = currentFontSize() else { return }
        guard size > 0 else { return }
        if let pending = pendingFontRestore {
            pendingFontRestore = nil
            if abs(size - pending) <= 0.5 { return }
        }
        controller?.sessionDidReportFontSize(sessionID, size)
    }

    func currentFontSize() -> Double? {
        guard let surface else { return nil }
        let size = Double(ghostty_surface_inherited_config(surface, GHOSTTY_SURFACE_CONTEXT_WINDOW).font_size)
        return size > 0 ? size : nil
    }

    func handleProcessExit() {
        guard !didHandleProcessExit else { return }
        didHandleProcessExit = true
        finishExitCodeCapture()
        let exit = onExit
        onExit = nil
        exit?()
    }

    func captureExitCode(from file: String, onCapture: @escaping (Int) -> Void) {
        exitCodeFile = file
        onExitCodeCaptured = onCapture
    }

    private func finishExitCodeCapture() {
        guard let file = exitCodeFile else { return }
        defer {
            exitCodeFile = nil
            onExitCodeCaptured = nil
        }
        guard let code = LinuxOverlayExitCapture.consume(file) else { return }
        onExitCodeCaptured?(code)
    }

    var shouldCloseOnChildExitAction: Bool { command != nil && !waitAfterCommand }

    func promoteToPrimary(onExit: (() -> Void)?) {
        role = .main
        self.onExit = onExit
    }

    func promoteToPrimaryPane() {
        role = .main
    }

    func terminalNotificationOrigin() -> LinuxTerminalNotificationOrigin? {
        guard let controller else { return nil }
        let liveOverlayPane = controller.store.session(withID: sessionID)?.paneOverlayRole(of: self)
        guard let pane = role.notificationPane(liveOverlayPane: liveOverlayPane) else { return nil }
        let appActive = gtk_window_is_active(WIN(controller.windowPointer)) != 0
        let firingIsFocused = appActive
            && gtk_widget_get_mapped(W(glArea)) != 0
            && gtk_widget_has_focus(W(glArea)) != 0
        return LinuxTerminalNotificationOrigin(
            windowID: controller.windowID, sessionID: sessionID, pane: pane,
            firingIsFocused: firingIsFocused, appActive: appActive)
    }

    /// Stable spawn identity shared with the shell as `AGTERM_PANE_ID`. The session model resolves this
    /// token against the surface's live slot after a split pane is promoted and a new split is created.
    var paneToken: String { env["AGTERM_PANE_ID"] ?? "" }

    /// The live foreground-process argv (via `/proc/<pid>/cmdline`), or nil at the shell prompt — the
    /// Linux analogue of macOS's KERN_PROCARGS2 capture, used for `tree` introspection / restore.
    func foregroundCommand() -> [String]? {
        guard let surface else { return nil }
        let pid = ghostty_surface_foreground_pid(surface)
        guard pid > 0,
              let data = try? Data(contentsOf: URL(fileURLWithPath: "/proc/\(pid)/cmdline")),
              let argv = CommandRestore.parseProcCmdline(data),
              !CommandRestore.isIdleShell(argv: argv) else { return nil }
        return argv
    }

    // MARK: - TerminalSurface

    func teardown() {
        onExit = nil
        if let surface {
            ghostty_surface_free(surface)
            self.surface = nil
        }
        finishExitCodeCapture()
        ownedConfigs.forEach { ghostty_config_free($0) }
        ownedConfigs = []
        configurationStorage?.release()
        configurationStorage = nil
    }
}

// MARK: - GTK signal trampolines (recover the GhosttySurface from the trailing user_data)

private func wrap(_ data: gpointer?) -> GhosttySurface? {
    guard let data else { return nil }
    return Unmanaged<GhosttySurface>.fromOpaque(data).takeUnretainedValue()
}

/// Releases the retained surface reference the GtkGLArea owned (balances the `passRetained` at connect
/// time). Fired when the widget is destroyed — the LAST signal, so the object stays valid through any
/// focus-leave/etc. emitted during teardown.
private let surfaceDestroy: @MainActor @convention(c) (OpaquePointer?, gpointer?) -> Void = { _, data in
    if let data { Unmanaged<GhosttySurface>.fromOpaque(data).release() }
}
private let surfaceRealize: @MainActor @convention(c) (OpaquePointer?, gpointer?) -> Void = { _, data in
    MainActor.assumeIsolated { wrap(data)?.realize() }
}
private let surfaceRender: @MainActor @convention(c) (OpaquePointer?, OpaquePointer?, gpointer?) -> gboolean = { _, _, data in
    MainActor.assumeIsolated { wrap(data)?.render() }
    return 1
}
private let surfaceResize: @MainActor @convention(c) (OpaquePointer?, Int32, Int32, gpointer?) -> Void = { _, w, h, data in
    MainActor.assumeIsolated { wrap(data)?.resize(width: w, height: h) }
}
private let surfaceKeyPressed: @MainActor @convention(c) (OpaquePointer?, UInt32, UInt32, UInt32, gpointer?) -> gboolean = { controller, keyval, keycode, state, data in
    MainActor.assumeIsolated {
        let event = controller.flatMap { gtk_event_controller_get_current_event($0) }
        return (wrap(data)?.keyPressed(
            keyval: keyval, keycode: keycode, state: state, event: event
        ) ?? false) ? 1 : 0
    }
}
/// Modifier-only releases reach libghostty (macOS `flagsChanged` parity) BEFORE the Ctrl-Tab commit: the
/// commit moves focus and rebuilds widgets, and this surface's own release must not queue behind it.
private let surfaceKeyReleased: @MainActor @convention(c) (OpaquePointer?, UInt32, UInt32, UInt32, gpointer?) -> Void = { _, keyval, keycode, state, data in
    let bit = ModifierKeyMods.modifierBit(forKeyval: keyval)
    if bit != nil {
        MainActor.assumeIsolated { wrap(data)?.modifierKeyReleased(keyval: keyval, keycode: keycode, state: state) }
    }
    if bit == ModifierKeyMods.controlBit {
        MainActor.assumeIsolated {
            wrap(data)?.controller?.scheduleSessionSwitchCommit(releasing: keycode)
        }
    }
}
private let surfaceFocusEnter: @MainActor @convention(c) (OpaquePointer?, gpointer?) -> Void = { _, data in
    MainActor.assumeIsolated {
        guard let surface = wrap(data) else { return }
        surface.setFocus(true)
        surface.imFocus(true)
        // Tell the controller which pane took focus so a split session's displayName/title/cwd track it.
        let livePane = surface.controller?.store.session(withID: surface.sessionID)?.paneOverlayRole(of: surface)
        surface.controller?.surfaceDidFocus(
            surface.sessionID, isSplit: livePane == .right || surface.isSplitPane)
    }
}
private let surfaceFocusLeave: @MainActor @convention(c) (OpaquePointer?, gpointer?) -> Void = { _, data in
    MainActor.assumeIsolated {
        wrap(data)?.setFocus(false)
        wrap(data)?.imFocus(false)
        wrap(data)?.controller?.resetLeader()
        wrap(data)?.controller?.cancelSessionSwitch()
    }
}
/// The IM context committed composed text (dead-key / compose / CJK result).
private let surfaceIMCommit: @MainActor @convention(c) (OpaquePointer?, UnsafePointer<CChar>?, gpointer?) -> Void = { _, text, data in
    guard let text else { return }
    let s = String(cString: text)
    MainActor.assumeIsolated { wrap(data)?.imCommit(s) }
}
private let surfacePreeditChanged: @MainActor @convention(c) (OpaquePointer?, gpointer?) -> Void = { _, data in
    MainActor.assumeIsolated { wrap(data)?.imPreeditChanged() }
}
private let surfaceClicked: @MainActor @convention(c) (OpaquePointer?, Int32, Double, Double, gpointer?) -> Void = { gesture, _, x, y, data in
    MainActor.assumeIsolated {
        wrap(data)?.grabFocus(supersedingPopoverCapture: true)
        wrap(data)?.mouseButton(gesture, pressed: true, x: x, y: y)
    }
}
private let surfaceReleased: @MainActor @convention(c) (OpaquePointer?, Int32, Double, Double, gpointer?) -> Void = { gesture, _, x, y, data in
    MainActor.assumeIsolated { wrap(data)?.mouseButton(gesture, pressed: false, x: x, y: y) }
}
private let surfaceMotion: @MainActor @convention(c) (OpaquePointer?, Double, Double, gpointer?) -> Void = { ctl, x, y, data in
    MainActor.assumeIsolated { wrap(data)?.mouseMoved(ctl, x: x, y: y) }
}
private let surfaceLeave: @MainActor @convention(c) (OpaquePointer?, gpointer?) -> Void = { _, data in
    MainActor.assumeIsolated { wrap(data)?.mouseLeft() }
}
private let surfaceScroll: @MainActor @convention(c) (OpaquePointer?, Double, Double, gpointer?) -> gboolean = { ctl, dx, dy, data in
    MainActor.assumeIsolated { wrap(data)?.scroll(controller: ctl, dx: dx, dy: dy) }
    return 1
}
private let surfaceDropString: @MainActor @convention(c) (OpaquePointer?, UnsafePointer<GValue>?, Double, Double, gpointer?) -> gboolean = { _, value, _, _, data in
    MainActor.assumeIsolated {
        guard let value, let cstr = g_value_get_string(value), let surface = wrap(data) else { return 0 }
        let payload = String(cString: cstr)
        // Defensive guard for in-app sidebar drags if a compositor offers COPY anyway.
        if UUID(uuidString: payload) != nil { return 0 }
        if payload.hasPrefix("w:"), UUID(uuidString: String(payload.dropFirst(2))) != nil { return 0 }
        guard let text = ShellEscape.dropPayload(payload) else { return 0 }
        surface.grabFocus(supersedingPopoverCapture: true)
        surface.inject(text: text)
        return 1
    }
}
private let surfaceDropFiles: @MainActor @convention(c) (OpaquePointer?, UnsafePointer<GValue>?, Double, Double, gpointer?) -> gboolean = { _, value, _, _, data in
    MainActor.assumeIsolated {
        guard let value, let boxed = g_value_get_boxed(value), let surface = wrap(data) else { return 0 }
        let fileList = OpaquePointer(boxed)
        guard let files = gdk_file_list_get_files(fileList) else { return 0 }
        defer { g_slist_free(files) }

        var parts: [String] = []
        var node: UnsafeMutablePointer<GSList>? = files
        while let current = node {
            if let rawFile = current.pointee.data {
                let file = OpaquePointer(rawFile)
                if let cpath = g_file_get_path(file) {
                    let path = String(cString: cpath)
                    g_free(cpath)
                    parts.append(ShellEscape.path(path))
                } else if let curi = g_file_get_uri(file) {
                    let uri = String(cString: curi)
                    g_free(curi)
                    parts.append(ShellEscape.path(uri))
                }
            }
            node = current.pointee.next
        }

        let text = parts.filter { !$0.isEmpty }.joined(separator: " ")
        guard !text.isEmpty else { return 0 }
        surface.grabFocus(supersedingPopoverCapture: true)
        surface.inject(text: text)
        return 1
    }
}
