import Foundation
import Testing
import agtermCore
@testable import AgtermLinux

private typealias Key = SidebarSnapshot.Section.Key
private typealias LayoutOp = SidebarSnapshotDiff.LayoutOp

private struct SectionShape: Equatable {
    let key: Key
    let rows: [UUID]
    let expanded: Bool
    let showsHint: Bool
}

private func content(_ name: String = "row") -> SidebarSnapshot.RowContent {
    SidebarSnapshot.RowContent(name: name, renaming: false, glyph: nil, blink: false,
                               star: false, badge: nil)
}

private func section(_ key: Key, _ rows: [UUID], expanded: Bool = true, showsHint: Bool = false,
                     header: SidebarSnapshot.HeaderContent? = nil,
                     content rowContent: [UUID: SidebarSnapshot.RowContent]? = nil)
    -> SidebarSnapshot.Section {
    SidebarSnapshot.Section(
        key: key, expanded: expanded, showsHint: showsHint, header: header, rows: rows,
        content: rowContent ?? Dictionary(uniqueKeysWithValues: rows.map { ($0, content()) }))
}

private func shape(_ sections: [SidebarSnapshot.Section]) -> [SectionShape] {
    sections.map { SectionShape(key: $0.key, rows: $0.rows, expanded: $0.expanded,
                                showsHint: $0.showsHint) }
}

/// The op contract `applyLayoutOps` implements against real widgets: ops run in emitted order against a
/// mutable list, and a move is "remove the element from where it is, then insert it at the op's index".
private func simulate(_ ops: [LayoutOp], from: SidebarSnapshot, to: SidebarSnapshot) -> [SectionShape] {
    var sections = from.sections
    func at(_ key: Key) -> Int { sections.firstIndex { $0.key == key }! }
    func drop(_ id: UUID) { for index in sections.indices { sections[index].rows.removeAll { $0 == id } } }
    for op in ops {
        switch op {
        case .rebuildAll:
            sections = to.sections
        case .removeRow(let id):
            drop(id)
        case .removeSection(let key):
            sections.remove(at: at(key))
        case .insertSection(let key, let index):
            let template = to.sections.first { $0.key == key }!
            sections.insert(section(key, [], expanded: template.expanded,
                                    showsHint: template.showsHint, header: template.header,
                                    content: [:]), at: index)
        case .moveSection(let key, let index):
            let moved = sections.remove(at: at(key))
            sections.insert(moved, at: index)
        case .insertRow(let id, let key, let index), .moveRow(let id, let key, let index):
            drop(id)
            sections[at(key)].rows.insert(id, at: index)
        case .setExpanded(let key, let value):
            sections[at(key)].expanded = value
        case .setHint(let key, let value):
            sections[at(key)].showsHint = value
        case .updateHeader, .updateRow, .updateSelection:
            break
        }
    }
    return shape(sections)
}

private func permutations<Element>(_ elements: [Element]) -> [[Element]] {
    guard elements.count > 1 else { return [elements] }
    var result: [[Element]] = []
    for (index, element) in elements.enumerated() {
        var rest = elements
        rest.remove(at: index)
        result += permutations(rest).map { [element] + $0 }
    }
    return result
}

private func longestIncreasing(_ values: [Int]) -> Int {
    var best = [Int](repeating: 1, count: values.count)
    for index in values.indices {
        for candidate in 0..<index where values[candidate] < values[index] {
            best[index] = max(best[index], best[candidate] + 1)
        }
    }
    return best.max() ?? 0
}

private func moveCount(_ ops: [LayoutOp]) -> Int {
    ops.filter { if case .moveRow = $0 { return true }; return false }.count
}

/// The persisted set, which is what the effective set is with an empty reveal overlay.
@MainActor
private func persistedExpansion(_ store: AppStore) -> Set<UUID> {
    Set(store.workspaces.filter(\.isExpanded).map(\.id))
}

@Suite("sidebar snapshot")
@MainActor
struct SidebarSnapshotTests {
    private func store(_ workspaces: [Workspace]) -> AppStore {
        AppStore(workspaces: workspaces, selectedSessionID: workspaces.first?.sessions.first?.id)
    }

    @Test("tree mode follows visible workspace order and expansion")
    func treeSections() {
        let alpha = Session(initialCwd: "/tmp", customName: "alpha")
        let beta = Session(initialCwd: "/tmp", customName: "beta")
        let first = Workspace(name: "one", sessions: [alpha])
        let second = Workspace(name: "two", sessions: [beta], isExpanded: false)
        let model = store([first, second])
        let snapshot = SidebarSnapshot.desired(from: model, settings: AppSettings(), renaming: nil,
                                               expandedWorkspaceIDs: persistedExpansion(model))

        #expect(snapshot.sections.map(\.key) == [.workspace(first.id), .workspace(second.id)])
        #expect(snapshot.sections.map(\.expanded) == [true, false])
        // A collapsed workspace still lists its rows: collapse hides the list box, it detaches nothing.
        #expect(snapshot.sections[1].rows == [beta.id])
        #expect(snapshot.sections[0].header?.name == "one")
        #expect(snapshot.sections.map { $0.header?.expanded } == [true, false])
        #expect(snapshot.sections[0].content[alpha.id]?.name == "alpha")
        #expect(snapshot.selection == [alpha.id])
    }

