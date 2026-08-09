// Drives the GTK UI from agtermCore's AppStore: an AdwNavigationSplitView with a
// workspace/session sidebar and a stable GtkOverlay deck reconciled from the shared model.
// The Swift importer maps GObject types inconsistently. Typed GTK pointers use the W/WIN/GLBR/cast
// helpers; opaque GTK objects take the stored OpaquePointer directly.
import CGtk
import LinuxIntegrations
import agtermCore
import Foundation
/// Frontmost-controller resolver for deliberately app-global actions only: unaddressed control commands,
/// fallback clipboard prompts, and the status-sound error-bell fallback.
/// Per-window callbacks use ControllerWidgetContext or a source-owned weak context.
@MainActor var gController: AppController?

@MainActor
final class AppController {
    let store: AppStore             // this window's tree (owned by the shared WindowLibrary)
    let autoFollowCoordinator: LinuxAutoFollowCoordinator
    let windowID: UUID
    let library: WindowLibrary
    let customCommandOrigin: LinuxCustomCommandOrigin
    let window: OpaquePointer        // AdwApplicationWindow
    let deck: OpaquePointer          // GtkOverlay (one stable overlay child per session)
    var contentBox: OpaquePointer?   // vertical box [search + deck-overlay]
    var deckOverlay: OpaquePointer?  // GtkOverlay over the deck, hosts the floating quick panel
    var switcherBox: OpaquePointer?  // the Ctrl-Tab MRU overlay (a centered overlay child while cycling)
    var toastOverlay: OpaquePointer? // AdwToastOverlay wrapping the content, for transient banners
    var bottomBar: OpaquePointer?    // the sidebar footer toolbar (compact/tall padding setting)
    var sidebarHeader: OpaquePointer? // sidebar AdwHeaderBar (hidden-toolbar mode)
    var contentHeader: OpaquePointer? // content AdwHeaderBar (hidden-toolbar mode)
    var glErrorLabel: OpaquePointer? // the persistent "no GL context" overlay (added once)
    var quickSurface: GhosttySurface?  // the window-level quick terminal (floating panel)
    var quickFrame: OpaquePointer?   // the card frame holding the quick surface
    var quickVisible = false
    /// Pending compositor state, used to serialize rapid GTK fullscreen toggles.
    var fullscreenDesired: Bool?
    var fullscreenTransitionInFlight = false
    var fullscreenTransitionTimeout: UInt32 = 0
    let terminalZoom = TerminalZoomController(); let dashboard = DashboardController(); let dashboardRuntime = DashboardRuntime(); var zoomHost: OpaquePointer?
    var zoomHeader: OpaquePointer?; var zoomTitleLabel: OpaquePointer?
    var splitToggleBtn: OpaquePointer?    // title-bar split toggle (swaps to .fill when active)
    var scratchToggleBtn: OpaquePointer?  // title-bar scratch toggle (swaps to .fill when active)
    var recentSessionsButton: OpaquePointer? // title-bar MRU session picker
    var attentionButton: OpaquePointer?   // optional title-bar attention indicator button
    var dashboardButton: OpaquePointer?   // title-bar MRU dashboard toggle
    var quickToggleBtn: OpaquePointer?; var sidebarToggleBtn: OpaquePointer?; var titleWidget: OpaquePointer?; var titlebarDividerAfterA: OpaquePointer?; var titlebarDividerAfterB: OpaquePointer?
    var interfaceWidgets: [InterfaceElement: OpaquePointer] = [:]
    var footerNewWorkspaceButton: OpaquePointer?; var footerNewSessionButton: OpaquePointer?
    var footerFocusFilterButton: OpaquePointer?; var footerFlaggedButton: OpaquePointer?
    var sessionPickerPopover: OpaquePointer?; var sessionPickerContexts: [SessionPickerRowContext] = []
    var sessionPickerSuppressesAutoFollow = false
    var sessionPickerShowsAttention = false
    let sidebarBox: OpaquePointer    // GtkBox holding per-workspace sections
    var splitView: OpaquePointer!    // root GtkPaned (collapsible, resizable sidebar)

    // Command palette (Ctrl+Shift+P)
    var paletteWindow: OpaquePointer?
    var paletteList: OpaquePointer?
    var paletteAll = LinuxPaletteList()
    var paletteItems: [LinuxPaletteItem] = []

    // Native control picker (`agtermctl pick`), one pending request per window.
    let pickController = PickController()
    var controlPickWindow: OpaquePointer?
    var controlPickList: OpaquePointer?
    var controlPickEntry: OpaquePointer?
    var controlPickRows: [LinuxControlPickRow] = []
    var controlPickSuppressesAutoFollow = false

    // In-terminal search bar (Ctrl+Shift+F)
    var searchBar: OpaquePointer?
    var searchEntry: OpaquePointer?
    var searchSuppressesAutoFollow = false
    var searchMatchLabel: OpaquePointer?
    var searchSessionID: UUID?
    var searchSurface: GhosttySurface?
    var searchTotal: Int?
    var searchSelected: Int?

