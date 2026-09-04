import Foundation
import agtermCore

/// What the sidebar SHOULD render, keyed by id: the host-free model `syncSidebar` diffs against the live
/// widget tree instead of rebuilding it. Settings-derived presentation is folded in, so a settings change
/// is an ordinary content change rather than a separate refresh path.
struct SidebarSnapshot: Equatable {
    struct HeaderContent: Equatable {
        var name: String
        var renaming: Bool
        var focusMember: Bool
        var addVisible: Bool
        /// Carried here as well as on the section so a collapse repaints the disclosure arrow and the
        /// add-session tooltip; `setExpanded` only hides the list box.
        var expanded: Bool
    }

    struct RowContent: Equatable {
        var name: String
        var renaming: Bool
        var glyph: LinuxStatusGlyphPresentation?
        var blink: Bool
        var star: Bool
        var badge: String?
    }

    struct Section: Equatable {
        enum Key: Hashable {
            case workspace(UUID)
            case flagged
        }

        var key: Key
        var expanded: Bool
        var showsHint: Bool
        /// nil for the flagged section: its header is fixed text with nothing to update.
        var header: HeaderContent?
        var rows: [UUID]
        var content: [UUID: RowContent]
    }

    var sections: [Section] = []
    /// The EFFECTIVE selection over rendered rows, through `LinuxSidebarPolicy`'s single predicate.
    var selection: Set<UUID> = []

    /// The two flattenings the planner and the applier both need, first-wins on a duplicate key: they
    /// must agree on that policy or the applier feeds a row content the plan never compared against.
    var sectionsByKey: [Section.Key: Section] {
        Dictionary(sections.map { ($0.key, $0) }) { first, _ in first }
    }

    var rowContent: [UUID: RowContent] {
        sections.reduce(into: [:]) { $0.merge($1.content) { first, _ in first } }
    }

    /// What was actually rendered when GTK refused to build part of it: the applier records the failures
    /// so the next plan asks for them again rather than believing they are on screen.
    func without(rows: Set<UUID>, sections dropped: Set<Section.Key>) -> SidebarSnapshot {
        guard !rows.isEmpty || !dropped.isEmpty else { return self }
        var result = self
        result.sections = sections.filter { !dropped.contains($0.key) }.map { section in
            var section = section
            section.rows.removeAll(where: rows.contains)
            section.content = section.content.filter { !rows.contains($0.key) }
            return section
        }
        result.selection = result.selection.intersection(result.sections.flatMap(\.rows))
        return result
    }
}

extension SidebarSnapshot {
    /// Rows of a collapsed workspace are listed like any other: collapse hides the section's list box
    /// rather than detaching rows, so a hidden row still takes its updates in place.
    @MainActor
    static func desired(from store: AppStore, settings: AppSettings,
                        renaming: AppController.RenameTarget?) -> SidebarSnapshot {
        let flaggedView = store.sidebarMode == .flagged
        let builder = SidebarSnapshotBuilder(store: store, settings: settings,
                                             flaggedView: flaggedView, renamingID: renaming?.id)
        var snapshot = SidebarSnapshot()
        if flaggedView {
            let sessions = store.flaggedSessions
            snapshot.sections = [builder.section(key: .flagged, header: nil, sessions: sessions,
                                                 expanded: true, showsHint: sessions.isEmpty)]
        } else {
            snapshot.sections = store.visibleWorkspaces.map { workspace in
                let header = HeaderContent(
                    name: workspace.name,
                    renaming: builder.renamingID == workspace.id,
                    focusMember: store.focusedWorkspaceIDs.contains(workspace.id),
                    addVisible: !settings.isInterfaceElementHidden(.workspaceAddSession),
                    expanded: workspace.isExpanded)
                return builder.section(key: .workspace(workspace.id), header: header,
                                       sessions: workspace.sessions, expanded: workspace.isExpanded,
                                       showsHint: false)
            }
        }
        snapshot.selection = Set(snapshot.sections.flatMap(\.rows).filter {
            LinuxSidebarPolicy.sessionIsInEffectiveSelection(
                $0, selection: store.sidebarSelectionIDs, activeID: store.selectedSessionID)
        })
        return snapshot
    }
}

/// Carries everything a row derives from — the store, the loaded settings, the sidebar mode and the
/// rename target — so building one section stays a short call. A header is built by `desired` itself.
@MainActor
private struct SidebarSnapshotBuilder {
    let store: AppStore
    let settings: AppSettings
    let flaggedView: Bool
    let renamingID: UUID?