    @Test("the caller's expanded set overrides a persisted collapse in section and header")
    func revealedWorkspaceReadsExpanded() {
        let folded = Workspace(name: "two", sessions: [Session(initialCwd: "/tmp")], isExpanded: false)
        let model = store([folded])
        let snapshot = SidebarSnapshot.desired(from: model, settings: AppSettings(), renaming: nil,
                                               expandedWorkspaceIDs: [folded.id])

        #expect(snapshot.sections[0].expanded)
        #expect(snapshot.sections[0].header?.expanded == true)
    }

    @Test("a session selected inside a collapsed workspace reveals it without a store write")
    func selectionRevealsItsOwner() {
        let buried = Session(initialCwd: "/tmp", customName: "buried")
        let folded = Workspace(name: "folded", sessions: [buried], isExpanded: false)
        let model = AppStore(workspaces: [folded], selectedSessionID: buried.id)
        var reveal = SidebarRevealState()
        let snapshot = SidebarSnapshot.desired(from: model, settings: AppSettings(), renaming: nil,
                                               expandedWorkspaceIDs: reveal.syncedExpansion(store: model))

        #expect(snapshot.sections[0].expanded)
        #expect(snapshot.sections[0].header?.expanded == true)
        #expect(model.workspaces[0].isExpanded == false)
    }

    @Test("flagged mode reveals nothing and the focus filter never narrows the effective set")
    func effectiveSetSpansEveryWorkspace() {
        let buried = Session(initialCwd: "/tmp", customName: "buried")
        let open = Workspace(name: "open", sessions: [Session(initialCwd: "/tmp")])
        let folded = Workspace(name: "folded", sessions: [buried], isExpanded: false)
        let model = AppStore(workspaces: [open, folded], selectedSessionID: buried.id)
        var reveal = SidebarRevealState()

        model.setSidebarMode(.flagged)
        #expect(reveal.syncedExpansion(store: model) == persistedExpansion(model))

        model.setSidebarMode(.tree)
        model.setFocusMembership(folded.id, member: true)
        model.setFocusEnabled(true)
        #expect(model.visibleWorkspaces.map(\.id) == [folded.id])
        #expect(reveal.syncedExpansion(store: model).contains(open.id))
    }