    // Theme picker (live preview). The unpersisted preview override itself — `themePreviewSettings` and its
    // `previewTheme`/`applyTheme` setters — lives in `GhosttyConfigTheme.swift`, next to the resolvers that
    // read it.
    var themeWindow: OpaquePointer?
    var themeList: OpaquePointer?
    var themeItems: [String] = []
    var themeCommitted: String?
    /// Coalesces rapid theme-picker arrow/typing previews so a burst collapses to one config rebuild
    /// (mirrors the macOS SettingsModel preview debounce). Commit/cancel/close cancel it and act now.
    let themePreviewDebouncer = Debouncer()
    static let themePreviewDebounceInterval: TimeInterval = 0.07
    // Independent debouncers coalesce layout saves and terminal-metadata sidebar refreshes.
    let layoutSaveDebouncer = Debouncer()
    let sidebarMetadataDebouncer = Debouncer()
    /// Owner-scoped, cancellable retries for persisted split divider restoration.
    let splitRatioRestore = SplitRatioRestoreCoordinator()
    /// The trailing deck reconcile a soft close arms: cancellable at window close and deferred while a
    /// sidebar interaction is live (see `SoftCloseReconcileCoordinator`).
    let softCloseReconcile = SoftCloseReconcileCoordinator(
        retryInterval: AppController.sidebarInteractionRetryInterval)
    var surfaces: [UUID: GhosttySurface] = [:]        // primary pane per session
    var splitSurfaces: [UUID: GhosttySurface] = [:]   // second pane (when split)
    var scratchSurfaces: [UUID: GhosttySurface] = [:] // full-overlay scratch shell
    var overlaySurfaces: [UUID: GhosttySurface] = [:]  // ephemeral overlay terminal (runs a command)
    var floatingOverlayFrames: [UUID: OpaquePointer] = [:]  // overlay rendered as a floating sized panel
    var sessionPanes: [UUID: OpaquePointer] = [:]     // GtkPaned (main content) per session
    var sessionStacks: [UUID: OpaquePointer] = [:]    // outer GtkStack (main <-> scratch), the deck page
    var rowSession: [OpaquePointer: UUID] = [:]
    var sidebarSelectionAnchor: UUID?
    var nameLabels: [OpaquePointer: (id: UUID, isWorkspace: Bool)] = [:]  // name label -> rename target (double-click)
    var workspaceDiscButtons: [OpaquePointer: UUID] = [:]  // disclosure button -> workspace (collapse toggle)
    // The session/workspace currently being inline-renamed (nil = none). One value instead of an
    // id + is-workspace pair, so the "is-workspace" flag can't drift from the id.
    enum RenameTarget {
        case session(UUID)
        case workspace(UUID)
        var id: UUID {
            switch self {
            case .session(let id), .workspace(let id): return id
            }
        }
        var isWorkspace: Bool { if case .workspace = self { return true }; return false }
    }
    var renaming: RenameTarget?
    var renameEntry: OpaquePointer?  // the live rename GtkEntry (focused after rebuild)
    var workspaceListBoxes: [OpaquePointer] = []
    var sidebarScroller: OpaquePointer?               // the sidebar's GtkScrolledWindow (scroll-to-selected)
    var contextMenuSession: UUID?                     // the session a row context menu targets
    var contextMoveTargets: [OpaquePointer: UUID] = [:]   // "Move to <ws>" button → target workspace
    var contextMenuWorkspace: UUID?                   // the workspace a header context menu targets
    var pendingDeleteWorkspace: UUID?                 // workspace awaiting the delete-confirm response
    var pendingCloseSession: UUID?                    // session awaiting the close-confirm response
    var pendingDeleteWindow: UUID?                    // window awaiting the delete-confirm response
    var pendingRenameWindow: UUID?                    // window awaiting the rename-dialog response
    var pendingRenameEntry: OpaquePointer?            // the rename dialog's GtkEntry
    var settingsDialog: OpaquePointer?
    // The Keyboard Shortcuts / About dialogs currently up. Each retains this controller through its
    // "closed" handler, so `windowWillClose` must force-close them alongside the other dialogs.
    var auxiliaryDialogs: [OpaquePointer] = []
    var settingsCustomDirectoryRow: OpaquePointer?
    var settingsConfigDirectoryRow: OpaquePointer?
    var settingsAutoFollowAwayRow: OpaquePointer?
    var settingsInterfaceRows: [OpaquePointer: InterfaceElement] = [:]
    var integrationRows: [IntegrationKind: OpaquePointer] = [:]
    var integrationKindButtons: [IntegrationKind: OpaquePointer] = [:]
    var integrationButtons: [OpaquePointer: IntegrationPlanKind] = [:]
    var integrationRefreshGeneration: UInt64 = 0
    var pendingIntegrationPlan: IntegrationPlan?
    var integrationOperationInFlight = false
    var pendingBackgroundOpacity: Double?
    var backgroundOpacityPending = false
    var backgroundSettingsSource: guint = 0
    var confirmedClose = false                       // set once the quit-confirm is accepted
    var badgeEnabled = linuxSettingsStore().load().notificationBadgeEnabled ?? true   // gates the unseen-count pill
    var sessionSwitcher = SessionSwitcherModel()                                  // Ctrl-Tab hold-to-cycle state
    var contextMenuPopover: OpaquePointer?            // the live row context-menu popover
    var pendingWorkspaceToggle: UUID?
    var pendingWorkspaceToggleSource: guint = 0
    var sessionProgress: [UUID: Int] = [:]            // per-session OSC 9;4 progress

    // Keymap dispatch state (see KeymapDispatch.swift): the parsed keymap.conf, the resolved built-in
    // chord -> action map (user override else Linux default), and the custom-command leader matcher.
    // Loaded at launch + rebuilt on reload. Internal (not private) so the KeymapDispatch extension reaches them.
    var keymap = Keymap(builtinOverrides: [:], commands: [])
    var keymapDiagnostics: [KeymapDiagnostic] = []
    var resolvedBuiltinChords: [Chord: BuiltinAction] = [:]
    var customCommandEngine = CustomCommandEngine(commands: [])   // matcher + id-lookup (shared, host-free)
    var leaderTimeout: guint = 0   // g_timeout source for the custom-command leader deadline (0 = none)

    static var homeCwd: String { ConfigPaths.defaultNewSessionCwd() }

    /// The main window, exposed to the palette extension (different file).
    var windowPointer: OpaquePointer { window }