    func section(key: SidebarSnapshot.Section.Key,
                 header: SidebarSnapshot.HeaderContent?, sessions: [Session],
                 expanded: Bool, showsHint: Bool) -> SidebarSnapshot.Section {
        SidebarSnapshot.Section(
            key: key, expanded: expanded, showsHint: showsHint, header: header,
            rows: sessions.map(\.id),
            content: Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, rowContent($0)) }))
    }

    private func rowContent(_ session: Session) -> SidebarSnapshot.RowContent {
        // A flagged row normally carries its workspace breadcrumb, but inline rename edits the bare name.
        let renaming = renamingID == session.id
        let glyph = LinuxStatusGlyphPresentation(indicator: session.agentIndicator, settings: settings)
        let unseen = session.unseenCount
        let badged = unseen > 0 && (settings.notificationBadgeEnabled ?? true)
        return SidebarSnapshot.RowContent(
            name: flaggedView && !renaming
                ? LinuxSidebarPolicy.flaggedRowLabel(for: session, in: store)
                : session.displayName,
            renaming: renaming,
            glyph: glyph,
            blink: glyph != nil && session.agentIndicator.blink,
            star: session.flagged && !flaggedView,
            badge: badged ? (unseen > 99 ? "99+" : "\(unseen)") : nil)
    }
}

/// Turns two snapshots into the smallest set of widget operations that carries the live tree from one to
/// the other. Structural moves are minimal in COUNT (everything outside a longest increasing subsequence
/// moves); WHICH id moves among tied choices is settled by `preferMoving` and otherwise unspecified.
enum SidebarSnapshotDiff {
    typealias Key = SidebarSnapshot.Section.Key

    enum LayoutOp: Equatable {
        case rebuildAll
        case removeRow(UUID)
        case insertRow(UUID, section: Key, index: Int)
        case moveRow(UUID, section: Key, index: Int)
        case removeSection(Key)
        case insertSection(Key, index: Int)
        case moveSection(Key, index: Int)
        case setExpanded(Key, Bool)
        case setHint(Key, Bool)
        case updateHeader(Key)
        case updateRow(UUID)
        case updateSelection(Set<UUID>)
    }

    /// Ops apply IN EMITTED ORDER against a mutable target list: an index is the position an element takes
    /// after every earlier op, and a move is "remove it from where it is, then insert at that index".
    static func plan(from: SidebarSnapshot, to: SidebarSnapshot,
                     preferMoving: Set<UUID> = []) -> [LayoutOp] {
        // Only a MODE flip rebuilds: rows differ in kind there. An empty `from` is the first sync, which
        // is all inserts.
        if !from.sections.isEmpty, !to.sections.isEmpty,
           hasFlagged(from) != hasFlagged(to) { return [.rebuildAll] }

        let toKeys = to.sections.map(\.key)
        let survivingKeys = from.sections.map(\.key).filter(toKeys.contains)
        let targetIDs = Set(to.sections.flatMap(\.rows))
        var ops: [LayoutOp] = []
        var work: [Key: [UUID]] = [:]

        for section in from.sections where survivingKeys.contains(section.key) {
            for id in section.rows where !targetIDs.contains(id) { ops.append(.removeRow(id)) }
            work[section.key] = section.rows.filter(targetIDs.contains)
        }
        for key in from.sections.map(\.key) where !toKeys.contains(key) { ops.append(.removeSection(key)) }

        var sectionOrder = survivingKeys
        ops += sectionOps(work: &sectionOrder, target: toKeys,
                          hinted: Set(preferMoving.map(Key.workspace)))
        let rowOps = rowOps(work: &work, to: to, preferMoving: preferMoving)
        ops += rowOps
        ops += contentOps(from: from, to: to, inserted: insertedRows(rowOps))
        let changedSelection = from.selection.symmetricDifference(to.selection)
        if !changedSelection.isEmpty { ops.append(.updateSelection(changedSelection)) }
        return ops
    }

    private static func hasFlagged(_ snapshot: SidebarSnapshot) -> Bool {
        snapshot.sections.contains { $0.key == .flagged }
    }

    /// Only an INSERT carries content: it builds the row from it. A move reparents the existing widget
    /// and touches nothing on it, so a row that moves and changes in one pass still needs its update.
    private static func insertedRows(_ ops: [LayoutOp]) -> Set<UUID> {
        Set(ops.compactMap {
            if case .insertRow(let id, _, _) = $0 { return id }
            return nil
        })
    }