    @Test("revealing a collapsed workspace plans one setExpanded and its header, never a rebuild")
    func revealPlansOneExpansion() {
        let folded = Workspace(name: "two", sessions: [Session(initialCwd: "/tmp")], isExpanded: false)
        let model = store([folded])
        let collapsed = SidebarSnapshot.desired(from: model, settings: AppSettings(), renaming: nil,
                                                expandedWorkspaceIDs: persistedExpansion(model))
        let revealed = SidebarSnapshot.desired(from: model, settings: AppSettings(), renaming: nil,
                                               expandedWorkspaceIDs: [folded.id])

        #expect(SidebarSnapshotDiff.plan(from: collapsed, to: revealed)
            == [.setExpanded(.workspace(folded.id), true), .updateHeader(.workspace(folded.id))])
    }

    @Test("the snapshot carries the whole multi-row selection, not just the active session")
    func multiRowSelection() {
        let alpha = Session(initialCwd: "/tmp", customName: "alpha")
        let beta = Session(initialCwd: "/tmp", customName: "beta")
        let gamma = Session(initialCwd: "/tmp", customName: "gamma")
        let model = store([Workspace(name: "one", sessions: [alpha, beta, gamma])])
        model.setSidebarSelection([alpha.id, beta.id])

        #expect(SidebarSnapshot.desired(from: model, settings: AppSettings(), renaming: nil,
                                        expandedWorkspaceIDs: persistedExpansion(model))
            .selection == [alpha.id, beta.id])
    }

    @Test("flagged mode is one breadcrumb section, hinted when empty")
    func flaggedSection() {
        let alpha = Session(initialCwd: "/tmp", customName: "alpha")
        alpha.flagged = true
        let plain = Session(initialCwd: "/tmp", customName: "plain")
        let model = store([Workspace(name: "one", sessions: [alpha, plain])])
        model.sidebarMode = .flagged
        let snapshot = SidebarSnapshot.desired(from: model, settings: AppSettings(), renaming: nil,
                                               expandedWorkspaceIDs: persistedExpansion(model))

        #expect(snapshot.sections.map(\.key) == [.flagged])
        #expect(snapshot.sections[0].header == nil)
        #expect(snapshot.sections[0].rows == [alpha.id])
        #expect(snapshot.sections[0].content[alpha.id]?.name == "alpha  —  one")
        #expect(snapshot.sections[0].content[alpha.id]?.star == false)
        #expect(!snapshot.sections[0].showsHint)

        alpha.flagged = false
        let empty = SidebarSnapshot.desired(from: model, settings: AppSettings(), renaming: nil,
                                            expandedWorkspaceIDs: persistedExpansion(model))
        #expect(empty.sections[0].rows.isEmpty)
        #expect(empty.sections[0].showsHint)
    }

    @Test("the focus filter drops non-member workspaces")
    func focusFilteredSections() {
        let first = Workspace(name: "one", sessions: [Session(initialCwd: "/tmp")])
        let second = Workspace(name: "two", sessions: [Session(initialCwd: "/tmp")])
        let model = store([first, second])
        model.setFocusMembership(second.id, member: true)
        model.setFocusEnabled(true)
        let snapshot = SidebarSnapshot.desired(from: model, settings: AppSettings(), renaming: nil,
                                               expandedWorkspaceIDs: persistedExpansion(model))

        #expect(snapshot.sections.map(\.key) == [.workspace(second.id)])
        #expect(snapshot.sections[0].header?.focusMember == true)
    }

    @Test("settings drive badge, add button and glyph presentation")
    func settingsDrivenContent() throws {
        let alpha = Session(initialCwd: "/tmp", customName: "alpha")
        alpha.unseenCount = 120
        alpha.flagged = true
        alpha.agentIndicator = AgentIndicator(status: .active, blink: true)
        let model = store([Workspace(name: "one", sessions: [alpha])])

        let plain = SidebarSnapshot.desired(from: model, settings: AppSettings(), renaming: nil,
                                            expandedWorkspaceIDs: persistedExpansion(model))
        let row = try #require(plain.sections[0].content[alpha.id])
        #expect(row.badge == "99+")
        #expect(row.star)
        #expect(row.blink)
        #expect(plain.sections[0].header?.addVisible == true)

        var settings = AppSettings()
        settings.notificationBadgeEnabled = false
        settings.hiddenInterfaceElements = [InterfaceElement.workspaceAddSession.rawValue]
        settings.activeStatusColorHex = "#112233"
        let tuned = SidebarSnapshot.desired(from: model, settings: settings, renaming: nil,
                                            expandedWorkspaceIDs: persistedExpansion(model))
        let tunedRow = try #require(tuned.sections[0].content[alpha.id])
        #expect(tunedRow.badge == nil)
        #expect(tunedRow.glyph?.colorHex == "#112233")
        #expect(tuned.sections[0].header?.addVisible == false)
    }

    @Test("an idle indicator has no glyph and cannot blink")
    func idleRowHasNoGlyph() throws {
        let alpha = Session(initialCwd: "/tmp", customName: "alpha")
        alpha.agentIndicator = AgentIndicator(status: .idle, blink: true)
        let model = store([Workspace(name: "one", sessions: [alpha])])
        let row = try #require(SidebarSnapshot.desired(
            from: model, settings: AppSettings(), renaming: nil,
            expandedWorkspaceIDs: persistedExpansion(model)).sections[0].content[alpha.id])

        #expect(row.glyph == nil)
        #expect(!row.blink)
    }

    @Test("renaming marks its row or header and drops the breadcrumb")
    func renamingContent() {
        let alpha = Session(initialCwd: "/tmp", customName: "alpha")
        alpha.flagged = true
        let workspace = Workspace(name: "one", sessions: [alpha])
        let model = store([workspace])
        model.sidebarMode = .flagged
        let renamed = SidebarSnapshot.desired(from: model, settings: AppSettings(),
                                              renaming: .session(alpha.id),
                                              expandedWorkspaceIDs: persistedExpansion(model))
        #expect(renamed.sections[0].content[alpha.id]?.renaming == true)
        #expect(renamed.sections[0].content[alpha.id]?.name == "alpha")

        model.sidebarMode = .tree
        let header = SidebarSnapshot.desired(
            from: model, settings: AppSettings(), renaming: .workspace(workspace.id),
            expandedWorkspaceIDs: persistedExpansion(model)).sections[0].header
        #expect(header?.renaming == true)
    }
}

@Suite("sidebar snapshot flattenings")
struct SidebarSnapshotFlatteningTests {
    @Test("the planner and the applier read one flattening of every section")
    func flattensEverySection() {
        let first = UUID(), second = UUID()
        let snapshot = SidebarSnapshot(
            sections: [section(.flagged, [first], content: [first: content("one")]),
                       section(.workspace(UUID()), [second], content: [second: content("two")])],
            selection: [])

        #expect(snapshot.sectionsByKey.count == 2)
        #expect(snapshot.sectionsByKey[.flagged]?.rows == [first])
        #expect(snapshot.rowContent[first]?.name == "one")
        #expect(snapshot.rowContent[second]?.name == "two")
    }
}

@Suite("sidebar snapshot diff")
@MainActor
struct SidebarSnapshotDiffTests {
    private let workspace = Key.workspace(UUID())
    private let other = Key.workspace(UUID())
    private let ids = (0..<6).map { _ in UUID() }