    /// The primary surface for a session, exposed to the search extension (different file).
    func surface(for id: UUID?) -> GhosttySurface? { id.flatMap { surfaces[$0] } }
    init(app: OpaquePointer?, windowID: UUID, library: WindowLibrary,
         commandProcessLauncher: any LinuxProcessLaunching = FoundationLinuxProcessLauncher()) {
        // This window's tree comes from the shared WindowLibrary (which loaded/seeded/
        // migrated it from windows/<id>.json). AppStore.save() targets that per-window file.
        self.windowID = windowID
        self.library = library
        customCommandOrigin = LinuxCustomCommandOrigin(launcher: commandProcessLauncher)
        let store = library.store(for: windowID) ?? AppStore()
        self.store = store
        autoFollowCoordinator = LinuxAutoFollowCoordinator(store: store)
        window = OpaquePointer(adw_application_window_new(APPW(app)))
        attachControllerContext(to: window, windowID: windowID)
        installEmptyWindowKeyController(on: window)
        // restore the window's last on-screen size (Wayland: size only — the compositor owns position),
        // else the default. set BEFORE present so the window maps at the saved size.
        if let geo = library.geometry(forWindow: windowID), geo.width > 0, geo.height > 0 {
            gtk_window_set_default_size(WIN(window), Int32(geo.width), Int32(geo.height))
        } else {
            gtk_window_set_default_size(WIN(window), 1100, 700)
        }
        deck = makeTerminalDeck()
        gtk_widget_set_hexpand(W(deck), 1)
        gtk_widget_set_vexpand(W(deck), 1)
        sidebarBox = OpaquePointer(gtk_box_new(GTK_ORIENTATION_VERTICAL, 2))
        gtk_widget_set_vexpand(W(sidebarBox), 1); installSidebarDirectoryDropTarget()
        // Sidebar header: regular GTK desktops keep left-side controls; Hyprland owns window actions.
        let sidebarHeader = OpaquePointer(adw_header_bar_new())
        self.sidebarHeader = sidebarHeader
        let decorationLayout = LinuxDesktopEnvironment.hidesClientSideWindowButtons() ? ":" : "close,minimize,maximize:"
        decorationLayout.withCString { adw_header_bar_set_decoration_layout(sidebarHeader, $0) }
        let scroller = OpaquePointer(gtk_scrolled_window_new())
        sidebarScroller = scroller
        gtk_widget_add_css_class(W(scroller), "agterm-sidebar")   // theme-bg tint target
        gtk_scrolled_window_set_child(scroller, W(sidebarBox))
        gtk_widget_set_size_request(W(scroller), 240, -1)
        let sidebarToolbar = OpaquePointer(adw_toolbar_view_new())
        adw_toolbar_view_add_top_bar(sidebarToolbar, W(sidebarHeader))
        adw_toolbar_view_set_content(sidebarToolbar, W(scroller))
        // Bottom bar (mirrors the macOS sidebar footer): New Window on the left, Flagged-view toggle on
        // the right, flat buttons with a spacer between.
        let bottomBar = OpaquePointer(gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6))
        self.bottomBar = bottomBar
        for m in [gtk_widget_set_margin_start, gtk_widget_set_margin_end] { m(W(bottomBar), 6) }
        applyToolbarMode()
        func footerButton(_ icon: String, _ tip: String, _ cb: @escaping @convention(c) (OpaquePointer?, gpointer?) -> Void) -> OpaquePointer? {
            let b = OpaquePointer(gtk_button_new_from_icon_name(icon))
            gtk_widget_set_tooltip_text(W(b), tip)
            gtk_button_set_has_frame(BUTTON(b), 0)
            connect(b, "clicked", unsafeBitCast(cb, to: GCallback.self))
            return b
        }
        footerNewWorkspaceButton = footerButton("agterm-new-workspace-symbolic", "New Workspace", onNewWorkspace)
        footerNewSessionButton = footerButton("agterm-new-session-symbolic", "New Session", onNewSession)
        gtk_box_append(cast(bottomBar), W(footerNewWorkspaceButton)); gtk_box_append(cast(bottomBar), W(footerNewSessionButton))
        let spacer = OpaquePointer(gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0))
        gtk_widget_set_hexpand(W(spacer), 1)
        gtk_box_append(cast(bottomBar), W(spacer))
        footerFocusFilterButton = footerButton(
            "agterm-grid-symbolic", "Show Only Focused Workspaces", onWorkspaceFilterToggle)
        gtk_box_append(cast(bottomBar), W(footerFocusFilterButton))
        footerFlaggedButton = footerButton("agterm-flag-symbolic", "Show Flagged Only", onFlaggedToggle)
        gtk_box_append(cast(bottomBar), W(footerFlaggedButton))
        adw_toolbar_view_add_bottom_bar(sidebarToolbar, W(bottomBar))

        // Content side: header over [search bar (hidden) + deck]. No menu button and no window controls
        // on the right (matching macOS — the window controls live on the left, on the sidebar header);
        // the right side carries only the terminal toggles. The palette is still on Ctrl+Shift+P.
        let contentHeader = OpaquePointer(adw_header_bar_new())
        self.contentHeader = contentHeader
        adw_header_bar_set_show_start_title_buttons(contentHeader, 0)
        adw_header_bar_set_show_end_title_buttons(contentHeader, 0)
        installInterfaceTitle(in: contentHeader)
        // Title-bar session pickers and terminal toggles mirror the macOS top-right action cluster.
        // `pack_end` stacks leftward, so construction proceeds from the visual right edge.
        // Sidebar toggle on the LEFT (macOS sidebar.left), always visible so a hidden sidebar can return.
        let sidebarBtn = OpaquePointer(gtk_button_new_from_icon_name("agterm-sidebar-symbolic"))
        sidebarToggleBtn = sidebarBtn
        gtk_widget_set_tooltip_text(W(sidebarBtn), "Toggle Sidebar (Ctrl+Shift+B)")
        connect(sidebarBtn, "clicked", unsafeBitCast(onSidebarToggle as @convention(c) (OpaquePointer?, gpointer?) -> Void, to: GCallback.self))
        adw_header_bar_pack_start(contentHeader, W(sidebarBtn))
        installPreferencesShortcut()
        // Left-to-right: Recent, Attention | Scratch, Split | Dashboard, Quick; split/scratch gain fill when active.
        quickToggleBtn = linuxHeaderToggle(contentHeader, "agterm-quick-symbolic", "Quick Terminal (Ctrl+`)", onQuickToggle)
        dashboardButton = linuxHeaderToggle(contentHeader, "agterm-grid-symbolic", "Dashboard (Ctrl+Shift+M)", onDashboardToggle)
        titlebarDividerAfterB = linuxHeaderSeparator(contentHeader)
        splitToggleBtn = linuxHeaderToggle(contentHeader, "agterm-split-symbolic", "Toggle Split (Ctrl+Shift+D)", onSplitToggle)
        scratchToggleBtn = linuxHeaderToggle(contentHeader, "agterm-scratch-symbolic", "Scratch Terminal (Ctrl+Shift+J)", onScratchToggle)
        titlebarDividerAfterA = linuxHeaderSeparator(contentHeader)
        attentionButton = linuxHeaderToggle(contentHeader, "emblem-important-symbolic", "Show sessions that need attention (Ctrl+Shift+I)", onAttentionButton)
        recentSessionsButton = linuxHeaderToggle(contentHeader, "document-open-recent-symbolic", "Recent Sessions (Ctrl+Tab)", onRecentSessionsButton)
        registerInterfaceWidgets(sidebarToggle: sidebarBtn)
        updateAttentionButton()
        updateDashboardButton()
        applyInterfaceElements()
        let contentToolbar = OpaquePointer(adw_toolbar_view_new())
        adw_toolbar_view_add_top_bar(contentToolbar, W(contentHeader))
        let contentBox = OpaquePointer(gtk_box_new(GTK_ORIENTATION_VERTICAL, 0))
        self.contentBox = contentBox
        buildSearchBar()
        gtk_box_append(cast(contentBox), W(searchBar))
        gtk_box_append(cast(contentBox), W(deck))
        adw_toolbar_view_set_content(contentToolbar, W(contentBox))
        let split = buildSidebarSplit(sidebar: sidebarToolbar, content: contentToolbar)
        applyToolbarMode()
        applySidebarFontSize()
        // The whole split (sidebar + deck) sits under a GtkOverlay so the quick terminal can float over
        // the FULL window content (matching macOS), not just the deck.
        let windowOverlay = OpaquePointer(gtk_overlay_new())
        self.deckOverlay = windowOverlay
        gtk_overlay_set_child(windowOverlay, W(split))
        installQuickCardPlacement(on: windowOverlay)   // percent-sized quick card; see AppControllerCallbacks
        // An AdwToastOverlay wraps the content so the app can surface transient banners (keymap/config
        // parse diagnostics, command failures) without a modal — the GTK analogue of the macOS banner.
        let toast = OpaquePointer(adw_toast_overlay_new())
        self.toastOverlay = toast
        adw_toast_overlay_set_child(toast, W(windowOverlay))
        adw_application_window_set_content(cast(window), W(toast))
        terminalZoom.targetResolver = { [weak self] in
            guard let self else { return nil }
            return TerminalZoomController.resolveTarget(store: self.store, quickTerminalVisible: self.quickVisible)
        }
        TerminalZoomRegistry.shared.register(windowID, controller: terminalZoom)
        DashboardControllerRegistry.shared.register(windowID, controller: dashboard)
        PickRegistry.shared.register(windowID, controller: pickController)

        // Become frontmost on activation (routes global shortcuts + control to this window);
        // tear down + deregister when the window closes.
        let me = Unmanaged.passUnretained(self).toOpaque()
        connect(window, "notify::is-active", unsafeBitCast(onWindowActive as @convention(c) (OpaquePointer?, OpaquePointer?, gpointer?) -> Void, to: GCallback.self))
        connect(window, "notify::fullscreened", unsafeBitCast(onWindowFullscreened as @convention(c) (OpaquePointer?, OpaquePointer?, gpointer?) -> Void, to: GCallback.self))
        connect(window, "close-request", unsafeBitCast(onWindowCloseRequest as @convention(c) (OpaquePointer?, gpointer?) -> gboolean, to: GCallback.self), me)

        applyWindowTranslucency()
        applyAutoFollowSettings()
        gtk_window_present(WIN(window))
        applySidebarThemeColor()   // tint the sidebar to the terminal theme background
        loadKeymapAtStartup()   // this window's own keymap.conf caches; NOT an app-wide reload
        reconcile()
        becameFrontmost()
    }
    // MARK: - Actions
    func newSession() {
        guard let wsID = store.currentWorkspaceID else { return }
        noteUserActivity()
        _ = store.addSession(toWorkspace: wsID, cwd: newSessionCwd())
        reconcile()
    }
    func newSessionCwd() -> String {
        linuxSettingsStore().load().resolveNewSessionCwd(currentSessionCwd: store.activeSession?.focusedCwd,
                                                    home: Self.homeCwd)
    }
    func newWorkspace() {
        noteUserActivity()
        _ = store.addSession(toWorkspace: store.addWorkspace(name: store.defaultWorkspaceName).id, cwd: Self.homeCwd)
        reconcile()
    }
    func selectSession(_ id: UUID, userInitiated: Bool = true) {
        // selectSession clears the unseen badge + an auto-reset (e.g. `completed`) glyph on BOTH the
        // visited and the previously-selected session; rebuild the sidebar when either row changes.
        let prev = store.selectedSessionID
        let focusWasEnabled = store.focusEnabled
        let needsRefresh = clearedRowChanges(id) || (prev.map(clearedRowChanges) ?? false)
        if prev != id, let owner = searchSurface {
            owner.endSearch()
            endSearchAutoFollowSuppression()
            searchSessionID = nil
            searchSurface = nil
            gtk_widget_set_visible(W(searchBar), 0)
        }
        if userInitiated { noteUserActivity() }
        store.selectSession(id)
        let focusFilterChanged = focusWasEnabled != store.focusEnabled
        NotificationManager.withdraw(windowID: windowID, sessionID: id)
        showActive()
        syncSidebarSelection()
        updateTitle()
        updateRecentSessionsButton()
        if needsRefresh || focusFilterChanged { rebuildSidebar() }
    }
    /// Whether selecting `id` would change its sidebar row (an unseen badge or an auto-reset glyph clears).
    private func clearedRowChanges(_ id: UUID) -> Bool {
        guard let s = store.session(withID: id) else { return false }
        return s.unseenCount > 0 || (s.agentIndicator.autoReset && s.agentIndicator.status != .idle)
    }

    /// Re-render the sidebar (public entry so cross-window notification routing can refresh a
    /// background window's unseen badges after a bump).
    func refreshSidebar() { rebuildSidebar() }

    func navigate(_ dir: SessionNavigation, userInitiated: Bool = true) {
        let attentionBefore = Set(store.attentionSessions.map(\.id))
        if userInitiated { noteUserActivity() }
        store.navigateSession(dir)
        let attentionChanged = attentionBefore != Set(store.attentionSessions.map(\.id))
        showActive()
        syncSidebarSelection()
        updateTitle()
        if attentionChanged {
            rebuildSidebar()
        } else {
            updateAttentionButton()
        }
    }
    /// Defer scrolling until the selected sidebar row is allocated.
    func scrollRowIntoView(_ row: OpaquePointer) {
        guard let scroller = sidebarScroller else { return }
        _ = g_object_ref(RAW(scroller)); _ = g_object_ref(RAW(row))
        let scrollerAddress = Int(bitPattern: scroller), rowAddress = Int(bitPattern: row)
        runOnMain { MainActor.assumeIsolated {
            guard let scroller = OpaquePointer(bitPattern: scrollerAddress),
                  let row = OpaquePointer(bitPattern: rowAddress) else { return }
            defer { g_object_unref(RAW(scroller)); g_object_unref(RAW(row)) }
            guard gtk_widget_is_ancestor(W(row), W(self.sidebarBox)) != 0,
                  let adj = gtk_scrolled_window_get_vadjustment(scroller) else { return }
            var origin = graphene_point_t()
            var translated = graphene_point_t()
            guard gtk_widget_compute_point(W(row), W(self.sidebarBox), &origin, &translated) != 0 else { return }
            let ry = Double(translated.y)
            let rowH = Double(gtk_widget_get_height(W(row)))
            let value = gtk_adjustment_get_value(adj), page = gtk_adjustment_get_page_size(adj)
            if ry < value {
                gtk_adjustment_set_value(adj, ry)
            } else if ry + rowH > value + page {
                gtk_adjustment_set_value(adj, ry + rowH - page)
            }
        } }
    }

    func closeSession(_ id: UUID) {
        store.closeSession(id)
        reconcile()
    }

    func requestCloseSession(_ id: UUID, closingCoversFirst: Bool = true) {
        if closingCoversFirst, id == store.selectedSessionID {
            if quickVisible {
                setQuick(false)
                return
            }
            if store.session(withID: id)?.overlayActive == true {
                closeOverlay(id)
                return
            }
            if store.session(withID: id)?.scratchActive == true {
                store.toggleScratch(id)
                reconcile()
                updateToggleIcons()
                return
            }
        }
        guard linuxSettingsStore().load().confirmCloseSession ?? false else {
            closeSessionFromGUI(id)
            return
        }
        pendingCloseSession = id
        let name = store.session(withID: id)?.displayName ?? "this session"
        let dialog = OpaquePointer("Close Session?".withCString { h in
            "This closes \(name), ending its running shell.".withCString { b in adw_alert_dialog_new(h, b) }
        })
        attachControllerContext(to: dialog, windowID: windowID)
        "cancel".withCString { i in "Cancel".withCString { l in adw_alert_dialog_add_response(cast(dialog), i, l) } }
        "close".withCString { i in "Close".withCString { l in adw_alert_dialog_add_response(cast(dialog), i, l) } }
        "close".withCString { adw_alert_dialog_set_response_appearance(cast(dialog), $0, ADW_RESPONSE_DESTRUCTIVE) }
        "cancel".withCString { adw_alert_dialog_set_close_response(cast(dialog), $0) }
        connect(dialog, "response", unsafeBitCast(onCloseSessionResponse as @convention(c) (
            OpaquePointer?, UnsafePointer<CChar>?, gpointer?) -> Void, to: GCallback.self))
        adw_dialog_present(cast(dialog), W(window))
    }

    func confirmSessionClose(_ response: String) {
        defer { pendingCloseSession = nil }
        guard response == "close", let id = pendingCloseSession else { return }
        closeSessionFromGUI(id)
    }

    /// The primary pane's shell exited. Mirrors macOS: if a split pane is alive the session SURVIVES,
    /// promoted to that single pane (a primary exit must never destroy the live split shell); with no
    /// split the session closes. `AppStore.closePrimaryPane` decides promote-vs-close.
    func closePrimaryPane(_ id: UUID) {
        // Capture the survivor (the split pane) before the store clears the session's split flags.
        if dashboard.isOpen { closeDashboard(refocus: false) }; let survivor = splitSurfaces[id]
        store.closePrimaryPane(id)
        guard store.session(withID: id) != nil, let survivor, let paned = sessionPanes[id] else {
            reconcile()   // no split → the store closed the session; reconcile drops its widgets
            return
        }
        // Promote the survivor to the single pane: detach the dead primary (the store already freed its
        // ghostty surface; teardown never touches the glArea) and reparent the survivor from the end
        // slot to the start slot, so it fills the page and a future re-split has a free end slot.
        // Removing a child from a GtkPaned does NOT free the survivor's glArea, so its shell lives on.
        gtk_paned_set_start_child(paned, nil)
        gtk_paned_set_end_child(paned, nil)
        gtk_paned_set_start_child(paned, W(survivor.glArea))
        surfaces[id] = survivor
        splitSurfaces[id] = nil
        let sid = id
        survivor.promoteToPrimary(onExit: { [weak self] in self?.closePrimaryPane(sid) })
        survivor.queueRender()
        survivor.grabFocus()
        reconcile()
    }

    func toggleSidebar() {
        store.toggleSidebarVisible()   // saving mutator, so the visibility survives relaunch
        applySidebarVisibility()
    }

    /// Swap the split/scratch title-bar toggles to their `.fill` variant when the active session has that
    /// mode on (mirrors the macOS active-state icons). Called whenever the active session or its state
    /// changes.
    func updateToggleIcons() {
        let s = store.activeSession
        let splitOn = s?.hasSplit == true
        let scratchOn = s?.scratchActive == true
        if let b = splitToggleBtn { gtk_button_set_icon_name(cast(b), splitOn ? "agterm-split-fill-symbolic" : "agterm-split-symbolic") }
        if let b = scratchToggleBtn { gtk_button_set_icon_name(cast(b), scratchOn ? "agterm-scratch-fill-symbolic" : "agterm-scratch-symbolic") }
    }

    /// Show/hide the window-level quick terminal — a percent-sized card centered over the window content
    /// below the header, running a login shell, kept alive when hidden, recreated after its shell exits.
    /// The control `quick` arm and Ctrl+` both drive it.
    func setQuick(_ visible: Bool) {
        if !visible, terminalZoom.target == .quick { setTerminalZoom(.off, target: .quick) }
        if quickFrame == nil, visible, let overlay = deckOverlay {
            let q = GhosttySurface(sessionID: UUID(), cwd: Self.homeCwd,
                                   env: SurfaceEnvironment.quickTerminal(windowID: windowID,
                                                                         socketPath: gControlServer.boundSocketPath ?? ControlServer.defaultSocketPath(),
                                                                         programVersion: LinuxAppMetadata.version),
                                   controller: self, role: .quick, reportsPaneState: false)
            q.onExit = { [weak self] in self?.closeQuick() }
            // A floating card panel over the FULL window content: rounded + shadowed by .agterm-quick
            // (app priority, overriding Adwaita "card"), sized as a PERCENTAGE of the window content below
            // the header (sidebar + deck visible around it) by the deck overlay's get-child-position
            // handler, which re-measures on every layout pass so the card tracks a live window resize and
            // hidden-toolbar mode. FILL + no margins is load-bearing there: gtk_widget_size_allocate
            // re-applies align and margins INSIDE the rectangle that handler returns.
            let frame = OpaquePointer(gtk_frame_new(nil))
            gtk_widget_add_css_class(W(frame), "card")
            gtk_widget_add_css_class(W(frame), "agterm-quick")   // opaque backing + border, radius, shadow
            gtk_widget_set_overflow(W(frame), GTK_OVERFLOW_HIDDEN)   // clip GL child to the rounded card; see LinuxQuickCardPolicy
            gtk_widget_set_halign(W(frame), GTK_ALIGN_FILL)
            gtk_widget_set_valign(W(frame), GTK_ALIGN_FILL)
            gtk_frame_set_child(cast(frame), W(q.glArea))
            quickFrame = frame
            quickSurface = q
            gtk_overlay_add_overlay(overlay, W(frame))
        }
        guard let frame = quickFrame else { return }
        quickVisible = visible
        gtk_widget_set_visible(W(frame), visible ? 1 : 0)
        if visible { quickSurface?.grabFocus() }
    }

    func toggleQuick() { setQuick(!quickVisible) }

    /// The quick shell exited: tear it down (a fresh one spawns on next show).
    func closeQuick() {
        if let frame = quickFrame, let overlay = deckOverlay { gtk_overlay_remove_overlay(overlay, W(frame)) }
        quickSurface?.teardown()
        quickFrame = nil
        quickSurface = nil
        quickVisible = false
    }

    func toggleFlagActive() {
        guard let id = store.selectedSessionID, let session = store.session(withID: id) else { return }
        store.setFlag(!session.flagged, forSession: id)
        rebuildSidebar()
        syncSidebarSelection()
    }

    func toggleFlaggedView() {
        store.setSidebarMode(store.sidebarMode == .tree ? .flagged : .tree)
        rebuildSidebar()
        syncSidebarSelection()
    }

    /// Unflag every session (the palette "Clear Flagged" + the `session.flag clear` control mode).
    func clearFlagged() {
        store.clearFlags()
        rebuildSidebar()
    }

    /// Expand every workspace (show all sessions) — the palette + `sidebar.expand` control arm.
    func expandWorkspaces() {
        store.setWorkspacesExpanded(Set(store.workspaces.map(\.id)))
        rebuildSidebar()
    }

    /// Toggle one workspace's collapsed state — the sidebar header disclosure triangle.
    func toggleWorkspaceCollapse(_ data: gpointer?) {
        guard let data, let wsID = workspaceDiscButtons[OpaquePointer(data)] else { return }
        cancelPendingWorkspaceToggle()
        let isExpanded = store.workspaces.first(where: { $0.id == wsID })?.isExpanded ?? true
        store.setWorkspaceExpanded(wsID, expanded: !isExpanded)
        rebuildSidebar()
    }

    func scheduleWorkspaceToggle(_ data: gpointer?) {
        guard let data, let wsID = workspaceDiscButtons[OpaquePointer(data)] else { return }
        cancelPendingWorkspaceToggle()
        pendingWorkspaceToggle = wsID
        pendingWorkspaceToggleSource = g_timeout_add(300, onWorkspaceToggleTimeout, Unmanaged.passUnretained(self).toOpaque())
    }

    func cancelPendingWorkspaceToggle() {
        if pendingWorkspaceToggleSource != 0 {
            g_source_remove(pendingWorkspaceToggleSource)
            pendingWorkspaceToggleSource = 0
        }
        pendingWorkspaceToggle = nil
    }

    func firePendingWorkspaceToggle() -> gboolean {
        pendingWorkspaceToggleSource = 0
        guard let wsID = pendingWorkspaceToggle else { return 0 }
        pendingWorkspaceToggle = nil
        let isExpanded = store.workspaces.first(where: { $0.id == wsID })?.isExpanded ?? true
        store.setWorkspaceExpanded(wsID, expanded: !isExpanded)
        rebuildSidebar()
        return 0
    }

    /// Collapse every workspace except the active one to a header — the palette + `sidebar.collapse` arm.
    func collapseOtherWorkspaces() {
        let expanded = store.currentWorkspaceID.map { Set([$0]) } ?? []
        store.setWorkspacesExpanded(expanded)
        rebuildSidebar()
        syncSidebarSelection()
    }

    /// Typing clears blocked/completed status; Escape or bare Ctrl-C also clears active status.
    func clearAttentionStatus(_ id: UUID, pane: StatusPane, isInterrupt: Bool) {
        guard let session = store.session(withID: id),
              session.agentIndicator.clearedBy(pane: pane, isInterrupt: isInterrupt) else { return }
        store.setAgentIndicator(AgentIndicator(), forSession: id)
        rebuildSidebar()
    }
    /// Reset the active session's agent status to idle (the palette "Clear Status", GUI half of
    /// `session.status idle`).
    func clearActiveStatus() {
        guard let id = store.selectedSessionID else { return }
        store.setAgentIndicator(AgentIndicator(), forSession: id)
        rebuildSidebar()
    }

    /// Move the active session to another workspace (the palette "Move Session to <ws>").
    func moveActiveSession(to workspaceID: UUID) {
        guard let id = store.selectedSessionID else { return }
        store.moveSession(id, toWorkspace: workspaceID)
        reconcile()
    }

    /// Rename the selected session (Ctrl+Shift+R / palette) — same inline path as a double-click.
    func startRenameActive() {
        if let id = store.selectedSessionID { beginRename(id: id, isWorkspace: false) }
    }

    /// Enter inline-rename for a session/workspace: render its name as a GtkEntry (rebuildSidebar swaps
    /// the label for an entry when the id matches `renaming`), then focus + select-all the entry.
    func beginRename(id: UUID, isWorkspace: Bool) {
        if isWorkspace { cancelPendingWorkspaceToggle() }
        if renaming == nil { suppressAutoFollow() }
        renaming = isWorkspace ? .workspace(id) : .session(id)
        rebuildSidebar()
        guard let e = renameEntry else {
            renaming = nil
            resumeAutoFollow()
            return
        }
        let entryAddress = Int(bitPattern: e)
        runOnMain { MainActor.assumeIsolated {
            guard let entry = OpaquePointer(bitPattern: entryAddress) else { return }
            _ = gtk_widget_grab_focus(W(entry))
            gtk_editable_select_region(entry, 0, -1)
        } }
    }

    /// Double-click on a name label → begin its inline rename.
    func beginRenameFromLabel(_ data: gpointer?) {
        guard let data, let target = nameLabels[OpaquePointer(data)] else { return }
        beginRename(id: target.id, isWorkspace: target.isWorkspace)
    }

    /// Commit the inline rename (Enter or focus-out). `renaming` is cleared first so the focus-out that
    /// rebuildSidebar triggers can't double-commit.
    func commitInlineRename(_ entryRaw: UnsafeMutableRawPointer?) {
        guard let entryRaw, let target = renaming else { return }   // already committed → no-op
        let entry = OpaquePointer(entryRaw)
        let text = gtk_editable_get_text(entry).map { String(cString: $0) } ?? ""
        renaming = nil
        renameEntry = nil
        resumeAutoFollow()
        if !text.isEmpty {
            if target.isWorkspace { store.renameWorkspace(target.id, to: text) } else { store.renameSession(target.id, to: text) }
        }
        runOnMain { [weak self] in MainActor.assumeIsolated { self?.rebuildAfterRename() } }
    }
    func rebuildAfterRename() { rebuildSidebar(); syncSidebarSelection(); updateTitle() }

    func cancelInlineRename() {
        guard renaming != nil else { return }
        renaming = nil
        renameEntry = nil
        resumeAutoFollow()
        rebuildAfterRename()
        focusedSurface()?.grabFocus()
    }

    /// A name label (session or workspace) when not renaming: a plain GtkLabel that selects on single
    /// click (the row/header handles that) and enters rename on DOUBLE click — or a focused GtkEntry when
    /// this id is being renamed.
    func makeNameWidget(id: UUID, text: String, isWorkspace: Bool) -> OpaquePointer? {
        if renaming?.id == id {
            guard let entry = op(gtk_entry_new()) else { return nil }
            text.withCString { gtk_editable_set_text(entry, $0) }
            gtk_widget_set_hexpand(W(entry), 1)
            renameEntry = entry
            connect(entry, "activate", unsafeBitCast(onRenameCommit as @convention(c) (OpaquePointer?, gpointer?) -> Void, to: GCallback.self), RAW(entry))
            let kc = gtk_event_controller_key_new()
            connect(kc, "key-pressed", unsafeBitCast(onRenameKey as @convention(c) (OpaquePointer?, UInt32, UInt32, UInt32, gpointer?) -> gboolean, to: GCallback.self))
            gtk_widget_add_controller(W(entry), kc)
            let fc = gtk_event_controller_focus_new()
            connect(fc, "leave", unsafeBitCast(onRenameCommit as @convention(c) (OpaquePointer?, gpointer?) -> Void, to: GCallback.self), RAW(entry))
            gtk_widget_add_controller(W(entry), fc)
            return entry
        }
        guard let label = op(gtk_label_new(text)) else { return nil }
        gtk_label_set_xalign(label, 0)
        gtk_widget_set_hexpand(W(label), 1)
        nameLabels[label] = (id, isWorkspace)
        let dbl = gtk_gesture_click_new()
        gtk_gesture_single_set_button(dbl, 1)   // left double-click only; right-click goes to the context menu
        connect(dbl, "pressed", unsafeBitCast(onNameDoubleClick as @convention(c) (OpaquePointer?, Int32, Double, Double, gpointer?) -> Void, to: GCallback.self), RAW(label))
        gtk_widget_add_controller(W(label), dbl)
        return label
    }

    func reorderActiveSession(_ dir: ReorderDirection) {
        guard let id = store.selectedSessionID else { return }
        store.reorderSession(id, dir)
        rebuildSidebar()
        syncSidebarSelection()
    }

    /// Move the active workspace up/down in the sidebar (the GUI half of the `workspace.move` control arm).
    func reorderActiveWorkspace(_ dir: ReorderDirection) {
        guard let id = store.currentWorkspaceID else { return }
        store.reorderWorkspace(id, dir)
        rebuildSidebar()
        syncSidebarSelection()
    }

    func toggleSplit() {
        guard let id = store.selectedSessionID else { return }
        store.toggleSplit(id)
        reconcile()
        updateToggleIcons()
        focusedSurface(for: id)?.grabFocus()
    }

    func closeSplitPane(_ id: UUID) {
        store.closeSplitPane(id)
        reconcile()
        surfaces[id]?.grabFocus()
    }

    func toggleScratch() {
        guard let id = store.selectedSessionID else { return }
        store.toggleScratch(id)
        reconcile()
        updateToggleIcons()
    }

    /// Move keyboard focus between the two split panes of the active session.
    func focusPane(left: Bool) {
        guard let id = store.selectedSessionID, store.session(withID: id)?.hasSplit == true else { return }
        (left ? surfaces[id] : splitSurfaces[id])?.grabFocus()
    }

    /// Ctrl+Tab: jump to the most-recently-used OTHER session. Selecting re-pushes recency,
    /// so a second Ctrl+Tab toggles back (Alt-Tab-between-two).
    /// Ctrl-Tab: begin (or advance) the hold-to-cycle MRU switch via the shared SessionSwitcherModel. The
    /// first press lands on the most-recent OTHER session; further presses (while Ctrl is held) walk the
    /// MRU; releasing Ctrl commits (endSessionSwitch). The snapshot insulates the cycle from the recency
    /// reordering each in-cycle selection triggers.
    func quickSwitchSession(reverse: Bool = false) {
        if sessionSwitcher.isActive {
            if let id = sessionSwitcher.advance(reverse: reverse) { selectSession(id) }
        } else {
            let valid = Set(store.navigableSessions.map(\.id))
            let mru = store.sessionRecency.top(min(10, valid.count), in: valid)
            if let id = sessionSwitcher.begin(mru) { selectSession(id) }
        }
        if sessionSwitcher.isActive { showSwitcherOverlay() }
    }

    /// Ctrl released → commit the cycle so the next Ctrl-Tab starts fresh from the new MRU order.
    func endSessionSwitch() { sessionSwitcher.end(); hideSwitcherOverlay() }

    /// Show/refresh the MRU switch overlay: a centered card listing the cycle's sessions (most-recent
    /// first) with the current one highlighted. A GtkOverlay child over the deck, rebuilt on each advance.
    private func showSwitcherOverlay() {
        hideSwitcherOverlay()
        guard let overlay = deckOverlay, let box = op(gtk_box_new(GTK_ORIENTATION_VERTICAL, 2)) else { return }
        gtk_widget_set_halign(W(box), GTK_ALIGN_CENTER)
        gtk_widget_set_valign(W(box), GTK_ALIGN_CENTER)
        gtk_widget_add_css_class(W(box), "agterm-switcher")
        for id in sessionSwitcher.ordered {
            guard let s = store.session(withID: id), let label = op(gtk_label_new(s.displayName)) else { continue }
            gtk_widget_set_margin_start(W(label), 18); gtk_widget_set_margin_end(W(label), 18)
            gtk_label_set_xalign(label, 0)
            if id == sessionSwitcher.current { gtk_widget_add_css_class(W(label), "agterm-switcher-current") }
            gtk_box_append(cast(box), W(label))
        }
        switcherBox = box
        gtk_overlay_add_overlay(overlay, W(box))
    }

    private func hideSwitcherOverlay() {
        if let overlay = deckOverlay, let box = switcherBox { gtk_overlay_remove_overlay(overlay, W(box)) }
        switcherBox = nil
    }

    /// Show a persistent, centered message when the GtkGLArea can't create a GL context (VM/headless/
    /// llvmpipe-less/Wayland-no-GL) — the terminal can't render, so explain it instead of a blank pane.
    /// Added once over the deck; a GL failure is display-wide so a single message suffices.
    func showGLError() {
        guard let overlay = deckOverlay, glErrorLabel == nil else { return }
        let msg = "Terminal rendering needs OpenGL.\n\nNo GL context is available — check your GPU drivers, " +
                  "or enable 3D acceleration if you're running in a VM."
        guard let label = op(gtk_label_new(msg)) else { return }
        gtk_label_set_justify(label, GTK_JUSTIFY_CENTER)
        gtk_label_set_wrap(label, 1)
        gtk_widget_set_halign(W(label), GTK_ALIGN_CENTER)
        gtk_widget_set_valign(W(label), GTK_ALIGN_CENTER)
        gtk_widget_add_css_class(W(label), "agterm-gl-error")
        glErrorLabel = label
        gtk_overlay_add_overlay(overlay, W(label))
    }

    /// Surface a transient banner (AdwToast) over the window content — keymap/config parse diagnostics
    /// and other non-modal alerts. No-op before the content (and its toast overlay) is built.
    func showToast(_ message: String) {
        guard let overlay = toastOverlay else { return }
        message.withCString { adw_toast_overlay_add_toast(overlay, adw_toast_new($0)) }
    }

    func closeScratch(_ id: UUID) {
        store.closeScratch(id)
        reconcile()
    }

    nonisolated static var systemIsDark: Bool {
        adw_style_manager_get_dark(adw_style_manager_get_default()) != 0
    }

    /// The theme currently rendered for the live system appearance.
    var currentTheme: String? { linuxSettingsStore().load().activeTheme(isDark: Self.systemIsDark) }

    /// Reload ghostty config (re-reads ~/.config/ghostty + the persisted theme) into every
    /// live surface — the control `config.reload`, no restart needed.
    func reloadConfig() { applySettings(linuxSettingsStore().load()) }

    /// Bundled ghostty theme names (the file names in the resolved themes dir).
    nonisolated static func bundledThemes() -> [String] {
        var names = themesDir().map { ThemeCatalog.names(in: $0) } ?? []
        if !names.contains(AppSettings.defaultTheme) {
            names.append(AppSettings.defaultTheme)
        }
        return names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// The ghostty config lines for `settings`, with the seeded `agterm` default theme INLINED when it
    /// isn't a findable theme file — Linux ships none of its own ghostty resources, so it falls back to
    /// the system themes dir, which doesn't carry `agterm`. Without this the default look silently
    /// degrades to ghostty's built-in default. macOS stages the theme file, so this would be a no-op there.
    nonisolated static func ghosttyLines(for settings: AppSettings, isDark: Bool) -> [String] {
        var rendered = settings
        if settings.followSystemAppearance == true {
            rendered.theme = settings.activeTheme(isDark: isDark)
            rendered.darkTheme = nil
            rendered.followSystemAppearance = nil
        }
        var lines = rendered.ghosttyConfigLines()
        if let opacity = settings.backgroundOpacity, opacity < 1 {
            lines.removeAll { $0.hasPrefix("background-opacity = ") }
            lines.append("background-opacity = \(min(1, max(0, opacity)))")
        }
        if rendered.theme == AppSettings.defaultTheme, themeFileLines(for: AppSettings.defaultTheme) == nil {
            lines.removeAll { $0 == "theme = \(AppSettings.defaultTheme)" }
            lines.append(contentsOf: AppSettings.agtermThemeLines)
        } else if let theme = rendered.theme, let themeLines = themeFileLines(for: theme) {
            // libghostty's `theme = <name>` resolution is a no-op in the embedded `-Dapp-runtime=none`
            // build (it doesn't search GHOSTTY_RESOURCES_DIR), so a named theme never reached the surface
            // — only the default worked, because it inlines its colors. Inline the theme FILE's own config
            // lines instead (a theme file IS a ghostty config snippet), which actually applies it.
            lines.removeAll { $0 == "theme = \(theme)" }
            lines.append(contentsOf: themeLines)
        }
        return lines
    }

    /// The raw config lines of a bundled theme file (palette/background/foreground/cursor/…), resolved
    /// through the same themes dir as the picker; nil if the theme isn't a findable file (then the
    /// `theme = <name>` line stays and ghostty's default colors remain).
    nonisolated static func themeFileLines(for theme: String) -> [String]? {
        guard let dir = themesDir() else { return nil }
        let path = (dir as NSString).appendingPathComponent(theme)
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let lines = content.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        return lines.isEmpty ? nil : lines
    }

    /// The ghostty themes dir, resolved through the SAME `GhosttyResourceResolver` + candidate list that
    /// sets `GHOSTTY_RESOURCES_DIR` (themes live under `<resources>/themes`); a system themes-only dir is
    /// the last-ditch fallback for installs that ship themes without the full resources.
    nonisolated static func themesDir() -> String? {
        let resolver = GhosttyResourceResolver(candidates: ghosttyResourceCandidates(),
                                               fileExists: { FileManager.default.fileExists(atPath: $0) })
        if let dir = resolver.resolve() {
            let themes = (dir as NSString).appendingPathComponent("themes")
            if FileManager.default.fileExists(atPath: themes) { return themes }
        }
        return ["/usr/share/ghostty/themes", "/usr/local/share/ghostty/themes"]
            .first { FileManager.default.fileExists(atPath: $0) }
    }

    /// A given theme's chrome colors (shared resolver), with the inline `agterm` lines as the fallback
    /// for the seeded default that isn't a findable theme file.
    nonisolated static func themeColors(for theme: String?) -> ThemeColors {
        // The agterm default isn't a findable file → fall back to its inline lines; any OTHER missing
        // theme falls back to no tint (keep the Adwaita chrome) rather than borrowing agterm's colors.
        let fallback = (theme == AppSettings.defaultTheme) ? AppSettings.agtermThemeLines : []
        return ThemeColorResolver.colors(forTheme: theme, themesDir: themesDir(), fallbackLines: fallback)
    }

    static var sidebarThemeProvider: OpaquePointer?

    /// Theme the WHOLE window chrome — header bars, content area, popovers, and the sidebar — to the
    /// terminal theme, so a theme change (and the live picker preview) re-colors the entire window, not
    /// just the terminal. Overriding libadwaita's named colors (`@window_bg_color`, `@headerbar_bg_color`,
    /// `@view_bg_color`, …) re-themes the whole Adwaita stylesheet at once; the explicit `.agterm-sidebar`
    /// rules carry the shifted sidebar tint. Display-wide provider above the app CSS, re-applied on every
    /// theme/preview. A theme with no background drops the override so the Adwaita defaults return.
    func applyWindowThemeColors(for theme: String?, resolvedColors: ThemeColors? = nil) {
        guard let display = gdk_display_get_default() else { return }
        let colors = resolvedColors ?? Self.themeColors(for: theme)
        guard let themeBg = colors.background else {
            if let p = Self.sidebarThemeProvider {   // default theme → restore Adwaita's own chrome
                gtk_style_context_remove_provider_for_display(display, p)
                Self.sidebarThemeProvider = nil
            }
            return
        }
        let fg = colors.foreground ?? "inherit"
        let fallbackColors = Self.themeColors(for: theme)
        let preferredSelection = colors.selectionBackground ?? fallbackColors.selectionBackground
        let sel = ThemeColorResolver.selectionHighlight(background: themeBg, preferred: preferredSelection)
        let selFg = colors.selectionForeground ?? fallbackColors.selectionForeground ?? fg
        // Sidebar tint: shift the theme background darker (>5) / lighter (<5) per the Sidebar Tint setting.
        let shift = linuxSettingsStore().load().sidebarBackgroundShift ?? AppSettings.defaultSidebarBackgroundShift
        let sidebarBg = ThemeColorResolver.shiftedHex(themeBg, amount: AppSettings.sidebarShiftAmount(strength: shift))
        let css = """
        @define-color window_bg_color \(themeBg);
        @define-color window_fg_color \(fg);
        @define-color view_bg_color \(themeBg);
        @define-color view_fg_color \(fg);
        @define-color headerbar_bg_color \(themeBg);
        @define-color headerbar_backdrop_color \(themeBg);
        @define-color headerbar_fg_color \(fg);
        @define-color dialog_bg_color \(themeBg);
        @define-color dialog_fg_color \(fg);
        @define-color card_bg_color alpha(\(fg), 0.08);
        @define-color card_fg_color \(fg);
        @define-color card_shade_color alpha(#000000, 0.25);
        @define-color popover_bg_color \(themeBg);
        @define-color popover_fg_color \(fg);
        @define-color popover_shade_color alpha(#000000, 0.25);
        @define-color shade_color alpha(#000000, 0.25);
        @define-color sidebar_bg_color \(sidebarBg);
        @define-color sidebar_fg_color \(fg);
        .agterm-sidebar { background-color: \(sidebarBg); }
        .agterm-sidebar list, .agterm-sidebar row { background-color: transparent; }
        .agterm-selected { background-color: \(sel); }
        .agterm-sidebar label { color: \(fg); }
        .agterm-selected label { color: \(selFg); }
        .agterm-sidebar button { color: \(fg); }
        .agterm-sidebar separator { background-color: alpha(\(fg), 0.22); }
        toolbarview.agterm-sidebar-column > .top-bar,
        toolbarview.agterm-sidebar-column > .bottom-bar { background-color: \(sidebarBg); color: \(fg); }
        paned.agterm-sidebar-split > separator {
            min-width: 1px; padding: 0 4px; background-color: alpha(\(fg), 0.18); background-clip: content-box; box-shadow: none;
        }
        """
        if Self.sidebarThemeProvider == nil {
            let provider = OpaquePointer(gtk_css_provider_new())
            Self.sidebarThemeProvider = provider
            gtk_style_context_add_provider_for_display(display, provider, 650)   // above the app CSS (600)
        }
        if let provider = Self.sidebarThemeProvider {
            css.withCString { gtk_css_provider_load_from_string(cast(provider), $0) }
        }
    }
    /// Re-theme the chrome (window build, settings change, config reload) to the theme currently in effect
    /// — the live theme-picker preview when one is up, else the persisted one; see
    /// `applyResolvedWindowThemeColors` in `GhosttyConfigTheme.swift`.
    func applySidebarThemeColor() { applyResolvedWindowThemeColors() }
}