    /// Row structure across ALL sections at once, so a row leaving one section for another is one move
    /// rather than a remove and an insert. Sections are processed in target order and each writes its
    /// list back before the next reads it, so a cross-section claim always sees current state.
    private static func rowOps(work: inout [Key: [UUID]], to: SidebarSnapshot,
                               preferMoving: Set<UUID>) -> [LayoutOp] {
        var ops: [LayoutOp] = []
        for section in to.sections {
            var list = work[section.key] ?? []
            let target = section.rows
            let keep = stable(list, target: target, hinted: preferMoving)
            for index in stride(from: target.count - 1, through: 0, by: -1) {
                let id = target[index]
                guard !keep.contains(id) else { continue }
                var reused = false
                if let existing = list.firstIndex(of: id) {
                    list.remove(at: existing)
                    reused = true
                } else if let source = work.first(where: { $0.key != section.key && $0.value.contains(id) })?.key {
                    work[source]?.removeAll { $0 == id }
                    reused = true
                }
                let anchor = Self.anchor(after: index, in: list, target: target)
                list.insert(id, at: anchor)
                ops.append(reused ? .moveRow(id, section: section.key, index: anchor)
                                  : .insertRow(id, section: section.key, index: anchor))
            }
            work[section.key] = list
        }
        return ops
    }

    private static func contentOps(from: SidebarSnapshot, to: SidebarSnapshot,
                                   inserted: Set<UUID>) -> [LayoutOp] {
        let previousSections = from.sectionsByKey
        let previousContent = from.rowContent
        var ops: [LayoutOp] = []
        for section in to.sections {
            guard let previous = previousSections[section.key] else { continue }
            if previous.expanded != section.expanded { ops.append(.setExpanded(section.key, section.expanded)) }
            if previous.showsHint != section.showsHint { ops.append(.setHint(section.key, section.showsHint)) }
        }
        for section in to.sections {
            if let previous = previousSections[section.key], previous.header != section.header {
                ops.append(.updateHeader(section.key))
            }
            // An inserted row is built from its content; a moved one still needs the update.
            for id in section.rows where !inserted.contains(id) {
                guard let content = section.content[id], previousContent[id] != content else { continue }
                ops.append(.updateRow(id))
            }
        }
        return ops
    }

    /// Places every section that is not kept, walking the target from the END so the already-placed
    /// successor is the anchor. A section already in `work` moves; a new one is inserted.
    private static func sectionOps(work: inout [Key], target: [Key], hinted: Set<Key>) -> [LayoutOp] {
        let keep = stable(work, target: target, hinted: hinted)
        var ops: [LayoutOp] = []
        for index in stride(from: target.count - 1, through: 0, by: -1) {
            let key = target[index]
            guard !keep.contains(key) else { continue }
            let existing = work.firstIndex(of: key)
            if let existing { work.remove(at: existing) }
            let anchor = Self.anchor(after: index, in: work, target: target)
            work.insert(key, at: anchor)
            ops.append(existing != nil ? .moveSection(key, index: anchor)
                                       : .insertSection(key, index: anchor))
        }
        return ops
    }

    /// Where the element at `index` lands: just before its already-placed successor, or at the end when
    /// it is last. Both walks run right-to-left, so that successor is always already in final position.
    private static func anchor<Element: Equatable>(after index: Int, in list: [Element],
                                                   target: [Element]) -> Int {
        guard index + 1 < target.count else { return list.count }
        return list.firstIndex(of: target[index + 1]) ?? list.count
    }

    /// The elements that stay put: a longest increasing subsequence of their target positions, so the
    /// moved COUNT is minimal. Among equally long subsequences the one holding the fewest `hinted`
    /// elements wins, which is what makes a drag move the id the user dragged rather than its neighbour.
    private static func stable<Element: Hashable>(
        _ work: [Element], target: [Element], hinted: Set<Element>) -> Set<Element> {
        var position: [Element: Int] = [:]
        for (index, element) in target.enumerated() { position[element] = index }
        let items = work.compactMap { element in position[element].map { (element, $0) } }
        guard !items.isEmpty else { return [] }
        var best = [(length: Int, unhinted: Int)](repeating: (1, 0), count: items.count)
        var previous = [Int?](repeating: nil, count: items.count)
        var top = 0
        for index in items.indices {
            let unhinted = hinted.contains(items[index].0) ? 0 : 1
            best[index] = (1, unhinted)
            for candidate in 0..<index where items[candidate].1 < items[index].1 {
                let score = (best[candidate].length + 1, best[candidate].unhinted + unhinted)
                if score > (best[index].length, best[index].unhinted) {
                    best[index] = (length: score.0, unhinted: score.1)
                    previous[index] = candidate
                }
            }
            if (best[index].length, best[index].unhinted) > (best[top].length, best[top].unhinted) {
                top = index
            }
        }
        var keep: Set<Element> = []
        var cursor: Int? = top
        while let index = cursor {
            keep.insert(items[index].0)
            cursor = previous[index]
        }
        return keep
    }
}