    private func tree(_ rows: [UUID], expanded: Bool = true) -> SidebarSnapshot {
        SidebarSnapshot(sections: [section(workspace, rows, expanded: expanded)], selection: [])
    }

    @Test("an unchanged snapshot plans nothing")
    func identical() {
        let snapshot = tree([ids[0], ids[1]])
        #expect(SidebarSnapshotDiff.plan(from: snapshot, to: snapshot).isEmpty)
    }

    @Test("a first sync from an empty snapshot is all inserts")
    func firstSync() {
        let target = tree([ids[0], ids[1]])
        let ops = SidebarSnapshotDiff.plan(from: SidebarSnapshot(), to: target)

        #expect(ops.contains(.insertSection(workspace, index: 0)))
        #expect(!ops.contains(.rebuildAll))
        #expect(simulate(ops, from: SidebarSnapshot(), to: target) == shape(target.sections))
    }

    @Test("row insert and remove touch one row each")
    func rowInsertAndRemove() {
        let from = tree([ids[0], ids[1]])
        let inserted = tree([ids[0], ids[2], ids[1]])
        let insertOps = SidebarSnapshotDiff.plan(from: from, to: inserted)
        #expect(insertOps == [.insertRow(ids[2], section: workspace, index: 1)])
        #expect(simulate(insertOps, from: from, to: inserted) == shape(inserted.sections))

        let removed = tree([ids[1]])
        let removeOps = SidebarSnapshotDiff.plan(from: from, to: removed)
        #expect(removeOps == [.removeRow(ids[0])])
        #expect(simulate(removeOps, from: from, to: removed) == shape(removed.sections))
    }

