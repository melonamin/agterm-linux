import CGtk
import Foundation

/// The widgets one session row owns for its whole life. Every optional part exists from the start —
/// hidden and cleared when absent — so a status, star or badge appearing later is a content update
/// rather than a structural edit. `applied` is what was last written: GTK re-parses markup and always
/// re-sets a tooltip, so the row skips unchanged values itself.
@MainActor
final class SessionRowWidgets {
    let row: OpaquePointer
    let box: OpaquePointer
    /// The fixed leading icon: the sibling a label ↔ rename-entry swap inserts after.
    let lead: OpaquePointer
    var name: OpaquePointer
    let glyph: OpaquePointer
    let star: OpaquePointer
    let badge: OpaquePointer
    var applied: SidebarSnapshot.RowContent?

    init(row: OpaquePointer, box: OpaquePointer, lead: OpaquePointer, name: OpaquePointer,
         glyph: OpaquePointer, star: OpaquePointer, badge: OpaquePointer) {
        self.row = row
        self.box = box
        self.lead = lead
        self.name = name
        self.glyph = glyph
        self.star = star
        self.badge = badge
    }
}

/// One `sidebarBox` child per section: a transparent wrapper holding the header, the list box and, in
/// flagged mode, the empty hint — so a section move is one `gtk_box_reorder_child_after` and detaches
/// nothing. The workspace-only parts are nil for the flagged section's plain label header.
@MainActor
final class SectionWidgets {
    let wrapper: OpaquePointer
    let header: OpaquePointer
    let disc: OpaquePointer?
    let icon: OpaquePointer?
    var name: OpaquePointer?
    let add: OpaquePointer?
    /// Always present: a collapsed section hides it, keeping its rows alive for in-place updates.
    let listBox: OpaquePointer
    var hint: OpaquePointer?
    var applied: SidebarSnapshot.HeaderContent?

    init(wrapper: OpaquePointer, header: OpaquePointer, listBox: OpaquePointer,
         disc: OpaquePointer? = nil, icon: OpaquePointer? = nil, name: OpaquePointer? = nil,
         add: OpaquePointer? = nil, hint: OpaquePointer? = nil) {
        self.wrapper = wrapper
        self.header = header
        self.listBox = listBox
        self.disc = disc
        self.icon = icon
        self.name = name
        self.add = add
        self.hint = hint
    }
}

/// Per-window state of the incremental sidebar: what is currently rendered, the widgets keyed by id, and
/// the blink pulse the rows share with the dashboard and the attention picker. Cleared by
/// `windowWillClose` before `blinkPhase.cancel()`, so no later resync can reach a destroyed tree.
@MainActor
final class SidebarRuntime {
    var current = SidebarSnapshot()
    var rows: [UUID: SessionRowWidgets] = [:]
    var sections: [SidebarSnapshot.Section.Key: SectionWidgets] = [:]
    /// Attention-picker glyph labels, live only while that popover is open.
    var pickerGlyphs: [UUID: OpaquePointer] = [:]
    var selectionRepublishScope = SelectionRepublishScope()
    let blinkPhase = BlinkPhaseCoordinator()
    var syncGate = SidebarSyncGate()
    var metadataRefresh = SidebarMetadataRefreshGate()
    var reveal = SidebarRevealState()
    let scrollRetry = SidebarScrollRetryCoordinator()
}

/// Which rows the next accessible-selection re-publish covers. Arming supersedes a pending job, so the
/// scope accumulates HERE instead of being captured by the closure: two syncs in one main-loop turn would
/// otherwise lose the first one's, and a forced rebuild's "every row" — which no id set expresses — would
/// be narrowed to a later pass's ids.
struct SelectionRepublishScope {
    private var all = false
    private var ids: Set<UUID> = []

    mutating func add(_ rows: Set<UUID>) { ids.formUnion(rows) }
    mutating func addAll() { all = true }

    /// Whether anything is waiting to be re-published: what the sync tail arms on.
    var isEmpty: Bool { !all && ids.isEmpty }

    /// The ids to re-publish, nil meaning every live row, consuming the scope.
    mutating func take() -> Set<UUID>? {
        defer { all = false; ids.removeAll() }
        return all ? nil : ids
    }
}

/// What one fired metadata refresh should do.
enum SidebarMetadataRefresh: Equatable {
    case inPlace, rebuild, retry
}

/// Both metadata callers share one debouncer, so forcedness is ORed across a coalesced burst: a
/// desktop font/DPI change must re-measure every label under new CSS and cannot be dropped by a
/// background shell's prompt redraw. Only that forced rebuild is destructive enough to wait behind an
/// interaction; an in-place refresh cannot disturb a rename or an open menu.
struct SidebarMetadataRefreshGate {
    private(set) var forced = false

    mutating func request(forced: Bool) {
        self.forced = self.forced || forced
    }

    /// Consumes the burst's forcedness — except on `.retry`, which re-arms itself as forced.
    mutating func take(interacting: Bool) -> SidebarMetadataRefresh {
        guard forced else { return .inPlace }
        guard !interacting else { return .retry }
        forced = false
        return .rebuild
    }
}

/// `syncSidebar` is not re-entrant: a dismissal grab lands in `surfaceDidFocus`, which comes back here.
/// A nested call records itself and returns; the owner drains those requests afterwards, bounded so a
/// pass that keeps re-entering cannot spin the main loop. A request past the bound is dropped rather than
/// left set, which would make the NEXT unrelated sync run a spurious extra pass.
struct SidebarSyncGate {
    static let maxDrainPasses = 3
    private var isSyncing = false
    private var pending = false
    private var drained = 0

    /// Whether the caller owns the pass; a nested call records itself instead.
    mutating func enter() -> Bool {
        guard !isSyncing else {
            pending = true
            return false
        }
        isSyncing = true
        pending = false
        drained = 0
        return true
    }

    /// Whether the owner should run one more pass for a request that arrived during the last one.
    mutating func takePending() -> Bool {
        defer { pending = false }
        guard pending, drained < Self.maxDrainPasses else { return false }
        drained += 1
        return true
    }

    mutating func exit() {
        isSyncing = false
        pending = false
    }
}