    @Test("one-row moves up and down move exactly the dragged row")
    func singleRowMoves() {
        let from = tree([ids[0], ids[1], ids[2]])
        let up = tree([ids[2], ids[0], ids[1]])
        #expect(SidebarSnapshotDiff.plan(from: from, to: up, preferMoving: [ids[2]])
            == [.moveRow(ids[2], section: workspace, index: 0)])
        #expect(simulate(SidebarSnapshotDiff.plan(from: from, to: up), from: from, to: up)
            == shape(up.sections))

        let down = tree([ids[1], ids[2], ids[0]])
        #expect(SidebarSnapshotDiff.plan(from: from, to: down, preferMoving: [ids[0]])
            == [.moveRow(ids[0], section: workspace, index: 2)])
    }

    @Test("a rotation moves one row and a reversal moves the minimum")
    func rotationsAndReversal() {
        let from = tree([ids[0], ids[1], ids[2]])
        for target in [tree([ids[1], ids[2], ids[0]]), tree([ids[2], ids[0], ids[1]])] {
            let ops = SidebarSnapshotDiff.plan(from: from, to: target)
            #expect(moveCount(ops) == 1)
            #expect(simulate(ops, from: from, to: target) == shape(target.sections))
        }
        let reversed = tree([ids[2], ids[1], ids[0]])
        let ops = SidebarSnapshotDiff.plan(from: from, to: reversed)
        #expect(moveCount(ops) == 2)
        #expect(simulate(ops, from: from, to: reversed) == shape(reversed.sections))
    }

    @Test("removals precede inserts and moves in a mixed change")
    func mixedChange() {
        let from = tree([ids[0], ids[1], ids[2]])
        let to = tree([ids[2], ids[3], ids[1]])
        let ops = SidebarSnapshotDiff.plan(from: from, to: to)

        #expect(ops.first == .removeRow(ids[0]))
        #expect(ops.contains { if case .insertRow(ids[3], _, _) = $0 { return true }; return false })
        #expect(moveCount(ops) == 1)
        #expect(simulate(ops, from: from, to: to) == shape(to.sections))
    }

    @Test("a row changing workspace is one move, not a remove and an insert")
    func crossSectionMove() {
        let from = SidebarSnapshot(sections: [section(workspace, [ids[0], ids[1]]),
                                              section(other, [ids[2]])])
        let to = SidebarSnapshot(sections: [section(workspace, [ids[0]]),
                                            section(other, [ids[1], ids[2]])])
        let ops = SidebarSnapshotDiff.plan(from: from, to: to)

        #expect(ops.contains(.moveRow(ids[1], section: other, index: 0)))
        #expect(!ops.contains(.removeRow(ids[1])))
        #expect(simulate(ops, from: from, to: to) == shape(to.sections))
    }

    @Test("sections insert, remove and move like rows")
    func sectionStructure() {
        let third = Key.workspace(UUID())
        let from = SidebarSnapshot(sections: [section(workspace, []), section(other, [])])
        let to = SidebarSnapshot(sections: [section(other, []), section(third, []),
                                            section(workspace, [])])
        let ops = SidebarSnapshotDiff.plan(from: from, to: to)

        #expect(ops.contains { if case .insertSection(third, _) = $0 { return true }; return false })
        #expect(ops.contains { if case .moveSection = $0 { return true }; return false })
        #expect(simulate(ops, from: from, to: to) == shape(to.sections))

        let dropped = SidebarSnapshot(sections: [section(other, [])])
        #expect(SidebarSnapshotDiff.plan(from: from, to: dropped) == [.removeSection(workspace)])
    }

    @Test("a removed section takes its rows with it, and a survivor elsewhere is an insert")
    func removedSectionCarriesItsRows() {
        let from = SidebarSnapshot(sections: [section(workspace, [ids[0], ids[1]]),
                                              section(other, [ids[2]])])
        // The wrapper goes down with every widget under it, so nothing is removed row by row.
        let closed = SidebarSnapshot(sections: [section(other, [ids[2]])])
        #expect(SidebarSnapshotDiff.plan(from: from, to: closed) == [.removeSection(workspace)])

        // The survivor's widget went down with the wrapper, so it is rebuilt rather than reparented.
        let survivor = SidebarSnapshot(sections: [section(other, [ids[2], ids[0]])])
        let ops = SidebarSnapshotDiff.plan(from: from, to: survivor)
        #expect(ops == [.removeSection(workspace), .insertRow(ids[0], section: other, index: 1)])
        #expect(simulate(ops, from: from, to: survivor) == shape(survivor.sections))
    }

    @Test("collapse, expand and the flagged hint carry no row ops")
    func expansionAndHint() {
        let from = tree([ids[0], ids[1]])
        let collapsed = tree([ids[0], ids[1]], expanded: false)
        #expect(SidebarSnapshotDiff.plan(from: from, to: collapsed) == [.setExpanded(workspace, false)])
        #expect(SidebarSnapshotDiff.plan(from: collapsed, to: from) == [.setExpanded(workspace, true)])

        let empty = SidebarSnapshot(sections: [section(.flagged, [])])
        let hinted = SidebarSnapshot(sections: [section(.flagged, [], showsHint: true)])
        #expect(SidebarSnapshotDiff.plan(from: empty, to: hinted) == [.setHint(.flagged, true)])
    }

    @Test("a mode switch rebuilds everything")
    func modeSwitchRebuilds() {
        let tree = tree([ids[0]])
        let flagged = SidebarSnapshot(sections: [section(.flagged, [ids[0]])])

        #expect(SidebarSnapshotDiff.plan(from: tree, to: flagged) == [.rebuildAll])
        #expect(SidebarSnapshotDiff.plan(from: flagged, to: tree) == [.rebuildAll])

        // A focus filter matching nothing renders no sections, and there is then no widget of the
        // wrong kind to tear down: both directions are ordinary structure.
        let none = SidebarSnapshot()
        #expect(SidebarSnapshotDiff.plan(from: none, to: flagged)
            == [.insertSection(.flagged, index: 0), .insertRow(ids[0], section: .flagged, index: 0)])
        #expect(SidebarSnapshotDiff.plan(from: flagged, to: none) == [.removeSection(.flagged)])
    }

    @Test("every permutation of up to five rows moves the minimum and reproduces the target")
    func exhaustivePermutations() {
        for count in 1...5 {
            let rows = Array(ids.prefix(count))
            let from = tree(rows)
            for target in permutations(rows) {
                let to = tree(target)
                let ops = SidebarSnapshotDiff.plan(from: from, to: to)
                let positions = rows.map { target.firstIndex(of: $0)! }
                #expect(moveCount(ops) == count - longestIncreasing(positions))
                #expect(ops.allSatisfy { if case .moveRow = $0 { return true }; return false })
                #expect(simulate(ops, from: from, to: to) == shape(to.sections))
            }
        }
    }

    /// Why `syncSidebar` refuses to nest: a pass reads `current` at entry and writes it back at exit, so a
    /// re-entrant call planning against the entry snapshot would apply ops the tree has already outgrown.
    @Test("a plan against a stale snapshot cannot reach the target")
    func stalePlanCannotReachTarget() {
        let rendered = tree([ids[0], ids[1]])
        let applied = tree([ids[0], ids[1], ids[2]])
        let target = tree([ids[1], ids[0]])

        let stale = SidebarSnapshotDiff.plan(from: rendered, to: target)
        #expect(simulate(stale, from: applied, to: target) != shape(target.sections))
        let fresh = SidebarSnapshotDiff.plan(from: applied, to: target)
        #expect(simulate(fresh, from: applied, to: target) == shape(target.sections))
    }

    @Test("a preferMoving hint decides which of two tied rows moves")
    func preferMovingBreaksTies() {
        let from = tree([ids[0], ids[1]])
        let to = tree([ids[1], ids[0]])

        #expect(SidebarSnapshotDiff.plan(from: from, to: to, preferMoving: [ids[0]])
            == [.moveRow(ids[0], section: workspace, index: 1)])
        #expect(SidebarSnapshotDiff.plan(from: from, to: to, preferMoving: [ids[1]])
            == [.moveRow(ids[1], section: workspace, index: 0)])
    }
}

@Suite("sidebar diff content ops")
@MainActor
struct SidebarSnapshotContentDiffTests {
    private let workspace = Key.workspace(UUID())
    private let ids = (0..<3).map { _ in UUID() }

    private func snapshot(_ rows: [UUID: SidebarSnapshot.RowContent],
                          order: [UUID], header: SidebarSnapshot.HeaderContent? = nil,
                          selection: Set<UUID> = []) -> SidebarSnapshot {
        SidebarSnapshot(sections: [section(workspace, order, header: header, content: rows)],
                        selection: selection)
    }

    private func header(name: String = "one", renaming: Bool = false, focusMember: Bool = false,
                        addVisible: Bool = true,
                        expanded: Bool = true) -> SidebarSnapshot.HeaderContent {
        SidebarSnapshot.HeaderContent(name: name, renaming: renaming, focusMember: focusMember,
                                      addVisible: addVisible, expanded: expanded)
    }

    private func mutations() -> [SidebarSnapshot.RowContent] {
        var renamed = content()
        renamed.name = "changed"
        var renaming = content()
        renaming.renaming = true
        var glyphed = content()
        glyphed.glyph = LinuxStatusGlyphPresentation(indicator: AgentIndicator(status: .active),
                                                     settings: AppSettings())
        var blinking = content()
        blinking.blink = true
        var starred = content()
        starred.star = true
        var badged = content()
        badged.badge = "2"
        return [renamed, renaming, glyphed, blinking, starred, badged]
    }

    @Test("each row content change updates exactly its own row")
    func rowContentChanges() {
        let base = snapshot([ids[0]: content(), ids[1]: content()], order: [ids[0], ids[1]])
        for changed in mutations() {
            let to = snapshot([ids[0]: changed, ids[1]: content()], order: [ids[0], ids[1]])
            #expect(SidebarSnapshotDiff.plan(from: base, to: to) == [.updateRow(ids[0])])
        }
    }

    @Test("each header change updates exactly its own header")
    func headerChanges() {
        let base = snapshot([:], order: [], header: header())
        for changed in [header(name: "two"), header(renaming: true), header(focusMember: true),
                        header(addVisible: false), header(expanded: false)] {
            #expect(SidebarSnapshotDiff.plan(from: base, to: snapshot([:], order: [], header: changed))
                == [.updateHeader(workspace)])
        }
    }

    @Test("a selection change is one op carrying the symmetric difference")
    func selectionChange() {
        let base = snapshot([ids[0]: content(), ids[1]: content()], order: [ids[0], ids[1]],
                            selection: [ids[0]])
        let to = snapshot([ids[0]: content(), ids[1]: content()], order: [ids[0], ids[1]],
                          selection: [ids[1]])

        #expect(SidebarSnapshotDiff.plan(from: base, to: to)
            == [.updateSelection([ids[0], ids[1]])])
    }

    @Test("an inserted row is built from its content; a moved one still takes its update")
    func structuralRowsAndTheirUpdates() {
        var changed = content()
        changed.name = "changed"
        let base = snapshot([ids[0]: content(), ids[1]: content()], order: [ids[0], ids[1]])
        let inserted = snapshot([ids[0]: content(), ids[1]: content(), ids[2]: changed],
                                order: [ids[0], ids[1], ids[2]])
        #expect(SidebarSnapshotDiff.plan(from: base, to: inserted)
            == [.insertRow(ids[2], section: workspace, index: 2)])

        // The move only reparents the widget; without the update the row would render stale content
        // for as long as nothing else about it changed.
        let moved = snapshot([ids[0]: changed, ids[1]: content()], order: [ids[1], ids[0]])
        #expect(SidebarSnapshotDiff.plan(from: base, to: moved, preferMoving: [ids[0]])
            == [.moveRow(ids[0], section: workspace, index: 1), .updateRow(ids[0])])

        let movedUnchanged = snapshot([ids[0]: content(), ids[1]: content()], order: [ids[1], ids[0]])
        #expect(SidebarSnapshotDiff.plan(from: base, to: movedUnchanged, preferMoving: [ids[0]])
            == [.moveRow(ids[0], section: workspace, index: 1)])
    }

    @Test("a collapse hides the list box AND repaints the header that owns the disclosure arrow")
    func collapseRepaintsTheHeader() {
        let base = SidebarSnapshot(sections: [section(workspace, [], header: header())])
        let collapsed = SidebarSnapshot(
            sections: [section(workspace, [], expanded: false, header: header(expanded: false))])

        #expect(SidebarSnapshotDiff.plan(from: base, to: collapsed)
            == [.setExpanded(workspace, false), .updateHeader(workspace)])
    }

    @Test("a settings-only change updates only the rows whose presentation moved")
    func settingsOnlyChange() {
        let active = Session(initialCwd: "/tmp", customName: "active")
        active.agentIndicator = AgentIndicator(status: .active)
        let idle = Session(initialCwd: "/tmp", customName: "idle")
        let store = AppStore(workspaces: [Workspace(name: "one", sessions: [active, idle])])
        var settings = AppSettings()
        settings.activeStatusColorHex = "#112233"

        let expanded = persistedExpansion(store)
        let before = SidebarSnapshot.desired(from: store, settings: AppSettings(), renaming: nil,
                                             expandedWorkspaceIDs: expanded)
        let after = SidebarSnapshot.desired(from: store, settings: settings, renaming: nil,
                                            expandedWorkspaceIDs: expanded)
        #expect(SidebarSnapshotDiff.plan(from: before, to: after) == [.updateRow(active.id)])
    }
}

/// The drag and reorder call sites, driven through their OWN composition: the slot helpers and the
/// unchanged `SidebarDrop` resolvers mutate a real store, and the plan is taken across `desired`
/// snapshots with the hint the handler passes to `syncSidebar`.
@Suite("sidebar drag and reorder plans")
@MainActor
struct SidebarDropDiffTests {
    private func snapshot(_ store: AppStore) -> SidebarSnapshot {
        SidebarSnapshot.desired(from: store, settings: AppSettings(), renaming: nil,
                                expandedWorkspaceIDs: persistedExpansion(store))
    }

    private func sources(_ store: AppStore, _ ids: [UUID]) -> [SidebarDrop.SessionSource] {
        ids.compactMap { id in
            store.sessionLocation(ofSession: id).map {
                SidebarDrop.SessionSource(workspace: $0.workspace, index: $0.index)
            }
        }
    }

    /// `handleSessionDrop`'s composition; returns the block it moved, which is what it hints with.
    private func dropOnRow(_ store: AppStore, source: UUID, onto target: UUID,
                           bottomHalf: Bool) -> Set<UUID> {
        guard let location = store.sessionLocation(ofSession: target) else { return [] }
        let slot = LinuxSidebarPolicy.dropInsertionSlot(targetIndex: location.index,
                                                        y: bottomHalf ? 22 : 8, height: 30)
        let ids = LinuxSidebarPolicy.draggedSessionBlock(source: source,
                                                        selection: store.sidebarSelectionIDs)
        guard let resolution = SidebarDrop.resolveSessions(
            sources: sources(store, ids),
            target: .sessionRow(workspace: location.workspace, sessionIndex: location.index,
                                sessionCount: location.count),
            childIndex: slot) else { return [] }
        store.moveSessions(ids, toWorkspace: resolution.workspace, at: resolution.destination)
        return Set(ids)
    }

    /// `handleSessionToWorkspace`'s composition.
    private func dropOnHeader(_ store: AppStore, source: UUID, workspace: UUID) -> Set<UUID> {
        guard let target = store.workspaces.first(where: { $0.id == workspace }) else { return [] }
        let ids = LinuxSidebarPolicy.draggedSessionBlock(source: source,
                                                        selection: store.sidebarSelectionIDs)
        guard let resolution = SidebarDrop.resolveSessions(
            sources: sources(store, ids),
            target: .workspaceRow(id: workspace, sessionCount: target.sessions.count),
            childIndex: SidebarDrop.onItemIndex) else { return [] }
        store.moveSessions(ids, toWorkspace: resolution.workspace, at: resolution.destination)
        return Set(ids)
    }

    /// `handleWorkspaceDrop`'s composition, including the visible-space slot mapping.
    private func dragWorkspace(_ store: AppStore, source: UUID, onto target: UUID, bottomHalf: Bool) {
        let visible = store.visibleWorkspaces
        guard let index = store.workspaces.firstIndex(where: { $0.id == source }),
              let targetVisibleIndex = visible.firstIndex(where: { $0.id == target }) else { return }
        let visibleIndices = visible.compactMap { workspace in
            store.workspaces.firstIndex(where: { $0.id == workspace.id })
        }
        let childIndex = LinuxSidebarPolicy.workspaceDropChildIndex(
            targetVisibleIndex: targetVisibleIndex, visibleIndices: visibleIndices,
            y: bottomHalf ? 22 : 8, height: 30)
        guard let resolution = SidebarDrop.resolveWorkspace(
            sourceIndex: index, count: store.workspaces.count, childIndex: childIndex) else { return }
        store.moveWorkspace(source, at: resolution.destination)
    }

    private func sessions(_ names: [String]) -> [Session] {
        names.map { Session(initialCwd: "/tmp", customName: $0) }
    }

    @Test("a dragged block moves only its own rows and keeps its selection")
    func blockDragMovesOnlyTheBlock() {
        let rows = sessions(["s0", "s1", "s2", "s3"])
        let workspace = Workspace(name: "one", sessions: rows)
        let store = AppStore(workspaces: [workspace], selectedSessionID: rows[0].id)
        store.setSidebarSelection([rows[0].id, rows[1].id])
        let before = snapshot(store)

        let dragged = dropOnRow(store, source: rows[0].id, onto: rows[3].id, bottomHalf: true)
        let after = snapshot(store)
        #expect(after.sections[0].rows == [rows[2].id, rows[3].id, rows[0].id, rows[1].id])

        let key = Key.workspace(workspace.id)
        #expect(SidebarSnapshotDiff.plan(from: before, to: after, preferMoving: dragged)
            == [.moveRow(rows[1].id, section: key, index: 3),
                .moveRow(rows[0].id, section: key, index: 2)])
        // A move re-roots the row but changes no selection: the `agterm-selected` paint rides the
        // surviving widget and the two `moveRow`s are what re-publish the accessible state.
        #expect(store.sidebarSelectionIDs == [rows[0].id, rows[1].id])
        #expect(after.selection == before.selection)
    }

    @Test("a header drop appends the whole block as moves into the target workspace")
    func headerDropMovesTheBlock() {
        let moving = sessions(["m0", "m1"])
        let resident = sessions(["r"])
        let source = Workspace(name: "src", sessions: moving)
        let target = Workspace(name: "dst", sessions: resident)
        let store = AppStore(workspaces: [source, target], selectedSessionID: moving[0].id)
        store.setSidebarSelection([moving[0].id, moving[1].id])
        let before = snapshot(store)

        let dragged = dropOnHeader(store, source: moving[0].id, workspace: target.id)
        let after = snapshot(store)
        #expect(after.sections.map(\.rows)
            == [[], [resident[0].id, moving[0].id, moving[1].id]])

        let key = Key.workspace(target.id)
        #expect(SidebarSnapshotDiff.plan(from: before, to: after, preferMoving: dragged)
            == [.moveRow(moving[1].id, section: key, index: 1),
                .moveRow(moving[0].id, section: key, index: 1)])
        #expect(store.sidebarSelectionIDs == [moving[0].id, moving[1].id])
    }

    @Test("a drop into a collapsed workspace is the same moves and leaves it collapsed")
    func headerDropIntoCollapsedWorkspace() {
        let moving = sessions(["m0", "m1"])
        let resident = sessions(["r"])
        let source = Workspace(name: "src", sessions: moving)
        let target = Workspace(name: "dst", sessions: resident, isExpanded: false)
        let store = AppStore(workspaces: [source, target], selectedSessionID: moving[0].id)
        store.setSidebarSelection([moving[0].id, moving[1].id])
        let before = snapshot(store)

        let dragged = dropOnHeader(store, source: moving[0].id, workspace: target.id)
        let after = snapshot(store)
        let key = Key.workspace(target.id)
        #expect(SidebarSnapshotDiff.plan(from: before, to: after, preferMoving: dragged)
            == [.moveRow(moving[1].id, section: key, index: 1),
                .moveRow(moving[0].id, section: key, index: 1)])
        #expect(!after.sections[1].expanded)
        #expect(after.sections[1].rows == [resident[0].id, moving[0].id, moving[1].id])
        #expect(store.sidebarSelectionIDs == [moving[0].id, moving[1].id])
    }

    @Test("a filtered workspace drag moves only the dragged section")
    func filteredWorkspaceDrag() {
        let workspaces = ["a", "b", "c", "d"].map {
            Workspace(name: $0, sessions: sessions([$0]))
        }
        let store = AppStore(workspaces: workspaces, selectedSessionID: workspaces[1].sessions[0].id)
        store.setFocusMembership(workspaces[1].id, member: true)
        store.setFocusMembership(workspaces[3].id, member: true)
        store.setFocusEnabled(true)
        let before = snapshot(store)
        #expect(before.sections.map(\.key)
            == [.workspace(workspaces[1].id), .workspace(workspaces[3].id)])

        dragWorkspace(store, source: workspaces[1].id, onto: workspaces[3].id, bottomHalf: true)
        let after = snapshot(store)
        #expect(store.workspaces.map(\.name) == ["a", "c", "d", "b"])
        #expect(SidebarSnapshotDiff.plan(from: before, to: after,
                                         preferMoving: [workspaces[1].id])
            == [.moveSection(.workspace(workspaces[1].id), index: 1)])
    }

    @Test("keyboard reorder moves exactly the reordered row and the reordered section")
    func keyboardReorder() {
        let rows = sessions(["s0", "s1", "s2"])
        let workspace = Workspace(name: "one", sessions: rows)
        let other = Workspace(name: "two", sessions: sessions(["t"]))
        let store = AppStore(workspaces: [workspace, other], selectedSessionID: rows[0].id)

        let beforeRow = snapshot(store)
        store.reorderSession(rows[0].id, .down)
        #expect(SidebarSnapshotDiff.plan(from: beforeRow, to: snapshot(store),
                                         preferMoving: [rows[0].id])
            == [.moveRow(rows[0].id, section: .workspace(workspace.id), index: 1)])

        let beforeSection = snapshot(store)
        store.reorderWorkspace(workspace.id, .down)
        #expect(SidebarSnapshotDiff.plan(from: beforeSection, to: snapshot(store),
                                         preferMoving: [workspace.id])
            == [.moveSection(.workspace(workspace.id), index: 1)])
    }
}
